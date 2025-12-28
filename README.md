# AI-assisted work follows `AI_WORKFLOW.md`; a concrete workflow for this repo is documented in `AI_WORKFLOW_THEROCK_GFX1031.md`.

# TheRock_gfx1031 (ROCm 7.11, RDNA2 gfx103X)

This repository is a **custom TheRock branch** that builds a **repo-local ROCm/HIP stack** optimized for **RDNA2 gfx103X** (tested on **Radeon RX 6700 XT / gfx1031**) and validates it **without** installing anything system-wide (no `/opt/rocm` required).

It focuses on:
- **Reproducible builds** (single entry script + pinned config).
- **Toolchain hygiene** (avoid “system ROCm” leakage and LLVM/ABI mixing).
- **Usability proof** via on-host tests and a Python validation suite with power/utilization checks.

Upstream project: `ROCm/TheRock` (this repo adds gfx103X-focused defaults, scripts, and validation).

## What you get

- A full in-tree ROCm distribution under:
  - `build-stage2/dist/rocm` (recommended)
  - `build-stage1/dist/rocm` (bootstrap/toolchain stage)
- A guided workflow that is intended to work on a **fresh clone**:
  - `build_gfx1031.sh` (configure/bootstrap/build/rebuild)
  - `monitor_gfx1031.sh` (build status snapshots / polling)
  - `test_gfx1031.sh` (sanity + consistency + benchmarks + MIOpen checks)
  - `test_docker_gfx1031.sh` (host vs docker comparison)
  - `validation/` (Python “usability & workloads” validation)

## Design constraints (why the scripts exist)

This build is intentionally strict about:
- **No /opt/rocm fallback**: configure sets `ROCM_PATH/HIP_*` roots to the in-tree dist to prevent accidental system ROCm usage.
- **No compiler switching inside one build dir**: Stage‑1 and Stage‑2 use **separate** build directories.
- **Bootstrapping**: `bootstrap` prepares early sysdeps/dist artifacts so later parallel configures can reliably resolve `find_package(...)` without races.

## System requirements

### Hardware
- GPU: AMD RDNA2 **gfx1031** (or other gfx103X in this branch).
- VRAM: 12GB recommended for LLM/vision/audio workloads.
- RAM: 32GB recommended (build scripts default to `MemoryHigh=28G`, `MemoryMax=31G`).
- Disk: **hundreds of GB** free space are typical for full source builds + caches.

### Kernel / driver / permissions
- Ensure the ROCm kernel interfaces are present:
  - `/dev/kfd` and `/dev/dri` should exist.
- Ensure your user can access the GPU:
  - membership in `video` and `render` groups is commonly required.

### Build tools (host)
Minimum tooling expected on the host:
- `python3` with `venv` support
- `cmake`, `ninja`
- `clang` / `clang++` (this repo uses **Clang 18** on the host)
- `lld` recommended
- standard build essentials (`make`, `g++`, `pkg-config`, etc.)

If you need an Ubuntu/Mint-style dependency list, see `BUILD_EXPERIENCE_NOTES.md`.

## Configuration

Edit `config_gfx1031.yaml` (tracked in git) to:
- toggle components (e.g. BLAS/SOLVER/MIOpen/Profiler/Tests/Benchmarks),
- select targets (`THEROCK_AMDGPU_TARGETS`, default `gfx1031`),
- control memory limits, jobs, and patch/fetch behavior.

Environment variables override config where appropriate (see `./build_gfx1031.sh --help`).

## Recommended workflow (Stage‑1 / Stage‑2)

Stage‑1 builds an in-tree toolchain using system clang (with `LLVM_ENABLE_WERROR=OFF` to reduce avoidable build aborts).
Stage‑2 reconfigures in a **fresh build dir** and uses the Stage‑1 toolchain to avoid falling back to `/usr/lib/llvm-*`.

### Stage‑1 (toolchain bootstrap)

```bash
./build_gfx1031.sh configure --stage1
./build_gfx1031.sh bootstrap --stage1
./build_gfx1031.sh build --stage1 --detach
```

