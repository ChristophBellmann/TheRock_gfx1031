from __future__ import annotations

import tempfile
from dataclasses import dataclass
from pathlib import Path

from ..utils import CommandResult, extract_gflops, fmt_duration, run_cmd, which
from .base import CheckResult


@dataclass
class Context:
    env: dict[str, str]
    build_dir: str
    rocm_path: Path
    logf: object | None
    allow_downloads: bool


@dataclass(frozen=True)
class CheckEnvironmentActivation:
    idx: int = 1
    name: str = "Environment activation"
    purpose: str = "Verify in-tree ROCm prefix is usable"
    expected: str = "typ. <50ms"
    timeout_s: int = 2

    def run(self, ctx: Context) -> CheckResult:
        ok = (ctx.rocm_path / "bin").is_dir() and (ctx.rocm_path / "llvm" / "bin").is_dir()
        return CheckResult(
            name=self.name,
            status="OK" if ok else "FAIL",
            duration="0ms",
            metric=f"ROCM_PATH={ctx.rocm_path}",
        )


@dataclass(frozen=True)
class CheckRocMinInfo:
    idx: int = 2
    name: str = "rocminfo"
    purpose: str = "Basic ROCr/runtime sanity"
    expected: str = "typ. <1s"
    timeout_s: int = 10

    def run(self, ctx: Context) -> CheckResult:
        r: CommandResult = run_cmd(ctx.env, ["rocminfo"], self.timeout_s, ctx.logf)
        return CheckResult(
            name=self.name,
            status="OK" if r.rc == 0 else "FAIL",
            duration=fmt_duration(r.dur_ms),
            metric="" if r.rc == 0 else f"rc={r.rc}",
        )


