from __future__ import annotations

import os
import re
import subprocess
import tarfile
from dataclasses import dataclass
from pathlib import Path

from ..third_party import CACHE_DIR, DownloadItem, download, ensure_venv, pip_install, venv_bin
from ..utils import CommandResult, fmt_duration, run_cmd, which
from .base import CheckResult
from .rocm_sanity import Context


def _enabled(ctx: Context) -> bool:
    return bool(ctx.allow_downloads)


@dataclass(frozen=True)
class CheckThirdPartyPlan:
    idx: int = 9
    name: str = "Third-party plan"
    purpose: str = "Print what will be installed/downloaded for third-party validations"
    expected: str = "typ. <1s"
    timeout_s: int = 2

    def run(self, ctx: Context) -> CheckResult:
        if not _enabled(ctx):
            return CheckResult(self.name, "SKIP", "0ms", "downloads disabled")
        items = [
            DownloadItem("llama.cpp (docker image)", "Pull + run container (GPU pass-through)", None),
            DownloadItem("Ollama (binary)", "Download user-space binary", 200_000_000),
            DownloadItem("Open Interpreter (pip)", "Install into validation venv", None),
            DownloadItem("Whisper (pip + model)", "Install openai-whisper + small model", 1_500_000_000),
            DownloadItem("MFEM (git + build)", "Clone + HIP build + run example", 500_000_000),
        ]
        metric = "; ".join(f"{i.name}≈{i.approx_str()}" for i in items)
        return CheckResult(self.name, "OK", "0ms", metric)


@dataclass(frozen=True)
class CheckLlamaCppDocker:
    idx: int = 10
    name: str = "llama.cpp (docker) smoke"
    purpose: str = "Pull and run llama.cpp ROCm Docker image (smoke only)"
    expected: str = "typ. minutes (pull) / <5s (run)"
    timeout_s: int = 900

    def run(self, ctx: Context) -> CheckResult:
        if not _enabled(ctx):
            return CheckResult(self.name, "SKIP", "0ms", "downloads disabled")
        if which("docker", ctx.env) is None:
            return CheckResult(self.name, "SKIP", "0ms", "docker not installed or not in PATH")

        # Fetch AMD doc and heuristically extract the first "docker pull <image>".
        url = "https://rocm.docs.amd.com/projects/install-on-linux/en/latest/install/3rd-party/llama-cpp-install.html"
        r = run_cmd(ctx.env, ["bash", "-lc", f"curl -fsSL {url!s}"], 30, ctx.logf)
        if r.rc != 0:
            return CheckResult(self.name, "FAIL", fmt_duration(r.dur_ms), f"failed to fetch doc rc={r.rc}")
        # The HTML contains "docker<span> </span>pull", so don't match on the literal command.
        # Instead, prefer a concrete published tag from the "Docker image support" section.
        m = re.search(r"rocm/llama\\.cpp:([a-zA-Z0-9._-]+_server)", r.out)
        if not m:
            m = re.search(r"rocm/llama\\.cpp:([a-zA-Z0-9._-]+_full)", r.out)
        if not m:
            return CheckResult(self.name, "FAIL", fmt_duration(r.dur_ms), "could not find a rocm/llama.cpp:<tag> in docs HTML")
        image = f"rocm/llama.cpp:{m.group(1)}"

        # Pull (may take a while).
        rp = run_cmd(ctx.env, ["docker", "pull", image], self.timeout_s, ctx.logf)
        if rp.rc != 0:
            return CheckResult(self.name, "FAIL", fmt_duration(rp.dur_ms), f"docker pull failed rc={rp.rc}")

        # Basic smoke: run help inside container. (No model downloads here.)
        rr = run_cmd(ctx.env, ["docker", "run", "--rm", image, "--help"], 60, ctx.logf)
        status = "OK" if rr.rc == 0 else "FAIL"
        metric = f"image={image}"
        return CheckResult(self.name, status, fmt_duration(rp.dur_ms + rr.dur_ms), metric)


