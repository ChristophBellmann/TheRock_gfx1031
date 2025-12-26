from __future__ import annotations

import json
import os
import re
import shutil
import sys
import tarfile
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable

from core.artifacts import write_report_json
from core.context import Context
from core.download import DownloadPolicy, download
from core.power import PowerSampler, discover_sensors, format_power_metrics, write_csv
from core.rocm_env import activated_env, which
from core.tree import detect_build_dirs, rocm_dist_for_build
from core.reporting.models import StepResult
from core.runner import fmt_duration, run_cmd


@dataclass(frozen=True)
class Step:
    group: str
    key: str
    name: str
    expected: str
    fn: Callable[[Context, dict[str, Any], str, Path, dict[str, str], Path | None], StepResult]


def _log_path(ctx: Context, build_dir: str, key: str) -> Path | None:
    if ctx.logs_dir is None:
        return None
    return ctx.logs_dir / f"{build_dir}.{key}.log"


def _downloads_enabled(cfg: dict[str, Any]) -> bool:
    run_cfg = cfg.get("run", {})
    return bool(run_cfg.get("downloads_enabled", True))


def _dl_policy(cfg: dict[str, Any]) -> DownloadPolicy:
    run_cfg = cfg.get("run", {})
    max_total_gb = float(run_cfg.get("max_download_gb", 8))
    max_single_gb = float(run_cfg.get("max_single_download_gb", 4))
    return DownloadPolicy(
        max_total_bytes=int(max_total_gb * 1024 * 1024 * 1024),
        max_single_bytes=int(max_single_gb * 1024 * 1024 * 1024),
    )


def _power_enabled(cfg: dict[str, Any]) -> bool:
    return bool(cfg.get("run", {}).get("power_monitor", False))


def _power_csv_path(ctx: Context, build_dir: str, key: str) -> Path | None:
    if ctx.logs_dir is None:
        return None
    return ctx.logs_dir / f"{build_dir}.{key}.power.csv"


def _with_power_sampler(ctx: Context, cfg: dict[str, Any], build_dir: str, key: str, fn):
    if not _power_enabled(cfg):
        return fn(None)
    sensors = discover_sensors()
    if sensors is None:
        return fn(None)
    sampler = PowerSampler(sensors=sensors, interval_s=0.5)
    sampler.start()
    try:
        return fn(sampler)
    finally:
        sampler.stop()
        csvp = _power_csv_path(ctx, build_dir, key)
        if csvp is not None:
            write_csv(csvp, sampler.samples())


def _baseline_cache(cfg: dict[str, Any]) -> dict[str, Any]:
    rt = cfg.setdefault("_runtime", {})
    return rt.setdefault("power_baseline", {})


def _get_baseline_avg_w(cfg: dict[str, Any], build_dir: str) -> float | None:
    b = _baseline_cache(cfg).get(build_dir) or {}
    v = b.get("avg_w")
    try:
        return float(v) if v is not None else None
    except Exception:
        return None


def _set_baseline(cfg: dict[str, Any], build_dir: str, *, avg_w: float | None, peak_w: float | None, energy_ws: float | None, gpu: float | None, mem: float | None) -> None:
    _baseline_cache(cfg)[build_dir] = {"avg_w": avg_w, "peak_w": peak_w, "energy_ws": energy_ws, "gpu": gpu, "mem": mem}


def _step_power_idle_baseline(ctx: Context, cfg: dict[str, Any], build_dir: str, rocm_dist: Path, env: dict[str, str], log: Path | None) -> StepResult:
    if not _power_enabled(cfg):
        return StepResult(build_dir, "Power idle baseline", "SKIP", "0ms", "power monitor disabled")
    sensors = discover_sensors()
    if sensors is None:
        return StepResult(build_dir, "Power idle baseline", "SKIP", "0ms", "no amdgpu power sensor found in sysfs")
    sampler = PowerSampler(sensors=sensors, interval_s=0.5)
    sampler.start()
    try:
        # No GPU load: just sleep to measure baseline.
        time.sleep(5.0)
    finally:
        sampler.stop()
        csvp = _power_csv_path(ctx, build_dir, "power_idle_baseline")
        if csvp is not None:
            write_csv(csvp, sampler.samples())
    avg = sampler.avg_power_w()
    peak = sampler.peak_power_w()
    e = sampler.energy_ws()
    gpu = sampler.avg_gpu_busy()
    mem = sampler.avg_mem_busy()
    _set_baseline(cfg, build_dir, avg_w=avg, peak_w=peak, energy_ws=e, gpu=gpu, mem=mem)
    metric = format_power_metrics(sampler)
    warn = []
    if gpu is not None and gpu >= 10.0:
        warn.append(f"gpu%={gpu:.0f} (busy?)")
    if warn:
        metric = (metric + " WARN:" + ";".join(warn)).strip()
    return StepResult(build_dir, "Power idle baseline", "OK", "5.000s", metric)


