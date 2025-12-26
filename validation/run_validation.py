#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import re
import shlex
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]


def is_tty() -> bool:
    try:
        return sys.stdout.isatty()
    except Exception:
        return False


class Ansi:
    def __init__(self, enabled: bool):
        self.enabled = enabled
        self.reset = "\033[0m" if enabled else ""
        self.bold = "\033[1m" if enabled else ""
        self.dim = "\033[2m" if enabled else ""
        self.red = "\033[31m" if enabled else ""
        self.green = "\033[32m" if enabled else ""
        self.yellow = "\033[33m" if enabled else ""
        self.cyan = "\033[36m" if enabled else ""

    def status(self, s: str) -> str:
        if not self.enabled:
            return s
        if s == "OK":
            return f"{self.green}{s}{self.reset}"
        if s == "FAIL":
            return f"{self.red}{s}{self.reset}"
        if s == "SKIP":
            return f"{self.yellow}{s}{self.reset}"
        return s

    def label(self, s: str) -> str:
        return f"{self.bold}{s}{self.reset}" if self.enabled else s


def now_ms() -> int:
    return int(time.time() * 1000)


def fmt_duration(ms: int) -> str:
    if ms <= 0:
        return "0ms"
    if ms < 1000:
        return f"{ms}ms"
    s = ms / 1000.0
    if s < 60:
        return f"{s:.3f}s"
    m = int(s // 60)
    rs = s - m * 60
    return f"{m}m{rs:05.2f}s"


def choose_default_build_dir() -> str:
    for d in ["build-stage2", "build", "build-stage1"]:
        if (REPO_ROOT / d / "dist" / "rocm").is_dir():
            return d
    return "build-stage2"


def activated_env(build_dir: str) -> dict[str, str]:
    rocm = REPO_ROOT / build_dir / "dist" / "rocm"
    env = os.environ.copy()
    env["ROCM_PATH"] = str(rocm)
    env.setdefault("HIP_PATH", str(rocm))
    env.setdefault("HSA_PATH", str(rocm))
    path = env.get("PATH", "")
    env["PATH"] = f"{rocm}/bin:{rocm}/llvm/bin:{path}"
    ld = env.get("LD_LIBRARY_PATH", "")
    env["LD_LIBRARY_PATH"] = (
        f"{rocm}/lib:{rocm}/lib64:{rocm}/lib/host-math/lib:{rocm}/lib/rocm_sysdeps/lib:{rocm}/llvm/lib:{ld}"
    )
    if "HIP_DEVICE_LIB_PATH" not in env:
        p1 = rocm / "lib" / "llvm" / "amdgcn" / "bitcode"
        p2 = rocm / "amdgcn" / "bitcode"
        env["HIP_DEVICE_LIB_PATH"] = str(p1 if p1.is_dir() else p2)
    return env


def run_cmd(
    env: dict[str, str],
    cmd: list[str],
    timeout_s: int | None,
    logf,
) -> tuple[int, str, str, int]:
    start = now_ms()
    proc = subprocess.Popen(
        cmd,
        cwd=str(REPO_ROOT),
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    try:
        out, err = proc.communicate(timeout=timeout_s)
        rc = proc.returncode
    except subprocess.TimeoutExpired:
        proc.kill()
        out, err = proc.communicate()
        rc = 124
    end = now_ms()
    if logf is not None:
        logf.write(f"$ {shlex.join(cmd)}\n")
        if out:
            logf.write(out)
            if not out.endswith("\n"):
                logf.write("\n")
        if err:
            logf.write(err)
            if not err.endswith("\n"):
                logf.write("\n")
        logf.write("\n")
        logf.flush()
    return rc, out, err, end - start


@dataclass(frozen=True)
class Check:
    idx: int
    name: str
    purpose: str
    expected: str
    timeout_s: int


def parse_select(s: str) -> list[int]:
    s = s.strip()
    if not s:
        return []
    s = s.replace(",", " ")
    out = []
    for part in s.split():
        if part.isdigit():
            out.append(int(part))
    return out


def extract_gflops(text: str) -> float | None:
    # rocblas-bench csv: ... rocblas-Gflops,us \n N,N,..., 11802.7, 1455.58
    m = re.search(r"([0-9]+(?:\.[0-9]+)?)\s*,\s*[0-9]+(?:\.[0-9]+)?\s*$", text.strip(), re.M)
    if m:
        try:
            return float(m.group(1))
        except ValueError:
            return None
    return None


def main() -> int:
    ap = argparse.ArgumentParser(description="Usability validation for in-tree ROCm (TheRock gfx1031).")
    ap.add_argument("--build-dir", default=None, help="Build directory to use (default: auto).")
    ap.add_argument("--select", default=None, help="Select checks by number (e.g. 1,2,3). 0 = all.")
    ap.add_argument("--log", default=None, help="Write full command output to this file.")
    ap.add_argument("--no-color", action="store_true", help="Disable ANSI color output.")
    args = ap.parse_args()

    build_dir = args.build_dir or choose_default_build_dir()
    env = activated_env(build_dir)
    rocm = Path(env["ROCM_PATH"])
    if not rocm.is_dir():
        print(f"ERROR: ROCM_PATH not found: {rocm}", file=sys.stderr)
        print(f"Hint: build first (expected: {REPO_ROOT/build_dir/'dist'/'rocm'}).", file=sys.stderr)
        return 2

    ansi = Ansi(enabled=is_tty() and not args.no_color and not bool(args.log))
    logf = open(args.log, "w", encoding="utf-8") if args.log else None

    checks = [
        Check(1, "Environment activation", "Verify in-tree ROCm prefix is usable", "typ. <50ms", 2),
        Check(2, "rocminfo", "Basic ROCr/runtime sanity", "typ. <1s", 10),
        Check(3, "hipcc compile+run", "Compile and run a tiny HIP kernel (vector add)", "typ. 1-5s", 60),
        Check(4, "rocBLAS GEMM", "Micro-benchmark (GEMM f32) + TFLOPS estimate", "typ. 1-2s", 60),
        Check(5, "rocFFT 1024", "Micro-benchmark (complex fwd FFT, single)", "typ. <1s", 30),
        Check(6, "rocRAND generate", "Micro-benchmark (philox, uniform-float)", "typ. <1s", 30),
        Check(7, "MIOpen driver", "MIOpen presence + driver invocation", "typ. <1s", 10),
        Check(8, "MIOpen smoke", "Tiny conv smoke (may JIT on first run)", "typ. 30-180s (cold)", 240),
        Check(9, "Third-party integrations (placeholder)", "Ollama/llama.cpp/Open Interpreter placeholders (no downloads)", "N/A", 1),
    ]

    selected = parse_select(args.select or "")
    if 0 in selected:
        selected = [c.idx for c in checks]
    if not selected and is_tty() and not args.select:
        # Interactive selection.
        print(f"{ansi.bold}Usability validation (in-tree ROCm){ansi.reset}")
        print(f"{ansi.dim}- build dir:{ansi.reset} {build_dir}")
        print(f"{ansi.dim}- ROCm:{ansi.reset} {rocm}")
        print(f"{ansi.dim}- logging:{ansi.reset} {args.log or 'disabled (use --log)'}")
        print("")
        while True:
            print("Select check number(s): 0=all, q=quit")
            for c in checks:
                print(f"  {c.idx}) {c.name} {ansi.dim}({c.expected}){ansi.reset}")
            sel = input("> ").strip()
            if sel.lower() in {"q", "quit", "exit"}:
                if logf:
                    logf.close()
                return 0
            s2 = parse_select(sel)
            if 0 in s2:
                selected = [c.idx for c in checks]
            else:
                selected = s2
            if selected:
                break
        print("")
    elif not selected:
        selected = [c.idx for c in checks]

    def add_result(name: str, status: str, dur: str, metric: str = ""):
        results.append((name, status, dur, metric))

    results: list[tuple[str, str, str, str]] = []

    print(f"{ansi.bold}gfx1031 usability validation{ansi.reset}")
    print(f"{ansi.dim}- build dir:{ansi.reset} {build_dir}")
    print(f"{ansi.dim}- ROCm:{ansi.reset} {rocm}")
    print(f"{ansi.dim}- will run:{ansi.reset} {', '.join(str(i) for i in selected)}")
    print("")

    for idx in selected:
        c = next((x for x in checks if x.idx == idx), None)
        if not c:
            continue
        print(f"{ansi.cyan}==>{ansi.reset} {ansi.label(c.name)} {ansi.dim}(expected: {c.expected}){ansi.reset}")
        if logf is not None:
            logf.write(f"==> {c.idx}) {c.name}\n")
            logf.write(f"purpose: {c.purpose}\nexpected: {c.expected}\n\n")
            logf.flush()

        if idx == 1:
            start = now_ms()
            # Verify key dirs exist.
            ok = (rocm / "bin").is_dir() and (rocm / "llvm" / "bin").is_dir()
            dur = fmt_duration(now_ms() - start)
            add_result(c.name, "OK" if ok else "FAIL", dur, f"ROCM_PATH={rocm}")
            continue

        if idx == 2:
            rc, out, err, dur_ms = run_cmd(env, ["rocminfo"], c.timeout_s, logf)
            if rc == 0:
                add_result(c.name, "OK", fmt_duration(dur_ms))
            else:
                add_result(c.name, "FAIL", fmt_duration(dur_ms), f"rc={rc}")
            continue

        if idx == 3:
            hipcc = shutil_which(env, "hipcc")
            if not hipcc:
                add_result(c.name, "SKIP", "0ms", "hipcc not in PATH")
                continue
            with tempfile.TemporaryDirectory(prefix="therock-hip-") as td:
                src = Path(td) / "vadd.cpp"
                exe = Path(td) / "vadd"
                src.write_text(
                    r"""
#include <hip/hip_runtime.h>
#include <cstdio>
#include <vector>

__global__ void vadd(const float* a, const float* b, float* c, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i < n) c[i] = a[i] + b[i];
}

int main() {
  int n = 1<<20;
  size_t bytes = n * sizeof(float);
  std::vector<float> ha(n, 1.0f), hb(n, 2.0f), hc(n, 0.0f);
  float *da=nullptr, *db=nullptr, *dc=nullptr;
  hipMalloc(&da, bytes);
  hipMalloc(&db, bytes);
  hipMalloc(&dc, bytes);
  hipMemcpy(da, ha.data(), bytes, hipMemcpyHostToDevice);
  hipMemcpy(db, hb.data(), bytes, hipMemcpyHostToDevice);
  int threads = 256;
  int blocks = (n + threads - 1) / threads;
  hipLaunchKernelGGL(vadd, dim3(blocks), dim3(threads), 0, 0, da, db, dc, n);
  hipDeviceSynchronize();
  hipMemcpy(hc.data(), dc, bytes, hipMemcpyDeviceToHost);
  hipFree(da); hipFree(db); hipFree(dc);
  // Verify a few values.
  for (int i = 0; i < 10; i++) {
    if (hc[i] != 3.0f) { std::printf("FAIL %d %f\n", i, hc[i]); return 1; }
  }
  std::printf("OK\n");
  return 0;
}
""".lstrip(),
                    encoding="utf-8",
                )
                cmd = [hipcc, "--offload-arch=gfx1031", str(src), "-O2", "-o", str(exe)]
                rc1, _, _, dur1 = run_cmd(env, cmd, 120, logf)
                if rc1 != 0:
                    add_result(c.name, "FAIL", fmt_duration(dur1), f"compile rc={rc1}")
                    continue
                rc2, out2, _, dur2 = run_cmd(env, [str(exe)], 60, logf)
                if rc2 == 0 and "OK" in out2:
                    add_result(c.name, "OK", fmt_duration(dur1 + dur2))
                else:
                    add_result(c.name, "FAIL", fmt_duration(dur1 + dur2), f"run rc={rc2}")
            continue

        if idx == 4:
            if not shutil_which(env, "rocblas-bench"):
                add_result(c.name, "SKIP", "0ms", "rocblas-bench not in PATH")
                continue
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
            rc, out, err, dur_ms = run_cmd(env, cmd, c.timeout_s, logf)
            if rc != 0:
                add_result(c.name, "FAIL", fmt_duration(dur_ms), f"rc={rc}")
                continue
            gflops = extract_gflops(out + "\n" + err)
            metric = ""
            if gflops is not None:
                metric = f"TFLOPS={gflops/1000.0:.3f} (GFLOPS={gflops:.1f})"
            add_result(c.name, "OK", fmt_duration(dur_ms), metric)
            continue

        if idx == 5:
            if not shutil_which(env, "rocfft-bench"):
                add_result(c.name, "SKIP", "0ms", "rocfft-bench not in PATH")
                continue
            cmd = ["rocfft-bench", "--length", "1024", "--precision", "single", "-t", "0", "-N", "2"]
            rc, out, err, dur_ms = run_cmd(env, cmd, c.timeout_s, logf)
            if rc != 0:
                add_result(c.name, "FAIL", fmt_duration(dur_ms), f"rc={rc}")
                continue
            m = re.search(r"Execution gpu time:\s*([0-9.]+)", out)
            metric = f"ms={m.group(1)}" if m else ""
            add_result(c.name, "OK", fmt_duration(dur_ms), metric)
            continue

        if idx == 6:
            if not shutil_which(env, "benchmark_rocrand_generate"):
                add_result(c.name, "SKIP", "0ms", "benchmark_rocrand_generate not in PATH")
                continue
            cmd = [
                "benchmark_rocrand_generate",
                "--size",
                "1048576",
                "--trials",
                "2",
                "--dis",
                "uniform-float",
                "--engine",
                "philox",
                "--format",
                "csv",
            ]
            rc, out, err, dur_ms = run_cmd(env, cmd, c.timeout_s, logf)
            if rc != 0:
                add_result(c.name, "FAIL", fmt_duration(dur_ms), f"rc={rc}")
                continue
            m = re.search(r",([0-9.]+),([0-9.]+),([0-9.]+),", out)
            metric = ""
            if m:
                metric = f"GB/s={m.group(1)} (GSample/s={m.group(2)}) (ms={m.group(3)})"
            add_result(c.name, "OK", fmt_duration(dur_ms), metric)
            continue

        if idx == 7:
            if not shutil_which(env, "MIOpenDriver") and not shutil_which(env, "miopen-driver"):
                add_result(c.name, "SKIP", "0ms", "MIOpenDriver/miopen-driver not in PATH")
                continue
            drv = "MIOpenDriver" if shutil_which(env, "MIOpenDriver") else "miopen-driver"
            rc, out, err, dur_ms = run_cmd(env, [drv, "--version"], c.timeout_s, logf)
            add_result(c.name, "OK" if rc == 0 else "FAIL", fmt_duration(dur_ms), f"driver={drv}")
            continue

        if idx == 8:
            if not shutil_which(env, "MIOpenDriver") and not shutil_which(env, "miopen-driver"):
                add_result(c.name, "SKIP", "0ms", "MIOpenDriver/miopen-driver not in PATH")
                continue
            drv = "MIOpenDriver" if shutil_which(env, "MIOpenDriver") else "miopen-driver"
            cmd = [drv, "conv", "-n", "1", "-c", "1", "-H", "8", "-W", "8", "-k", "1", "-y", "3", "-x", "3", "-p", "1", "-q", "1"]
            rc, _, _, dur_ms = run_cmd(env, cmd, c.timeout_s, logf)
            add_result(c.name, "OK" if rc == 0 else "FAIL", fmt_duration(dur_ms), f"driver={drv}")
            continue

        if idx == 9:
            add_result(c.name, "SKIP", "0ms", "placeholders only (no downloads)")
            continue

    print("")
    print("==== validation summary ====")
    for i, (name, status, dur, metric) in enumerate(results, start=1):
        line = f"- {i:02d}) {ansi.label(name):<28} {ansi.status(status)} {ansi.dim}({dur}){ansi.reset}"
        if metric:
            line += f" {metric}"
        print(line)
    if args.log:
        print(f"{ansi.dim}Log:{ansi.reset} {args.log}")
        logf.close()
    else:
        print(f"{ansi.dim}Log:{ansi.reset} disabled (use --log file)")

    return 0 if all(s != "FAIL" for _, s, _, _ in results) else 1


def shutil_which(env: dict[str, str], exe: str) -> str | None:
    path = env.get("PATH", "")
    for p in path.split(":"):
        candidate = Path(p) / exe
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)
    return None


if __name__ == "__main__":
    raise SystemExit(main())

