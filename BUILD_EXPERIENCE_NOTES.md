# Build Experience Notes (gfx1031 custom branch)

## Current Configuration

- Branch: `hashcat/rocm-7.11-gfx103X`
- Generator: `cmake -B build -GNinja`
- Targets: `THEROCK_AMDGPU_TARGETS=gfx1031`
- Dist bundle: `THEROCK_DIST_AMDGPU_TARGETS=gfx1031`, `THEROCK_DIST_AMDGPU_FAMILIES=gfx1031`
- Python: `-DPython3_EXECUTABLE=/media/christoph/some_space/make_my_gpu_useful/TheRock_gfx1031/.venv/bin/python3`
- Build command: `cmake --build build -- -j1` (serial; easier to resume)
- `ccache` enabled via `eval "$(./build_tools/setup_ccache.py --init)"` before each cmake/build call.
- Memory limits (optional): `systemd-run --user --scope -p MemoryHigh=26G -p MemoryMax=29G bash -lc 'cd ... && ninja -C build -j1 -l1'`

## Lessons / Fixes

1. **Stage → Dist mirror for Third-Party packages**  
   Ninja starts dependent projects before the dist artefacts exist. Manually mirroring stage to dist keeps `find_package(...)` happy. Useful commands:
   ```
   rsync -a build/<component>/stage/ build/<component>/dist/
   ```
   Needed so far: `FunctionalPlus`, `Eigen3`, `nlohmann-json`, `fmt`, `host-blas`, `SuiteSparse`, `zlib`.

2. **Patch scripts requiring Python**  
   - `third-party/sysdeps/linux/libcap/patch_install.sh`  
   - `third-party/sysdeps/linux/amd-mesa/patch_install.sh`  
   Both now try `Python3_EXECUTABLE` from the environment and fall back to `$(command -v python3)` with a clear error if missing. Ensures rocprofiler/rdc/sysdeps installs do not fail mid-build.

3. **Interrupted builds**  
   With `-j1`, Ninja resumes exactly where it left off; `ccache` shortens re-compiles. No need to restart from scratch after a Ctrl+C, just rerun the same build command.

4. **Live Monitoring**  
   Keep `tail -f build.log` in a second terminal. The file only shows the active command; detailed per-target logs live under `build/logs/therock-*.log`.

5. **CMake version compatibility (fftw3 / c-ares)**  
   The venv `pip install cmake` (4.x) breaks third-party builds that still use `cmake_minimum_required(<3.5)` (fftw3, grpc/cares). Use system CMake 3.28 (`/usr/bin/cmake`) and remove the venv wrappers (`rm ~/.local/bin/cmake ~/.local/bin/cpack ~/.local/bin/ctest`) to avoid patching external sources.

6. **In-tree ROCm env helper**  
   Use `source ./rocm-env-therock.sh` to set `ROCM_PATH`/`HIP_PATH`/`LD_LIBRARY_PATH` and auto-activate `.venv` when present. This is the fastest way to run `rocminfo`, `rocm-smi`, `hipcc`, or tests against `build/dist/rocm` before system install.

7. **Verify gfx1031 HIP kernel/device-lib path (avoid generic fallback)**  
   The critical check is that HIP compiles and links against gfx1031-specific device libs, not generic compatibility bitcode.  
   ```
   source ./rocm-env-therock.sh
   ls $HIP_DEVICE_LIB_PATH/oclc_isa_version_1031.bc
   hipcc -v tests/hipcc_check.cpp -o /tmp/hipcc_check 2>&1 | rg -n "gfx1031|oclc_isa_version_1031|amdgcn/bitcode"
   ```
   Expected: `-mcpu=gfx1031` (or `--offload-arch=gfx1031`) and `oclc_isa_version_1031.bc` in the compile/link line.  
   If you only see `10-3-generic` (or another gfx target), force the arch with `--offload-arch=gfx1031` or set `HIPCC_COMPILE_FLAGS_APPEND="--offload-arch=gfx1031"` and rebuild.
   Verified on 2025-12-18: `hipcc -v` shows `-target-cpu gfx1031` and links `oclc_isa_version_1031.bc`.

