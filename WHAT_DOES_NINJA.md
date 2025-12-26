### What `cmake -B build -GNinja .` actually does

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

