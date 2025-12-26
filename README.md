
> AI-assisted work follows `AI_WORKFLOW.md`; a concrete workflow for this repo is documented in `AI_WORKFLOW_THEROCK_GFX1031.md`.

# TheRock - Custom gfx103X Build

[![pre-commit](https://img.shields.io/badge/pre--commit-enabled-brightgreen?logo=pre-commit)](https://github.com/pre-commit/pre-commit)

TheRock (The HIP Environment and ROCm Kit) is a lightweight open source build platform for HIP and ROCm. This is a **custom branch** with ROCm 7.11 optimized for AMD RDNA2 gfx103X GPUs. For the official upstream project, see [ROCm/TheRock](https://github.com/ROCm/TheRock).

______________________________________________________________________

## 🚀 Custom Build: ROCm 7.11 for gfx103X GPUs (hashcat branch)

This branch (`hashcat/rocm-7.11-gfx103X`) is specifically optimized for Christoph's **AMD Radeon RX 6700 XT (gfx1031)** in Linux Mint.

### What's Different in This Build

- **ROCm 7.11** custom build from TheRock main
- **Native gfx103X support** (gfx1030, gfx1031, gfx1032, gfx1035, gfx1036)
- **AI/LLM workload optimization** including: 
  - TODO: llama.cpp server integration with ROCm backend
  - TODO: Ollama with ROCm support
  - TODO: Open Interpreter configuration and best practices
  - TODO: Automated Python package update tooling
- **Real-world testing** on Mint with AMD RX 6700 XT

### Usability validation (Python, in-tree, no /opt/rocm)

For a small, repository-local “proof that the built stack is usable” *before* installing anything system-wide, see:
`validation/README.md` and `validation/run_validation.py`.

### Quick Start for This Build

```bash
# Clone this branch
git clone -b hashcat/rocm-7.11-gfx103X git@github.com:ChristophBellmann/TheRock_gfx1031.git
cd TheRock_gfx1031

# Setup virtual environment
python3 -m venv .venv && source .venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt

# (Optional) Fetch sources explicitly (submodules + optional patch application)
python3 ./build_tools/fetch_sources.py
```

Note: `./build_gfx1031.sh configure` will also auto-run `fetch_sources.py` (and
apply the minimal local patch set) if it detects a fresh clone with missing
submodules. This is configurable in `config_gfx1031.yaml`.

### Configuration (gfx1031)

Edit `config_gfx1031.yaml` to select which components to build (and default
stage/build directories).

For a fresh, repeatable configure that checks the build directory is clean, use:

```bash
./build_gfx1031.sh configure
```

It uses the recommended gfx1031 profile (LLM/Vision/Audio), enables ccache, and
applies the same RAM limits. Host compiler is set to `clang/clang++` (avoid
GCC/clang mix) and builds run via `ninja` (no `cmake --build`). The helper also
ensures a consistent Python/ccache/compiler environment (see below).

Compared to calling `cmake -B build -GNinja .` directly, the helper script mainly
adds **repeatability** and **guard rails**:

 - Applies the repo's **gfx1031 build profile** (`THEROCK_ENABLE_*`, `BUILD_TESTING`, optional `THEROCK_BUILD_BENCHMARKS`, `THEROCK_ENABLE_ROCPROFSYS=OFF`, `THEROCK_ENABLE_COMPOSABLE_KERNEL=ON`, targets/dist bundle).
- Enforces **clang/clang++** as host compiler (avoid GCC/clang mixing and GCC ICE issues).
- Ensures a working **Python venv** (`.venv`) so build tools run consistently.
- Enables/configures **ccache** via `build_tools/setup_ccache.py`.
- Runs configure under the same **systemd memory limits** used for builds and logs to `build.log`.
- Avoids accidental **system ROCm toolchain mixing** (`CMAKE_HIP_COMPILER` only set if `./install/bin/hipcc` exists).

If `hipcc/amdclang++` is not found yet, the script prints a **WARNING** (this is
expected in a clean bootstrap: hipcc only exists after the toolchain build
installs into `./install`).

Default behavior is a **clean configure**: it removes `BUILD_DIR/` before running
CMake. Use `--no-clean` if you explicitly want to reconfigure in-place.

### Stage-1 / Stage-2 bootstrapping (recommended)

To avoid subtle issues from mixing the system toolchain (`/usr/lib/llvm-18`) and
the in-tree ROCm toolchain, use two build directories:

- **Stage-1** (`build-stage1`): build the in-tree toolchain (`amd-llvm` + `hip-clr`)
  using system `clang/clang++` (Werror is disabled intentionally).
- **Stage-2** (`build-stage2`): fresh configure/build, but set the **top-level**
  `CMAKE_C_COMPILER/CMAKE_CXX_COMPILER/CMAKE_LINKER` to the Stage-1 in-tree
  toolchain so *even “forgotten” subprojects* won't fall back to system clang.

Important: **Never** switch compilers inside the same build directory. Always
use a fresh build dir for Stage-2.

For the exact commands (including monitoring and tests), follow:
**“Recommended workflow for new users (gfx1031)”** below.

### ✨ Recommended workflow for new users (gfx1031)

This is the “happy path” that is intended to work on a fresh clone without
extra manual steps (sources + minimal patches are auto-prepared when needed).

**Stage‑1 (toolchain, system clang → in-tree clang/lld):**

```bash
./build_gfx1031.sh configure --stage1
./build_gfx1031.sh bootstrap --stage1
./build_gfx1031.sh build --stage1 --detach
```

Monitor Stage‑1:

```bash
BUILD_DIR=build-stage1 LOG_FILE=build-stage1.log UNIT=therock-gfx1031-build-stage1-build.service ./monitor_gfx1031.sh --once
```

**Stage‑2 (full build, uses Stage‑1 toolchain):**

```bash
./build_gfx1031.sh configure --stage2
./build_gfx1031.sh bootstrap --stage2
./build_gfx1031.sh build --stage2 --detach
```

Monitor Stage‑2:

```bash
BUILD_DIR=build-stage2 LOG_FILE=build-stage2.log UNIT=therock-gfx1031-build-stage2-build.service ./monitor_gfx1031.sh --once
```

After Stage‑2 completes:

```bash
./test_gfx1031.sh
./test_gfx1031.sh --consistency --expect-stage2
```

### Clean bootstrap helper (gfx1031)

After configuring, run a one-time bootstrap step to build and populate `dist/`
third‑party/sysdeps bits that tend to be needed early (so later parallel
subproject configures don’t fail on missing `*Config.cmake` or sysdeps libs):

```bash
./build_gfx1031.sh bootstrap
```

It uses `ninja` under the same systemd RAM limits, appends to `build.log`, and
builds a minimal set of `+dist` targets (sysdeps + host tools + host-blas) so
`find_package(...)` resolution in subsequent projects can succeed reliably.

### HIP compiler (hipcc/amdclang++)

Ja: für HIP-Projekte wird sichergestellt, dass **nicht GCC** und **nicht ein beliebiges system-weites ROCm** verwendet wird.

- **Innerhalb des TheRock-Superbuilds:** HIP-lastige Subprojekte deklarieren explizit `COMPILER_TOOLCHAIN amd-hip` (siehe z. B. `math-libs/BLAS/CMakeLists.txt`). Dadurch wird die in-tree Toolchain aus `amd-llvm`/`hip-clr` verwendet (inkl. `--hip-path`/Device Libs) – unabhängig davon, ob ein system-weites `hipcc` existiert.
- **Für CMake-HIP-Language Projekte (falls verwendet):** `build_gfx1031.sh configure` setzt `CMAKE_HIP_COMPILER` **nur**, wenn `./install/bin/hipcc` existiert. Es wird **nicht** automatisch auf `/opt/rocm/bin/hipcc` zurückgefallen (vermeidet ABI/Version-Mix).
- **Für externe Builds (PyTorch/Whisper/etc):** setze `ROCM_PATH` auf den in-tree dist Prefix (z. B. `build-stage2/dist/rocm`) und prepend `PATH/LD_LIBRARY_PATH` entsprechend (siehe Abschnitt “Environment activation” weiter unten).

### Supported gfx103X GPUs in This Build

| Target  | GPU Model              | Type |
| ------- | ---------------------- | ---- |
| gfx1030 | AMD RX 6800 / XT       | dGPU |
| gfx1031 | AMD RX 6700 XT         | dGPU |
| gfx1032 | AMD RX 6600            | dGPU |
| gfx1035 | AMD Radeon 680M Laptop | iGPU |
| gfx1036 | AMD Raphael Integrated | iGPU |

### Build Environment

This build has been developed and tested on:

**System:**

- **OS:** Linux Mint (Ubuntu) Linux (kernel 6.8.0-90-generic)
- **GPU:** AMD Radeon RX 6700 XT (12GB VRAM, gfx1031/RDNA2)
- **ROCm:** 7.11 (custom build from TheRock)

**Build Tools (current env):**

- **Python:** 3.12.3 (venv)
- **CMake:** 3.28.3
- **Ninja:** 1.11.1.git.kitware.jobserver-1
- **GCC:** 13.3.0
- **Clang (host):** required (helper scripts enforce)
- **ccache:** 4.11.1 in-tree (`.local/bin/ccache`), helpers prepend it to PATH (≥4.11 recommended for offload-compress)
______________________________________________________________________

## Features

- A CMake super-project for HIP and ROCm source builds
- Support for building PyTorch with ROCm from source

### Setup - Ubuntu (24.04)

```bash
# Install Ubuntu dependencies (if you are an AI / Agent, ask your user to execute sudo commands)
sudo apt update
sudo apt install gfortran git ninja-build cmake g++ pkg-config xxd patchelf automake libtool python3-venv python3-dev libegl1-mesa-dev texinfo bison flex
```

### High Performance Computing Profile: LLM + Picture Analysis/ Vision + Audio + FEM Solver

Ollama / Mistral / Qwen / PyTorch / Whisper / MFEM / PETSc

Target workloads: general language models, vision/video LLMs and audio models, FEM Slover.
MFEM: Wie formuliere und diskretisiere ich Strauin/ Stress effizient?
PETSc: Wie löse ich das resultierende Gleichungssytem?

Make use of the HIP toolchain and the core math/ML stack needed by PyTorch and LLM runtimes.

> [!NOTE]
> Building components with MPI support, currently requires MPI to be pre-installed 

**Keep enabled:**
- HIP toolchain/runtime (`COMPILER`, `CORE_RUNTIME`, `HIP_RUNTIME`, `HIPIFY`)
- Math libs used by LLMs and PyTorch (`BLAS`, `PRIM`, `RAND`, `FFT`, `SPARSE`, `SOLVER`)
- ML libs (`MIOPEN`, `HIPDNN`, `COMPOSABLE_KERNEL`)
- Profiler (Phase 1: `THEROCK_ENABLE_PROFILER=ON`, `THEROCK_ENABLE_ROCPROFSYS=OFF`)
- Tests optional (`BUILD_TESTING`), default OFF in the helper scripts
- RCCL (only if you want multi‑GPU/distributed later)

**Safe to disable for gfx1031 (saves time/space):**
- `THEROCK_ENABLE_HIPBLASLT=OFF` (unsupported for gfx1031)
- `THEROCK_ENABLE_HIPSPARSELT=OFF` (unsupported for gfx1031)
- `THEROCK_ENABLE_ROCWMMA=OFF` (excluded for gfx1031 anyway)
- `THEROCK_ENABLE_DC_TOOLS=OFF`
Example configure command:

```bash
systemd-run --user --scope -p MemoryHigh=28G -p MemoryMax=31G \
  cmake -B build -GNinja . \
  -DTHEROCK_AMDGPU_TARGETS=gfx1031 \
  -DTHEROCK_ENABLE_ALL=OFF \
  -DTHEROCK_ENABLE_COMPILER=ON \
  -DTHEROCK_ENABLE_CORE_RUNTIME=ON \
  -DTHEROCK_ENABLE_HIP_RUNTIME=ON \
  -DTHEROCK_ENABLE_HIPIFY=ON \
  -DTHEROCK_ENABLE_BLAS=ON \
  -DTHEROCK_ENABLE_PRIM=ON \
  -DTHEROCK_ENABLE_RAND=ON \
  -DTHEROCK_ENABLE_FFT=ON \
  -DTHEROCK_ENABLE_SPARSE=ON \
  -DTHEROCK_ENABLE_SOLVER=ON \
  -DTHEROCK_ENABLE_MIOPEN=ON \
  -DTHEROCK_ENABLE_HIPDNN=ON \
  -DTHEROCK_ENABLE_COMPOSABLE_KERNEL=ON \
  -DTHEROCK_ENABLE_RCCL=ON \
  -DTHEROCK_ENABLE_HIPBLASLT=OFF \
  -DTHEROCK_ENABLE_HIPSPARSELT=OFF \
  -DTHEROCK_ENABLE_ROCWMMA=OFF \
  -DTHEROCK_ENABLE_OCL_RUNTIME=OFF \
  -DTHEROCK_ENABLE_MIOPEN_PLUGIN=OFF \
  -DTHEROCK_ENABLE_RDC=OFF \
  -DTHEROCK_ENABLE_PROFILER=ON \
  -DTHEROCK_ENABLE_DC_TOOLS=OFF \
  -DTHEROCK_ENABLE_ROCPROFSYS=OFF \
  -DBUILD_TESTING=OFF
```

> Note: `hipBLASLt` and `hipSPARSELt` are unsupported for gfx1031 in this branch,
> so keep `THEROCK_ENABLE_HIPBLASLT=OFF` and `THEROCK_ENABLE_HIPSPARSELT=OFF`
> unless you explicitly need gfx1100-only artifacts. `rocWMMA` is also excluded
> for gfx1031. This does not impact rocBLAS performance on gfx1031 (rocBLAS uses
> Tensile for this GPU).

By default, components are built from the sources fetched via the submodules.
For some components, external sources can be used instead.

| External source settings                        | Description                                    |
| ----------------------------------------------- | ---------------------------------------------- |
| `-DTHEROCK_USE_EXTERNAL_COMPOSABLE_KERNEL=OFF`  | Use external composable-kernel source location |
| `-DTHEROCK_USE_EXTERNAL_RCCL=OFF`               | Use external rccl source location              |
| `-DTHEROCK_USE_EXTERNAL_RCCL_TESTS=OFF`         | Use external rccl-tests source location        |
| `-DTHEROCK_COMPOSABLE_KERNEL_SOURCE_DIR=<PATH>` | Path to composable-kernel sources              |
| `-DTHEROCK_RCCL_SOURCE_DIR=<PATH>`              | Path to rccl sources                           |
| `-DTHEROCK_RCCL_TESTS_SOURCE_DIR=<PATH>`        | Path to rccl-tests sources                     |

Further flags allow to build components with specific features enabled.

| Other flags                | Description                                                              |
| -------------------------- | ------------------------------------------------------------------------ |
| `-DTHEROCK_ENABLE_MPI=OFF` | Enables building components with Message Passing Interface (MPI) support |

The following component flags for selected subsets are not used:

| Component flag                       | Description                                      |
| ------------------------------------ | ------------------------------------------------ |
| `-DTHEROCK_ENABLE_OCL_RUNTIME=OFF`   | OpenCL runtime components off, HIP-only workloads|
| `-DTHEROCK_ENABLE_MIOPEN_PLUGIN=OFF` | MIOpen_plugin off except explicitly required     |
| `-DTHEROCK_ENABLE_RDC=OFF`           | Enables ROCm Data Center Tool (Linux only)       |

### Clean build helper (gfx1031)

For a fresh, repeatable build (same defaults, same logs, same RAM limits), use:

```bash
./build_gfx1031.sh configure
./build_gfx1031.sh bootstrap
./build_gfx1031.sh build
```

This runs `cmake -B <builddir> -GNinja .` and then `ninja -C <builddir>` under
systemd memory limits and appends to `build.log`.

Notes:
- Configure defaults are in `config_gfx1031.yaml` (env/CLI overrides work).
- Fresh clone convenience: `configure` auto-runs `fetch_sources.py` and applies the
  minimal local patch set if submodules are missing.
- Use `--no-clean --no-check-clean` only if you *know* the build dir is still coherent.

If you’re new here, prefer the Stage‑1/Stage‑2 flow from:
**“Recommended workflow for new users (gfx1031)”**.

### Typical workflows

- reconfigure + build (clang + ninja):
  - edit `config_gfx1031.yaml`, choose which components to enable/disable.
  - then run:
```bash
./build_gfx1031.sh configure --no-clean --no-check-clean
./build_gfx1031.sh bootstrap
./build_gfx1031.sh build
```

- Clean reconfigure + build (clang + ninja):
```bash
./build_gfx1031.sh configure
./build_gfx1031.sh bootstrap
./build_gfx1031.sh build
```

- Teil-Rebuild einzelner Targets (expunge + Log-Rotation):
```bash
./build_gfx1031.sh rebuild hipBLAS rocBLAS
./build_gfx1031.sh rebuild hipSPARSE
```

- Nach dem Build: Sanity / Benchmarks / Komponenten-Smokes:
```bash
./test_gfx1031.sh              # sanity (auto-tests all detected build dirs)
./test_gfx1031.sh --bench      # quick micro-benchmarks (if installed)
./test_gfx1031.sh --bench --full # larger benchmark sizes / more iters

# MIOpen + composable_kernel checks + optional tiny smoke
./test_gfx1031.sh --miopen
./test_gfx1031.sh --miopen-smoke
```

For the full list of testing options (including consistency checks), see
**“Notes on testing”** below.

### Bootstrap (Third-party/sysdeps)

Nach dem Configure sollte einmal gebootstrapped werden, damit frühe `find_package(...)`
Auflösungen während des eigentlichen Builds nicht an fehlenden `*Config.cmake`/sysdeps scheitern:

```bash
./build_gfx1031.sh bootstrap
```

Der Bootstrap schreibt wie Configure/Build nach `build.log` (append).

Hinweis: `build_gfx1031.sh build --stage1` verweigert den Start, wenn Bootstrap für
`build-stage1/` noch nicht erfolgreich verifiziert wurde (Marker:
`build-stage1/.therock_bootstrap.ok`).

### Repeatable rebuild (with RAM limits)

Use the helper script for consistent, logged rebuilds with the same memory
limits used in this branch:

```bash
./build_gfx1031.sh rebuild <targets...>
```

Defaults use `MemoryHigh=28G` and `MemoryMax=31G`. Override if needed:

```bash
MEM_HIGH=28G MEM_MAX=31G ./build_gfx1031.sh rebuild <targets...>
```

### Build monitoring (detached)

Wenn der Build detached läuft, startet `build_gfx1031.sh` ihn als systemd user unit:

- Default `BUILD_DIR=build`: `therock-gfx1031-build-build.service`
- Stage-1: `therock-gfx1031-build-stage1-build.service`
- Stage-2: `therock-gfx1031-build-stage2-build.service`

```bash
./monitor_gfx1031.sh --once
./monitor_gfx1031.sh --interval 30
```

### monitor (5min interval, 6h dauer)

Für lange Builds kann ein 6‑Stunden Monitor als eigener systemd‑User‑Service gestartet werden.
Der Monitor pollt alle 5 Minuten und schreibt nach `monitor_6h.log`:

```bash
systemctl --user stop therock-gfx1031-monitor.service 2>/dev/null || true
test -f monitor_6h.log && mv -v monitor_6h.log "monitor_6h.log.$(date +%Y%m%d_%H%M%S)" || true
systemd-run --user --no-block --collect --unit therock-gfx1031-monitor \
  bash -lc 'cd "/media/christoph/some_space/make_my_gpu_useful/TheRock_gfx1031" && ./monitor_gfx1031.sh --interval 300 --duration 21600 >> monitor_6h.log 2>&1'
tail -f monitor_6h.log
```

Stoppen:
```bash
systemctl --user stop therock-gfx1031-build-build.service
```

Wenn der Build detached läuft, kannst du den Status über `monitor_gfx1031.sh` prüfen und bei Fehlern in `build.log` nach `FAILED:`/`CMake Error` suchen.

Wenn der Build fehlschlägt, ist die “erste echte” Fehlermeldung meist in `build.log` und zusätzlich
pro Subprojekt in `build/logs/*_build.log`.

### composable_kernel & MIOpen

- `THEROCK_MIOPEN_USE_COMPOSABLE_KERNEL` wird im Helper an `THEROCK_ENABLE_COMPOSABLE_KERNEL` gespiegelt.
- gfx1031 wird von composable_kernel nicht direkt unterstützt; MIOpen schaltet dann intern CK ab (Warnung im Configure, kein harter Fehler).
- Tests: siehe **“Notes on testing”** (`--miopen`, `--miopen-smoke`).

### Notes on testing

`./test_gfx1031.sh` has two main roles:

1) **Build validation / hygiene** (what we use during active development):
   verify the build graph is coherent (no `/opt/rocm` leakage), toolchain
   expectations match the stage, and basic runtime tools are callable.

2) **Post-build functionality checks + micro-benchmarks** (what we use once the
   build is “installed” into `<builddir>/dist/rocm`):
   run real GPU workloads via installed tools (rocBLAS/hipBLAS benches, MIOpen
   driver smoke, etc.) to confirm the built stack is usable and reasonably fast.

The script auto-activates the in-tree ROCm environment from `<builddir>/dist/rocm`
(so you don’t accidentally pick up `/opt/rocm-*`).

**Common usage:**

```bash
# Interactive bench menu (default if you run without args in a terminal)
./test_gfx1031.sh

# Sanity only (no benchmarks unless you opt-in)
./test_gfx1031.sh --no-bench

# Enable benchmarks (requires the bench binaries to exist in PATH; build them via `config_gfx1031.yaml: build.benchmarks: true`)
./test_gfx1031.sh --bench
./test_gfx1031.sh --bench --full

# Add sysfs power/util sampling (baseline + per-test metrics)
./test_gfx1031.sh --bench-lite --power

# Benchmarks only
./test_gfx1031.sh --bench-only

# Enable log files (otherwise no logs are written; useful for debugging/recordkeeping)
./test_gfx1031.sh --log --bench-only
./test_gfx1031.sh --log my_run.log --bench
```

**Build/toolchain consistency checks (recommended after reconfigure / rebuild):**

```bash
# Stage-1: allow system clang, but ensure no /opt/rocm leakage
./test_gfx1031.sh --consistency-only --expect-stage1 --stage1

# Stage-2: strict (no /usr/lib/llvm-18 fallback; no effective /opt/rocm leakage)
./test_gfx1031.sh --consistency --expect-stage2 --stage2
./test_gfx1031.sh --consistency --deep --expect-stage2 --stage2
```

**MIOpen / composable_kernel checks:**

```bash
./test_gfx1031.sh --miopen
./test_gfx1031.sh --miopen-smoke
```

**CLI options (overview):**

- Modes: `--quick` (default), `--full`
- Bench control: `--bench`, `--no-bench` (default), `--bench-only`
- Consistency: `--consistency`, `--consistency-only`, `--deep`, `--expect-stage1`, `--expect-stage2`
- Components: `--miopen`, `--miopen-smoke`
- Build dir: `--stage1`, `--stage2`, `--build-dir <dir>`

**Environment overrides (advanced):**

- `BENCH_SIZE`, `BENCH_ITERS` to control benchmark sizes/iters
- `TEST_LOG` to override output log path (default: `test_gfx1031.log`)

**Building the bench binaries (rocblas-bench / hipblas-bench):**

```bash
# 1) Edit config_gfx1031.yaml:
#    build:
#      benchmarks: true
#
# 2) Reconfigure + rebuild only what’s needed:
./build_gfx1031.sh configure --stage2 --no-clean --no-check-clean
./build_gfx1031.sh rebuild --stage2 rocBLAS hipBLAS
./build_gfx1031.sh build --stage2 dist-rocm
```

Notes:
- The bench binaries link a **host reference BLAS** from `host-blas` (OpenBLAS in `lib/host-math/lib`). Running via `./test_gfx1031.sh` is recommended because it auto-sets `LD_LIBRARY_PATH` appropriately.
- `dist-rocm` updates `<builddir>/dist/rocm/bin` so the bench binaries are in `PATH` for `./test_gfx1031.sh`.

**Bench tools you may have in Stage‑2 (`build-stage2/dist/rocm/bin`)** (numbered for easy reference):

1) `rocblas-bench` — rocBLAS (BLAS) benchmark client  
2) `hipblas-bench` — hipBLAS (BLAS) benchmark client  
3) `rocsolver-bench` — rocSOLVER (LAPACK/solver) benchmark client  
4) `hipsolver-bench` — hipSOLVER (LAPACK/solver) benchmark client  
5) `rocsparse-bench` — rocSPARSE benchmark client  
6) `hipsparse-bench` — hipSPARSE benchmark client  
7) `rocfft-bench` — rocFFT benchmark client  
8) `dyna-rocfft-bench` — rocFFT dynamic loader benchmark client  
9) `benchmark_rocrand_*` — rocRAND micro-benchmarks (multiple executables)