def _repeat_cmd_for_load(
    ctx: Context,
    env: dict[str, str],
    cmd: list[str],
    *,
    min_wall_s: float = 5.0,
    max_wall_s: float = 8.0,
    per_run_timeout_s: int = 60,
    log: Path | None,
):
    """
    Run `cmd` repeatedly to create sustained load.

    Some upstream bench tools have a large fixed setup cost or ignore iteration knobs.
    Repeating the process is a pragmatic way to keep GPU/CPU utilization visible for ~5s.
    """
    start = time.monotonic()
    total_ms = 0
    runs = 0
    last = None
    while True:
        r = run_cmd(ctx.repo_root, env, cmd, per_run_timeout_s, log)
        last = r
        runs += 1
        total_ms += r.dur_ms
        if r.rc != 0:
            return r, total_ms, runs
        elapsed = time.monotonic() - start
        if elapsed >= min_wall_s or elapsed >= max_wall_s:
            return r, total_ms, runs


def _step_rocm_env(ctx: Context, cfg: dict[str, Any], build_dir: str, rocm_dist: Path, env: dict[str, str], log: Path | None) -> StepResult:
    ok = (rocm_dist / "bin").is_dir() and (rocm_dist / "llvm" / "bin").is_dir()
    return StepResult(build_dir, "ROCm env activation", "OK" if ok else "FAIL", "0ms", f"ROCM_PATH={rocm_dist}")


def _step_rocminfo(ctx: Context, cfg: dict[str, Any], build_dir: str, rocm_dist: Path, env: dict[str, str], log: Path | None) -> StepResult:
    t = int(cfg.get("timeouts_s", {}).get("rocminfo", 10))
    r = run_cmd(ctx.repo_root, env, ["rocminfo"], t, log)
    return StepResult(build_dir, "rocminfo", "OK" if r.rc == 0 else "FAIL", fmt_duration(r.dur_ms), "" if r.rc == 0 else f"rc={r.rc}")


