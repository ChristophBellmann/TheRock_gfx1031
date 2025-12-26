# Validation (in-tree ROCm usability & integrations)

This directory contains a repository-local **validation suite** whose purpose is:

1) **Usability proof (in-tree ROCm)**  
   Show that the built stack under `<builddir>/dist/rocm` is runnable and fast enough
   *without* installing anything into the system (no `/opt/rocm` dependency).

2) **Practical integration checks (optional downloads/builds)**  
   Validate representative “real apps” for the intended use-cases:
   - llama.cpp (ROCm docker image)
   - Ollama
   - Whisper
   - Open Interpreter
   - MFEM (HIP build) for meshing/solving-style workloads

The validation runner is implemented as a small Python program with a stable,
numbered test list and a human-friendly report.

## How it works (high level)

- **Explicit in-tree activation:** every check runs with `ROCM_PATH`, `PATH`, and
  `LD_LIBRARY_PATH` set to `<builddir>/dist/rocm` so we don’t accidentally pick up
  system ROCm.
- **Stable test IDs:** checks are numbered so results can be referenced in notes/issues.
- **Downloads are gated:** third-party checks are *enabled by default* but guarded by
  a **Y/n prompt** on the first run. Use `--yes` for non-interactive automation.
- **Cache/build dirs:** anything downloaded/built by validation lives under `validation/_cache`
  and is not committed to git.

## Usage

Minimal (runs all core ROCm usability checks; prompts for third-party)
```bash
python3 validation/run_validation.py
```

Non-interactive (assume “yes” to the third-party prompt)
```bash
python3 validation/run_validation.py --yes
```

Disable third-party downloads/builds entirely (ROCm-only validation)
```bash
python3 validation/run_validation.py --no-downloads
```

Select checks by number
```bash
python3 validation/run_validation.py --select 1,2,3
python3 validation/run_validation.py --select 0   # all checks
```

Write a detailed log
```bash
python3 validation/run_validation.py --log validation.log
```

Select the build directory (defaults to the first existing: `build-stage2`, `build`, `build-stage1`)
```bash
python3 validation/run_validation.py --build-dir build-stage2
```

## What I’m planning to validate (roadmap)

The third-party checks are intentionally structured so they can evolve into
“scientific”/repeatable experiments:

- **Repeatable inputs** (fixed seeds where possible)
- **Clear success criteria** (e.g. “loads model”, “produces output”, “runs on HIP/ROCm”)
- **Measured outputs** (time/throughput, basic correctness signals)
- **Small-by-default artifacts** (try to keep downloads within a “few GB”, and
  make anything larger explicit/optional)

## Files & structure

- `validation/run_validation.py` — entrypoint wrapper for running the suite
- `validation/therock_validation/` — implementation package
  - `cli.py` — argument parsing + orchestration
  - `env.py` — in-tree ROCm activation
  - `checks/` — individual check implementations (numbered)
  - `third_party.py` — helper utilities for downloads/venv/caches
- `validation/_cache/` — downloads/clones (gitignored)
- `validation/_build/` — local builds (gitignored)
- `validation/_logs/` — logs (gitignored)

## Notes

- On Linux, `hipinfo` is typically not shipped by TheRock (it’s a windows-only artifact).
  Use `rocminfo` + the toolchain consistency checks in `./test_gfx1031.sh` for HIP sanity.
