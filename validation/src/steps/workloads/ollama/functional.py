from __future__ import annotations

import json
import os
import socket
import subprocess
import time
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from core.context import Context
from core.power import PowerSampler
from core.reporting.models import StepResult
from core.runner import fmt_duration, run_cmd
from steps.workloads.ollama.setup import ensure_ollama
from steps.shared import append_power, baseline_avg_w, read_small_text, with_power_sampler


@dataclass(frozen=True)
class GenerateMetrics:
    load_s: float | None
    prompt_eval_s: float | None
    prompt_tokens: int | None
    eval_s: float | None
    eval_tokens: int | None
    total_s: float | None

    @property
    def tok_per_s(self) -> float | None:
        if self.eval_s and self.eval_tokens is not None and self.eval_s > 0:
            return float(self.eval_tokens) / float(self.eval_s)
        return None

    @property
    def prompt_tok_per_s(self) -> float | None:
        if self.prompt_eval_s and self.prompt_tokens is not None and self.prompt_eval_s > 0:
            return float(self.prompt_tokens) / float(self.prompt_eval_s)
        return None


def _post_json(url: str, payload: dict[str, Any], *, timeout_s: int) -> dict[str, Any]:
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout_s) as r:
        return json.loads(r.read().decode("utf-8", errors="replace"))


def _get_json(url: str, *, timeout_s: int) -> dict[str, Any] | None:
    try:
        with urllib.request.urlopen(url, timeout=timeout_s) as r:
            return json.loads(r.read().decode("utf-8", errors="replace"))
    except Exception:
        return None


def _measure_ttft_ms(url: str, payload: dict[str, Any], *, timeout_s: int) -> float | None:
    """
    Approx time-to-first-token by streaming and measuring when the first non-empty "response" arrives.
    """
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
    t0 = time.monotonic()
    try:
        with urllib.request.urlopen(req, timeout=timeout_s) as r:
            for raw in r:
                if not raw:
                    continue
                try:
                    obj = json.loads(raw.decode("utf-8", errors="replace"))
                except Exception:
                    continue
                if obj.get("response"):
                    return (time.monotonic() - t0) * 1000.0
    except Exception:
        return None
    return None


def _parse_generate_metrics(resp: dict[str, Any]) -> GenerateMetrics:
    def ns_to_s(v: Any) -> float | None:
        try:
            if v is None:
                return None
            return float(v) / 1e9
        except Exception:
            return None

    def as_int(v: Any) -> int | None:
        try:
            return int(v) if v is not None else None
        except Exception:
            return None

    return GenerateMetrics(
        load_s=ns_to_s(resp.get("load_duration")),
        prompt_eval_s=ns_to_s(resp.get("prompt_eval_duration")),
        prompt_tokens=as_int(resp.get("prompt_eval_count")),
        eval_s=ns_to_s(resp.get("eval_duration")),
        eval_tokens=as_int(resp.get("eval_count")),
        total_s=ns_to_s(resp.get("total_duration")),
    )


def _find_free_port() -> int:
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        s.bind(("127.0.0.1", 0))
        return int(s.getsockname()[1])
    finally:
        s.close()


def _has_rocm_backend(exe: str) -> bool:
    """
    Best-effort heuristic: the official linux tarball typically ships CPU + CUDA/Vulkan backends.
    If no ROCm backend is present, we prefer docker.
    """
    try:
        root = Path(exe).resolve().parents[1]  # .../root/bin/ollama -> .../root
        libdir = root / "lib" / "ollama"
        if not libdir.is_dir():
            return False
        for p in libdir.rglob("*"):
            s = p.name.lower()
            if "rocm" in s or "hip" in s or "rocr" in s:
                return True
        return False
    except Exception:
        return False


def _write_log_line(log: Path | None, line: str) -> None:
    if log is None:
        return
    log.parent.mkdir(parents=True, exist_ok=True)
    with log.open("a", encoding="utf-8") as f:
        f.write(line.rstrip() + "\n")


