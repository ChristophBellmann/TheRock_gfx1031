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

## TODO / Watchouts

- When new third-party packages are added, verify their `dist/` directories are populated before dependent projects configure.  
- GPU-focused warnings (hipBLASLt, hipSPARSELt, rocWMMA, composable_kernel) are expected on gfx1031 in this branch; no action required yet.  
- Continue using serial builds unless we add explicit dependencies between stage/dist targets.
