#!/usr/bin/env python3
"""
vLLM Utility for kollzsh
Interacts with vLLM server (OpenAI-compatible API) for command generation.
"""

import os
import sys
import re
import json
import logging
import platform
import httpx

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


def interact_with_vllm(user_query):
    """Interact with vLLM server to get command suggestions."""
    server_url = os.getenv('KOLLZSH_VLLM_SERVER_URL', 'http://localhost:8000')
    model = os.getenv('KOLLZSH_VLLM_MODEL', '')

    log_debug(f"Connecting to vLLM server at: {server_url}")

    # Format the prompt for command generation
    formatted_query = f"""Generate shell commands for the following task on {platform.system()}: {user_query}

Return the commands as a JSON array of strings, like: ["command1", "command2"]
Only return the JSON array, no explanation."""

    log_debug(f"Sending query: {formatted_query}")

    try:
        with httpx.Client(timeout=60.0) as client:
            # First, get available models if model not specified
            if not model:
                try:
                    models_response = client.get(f"{server_url}/v1/models")
                    models_response.raise_for_status()
                    models_data = models_response.json()
                    if models_data.get('data'):
                        model = models_data['data'][0]['id']
                        log_debug(f"Using model: {model}")
                except Exception as e:
                    log_debug(f"Could not fetch models: {e}")
                    # Try without model specification
                    pass

            # Build request payload
            payload = {
                "messages": [
                    {"role": "user", "content": formatted_query}
                ],
                "temperature": 0.7,
                "max_tokens": 512,
            }

            if model:
                payload["model"] = model

            # Use OpenAI-compatible chat completions endpoint
            response = client.post(
                f"{server_url}/v1/chat/completions",
                json=payload
            )
            response.raise_for_status()
            data = response.json()

            log_debug(f"Received response: {data}")

            if 'choices' in data and data['choices']:
                content = data['choices'][0].get('message', {}).get('content', '')
                if content:
                    log_debug(f"Raw content: {content}")
                    commands = extract_commands_from_response(content)
                    log_debug(f"Extracted commands: {commands}")
                    return commands

            return []

    except httpx.ConnectError as e:
        log_debug(f"Connection error: {e}")
        log_debug("Make sure vLLM server is running")
        return []
    except httpx.HTTPStatusError as e:
        log_debug(f"HTTP error: {e}")
        log_debug(f"Response: {e.response.text}")
        return []
    except Exception as e:
        log_debug(f"Error interacting with vLLM: {e}")
        return []


def interact_with_vllm_tools(user_query):
    """Interact with vLLM server using tool calling (if supported)."""
    server_url = os.getenv('KOLLZSH_VLLM_SERVER_URL', 'http://localhost:8000')
    model = os.getenv('KOLLZSH_VLLM_MODEL', '')

    log_debug(f"Connecting to vLLM server (with tools) at: {server_url}")

    formatted_query = f"Generate shell commands for the following task: {user_query}. Provide multiple relevant commands if available."

    try:
        with httpx.Client(timeout=60.0) as client:
            # Get model if not specified
            if not model:
                try:
                    models_response = client.get(f"{server_url}/v1/models")
                    models_response.raise_for_status()
                    models_data = models_response.json()
                    if models_data.get('data'):
                        model = models_data['data'][0]['id']
                except Exception:
                    pass

            payload = {
                "messages": [
                    {"role": "user", "content": formatted_query}
                ],
                "temperature": 0.7,
                "max_tokens": 512,
                "tools": [{
                    "type": "function",
                    "function": {
                        "name": "get_shell_commands",
                        "description": f"Generate shell commands for {platform.system()} operating system",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "commands": {
                                    "type": "array",
                                    "description": "List of possible shell commands to accomplish the task",
                                    "items": {
                                        "type": "string",
                                        "description": "A valid shell command"
                                    }
                                }
                            },
                            "required": ["commands"]
                        }
                    }
                }]
            }

            if model:
                payload["model"] = model

            response = client.post(
                f"{server_url}/v1/chat/completions",
                json=payload
            )
            response.raise_for_status()
            data = response.json()

            log_debug(f"Received tool response: {data}")

            if 'choices' in data and data['choices']:
                choice = data['choices'][0]

                # Check for tool calls
                tool_calls = choice.get('message', {}).get('tool_calls', [])
                for tool_call in tool_calls:
                    if tool_call.get('function', {}).get('name') == 'get_shell_commands':
                        try:
                            arguments = json.loads(tool_call['function']['arguments'])
                            commands = arguments.get('commands', [])
                            if commands:
                                log_debug(f"Extracted commands from tool call: {commands}")
                                return commands
                        except (json.JSONDecodeError, KeyError) as e:
                            log_debug(f"Error parsing tool call: {e}")

                # Fallback to content
                content = choice.get('message', {}).get('content', '')
                if content:
                    return extract_commands_from_response(content)

            return []

    except httpx.HTTPStatusError as e:
        # Tool calling might not be supported, fall back to regular chat
        if e.response.status_code in (400, 422):
            log_debug("Tool calling not supported, falling back to regular chat")
            return interact_with_vllm(user_query)
        raise
    except Exception as e:
        log_debug(f"Error with tool calling: {e}")
        return interact_with_vllm(user_query)


if __name__ == '__main__':
    if len(sys.argv) < 2:
        log_debug("Usage: vllm_util.py <user_query>")
        sys.exit(1)

    user_query = ' '.join(sys.argv[1:])

    # Try with tool calling first, fall back to regular chat
    commands = interact_with_vllm_tools(user_query)

    if not commands:
        log_debug("No valid commands found")
        sys.exit(1)

    # Print each command on a new line
    for cmd in commands:
        print(cmd)

    log_debug("Successfully output commands")
