from __future__ import annotations


def defaults() -> dict[str, int]:
    return {
        "rocminfo": 10,
        "hipcc_compile_run": 120,
        "rocblas_bench": 60,
        "rocfft_bench": 30,
        "rocrand_bench": 30,
        "miopen_driver": 10,
        "miopen_smoke": 240,
        "llama_cpp_docker": 900,
        "ollama": 120,
        "open_interpreter": 900,
        "whisper": 1800,
        "mfem_hip": 3600,
    }

