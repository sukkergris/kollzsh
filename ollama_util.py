#!/usr/bin/env python3
import logging
from datetime import datetime
import sys
import json
import re
import ast
from ollama import Client
import platform
import os
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
    """Log debug messages if debug mode is enabled."""
    message = ' '.join(str(m) for m in messages)
    logging.debug(message)

def get_shell_command_tool(commands: list[str]) -> dict:
    """
    Return a list of complete, ready-to-run shell commands for the user's task.
    Each entry must be a full command with all required arguments and flags —
    never just a command name. Example: 'echo "Hello World"', not 'echo'.

    Args:
        commands: Complete shell commands, e.g. ['echo "Hello World"', 'printf "Hello World\\n"']
    """
    log_debug("Generating tool specification for commands:", commands)
    return commands

def interact_with_ollama(user_query):
    """Interact with the Ollama server, DeepSeek API, or OpenAI API to retrieve command suggestions."""
    base_url = os.getenv('KOLLZSH_URL', 'http://localhost:11434')
    api_key = os.getenv('KOLLZSH_API_KEY')
    model = os.getenv('KOLLZSH_MODEL', 'qwen2.5-coder:3b')
    
    log_debug("Sending query:", user_query)
    
    formatted_query = (
        f"List complete, ready-to-run {platform.system()} shell commands for: {user_query}\n"
        "Rules: one command per line, no explanations, no numbering, no markdown, no JSON. "
        "Every command must include all required arguments and flags."
    )
    
    try:
        # Check if we're using OpenAI API
        if api_key and 'openai' in base_url:
            headers = {
                'Authorization': f'Bearer {api_key}',
                'Content-Type': 'application/json'
            }
            
            payload = {
                'model': model,
                'messages': [{
                    'role': 'user',
                    'content': formatted_query
                }],
                'tools': [{
                    'type': 'function',
                    'function': {
                        'name': 'get_shell_command_tool',
                        'description': f'Generate shell commands for {platform.system()} operating system',
                        'parameters': {
                            'type': 'object',
                            'properties': {
                                'commands': {
                                    'type': 'array',
                                    'description': 'List of possible shell commands to accomplish the task',
                                    'items': {
                                        'type': 'string',
                                        'description': 'A valid shell command'
                                    }
                                }
                            },
                            'required': ['commands']
                        }
                    }
                }]
            }
            
            with httpx.Client(base_url=base_url, headers=headers) as client:
                response = client.post('/v1/chat/completions', json=payload)
                response.raise_for_status()
                data = response.json()
                log_debug("Received response from OpenAI:", data)
                
                if 'choices' in data and data['choices']:
                    tool_calls = data['choices'][0].get('message', {}).get('tool_calls', [])
                    for tool_call in tool_calls:
                        if tool_call['function']['name'] == 'get_shell_command_tool':
                            try:
                                arguments = json.loads(tool_call['function']['arguments'])
                                commands = arguments.get('commands', [])
                                if commands:
                                    log_debug("Successfully extracted commands:", commands)
                                    return commands
                            except (json.JSONDecodeError, AttributeError) as e:
                                log_debug(f"Error parsing OpenAI tool call arguments: {str(e)}")
                
                # Fallback to content if no tool calls
                content = data['choices'][0].get('message', {}).get('content', '')
                if content:
                    log_debug("No tool calls found, falling back to content parsing")
                    return parse_commands(content)
                    
        # Check if we're using DeepSeek API
        elif api_key and 'deepseek' in base_url:
            headers = {
                'Authorization': f'Bearer {api_key}',
                'Content-Type': 'application/json'
            }
            
            payload = {
                'model': model,
                'messages': [{
                    'role': 'user',
                    'content': formatted_query
                }],
                'tools': [get_shell_command_tool]
            }
            
            with httpx.Client(base_url=base_url, headers=headers) as client:
                response = client.post('/v1/chat/completions', json=payload)
                response.raise_for_status()
                data = response.json()
                log_debug("Received response from DeepSeek:", data)
                
                if 'choices' in data and data['choices']:
                    tool_calls = data['choices'][0].get('message', {}).get('tool_calls', [])
                    for tool_call in tool_calls:
                        if tool_call['function']['name'] == 'get_shell_command_tool':
                            try:
                                commands = tool_call['function']['arguments'].get('commands', [])
                                if commands:
                                    log_debug("Successfully extracted commands:", commands)
                                    return commands
                            except AttributeError as e:
                                log_debug(f"Error accessing tool call arguments: {str(e)}")
                
                # Fallback to content if no tool calls
                content = data['choices'][0].get('message', {}).get('content', '')
                if content:
                    log_debug("No tool calls found, falling back to content parsing")
                    return parse_commands(content)
        
        else:  # Use Ollama API (plain text — tool calls produce unreliable JSON with small models)
            client = Client(host=base_url, timeout=120)
            response = client.chat(
                model=model,
                messages=[{
                    "role": "user",
                    "content": formatted_query
                }],
                stream=False,
                think=False,
            )
            log_debug("Received response from Ollama:", response)

            content = response.message.content if hasattr(response.message, 'content') else ''
            if content:
                log_debug("Parsing plain-text response from Ollama")
                return parse_commands(content)
        
        log_debug("No valid commands found in response")
        return []
        
    except Exception as e:
        log_debug(f"Error interacting with API: {str(e)}")
        return []

def parse_commands(content):
    """Resiliently extract a list of shell commands from text or JSON."""
    if not isinstance(content, str):
        return []

    # Strip markdown code fences
    m = re.search(r'```(?:json)?\s*(\[.*?\])\s*```', content, re.DOTALL)
    if m:
        content = m.group(1)

    content = content.strip()

    # Try standard JSON
    try:
        result = json.loads(content)
        if isinstance(result, list):
            return [str(c) for c in result if str(c).strip()]
    except (json.JSONDecodeError, ValueError):
        pass

    # Try Python literal (handles single-quoted lists some models emit)
    try:
        result = ast.literal_eval(content)
        if isinstance(result, list):
            return [str(c) for c in result if str(c).strip()]
    except Exception:
        pass

    # Only try regex string extraction if content looks like a JSON structure
    if content.lstrip().startswith('[') or content.lstrip().startswith('{'):
        matches = re.findall(r'"((?:[^"\\]|\\.)*)"', content)
        if matches:
            cleaned = []
            for m in matches:
                cmd = m.replace('\\"', '"').replace('\\\\', '\\').strip().strip('"\'')
                if cmd:
                    cleaned.append(cmd)
            if cleaned:
                return cleaned

    # Plain-text fallback: one command per line, strip list markers and code fences
    lines = [re.sub(r'^(\d+\.|\*|-)\s*', '', l.strip()) for l in content.splitlines()]
    return [l for l in lines
            if len(l) > 1
            and re.match(r'^[a-z0-9/.$~_\-]', l)   # commands start lowercase/path, not prose
            and not l.startswith('```')
            and '<<' not in l]

if __name__ == '__main__':
    if len(sys.argv) != 2:
        log_debug("Usage: ollama_util.py <user_query>")
        sys.exit(1)
    
    user_query = sys.argv[1]
    commands = interact_with_ollama(user_query)
    
    if not commands:
        log_debug("No valid commands found")
        sys.exit(1)
        
    seen = set()
    for cmd in commands:
        if '\n' not in cmd and cmd not in seen:
            seen.add(cmd)
            print(cmd)
        
    log_debug("Successfully output commands")
