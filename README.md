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
  - llama.cpp server integration with ROCm backend ?ToDo?
  - Ollama with ROCm support ?ToDo?
  - Open Interpreter configuration and best practices ?ToDo?
  - Automated Python package update tooling ?ToDo?
- **Real-world testing** on Mint with AMD RX 6700 XT

### Quick Start for This Build

```bash
# Clone this branch
git clone -b hashcat/rocm-7.11-gfx103X git@github.com:ChristophBellmann/TheRock_gfx1031.git
cd TheRock_gfx1031

# Setup virtual environment
python3 -m venv .venv && source .venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt

# Fetch sources
python3 ./build_tools/fetch_sources.py
```

### Clean configure helper (gfx1031)

For a fresh, repeatable configure that checks the build directory is clean,
use:

```bash
./configure_gfx1031.sh
```

It uses the recommended gfx1031 profile (LLM/Vision/Audio), enables ccache, and
applies the same RAM limits. Host compiler is set to `clang/clang++` (avoid
GCC/clang mix) and builds run via `ninja` (no `cmake --build`). The helper also
ensures a consistent Python/ccache/compiler environment (see below).

Compared to calling `cmake -B build -GNinja .` directly, the helper script mainly
adds **repeatability** and **guard rails**:

- Applies the repo's **gfx1031 build profile** (`THEROCK_ENABLE_*`, `BUILD_TESTING`, `THEROCK_ENABLE_ROCPROFSYS=OFF`, `THEROCK_ENABLE_COMPOSABLE_KERNEL=ON`, targets/dist bundle).
- Enforces **clang/clang++** as host compiler (avoid GCC/clang mixing and GCC ICE issues).
- Ensures a working **Python venv** (`.venv`) so build tools run consistently.
- Enables/configures **ccache** via `build_tools/setup_ccache.py`.
- Runs configure under the same **systemd memory limits** used for builds and logs to `build.log`.
- Avoids accidental **system ROCm toolchain mixing** (`CMAKE_HIP_COMPILER` only set if `./install/bin/hipcc` exists).

If `hipcc/amdclang++` is not found yet, the script prints a **WARNING** (this is
expected in a clean bootstrap: hipcc only exists after the toolchain build
installs into `./install`).

Default behavior is a **clean configure**: it removes `build/` before running
CMake. Use `--no-clean` if you explicitly want to reconfigure in-place.

### What `cmake -B build -GNinja .` actually does (ASCII overview)

```text
User cmd
  cmake -S . -B build -G Ninja  [ + -D... cache args ]
    |
    v
(1) CMake reads + initializes
    - ./CMakeLists.txt
        - sets up project + cmake module path
        - includes cmake/*.cmake modules (superbuild machinery)
        - runs python/topology generation
        - defines/validates THEROCK_ENABLE_* feature flags
        - declares subprojects (configure/build/stage/dist phases)
        - emits Ninja rules + per-subproject helper files

    - ./cmake/*.cmake (key roles)
        - cmake/therock_python_setup.cmake
            - find Python3 interpreter
            - runs build_tools/topology_to_cmake.py to generate:
              build/cmake/therock_topology.cmake
        - cmake/therock_features.cmake + cmake/therock_feature_groups.cmake
            - defines THEROCK_ENABLE_* and dependencies between features
        - cmake/therock_subproject.cmake
            - declares each subproject as a DAG of phase targets:
              <name>+configure -> <name>+build -> <name>+stage -> <name>+dist
            - writes per-subproject:
              build/<...>/_init.cmake (dep provider + env glue)
              build/<...>/_toolchain.cmake (compiler/toolchain settings)
        - cmake/therock_job_pools.cmake
            - configures Ninja JOB_POOLS (BACKGROUND_BUILD)
        - cmake/therock_bundled_sysdeps.cmake
            - wires sysdeps (zlib/zstd/…) as deps and RPATH inputs

    - ./BUILD_TOPOLOGY.toml
        - source of truth for artifacts/features/grouping

    - ./version.json + ./rocm-systems/projects/hip/VERSION
        - sets ROCm + HIP version values used across the build

    - ./build_tools/*.py
        - topology_to_cmake.py: generates build/cmake/therock_topology.cmake
        - teatime.py: log wrapper used in generated build rules
        - fileset_tool.py: copies stage -> dist, assembles artifacts

    - ./rocm-libraries/** and ./rocm-systems/**
        - sources for ROCm components (must exist beforehand)

    |
    v
(2) Configure output (what you get in build/)
    - build/CMakeCache.txt
        - saved cache variables (all -D options, detected tools, etc.)
    - build/build.ninja
        - Ninja build graph for the superbuild
    - build/cmake/therock_topology.cmake
        - auto-generated from BUILD_TOPOLOGY.toml
    - build/**/_init.cmake + build/**/_toolchain.cmake
        - generated per subproject; injected into subproject configures

    |
    v
(3) Next command (actual compilation)
    ninja -C build
      - executes the graph from build/build.ninja:
        for each subproject:
          configure (cmake -S src -B subbuild ...)
          build     (cmake --build subbuild)
          stage     (cmake --install ...)
          dist      (fileset_tool.py copy stage -> dist)

Result of the *cmake configure step alone*
  -> No compilation yet.
  -> You end up with a generated Ninja build system in `build/`.
```