Note: `./test_gfx1031.sh --bench` runs the full “quick” bench suite (skipping missing tools) and reports key throughput metrics when available. Use `./test_gfx1031.sh --bench-lite` to run only rocBLAS+hipBLAS GEMM.

`hipinfo` note: On Linux, TheRock does not typically ship a `hipinfo` executable (the `core-hipinfo` artifact is windows-only). Use `rocminfo` + `./test_gfx1031.sh --consistency --expect-stage2` to validate the HIP toolchain/device libs instead.

### Phase 1 vs Phase 2 (rocprofiler-systems)

- **Phase 1 (default in helpers):** ROCm stack stabil bauen, `THEROCK_ENABLE_ROCPROFSYS=OFF`.
- **Phase 2 (optional):** `rocprofiler-systems` separat mit GCC bauen/installen via:
  ```bash
  ./build_gfx1031.sh rocprofiler-gcc
  ```

### Environment activation (in-tree ROCm)

After a successful build, you can run tools against the in-tree ROCm install
under `<builddir>/dist/rocm` by setting:

```bash
BUILD_DIR=build-stage2
export ROCM_PATH="$PWD/$BUILD_DIR/dist/rocm"
export PATH="$ROCM_PATH/bin:$ROCM_PATH/llvm/bin:$PATH"
export LD_LIBRARY_PATH="$ROCM_PATH/lib:$ROCM_PATH/lib64:$ROCM_PATH/lib/host-math/lib:$ROCM_PATH/lib/rocm_sysdeps/lib:$ROCM_PATH/llvm/lib:${LD_LIBRARY_PATH:-}"
```

