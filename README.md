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
  - `install_to_opt.sh` (optional: mirror dist to `/opt/rocm`)
  - `install_pytorch_rocm711.sh` (optional: install custom PyTorch wheel to a venv)

## System requirements

### Kernel / driver / permissions
- Ensure the ROCm kernel interfaces are present:
  - `/dev/kfd` and `/dev/dri` should exist.
- Ensure your user can access the GPU:
  - membership in `video` and `render` groups is commonly required.
### OpenCL (DaVinci Resolve)

DaVinci Resolve uses **OpenCL** on AMD GPUs. If Resolve does not detect your GPU, first verify:
```bash
clinfo | head -n 40
```
Expected: **Number of platforms > 0** and an AMD GPU device.

This repo can build the AMD OpenCL runtime (`features.enable_ocl_runtime: true`). A system-wide install via
`install_to_opt.sh` also installs `/etc/OpenCL/vendors/amdocl64.icd` so OpenCL apps can find the platform.

### Build tools (host)

Ubuntu (recommended baseline):
```bash
sudo apt update
sudo apt install -y \
  build-essential git pkg-config \
  ca-certificates curl \
  python3 python3-venv \
  cmake ninja-build \
  clang-18 lld-18 \
  ccache
```

Notes:
- For the full workload validation (`validation/`, default `all`), also install:
  ```bash
  sudo apt install -y ffmpeg docker.io
  ```
- If you install docker: ensure your user can run it (e.g. `sudo usermod -aG docker $USER`, then re-login).

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

Thorough host run (full suite, power, logs):
```bash
./test_gfx1031.sh --build-dir build-stage2 --consistency --miopen --miopen-smoke --bench --full --log test_gfx1031.stage2.full.log
```

## Docker comparison: `test_docker_gfx1031.sh`

This script runs the same bench suite against the in-tree dist:
- on the **host**
- inside a **ROCm docker image** with `/dev/kfd` and `/dev/dri` passed through

```bash
./test_docker_gfx1031.sh
```

Host vs docker (keeps captured output under `perf_compare/<timestamp>/`):
```bash
./test_docker_gfx1031.sh --build-dir build-stage2 --full --consistency --miopen --miopen-smoke --keep-logs
```

Note: the docker image is used as a runtime container; host-build-tool presence checks (`cmake`, `ninja`, `ccache`) may show as missing inside the container unless you install them there.

## Validation suite (apps + ROCm usability): `validation/`

The validation suite proves that the in-tree ROCm stack is usable **before** any system install.
It runs sustained GPU tests with optional power sampling.

Start here:
```bash
python3 validation/scripts/validate.py
```

The validation scripts auto-create and manage a repo-local Python venv under `validation/workspace/` (no manual activation required).

Validation profiles:
- `all` (default): enables everything (ROCm benches + MIOpen + all workloads incl. Whisper/MFEM/PETSc/PyTorch/llama.cpp/Ollama) and prompts once before downloads
- `quick`: ROCm env + power baseline + `rocminfo` + HIP compile+run (no downloads)
- `full`: adds representative workloads (docker/pip/build) and prompts once before downloads
- Focused: `llama_cpp`, `ollama`, `whisper`, `mfem`, `pytorch`, `petsc`
- PyTorch (ROCm 7.11, source build): `pytorch_rocm711_source` (very heavy; builds `torch` from source against the in-tree dist under `<builddir>/dist/rocm`)

Note: the default `all` profile builds a ROCm 7.11-aligned PyTorch wheel from source (slow) to avoid accidental
CPU fallback due to mismatched ROCm wheel channels. If you want a faster PyTorch check, use `--profile pytorch`.
Also note: `torch.version.hip` is the HIP toolchain version (e.g. 7.2.x), while `torch.version.rocm` is the ROCm release (e.g. 7.11.x).

Examples:
```bash
python3 validation/scripts/validate.py --profile quick --no-downloads
python3 validation/scripts/validate.py --profile all --yes --power --log
```

See `validation/README.md` for full details, configuration, and per-workload one-shot validators.

Example full regression run (with logs):
```bash
# Host tests (writes test_gfx1031.stage2.full.log):
./test_gfx1031.sh --build-dir build-stage2 --consistency --miopen --miopen-smoke --bench --full --log test_gfx1031.stage2.full.log

# Host vs docker comparison (writes perf_compare/<timestamp>/):
./test_docker_gfx1031.sh --build-dir build-stage2 --full --consistency --miopen --miopen-smoke --keep-logs

# Full workload validation (writes validation/workspace/runs/<run_id>/logs/):
python3 validation/scripts/validate.py --profile all --yes --power --summary-multiline --log
```

## Latest known-good run (example)

This section documents a recent, complete end-to-end run to serve as a **baseline**.
Numbers depend on GPU/driver/kernel and will vary, but **GPU usage should be obvious**
from `dW` (power delta) and `gpu%`.

### 2026-02-08 (PyTorch ROCm 7.11 source build, RX 6700 XT / gfx1031)

