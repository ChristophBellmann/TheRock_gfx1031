# Usability Validation (in-tree ROCm)

This folder contains a small, repository-local **usability validation** program.
It is intended as a practical “proof that the built stack is usable” **before**
installing anything into the system (i.e. without relying on `/opt/rocm`).

Principles
- **In-tree activation:** each check runs against `<builddir>/dist/rocm` by setting `ROCM_PATH`, `PATH`, and `LD_LIBRARY_PATH` explicitly.
- **Small by default:** no large downloads happen automatically. Optional third‑party integrations are *placeholders* and require explicit opt‑in.
- **Repeatable:** the program prints a numbered report with runtimes and key metrics.

Run
```bash
python3 -m venv .venv && source .venv/bin/activate
python3 validation/run_validation.py
```

Non-interactive (select specific checks)
```bash
python3 validation/run_validation.py --select 1,2,3
python3 validation/run_validation.py --select 0   # all checks
```

Logging
```bash
python3 validation/run_validation.py --log validation.log
```

Build dir selection
```bash
python3 validation/run_validation.py --build-dir build-stage2
```

Notes
- Check numbers are stable, so results can be referenced in notes/issues.
- The validation runner intentionally focuses on *smoke/integration* behavior:
  it confirms the toolchain/runtime can execute a minimal HIP workload and that
  key CLI tools can be invoked from the in-tree environment.
