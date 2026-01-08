use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::env;

use crate::extract::extract_commands;

#[derive(Debug, Serialize)]
struct OllamaRequest {
    model: String,
    messages: Vec<Message>,
    stream: bool,
    tools: Option<Vec<Tool>>,
}

#[derive(Debug, Serialize, Deserialize)]
struct Message {
    role: String,
    content: String,
}

#[derive(Debug, Serialize)]
struct Tool {
    #[serde(rename = "type")]
    tool_type: String,
    function: ToolFunction,
}

#[derive(Debug, Serialize)]
struct ToolFunction {
    name: String,
    description: String,
    parameters: Value,
}

#[derive(Debug, Deserialize)]
struct OllamaResponse {
    message: Option<OllamaMessage>,
}

#[derive(Debug, Deserialize)]
struct OllamaMessage {
    content: Option<String>,
    tool_calls: Option<Vec<ToolCall>>,
}

#[derive(Debug, Deserialize)]
struct ToolCall {
    function: ToolCallFunction,
}

#[derive(Debug, Deserialize)]
struct ToolCallFunction {
    name: String,
    arguments: Value,
}

#[derive(Debug, Deserialize)]
struct OpenAIResponse {
    choices: Vec<OpenAIChoice>,
}

#[derive(Debug, Deserialize)]
struct OpenAIChoice {
    message: OpenAIMessage,
}

#[derive(Debug, Deserialize)]
struct OpenAIMessage {
    content: Option<String>,
    tool_calls: Option<Vec<OpenAIToolCall>>,
}

#[derive(Debug, Deserialize)]
struct OpenAIToolCall {
    function: OpenAIToolCallFunction,
}

#[derive(Debug, Deserialize)]
struct OpenAIToolCallFunction {
    name: String,
    arguments: String,
}

fn get_tool_spec() -> Tool {
    Tool {
        tool_type: "function".to_string(),
        function: ToolFunction {
            name: "get_shell_command_tool".to_string(),
            description: format!(
                "Generate shell commands for {} operating system",
                std::env::consts::OS
            ),
            parameters: json!({
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
            }),
        },
    }
}

pub fn interact(user_query: &str) -> Result<Vec<String>> {
    let base_url = env::var("KOLLZSH_URL").unwrap_or_else(|_| "http://localhost:11434".to_string());
    let api_key = env::var("KOLLZSH_API_KEY").ok();
    let model = env::var("KOLLZSH_MODEL").unwrap_or_else(|_| "qwen2.5-coder:3b".to_string());

    log::debug!("Sending query: {}", user_query);

    let formatted_query = format!(
        "Generate shell commands for the following task: {}. Provide multiple relevant commands if available.",
        user_query
    );

    let client = reqwest::blocking::Client::new();

    // Determine which API to use based on URL and API key
    if let Some(ref key) = api_key {
        if base_url.contains("openai") || base_url.contains("deepseek") {
            return interact_openai_compatible(&client, &base_url, key, &model, &formatted_query);
        }
    }

    // Default to Ollama API
    interact_ollama(&client, &base_url, &model, &formatted_query)
}

fn interact_ollama(
    client: &reqwest::blocking::Client,
    base_url: &str,
    model: &str,
    query: &str,
) -> Result<Vec<String>> {
    let request = OllamaRequest {
        model: model.to_string(),
        messages: vec![Message {
            role: "user".to_string(),
            content: query.to_string(),
        }],
        stream: false,
        tools: Some(vec![get_tool_spec()]),
    };

    let response = client
        .post(format!("{}/api/chat", base_url))
        .json(&request)
        .send()
        .context("Failed to send request to Ollama")?;

    let data: OllamaResponse = response.json().context("Failed to parse Ollama response")?;
    log::debug!("Received response from Ollama: {:?}", data);

    if let Some(message) = data.message {
        // Check for tool calls
        if let Some(tool_calls) = message.tool_calls {
            for tool_call in tool_calls {
                if tool_call.function.name == "get_shell_command_tool" {
                    if let Some(commands) = tool_call.function.arguments.get("commands") {
                        if let Some(arr) = commands.as_array() {
                            let cmds: Vec<String> = arr
                                .iter()
                                .filter_map(|v| v.as_str().map(String::from))
                                .collect();
                            if !cmds.is_empty() {
                                log::debug!("Successfully extracted commands: {:?}", cmds);
                                return Ok(cmds);
                            }
                        }
                    }
                }
            }
        }

        // Fallback to content parsing
        if let Some(content) = message.content {
            log::debug!("No tool calls found, falling back to content parsing");
            let commands = extract_commands(&content);
            if !commands.is_empty() {
                return Ok(commands);
            }
        }
    }

    log::debug!("No valid commands found in response");
    Ok(Vec::new())
}

fn interact_openai_compatible(
    client: &reqwest::blocking::Client,
    base_url: &str,
    api_key: &str,
    model: &str,
    query: &str,
) -> Result<Vec<String>> {
    let payload = json!({
        "model": model,
        "messages": [{
            "role": "user",
            "content": query
        }],
        "tools": [{
            "type": "function",
            "function": {
                "name": "get_shell_command_tool",
                "description": format!("Generate shell commands for {} operating system", std::env::consts::OS),
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
    });

    let response = client
        .post(format!("{}/v1/chat/completions", base_url))
        .header("Authorization", format!("Bearer {}", api_key))
        .header("Content-Type", "application/json")
        .json(&payload)
        .send()
        .context("Failed to send request to OpenAI-compatible API")?;

    let data: OpenAIResponse = response.json().context("Failed to parse response")?;
    log::debug!("Received response from API: {:?}", data);

    if let Some(choice) = data.choices.first() {
        // Check for tool calls
        if let Some(tool_calls) = &choice.message.tool_calls {
            for tool_call in tool_calls {
                if tool_call.function.name == "get_shell_command_tool" {
                    if let Ok(args) = serde_json::from_str::<Value>(&tool_call.function.arguments) {
                        if let Some(commands) = args.get("commands") {
                            if let Some(arr) = commands.as_array() {
                                let cmds: Vec<String> = arr
                                    .iter()
                                    .filter_map(|v| v.as_str().map(String::from))
                                    .collect();
                                if !cmds.is_empty() {
                                    log::debug!("Successfully extracted commands: {:?}", cmds);
                                    return Ok(cmds);
                                }
                            }
                        }
                    }
                }
            }
        }

        // Fallback to content
        if let Some(content) = &choice.message.content {
            log::debug!("No tool calls found, falling back to content parsing");
            let commands = extract_commands(content);
            if !commands.is_empty() {
                return Ok(commands);
            }
        }
    }

    log::debug!("No valid commands found in response");
    Ok(Vec::new())
}