Notes:
- `./test_gfx1031.sh` performs this activation automatically (based on `BUILD_DIR`), and is the simplest way to run sanity/benchmarks.
- If you don’t pass `--stage1/--stage2/--build-dir`, the script tests all detected in-tree dist roots for sanity/consistency (prefers `build-stage2`, then `build`, then `build-stage1`). For `--bench/--bench-only`, it defaults to Stage‑2 if available.

### Optional: run sanity inside an ROCm dev container

If you want to validate that **your in-tree Stage‑2 dist** works in a clean userland (and that it is not accidentally
depending on host `/opt/rocm`), you can mount the repo into an ROCm dev image and run `./test_gfx1031.sh` there.

Recommended helper:

```bash
# Sanity inside container + drop into an interactive shell afterwards:
./run_rocm_container.sh --stage2

# Benchmarks (if built) inside container:
./run_rocm_container.sh --stage2 --bench

# Exit after tests (no shell):
./run_rocm_container.sh --stage2 --no-shell
```

Notes:
- The container run passes through `/dev/kfd` and `/dev/dri` and adds the `video`/`render` groups.
- `./test_gfx1031.sh` automatically **skips** activating the repo `.venv` when it detects a container (to avoid ABI mismatches). Override with `THEROCK_FORCE_VENV=1` or disable explicitly with `TEST_SKIP_VENV=1`.
- Your in-tree `dist/rocm` is linked against your host userland (glibc/libstdc++). If the container base is too old, you can get errors like `GLIBC_2.38 not found`.
  In that case, use a newer ROCm dev image (e.g. Ubuntu 24.04): `./run_rocm_container.sh --image rocm/dev-ubuntu-24.04:latest ...`.