@dataclass(frozen=True)
class CheckHipccCompileRun:
    idx: int = 3
    name: str = "hipcc compile+run"
    purpose: str = "Compile and run a tiny HIP kernel (vector add)"
    expected: str = "typ. 1-5s"
    timeout_s: int = 120

    def run(self, ctx: Context) -> CheckResult:
        hipcc = which("hipcc", ctx.env)
        if not hipcc:
            return CheckResult(self.name, "SKIP", "0ms", "hipcc not in PATH")

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
  for (int i = 0; i < 10; i++) {
    if (hc[i] != 3.0f) { std::printf("FAIL %d %f\n", i, hc[i]); return 1; }
  }
  std::printf("OK\n");
  return 0;
}
""".lstrip(),
                encoding="utf-8",
            )

            r1 = run_cmd(
                ctx.env,
                [hipcc, "--offload-arch=gfx1031", str(src), "-O2", "-o", str(exe)],
                self.timeout_s,
                ctx.logf,
            )
            if r1.rc != 0:
                return CheckResult(self.name, "FAIL", fmt_duration(r1.dur_ms), f"compile rc={r1.rc}")

            r2 = run_cmd(ctx.env, [str(exe)], 60, ctx.logf)
            status = "OK" if r2.rc == 0 and "OK" in (r2.out + r2.err) else "FAIL"
            metric = "" if status == "OK" else f"run rc={r2.rc}"
            return CheckResult(self.name, status, fmt_duration(r1.dur_ms + r2.dur_ms), metric)


@dataclass(frozen=True)
class CheckRocBLASGemm:
    idx: int = 4
    name: str = "rocBLAS GEMM"
    purpose: str = "Micro-benchmark (GEMM f32) + TFLOPS estimate"
    expected: str = "typ. 1-2s"
    timeout_s: int = 60

    def run(self, ctx: Context) -> CheckResult:
        if not which("rocblas-bench", ctx.env):
            return CheckResult(self.name, "SKIP", "0ms", "rocblas-bench not in PATH")
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
        r = run_cmd(ctx.env, cmd, self.timeout_s, ctx.logf)
        if r.rc != 0:
            return CheckResult(self.name, "FAIL", fmt_duration(r.dur_ms), f"rc={r.rc}")
        gflops = extract_gflops(r.out + "\n" + r.err)
        metric = ""
        if gflops is not None:
            metric = f"TFLOPS={gflops/1000.0:.3f} (GFLOPS={gflops:.1f})"
        return CheckResult(self.name, "OK", fmt_duration(r.dur_ms), metric)


@dataclass(frozen=True)
class CheckRocFFT1024:
    idx: int = 5
    name: str = "rocFFT 1024"
    purpose: str = "Micro-benchmark (complex fwd FFT, single)"
    expected: str = "typ. <1s"
    timeout_s: int = 30

    def run(self, ctx: Context) -> CheckResult:
        if not which("rocfft-bench", ctx.env):
            return CheckResult(self.name, "SKIP", "0ms", "rocfft-bench not in PATH")
        r = run_cmd(ctx.env, ["rocfft-bench", "--length", "1024", "--precision", "single", "-t", "0", "-N", "2"], self.timeout_s, ctx.logf)
        if r.rc != 0:
            return CheckResult(self.name, "FAIL", fmt_duration(r.dur_ms), f"rc={r.rc}")
        metric = ""
        for line in (r.out + "\n" + r.err).splitlines():
            if "Execution gpu time:" in line:
                parts = line.strip().split()
                if len(parts) >= 4:
                    metric = f"ms={parts[3]}"
                break
        return CheckResult(self.name, "OK", fmt_duration(r.dur_ms), metric)


@dataclass(frozen=True)
class CheckRocRandGenerate:
    idx: int = 6
    name: str = "rocRAND generate"
    purpose: str = "Micro-benchmark (philox, uniform-float)"
    expected: str = "typ. <1s"
    timeout_s: int = 30

    def run(self, ctx: Context) -> CheckResult:
        if not which("benchmark_rocrand_generate", ctx.env):
            return CheckResult(self.name, "SKIP", "0ms", "benchmark_rocrand_generate not in PATH")
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
        r = run_cmd(ctx.env, cmd, self.timeout_s, ctx.logf)
        if r.rc != 0:
            return CheckResult(self.name, "FAIL", fmt_duration(r.dur_ms), f"rc={r.rc}")
        metric = ""
        for line in (r.out + "\n" + r.err).splitlines():
            if line.startswith("philox,"):
                parts = line.split(",")
                if len(parts) >= 6:
                    metric = f"GB/s={parts[2]} (GSample/s={parts[3]}) (ms={parts[4]})"
                break
        return CheckResult(self.name, "OK", fmt_duration(r.dur_ms), metric)


@dataclass(frozen=True)
class CheckMIOpenDriver:
    idx: int = 7
    name: str = "MIOpen driver"
    purpose: str = "MIOpen presence + driver invocation"
    expected: str = "typ. <1s"
    timeout_s: int = 10

    def run(self, ctx: Context) -> CheckResult:
        drv = which("MIOpenDriver", ctx.env) or which("miopen-driver", ctx.env)
        if not drv:
            return CheckResult(self.name, "SKIP", "0ms", "MIOpenDriver/miopen-driver not in PATH")
        r = run_cmd(ctx.env, [drv, "--version"], self.timeout_s, ctx.logf)
        return CheckResult(self.name, "OK" if r.rc == 0 else "FAIL", fmt_duration(r.dur_ms), f"driver={Path(drv).name}")


@dataclass(frozen=True)
class CheckMIOpenSmoke:
    idx: int = 8
    name: str = "MIOpen smoke"
    purpose: str = "Tiny conv smoke (may JIT on first run)"
    expected: str = "typ. 30-180s (cold)"
    timeout_s: int = 240

    def run(self, ctx: Context) -> CheckResult:
        drv = which("MIOpenDriver", ctx.env) or which("miopen-driver", ctx.env)
        if not drv:
            return CheckResult(self.name, "SKIP", "0ms", "MIOpenDriver/miopen-driver not in PATH")
        cmd = [drv, "conv", "-n", "1", "-c", "1", "-H", "8", "-W", "8", "-k", "1", "-y", "3", "-x", "3", "-p", "1", "-q", "1"]
        r = run_cmd(ctx.env, cmd, self.timeout_s, ctx.logf)
        return CheckResult(self.name, "OK" if r.rc == 0 else "FAIL", fmt_duration(r.dur_ms), f"driver={Path(drv).name}")


@dataclass(frozen=True)
class CheckThirdPartyPlaceholders:
    idx: int = 9
    name: str = "Third-party integrations"
    purpose: str = "Ollama/llama.cpp/Open Interpreter/Whisper/MFEM plan (placeholder)"
    expected: str = "N/A"
    timeout_s: int = 1

    def run(self, ctx: Context) -> CheckResult:
        # Implemented in later iteration; keep as a stable slot.
        return CheckResult(self.name, "SKIP", "0ms", "placeholders only (no downloads implemented yet)")

