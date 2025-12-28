# Validation (ROCm usability & app-style checks)

This directory contains a **repo-local validation suite** that validates the in-tree ROCm
artifact(s) under `<builddir>/dist/rocm` without requiring a system install (no `/opt/rocm`).

It has two goals:
1) **ROCm usability proof**: `rocminfo`, HIP compile+run, and a few small library smokes/benches.
2) **Representative apps (optional, download/build)**: smoke checks for typical workloads:
   llama.cpp (docker), Ollama, Whisper, Open Interpreter, MFEM (HIP build).

This suite includes small **sample inputs** under `validation/src/assets/samples/`:
- `audio/` contains a short WAV used by the Whisper smoke test.
- `prompts/` contains short LLM prompts used by future functional inference checks.

## Quick start

Default (no args): quick suite with **power metrics** (no downloads, no logs):
```bash
python3 validation/scripts/validate.py
```

More readable summary output (prints params/power under each test):
```bash
python3 validation/scripts/validate.py --summary-multiline
```

Explicit ROCm-only smoke (no downloads):
```bash
python3 validation/scripts/validate.py --profile quick
```

Full validation (enables workloads; prompts once before downloads/builds):
```bash
python3 validation/scripts/validate.py --profile full
```

Non-interactive full validation (assume “yes” to the prompt):
```bash
python3 validation/scripts/validate.py --yes
```

## Workloads (functional inputs)

Workload steps use small repo-local inputs by default:
- Prompt: `validation/src/assets/samples/prompts/tiny_prompt.txt`
- Audio: `validation/src/assets/samples/audio/Take2_Audio1-1.wav`

Some workload steps have **optional functional modes** which are disabled unless configured:
- **Ollama**: enabled by default (model `llama3.2:3b-instruct-q4_0`, ~1.9GB). The suite measures:
  - `tok/s` (generation throughput)
  - `ttft` (time to first token, ms)
  - `avg_tok` (avg ms/token)
  - optional power/energy when `--power` is enabled
- **llama.cpp (docker)**: set `workloads.llama_cpp.model_url` (and optionally `model_sha256`) to download a GGUF and run a sustained **`llama-bench`** run inside the container.
  - Reports `pp_tok/s` (prompt processing) and `tg_tok/s` (token generation) plus optional power/energy.
  - Strict inference mode (must run GPU inference) is the default: `python3 validation/scripts/llama_cpp_validate.py`.
  - Smoke-only mode (no model download / no inference): `python3 validation/scripts/llama_cpp_validate.py --smoke`.

### llama.cpp vs Ollama (why both)

- **llama.cpp** is a low-level inference engine that runs GGUF models directly. In this repo’s validation it runs **inside Docker** via the `rocm/llama.cpp` wrapper image and we measure `pp_tok/s` + `tg_tok/s` via `llama-bench`.
- **Ollama** is a higher-level runtime/serving layer (model management + HTTP API). It can use a GPU backend when available and we measure `tok/s`, `ttft`, `avg_tok` via its API. In this repo’s validation, Ollama runs in **docker ROCm** when the host `ollama` binary lacks a ROCm backend (`workloads.ollama.use_docker: auto`).

Tip: run just the Ollama workload:
```bash
python3 validation/scripts/validate.py --profile ollama --yes --power --log
```

One-shot self-contained validation + diagnosis:
```bash
python3 validation/scripts/ollama_doctor.py --yes
```

One-shot self-contained workload validators (GPU required):
```bash
python3 validation/scripts/llama_cpp_validate.py
python3 validation/scripts/ollama_validate.py
python3 validation/scripts/whisper_validate.py
python3 validation/scripts/mfem_validate.py
```

Additional GPU compute validations:
```bash
# PyTorch audio/video style GPU compute (requires ROCm-enabled torch in the venv):
python3 validation/scripts/validate.py --profile pytorch --yes --power

# PETSc HIP build + KSP solve (downloads + builds PETSc; can take a while):
python3 validation/scripts/validate.py --profile petsc --yes --power --log
```

MFEM notes:
- The HIP CMake package sometimes ends up with an empty `HIP_PLATFORM` during early configure in external projects; the validator pins `-DHIP_PLATFORM=amd`.
- MFEM examples are often excluded from the default build target; the validator builds `ex1` explicitly and falls back to smaller runtime parameters if a HIP OOM occurs.

llama.cpp options:
- Default (strict GPU inference via `llama-bench`): `python3 validation/scripts/llama_cpp_validate.py`
- Smoke-only (no model download / no inference): `python3 validation/scripts/llama_cpp_validate.py --smoke`

If Ollama falls back to CPU, the suite marks the step as `FAIL` and the per-step log contains the docker logs
showing why (e.g. `entering low vram mode` / `total vram=0 B`).

Write per-step logs + a JSON report:
```bash
python3 validation/scripts/validate.py --log
```

Add optional GPU power/util sampling during sustained-load tests:
```bash
python3 validation/scripts/validate.py --profile quick --power --log
```

When `--power` is enabled, the run starts with a **5s idle baseline** (no GPU load) and then
reports per-test energy deltas (`dW`) relative to that baseline.