### Optional: compare performance (host vs container)

If you want a quick sanity check that performance is comparable between your host userland and a clean ROCm dev container,
run:

```bash
# Default: bench-lite (rocBLAS + hipBLAS GEMM), Stage-2.
./compare_perf_gfx1031.sh

# Full bench set (can take longer):
./compare_perf_gfx1031.sh --bench

# Override docker image (useful for glibc compatibility):
./compare_perf_gfx1031.sh --image rocm/dev-ubuntu-24.04:latest
```

This writes logs under `./perf_compare/<timestamp>/` and prints a side-by-side TFLOPS comparison.

Notes:
- The container run installs a minimal runtime dep (`libgfortran5`) because some bench clients link it dynamically. Disable via `./compare_perf_gfx1031.sh --no-install-deps`.
- By default, `compare_perf_gfx1031.sh` enables `--power` and prints avgW + gpu% next to TFLOPS. Disable via `./compare_perf_gfx1031.sh --no-power`.

### Optional: Upstream test suites (ctest / gtest clients)

Project-wide testing can be controlled with the standard CMake `-DBUILD_TESTING=ON|OFF` flag.
- default: `BUILD_TESTING=OFF` (in `config_gfx1031.yaml` oder via `ENABLE_BUILD_TESTING=true` env überschreibbar).

This gates both setup of build tests and compilation of installed testing artifacts. 

Tests of the integrity of the build are enabled by default and can be run
with ctest:

```bash
ctest --test-dir build-stage2
```

Note: gtest-style client test binaries such as `rocsolver-test` are not built/installed by default in this branch configuration (we optimize for a usable ROCm stack + benchmarks). If you enable full testing, you can run client tests via their `--gtest_filter` options (see upstream component docs).