Command used:
- `./test_gfx1031.sh --build-dir build-stage2 --consistency --miopen --miopen-smoke --bench --full --log test_gfx1031.stage2.full-2026-02-08.log`
- `python3 validation/scripts/validate.py --profile pytorch_rocm711_source --build-dirs build-stage2 --yes --power --log`

Artifacts (local):
- Host test log: `test_gfx1031.stage2.full-2026-02-08.log`
- Validation report: `validation/workspace/runs/2026-02-08_050854/report.json`
- Validation logs: `validation/workspace/runs/2026-02-08_050854/logs/`

Key results (`pytorch_rocm711_source`, `build-stage2`):
- ROCm sanity:
  - Power idle baseline (5s): OK (`avgW≈5.9W`, `gpu%≈1`)
  - HIP compile+run: OK (`avgW≈107W`, `dW≈+101W`, `gpu%≈87`)
- ROCm micro-bench suite (sustained per-test power sampling):

| Bench | Time | Perf | Energy | avgW | maxW | dW | gpu% | mem% |
|---|---:|---|---:|---:|---:|---:|---:|---:|
| rocBLAS GEMM f32 | 7.245s | `TFLOPS≈11.142` | 0.281Wh | 139.4W | 202.0W | +121.4W | 70 | 2 |
| hipBLAS GEMM f32 | 8.071s | `TFLOPS≈11.191` | 0.276Wh | 125.5W | 200.0W | +107.8W | 60 | 1 |
| rocSOLVER geqrf_strided_batched (d) | 6.837s | `gpu_time_us≈1014218` | 0.162Wh | 85.5W | 177.0W | +66.7W | 48 | 5 |
| hipSOLVER (tiny solver) | 7.898s | — | 0.152Wh | 69.2W | 161.0W | +51.7W | 39 | 1 |
| rocSPARSE axpyi (d) | 5.041s | `GB/s≈346.55, GFLOP/s≈24.75` | 0.180Wh | 126.8W | 142.0W | +109.4W | 85 | 24 |
| hipSPARSE axpyi (d) | 5.061s | `GB/s≈358.39, GFLOP/s≈25.60` | 0.186Wh | 131.2W | 144.0W | +113.4W | 88 | 32 |
| rocFFT complex fwd (524288, batch=4, d) | 4.136s | `ms≈0.60496` | 0.157Wh | 138.6W | 161.0W | +120.8W | 84 | 16 |
| dyna-rocFFT complex fwd (524288, batch=4, d) | 4.414s | `ms≈0.603719` | 0.164Wh | 131.1W | 162.0W | +113.6W | 82 | 16 |
| rocRAND generate (philox, uniform-float) | 5.458s | `GB/s≈313.161, GSample/s≈78.29` | 0.272Wh | 176.2W | 191.0W | +157.1W | 93 | 38 |
- PyTorch (built from source vs in-tree ROCm 7.11):
  - audio: OK (`tflops_est≈9.83`, `avgW≈178W`, `dW≈+172W`, `gpu%≈85`)
  - video: OK (`tflops_est≈2.90`, `avgW≈201W`, `dW≈+195W`, `gpu%≈97`)

Versions (selected, from the in-tree Stage‑2 dist):

| Component | Version |
|---|---|
| ROCm dist (`rocm-core`) | `7.11.0` |
| LLVM / Clang / LLD | `22.0.0git` |
| HIP / hip-lang / hiprtc | `7.2.53150` |
| `amd_comgr` | `3.0.0` |
| `hsa-runtime64` | `1.18.0` |
| `hsakmt` | `7.3.53390-…-g1cedb43795` |
| rocBLAS / hipBLAS / hipBLASLt | `5.3.0` / `3.3.0` / `1.2.0` |
| rocSOLVER / hipSOLVER | `3.32.0` / `3.2.0` |
| rocSPARSE / hipSPARSE | `4.3.0` / `4.3.0` |
| rocFFT / hipFFT | `1.0.36` / `1.0.22` |
| rocRAND / hipRAND | `4.2.0` / `3.1.0` |
| MIOpen / RCCL | `3.5.1` / `2.27.3` |
| rocPRIM / rocThrust / hipCUB | `4.2.0` / `4.2.0` / `4.2.0` |
| composable_kernel / rocroller | `1.2.0` / `1.0.0` |
| rocprofiler-sdk / rocprofiler-register | `1.1.0` / `0.6.0` |
| roctracer64 / roctx64 | `4.1.0` (from library SONAME) |

PyTorch (built from source against the in-tree dist):
- `torch`: `2.11.0a0+git3b6829f`
- `torch.version.rocm`: `7.11.0`
- `torch.version.hip`: `7.2.53150`
- venv Python: `3.12.3`

Where this is recorded:
- ROCm dist version: `build-stage2/dist/rocm/.info/version`
- Per-package versions: `build-stage2/dist/rocm/lib/cmake/<pkg>/*ConfigVersion.cmake`
- roctracer/roctx SONAME: `build-stage2/dist/rocm/lib/libroctracer64.so.*`, `build-stage2/dist/rocm/lib/libroctx64.so.*`
- PyTorch build marker: `validation/workspace/cache/wheels/pytorch_rocm711/BUILD_INFO.json`