def _step_hipcc_compile_run(ctx: Context, cfg: dict[str, Any], build_dir: str, rocm_dist: Path, env: dict[str, str], log: Path | None) -> StepResult:
    t = int(cfg.get("timeouts_s", {}).get("hipcc_compile_run", 120))
    hipcc = which("hipcc", env)
    if not hipcc:
        return StepResult(build_dir, "hipcc compile+run", "SKIP", "0ms", "hipcc not in PATH")

    arch = str(cfg.get("rocm", {}).get("amd_gpu_arch", "gfx1031"))
    with tempfile.TemporaryDirectory(prefix="rocm-validation-hip-") as td:
        td = Path(td)
        src = td / "vadd.cpp"
        exe = td / "vadd"
        src.write_text(
            r"""
#include <hip/hip_runtime.h>
#include <cstdio>
#include <chrono>
#include <cstdlib>
#include <vector>

__global__ void vadd(const float* a, const float* b, float* c, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i < n) c[i] = a[i] + b[i];
}

int main() {
  // Choose a size that is big enough to keep the GPU busy for a few seconds
  // (we want sustained load, not just microsecond kernels).
  int n = 1<<25; // 33,554,432 floats (~128MB per vector)
  int iters = 3000;
  size_t bytes = n * sizeof(float);
  std::vector<float> ha(n, 1.0f), hb(n, 2.0f), hc(n, 0.0f);
  float *da=nullptr, *db=nullptr, *dc=nullptr;
  if (hipMalloc(&da, bytes) != hipSuccess ||
      hipMalloc(&db, bytes) != hipSuccess ||
      hipMalloc(&dc, bytes) != hipSuccess) {
    std::fprintf(stderr, "hipMalloc failed (bytes=%zu)\n", bytes);
    return 2;
  }
  hipMemcpy(da, ha.data(), bytes, hipMemcpyHostToDevice);
  hipMemcpy(db, hb.data(), bytes, hipMemcpyHostToDevice);
  int threads = 256;
  int blocks = (n + threads - 1) / threads;
  hipDeviceSynchronize();
  auto t0 = std::chrono::high_resolution_clock::now();
  for (int i = 0; i < iters; i++) {
    hipLaunchKernelGGL(vadd, dim3(blocks), dim3(threads), 0, 0, da, db, dc, n);
  }
  hipDeviceSynchronize();
  auto t1 = std::chrono::high_resolution_clock::now();
  hipMemcpy(hc.data(), dc, bytes, hipMemcpyDeviceToHost);
  hipFree(da); hipFree(db); hipFree(dc);
  for (int i = 0; i < 10; i++) {
    if (hc[i] != 3.0f) { std::printf("FAIL %d %f\n", i, hc[i]); return 1; }
  }
  auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(t1 - t0).count();
  std::printf("OK iters=%d ms=%lld\n", iters, (long long)ms);
  return 0;
}
""".lstrip(),
            encoding="utf-8",
        )
        r1 = run_cmd(ctx.repo_root, env, [hipcc, f"--offload-arch={arch}", str(src), "-O2", "-o", str(exe)], t, log)
        if r1.rc != 0:
            return StepResult(build_dir, "hipcc compile+run", "FAIL", fmt_duration(r1.dur_ms), f"compile rc={r1.rc}")
        def run_kernel(sampler: PowerSampler | None):
            r2 = run_cmd(ctx.repo_root, env, [str(exe)], 120, log)
            return r2, sampler

        r2, sampler = _with_power_sampler(ctx, cfg, build_dir, "hipcc_compile_run", run_kernel)
        ok = (r2.rc == 0) and ("OK" in (r2.out + r2.err))
        metric = "" if ok else f"run rc={r2.rc}"
        if ok and sampler is not None:
            pm = format_power_metrics(sampler, baseline_avg_w=_get_baseline_avg_w(cfg, build_dir))
            if pm:
                metric = (metric + " " + pm).strip()
        return StepResult(build_dir, "hipcc compile+run", "OK" if ok else "FAIL", fmt_duration(r1.dur_ms + r2.dur_ms), metric)


def _extract_gflops(text: str) -> float | None:
    # Matches rocblas-bench CSV output tail: "<GFLOPS>, <ms>"
    import re

    m = re.search(r"([0-9]+(?:\.[0-9]+)?)\s*,\s*[0-9]+(?:\.[0-9]+)?\s*$", text.strip(), re.M)
    if not m:
        return None
    try:
        return float(m.group(1))
    except ValueError:
        return None


def _step_rocblas(ctx: Context, cfg: dict[str, Any], build_dir: str, rocm_dist: Path, env: dict[str, str], log: Path | None) -> StepResult:
    t = int(cfg.get("timeouts_s", {}).get("rocblas_bench", 60))
    if not which("rocblas-bench", env):
        return StepResult(build_dir, "rocBLAS GEMM f32", "SKIP", "0ms", "rocblas-bench not in PATH")
    cmd = [
        "rocblas-bench",
        "-f",
        "gemm",
        "-r",
        "f32_r",
        "-m",
        "2048",
        "-n",
        "2048",
        "-k",
        "2048",
        "--alpha",
        "1",
        "--beta",
        "0",
        "--iters",
        "10",
    ]
    def run_load(sampler: PowerSampler | None):
        r, total_ms, runs = _repeat_cmd_for_load(ctx, env, cmd, min_wall_s=5.0, max_wall_s=8.0, per_run_timeout_s=t, log=log)
        return r, total_ms, runs, sampler

    r, total_ms, runs, sampler = _with_power_sampler(ctx, cfg, build_dir, "rocblas_gemm_f32", run_load)
    if r.rc != 0:
        return StepResult(build_dir, "rocBLAS GEMM f32", "FAIL", fmt_duration(total_ms), f"rc={r.rc}")
    gflops = _extract_gflops(r.out + "\n" + r.err)
    metric = f"runs={runs}"
    if gflops is not None:
        metric += f" TFLOPS={gflops/1000.0:.3f} (GFLOPS={gflops:.1f})"
    if sampler is not None:
        pm = format_power_metrics(sampler, baseline_avg_w=_get_baseline_avg_w(cfg, build_dir))
        if pm:
            metric += f" {pm}"
    return StepResult(build_dir, "rocBLAS GEMM f32", "OK", fmt_duration(total_ms), metric)