### Clean bootstrap helper (gfx1031)

After configuring, run a one-time bootstrap step to build and stage the
third‑party/sysdeps bits that tend to be needed early (so later parallel
subproject configures don’t fail on missing `*Config.cmake` or sysdeps libs):

```bash
./bootstrap_gfx1031.sh
```

It uses `ninja` under the same systemd RAM limits, appends to `build.log`, and
prepares a minimal set of `+stage` targets (sysdeps + host tools + host-blas)
so `find_package(...)` resolution in subsequent projects can succeed reliably.

### HIP compiler (hipcc/amdclang++)

Ja: für HIP-Projekte wird sichergestellt, dass **nicht GCC** und **nicht ein beliebiges system-weites ROCm** verwendet wird.

- **Innerhalb des TheRock-Superbuilds:** HIP-lastige Subprojekte deklarieren explizit `COMPILER_TOOLCHAIN amd-hip` (siehe z. B. `math-libs/BLAS/CMakeLists.txt`). Dadurch wird die in-tree Toolchain aus `amd-llvm`/`hip-clr` verwendet (inkl. `--hip-path`/Device Libs) – unabhängig davon, ob ein system-weites `hipcc` existiert.
- **Für CMake-HIP-Language Projekte (falls verwendet):** `configure_gfx1031.sh` setzt `CMAKE_HIP_COMPILER` **nur**, wenn `./install/bin/hipcc` existiert. Es wird **nicht** automatisch auf `/opt/rocm/bin/hipcc` zurückgefallen (vermeidet ABI/Version-Mix).
- **Für externe Builds (PyTorch/Whisper/etc):** nach dem Build `source ./rocm-env-therock.sh` ausführen; das setzt `PATH` so, dass das in-tree `hipcc`/`amdclang++` bevorzugt wird.

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

### Profile: LLM + Vision + Audio (Ollama / Mistral / Qwen / PyTorch / Whisper)

Target workloads: general language models, vision/video LLMs, and audio models
with best performance on gfx1031. This profile keeps the HIP toolchain and the
core math/ML stack needed by PyTorch and LLM runtimes, while dropping unrelated
features.

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

For a fresh, repeatable full build that checks the build directory is clean,
use the helper script:

```bash
./build_gfx1031.sh
```

It uses the recommended gfx1031 profile (LLM/Vision/Audio), enables ccache, and
applies the same RAM limits. Host compiler is set to `clang/clang++` and builds
run via `ninja` (no `cmake --build`). If
`build/` already exists and is not empty, the script will stop unless you pass
`--clean` (delete `build/`) or `--no-check-clean` (skip the clean check).

### Typical workflows

- reconfigure + build (clang + ninja):
  - edit configure_gfx1031.sh, choose which component to set/unset.
  - then run:
```bash
./configure_gfx1031.sh 
./bootstrap_gfx1031.sh
./build_gfx1031.sh
```
- Clean reconfigure + build (clang + ninja):
  ```bash
  ./configure_gfx1031.sh
  ./bootstrap_gfx1031.sh
  ./build_gfx1031.sh
  ```
- Clean build in einem Schritt (configure + build):
  ```bash
  ./build_gfx1031.sh --clean
  ```
- Teil-Rebuild einzelner Targets (expunge + Log-Rotation):
  ```bash
  ./rebuild_gfx1031_subprojects.sh hipBLAS rocBLAS
  ./rebuild_gfx1031_subprojects.sh --no-expunge hipSPARSE
  ```
- Nach dem Build: Sanity + Benchmarks:
  ```bash
  ./test_gfx1031.sh        # quick
  ./test_gfx1031.sh --full # längere Bench
  ```

### CCache defaults

- Du brauchst ein aktuelles ccache (>= 4.11), damit Device-Code Caching mit `--offload-compress` zuverlässig funktioniert (große AMDGPU Artefakte).
- `.local/bin/ccache` (4.11.1) wird automatisch vorangestellt, wenn vorhanden.
- `configure_gfx1031.sh` **und** `build_gfx1031.sh` evaluiert `build_tools/setup_ccache.py` automatisch (setzt `CCACHE_CONFIGPATH` auf `./.ccache/ccache.conf`).
- `setup_ccache.py` setzt dabei u. a.:
  - `sloppiness = include_file_ctime` (entspricht dem empfohlenen `export CCACHE_SLOPPINESS=include_file_ctime` für Hardlink-Farms)
  - ein sicheres `compiler_check` (wichtig bei Compiler-Bootstrapping, damit Cache-Einträge nicht “falsch” wiederverwendet werden)
