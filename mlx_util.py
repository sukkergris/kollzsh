#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.10"
# dependencies = [
#     "transformers>=4.52.4",
#     "mlx-lm>=0.26.0",
# ]
# ///
"""
MLX Model Utility for kollzsh
Runs local MLX models on Apple Silicon for command generation.
Based on mlx_backend.py
"""

import os
import sys
import re
import json
import logging
import platform

# Disable tokenizers parallelism to avoid fork warnings
os.environ["TOKENIZERS_PARALLELISM"] = "false"
# Disable progress bars
os.environ["HF_HUB_DISABLE_PROGRESS_BARS"] = "1"
os.environ["TQDM_DISABLE"] = "1"

# Import after setting env vars
from mlx_lm import load, generate

# Configure logging
LOG_FILE = '/tmp/kollzsh_debug.log'
logging.basicConfig(
    filename=LOG_FILE,
    level=logging.DEBUG,
    format='[%(asctime)s] %(message)s',
    datefmt='%Y-%m-%d %H:%M:%S'
)


def log_debug(*messages):
    """Log debug messages."""
    message = ' '.join(str(m) for m in messages)
    logging.debug(message)


def clean_response(response):
    """Remove thinking tags from response."""
    cleaned = re.sub(r'<think>.*?</think>\s*', '', response, flags=re.DOTALL)
    return cleaned.strip()


def extract_commands_from_response(text):
    """Extract shell commands from the model response."""
    # Try to find JSON array of commands
    json_match = re.search(r'\[.*?\]', text, re.DOTALL)
    if json_match:
        try:
            commands = json.loads(json_match.group())
            if isinstance(commands, list) and all(isinstance(c, str) for c in commands):
                return commands
        except json.JSONDecodeError:
            pass

    # Try to find commands in code blocks
    code_block_pattern = r'```(?:bash|sh|shell|zsh)?\s*\n(.*?)```'
    code_blocks = re.findall(code_block_pattern, text, re.DOTALL | re.IGNORECASE)
    if code_blocks:
        commands = []
        for block in code_blocks:
            for line in block.strip().split('\n'):
                line = line.strip()
                if line and not line.startswith('#'):
                    commands.append(line)
        if commands:
            return commands

    # Try to find inline code commands
    inline_pattern = r'`([^`]+)`'
    inline_commands = re.findall(inline_pattern, text)
    if inline_commands:
        # Filter to likely shell commands
        shell_commands = [cmd for cmd in inline_commands
                         if any(cmd.startswith(prefix) for prefix in
                               ['ls', 'cd', 'cat', 'grep', 'find', 'mkdir', 'rm', 'cp', 'mv',
                                'echo', 'pwd', 'chmod', 'chown', 'curl', 'wget', 'git', 'docker',
                                'npm', 'pip', 'python', 'node', 'brew', 'apt', 'sudo'])]
        if shell_commands:
            return shell_commands

    return []


def interact_with_mlx(user_query, thinking_mode=False):
    """Interact with local MLX model to get command suggestions."""
    model_name = os.getenv('KOLLZSH_MODEL', 'Qwen/Qwen3-14B-MLX-4bit')
    max_tokens = int(os.getenv('KOLLZSH_MAX_TOKENS', '1024'))

    log_debug(f"Loading MLX model: {model_name}")

    try:
        model, tokenizer = load(model_name)
    except Exception as e:
        log_debug(f"Error loading model: {e}")
        return []

    # Format the prompt for command generation
    formatted_query = f"""Generate shell commands for the following task on {platform.system()}: {user_query}

Return the commands as a JSON array of strings, like: ["command1", "command2"]
Only return the JSON array, no explanation."""

    log_debug(f"Sending query: {formatted_query}")

    messages = [{"role": "user", "content": formatted_query}]

    # Apply chat template
    if tokenizer.chat_template is not None:
        formatted_prompt = tokenizer.apply_chat_template(
            messages,
            add_generation_prompt=True,
            enable_thinking=thinking_mode,
        )
    else:
        formatted_prompt = formatted_query

    log_debug("Generating response...")

    try:
        response = generate(
            model,
            tokenizer,
            prompt=formatted_prompt,
            verbose=False,
            max_tokens=max_tokens,
        )
    except Exception as e:
        log_debug(f"Error generating response: {e}")
        return []

    log_debug(f"Raw response: {response}")

    # Clean response
    cleaned_response = clean_response(response)

    # Extract commands from the response
    commands = extract_commands_from_response(cleaned_response)

    log_debug(f"Extracted commands: {commands}")

    return commands


def interact_with_mlx_thinking(user_query):
    """Interact with MLX model in thinking mode for complex queries."""
    model_name = os.getenv('KOLLZSH_MODEL', 'Qwen/Qwen3-14B-MLX-4bit')
    max_tokens = int(os.getenv('KOLLZSH_MAX_TOKENS', '2048'))

    log_debug(f"Loading MLX model (thinking mode): {model_name}")

    try:
        model, tokenizer = load(model_name)
    except Exception as e:
        log_debug(f"Error loading model: {e}")
        return ""

    log_debug(f"Thinking mode query: {user_query}")

    messages = [{"role": "user", "content": user_query}]

    # Apply chat template with thinking enabled
    if tokenizer.chat_template is not None:
        formatted_prompt = tokenizer.apply_chat_template(
            messages,
            add_generation_prompt=True,
            enable_thinking=True,
        )
    else:
        formatted_prompt = user_query

    log_debug("Generating thinking response...")

    try:
        response = generate(
            model,
            tokenizer,
            prompt=formatted_prompt,
            verbose=False,
            max_tokens=max_tokens,
        )
    except Exception as e:
        log_debug(f"Error generating response: {e}")
        return f"Error: {e}"

    log_debug(f"Thinking response: {response}")

    return response


if __name__ == '__main__':
    if len(sys.argv) < 2:
        log_debug("Usage: mlx_util.py <user_query> [--thinking]")
        sys.exit(1)

    thinking_mode = '--thinking' in sys.argv
    args = [arg for arg in sys.argv[1:] if arg != '--thinking']
    user_query = ' '.join(args)

    if thinking_mode:
        # Thinking mode - return full response
        response = interact_with_mlx_thinking(user_query)
        if response:
            print(response)
        else:
            log_debug("No response generated")
            sys.exit(1)
    else:
        # Command mode - return commands
        commands = interact_with_mlx(user_query)

        if not commands:
            log_debug("No valid commands found")
            sys.exit(1)

        # Print each command on a new line
        for cmd in commands:
            print(cmd)

        log_debug("Successfully output commands")
