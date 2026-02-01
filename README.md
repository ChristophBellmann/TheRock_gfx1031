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

The validation scripts auto-create and manage a repo-local Python venv under `validation/workspace/` (no manual activation required).

Validation profiles:
- `all` (default): enables everything (ROCm benches + MIOpen + all workloads incl. PyTorch + PETSc) and prompts once before downloads
- `quick`: ROCm env + power baseline + `rocminfo` + HIP compile+run (no downloads)
- `full`: adds representative workloads (docker/pip/build) and prompts once before downloads
- Focused: `llama_cpp`, `ollama`, `whisper`, `mfem`, `pytorch`, `petsc`

Examples:
```bash
python3 validation/scripts/validate.py --profile quick --no-downloads
python3 validation/scripts/validate.py --profile all --yes --power --log
```

See `validation/README.md` for full details, configuration, and per-workload one-shot validators.


### Validation Christophs PC:

christoph@christoph-Produktion:/media/christoph/some_space/make_my_gpu_useful/TheRock_gfx1031$ python3 validation/scripts/validate.py
Validation profile: all
Build dirs: build-stage2

May download/build (if enabled):
- llama.cpp (docker image) + GGUF model: https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf
- Ollama (download or docker) + model: llama3.2:3b-instruct-q4_0
- Open Interpreter (pip install)
- Whisper (pip install) + model: base (audio_target_s=300)
- MFEM source clone + HIP build (ref=v4.9)
- PyTorch (pip install ROCm wheels): ['torch']
- PETSc source clone + HIP build (ref=v3.24.2)

Download limits: max_total=8GB, max_single=4GB (best-effort)
Proceed? [Y/n] 

==== validation summary ====
-- build dir: build-stage2
- ROCm env activation      OK (    0ms)  ROCM_PATH=/media/christoph/some_space/make_my_gpu_useful/TheRock_gfx1031/build-stage2/dist/rocm
- Power idle baseline      OK ( 5.000s)                                                                                                            |  E=  85Ws  avgW=  18.8W  dW=   n/a  maxW=  19.0W  gpu%=  2  mem%=  0
- rocminfo                 OK (   36ms)
- hipcc compile+run        OK ( 5.288s)                                                                                                            |  E= 413Ws  avgW= 112.5W  dW= +93.7W  maxW= 129.0W  gpu%= 87  mem%= 37
- rocBLAS GEMM f32         OK ( 5.725s)  m=n=k=6144 iters=80 TFLOPS=11.248 (GFLOPS=11247.9)                                                        |  E= 701Ws  avgW= 128.1W  dW=+109.3W  maxW= 198.0W  gpu%= 60  mem%=  4
- rocFFT                   OK ( 5.394s)  len=1048576 batch=16 ntrial=800                                                                           |  E= 742Ws  avgW= 144.5W  dW=+125.7W  maxW= 154.0W  gpu%= 90  mem%= 25
- rocRAND generate         OK ( 5.272s)  size=134217728 trials=3300                                                                                |  E= 936Ws  avgW= 184.0W  dW=+165.2W  maxW= 191.0W  gpu%= 91  mem%= 38
- MIOpen driver            OK (   32ms)  driver=MIOpenDriver
- MIOpen smoke             OK ( 5.313s)  driver=MIOpenDriver iters=700                                                                             |  E= 904Ws  avgW= 178.7W  dW=+159.9W  maxW= 208.0W  gpu%= 81  mem%= 13
- llama.cpp (docker) smoke OK (31.136s)  image=rocm/llama.cpp:llama.cpp-b6652.amd0_rocm7.0.0_ubuntu24.04_full model=Llama-3.2-3B-Instruct-Q4_K_M…  |  E=4784Ws  avgW= 160.7W  dW=+141.9W  maxW= 187.0W  gpu%= 94  mem%= 21
- Ollama (docker ROCm) bench OK ( 5.205s)  backend=rocm model=llama3.2:3b-instruct-q4_0 out=512 runs=8 tok/s=135.61 prompt_tok/s=3087.12 ttft=222m…  |  E= 503Ws  avgW=  99.8W  dW= +81.0W  maxW= 141.0W  gpu%= 56  mem%= 16
- Open Interpreter (pip) smoke OK ( 2.349s)  interpreter --help
- Whisper (python) smoke   OK (1m46.59s)  base transcribe (audio=audio_repeat_300s.wav) rocm_env=system wall=106.59s audio_target_s=300 repeats=5…  |  E=10042Ws  avgW=  94.3W  dW= +75.5W  maxW= 115.0W  gpu%= 90  mem%=  5
- MFEM (HIP) build+run     OK ( 9.068s)  mfem_apply mesh=fichera.mesh wall=8.61s order=3 refine=4 pa=1 ndofs=802081 iters=6770 seconds=7.77831 a…  |  E=1360Ws  avgW= 156.3W  dW=+137.5W  maxW= 180.0W  gpu%= 88  mem%= 24
- PyTorch (audio)          OK (11.661s)  device=AMD Radeon RX 6700 XT rocm_env=system wall=11.66s hsa_override=10.3.0 tflops_est=9.38 shape=16x6…  |  E=1894Ws  avgW= 158.5W  dW=+139.7W  maxW= 207.0W  gpu%= 75  mem%=  7
- PyTorch (video)          OK (20.613s)  device=AMD Radeon RX 6700 XT rocm_env=system wall=20.61s hsa_override=10.3.0 tflops_est=3.21 shape=2x32…  |  E=3806Ws  avgW= 181.5W  dW=+162.7W  maxW= 211.0W  gpu%= 83  mem%= 10
- PETSc (HIP) build+solve  OK ( 8.465s)  spmv m×n=1024x1024 wall=7.28s vec=hip mat=seqsellhip iters=45694 seconds=5.06662 matmult/s=9018.6         |  E=1189Ws  avgW= 123.7W  dW=+104.9W  maxW= 180.0W  gpu%= 65  mem%=  5
Logs: disabled (use --log)


## TODO

- Expand validation workloads (audio/video LLMs, additional scientific solvers) with pinned versions and clear size policies.
- Add optional CI-friendly report formats (JUnit/HTML) for `validation/`.