def _docker_run_ollama(
    ctx: Context,
    cfg: dict[str, Any],
    build_dir: str,
    env: dict[str, str],
    log: Path | None,
    *,
    model: str,
    prompt: str,
    prompt_name: str,
) -> StepResult:
    image = str(cfg.get("workloads", {}).get("ollama", {}).get("docker_image", "ollama/ollama:rocm")).strip() or "ollama/ollama:rocm"
    tpull = int(cfg.get("timeouts_s", {}).get("ollama_pull", 1800))
    trun = int(cfg.get("timeouts_s", {}).get("ollama_run", 600))
    num_predict = int(cfg.get("workloads", {}).get("ollama", {}).get("num_predict", 128) or 128)
    min_bench_s = float(cfg.get("workloads", {}).get("ollama", {}).get("min_bench_s", 5.0) or 5.0)

    port = _find_free_port()
    name = f"rocm_validation_ollama_{os.getpid()}_{port}"
    models_dir = ctx.cache_dir() / "ollama" / "models"
    models_dir.mkdir(parents=True, exist_ok=True)

    # Some prebuilt ROCm binaries (including ggml HIP code objects) are built for gfx1030,
    # which can crash on gfx1031 unless we spoof the gfx version.
    arch = str(cfg.get("rocm", {}).get("amd_gpu_arch", "")).strip()
    hsa_override = "10.3.0" if arch == "gfx1031" else ""

    rpi = run_cmd(ctx.repo_root, env, ["docker", "pull", image], 1800, log)
    if rpi.rc != 0:
        return StepResult(build_dir, "Ollama (docker ROCm) bench", "FAIL", fmt_duration(rpi.dur_ms), f"docker pull rc={rpi.rc}")

    rr = run_cmd(
        ctx.repo_root,
        env,
        [
            "docker",
            "run",
            "-d",
            "--rm",
            "--name",
            name,
            "-p",
            f"127.0.0.1:{port}:11434",
            "--device=/dev/kfd",
            "--device=/dev/dri",
            "-e",
            "OLLAMA_LLM_LIBRARY=rocm",
            "-e",
            "OLLAMA_LIBRARY_PATH=/usr/lib/ollama",
            *([] if not hsa_override else ["-e", f"HSA_OVERRIDE_GFX_VERSION={hsa_override}"]),
            *([] if log is None else ["-e", "OLLAMA_DEBUG=1"]),
            "-v",
            f"{models_dir}:/root/.ollama/models",
            image,
        ],
        120,
        log,
    )
    if rr.rc != 0:
        return StepResult(build_dir, "Ollama (docker ROCm) bench", "FAIL", fmt_duration(rpi.dur_ms + rr.dur_ms), f"docker run rc={rr.rc}")

    base = f"http://127.0.0.1:{port}"
    try:
        t0 = time.monotonic()
        while time.monotonic() - t0 < 30.0:
            v = _get_json(f"{base}/api/version", timeout_s=2)
            if v and v.get("version"):
                break
            time.sleep(0.5)

        rp = run_cmd(ctx.repo_root, env, ["docker", "exec", name, "ollama", "pull", model], tpull, log)
        if rp.rc != 0:
            return StepResult(build_dir, "Ollama (docker ROCm) bench", "FAIL", fmt_duration(rpi.dur_ms + rr.dur_ms + rp.dur_ms), f"ollama pull rc={rp.rc}")

        gen_url = f"{base}/api/generate"
        # Warm-up to ensure model is loaded and the subsequent benchmark run reflects steady-state.
        warm_payload = {"model": model, "prompt": "Hello", "stream": False, "options": {"num_predict": 8, "temperature": 0}}
        _ = _post_json(gen_url, warm_payload, timeout_s=min(120, trun))

        payload = {"model": model, "prompt": prompt, "stream": False, "options": {"num_predict": num_predict, "temperature": 0}}

        # Measure TTFT with a short streaming run (not included in benchmark sampler window).
        ttft_ms = _measure_ttft_ms(
            gen_url,
            {"model": model, "prompt": prompt, "stream": True, "options": {"num_predict": min(16, num_predict), "temperature": 0}},
            timeout_s=min(60, trun),
        )

        def run_bench(sampler: PowerSampler | None):
            t1 = time.monotonic()
            eval_s_total = 0.0
            eval_tok_total = 0
            prompt_eval_s_total = 0.0
            prompt_tok_total = 0
            load_s_total = 0.0
            runs = 0

            # Keep a sustained load for (at least) min_bench_s wall time so power sampling is meaningful.
            while (time.monotonic() - t1) < min_bench_s and runs < 50:
                resp_i = _post_json(gen_url, payload, timeout_s=trun)
                mi = _parse_generate_metrics(resp_i)
                runs += 1
                # Sum API durations when present (used for reporting); wall time is measured independently above.
                load_s_total += float(mi.load_s or 0.0)
                prompt_eval_s_total += float(mi.prompt_eval_s or 0.0)
                prompt_tok_total += int(mi.prompt_tokens or 0)
                eval_s_total += float(mi.eval_s or 0.0)
                eval_tok_total += int(mi.eval_tokens or 0)

            wall_real = time.monotonic() - t1
            return (
                {
                    "runs": runs,
                    "wall_s": wall_real,
                    "load_s": load_s_total,
                    "prompt_eval_s": prompt_eval_s_total,
                    "prompt_tokens": prompt_tok_total,
                    "eval_s": eval_s_total,
                    "eval_tokens": eval_tok_total,
                },
                sampler,
            )

        bench, sampler = with_power_sampler(cfg, build_dir=build_dir, fn=run_bench)
        wall_s = float(bench["wall_s"])
        eval_s = float(bench["eval_s"])
        eval_tokens = int(bench["eval_tokens"])
        prompt_eval_s = float(bench["prompt_eval_s"])
        prompt_tokens = int(bench["prompt_tokens"])
        load_s = float(bench["load_s"])
        runs = int(bench["runs"])

        # Inspect container logs for backend + VRAM hints.
        rlog_now = run_cmd(ctx.repo_root, env, ["docker", "logs", name], 20, None)
        logs_text = (rlog_now.out + "\n" + rlog_now.err)
        backend = "unknown"
        if "inference compute\" id=cpu" in logs_text or "library=cpu" in logs_text:
            backend = "cpu"
        elif "libdir=/usr/lib/ollama/rocm" in logs_text or "library=ROCm" in logs_text:
            backend = "rocm"
        vram = None
        for ln in logs_text.splitlines():
            if "runner.vram=" in ln:
                vram = ln.split("runner.vram=", 1)[-1].strip().split()[0].strip('"')
                break

        tokps = (float(eval_tokens) / float(eval_s)) if eval_s > 0 else None
        ptokps = (float(prompt_tokens) / float(prompt_eval_s)) if prompt_eval_s > 0 else None
        avg_tok_ms = (1000.0 / tokps) if tokps and tokps > 0 else None

        metric = f"backend={backend} model={model} out={num_predict} runs={runs}"
        if tokps is not None:
            metric += f" tok/s={tokps:.2f}"
        if ptokps is not None:
            metric += f" prompt_tok/s={ptokps:.2f}"
        if ttft_ms is not None:
            metric += f" ttft={ttft_ms:.0f}ms"
        if avg_tok_ms is not None:
            metric += f" avg_tok={avg_tok_ms:.1f}ms"
        metric += f" load={load_s:.2f}s prompt_eval={prompt_eval_s:.2f}s eval={eval_s:.2f}s"
        if vram:
            metric += f" vram={vram}"
        metric += f" wall={wall_s:.2f}s prompt={prompt_name}"

        baseline_w = baseline_avg_w(cfg, build_dir)
        metric = append_power(metric, sampler, baseline_w=baseline_w)

        # Hard requirement for this bench: must be on ROCm backend.
        if backend != "rocm":
            hint = ""
            keep = [ln for ln in logs_text.splitlines() if ("failure during GPU discovery" in ln) or ("entering low vram mode" in ln) or ("filtering device" in ln)]
            if keep:
                hint = " | " + keep[-1].strip()
            return StepResult(build_dir, "Ollama (docker ROCm) bench", "FAIL", fmt_duration(int(wall_s * 1000.0)), f"ROCm backend inactive{hint} | {metric}")

        if sampler is not None:
            gpu = sampler.avg_gpu_busy()
            base_w = baseline_w if baseline_w is not None else 0.0
            avgw = sampler.avg_power_w() or 0.0
            if (gpu is not None and gpu < 5) and (avgw - base_w) < 5:
                # Include a tiny hint from container logs when available.
                hint = ""
                if log is not None:
                    lines = logs_text.splitlines()
                    keep = [ln for ln in lines if ("failure during GPU discovery" in ln) or ("entering low vram mode" in ln) or ("filtering device" in ln)]
                    if keep:
                        hint = " | " + keep[-1].strip()
                return StepResult(build_dir, "Ollama (docker ROCm) bench", "FAIL", fmt_duration(int(wall_s * 1000.0)), f"no GPU activity detected{hint} | {metric}")

        return StepResult(build_dir, "Ollama (docker ROCm) bench", "OK", fmt_duration(int(wall_s * 1000.0)), metric)
    finally:
        if log is not None:
            _write_log_line(log, "")
            _write_log_line(log, "---- docker logs (ollama) ----")
            rlog = run_cmd(ctx.repo_root, env, ["docker", "logs", name], 20, None)
            for ln in (rlog.out + "\n" + rlog.err).splitlines():
                _write_log_line(log, ln)
        run_cmd(ctx.repo_root, env, ["docker", "rm", "-f", name], 30, log)