def _step_rocfft(ctx: Context, cfg: dict[str, Any], build_dir: str, rocm_dist: Path, env: dict[str, str], log: Path | None) -> StepResult:
    t = int(cfg.get("timeouts_s", {}).get("rocfft_bench", 30))
    if not which("rocfft-bench", env):
        return StepResult(build_dir, "rocFFT 1024", "SKIP", "0ms", "rocfft-bench not in PATH")
    cmd = ["rocfft-bench", "--length", "1024", "--precision", "single", "-t", "0", "-N", "2"]
    def run_load(sampler: PowerSampler | None):
        r, total_ms, runs = _repeat_cmd_for_load(ctx, env, cmd, min_wall_s=5.0, max_wall_s=8.0, per_run_timeout_s=t, log=log)
        return r, total_ms, runs, sampler

    r, total_ms, runs, sampler = _with_power_sampler(ctx, cfg, build_dir, "rocfft_1024", run_load)
    if r.rc != 0:
        return StepResult(build_dir, "rocFFT 1024", "FAIL", fmt_duration(total_ms), f"rc={r.rc}")
    metric = f"runs={runs}"
    if sampler is not None:
        pm = format_power_metrics(sampler, baseline_avg_w=_get_baseline_avg_w(cfg, build_dir))
        if pm:
            metric += f" {pm}"
    return StepResult(build_dir, "rocFFT 1024", "OK", fmt_duration(total_ms), metric)


def _step_rocrand(ctx: Context, cfg: dict[str, Any], build_dir: str, rocm_dist: Path, env: dict[str, str], log: Path | None) -> StepResult:
    t = int(cfg.get("timeouts_s", {}).get("rocrand_bench", 30))
    if not which("benchmark_rocrand_generate", env):
        return StepResult(build_dir, "rocRAND generate", "SKIP", "0ms", "benchmark_rocrand_generate not in PATH")
    cmd = [
        "benchmark_rocrand_generate",
        "--size",
        "16777216",
        "--trials",
        "2",
        "--dis",
        "uniform-float",
        "--engine",
        "philox",
        "--format",
        "csv",
    ]
    def run_load(sampler: PowerSampler | None):
        r, total_ms, runs = _repeat_cmd_for_load(ctx, env, cmd, min_wall_s=5.0, max_wall_s=8.0, per_run_timeout_s=t, log=log)
        return r, total_ms, runs, sampler

    r, total_ms, runs, sampler = _with_power_sampler(ctx, cfg, build_dir, "rocrand_generate", run_load)
    if r.rc != 0:
        return StepResult(build_dir, "rocRAND generate", "FAIL", fmt_duration(total_ms), f"rc={r.rc}")
    metric = f"runs={runs} size=16777216"
    if sampler is not None:
        pm = format_power_metrics(sampler, baseline_avg_w=_get_baseline_avg_w(cfg, build_dir))
        if pm:
            metric += f" {pm}"
    return StepResult(build_dir, "rocRAND generate", "OK", fmt_duration(total_ms), metric)


def _step_miopen_driver(ctx: Context, cfg: dict[str, Any], build_dir: str, rocm_dist: Path, env: dict[str, str], log: Path | None) -> StepResult:
    t = int(cfg.get("timeouts_s", {}).get("miopen_driver", 10))
    drv = which("MIOpenDriver", env) or which("miopen-driver", env)
    if not drv:
        return StepResult(build_dir, "MIOpen driver", "SKIP", "0ms", "MIOpenDriver/miopen-driver not in PATH")
    r = run_cmd(ctx.repo_root, env, [drv, "--version"], t, log)
    return StepResult(build_dir, "MIOpen driver", "OK" if r.rc == 0 else "FAIL", fmt_duration(r.dur_ms), f"driver={Path(drv).name}")