@dataclass(frozen=True)
class CheckOllama:
    idx: int = 11
    name: str = "Ollama (local binary) smoke"
    purpose: str = "Ensure an Ollama binary can run without /opt installs"
    expected: str = "typ. <10s (download) / <1s (version)"
    timeout_s: int = 120

    def run(self, ctx: Context) -> CheckResult:
        if not _enabled(ctx):
            return CheckResult(self.name, "SKIP", "0ms", "downloads disabled")

        exe = which("ollama", ctx.env)
        if exe is None:
            # User-space download (official tgz points to latest GitHub release).
            # This avoids `sudo` and keeps everything under validation/_cache.
            tgz = CACHE_DIR / "ollama" / "ollama-linux-amd64.tgz"
            root = CACHE_DIR / "ollama" / "root"
            bin_path = root / "bin" / "ollama"
            if not bin_path.exists():
                url = "https://ollama.com/download/ollama-linux-amd64.tgz"
                try:
                    download(url, tgz)
                    if root.exists():
                        subprocess.check_call(["rm", "-rf", str(root)])
                    root.mkdir(parents=True, exist_ok=True)
                    with tarfile.open(tgz, "r:gz") as tf:
                        tf.extractall(path=root)
                    # Some bundles place `ollama` at the top-level; normalize.
                    if (root / "ollama").exists() and not bin_path.exists():
                        (root / "bin").mkdir(parents=True, exist_ok=True)
                        (root / "ollama").rename(bin_path)
                    bin_path.chmod(0o755)
                except Exception as e:
                    return CheckResult(self.name, "FAIL", "0ms", f"download/extract failed: {e}")
            exe = str(bin_path)

        r = run_cmd(ctx.env, [exe, "--version"], 20, ctx.logf)
        if r.rc != 0:
            return CheckResult(self.name, "FAIL", fmt_duration(r.dur_ms), f"rc={r.rc}")
        return CheckResult(self.name, "OK", fmt_duration(r.dur_ms), "ollama --version")


@dataclass(frozen=True)
class CheckOpenInterpreter:
    idx: int = 12
    name: str = "Open Interpreter (pip) smoke"
    purpose: str = "Install and invoke Open Interpreter CLI (no model/chat)"
    expected: str = "typ. minutes (pip) / <2s (help)"
    timeout_s: int = 900

    def run(self, ctx: Context) -> CheckResult:
        if not _enabled(ctx):
            return CheckResult(self.name, "SKIP", "0ms", "downloads disabled")

        try:
            vpy = ensure_venv()
            pip_install(vpy, ["open-interpreter"])
            interp = venv_bin(vpy, "interpreter")
        except Exception as e:
            return CheckResult(self.name, "FAIL", "0ms", f"pip install failed: {e}")

        r = run_cmd(ctx.env, [str(interp), "--help"], 20, ctx.logf)
        status = "OK" if r.rc == 0 else "FAIL"
        return CheckResult(self.name, status, fmt_duration(r.dur_ms), "interpreter --help")


