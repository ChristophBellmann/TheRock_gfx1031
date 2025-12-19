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

18. **2025-12-18: Switch helper builds to ninja**
   - `build_gfx1031.sh` and `rebuild_gfx1031_subprojects.sh` now call `ninja -C build` directly instead of `cmake --build build`.
   - Added a `ninja` availability check; keeps expunge + target sequencing explicit.

19. **2025-12-18: Helper QoL (ccache & venv automation)**
   - Bundled ccache 4.11.1 to `.local/bin/ccache`; helpers prepend `.local/bin` if present.
   - `configure_gfx1031.sh` now auto-evals `build_tools/setup_ccache.py`.
   - `configure_gfx1031.sh` auto-creates `.venv` (python3 -m venv + requirements.txt) if missing.
   - README updated with ccache defaults and typical workflows.
   - Note: the new auto-venv/ccache flow has not yet been run end-to-end; run `./configure_gfx1031.sh --clean && ./build_gfx1031.sh` to validate.

20. **2025-12-19: Default BUILD_TESTING=OFF in configure helper**
   - `ENABLE_BUILD_TESTING=false` by default to avoid gcc-related ICEs; clang enforced as host compiler.
   - README notes how to re-enable tests via script toggle or extra CMake arg.

21. **2025-12-19: Composable-kernel toggle propagated to MIOpen**
   - `configure_gfx1031.sh` now sets `THEROCK_MIOPEN_USE_COMPOSABLE_KERNEL` to match the CK flag.
   - README notes: CK unsupported on gfx1031; MIOpen disables CK internally with a warning only.

22. **2025-12-19: Phase 1 clang build (ROCPROFSYS=OFF) stalled on sysdeps cmake configs**
   - Configure succeeds with clang18, BUILD_TESTING=OFF, ROCPROFSYS=OFF, hipBLASLt/hipSPARSELt/ROCWMMA=OFF.
   - `build_gfx1031.sh --skip-configure` fails during configure of `rocm-half` and `grpc`: missing `ROCmCMakeBuildTools` (from rocm-cmake) and `ZLIBConfig.cmake` (from sysdeps zlib) under `dist/share/...`.
   - Root cause: missing/empty `dist/` configs during early parallel configures (and earlier also a Python3 scoping issue that prevented the stage→dist population rules from running reliably).
   - Fix (current state): add a dedicated bootstrap step (`./bootstrap_gfx1031.sh`) which builds the minimal `+dist` targets (rocm-cmake + sysdeps + host-blas + common CMake-config deps) before the full build runs.

23. **2025-12-19: Helpers hardened (sysdeps stage→dist + LD_LIBRARY_PATH for host tools)**
   - `bootstrap_gfx1031.sh` builds a minimal set of `+dist` targets so dependent `find_package(...)` calls can resolve reliably during later parallel configures.
   - `build_gfx1031.sh` injects `LD_LIBRARY_PATH` with sysdeps dist+stage `rocm_sysdeps/lib` (zstd/zlib/bzip2/liblzma/elfutils/libdrm/numactl) to let host tools like `llvm-min-tblgen` load `librocm_sysdeps_zstd.so.1` during amd-llvm build.
   - Current state: helpers set `LD_LIBRARY_PATH` explicitly (no inheritance by default) to avoid mixing with `/opt/rocm-*`.

24. **2025-12-19: OpenBLAS → SuiteSparse path fixed**
   - SuiteSparse configure failed: `OpenBLASConfig.cmake` not found under `host-blas/dist`.
   - Fix (current state): `bootstrap_gfx1031.sh` includes `therock-host-blas+dist` so `host-blas/dist` is populated before SuiteSparse configures.
   - Re-run `./bootstrap_gfx1031.sh` after configure to validate.

25. **2025-12-19: Build helper hygiene (hipcc notice + clang 18 enum fix)**
   - `configure_gfx1031.sh` now warns loudly if hipcc/amdclang++ is missing (bootstrap still proceeds with host clang++) so we remember to switch to ROCm toolchain after Stage 1.
   - Initially tried adding `-Wno-enum-constexpr-conversion` via global `CMAKE_CXX_FLAGS`, but this later broke projects that treat unknown warning options as errors (e.g. `rocminfo` with `-Werror,-Wunknown-warning-option`). The helper no longer sets this globally; if SPIR-V headers cause issues again, the fix must be applied narrowly (to the affected subproject/toolchain only).
   - `build_gfx1031.sh` extends `LD_LIBRARY_PATH` to include the raw `build/.../zlib|zstd/build/b` directories in addition to stage/dist `rocm_sysdeps` to keep host tools (llvm-min-tblgen, etc.) finding `librocm_sysdeps_z*.so` during early compiler build.
   - Next step: rerun `./configure_gfx1031.sh --clean` then `./build_gfx1031.sh --skip-configure` to verify amd-llvm now builds cleanly.