def _step_miopen_smoke(ctx: Context, cfg: dict[str, Any], build_dir: str, rocm_dist: Path, env: dict[str, str], log: Path | None) -> StepResult:
    t = int(cfg.get("timeouts_s", {}).get("miopen_smoke", 240))
    drv = which("MIOpenDriver", env) or which("miopen-driver", env)
    if not drv:
        return StepResult(build_dir, "MIOpen smoke", "SKIP", "0ms", "MIOpenDriver/miopen-driver not in PATH")
    def cmd_for(iters: int) -> list[str]:
        # Use a moderately-sized forward conv with timing enabled and verification disabled.
        # Goal: ~5s of sustained GPU load (adaptive iters).
        return [
            drv,
            "conv",
            "--forw",
            "1",
            "--verify",
            "0",
            "--gpualloc",
            "1",
            "--time",
            "1",
            "--wall",
            "1",
            "--iter",
            str(iters),
            "--batchsize",
            "32",
            "--in_channels",
            "64",
            "--out_channels",
            "64",
            "--in_h",
            "224",
            "--in_w",
            "224",
            "--fil_h",
            "3",
            "--fil_w",
            "3",
            "--pad_h",
            "1",
            "--pad_w",
            "1",
        ]

    # `--iter` is not always reliably reflected in wall time (backend-specific), so we
    # also repeat the command until we reach sustained load.
    cmd = cmd_for(20)

    def run_load(sampler: PowerSampler | None):
        r, total_ms, runs = _repeat_cmd_for_load(ctx, env, cmd, min_wall_s=5.0, max_wall_s=10.0, per_run_timeout_s=t, log=log)
        return r, total_ms, runs, sampler

    r, total_ms, runs, sampler = _with_power_sampler(ctx, cfg, build_dir, "miopen_smoke", run_load)
    if r.rc != 0:
        return StepResult(build_dir, "MIOpen smoke", "FAIL", fmt_duration(total_ms), f"rc={r.rc}")
    metric = f"driver={Path(drv).name} runs={runs} iters=20"
    if sampler is not None:
        pm = format_power_metrics(sampler, baseline_avg_w=_get_baseline_avg_w(cfg, build_dir))
        if pm:
            metric += f" {pm}"
    return StepResult(build_dir, "MIOpen smoke", "OK", fmt_duration(total_ms), metric)


def _pip_install(ctx: Context, env: dict[str, str], pkgs: list[str], log: Path | None, timeout_s: int) -> StepResult | None:
    cmd = [sys.executable, "-m", "pip", "install"] + pkgs
    r = run_cmd(ctx.repo_root, env, cmd, timeout_s, log)
    if r.rc != 0:
        return StepResult("<meta>", "pip install", "FAIL", fmt_duration(r.dur_ms), f"rc={r.rc}")
    return None


def _step_llama_cpp_docker(ctx: Context, cfg: dict[str, Any], build_dir: str, rocm_dist: Path, env: dict[str, str], log: Path | None) -> StepResult:
    if not _downloads_enabled(cfg):
        return StepResult(build_dir, "llama.cpp (docker) smoke", "SKIP", "0ms", "downloads disabled")
    if which("docker", env) is None:
        return StepResult(build_dir, "llama.cpp (docker) smoke", "SKIP", "0ms", "docker not installed or not in PATH")

    url = "https://rocm.docs.amd.com/projects/install-on-linux/en/latest/install/3rd-party/llama-cpp-install.html"
    r = run_cmd(ctx.repo_root, env, ["bash", "-lc", f"curl -fsSL {url!s}"], 30, log)
    if r.rc != 0:
        return StepResult(build_dir, "llama.cpp (docker) smoke", "FAIL", fmt_duration(r.dur_ms), f"failed to fetch docs rc={r.rc}")

    tags = re.findall(r"rocm/llama\\.cpp:([a-zA-Z0-9._-]+_(?:server|full|light))", r.out)
    if not tags:
        return StepResult(build_dir, "llama.cpp (docker) smoke", "FAIL", fmt_duration(r.dur_ms), "no rocm/llama.cpp tag found in docs HTML")
    image = f"rocm/llama.cpp:{tags[0]}"

    rp = run_cmd(ctx.repo_root, env, ["docker", "pull", image], int(cfg.get("timeouts_s", {}).get("llama_cpp_docker", 900)), log)
    if rp.rc != 0:
        return StepResult(build_dir, "llama.cpp (docker) smoke", "FAIL", fmt_duration(rp.dur_ms), f"docker pull rc={rp.rc}")

    rr = run_cmd(ctx.repo_root, env, ["docker", "run", "--rm", image, "--help"], 60, log)
    return StepResult(build_dir, "llama.cpp (docker) smoke", "OK" if rr.rc == 0 else "FAIL", fmt_duration(rp.dur_ms + rr.dur_ms), f"image={image}")


