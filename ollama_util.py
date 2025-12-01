#!/usr/bin/env python3
import logging
from datetime import datetime
import sys
import json
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
    if os.getenv('KOLLZSH_DEBUG'):
        message = ' '.join(str(m) for m in messages)
        logging.debug(message)
    else:
        logging.debug(message)

def get_shell_command_tool(commands: list[str]) -> dict:
    """
    Generate shell command tool specification for Ollama

    Args:
        commands: List of shell commands to be executed

    Returns:
        dict: Tool specification containing name, description, and parameters
    """
    log_debug("Generating tool specification for commands:", commands)
    return commands

def interact_with_ollama(user_query):
    """Interact with the Ollama server, DeepSeek API, or OpenAI API to retrieve command suggestions."""
    base_url = os.getenv('KOLLZSH_URL', 'http://localhost:11434')
    api_key = os.getenv('KOLLZSH_API_KEY')
    model = os.getenv('KOLLZSH_MODEL', 'qwen2.5-coder:3b')
    
    log_debug("Sending query:", user_query)
    
    # Format the user query to focus on shell commands
    formatted_query = f"Generate shell commands for the following task: {user_query}. Provide multiple relevant commands if available."
    
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
        
        else:  # Use Ollama API
            client = Client(host=base_url)
            response = client.chat(
                model=model,
                messages=[{
                    "role": "user",
                    "content": formatted_query
                }],
                stream=False,
                tools=[get_shell_command_tool]
            )
            log_debug("Received response from Ollama:", response)
            
            if hasattr(response.message, 'tool_calls') and response.message.tool_calls:
                for tool_call in response.message.tool_calls:
                    if tool_call.function.name == 'get_shell_command_tool':
                        try:
                            commands = tool_call.function.arguments.get('commands', [])
                            if commands:
                                log_debug("Successfully extracted commands:", commands)
                                return commands
                        except AttributeError as e:
                            log_debug(f"Error accessing tool call arguments: {str(e)}")
            
            # Fallback to parsing content if no tool calls
            content = response.message.content if hasattr(response.message, 'content') else ''
            if content:
                log_debug("No tool calls found, falling back to content parsing")
                return parse_commands(content)
        
        log_debug("No valid commands found in response")
        return []
        
    except Exception as e:
        log_debug(f"Error interacting with API: {str(e)}")
        return []

def parse_commands(content):
    """Parse commands from response content."""
    try:
        # Try to find markdown-wrapped JSON first
        import re
        markdown_match = re.search(r'```json\s*(.*?)\s*```', content, re.DOTALL)
        if markdown_match:
            content = markdown_match.group(1)
        
        # Clean and normalize the content
        content = normalize_json_string(content)
        log_debug("Normalized content:", content)
        
        # Try parsing as JSON
        try:
            commands = json.loads(content)
        except json.JSONDecodeError:
            # Try Python's ast as fallback
            import ast
            commands = ast.literal_eval(content)
        
        # Ensure we have a list of commands
        if isinstance(commands, list):
            # Clean up commands
            cleaned_commands = []
            for cmd in commands:
                if isinstance(cmd, str):
                    # Clean up escaping but preserve shell escapes
                    cmd = cmd.replace('\\"', '"')  # Unescape quotes
                    cmd = cmd.replace('\\\\', '\\')  # Fix double escapes
                    cmd = cmd.replace('"', '\\"')  # Re-escape quotes for shell
                    cleaned_commands.append(cmd)
            
            log_debug("Successfully parsed commands:", cleaned_commands)
            return cleaned_commands
            
        log_debug("Parsed content is not a list:", commands)
        return []
        
    except Exception as e:
        log_debug(f"Error parsing commands: {str(e)}", content)
        return []

def normalize_json_string(content):
    """Normalize JSON string by handling escapes and newlines."""
    # Handle control characters
    content = content.replace('\n', ' ')
    content = content.replace('\r', ' ')
    content = content.replace('\t', ' ')
    
    # Handle escaped characters
    content = content.replace('\\"', '"')  # Temporarily unescape quotes
    content = content.replace('\\\\', '\\')  # Fix double escapes
    content = content.replace('"', '\\"')  # Re-escape all quotes
    
    # Clean up whitespace
    content = ' '.join(content.split())
    
    log_debug("Normalized JSON string:", content)
    return content

if __name__ == '__main__':
    if len(sys.argv) != 2:
        log_debug("Usage: ollama_util.py <user_query>")
        sys.exit(1)
    
    user_query = sys.argv[1]
    commands = interact_with_ollama(user_query)
    
    if not commands:
        log_debug("No valid commands found")
        sys.exit(1)
        
    # Print each command on a new line
    for cmd in commands:
        print(cmd)
        
    log_debug("Successfully output commands")
