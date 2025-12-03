#!/usr/bin/env python3
"""
llama.cpp Utility for kollzsh
Interacts with llama.cpp server or runs llama-cli directly for command generation.
"""

import os
import sys
import re
import json
import logging
import platform
import subprocess
import shutil

try:
    import httpx
    HAS_HTTPX = True
except ImportError:
    HAS_HTTPX = False

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


def extract_commands_from_response(text):
    """Extract shell commands from the model response."""
    # Try to find JSON array in code blocks first (```json ... ```)
    json_block_pattern = r'```(?:json)?\s*\n?([\[\{].*?[\]\}])\s*\n?```'
    json_block_match = re.search(json_block_pattern, text, re.DOTALL | re.IGNORECASE)
    if json_block_match:
        try:
            commands = json.loads(json_block_match.group(1))
            if isinstance(commands, list) and all(isinstance(c, str) for c in commands):
                return commands
        except json.JSONDecodeError:
            pass

    # Try to find JSON array of commands anywhere in text
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
                                'npm', 'pip', 'python', 'node', 'brew', 'apt', 'sudo', 'jq'])]
        if shell_commands:
            return shell_commands

    return []


def find_llama_cli():
    """Find llama-cli binary."""
    llama_path = os.getenv('KOLLZSH_LLAMACPP_PATH', '')

    # Check in KOLLZSH_LLAMACPP_PATH first
    if llama_path:
        candidates = [
            os.path.join(llama_path, 'llama-cli'),
            os.path.join(llama_path, 'build', 'bin', 'llama-cli'),
            os.path.join(llama_path, 'main'),  # older name
            os.path.join(llama_path, 'build', 'bin', 'main'),
        ]
        for candidate in candidates:
            if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
                return candidate

    # Check in PATH
    for name in ['llama-cli', 'main']:
        found = shutil.which(name)
        if found:
            return found

    return None


def interact_with_llamacpp_cli(user_query):
    """Run llama-cli directly to get command suggestions."""
    model_path = os.getenv('KOLLZSH_LLAMACPP_MODEL', '')
    n_ctx = os.getenv('KOLLZSH_LLAMACPP_N_CTX', '2048')
    n_gpu_layers = os.getenv('KOLLZSH_LLAMACPP_N_GPU_LAYERS', '-1')

    if not model_path:
        log_debug("KOLLZSH_LLAMACPP_MODEL not set")
        return []

    if not os.path.isfile(model_path):
        log_debug(f"Model file not found: {model_path}")
        return []

    llama_cli = find_llama_cli()
    if not llama_cli:
        log_debug("llama-cli not found")
        return []

    log_debug(f"Using llama-cli: {llama_cli}")
    log_debug(f"Using model: {model_path}")

    # Format the prompt for command generation
    formatted_query = f"""Generate shell commands for the following task on {platform.system()}: {user_query}

Return the commands as a JSON array of strings, like: ["command1", "command2"]
Only return the JSON array, no explanation."""

    log_debug(f"Sending query: {formatted_query}")

    try:
        cmd = [
            llama_cli,
            '-m', model_path,
            '-c', n_ctx,
            '-ngl', n_gpu_layers,
            '-n', '512',
            '--temp', '0.7',
            '-p', formatted_query,
            '--no-display-prompt',
        ]

        log_debug(f"Running command: {cmd}")

        result = subprocess.run(
            cmd,
            capture_output=True,
            timeout=120,
        )

        if result.returncode != 0:
            log_debug(f"llama-cli failed with code {result.returncode}")
            log_debug(f"stderr: {result.stderr}")
            return []

        # Decode output, handling potential encoding issues
        try:
            content = result.stdout.decode('utf-8', errors='replace').strip()
        except Exception:
            content = result.stdout.decode('latin-1', errors='replace').strip()

        log_debug(f"Raw output: {content}")

        commands = extract_commands_from_response(content)
        log_debug(f"Extracted commands: {commands}")

        return commands

    except subprocess.TimeoutExpired:
        log_debug("llama-cli timed out")
        return []
    except Exception as e:
        log_debug(f"Error running llama-cli: {e}")
        return []


