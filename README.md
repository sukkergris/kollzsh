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

* **Intelligent Command Suggestions**: Use OLLAMA or MLX to generate relevant MacOS
  terminal commands based on your query or input requirement.
* **FZF Integration**: Interactively select suggested commands using FZF's fuzzy
  finder, ensuring you find the right command for your task.
* **MLX Support**: Run models locally on Apple Silicon using MLX framework for
  faster inference without a server.
* **Thinking Mode**: Use Ctrl-t to run queries in thinking mode (MLX only) for
  more complex reasoning tasks.
* **Customizable**: Configure default shortcut, model, platform, and response number
  to suit your workflow.

## Requirements

### For Ollama (default)
* `jq` for parsing JSON responses
* `fzf` for interactive selection of commands
* `curl` for making API requests
* `OLLAMA` server running

### For MLX (Apple Silicon)
* `jq` for parsing JSON responses
* `fzf` for interactive selection of commands
* `uv` package manager ([install](https://docs.astral.sh/uv/getting-started/installation/))
* Apple Silicon Mac (M1/M2/M3/M4)

Dependencies (`mlx-lm`, `transformers`) are automatically managed by `uv` at runtime.

## Configuration Variables

The following environment variables can be set to customize the behavior:

| Variable Name             | Description                                        | Default Value              |
|---------------------------|---------------------------------------------------|----------------------------|
| `KOLLZSH_PLATFORM`        | Platform to use (`ollama` or `MLX`)               | `ollama`                   |
| `KOLLZSH_MODEL`           | Model to use for command generation               | `qwen2.5-coder:3b`         |
| `KOLLZSH_HOTKEY`          | Default shortcut key for triggering the plugin    | `^o` (Ctrl-o)              |
| `KOLLZSH_THINKING_HOTKEY` | Shortcut key for thinking mode (MLX only)         | `^t` (Ctrl-t)              |
| `KOLLZSH_COMMAND_COUNT`   | Number of command suggestions displayed           | `5`                        |
| `KOLLZSH_URL`             | API endpoint URL (Ollama only)                    | `http://localhost:11434`   |
| `KOLLZSH_API_KEY`         | API key for external APIs (DeepSeek/OpenAI)       | None                       |
| `KOLLZSH_MAX_TOKENS`      | Maximum tokens for MLX response                   | `1024`                     |

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

## Usage

1. Clone the repository to `oh-my-zsh` custom plugin folder
    ```bash
    git clone https://github.com/keyvez/kollzsh.git ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/kollzsh
    ```

2. Enable the plugin in ~/.zshrc:
    ```bash
    plugins=(
      [plugins...]
      kollzsh
    )
    ```
3. Input what you want to do then trigger the plugin:
   - Press **Ctrl-o** (default) to get command suggestions via fzf
   - Press **Ctrl-t** (MLX only) to run in thinking mode for complex queries
4. Interact with FZF: Type a query or input requirement, and FZF will display
   suggested MacOS terminal commands. Select one to execute.

**Get Started**

Experience the power of AI-driven command suggestions in your MacOS terminal! This
plugin is perfect for developers, system administrators, and anyone looking to
streamline their workflow.

Let me know if you have any specific requests or changes!

![Kollzsh Beer](kollzsh_beer.png)