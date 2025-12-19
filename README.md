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
GCC/clang mix) and builds run via `ninja` (no `cmake --build`). If
`build/` already exists and is not empty, the script will stop unless you pass
`--clean` (delete `build/`) or `--no-check-clean` (skip the clean check).

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
- Profiler (`ROCPROFV3`/`ROCPROFSYS`) and tests (`BUILD_TESTING`)
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
  -DBUILD_TESTING=ON
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

- Clean reconfigure + build (clang + ninja):
  ```bash
  ./configure_gfx1031.sh --clean
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

```
ctest --test-dir build
```

### CCache usage on Linux

To build with the ccache compiler cache:

* You must have a recent ccache (>= 4.11 recommended; helpers currently work with 4.9.1 but upgrade for `--offload-compress`).
* export CCACHE_SLOPPINESS=include_file_ctime to support hard-linking
* Proper setup of the compiler_check directive to do safe caching in the presence of compiler bootstrapping
* Set the C/CXX compiler launcher options to cmake appropriately.

The helper scripts (`configure_gfx1031.sh`, `build_gfx1031.sh`, `rebuild_gfx1031_subprojects.sh`) prepend the in-tree
`.local/bin` (ccache 4.11.1) when present and set `CMAKE_*_COMPILER_LAUNCHER=ccache`.
Run `./build_tools/setup_ccache.py` once per shell/session to export the recommended env
(or configure ccache manually).

Example:

# Any shell used to build must eval setup_ccache.py to set environment variables.
eval "$(./build_tools/setup_ccache.py)"
systemd-run --user --scope -p MemoryHigh=28G -p MemoryMax=31G   cmake -B build -GNinja -DTHEROCK_AMDGPU_TARGETS=gfx1031 \
  -DCMAKE_C_COMPILER_LAUNCHER=ccache \
  -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
  .

systemd-run --user --scope -p MemoryHigh=28G -p MemoryMax=31G   cmake --build build