### Stage‑2 (full build, using Stage‑1 toolchain)

```bash
./build_gfx1031.sh configure --stage2
./build_gfx1031.sh bootstrap --stage2
./build_gfx1031.sh build --stage2 --detach
```

Notes:
- `configure` is **clean by default** (removes the build dir). Use `--no-clean` only if you know the build dir is consistent.
- `build` uses a per-build-dir lock (`.locks/`) to prevent accidental concurrent builds. Use `--wait` if you want to wait for an existing lock.

## Monitoring builds

`monitor_gfx1031.sh` prints a build snapshot (systemd unit + log tail). It exits automatically when the unit is no longer active.

```bash
./monitor_gfx1031.sh --once
./monitor_gfx1031.sh --interval 30
```

If you used `--detach`, the build runs as a user unit (derived from `BUILD_DIR`):
- `therock-gfx1031-<builddir>-build.service`

Stop a detached build:
```bash
systemctl --user stop "therock-gfx1031-build-stage2-build.service"
```

## Testing (on host): `test_gfx1031.sh`

`test_gfx1031.sh` has two roles:
1) **Build validation**: sanity + consistency checks (paths, toolchain expectations, basic tools).
2) **GPU micro-benchmarks**: sustained ~5s loads to verify acceleration (power/utilization makes CPU fallback obvious).

Defaults:
- Power sampling: **ON** (includes a 5s idle baseline).
- Logging: **OFF** (enable with `--log`).
- Benchmarks: **OFF** unless you opt in; interactive bench menu is the default when run without args in a TTY.

Common usage:
```bash
# Interactive bench menu (TTY default)
./test_gfx1031.sh

# Consistency checks (strict for Stage‑2)
./test_gfx1031.sh --consistency --expect-stage2 --stage2

# Bench suite (1–9), quick mode
./test_gfx1031.sh --bench-only --stage2

# Longer benches
./test_gfx1031.sh --bench-only --full --stage2

# MIOpen / composable_kernel checks
./test_gfx1031.sh --miopen --stage2
./test_gfx1031.sh --miopen-smoke --stage2
```

Bench outputs include:
- a short math block (formula + brief interpretation),
- estimated operation/data volume in e-notation (for context),
- fixed-column summaries with power/utilization metrics (when enabled).

## Docker comparison: `test_docker_gfx1031.sh`

This script runs the same bench suite against the in-tree dist:
- on the **host**
- inside a **ROCm docker image** with `/dev/kfd` and `/dev/dri` passed through

and prints a compact host vs docker comparison.

```bash
./test_docker_gfx1031.sh
./test_docker_gfx1031.sh --bench-lite
./test_docker_gfx1031.sh --full
./test_docker_gfx1031.sh --docker-only --shell
```

If docker numbers show as `n/a`, it usually indicates parsing issues or that the container run didn’t execute the bench tool; keep logs with `--keep-logs` and inspect the captured output.

## Validation suite (apps + ROCm usability): `validation/`

The validation suite proves that the in-tree ROCm stack is usable **before** any system install:
- It activates `<builddir>/dist/rocm` explicitly (no `/opt/rocm`).
- It runs sustained GPU tests with optional power sampling.
- Optional “workload” steps download/build/run representative apps and **fail** if they fall back to CPU.

Start here:
```bash
python3 validation/scripts/validate.py
```

Profiles:
```bash
python3 validation/scripts/validate.py --profile quick
python3 validation/scripts/validate.py --profile full --yes
python3 validation/scripts/validate.py --profile pytorch --yes --power
python3 validation/scripts/validate.py --profile petsc --yes --power --log
```

See `validation/README.md` for full details, configuration, and per-workload one-shot validators.

## TODO

- Tighten and simplify “new user” OS dependency documentation into one canonical list.
- Expand validation workloads (audio/video LLMs, additional scientific solvers) with pinned versions and clear size policies.
- Add optional CI-friendly report formats (JUnit/HTML) for `validation/`.
