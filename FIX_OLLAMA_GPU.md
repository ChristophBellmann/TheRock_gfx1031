# Fix Ollama GPU Detection - Native gfx1031

## Problem Identified

Your Ollama is not detecting the GPU because:

1. ✅ **Fixed**: `HSA_OVERRIDE_GFX_VERSION=10.3.0` removed from `.bashrc` and `.zshrc`
1. ✅ **System ROCm installed**: `/opt/rocm` with native gfx1031 support
1. ⚠️ **Issue**: Ollama process (PIDs 296580, 297241) running as "ollama" user needs restart

## Solution: Restart Ollama System Service

The Ollama processes are running as a system service under the "ollama" user. You need sudo to restart them.

### Option 1: Quick Restart (Recommended)

```bash
# Kill old ollama processes
sudo pkill -9 ollama

# Wait a moment
sleep 3

# Start Ollama with proper environment
sudo -u ollama bash -c 'unset HSA_OVERRIDE_GFX_VERSION && ROCM_PATH=/opt/rocm HIP_PATH=/opt/rocm LD_LIBRARY_PATH=/opt/rocm/lib:/opt/rocm/lib64:$LD_LIBRARY_PATH /usr/local/bin/ollama serve' &

# Wait for startup
sleep 5

# Test GPU detection
ollama ps
```

### Option 2: Using systemd Service

If you have a systemd service for Ollama:

```bash
# Restart the service
sudo systemctl restart ollama

# Check status
sudo systemctl status ollama

# Test
ollama ps
```

### Option 3: Manual Restart (Simple)

```bash
# Stop
sudo pkill -9 ollama

# Start (run in background)
sudo bash -c 'unset HSA_OVERRIDE_GFX_VERSION && nohup /usr/local/bin/ollama serve > /var/log/ollama.log 2>&1 &'

# Test
sleep 5 && ollama run llama3.2 "test"
```

## Verification Steps

After restarting Ollama, verify GPU detection:

### 1. Check Process Status

```bash
ollama ps
```

**Expected**: Should show `GPU` instead of `CPU` in PROCESSOR column

### 2. Test Inference with Monitoring

```bash
# Terminal 1: Monitor GPU
watch -n 1 'rocm-smi --showuse'

# Terminal 2: Run inference
ollama run llama3.2 "Write a haiku"
```

**Expected**: GPU usage should spike to 80-100%

### 3. Check ROCm Detection

```bash
# Check what GPU rocminfo sees
rocminfo | grep "Name:"
```

**Expected**: Should show `gfx1031` (not gfx1030)

### 4. Performance Check

```bash
ollama run llama3.2 "Count to 20" --verbose
```

**Expected Performance with GPU**:

- Prompt eval rate: 200-400 tokens/s
- Generation rate: 30-60 tokens/s

**Current Performance (CPU)**:

- Prompt eval rate: ~102 tokens/s
- Generation rate: ~13 tokens/s

You should see **2-4x speedup** after GPU detection works!

## Why This Fix Works

### Before

- `HSA_OVERRIDE_GFX_VERSION=10.3.0` forced GPU to report as gfx1030
- Ollama saw "gfx1030" and may have had compatibility issues
- Fell back to CPU execution

### After

- No override → GPU reports as native gfx1031
- TheRock ROCm has native gfx1031 support and optimized kernels
- Ollama will detect and use GPU properly

## Troubleshooting

### If still showing CPU after restart:

**Check 1: Verify environment has no override**

```bash
# In the shell where Ollama runs
ps aux | grep "ollama serve"  # Get PID
sudo cat /proc/[PID]/environ | tr '\0' '\n' | grep HSA
# Should NOT show HSA_OVERRIDE_GFX_VERSION
```

**Check 2: Verify Ollama can see ROCm**

```bash
sudo ldd /usr/local/lib/ollama/rocm/libggml-hip.so | grep rocm
# Should show /opt/rocm paths
```

**Check 3: Check Ollama startup logs**

```bash
# If running as systemd service
sudo journalctl -u ollama -n 50

# Or check log file
sudo tail -50 /var/log/ollama.log
```

Look for lines like:

- `Loaded rocm library` ✓ Good
- `Found GPU: gfx1031` ✓ Good
- `GPU not found, using CPU` ✗ Problem

### If GPU still not detected:

Try setting `OLLAMA_DEBUG=1` to see detailed logs:

```bash
sudo pkill -9 ollama
sudo bash -c 'OLLAMA_DEBUG=1 ROCM_PATH=/opt/rocm /usr/local/bin/ollama serve 2>&1 | tee /tmp/ollama-debug.log' &
sleep 5
ollama run llama3.2 "test"

# Check debug log
cat /tmp/ollama-debug.log | grep -i "gpu\|rocm\|gfx"
```

## Summary

**What's Fixed**:

- ✅ Removed HSA_OVERRIDE_GFX_VERSION from .bashrc and .zshrc
- ✅ System ROCm with native gfx1031 installed
- ✅ ROCm libraries working (/opt/rocm)

**What's Needed**:

- ⚠️ Restart Ollama process with sudo (it runs as "ollama" user)

**Command to run**:

```bash
sudo pkill -9 ollama && sleep 2 && sudo bash -c 'unset HSA_OVERRIDE_GFX_VERSION && nohup /usr/local/bin/ollama serve > /var/log/ollama.log 2>&1 &' && sleep 5 && ollama ps
```

This single command will:

1. Kill old Ollama
1. Start new Ollama with clean environment
1. Show process status (should show GPU!)

**Expected Result**: `ollama ps` shows GPU instead of CPU, and inference runs 2-4x faster!

______________________________________________________________________

**Note**: After restart, your models will need to reload into VRAM. The first inference after restart may be slower while the model loads.