26. **2025-12-19: Add explicit bootstrap step for third-party/sysdeps**
   - Added `bootstrap_gfx1031.sh` to build the minimum `+dist` targets that tend to be needed early (rocm-cmake, sysdeps zlib/zstd, host-blas, and a few common CMake-config deps) before the full parallel superbuild runs.
   - Goal: avoid intermittent configure failures during the full build due to missing `*Config.cmake` under `dist/` and missing `librocm_sysdeps_*.so` for host tools.
   - Status: script is new; needs validation as part of a full clean run (configure → bootstrap → build).

27. **2025-12-19: Ensure ccache bootstrapping config is active in build helper**
   - TheRock includes `build_tools/setup_ccache.py` which writes a repo-local `./.ccache/ccache.conf` with:
     - `sloppiness = include_file_ctime` (hardlink-friendly)
     - a custom `compiler_check` suitable for compiler bootstrapping
   - `build_gfx1031.sh` now also evals `setup_ccache.py` (not just configure) so the above settings are active during compilation, and exports `CCACHE_SLOPPINESS=include_file_ctime` as an explicit belt-and-suspenders.

28. **2025-12-19: Default to clean configure in helper**
   - `configure_gfx1031.sh` now removes `build/` by default to ensure the toolchain/config stays coherent (especially when switching compilers or feature flags).
   - Added `--no-clean` for the rare case where an in-place reconfigure is desired.

29. **2025-12-19: Move stage→dist sync into bootstrap + unify logging**
   - Centralized early dependency preparation into `bootstrap_gfx1031.sh` so `configure_gfx1031.sh` stays “pure”.
   - Later refined bootstrap to build `+dist` targets directly (instead of stage→dist symlinks) to avoid symlink edge cases while still providing early `dist/` CMake configs.
   - `bootstrap_gfx1031.sh` now appends to `build.log` (same log as configure/build) instead of using a separate `bootstrap.log`.
   - Downgraded the hipcc “missing” message from WARNING to INFO and clarified that hipcc appears only after the compiler/toolchain is built+installed into `./install` (not after the third-party bootstrap step).

30. **2025-12-19: Avoid system hipcc fallback (ensure in-tree HIP toolchain)**
   - `configure_gfx1031.sh` now only sets `CMAKE_HIP_COMPILER` when `./install/bin/hipcc` exists, and does not auto-fallback to `/opt/rocm/bin/hipcc`.
   - Rationale: prevent ABI/version mixing between in-tree ROCm and any system ROCm; TheRock’s HIP subprojects already pin their toolchain via `COMPILER_TOOLCHAIN amd-hip`.

31. **2025-12-19: amd-llvm failed in rocr-runtime configure (missing NUMAConfig)**
   - Failure: `rocr-runtime` (libhsakmt) `find_package(NUMA)` failed because `NUMAConfig.cmake` was expected under `build/third-party/sysdeps/linux/numactl/build/dist/lib/rocm_sysdeps/lib/cmake/NUMA` but sysdeps `therock-numactl` was never built in bootstrap.
   - Fix (current state): `bootstrap_gfx1031.sh` includes `therock-numactl+dist` and verifies `numa-config.cmake` exists under `dist/`.

32. **2025-12-19: amd-llvm rocr-runtime configure needed LibElfConfig (elfutils)**
   - Failure: `rocr-runtime` (hsa-runtime) `find_package(LibElf)` expected `build/third-party/sysdeps/linux/elfutils/build/dist/lib/rocm_sysdeps/lib/cmake/LibElf` but sysdeps `therock-elfutils` was not in bootstrap.
   - Fix (current state): `bootstrap_gfx1031.sh` includes `therock-elfutils+dist` and verifies `libelf-config.cmake` exists under `dist/`.

33. **2025-12-19: Dist dirs stayed empty (Python3_EXECUTABLE not exported) → find_package failures**
   - Symptom: subproject configures (notably `amd-comgr-impl`) failed with messages like:
     - `Super-project based find_package(AMDDeviceLibs) config file not found under .../build/compiler/amd-llvm/dist/...`
     - after manually copying one config, it would then fail on the next (`ClangConfig.cmake`, `LLVMConfig.cmake`, …).
   - Root cause: `Python3_EXECUTABLE` was not exported from `therock_setup_python_and_topology()` (function scope), so generated Ninja rules invoked `build_tools/teatime.py` and `build_tools/fileset_tool.py` without an explicit interpreter. This also prevented the stage→dist population step from running reliably, leaving many `dist/` dirs empty.
   - Fix: `cmake/therock_python_setup.cmake` now forces `Python3_EXECUTABLE` into the cache so generated rules consistently use the venv interpreter (`.venv/bin/python3`) for `teatime.py` and `fileset_tool.py`.
   - Recovery: re-run `./configure_gfx1031.sh --no-clean` to regenerate `build/build.ninja`, then `./build_gfx1031.sh --skip-configure --detach` to continue.