### 2026-02-02 (RX 6700 XT / gfx1031)

Commands used:
- `./test_gfx1031.sh --build-dir build-stage2 --consistency --miopen --miopen-smoke --bench --full --log test_gfx1031.stage2.full.log`
- `./test_docker_gfx1031.sh --build-dir build-stage2 --full --consistency --miopen --miopen-smoke --keep-logs`
- `python3 validation/scripts/validate.py --profile all --yes --power --summary-multiline --log`

Artifacts:
- Host test log: `test_gfx1031.stage2.full.log`
- Validation report (local): `validation/workspace/runs/2026-02-02_003528/report.json`
- Validation logs (local): `validation/workspace/runs/2026-02-02_003528/logs/`

Key validation results (`--profile all`, `build-stage2`):
- ROCm sanity:
  - `rocminfo`: OK
  - HIP compile+run: OK (`avgW≈113W`, `dW≈+94W`, `gpu%≈87`)
- ROCm bench smoke (~5s sustained per test):
  - rocBLAS GEMM f32: `TFLOPS≈11.2` (`avgW≈129W`, `dW≈+110W`, `gpu%≈62`)
  - rocFFT: OK (`avgW≈139W`, `dW≈+120W`, `gpu%≈88`)
  - rocRAND generate: OK (`avgW≈183W`, `dW≈+164W`, `gpu%≈91`)
- MIOpen:
  - driver present + smoke: OK (`avgW≈162W`, `dW≈+143W`, `gpu%≈72`)
- LLMs:
  - llama.cpp (docker): OK (`pp_tok/s≈1723`, `tg_tok/s≈98`, `avgW≈132W`, `dW≈+113W`, `gpu%≈74`)
  - Ollama (docker ROCm): OK (`tok/s≈135`, `ttft≈232ms`, `avgW≈105W`, `dW≈+86W`, `gpu%≈62`)
- Speech:
  - Whisper (python, 300s audio): OK (`words=268`, `w/s≈2.38`, `rtf≈0.375`, `avgW≈92W`, `dW≈+73W`, `gpu%≈87`)
- FEM / solvers:
  - MFEM (HIP): OK (`ndofs≈802k`, `apply/s≈867`, `avgW≈155W`, `dW≈+136W`, `gpu%≈89`)
  - PETSc (HIP): OK (`matmult/s≈9177`, `avgW≈120W`, `dW≈+101W`, `gpu%≈64`)
- PyTorch:
  - audio: OK (`it/s≈66.9`, `tflops_est≈9.5`, `avgW≈155W`, `dW≈+136W`, `gpu%≈71`)
  - video: OK (`it/s≈72.1`, `tflops_est≈3.2`, `avgW≈183W`, `dW≈+164W`, `gpu%≈85`)

Reproducibility notes:
- MFEM is pinned to `v4.9` and PETSc to `v3.24.2` in the validation defaults.
- Whisper "long audio" is generated at runtime via `ffmpeg` (no large WAV is committed).
- `perf_compare/` is intentionally not tracked (captured docker vs host logs).

## Optional: system-wide install (/opt/rocm)

The intended workflow is **in-tree** (no system install). If you want a system-wide prefix anyway,
use `install_to_opt.sh` to mirror the Stage‑2 dist to `/opt/rocm`.

```bash
# Builds are incremental; ensure Stage‑2 dist exists first:
./build_gfx1031.sh build --stage2

# Install to /opt/rocm (prompts once, uses rsync, sets ldconfig paths):
./install_to_opt.sh --build-dir build-stage2 --prefix /opt/rocm
```

`install_to_opt.sh` also (best-effort) copies the custom PyTorch wheel (if present) to:
`/opt/rocm/wheels/pytorch_rocm711/`.

### Install the custom PyTorch (ROCm 7.11, built from source)

The validation suite can build a custom `torch` wheel against the in-tree ROCm 7.11 dist.
To install that wheel into a user venv (recommended), use:

```bash
./install_pytorch_rocm711.sh --rocm-prefix /opt/rocm
```

If the wheel is missing, build it first:
```bash
python3 validation/scripts/validate.py --profile pytorch_rocm711_source --build-dirs build-stage2 --yes --power --log
```

### Using ROCm 7.11 PyTorch in new Python projects (recommended)

To ensure you **always** use the custom ROCm 7.11 wheel (and never accidentally install a
different ROCm/CUDA/CPU build), pin `torch` to the local wheel path in your project:

Example `requirements.txt`:
```txt
torch @ file:///opt/rocm/wheels/pytorch_rocm711/torch-2.11.0a0+git3b6829f-cp312-cp312-linux_x86_64.whl
numpy
```

Install:
```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -U pip
python -m pip install -r requirements.txt
```

GPU smoke:
```bash
python -c "import torch; print(torch.__version__); print(torch.version.rocm); print(torch.cuda.is_available())"
```

Concrete working example project:
- `/media/christoph/some_space/rocm711_torch_example`

## TODO

- Expand validation workloads (audio/video LLMs, additional scientific solvers) with pinned versions and clear size policies.
- Add optional CI-friendly report formats (JUnit/HTML) for `validation/`.