@dataclass(frozen=True)
class CheckWhisper:
    idx: int = 13
    name: str = "Whisper (pip) smoke"
    purpose: str = "Install openai-whisper and run a tiny transcription smoke"
    expected: str = "typ. minutes (pip/model) / <30s (run)"
    timeout_s: int = 1800

    def run(self, ctx: Context) -> CheckResult:
        if not _enabled(ctx):
            return CheckResult(self.name, "SKIP", "0ms", "downloads disabled")
        try:
            vpy = ensure_venv()
            # Torch wheels can be large; we try but will accept CPU-only installs.
            pip_install(vpy, ["torch", "openai-whisper"])
        except Exception as e:
            return CheckResult(self.name, "FAIL", "0ms", f"pip install failed: {e}")

        script = r"""
import os, wave, struct, math, time
import torch
import whisper

print("torch", torch.__version__)
print("torch.cuda.is_available", torch.cuda.is_available())
print("torch.version.hip", getattr(torch.version, "hip", None))

# Generate a tiny sine wave WAV (no ffmpeg needed)
sr=16000
dur=1.0
freq=440.0
n=int(sr*dur)
fname="validation/_cache/whisper_test.wav"
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
        r = run_cmd(ctx.env, [str(ensure_venv()), "-c", script], self.timeout_s, ctx.logf)
        if r.rc != 0:
            return CheckResult(self.name, "FAIL", fmt_duration(r.dur_ms), f"rc={r.rc}")
        # If ROCm isn't active, still report OK but mention CPU-only in metric.
        metric = "ran tiny.en transcribe"
        if "torch.version.hip None" in (r.out + r.err) and "torch.cuda.is_available False" in (r.out + r.err):
            metric += " (CPU torch; ROCm not detected)"
        return CheckResult(self.name, "OK", fmt_duration(r.dur_ms), metric)


@dataclass(frozen=True)
class CheckMFEM:
    idx: int = 14
    name: str = "MFEM (HIP) build+run smoke"
    purpose: str = "Clone MFEM, configure HIP build, compile and run a small example"
    expected: str = "typ. minutes (clone/build) / <5s (run)"
    timeout_s: int = 3600

    def run(self, ctx: Context) -> CheckResult:
        if not _enabled(ctx):
            return CheckResult(self.name, "SKIP", "0ms", "downloads disabled")

        if which("cmake", ctx.env) is None or which("ninja", ctx.env) is None:
            return CheckResult(self.name, "SKIP", "0ms", "missing cmake/ninja (install system packages)")
        if which("hipcc", ctx.env) is None:
            return CheckResult(self.name, "SKIP", "0ms", "hipcc not in PATH (build Stage-2 first)")

        src = CACHE_DIR / "mfem" / "src"
        bld = CACHE_DIR / "mfem" / "build"
        src.parent.mkdir(parents=True, exist_ok=True)
        if not src.exists():
            r0 = run_cmd(ctx.env, ["git", "clone", "--depth", "1", "https://github.com/mfem/mfem.git", str(src)], 900, ctx.logf)
            if r0.rc != 0:
                return CheckResult(self.name, "FAIL", fmt_duration(r0.dur_ms), f"git clone rc={r0.rc}")

        bld.mkdir(parents=True, exist_ok=True)
        hipcc = which("hipcc", ctx.env) or "hipcc"
        clangxx = str(Path(ctx.env["ROCM_PATH"]) / "llvm" / "bin" / "clang++")
        cfg = run_cmd(
            ctx.env,
            [
                "cmake",
                "-S",
                str(src),
                "-B",
                str(bld),
                "-G",
                "Ninja",
                "-DMFEM_USE_HIP=YES",
                "-DHIP_ARCH=gfx1031",
                f"-DCMAKE_CXX_COMPILER={clangxx}",
                f"-DCMAKE_HIP_COMPILER={hipcc}",
                "-DMFEM_USE_MPI=NO",
            ],
            900,
            ctx.logf,
        )
        if cfg.rc != 0:
            return CheckResult(self.name, "FAIL", fmt_duration(cfg.dur_ms), f"cmake rc={cfg.rc}")

        b = run_cmd(ctx.env, ["ninja", "-C", str(bld), "-j", "4"], self.timeout_s, ctx.logf)
        if b.rc != 0:
            return CheckResult(self.name, "FAIL", fmt_duration(cfg.dur_ms + b.dur_ms), f"build rc={b.rc}")

        ex1 = bld / "examples" / "ex1"
        if not ex1.exists():
            return CheckResult(self.name, "FAIL", fmt_duration(cfg.dur_ms + b.dur_ms), "ex1 not built")
        rrun = run_cmd(ctx.env, [str(ex1), "-m", str(src / "data" / "star.mesh")], 60, ctx.logf)
        status = "OK" if rrun.rc == 0 else "FAIL"
        return CheckResult(self.name, status, fmt_duration(cfg.dur_ms + b.dur_ms + rrun.dur_ms), "mfem ex1")