def _step_ollama(ctx: Context, cfg: dict[str, Any], build_dir: str, rocm_dist: Path, env: dict[str, str], log: Path | None) -> StepResult:
    if not _downloads_enabled(cfg):
        return StepResult(build_dir, "Ollama (local binary) smoke", "SKIP", "0ms", "downloads disabled")

    exe = which("ollama", env)
    if exe is None:
        tgz = ctx.downloads_dir() / "ollama" / "ollama-linux-amd64.tgz"
        root = ctx.builds_dir() / "ollama" / "root"
        bin_path = root / "bin" / "ollama"
        if not bin_path.exists():
            url = "https://ollama.com/download/ollama-linux-amd64.tgz"
            try:
                download(ctx, url, tgz, policy=_dl_policy(cfg))
                if root.exists():
                    shutil.rmtree(root)
                root.mkdir(parents=True, exist_ok=True)
                with tarfile.open(tgz, "r:gz") as tf:
                    tf.extractall(path=root)
                if (root / "ollama").is_file() and not bin_path.exists():
                    (root / "ollama").rename(bin_path)
                bin_path.chmod(0o755)
            except Exception as e:
                return StepResult(build_dir, "Ollama (local binary) smoke", "FAIL", "0ms", f"download/extract failed: {e}")
        exe = str(bin_path)
    r = run_cmd(ctx.repo_root, env, [exe, "--version"], int(cfg.get("timeouts_s", {}).get("ollama", 120)), log)
    return StepResult(build_dir, "Ollama (local binary) smoke", "OK" if r.rc == 0 else "FAIL", fmt_duration(r.dur_ms), "ollama --version" if r.rc == 0 else f"rc={r.rc}")


def _step_open_interpreter(ctx: Context, cfg: dict[str, Any], build_dir: str, rocm_dist: Path, env: dict[str, str], log: Path | None) -> StepResult:
    if not _downloads_enabled(cfg):
        return StepResult(build_dir, "Open Interpreter (pip) smoke", "SKIP", "0ms", "downloads disabled")
    t = int(cfg.get("timeouts_s", {}).get("open_interpreter", 900))
    rpi = _pip_install(ctx, env, ["open-interpreter"], log, t)
    if rpi is not None:
        return StepResult(build_dir, "Open Interpreter (pip) smoke", "FAIL", rpi.duration, rpi.metric)
    interp = which("interpreter", env) or str(Path(sys.executable).resolve().parent / "interpreter")
    r = run_cmd(ctx.repo_root, env, [interp, "--help"], 20, log)
    return StepResult(build_dir, "Open Interpreter (pip) smoke", "OK" if r.rc == 0 else "FAIL", fmt_duration(r.dur_ms), "interpreter --help" if r.rc == 0 else f"rc={r.rc}")


