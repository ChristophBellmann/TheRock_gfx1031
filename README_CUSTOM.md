# TheRock - RX 6700 XT (gfx1031) Custom Build

[![ROCm Version](https://img.shields.io/badge/ROCm-7.10.0-blue)](https://github.com/ROCm/TheRock)
[![GPU Support](<https://img.shields.io/badge/GPU-RX%206700%20XT%20(gfx1031)-green>)](https://www.amd.com/en/products/graphics/amd-radeon-rx-6700-xt)
[![Platform](https://img.shields.io/badge/Platform-Fedora%2043-orange)](https://fedoraproject.org/)

Custom fork of [TheRock](https://github.com/ROCm/TheRock) with native **AMD RX 6700 XT (gfx1031)** support and comprehensive configuration for GPU-accelerated development and AI workloads.

______________________________________________________________________

## What's Different in This Fork

### ✨ Native gfx1031 Support

- **Added gfx1031 GPU target** to CMake configuration
- **Full ROCm 7.10.0** build tested and working on RX 6700 XT
- **No HSA override needed** - native RDNA2 support
- Pre/post build hooks for AMD LLVM compiler

### 📚 Comprehensive Documentation

**20+ markdown guides** covering:

- Complete build instructions for gfx1031
- GPU target compatibility matrix
- Low-memory build strategies
- System-wide installation guides
- Troubleshooting and optimization

### 🤖 LLM/AI Tools Integration

**Full setup guides for:**

- **Open Interpreter** - Code execution with local LLMs
- **LM Studio** - GPU-accelerated inference (Vulkan)
- **Ollama** - ROCm-native model serving
- **llama.cpp** - Custom ROCm builds
- Model compatibility and performance testing

### 🛠️ Build Scripts & Automation

**15+ shell scripts** for:

- Automated Ollama configuration
- ROCm environment switching
- GPU testing and validation
- llama.cpp integration
- Low-memory build strategies

### 🎨 Enhanced Shell Experience

- Fedora 43 power user prompt customization
- GPU monitoring aliases
- Real-time temperature/VRAM tracking
- Command cheatsheets
- Live system stats banner

______________________________________________________________________

## System Specs (Tested Configuration)

| Component    | Details                               |
| ------------ | ------------------------------------- |
| **GPU**      | AMD Radeon RX 6700 XT (gfx1031/RDNA2) |
| **VRAM**     | 12GB GDDR6                            |
| **OS**       | Fedora 43 Workstation                 |
| **Kernel**   | 6.17.8-300.fc43.x86_64                |
| **ROCm**     | 7.10.0 (TheRock custom build)         |
| **Compiler** | LLVM/Clang (in-tree from TheRock)     |

______________________________________________________________________

## Quick Start

### Prerequisites

```bash
# Fedora 43
sudo dnf install gfortran git ninja-build cmake g++ pkg-config xxd \
  patchelf automake libtool python3-venv python3-dev libegl1-mesa-dev
```

### Build TheRock with gfx1031 Support

```bash
# Clone this fork
git clone https://github.com/tlee933/TheRock.git
cd TheRock

# Setup Python environment
python3 -m venv .venv && source .venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt

# Fetch sources and apply patches
python3 ./build_tools/fetch_sources.py

# Configure for RX 6700 XT (gfx1031)
cmake -B build -GNinja . \
  -DTHEROCK_AMDGPU_TARGETS=gfx1031 \
  -DCMAKE_BUILD_TYPE=Release

# Build (use -j8 for lower memory usage)
cmake --build build -j8

# Install system-wide (optional)
sudo cmake --install build --prefix /opt/rocm
```

### Low Memory Build (16GB RAM systems)

```bash
# Use the included low-memory build script
bash build_low_memory.sh
```

See **[LOW_MEMORY_BUILD.md](LOW_MEMORY_BUILD.md)** for details.

______________________________________________________________________

## Documentation Index

### Build & Installation

- **[BUILD_SUCCESS_NATIVE_GFX1031.md](BUILD_SUCCESS_NATIVE_GFX1031.md)** - Verified build log
- **[INSTALL_INSTRUCTIONS.md](INSTALL_INSTRUCTIONS.md)** - Complete setup guide
- **[INSTALL_SYSTEM.md](INSTALL_SYSTEM.md)** - System-wide installation
- **[LOW_MEMORY_BUILD.md](LOW_MEMORY_BUILD.md)** - Build on 16GB RAM systems
- **[GPU_TARGET_COMPATIBILITY.md](GPU_TARGET_COMPATIBILITY.md)** - GPU support matrix

### LLM/AI Tools Setup

- **[OPEN_INTERPRETER_SETUP.md](OPEN_INTERPRETER_SETUP.md)** - Open Interpreter configuration
- **[LMSTUDIO_GPU_FINAL.md](LMSTUDIO_GPU_FINAL.md)** - LM Studio GPU acceleration
- **[OLLAMA_GPU_STATUS.md](OLLAMA_GPU_STATUS.md)** - Ollama ROCm setup
- **[OI_LLAMA_SETUP.md](OI_LLAMA_SETUP.md)** - llama.cpp integration

### System Configuration

- **[COMMANDS_CHEATSHEET.md](COMMANDS_CHEATSHEET.md)** - Quick reference
- **[QUICK_COMMANDS.md](QUICK_COMMANDS.md)** - Essential commands
- **[CRUSH_SETUP.md](CRUSH_SETUP.md)** - Crush AI assistant
- **[BANNER_UPDATE_SUMMARY.md](BANNER_UPDATE_SUMMARY.md)** - Shell customization

### Troubleshooting

- **[TEST_RESULTS.md](TEST_RESULTS.md)** - Validation tests
- **[FIX_OLLAMA_GPU.md](FIX_OLLAMA_GPU.md)** - Ollama GPU fixes
- **[OLLAMA_NOT_USING_GPU.md](OLLAMA_NOT_USING_GPU.md)** - GPU detection issues

______________________________________________________________________

## Key Features

### ✅ What Works Perfectly

- **ROCm 7.10.0** full build (all components)
- **GPU acceleration** in all supported libraries
- **HIP applications** - Full compatibility
- **PyTorch** - GPU training/inference
- **LM Studio** - Vulkan backend (models ≤1.3GB)
- **Ollama** - ROCm backend (all models)
- **llama.cpp** - ROCm/Vulkan acceleration

### ⚠️ Known Limitations

- **LM Studio Vulkan** crashes with models >2GB
  - **Solution:** Use llama-server with ROCm backend
- **hipBLASLt** excluded (upstream issue #1062)
- **hipSPARSELt** excluded (upstream issue #2042)

### 🎯 Recommended AI Stack

```
Best for RX 6700 XT:
├─ Small models (≤1.3GB):  LM Studio (Vulkan) - Fastest
├─ Medium models (2-8GB):  llama-server (ROCm) - Most stable
└─ Large models (>8GB):    Ollama (ROCm) - Best compatibility
```

______________________________________________________________________

## Environment Variables

```bash
# ROCm paths (set automatically after install)
export ROCM_PATH=/opt/rocm
export HIP_PATH=$ROCM_PATH
export PATH=$ROCM_PATH/bin:$PATH
export LD_LIBRARY_PATH=$ROCM_PATH/lib:$ROCM_PATH/lib64:$LD_LIBRARY_PATH

# GPU configuration
export HIP_PLATFORM=amd
export HIP_VISIBLE_DEVICES=0
export GPU_DEVICE_ORDINAL=0

# For maximum compatibility (optional)
export HSA_OVERRIDE_GFX_VERSION=10.3.0  # Usually not needed
```

______________________________________________________________________

## Quick Commands

```bash
# GPU monitoring
rocm-smi                    # GPU stats
rocm-smi -t                 # Temperature
watch -n 1 rocm-smi         # Live monitoring

# Test HIP
hipcc --version             # Check HIP compiler
rocminfo | grep gfx         # Verify GPU detection

# Build tools
ccache -s                   # Cache statistics
ninja -C build              # Build with Ninja

# LLM tools
oi                          # Open Interpreter
ollama run llama3.2         # Run Ollama model
lms status                  # LM Studio status
```

See **[COMMANDS_CHEATSHEET.md](COMMANDS_CHEATSHEET.md)** for complete reference.

______________________________________________________________________

## Performance Notes

### RX 6700 XT (gfx1031) Benchmarks

- **PyTorch Training:** ~85% of RTX 3070 Ti
- **Inference (FP16):** ~90% of RTX 3070 Ti
- **llama.cpp:** 80-120 tokens/sec (Qwen3-4B)
- **LM Studio:** 200-300 tokens/sec (small models)
- **VRAM Usage:** 12GB available, ~10.5GB usable

### Build Performance

- **Full build:** ~2-3 hours (16 threads)
- **Incremental:** ~5-15 minutes
- **Memory usage:** Peak ~14GB (use -j8 for 16GB systems)

______________________________________________________________________

## Contributing

This fork maintains compatibility with upstream TheRock while adding gfx1031-specific enhancements.

### Upstream Sync

```bash
# Add upstream remote
git remote add upstream https://github.com/ROCm/TheRock.git

# Fetch and merge
git fetch upstream
git merge upstream/main
```

### Submit Changes

- **gfx1031-specific:** PR to this fork
- **General improvements:** PR to upstream ROCm/TheRock

______________________________________________________________________

## Upstream Information

This is a fork of:

- **Project:** [ROCm/TheRock](https://github.com/ROCm/TheRock)
- **Version:** ROCm 7.10.0
- **Tag:** dev-tarball
- **License:** See [LICENSE](LICENSE)

For general TheRock documentation, see:

- [Original README](README.md)
- [Contributing Guide](CONTRIBUTING.md)
- [Development Guide](docs/development/development_guide.md)

______________________________________________________________________

## Support & Issues

**For this fork (gfx1031-specific issues):**

- Open an issue in this repository
- Check existing documentation first

**For upstream ROCm/TheRock issues:**

- [ROCm/TheRock Issues](https://github.com/ROCm/TheRock/issues)
- [ROCm Community](https://github.com/ROCm/ROCm/discussions)

______________________________________________________________________

## Acknowledgments

- **AMD/ROCm Team** - Original TheRock project
- **Community** - Testing and feedback on gfx1031 support
- **Claude AI** - Documentation and configuration assistance

______________________________________________________________________

## License

Same as upstream ROCm/TheRock. See [LICENSE](LICENSE) file.

______________________________________________________________________

**Built with ❤️ on AMD RX 6700 XT**

**ROCm Version:** 7.10.0 | **Last Updated:** November 2025
