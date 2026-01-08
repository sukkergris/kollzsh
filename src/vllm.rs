use anyhow::{Context, Result};
use serde::Deserialize;
use serde_json::json;
use std::env;
use std::time::Duration;

use crate::extract::extract_commands;

#[derive(Debug, Deserialize)]
struct ModelsResponse {
    data: Vec<ModelInfo>,
}

#[derive(Debug, Deserialize)]
struct ModelInfo {
    id: String,
}

#[derive(Debug, Deserialize)]
struct ChatResponse {
    choices: Vec<ChatChoice>,
}

#[derive(Debug, Deserialize)]
struct ChatChoice {
    message: ChatMessage,
}

#[derive(Debug, Deserialize)]
struct ChatMessage {
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
    arguments: String,
}

fn format_query(user_query: &str) -> String {
    format!(
        r#"Generate shell commands for the following task on {}: {}

Return the commands as a JSON array of strings, like: ["command1", "command2"]
Only return the JSON array, no explanation."#,
        std::env::consts::OS,
        user_query
    )
}

fn get_model(client: &reqwest::blocking::Client, server_url: &str) -> Option<String> {
    // First check if model is set in env
    if let Ok(model) = env::var("KOLLZSH_VLLM_MODEL") {
        if !model.is_empty() {
            return Some(model);
        }
    }

    // Try to get model from server
    if let Ok(response) = client.get(format!("{}/v1/models", server_url)).send() {
        if let Ok(data) = response.json::<ModelsResponse>() {
            if let Some(model) = data.data.first() {
                log::debug!("Using model: {}", model.id);
                return Some(model.id.clone());
            }
        }
    }

    None
}

fn interact_with_tools(user_query: &str) -> Result<Vec<String>> {
    let server_url =
        env::var("KOLLZSH_VLLM_SERVER_URL").unwrap_or_else(|_| "http://localhost:8000".to_string());

    log::debug!("Connecting to vLLM server (with tools) at: {}", server_url);

    let client = reqwest::blocking::Client::builder()
        .timeout(Duration::from_secs(60))
        .build()?;

    let model = get_model(&client, &server_url);

    let formatted_query = format!(
        "Generate shell commands for the following task: {}. Provide multiple relevant commands if available.",
        user_query
    );

    let mut payload = json!({
        "messages": [{
            "role": "user",
            "content": formatted_query
        }],
        "temperature": 0.7,
        "max_tokens": 512,
        "tools": [{
            "type": "function",
            "function": {
                "name": "get_shell_commands",
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

    if let Some(model) = model {
        payload["model"] = json!(model);
    }

    let response = client
        .post(format!("{}/v1/chat/completions", server_url))
        .json(&payload)
        .send();

    match response {
        Ok(resp) => {
            let status = resp.status().as_u16();
            if status == 400 || status == 422 {
                // Tool calling not supported, fall back to regular chat
                log::debug!("Tool calling not supported, falling back to regular chat");
                return interact_chat(user_query);
            }

            let data: ChatResponse = resp.json().context("Failed to parse response")?;
            log::debug!("Received tool response: {:?}", data);

            if let Some(choice) = data.choices.first() {
                // Check for tool calls
                if let Some(tool_calls) = &choice.message.tool_calls {
                    for tool_call in tool_calls {
                        if tool_call.function.name == "get_shell_commands" {
                            if let Ok(args) =
                                serde_json::from_str::<serde_json::Value>(&tool_call.function.arguments)
                            {
                                if let Some(commands) = args.get("commands") {
                                    if let Some(arr) = commands.as_array() {
                                        let cmds: Vec<String> = arr
                                            .iter()
                                            .filter_map(|v| v.as_str().map(String::from))
                                            .collect();
                                        if !cmds.is_empty() {
                                            log::debug!(
                                                "Extracted commands from tool call: {:?}",
                                                cmds
                                            );
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
                    let commands = extract_commands(content);
                    if !commands.is_empty() {
                        return Ok(commands);
                    }
                }
            }
        }
        Err(e) => {
            log::debug!("Error with tool calling: {}", e);
            return interact_chat(user_query);
        }
    }

    Ok(Vec::new())
}

fn interact_chat(user_query: &str) -> Result<Vec<String>> {
    let server_url =
        env::var("KOLLZSH_VLLM_SERVER_URL").unwrap_or_else(|_| "http://localhost:8000".to_string());

    log::debug!("Connecting to vLLM server at: {}", server_url);

    let client = reqwest::blocking::Client::builder()
        .timeout(Duration::from_secs(60))
        .build()?;

    let model = get_model(&client, &server_url);

    let formatted_query = format_query(user_query);
    log::debug!("Sending query: {}", formatted_query);

    let mut payload = json!({
        "messages": [{
            "role": "user",
            "content": formatted_query
        }],
        "temperature": 0.7,
        "max_tokens": 512
    });

    if let Some(model) = model {
        payload["model"] = json!(model);
    }

    let response = client
        .post(format!("{}/v1/chat/completions", server_url))
        .json(&payload)
        .send()
        .context("Failed to send request to vLLM server")?;

    let data: ChatResponse = response.json().context("Failed to parse response")?;
    log::debug!("Received response: {:?}", data);

    if let Some(choice) = data.choices.first() {
        if let Some(content) = &choice.message.content {
            log::debug!("Raw content: {}", content);
            let commands = extract_commands(content);
            log::debug!("Extracted commands: {:?}", commands);
            return Ok(commands);
        }
    }

    Ok(Vec::new())
}

pub fn interact(user_query: &str) -> Result<Vec<String>> {
    // Try with tool calling first, fall back to regular chat
    interact_with_tools(user_query)
}