## How it works

- **Explicit in-tree activation:** each step runs with `ROCM_PATH`, `PATH`, and `LD_LIBRARY_PATH`
  set to `<builddir>/dist/rocm` so it doesn’t accidentally use system ROCm.
- **Sustained-load checks:** core ROCm tests are parameterized to run for ~5 seconds each, so it’s
  easier to observe *continuous* GPU/CPU utilization (no “pulses”) and confirm hardware acceleration before running workloads.
- **Optional power/energy sampling:** with `--power`, sustained-load tests sample AMDGPU sysfs
  power (`power1_average`, µW) and integrate to an approximate energy in **Ws**. With `--log`,
  per-test samples are written as `*.power.csv` under the run’s `logs/` directory.
- **Repo-local Python environment:** the scripts auto-create a venv under
  `validation/workspace/envs/py/` and install only minimal dependencies (see `validation/requirements-lock.txt`).
- **Downloads are gated:** third-party checks are enabled by default in `full` and guarded by
  a single **Y/n prompt** on startup (use `--yes` to skip prompting).
- **Workloads are best-effort:** workload steps may `SKIP` if prerequisites aren’t present
  (e.g. `docker` missing for llama.cpp, or Python packages missing for Whisper).
  The goal is to keep the suite reproducible and avoid surprise multi-GB installs.
- **GPU is mandatory for workloads:** if a workload runs but cannot prove GPU acceleration (CPU fallback),
  it is treated as `FAIL` (with hints in the metric and optional logs).
- **gfx1031 note:** some prebuilt ROCm docker images ship HIP code objects for `gfx1030` but not `gfx1031`.
  For such images, the suite uses `HSA_OVERRIDE_GFX_VERSION=10.3.0` automatically when `rocm.amd_gpu_arch=gfx1031`.
- **All runtime artifacts live in `validation/workspace/`** and are gitignored.

## Build dirs (Stage-1 vs Stage-2)

If you don’t specify anything, validation auto-detects and uses the **preferred** build dir
in this order: `build-stage2`, `build`, `build-stage1`.

This is why results can differ per build dir:
- **Stage-2** typically contains `hipcc`, benches (e.g. `rocblas-bench`), and is the main target.
- **Stage-1** may be a bootstrap toolchain stage and can legitimately `SKIP` GPU runtime steps.

To force one build dir:
```bash
python3 validation/scripts/validate.py --build-dirs build-stage2
```

To validate all detected build dirs:
```bash
python3 validation/scripts/validate.py --all-build-dirs
```

## Doctor / cache / reports

System + in-tree sanity (no downloads):
```bash
python3 validation/scripts/doctor.py
```

Delete old run artifacts (and optionally downloads/build caches):
```bash
python3 validation/scripts/cache_gc.py
python3 validation/scripts/cache_gc.py --all
```

Print the latest report path (and optionally open a browser for HTML reports if present):
```bash
python3 validation/scripts/report_open.py
python3 validation/scripts/report_open.py --open
```

## Configuration

- Defaults: `validation/config/defaults.yaml`
- Profiles:
  - `validation/config/profiles/full.yaml` (default; everything enabled, downloads gated)
  - `validation/config/profiles/quick.yaml` (ROCm-only smoke)
  - `validation/config/profiles/airgapped.yaml` (same as quick; future-proof name)
  - `validation/config/profiles/ollama.yaml` (Ollama-only)
  - `validation/config/profiles/ollama_smoke.yaml` (Ollama smoke-only; no model/inference)
  - `validation/config/profiles/llama_cpp.yaml` (llama.cpp-only)
  - `validation/config/profiles/llama_cpp_infer.yaml` (llama.cpp inference-only; requires a model URL)
  - `validation/config/profiles/llama_cpp_smoke.yaml` (llama.cpp smoke-only; no model/inference)
  - `validation/config/profiles/whisper.yaml` (Whisper-only)
  - `validation/config/profiles/mfem.yaml` (MFEM-only)
  - `validation/config/profiles/pytorch.yaml` (PyTorch GPU compute: audio+video conv)
  - `validation/config/profiles/petsc.yaml` (PETSc HIP build+solve)
- Workload inputs (URLs/refs): `validation/config/defaults.yaml` under `workloads:`
- Layout/env hints:
  - `validation/config/layout/gfx_targets.yaml`
  - `validation/config/layout/install_layouts.yaml`
  - `validation/config/layout/env_exports.yaml`

## Layout

```
validation/
├─ README.md
├─ AI_WORKFLOW_VALIDATION.md
├─ ANWEISUNG_STRUKTUR.md
├─ pyproject.toml
├─ requirements-lock.txt
├─ .gitignore
├─ .env.example
├─ config/
├─ scripts/                # user entrypoints (auto-venv bootstrap)
├─ src/                    # implementation (cli/core/steps/assets/data)
└─ workspace/              # runtime artifacts (gitignored)
```

## Legal / third-party

Third-party projects used by optional checks are referenced in:
`validation/src/assets/notices/THIRD_PARTY_NOTICES.md`.