def is_server_running():
    """Check if llama.cpp server is running."""
    if not HAS_HTTPX:
        return False

    server_url = os.getenv('KOLLZSH_LLAMACPP_SERVER_URL', 'http://localhost:8080')
    try:
        with httpx.Client(timeout=2.0) as client:
            response = client.get(f"{server_url}/health")
            return response.status_code == 200
    except Exception:
        return False


def interact_with_llamacpp_server(user_query):
    """Interact with llama.cpp server to get command suggestions."""
    if not HAS_HTTPX:
        log_debug("httpx not available, cannot use server mode")
        return []

    server_url = os.getenv('KOLLZSH_LLAMACPP_SERVER_URL', 'http://localhost:8080')

    log_debug(f"Connecting to llama.cpp server at: {server_url}")

    # Format the prompt for command generation
    formatted_query = f"""Generate shell commands for the following task on {platform.system()}: {user_query}

Return the commands as a JSON array of strings, like: ["command1", "command2"]
Only return the JSON array, no explanation."""

    log_debug(f"Sending query: {formatted_query}")

    try:
        with httpx.Client(timeout=60.0) as client:
            # llama.cpp server uses /completion endpoint
            response = client.post(
                f"{server_url}/completion",
                json={
                    "prompt": formatted_query,
                    "n_predict": 512,
                    "temperature": 0.7,
                    "stop": ["\n\n", "```\n\n"],
                }
            )
            response.raise_for_status()
            data = response.json()

            log_debug(f"Received response: {data}")

            content = data.get('content', '')
            if not content:
                log_debug("No content in response")
                return []

            log_debug(f"Raw content: {content}")

            # Extract commands from the response
            commands = extract_commands_from_response(content)

            log_debug(f"Extracted commands: {commands}")

            return commands

    except httpx.ConnectError as e:
        log_debug(f"Connection error: {e}")
        return []
    except Exception as e:
        log_debug(f"Error interacting with llama.cpp: {e}")
        return []


def interact_with_llamacpp_chat(user_query):
    """Interact with llama.cpp server using chat completions API (OpenAI compatible)."""
    if not HAS_HTTPX:
        log_debug("httpx not available, cannot use server mode")
        return []

    server_url = os.getenv('KOLLZSH_LLAMACPP_SERVER_URL', 'http://localhost:8080')

    log_debug(f"Connecting to llama.cpp server (chat API) at: {server_url}")

    # Format the prompt for command generation
    formatted_query = f"""Generate shell commands for the following task on {platform.system()}: {user_query}

Return the commands as a JSON array of strings, like: ["command1", "command2"]
Only return the JSON array, no explanation."""

    log_debug(f"Sending query: {formatted_query}")

    try:
        with httpx.Client(timeout=60.0) as client:
            # Try OpenAI-compatible chat completions endpoint first
            response = client.post(
                f"{server_url}/v1/chat/completions",
                json={
                    "messages": [
                        {"role": "user", "content": formatted_query}
                    ],
                    "temperature": 0.7,
                    "max_tokens": 512,
                }
            )
            response.raise_for_status()
            data = response.json()

            log_debug(f"Received chat response: {data}")

            if 'choices' in data and data['choices']:
                content = data['choices'][0].get('message', {}).get('content', '')
                if content:
                    commands = extract_commands_from_response(content)
                    log_debug(f"Extracted commands: {commands}")
                    return commands

            return []

    except httpx.HTTPStatusError as e:
        if e.response.status_code == 404:
            # Fall back to completion endpoint
            log_debug("Chat API not available, falling back to completion endpoint")
            return interact_with_llamacpp_server(user_query)
        raise
    except httpx.ConnectError as e:
        log_debug(f"Connection error: {e}")
        return []
    except Exception as e:
        log_debug(f"Error interacting with llama.cpp: {e}")
        return []


if __name__ == '__main__':
    if len(sys.argv) < 2:
        log_debug("Usage: llamacpp_util.py <user_query>")
        sys.exit(1)

    user_query = ' '.join(sys.argv[1:])

    # Check if server is running, otherwise use CLI directly
    if is_server_running():
        log_debug("Server is running, using server mode")
        commands = interact_with_llamacpp_chat(user_query)
    else:
        log_debug("Server not running, using CLI mode")
        commands = interact_with_llamacpp_cli(user_query)

    if not commands:
        log_debug("No valid commands found")
        sys.exit(1)

    # Print each command on a new line
    for cmd in commands:
        print(cmd)

    log_debug("Successfully output commands")
