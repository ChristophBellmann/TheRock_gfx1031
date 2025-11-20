# 🤖 Crush AI Assistant - LM Studio Configuration

## ✅ Configuration Complete!

Crush is now configured to use **LM Studio** on port 1234 with GPU acceleration!

______________________________________________________________________

## 🚀 Quick Start

### 1. Load a Model in LM Studio

```bash
lm-deepseek   # Recommended for coding (8B, best reasoning)
# or
lm-gpt        # GPT-OSS 20B (balanced)
lm-claude     # Claude 3.7 (12B, good quality)
lm-liquid     # Liquid (1.2B, fastest)
```

### 2. Verify LM Studio is Running

```bash
lms-status
# Should show: Server: ON (port: 1234)
```

### 3. Launch Crush

```bash
crush
# or
crush-lms    # Explicitly use LM Studio (same as 'crush')
```

______________________________________________________________________

## 📋 Configuration Details

**File**: `~/.config/crush/crush.json`

**Default Provider**: LM Studio (port 1234)

**Configured Models**:

- **DeepSeek-R1** (gpt-3.5-turbo) - 16K context, 8K max tokens
- **GPT-OSS-20B** (gpt-4) - 16K context, 8K max tokens

**Alternative Providers**:

- **Ollama** (port 11434) - Use with `crush-ollama`
- **OpenRouter** (cloud) - Requires API key

______________________________________________________________________

## 🎯 Usage Examples

### Interactive Chat Mode

```bash
crush

# Inside Crush:
> Explain how to use goroutines in Go
> Write a function to parse JSON in Python
> Debug this code: [paste code]
```

### Single Command Mode

```bash
crush run "Explain the use of context in Go"
crush run "Write a Python script to calculate fibonacci"
crush run "What's the difference between sync.Mutex and sync.RWMutex?"
```

### Debug Mode

```bash
crush -d
# Shows detailed logging and API calls
```

### Custom Directory

```bash
crush -c /path/to/project
# Launch Crush in specific project directory
```

______________________________________________________________________

## 🔧 Aliases

| Alias          | Description                              |
| -------------- | ---------------------------------------- |
| `crush`        | Default: uses LM Studio                  |
| `crush-lms`    | Explicitly use LM Studio (same as crush) |
| `crush-ollama` | Use Ollama instead of LM Studio          |

______________________________________________________________________

## 🎨 Features

### Code Understanding

- Explain code snippets
- Analyze algorithms
- Review code for bugs
- Suggest improvements

### Code Generation

- Write functions/classes
- Generate test cases
- Create boilerplate code
- Implement algorithms

### LSP Integration

- Code analysis
- Symbol lookup
- Definition finding
- Workspace awareness

### Interactive Chat

- Multi-turn conversations
- Context retention
- Code-focused responses
- Terminal-based UI

______________________________________________________________________

## 📊 Provider Configuration

### LM Studio (Default - Port 1234)

```json
{
  "name": "LM Studio (GPU)",
  "base_url": "http://localhost:1234/v1/",
  "type": "openai",
  "api_key": "lm-studio",
  "models": [
    {
      "name": "DeepSeek-R1",
      "id": "gpt-3.5-turbo",
      "context_window": 16384,
      "default_max_tokens": 8192
    }
  ]
}
```

### Ollama (Alternative - Port 11434)

```json
{
  "name": "Ollama Local",
  "base_url": "http://localhost:11434/v1/",
  "type": "openai",
  "api_key": "ollama",
  "models": [
    {
      "name": "Qwen3-4b-instruct",
      "id": "hf.co/unsloth/Qwen3-4B-Instruct-2507-GGUF:latest",
      "context_window": 8192,
      "default_max_tokens": 4096
    }
  ]
}
```

______________________________________________________________________

## 🔄 Switching Providers

### Temporarily Use Ollama

```bash
crush-ollama
# or
CRUSH_PROVIDER=ollama crush
```

### Permanently Change Default

Edit `~/.config/crush/crush.json`:

```json
{
  "default_provider": "ollama",  // Change to "lmstudio" or "ollama"
  ...
}
```

______________________________________________________________________

## 💡 Tips & Tricks

### Best Models for Coding

**DeepSeek-R1** (Recommended):

- Best reasoning capabilities
- Excellent for complex code
- 8B parameters, good balance
- Load with: `lm-deepseek`

**GPT-OSS-20B**:

- Larger model (20B params)
- Good general knowledge
- Slower but more capable
- Load with: `lm-gpt`

**Liquid** (Fast):

- Smallest model (1.2B)
- Very fast responses
- Good for simple tasks
- Load with: `lm-liquid`

