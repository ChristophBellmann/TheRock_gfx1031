# AI-assisted work follows `AI_WORKFLOW.md`; a concrete workflow for this repo is documented in `AI_WORKFLOW_THEROCK_GFX1031.md`.

# TheRock_gfx1031 (ROCm 7.11, RDNA2 gfx103X)

This repository is a custom TheRock branch that builds a repo-local ROCm/HIP stack.
For **RDNA2 gfx103X**, tested on **Radeon RX 6700 XT / gfx1031**.
Validation runs without installing anything system-wide (no `/opt/rocm` required).

Upstream project: `ROCm/TheRock` (this repo adds gfx103X-focused defaults, scripts, and validation).

## Quick start

  - `build_gfx1031.sh` (configure/bootstrap/build/rebuild)
  - `monitor_gfx1031.sh` (build status snapshots / polling)
  - `test_gfx1031.sh` (sanity + consistency + benchmarks + MIOpen checks)
  - `test_docker_gfx1031.sh` (host vs docker comparison)
  - `validation/` (Python “usability & workloads” validation)

## System requirements

### Kernel / driver / permissions
- Ensure the ROCm kernel interfaces are present:
  - `/dev/kfd` and `/dev/dri` should exist.
- Ensure your user can access the GPU:
  - membership in `video` and `render` groups is commonly required.

### Build tools (host)

- `python3` with `venv` support
- `cmake`, `ninja`
- `clang` / `clang++` (Clang 18 on the host)
- `lld` 
- `make`, `g++`, `pkg-config`

## Configuration

Edit `config_gfx1031.yaml` (tracked in git) to:
- toggle components (e.g. BLAS/SOLVER/MIOpen/Profiler/Tests/Benchmarks),
- select targets (`THEROCK_AMDGPU_TARGETS`, default `gfx1031`),
- control memory limits, jobs, and patch/fetch behavior.

see `./build_gfx1031.sh --help`

### Default behavior (no CLI options)

- `./build_gfx1031.sh configure` uses the defaults from `config_gfx1031.yaml`:
  - it configures **Stage‑1 first** (toolchain stage) using the enabled `features.*` set from the YAML
  - if the Stage‑1 toolchain is already built, it also configures **Stage‑2**
- To make Stage‑2 the default, either run `./build_gfx1031.sh configure --stage2` (recommended) or change the YAML defaults to `build.stage: 2` and `build.build_dir: build-stage2`.
- If you want to configure both stages in one go (still configure-only): `./build_gfx1031.sh configure --all`.

## workflow 

Stage‑1 builds an in-tree toolchain using system clang.
Stage‑2 reconfigures in a **fresh build dir**.

### One-command build (default)

After a fresh clone, the intended minimal workflow is:

```bash
./build_gfx1031.sh configure
./build_gfx1031.sh build
```

`build` (without options) builds the full pipeline needed for `test_gfx1031.sh` and `validation/`:
Stage‑1 bootstrap+build, then Stage‑2 configure+bootstrap+build.

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
- `build` uses a per-build-dir lock (`.locks/`) to prevent accidental concurrent builds.

## Monitoring builds

`monitor_gfx1031.sh` prints a build snapshot (systemd unit + log tail). It exits automatically when the unit is no longer active.

```bash
./monitor_gfx1031.sh
```

## Testing (on host): `test_gfx1031.sh`

`test_gfx1031.sh` has two roles:
1) **Build validation**: sanity + consistency checks (paths, toolchain expectations, basic tools).
2) **GPU micro-benchmarks**: sustained ~5s loads to verify acceleration (power/utilization makes CPU fallback obvious).

```bash
./test_gfx1031.sh
```

## Docker comparison: `test_docker_gfx1031.sh`

This script runs the same bench suite against the in-tree dist:
- on the **host**
- inside a **ROCm docker image** with `/dev/kfd` and `/dev/dri` passed through

```bash
./test_docker_gfx1031.sh
```

## Validation suite (apps + ROCm usability): `validation/`

The validation suite proves that the in-tree ROCm stack is usable **before** any system install.
It runs sustained GPU tests with optional power sampling.

Start here:
```bash
python3 validation/scripts/validate.py
```

See `validation/README.md` for full details, configuration, and per-workload one-shot validators.

## TODO

- Tighten and simplify “new user” OS dependency documentation into one canonical list.
- Expand validation workloads (audio/video LLMs, additional scientific solvers) with pinned versions and clear size policies.
- Add optional CI-friendly report formats (JUnit/HTML) for `validation/`.
