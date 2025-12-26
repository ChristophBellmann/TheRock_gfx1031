# Validation (ROCm usability & app-style checks)

This directory contains a **repo-local validation suite** that validates the in-tree ROCm
artifact(s) under `<builddir>/dist/rocm` without requiring a system install (no `/opt/rocm`).

It has two goals:
1) **ROCm usability proof**: `rocminfo`, HIP compile+run, and a few small library smokes/benches.
2) **Representative apps (optional, download/build)**: smoke checks for typical workloads:
   llama.cpp (docker), Ollama, Whisper, Open Interpreter, MFEM (HIP build).

## Quick start

ROCm-only smoke (no downloads):
```bash
python3 validation/scripts/validate.py --profile quick
```

Full validation (default profile, prompts once before downloads/builds):
```bash
python3 validation/scripts/validate.py
```

Non-interactive full validation (assume “yes” to the prompt):
```bash
python3 validation/scripts/validate.py --yes
```

Write per-step logs + a JSON report:
```bash
python3 validation/scripts/validate.py --log
```

Add optional GPU power/util sampling during sustained-load tests:
```bash
python3 validation/scripts/validate.py --profile quick --power --log
```

## How it works

- **Explicit in-tree activation:** each step runs with `ROCM_PATH`, `PATH`, and `LD_LIBRARY_PATH`
  set to `<builddir>/dist/rocm` so it doesn’t accidentally use system ROCm.
- **Sustained-load checks:** core ROCm tests are parameterized to run for ~5 seconds each, so it’s
  easier to observe GPU/CPU utilization and confirm hardware acceleration before running workloads.
- **Optional power/energy sampling:** with `--power`, sustained-load tests sample AMDGPU sysfs
  power (`power1_average`, µW) and integrate to an approximate energy in **Ws**. With `--log`,
  per-test samples are written as `*.power.csv` under the run’s `logs/` directory.
- **Repo-local Python environment:** the scripts auto-create a venv under
  `validation/workspace/envs/py/` and install only minimal dependencies (see `validation/requirements-lock.txt`).
- **Downloads are gated:** third-party checks are enabled by default in `full` and guarded by
  a single **Y/n prompt** on startup (use `--yes` to skip prompting).
- **All runtime artifacts live in `validation/workspace/`** and are gitignored.

## Build dirs (Stage-1 vs Stage-2)

If you don’t specify anything, validation auto-detects and runs against every present build dir
in this order: `build-stage2`, `build`, `build-stage1`.

This is why results can differ per build dir:
- **Stage-2** typically contains `hipcc`, benches (e.g. `rocblas-bench`), and is the main target.
- **Stage-1** may be a bootstrap toolchain stage and can legitimately `SKIP` GPU runtime steps.

To force one build dir:
```bash
python3 validation/scripts/validate.py --build-dirs build-stage2
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