- In CMake wird ccache als Launcher gesetzt: `-DCMAKE_C_COMPILER_LAUNCHER=ccache` und `-DCMAKE_CXX_COMPILER_LAUNCHER=ccache`.
- Für manuelle Nutzung in neuen Shells: `eval "$(./build_tools/setup_ccache.py)"`.

### Bootstrap (Third-party/sysdeps)

Nach dem Configure sollte einmal gebootstrapped werden, damit frühe `find_package(...)`
Auflösungen während des eigentlichen Builds nicht an fehlenden `*Config.cmake`/sysdeps scheitern:

```bash
./bootstrap_gfx1031.sh
```

`bootstrap_gfx1031.sh` schreibt wie Configure/Build nach `build.log` (append).

### Build monitoring (detached)

Wenn der Build detached als `therock-gfx1031-build.service` läuft:

```bash
./monitor_gfx1031.sh --once
./monitor_gfx1031.sh --interval 30
```

### 6h monitor (5min interval)

Für lange Builds kann ein 6‑Stunden Monitor als eigener systemd‑User‑Service gestartet werden.
Das ist bewusst “detached”, weil eine interaktive Session nicht 6 Stunden “wach” bleiben kann.
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
systemctl --user stop therock-gfx1031-build.service
```

Wenn der Build endet (success/fail), schreibt `build_gfx1031.sh --detach` automatisch eine Zusammenfassung nach `build_result.txt`.

Wenn der Build fehlschlägt, ist die “erste echte” Fehlermeldung meist in `build.log` und zusätzlich
pro Subprojekt in `build/logs/*_build.log`.

### composable_kernel & MIOpen

- `THEROCK_MIOPEN_USE_COMPOSABLE_KERNEL` wird im Helper an `THEROCK_ENABLE_COMPOSABLE_KERNEL` gespiegelt.
- gfx1031 wird von composable_kernel nicht direkt unterstützt; MIOpen schaltet dann intern CK ab (nur Warnung im Configure, kein Fehler).

### Notes on testing

- `configure_gfx1031.sh` default: `BUILD_TESTING=OFF` (kann per `ENABLE_BUILD_TESTING=true` im Script oder `-- -DBUILD_TESTING=ON` überschrieben werden). Hintergrund: gcc‑ICEs vermeiden; clang wird als Host-Compiler erzwungen.

### Phase 1 vs Phase 2 (rocprofiler-systems)

- **Phase 1 (default in helpers):** ROCm stack stabil bauen, `THEROCK_ENABLE_ROCPROFSYS=OFF`.
- **Phase 2 (optional):** `rocprofiler-systems` separat mit GCC bauen/installen via:
  ```bash
  ./configure_build_rocprofiler.sh
  ```

### Quick test helper (gfx1031)

After a build, you can run basic sanity checks plus a lightweight GEMM
benchmark (with approximate TFLOPS extraction) using:

```bash
./test_gfx1031.sh
```

Use `--full` for a longer benchmark run, `--no-bench` to skip performance
tests, or `--bench-only` to run benchmarks only. Output is summarized on
stdout and saved to `test_gfx1031.log`.

### Environment activation (in-tree ROCm)

After a successful build, you can source the helper to run tools against the
in-tree ROCm install at `build/dist/rocm`:

```bash
source ./rocm-env-therock.sh
```

Notes:
- This helper is intended for running tools/tests against the built tree.
  It will fail if `build/dist/rocm` does not exist yet.
- For building, just activate the virtualenv (`source .venv/bin/activate`);
  `rocm-env-therock.sh` will do that automatically when present, but it is not
  required for CMake itself.

### Repeatable rebuild (with RAM limits)

Use the helper script for consistent, logged rebuilds with the same memory
limits used in this branch:

```bash
./rebuild_gfx1031_subprojects.sh <targets...>
```

Defaults use `MemoryHigh=28G` and `MemoryMax=31G`. Override if needed:

```bash
MEM_HIGH=28G MEM_MAX=31G ./rebuild_gfx1031_subprojects.sh <targets...>
```

### Running tests ?

Project-wide testing can be controlled with the standard CMake `-DBUILD_TESTING=ON|OFF` flag.
This gates both setup of build tests and compilation of installed testing artifacts. 

Tests of the integrity of the build are enabled by default and can be run
with ctest:

```bash
ctest --test-dir build
```
