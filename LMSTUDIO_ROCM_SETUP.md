# LM Studio with ROCm on AMD RX 6700 XT (gfx1031)

## Problem

LM Studio doesn't natively recognize gfx1031 GPUs because the bundled llama.cpp may not have gfx1031 compiled in. We need to override the GPU architecture to gfx1030, which is well-supported.

## Solution

Use `HSA_OVERRIDE_GFX_VERSION=10.3.0` environment variable to make the GPU appear as gfx1030.

## Quick Start

### Option 1: Using the startup script (Recommended)

```bash
~/start_lmstudio_rocm.sh
```

This script:

- Sets all necessary ROCm environment variables
- Sets `HSA_OVERRIDE_GFX_VERSION=10.3.0`
- Starts LM Studio with GPU support enabled

### Option 2: Manual start with environment variable

```bash
HSA_OVERRIDE_GFX_VERSION=10.3.0 ~/Downloads/LM-Studio-0.3.32-1-x64.AppImage
```

## Using the CLI

### Regular lms command (may not use GPU)

```bash
~/.lmstudio/bin/lms ps
```

### lms with ROCm support (recommended)

```bash
~/lms-rocm ps
~/lms-rocm load <model-name>
~/lms-rocm ls
```

The `lms-rocm` wrapper automatically sets the HSA override.

## Testing GPU Acceleration

### Check if GPU is being used

```bash
~/test_lmstudio_gpu.sh
```

### Monitor GPU usage in real-time

```bash
watch -n 1 rocm-smi
```

### Check LM Studio logs

```bash
tail -f ~/.lmstudio/server-logs/*/$(date +%Y-%m-%d).*.log
```

Look for messages indicating GPU initialization and layer offloading.

## Verifying It's Working

When you load a model, you should see:

1. In LM Studio UI: GPU layers being offloaded (should show VRAM usage)
1. In `rocm-smi`: GPU usage percentage > 0% when generating text
1. In logs: Messages about GPU initialization and layer counts

Example log output when working:

```
llm_load_tensors: using ROCm for GPU acceleration
llm_load_tensors: offloading 32 layers to GPU
llm_load_tensors: GPU 0: AMD Radeon RX 6700 XT
```

## Troubleshooting

### GPU not detected

```bash
# Check ROCm can see GPU
rocminfo | grep gfx1031

# Check environment
echo $HSA_OVERRIDE_GFX_VERSION  # Should show 10.3.0
```

### LM Studio using CPU only

1. Restart LM Studio using the startup script
1. Check backend preferences: `~/.lmstudio/.internal/backend-preferences-v1.json`
   - Should show: `llama.cpp-linux-x86_64-amd-rocm-avx2`
1. In LM Studio UI, check that GPU layers slider is > 0

### Server won't start

```bash
# Check if port 1234 is in use
lsof -i :1234

# Kill existing instance
pkill -f lm-studio

# Restart with script
~/start_lmstudio_rocm.sh
```

## Environment Variables Explained

| Variable                   | Value       | Purpose                                     |
| -------------------------- | ----------- | ------------------------------------------- |
| `HSA_OVERRIDE_GFX_VERSION` | `10.3.0`    | Makes gfx1031 appear as gfx1030 (supported) |
| `HSA_ENABLE_SDMA`          | `0`         | Disables SDMA (prevents hangs on RDNA 2)    |
| `HSA_XNACK`                | `0`         | Disables XNACK (not needed for gfx1031)     |
| `AMD_DIRECT_DISPATCH`      | `0`         | Safer dispatch for RDNA 2                   |
| `ROCM_PATH`                | `/opt/rocm` | ROCm installation path                      |
| `HIP_PATH`                 | `/opt/rocm` | HIP runtime path                            |

## Making It Permanent

To always use GPU with LM Studio, add to `~/.bashrc`:

```bash
# Uncomment the HSA_OVERRIDE_GFX_VERSION line
export HSA_OVERRIDE_GFX_VERSION=10.3.0
```

Then LM Studio will automatically use GPU when started normally.

## Performance Tips

1. **GPU Layers**: In LM Studio, set GPU layers to maximum your VRAM allows (12GB for RX 6700 XT)
1. **Context Size**: Larger context uses more VRAM - adjust if you run out
1. **Batch Size**: Default is usually fine, but you can experiment
1. **Model Size**: 7B models should fully fit in VRAM, 13B models might need partial offloading

## Files Created

- `~/start_lmstudio_rocm.sh` - Startup script with ROCm environment
- `~/lms-rocm` - CLI wrapper with ROCm environment
- `~/test_lmstudio_gpu.sh` - GPU acceleration test script
- `~/TheRock/LMSTUDIO_ROCM_SETUP.md` - This documentation

## Comparison with Ollama

| Feature      | LM Studio             | Ollama                 |
| ------------ | --------------------- | ---------------------- |
| GPU Support  | Requires HSA override | Native gfx1031 support |
| Interface    | GUI + CLI + API       | CLI + API              |
| Model Format | GGUF                  | GGUF (via Modelfile)   |
| Ease of Use  | More complex setup    | Simpler (when working) |

Both tools use llama.cpp under the hood, but they may bundle different versions with different GPU support compiled in.