8. **Quick Bench Suite (gfx1031, RX 6700 XT)**  
   Run after `source ./rocm-env-therock.sh`. Results captured on 2025-12-18:
   ```
   rocfft-bench --length 1024 --precision single -t 0 -N 5
   # ~0.0122 ms, ~4.16 GFLOPS

   rocblas-bench -f axpy -r f32_r -n 1048576
   # 77.68 GFLOPS, 466.10 GB/s, 26.99 us

   hipblas-bench -f gemm -r f32_r -m 256 -n 256 -k 256
   # 1161.05 GFLOPS, 27.21 GB/s, 28.9 us

   benchmark_rocrand_generate --size 1048576 --trials 3 --dis uniform-float --engine philox
   # 187.8 GB/s, 46.95 GSample/s, 0.021 ms

   hipsparse-bench -f axpyi -n 1024 -z 256 -i 1
   # 0.03 GFLOPS, 0.22 GB/s, 0.02 ms
   ```

9. **Large GEMM (rocBLAS)**
   ```
   rocblas-bench -f gemm -r f32_r -m 4096 -n 4096 -k 4096
   # 12193.4 GFLOPS, 11271.6 us
   ```

10. **hipBLASLt status**
   `hipblaslt-bench` currently segfaults (Signal 11) even for small sizes on this setup:
   ```
   hipblaslt-bench -f matmul -m 1024 -n 1024 -k 1024
   hipblaslt-bench -f matmul -r f32_r -m 1024 -n 1024 -k 1024 --compute_type f32_r
   ```
   Standalone build from `rocm-libraries/projects/hipblaslt` fails at configure time because gfx1031 is not in the supported GPU list:
   ```
   cmake -S rocm-libraries/projects/hipblaslt -B rocm-libraries/projects/hipblaslt/build-standalone \
     -D CMAKE_C_COMPILER=$ROCM_PATH/lib/llvm/bin/clang \
     -D CMAKE_CXX_COMPILER=$ROCM_PATH/lib/llvm/bin/clang++ \
     -D CMAKE_PREFIX_PATH=$ROCM_PATH \
     -D GPU_TARGETS=gfx1031
   # CMake Error: Unsupported GPU target: gfx1031
   ```

11. **2025-12-18: Partial rebuild (gfx1031) + docs update**
   - Updated `README.md` to mention `rocm-env-therock.sh` for in-tree runtime use; build still uses only `.venv`.
   - Added `rebuild_gfx1031_subprojects.sh` to make the expunge+rebuild loop repeatable
     (now requires explicit targets; `--include-unsupported` opts into hipBLASLt/hipSPARSELt/rocWMMA).
   - Rotated `build.log` to `build.log.bak-20251218-171506` and continued logging to fresh `build.log`.
   - Cleaned + rebuilt subprojects with memory limits and venv:
     ```
     systemd-run --user --scope -p MemoryHigh=28G -p MemoryMax=31G bash -lc 'source .venv/bin/activate && cmake --build build --target hipBLASLt+expunge'
     systemd-run --user --scope -p MemoryHigh=28G -p MemoryMax=31G bash -lc 'source .venv/bin/activate && cmake --build build --target hipSPARSELt+expunge'
     systemd-run --user --scope -p MemoryHigh=28G -p MemoryMax=31G bash -lc 'source .venv/bin/activate && cmake --build build --target rocWMMA+expunge'
     systemd-run --user --scope -p MemoryHigh=28G -p MemoryMax=31G bash -lc 'source .venv/bin/activate && cmake --build build --target hipBLASLt'
     systemd-run --user --scope -p MemoryHigh=28G -p MemoryMax=31G bash -lc 'source .venv/bin/activate && cmake --build build --target hipSPARSELt'
     systemd-run --user --scope -p MemoryHigh=28G -p MemoryMax=31G bash -lc 'source .venv/bin/activate && cmake --build build --target rocWMMA'
     ```
   - Build logs live in `build/logs/{hipBLASLt,hipSPARSELt,rocWMMA}_build.log` (all end with rc=0).
   - Expected warnings: gfx1031 excluded for hipBLASLt/hipSPARSELt/rocWMMA (fallback to defaults),
     plus `rocm_smi_lib` git describe warnings (harmless).