def _step_whisper(ctx: Context, cfg: dict[str, Any], build_dir: str, rocm_dist: Path, env: dict[str, str], log: Path | None) -> StepResult:
    if not _downloads_enabled(cfg):
        return StepResult(build_dir, "Whisper (pip) smoke", "SKIP", "0ms", "downloads disabled")
    t = int(cfg.get("timeouts_s", {}).get("whisper", 1800))
    rpi = _pip_install(ctx, env, ["torch", "openai-whisper"], log, t)
    if rpi is not None:
        return StepResult(build_dir, "Whisper (pip) smoke", "FAIL", rpi.duration, rpi.metric)

    script = r"""
import os, wave, struct, math, time
import torch
import whisper

print("torch", torch.__version__)
print("torch.cuda.is_available", torch.cuda.is_available())
print("torch.version.hip", getattr(torch.version, "hip", None))

sr=16000
dur=1.0
freq=440.0
n=int(sr*dur)
fname=os.path.join("validation","workspace","cache","downloads","whisper_test.wav")
os.makedirs(os.path.dirname(fname), exist_ok=True)
with wave.open(fname, "w") as w:
    w.setnchannels(1)
    w.setsampwidth(2)
    w.setframerate(sr)
    for i in range(n):
        v=int(0.2*32767*math.sin(2*math.pi*freq*i/sr))
        w.writeframes(struct.pack("<h", v))

model=whisper.load_model("tiny.en")
t0=time.time()
result=model.transcribe(fname, fp16=False)
dt=time.time()-t0
print("seconds", dt)
print("text_len", len(result.get("text","")))
"""
    r = run_cmd(ctx.repo_root, env, [sys.executable, "-c", script], t, log)
    if r.rc != 0:
        return StepResult(build_dir, "Whisper (pip) smoke", "FAIL", fmt_duration(r.dur_ms), f"rc={r.rc}")
    out = r.out + "\n" + r.err
    metric = "ran tiny.en transcribe"
    if "torch.version.hip None" in out and "torch.cuda.is_available False" in out:
        metric += " (CPU torch; ROCm not detected)"
    return StepResult(build_dir, "Whisper (pip) smoke", "OK", fmt_duration(r.dur_ms), metric)


def _step_mfem(ctx: Context, cfg: dict[str, Any], build_dir: str, rocm_dist: Path, env: dict[str, str], log: Path | None) -> StepResult:
    if not _downloads_enabled(cfg):
        return StepResult(build_dir, "MFEM (HIP) build+run", "SKIP", "0ms", "downloads disabled")
    if which("cmake", env) is None or which("ninja", env) is None:
        return StepResult(build_dir, "MFEM (HIP) build+run", "SKIP", "0ms", "missing cmake/ninja (install system packages)")
    if which("hipcc", env) is None:
        return StepResult(build_dir, "MFEM (HIP) build+run", "SKIP", "0ms", "hipcc not in PATH (need Stage-2 dist)")

    t = int(cfg.get("timeouts_s", {}).get("mfem_hip", 3600))
    src = ctx.git_cache_dir() / "mfem"
    bld = ctx.builds_dir() / "mfem"
    if not src.exists():
        r0 = run_cmd(ctx.repo_root, env, ["git", "clone", "--depth", "1", "https://github.com/mfem/mfem.git", str(src)], 900, log)
        if r0.rc != 0:
            return StepResult(build_dir, "MFEM (HIP) build+run", "FAIL", fmt_duration(r0.dur_ms), f"git clone rc={r0.rc}")

    bld.mkdir(parents=True, exist_ok=True)
    hipcc = which("hipcc", env) or "hipcc"
    clangxx = str(rocm_dist / "llvm" / "bin" / "clang++")
    arch = str(cfg.get("rocm", {}).get("amd_gpu_arch", "gfx1031"))
    cfg_cmd = [
        "cmake",
        "-S",
        str(src),
        "-B",
        str(bld),
        "-G",
        "Ninja",
        "-DMFEM_USE_HIP=YES",
        f"-DHIP_ARCH={arch}",
        f"-DCMAKE_CXX_COMPILER={clangxx}",
        f"-DCMAKE_HIP_COMPILER={hipcc}",
    ]
    r1 = run_cmd(ctx.repo_root, env, cfg_cmd, 600, log)
    if r1.rc != 0:
        return StepResult(build_dir, "MFEM (HIP) build+run", "FAIL", fmt_duration(r1.dur_ms), f"cmake rc={r1.rc}")
    r2 = run_cmd(ctx.repo_root, env, ["ninja", "-C", str(bld), "-j4"], t, log)
    if r2.rc != 0:
        return StepResult(build_dir, "MFEM (HIP) build+run", "FAIL", fmt_duration(r1.dur_ms + r2.dur_ms), f"ninja rc={r2.rc}")
    ex1 = bld / "examples" / "ex1"
    if not ex1.exists():
        ex1 = bld / "bin" / "ex1"
    if not ex1.exists():
        return StepResult(build_dir, "MFEM (HIP) build+run", "FAIL", fmt_duration(r1.dur_ms + r2.dur_ms), "MFEM ex1 not found after build")
    r3 = run_cmd(ctx.repo_root, env, [str(ex1), "-m", str(src / "data" / "star.mesh")], 60, log)
    return StepResult(build_dir, "MFEM (HIP) build+run", "OK" if r3.rc == 0 else "FAIL", fmt_duration(r1.dur_ms + r2.dur_ms + r3.dur_ms), "ex1 star.mesh" if r3.rc == 0 else f"run rc={r3.rc}")


