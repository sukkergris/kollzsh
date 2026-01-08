# koll.zsh

```
  :###:
  :   :
  :   :
.'     '.
:       :
|_______|
|kollzsh|
|‐‐‐‐‐‐‐|
|       |
:_______:
```
koll.zsh: keyvez ollama for zsh

<img src="demo.svg" alt="Kollzsh Demo" width="600">

An [`oh-my-zsh`](https://ohmyz.sh) plugin that integrates the OLLAMA AI model
with [fzf](https://github.com/junegunn/fzf) to provide intelligent command
suggestions based on user input requirements.

## Features

* **Intelligent Command Suggestions**: Use OLLAMA, MLX, or llama.cpp to generate relevant
  terminal commands based on your query or input requirement.
* **FZF Integration**: Interactively select suggested commands using FZF's fuzzy
  finder, ensuring you find the right command for your task.
* **MLX Support**: Run models locally on Apple Silicon using MLX framework for
  faster inference without a server.
* **llama.cpp Support**: Run GGUF models locally using llama.cpp for cross-platform
  local inference.
* **Thinking Mode**: Use Ctrl-t to run queries in thinking mode (MLX only) for
  more complex reasoning tasks.
* **REPL Mode**: Interactive shell with history support - execute commands and see
  output directly, with options to edit, copy, or run.
* **Customizable**: Configure default shortcut, model, platform, and response number
  to suit your workflow.

## Installation

### Building from source (recommended)

The plugin includes a Rust binary for fast command generation. To build:

```bash
# Clone the repository
git clone https://github.com/keyvez/kollzsh.git ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/kollzsh

# Build the Rust binary
cd ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/kollzsh
cargo build --release
```

If you don't have Rust installed, the plugin will fall back to Python scripts automatically.

### Requirements

**Core Requirements:**
* `fzf` for interactive selection of commands

**With Rust binary (recommended):**
* Rust toolchain (`rustup` + `cargo`) for building

**Without Rust binary (fallback):**
* `python3` with `httpx` package

### Platform-specific Requirements

#### For Ollama (default)
* `OLLAMA` server running

#### For MLX (Apple Silicon)
* `uv` package manager ([install](https://docs.astral.sh/uv/getting-started/installation/))
* Apple Silicon Mac (M1/M2/M3/M4)

Dependencies (`mlx-lm`, `transformers`) are automatically managed by `uv` at runtime.

#### For llama.cpp
* llama.cpp installation with `llama-cli` or `llama-server` binary
* A GGUF model file

#### For vLLM
* vLLM server running (`pip install vllm`)
* NVIDIA GPU with CUDA support

## Configuration Variables

The following environment variables can be set to customize the behavior:

| Variable Name               | Description                                        | Default Value              |
|-----------------------------|---------------------------------------------------|----------------------------|
| `KOLLZSH_PLATFORM`          | Platform to use (`ollama`, `MLX`, `llamacpp`, or `vllm`) | `ollama`              |
| `KOLLZSH_MODEL`             | Model to use for command generation               | `qwen2.5-coder:3b`         |
| `KOLLZSH_HOTKEY`            | Default shortcut key for triggering the plugin    | `^o` (Ctrl-o)              |
| `KOLLZSH_THINKING_HOTKEY`   | Shortcut key for thinking mode (MLX only)         | `^t` (Ctrl-t)              |
| `KOLLZSH_REPL_HOTKEY`       | Shortcut key for REPL mode                        | `^x^o` (Ctrl-x Ctrl-o)     |
| `KOLLZSH_COMMAND_COUNT`     | Number of command suggestions displayed           | `5`                        |
| `KOLLZSH_URL`               | API endpoint URL (Ollama only)                    | `http://localhost:11434`   |
| `KOLLZSH_API_KEY`           | API key for external APIs (DeepSeek/OpenAI)       | None                       |
| `KOLLZSH_MAX_TOKENS`        | Maximum tokens for MLX response                   | `1024`                     |
| `KOLLZSH_LLAMACPP_PATH`     | Path to llama.cpp installation directory          | None                       |
| `KOLLZSH_LLAMACPP_MODEL`    | Path to GGUF model file for llama.cpp             | None                       |
| `KOLLZSH_LLAMACPP_SERVER_URL` | llama.cpp server URL                            | `http://localhost:8080`    |
| `KOLLZSH_LLAMACPP_N_CTX`    | Context size for llama.cpp                        | `2048`                     |
| `KOLLZSH_LLAMACPP_N_GPU_LAYERS` | GPU layers for llama.cpp (-1 for all)         | `-1`                       |
| `KOLLZSH_VLLM_SERVER_URL`   | vLLM server URL                                   | `http://localhost:8000`    |
| `KOLLZSH_VLLM_MODEL`        | Model name for vLLM                               | None (auto-detect)         |

### Example: DeepSeek API Configuration

| Variable Name         | Value                                                                                                   |
|----------------------|---------------------------------------------------------------------------------------------------------|
| `KOLLZSH_URL`        | `https://api.deepseek.com`                                                                              |
| `KOLLZSH_API_KEY`    | apply for an API key ([https://platform.deepseek.com/api_keys](https://platform.deepseek.com/api_keys)) |
| `KOLLZSH_MODEL`      | `deepseek-chat`                                                                                         |

```bash
# Use DeepSeek API
export KOLLZSH_URL="https://api.deepseek.com"
export KOLLZSH_API_KEY="your_api_key_here"
export KOLLZSH_MODEL="deepseek-chat"
```

### Example: OpenAI API Configuration

| Variable Name         | Value                                                                                                   |
|----------------------|---------------------------------------------------------------------------------------------------------|
| `KOLLZSH_URL`        | `https://api.openai.com`                                                                                |
| `KOLLZSH_API_KEY`    | apply for an API key ([https://platform.openai.com/api-keys](https://platform.openai.com/api-keys))     |
| `KOLLZSH_MODEL`      | `gpt-4-turbo-preview`                                                                                   |

```bash
# Use OpenAI API
export KOLLZSH_URL="https://api.openai.com"
export KOLLZSH_API_KEY="your_api_key_here"
export KOLLZSH_MODEL="gpt-4-turbo-preview"
```

### Example: MLX Configuration (Apple Silicon)

| Variable Name         | Value                                    |
|----------------------|------------------------------------------|
| `KOLLZSH_PLATFORM`   | `MLX`                                    |
| `KOLLZSH_MODEL`      | `Qwen/Qwen3-14B-MLX-4bit`               |

```bash
# Use local MLX model on Apple Silicon
export KOLLZSH_PLATFORM="MLX"
export KOLLZSH_MODEL="Qwen/Qwen3-14B-MLX-4bit"

# Optional: increase max tokens for longer responses
export KOLLZSH_MAX_TOKENS="2048"
```

**Available MLX Models:**
- `Qwen/Qwen3-14B-MLX-4bit` - Recommended for general use
- `Qwen/Qwen3-8B-MLX-4bit` - Faster, smaller model
- `mlx-community/Llama-3.2-3B-Instruct-4bit` - Llama-based alternative
- Any model from [mlx-community](https://huggingface.co/mlx-community)

**Thinking Mode (Ctrl-t):**
When using MLX platform, press Ctrl-t to run your query in thinking mode. This
enables the model's internal reasoning (using `<think>` tags) for more complex
tasks. The thinking process and response will be displayed in the terminal.

### Example: llama.cpp Configuration

llama.cpp supports two modes: **CLI mode** (runs llama-cli directly) and **server mode**
(connects to llama-server). CLI mode is used automatically when no server is running.

| Variable Name               | Value                                    |
|-----------------------------|------------------------------------------|
| `KOLLZSH_PLATFORM`          | `llamacpp`                               |
| `KOLLZSH_LLAMACPP_PATH`     | `/path/to/llama.cpp`                     |
| `KOLLZSH_LLAMACPP_MODEL`    | `/path/to/model.gguf`                    |

**CLI Mode (recommended for simplicity):**

```bash
# Configure llama.cpp platform with CLI mode
export KOLLZSH_PLATFORM="llamacpp"
export KOLLZSH_LLAMACPP_PATH="/home/user/llama.cpp"
export KOLLZSH_LLAMACPP_MODEL="/home/user/models/qwen2.5-coder-3b-q4_k_m.gguf"

# Optional: customize inference settings
export KOLLZSH_LLAMACPP_N_CTX="4096"
export KOLLZSH_LLAMACPP_N_GPU_LAYERS="-1"  # -1 for all layers on GPU
```

With CLI mode, llama-cli runs directly each time you press Ctrl-o. No server needed!

**Server Mode (for faster repeated queries):**

If you have llama-server running, it will be used automatically for faster responses:

```bash
# Start server manually
llama-server -m /path/to/model.gguf -c 2048 -ngl -1 --port 8080

# Or use the helper function
kollzsh-start-llamacpp
```

```bash
# If you only have a server running (no CLI), just set the URL
export KOLLZSH_PLATFORM="llamacpp"
export KOLLZSH_LLAMACPP_SERVER_URL="http://localhost:8080"
```

**Recommended GGUF Models:**
- `qwen2.5-coder-3b-instruct-q4_k_m.gguf` - Good balance of speed and quality
- `qwen2.5-coder-7b-instruct-q4_k_m.gguf` - Better quality, more resources
- Any instruction-tuned GGUF model from [Hugging Face](https://huggingface.co/models?library=gguf)

### Example: vLLM Configuration

| Variable Name               | Value                                    |
|-----------------------------|------------------------------------------|
| `KOLLZSH_PLATFORM`          | `vllm`                                   |
| `KOLLZSH_VLLM_MODEL`        | `Qwen/Qwen2.5-Coder-3B-Instruct`        |

```bash
# Configure vLLM platform
export KOLLZSH_PLATFORM="vllm"
export KOLLZSH_VLLM_MODEL="Qwen/Qwen2.5-Coder-3B-Instruct"

# Optional: customize server URL (default is port 8000)
export KOLLZSH_VLLM_SERVER_URL="http://localhost:8000"
```

**Starting the server:**

The vLLM server is NOT auto-started on shell init. Use the helper function:

```bash
# Start the server using the helper function
kollzsh-start-vllm

# Stop the server when done
kollzsh-stop-vllm
```

**Or start manually:**
```bash
vllm serve Qwen/Qwen2.5-Coder-3B-Instruct --port 8000
```

**Using with an already running server:**
```bash
# If you already have vLLM running, just set the platform
export KOLLZSH_PLATFORM="vllm"
export KOLLZSH_VLLM_SERVER_URL="http://localhost:8000"
# Model is auto-detected from the running server
```

**Recommended vLLM Models:**
- `Qwen/Qwen2.5-Coder-3B-Instruct` - Fast, good for command generation
- `Qwen/Qwen2.5-Coder-7B-Instruct` - Better quality
- `mistralai/Ministral-3B-Instruct-2412` - Lightweight alternative
- Any instruction-tuned model supported by vLLM

## Usage

1. Clone the repository to `oh-my-zsh` custom plugin folder
    ```bash
    git clone https://github.com/keyvez/kollzsh.git ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/kollzsh
    ```

2. Build the Rust binary (optional but recommended for faster startup):
    ```bash
    cd ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/kollzsh
    cargo build --release
    ```

3. Enable the plugin in ~/.zshrc:
    ```bash
    plugins=(
      [plugins...]
      kollzsh
    )
    ```

4. Input what you want to do then trigger the plugin:
   - Press **Ctrl-o** (default) to get command suggestions via fzf
   - Press **Ctrl-t** (MLX only) to run in thinking mode for complex queries
   - Press **Ctrl-x Ctrl-o** (or type `kollzsh-repl`) to enter REPL mode

5. Interact with FZF: Type a query or input requirement, and FZF will display
   suggested terminal commands. Select one to execute.

### REPL Mode (Ctrl-x Ctrl-o or `kollzsh-repl`)

REPL mode provides an interactive shell for exploring AI-generated commands:

```
╔════════════════════════════════════════════════════════════╗
║  🍺 KOLLZSH REPL  (AI-powered command suggestions)        ║
╠════════════════════════════════════════════════════════════╣
║  • Type a task description and press Enter                ║
║  • Use ↑/↓ arrows to navigate history                     ║
║  • Select a command with fzf, then choose to run it       ║
║  • Type 'exit', 'quit', or press Ctrl-C/Ctrl-D to exit    ║
╚════════════════════════════════════════════════════════════╝

kollzsh> list all docker containers
```

After selecting a command from fzf, you can:
- **[r]un** - Execute the command and see its output
- **[e]dit** - Modify the command before running
- **[c]opy** - Copy to clipboard
- **[s]kip** - Skip and ask a new question

History is persisted to `~/.local/share/kollzsh/repl_history`.

**Get Started**

Experience the power of AI-driven command suggestions in your MacOS terminal! This
plugin is perfect for developers, system administrators, and anyone looking to
streamline their workflow.

Let me know if you have any specific requests or changes!

![Kollzsh Beer](kollzsh_beer.png)