12. **Recommended build profile (LLM / Vision / Audio, gfx1031)**
   Intended for Ollama/Mistral/Qwen, PyTorch, Whisper, and similar workloads
   with best performance on RX 6700 XT. Keep HIP toolchain + core math/ML libs,
   and keep composable kernel, profiler, and tests ON. Disable hipBLASLt and
   hipSPARSELt (unsupported for gfx1031).
   ```
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
     -DTHEROCK_ENABLE_HIPBLASLT=OFF \
     -DTHEROCK_ENABLE_HIPSPARSELT=OFF \
     -DTHEROCK_ENABLE_MIOPEN=ON \
     -DTHEROCK_ENABLE_HIPDNN=ON \
     -DTHEROCK_ENABLE_COMPOSABLE_KERNEL=ON \
     -DTHEROCK_ENABLE_RCCL=ON \
     -DTHEROCK_ENABLE_ROCWMMA=OFF \
     -DTHEROCK_ENABLE_PROFILER=ON \
     -DTHEROCK_ENABLE_DC_TOOLS=OFF \
     -DBUILD_TESTING=ON
   ```

13. **2025-12-18: Make BLAS Lt components optional for gfx1031**
   - Added `THEROCK_ENABLE_HIPBLASLT` and `THEROCK_ENABLE_HIPSPARSELT` gating in BLAS.
   - rocBLAS now honors `THEROCK_ENABLE_HIPBLASLT` (sets `BUILD_WITH_HIPBLASLT=OFF` when disabled).
   - hipBLASLt/hipSPARSELt artifacts marked optional so packaging won't expect them.
   - README and recommended profile updated to disable unsupported Lt components for gfx1031.

14. **2025-12-18: Clean gfx1031 build helper**
   - Added `build_gfx1031.sh` for a clean full build with memory limits and ccache.
   - Script refuses to run if `build/` is not clean (unless `--clean` or `--no-check-clean` is used).
   - Uses the recommended gfx1031 profile (LLM/Vision/Audio) and logs to `build.log`.

15. **2025-12-18: Clean gfx1031 configure helper**
   - Added `configure_gfx1031.sh` for a clean configure with memory limits and ccache.
   - Script refuses to run if `build/` is not clean (unless `--clean` or `--no-check-clean` is used).
   - Uses the recommended gfx1031 profile (LLM/Vision/Audio) and logs to `build.log`.

16. **2025-12-18: gfx1031 test helper**
   - Added `test_gfx1031.sh` for sanity checks and lightweight GEMM benchmarks.
   - Summarizes durations and (when available) TFLOPS parsed from bench output.
   - Logs output to `test_gfx1031.log` for quick inspection.

17. **2025-12-18: Switch helpers to clang host compiler**
   - `configure_gfx1031.sh` and `build_gfx1031.sh` now set `CMAKE_C_COMPILER=clang` and `CMAKE_CXX_COMPILER=clang++`.
   - Scripts fail fast if clang/clang++ are missing; ccache launchers remain enabled.

## TODO / Watchouts

- When new third-party packages are added, verify their `dist/` directories are populated before dependent projects configure.  
- GPU-focused warnings (hipBLASLt/hipSPARSELt/rocWMMA/composable_kernel) are expected on gfx1031 in this branch if those components are enabled; no action required yet.  
- Continue using serial builds unless we add explicit dependencies between stage/dist targets.