def build_plan(cfg: dict[str, Any], *, doctor_only: bool = False) -> list[Step]:
    steps_cfg = cfg.get("steps", {})
    plan: list[Step] = []

    def group_enabled(group: str) -> bool:
        return bool(steps_cfg.get(group, True))

    def add(group: str, key: str, name: str, expected: str, fn):
        if doctor_only and group not in {"rocm_sanity"}:
            return
        if not group_enabled(group):
            return
        plan.append(Step(group=group, key=key, name=name, expected=expected, fn=fn))

    add("rocm_sanity", "rocm_env", "ROCm env activation", "typ. <50ms", _step_rocm_env)
    add("rocm_sanity", "power_idle_baseline", "Power idle baseline", "5s (no load)", _step_power_idle_baseline)
    add("rocm_sanity", "rocminfo", "rocminfo", "typ. <1s", _step_rocminfo)
    add("rocm_sanity", "hipcc_compile_run", "hipcc compile+run", "typ. ~5s (sustained)", _step_hipcc_compile_run)

    add("rocm_bench_smoke", "rocblas_gemm_f32", "rocBLAS GEMM f32", "typ. ~5s (sustained)", _step_rocblas)
    add("rocm_bench_smoke", "rocfft_1024", "rocFFT 1024", "typ. ~5s (sustained)", _step_rocfft)
    add("rocm_bench_smoke", "rocrand_generate", "rocRAND generate", "typ. ~5s (sustained)", _step_rocrand)

    add("miopen_smoke", "miopen_driver", "MIOpen driver", "typ. <1s", _step_miopen_driver)
    add("miopen_smoke", "miopen_smoke", "MIOpen smoke", "typ. ~5s (sustained; first run may JIT)", _step_miopen_smoke)

    add("llama_cpp_docker", "llama_cpp_docker", "llama.cpp (docker) smoke", "minutes (pull), <5s run", _step_llama_cpp_docker)
    add("ollama", "ollama", "Ollama (local binary) smoke", "<10s download, <1s version", _step_ollama)
    add("open_interpreter", "open_interpreter", "Open Interpreter (pip) smoke", "minutes (pip), <2s help", _step_open_interpreter)
    add("whisper", "whisper", "Whisper (pip) smoke", "minutes (pip/model), <30s run", _step_whisper)
    add("mfem_hip", "mfem_hip", "MFEM (HIP) build+run", "minutes (clone/build), <5s run", _step_mfem)
    return plan


def run_plan(ctx: Context, cfg: dict[str, Any], plan: list[Step]) -> list[StepResult]:
    build_dirs = cfg.get("run", {}).get("build_dirs") or []
    if not build_dirs:
        build_dirs = detect_build_dirs(ctx.repo_root)

    results: list[StepResult] = []
    report: dict[str, Any] = {"run_id": ctx.run_id, "build_dirs": build_dirs, "results": []}
    for build_dir in build_dirs:
        rocm_dist = rocm_dist_for_build(ctx.repo_root, build_dir)
        env = activated_env(ctx.env_base(), rocm_dist)
        for step in plan:
            log = _log_path(ctx, build_dir, step.key)
            r = step.fn(ctx, cfg, build_dir, rocm_dist, env, log)
            results.append(r)
            report["results"].append(
                {
                    "build_dir": r.build_dir,
                    "group": step.group,
                    "key": step.key,
                    "name": r.name,
                    "status": r.status,
                    "duration": r.duration,
                    "metric": r.metric,
                }
            )
    write_report_json(ctx, report)
    return results