### Performance Optimization

1. **Context Window**: 16K tokens (plenty for most code)
1. **Max Tokens**: 8K output (adjust if needed)
1. **GPU Layers**: LM Studio auto-manages (99 layers for full GPU)
1. **VRAM Usage**: Monitor with `gpu` command

### Keyboard Shortcuts in Crush

- **Ctrl+C**: Cancel current operation
- **Ctrl+D**: Exit Crush
- **Up/Down Arrows**: Navigate history
- **Tab**: Code completion (if enabled)

______________________________________________________________________

## 🚨 Troubleshooting

### Crush Won't Connect

**Symptoms**: Connection refused, timeout

**Solutions**:

```bash
# 1. Check LM Studio is running
lms-status

# 2. Verify model is loaded
lms-models

# 3. Test API endpoint
curl http://localhost:1234/v1/models

# 4. Load a model if none loaded
lm-deepseek

# 5. Restart Crush
crush
```

### Wrong Model Being Used

**Symptoms**: Unexpected responses, poor quality

**Solutions**:

```bash
# Check config
cat ~/.config/crush/crush.json

# Verify provider
crush -d  # Shows which provider/model is used

# Switch to Ollama if needed
crush-ollama
```

### Slow Responses

**Symptoms**: Long wait times, timeouts

**Solutions**:

```bash
# Use smaller/faster model
lm-liquid

# Check GPU usage
gpu

# Monitor VRAM
watch -n 1 'gpu | grep -E "Temp|VRAM"'

# Restart LM Studio
lms-restart
```

### Debug Mode

For detailed troubleshooting:

```bash
crush -d
# Shows all API calls, responses, and errors
```

______________________________________________________________________

## 📈 Performance Notes

### Current Setup

**LM Studio** (Port 1234):

- GPU Acceleration: ✅ Full (99 layers)
- VRAM Usage: ~2-4GB (depends on model)
- Response Time: Fast (GPU-accelerated)
- Context: 16K tokens
- Max Output: 8K tokens

**Recommended Models by Use Case**:

**Quick Questions**: Liquid (1.2B)

- VRAM: ~1-2GB
- Speed: Very fast
- Quality: Good for simple tasks

**General Coding**: DeepSeek-R1 (8B)

- VRAM: ~3-5GB
- Speed: Fast
- Quality: Excellent reasoning

**Complex Tasks**: GPT-OSS (20B)

- VRAM: ~8-10GB
- Speed: Moderate
- Quality: Best overall

______________________________________________________________________

## 🎯 Example Workflows

### Code Review

```bash
crush

> Review this function for potential bugs:
> [paste code]
>
> What are the edge cases I should test?
> How can I improve performance?
```

### Learning New Language

```bash
crush run "Explain Python decorators with examples"
crush run "Show me how to use channels in Go"
crush run "What's the difference between let, const, and var in JavaScript?"
```

### Debugging

```bash
crush

> I'm getting a segfault in this C code:
> [paste code]
>
> What could be causing this?
> How do I use gdb to debug it?
```

### Code Generation

```bash
crush run "Write a Python function to merge two sorted lists"
crush run "Create a React component for a todo list"
crush run "Generate a Makefile for a C++ project"
```

______________________________________________________________________

## 📁 Files & Directories

**Configuration**:

- `~/.config/crush/crush.json` - Main config (provider settings)
- `~/.crush/` - Data directory (history, DB, logs)
- `~/.crush/commands/` - Custom commands
- `~/.crush/logs/` - Debug logs

**Aliases**:

- `~/.bashrc` - Bash aliases (lines 319-320)
- `~/.zshrc` - Zsh aliases (lines 367-368)

______________________________________________________________________

## ✅ Summary

✅ **Configured**: Crush → LM Studio (port 1234)
✅ **Default Provider**: LM Studio (GPU-accelerated)
✅ **Models Available**: DeepSeek-R1, GPT-OSS-20B
✅ **Alternatives**: Ollama (port 11434) via `crush-ollama`
✅ **Aliases**: `crush`, `crush-lms`, `crush-ollama`

**Ready to use!** Just type `crush` after loading a model! 🚀

______________________________________________________________________

## 🔗 Quick Reference

```bash
# Load a model
lm-deepseek

# Check status
lms-status

# Launch Crush
crush

# Use Ollama instead
crush-ollama

# Run single command
crush run "your question"

# Debug mode
crush -d
```

______________________________________________________________________

*Last Updated: 2025-11-19*
*Default Provider: LM Studio (port 1234)*
*Models: DeepSeek-R1, GPT-OSS-20B*