34. **2025-12-19: fileset_tool copy failed when `dist/` is a symlink**
   - Symptom: stage installs failed with `OSError: Cannot call rmtree on a symbolic link` while running `fileset_tool.py copy .../dist .../stage`.
   - Cause: earlier helper workflows sometimes created `dist/` as a stage→dist symlink for quick bootstrapping. `PatternMatcher.copy_to()` used `shutil.rmtree()` unconditionally when `--remove-dest` is enabled, which raises on symlinks.
   - Fix: `build_tools/_therock_utils/pattern_match.py` now unlinks `destdir` when it is a symlink (instead of calling `rmtree`) and then proceeds with the normal directory copy.

35. **2025-12-19: ROCR-Runtime configure failed (Ninja RPATH relink error)**
   - Failure: `ROCR-Runtime` (hsa-runtime64) configure errored at `runtime/hsa-runtime/CMakeLists.txt:97 (add_library)`:
     - “install … requires changing an RPATH from the build tree … not supported with the Ninja generator … set CMAKE_BUILD_WITH_INSTALL_RPATH”.
   - Fix: added `-DCMAKE_BUILD_WITH_INSTALL_RPATH=ON` to the ROCR-Runtime subproject `CMAKE_ARGS` in `core/CMakeLists.txt`.
   - Recovery: reconfigure (`./configure_gfx1031.sh --no-clean --no-check-clean`), then `ninja -C build ROCR-Runtime+expunge`, then resume via `./build_gfx1031.sh --skip-configure --detach`.

36. **2025-12-19: Bootstrap now builds +dist (no stage→dist symlinks)**
   - `bootstrap_gfx1031.sh` now uses `+dist` targets instead of creating stage→dist symlinks. This avoids symlink-related edge cases and ensures `dist/` CMake configs are real directories.
   - `bootstrap_gfx1031.sh` and `build_gfx1031.sh` now default to *not inheriting* `LD_LIBRARY_PATH` (to avoid accidentally pulling in `/opt/rocm-*`). Set `PRESERVE_LD_LIBRARY_PATH=1` if you explicitly want to append the inherited path.

37. **2025-12-19: rocSPARSE stage install failed when BUILD_CLIENTS_TESTS=OFF**
   - Failure: `rocSPARSE+stage` ran `cmake --install` and failed with:
     - `file INSTALL cannot find ".../rocSPARSE/build/clients/matrices": No such file or directory.`
   - Root cause: `math-libs/BLAS/pre_hook_rocSPARSE.cmake` unconditionally installed `${CMAKE_CURRENT_BINARY_DIR}/clients/matrices`, but that directory is only created when rocSPARSE client tests generate/copy matrices.
   - Fix: mark the install rule as `OPTIONAL` so `cmake --install` doesn’t hard-fail when client tests (and matrices) are disabled.
   - Recovery: `ninja -C build rocSPARSE+expunge rocSPARSE+stage` and then resume the full build.

38. **2025-12-19: hipSPARSE stage install failed for the same reason**
   - Failure: `hipSPARSE+stage` ran `cmake --install` and failed with:
     - `file INSTALL cannot find ".../hipSPARSE/build/clients/matrices": No such file or directory.`
   - Root cause: `math-libs/BLAS/pre_hook_hipSPARSE.cmake` installed `${CMAKE_CURRENT_BINARY_DIR}/clients/matrices` unconditionally, but with `BUILD_CLIENTS_TESTS=OFF` no matrices directory is generated.
   - Fix: mark the install rule as `OPTIONAL`.
   - Recovery: `ninja -C build hipSPARSE+expunge hipSPARSE+stage` and then resume the full build.
## TODO / Watchouts

- When new third-party packages are added, verify their `dist/` directories are populated before dependent projects configure.  
- GPU-focused warnings (hipBLASLt/hipSPARSELt/rocWMMA/composable_kernel) are expected on gfx1031 in this branch if those components are enabled; no action required yet.  
- Continue using serial builds unless we add explicit dependencies between stage/dist targets.
- Pending validation: helper automation (auto-venv + ccache 4.11.1 + clang/ninja) has not been executed in a fresh build yet.