def step_ollama(ctx: Context, cfg: dict[str, Any], build_dir: str, rocm_dist: Path, env: dict[str, str], log: Path | None) -> StepResult:
    use_docker_cfg = str(cfg.get("workloads", {}).get("ollama", {}).get("use_docker", "auto")).strip().lower()
    use_docker = use_docker_cfg in {"1", "true", "yes"}

    exe, meta = ensure_ollama(ctx, cfg, env)
    if meta is not None and meta.status == "FAIL":
        return StepResult(build_dir, "Ollama (local binary) smoke", meta.status, meta.duration, meta.metric)
    if exe is None and not use_docker:
        if meta is not None:
            return StepResult(build_dir, "Ollama (local binary) smoke", meta.status, meta.duration, meta.metric)
        return StepResult(build_dir, "Ollama (local binary) smoke", "SKIP", "0ms", "ollama not available")

    # Always do a quick version check.
    if exe is not None:
        r = run_cmd(ctx.repo_root, env, [exe, "--version"], int(cfg.get("timeouts_s", {}).get("ollama", 120)), log)
        if r.rc != 0:
            return StepResult(build_dir, "Ollama (local binary) smoke", "FAIL", fmt_duration(r.dur_ms), f"ollama --version rc={r.rc}")
    else:
        r = None  # type: ignore[assignment]

    model = str(cfg.get("workloads", {}).get("ollama", {}).get("model", "")).strip()
    if not model:
        if exe is not None:
            return StepResult(build_dir, "Ollama (local binary) smoke", "OK", fmt_duration(r.dur_ms), "ollama --version (set workloads.ollama.model to run a prompt)")
        return StepResult(build_dir, "Ollama (docker ROCm) bench", "SKIP", "0ms", "no workloads.ollama.model configured")

    prompt_file = str(cfg.get("workloads", {}).get("ollama", {}).get("prompt_file", "validation/src/assets/samples/prompts/tiny_prompt.txt"))
    prompt_path = (ctx.repo_root / prompt_file) if not Path(prompt_file).is_absolute() else Path(prompt_file)
    prompt = read_small_text(prompt_path).strip().splitlines()[0:1]
    prompt = prompt[0] if prompt else "Hello"
    prompt_name = prompt_path.name

    if use_docker_cfg == "auto" and exe is not None and not _has_rocm_backend(exe):
        use_docker = True
        _write_log_line(log, "Note: host Ollama tarball appears CPU/CUDA-only; using docker ROCm image instead.")
    if use_docker:
        return _docker_run_ollama(ctx, cfg, build_dir, env, log, model=model, prompt=prompt, prompt_name=prompt_name)

    # Run an ephemeral local server so we don't depend on a system service.
    ollama_env = dict(env)
    ollama_env.setdefault("OLLAMA_HOST", "127.0.0.1:11434")
    models_dir = ctx.cache_dir() / "ollama" / "models"
    models_dir.mkdir(parents=True, exist_ok=True)
    ollama_env.setdefault("OLLAMA_MODELS", str(models_dir))

    srv = subprocess.Popen(
        [exe, "serve"],
        cwd=str(ctx.repo_root),
        env=ollama_env,
        stdout=subprocess.DEVNULL if log is None else subprocess.PIPE,
        stderr=subprocess.DEVNULL if log is None else subprocess.PIPE,
        text=True,
    )
    try:
        # Give it a moment to bind.
        time.sleep(1.0)

        tpull = int(cfg.get("timeouts_s", {}).get("ollama_pull", 1800))
        trun = int(cfg.get("timeouts_s", {}).get("ollama_run", 600))

        rp = run_cmd(ctx.repo_root, ollama_env, [exe, "pull", model], tpull, log)
        if rp.rc != 0:
            return StepResult(build_dir, "Ollama (local binary) smoke", "FAIL", fmt_duration(r.dur_ms + rp.dur_ms), f"ollama pull {model} rc={rp.rc}")

        host = ollama_env.get("OLLAMA_HOST", "127.0.0.1:11434")
        base = f"http://{host}"
        gen_url = f"{base}/api/generate"

        num_predict = int(cfg.get("workloads", {}).get("ollama", {}).get("num_predict", 128) or 128)
        payload = {
            "model": model,
            "prompt": prompt,
            "stream": False,
            "options": {"num_predict": num_predict, "temperature": 0},
        }

        def run_generate(sampler):
            t0 = time.monotonic()
            resp = _post_json(gen_url, payload, timeout_s=trun)
            wall_s = time.monotonic() - t0
            return resp, wall_s, sampler

        resp, wall_s, sampler = with_power_sampler(cfg, build_dir=build_dir, fn=run_generate)
        m = _parse_generate_metrics(resp)

        # Measure TTFT with a short streaming run.
        ttft_ms = _measure_ttft_ms(
            gen_url,
            {"model": model, "prompt": prompt, "stream": True, "options": {"num_predict": min(16, num_predict), "temperature": 0}},
            timeout_s=min(60, trun),
        )

        tokps = m.tok_per_s
        ptokps = m.prompt_tok_per_s
        avg_tok_ms = (1000.0 / tokps) if tokps and tokps > 0 else None

        metric = f"model={model} out={num_predict} tok/s={tokps:.2f}" if tokps is not None else f"model={model} out={num_predict}"
        if ptokps is not None:
            metric += f" prompt_tok/s={ptokps:.2f}"
        if ttft_ms is not None:
            metric += f" ttft={ttft_ms:.0f}ms"
        if avg_tok_ms is not None:
            metric += f" avg_tok={avg_tok_ms:.1f}ms"
        metric += f" wall={wall_s:.2f}s prompt={prompt_path.name}"

        metric = append_power(metric, sampler, baseline_w=baseline_avg_w(cfg, build_dir))
        return StepResult(build_dir, "Ollama (local binary) smoke", "OK", fmt_duration(r.dur_ms + rp.dur_ms + int(wall_s * 1000.0)), metric)
    finally:
        try:
            srv.terminate()
        except Exception:
            pass
        try:
            srv.wait(timeout=3.0)
        except Exception:
            try:
                srv.kill()
            except Exception:
                pass
