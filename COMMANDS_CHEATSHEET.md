# ⚡ Quick Commands Cheat Sheet

## 🔥 Most Used Commands

```bash
# Check GPU status
gpu

# Check all services
check-all

# Monitor GPU live
gpu-watch

# Test llama-server
llama-health

# View logs
logs-all

# Show system info
banner
```

## 🎯 GPU Commands

```bash
gpu                 # GPU stats
gpu-temp            # Temperature only
gpu-watch           # Live monitoring
test-gpu            # Run GPU tests
debug-gpu           # Debug info
show-temps          # CPU + GPU temps
```

## 🤖 llama-server (Port 8080)

```bash
llama-status        # Check if running
llama-health        # Health check
llama-restart       # Restart server
llama-logs          # View logs
test-llama          # Test API
```

## 📦 Ollama

```bash
ollama run <model>  # Run a model
ollama ps           # Show running
ollama-status       # Service status
ollama-logs         # View logs
```

## 🎨 LM Studio (Port 1234)

```bash
lms-status          # Server status
lms-models          # Show loaded models
lm-gpt              # Load GPT-OSS
lm-deepseek         # Load DeepSeek
```

## 🏗️ TheRock Build

```bash
rock                # Go to TheRock dir
rock-build          # Build project
rock-test           # Run tests
ccache-stats        # Cache stats
```

## 🔍 System Check

```bash
check-all           # Check everything
sys-all             # System + GPU info
show-models         # Loaded models
show-temps          # Temperatures
```

## 🔧 Environment

```bash
use-rocm-native     # Native gfx1031
use-rocm-compat     # Compatibility gfx1030
show-rocm-env       # Show ROCm vars
venv-rock           # Activate Python venv
```

## 📊 Monitoring

```bash
temps               # Live temp monitor
gpustat             # Live GPU stats
logs-all            # All service logs
banner              # Show banner again
```

## 🧪 Testing

```bash
test-rocm           # Test ROCm detection
test-hip            # Test HIP compilation
test-gpu            # Full GPU test
test-llama          # Test llama API
```

______________________________________________________________________

## 🚀 Common Workflows

### Start Everything

```bash
llama-status && lms-status && gpu
```

### Full Health Check

```bash
check-all
```

### Debug GPU Issues

```bash
debug-gpu
test-gpu
show-rocm-env
```

### Monitor System

```bash
# Terminal 1: GPU
gpu-watch

# Terminal 2: Logs
llama-logs

# Terminal 3: Temperature
temps
```

### Switch ROCm Mode

```bash
# For maximum compatibility
use-rocm-compat

# For maximum performance
use-rocm-native
```

______________________________________________________________________

## 📝 Quick Reference

| Service      | Port  | Health Check   |
| ------------ | ----- | -------------- |
| llama-server | 8080  | `llama-health` |
| LM Studio    | 1234  | `lms-status`   |
| Ollama       | 11434 | `ollama ps`    |

| File                     | Purpose                |
| ------------------------ | ---------------------- |
| `QUICK_COMMANDS.md`      | Full command reference |
| `TEST_RESULTS.md`        | System test results    |
| `COMMANDS_CHEATSHEET.md` | This file              |

______________________________________________________________________

**💡 Tip:** Type any command + `--help` or `-h` for more options

**🔄 Reload:** Run `source ~/.bashrc` (or `~/.zshrc`) to reload aliases

**📚 Help:** See `QUICK_COMMANDS.md` for detailed documentation
