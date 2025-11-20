# Open Interpreter with llama-server (GPU)

## Quick Start

### 1. Start llama-server

```bash
~/start_llama_server_openai.sh
```

This starts llama-server on port 8080 with:

- Model: DeepSeek-R1-Qwen3-8B (Q4_K_M) - coding + reasoning
- GPU: 20 layers offloaded to AMD RX 6700 XT via ROCm
- Context: 4096 tokens
- API: OpenAI-compatible at http://localhost:8080/v1
- Auto-starts on boot via systemd

### 2. Start Open Interpreter

```bash
interpreter
```

Open Interpreter is now configured to use llama-server on port 8080.

## Configuration Files

### Main Config

`~/.config/open-interpreter/config.yaml`

- Currently set to use llama-server (port 8080)
- To switch to LM Studio: change `api_base` to `http://localhost:1234/v1`

### Profile (Optional)

`~/.config/open-interpreter/profiles/llama-server.yaml`

- Dedicated profile for llama-server
- Use with: `interpreter --profile llama-server`

## Switching Models

### Use a different model:

```bash
# Set MODEL_PATH and start server
MODEL_PATH=~/.lmstudio/models/path/to/your/model.gguf ~/start_llama_server_openai.sh
```

### Available models in ~/.lmstudio/models/:

```bash
find ~/.lmstudio/models -name "*.gguf"
```

## Server Management

### Start server:

```bash
~/start_llama_server_openai.sh
```

### Check if server is running:

```bash
curl http://localhost:8080/v1/models
```

### Stop server:

```bash
pkill -f "llama-server.*8080"
```

### Monitor GPU usage:

```bash
watch -n 1 rocm-smi
```

## Switching Between LM Studio and llama-server

### Use LM Studio (Vulkan):

1. Start LM Studio: `systemctl --user start lmstudio-server`
1. Edit `~/.config/open-interpreter/config.yaml`:
   ```yaml
   api_base: "http://localhost:1234/v1"
   model: "openai/gpt-oss-20b"
   ```
1. Run: `interpreter`

### Use llama-server (ROCm):

1. Start llama-server: `~/start_llama_server_openai.sh`
1. Edit `~/.config/open-interpreter/config.yaml`:
   ```yaml
   api_base: "http://localhost:8080/v1"
   model: "deepseek-r1-qwen3-8b"
   ```
1. Run: `interpreter`

## Performance Comparison

| Backend      | Port | GPU    | VRAM   | Speed | Stability |
| ------------ | ---- | ------ | ------ | ----- | --------- |
| llama-server | 8080 | ROCm   | ~5-6GB | Fast  | Excellent |
| LM Studio    | 1234 | Vulkan | ~6-7GB | Fast  | Excellent |

Both work great! Choose based on preference:

- **llama-server**: Direct control, lighter weight, native ROCm
- **LM Studio**: GUI, easier model management, Vulkan backend

## Troubleshooting

### "Connection refused" error

```bash
# Check if server is running
curl http://localhost:8080/health

# Check what's on port 8080
lsof -i :8080

# Restart server
pkill -f llama-server && ~/start_llama_server_openai.sh
```

### GPU not being used

```bash
# Check GPU detection in server output
~/start_llama_server_openai.sh | grep -i gpu

# Monitor GPU while generating
rocm-smi --showuse
```

### Out of VRAM

```bash
# Reduce GPU layers in start script (edit line 43)
# Change: --n-gpu-layers 33
# To:     --n-gpu-layers 20  (or lower)
```

## Testing

### Test server with curl:

```bash
curl http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "deepseek-r1-qwen3-8b",
    "messages": [{"role": "user", "content": "Hello! Who are you?"}],
    "max_tokens": 100,
    "temperature": 0.7
  }'
```

### Test Open Interpreter:

```bash
interpreter
```

Then try: `print("Hello from Open Interpreter with GPU!")`

## Model Recommendations

For Open Interpreter:

- **DeepSeek-R1-Qwen3-8B** (current, default) - Best for coding + reasoning (5GB, Q4_K_M)
- **Codestral-22B** - Pure code generation, larger (11GB, Q3_K_M)
- **Phi-4-reasoning-plus** - Strong reasoning, medium size

## Auto-Start on Boot

llama-server is configured to auto-start via systemd:

```bash
# Check service status
systemctl --user status llama-server.service

# Restart service
systemctl --user restart llama-server.service

# Disable auto-start
systemctl --user disable llama-server.service

# Re-enable auto-start
systemctl --user enable llama-server.service
```

Service logs: `/tmp/llama-server.log`

## Files

- `~/start_llama_server_openai.sh` - Server startup script
- `~/.config/open-interpreter/config.yaml` - Main OI config
- `~/.config/open-interpreter/profiles/llama-server.yaml` - llama-server profile
- `~/TheRock/OPEN_INTERPRETER_SETUP.md` - This file

## Resources

- llama.cpp docs: https://github.com/ggerganov/llama.cpp
- Open Interpreter docs: https://docs.openinterpreter.com
- ROCm docs: https://rocm.docs.amd.com
