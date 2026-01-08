use anyhow::{Context, Result};
use serde::Deserialize;
use serde_json::json;
use std::env;
use std::path::Path;
use std::process::Command;
use std::time::Duration;

use crate::extract::extract_commands;
use crate::vllm;

#[derive(Debug, Deserialize)]
struct CompletionResponse {
    content: Option<String>,
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

fn find_llama_cli() -> Option<String> {
    let llama_path = env::var("KOLLZSH_LLAMACPP_PATH").unwrap_or_default();

    if !llama_path.is_empty() {
        let candidates = [
            format!("{}/llama-cli", llama_path),
            format!("{}/build/bin/llama-cli", llama_path),
            format!("{}/main", llama_path),
            format!("{}/build/bin/main", llama_path),
        ];

        for candidate in candidates {
            let path = Path::new(&candidate);
            if path.is_file() {
                return Some(candidate);
            }
        }
    }

    // Check in PATH
    for name in ["llama-cli", "main"] {
        if let Ok(output) = Command::new("which").arg(name).output() {
            if output.status.success() {
                let path = String::from_utf8_lossy(&output.stdout).trim().to_string();
                if !path.is_empty() {
                    return Some(path);
                }
            }
        }
    }

    None
}

fn is_server_running() -> bool {
    let server_url =
        env::var("KOLLZSH_LLAMACPP_SERVER_URL").unwrap_or_else(|_| "http://localhost:8080".to_string());

    let client = reqwest::blocking::Client::builder()
        .timeout(Duration::from_secs(2))
        .build()
        .ok();

    if let Some(client) = client {
        if let Ok(response) = client.get(format!("{}/health", server_url)).send() {
            return response.status().is_success();
        }
    }

    false
}

fn is_vllm_running() -> bool {
    let server_url =
        env::var("KOLLZSH_VLLM_SERVER_URL").unwrap_or_else(|_| "http://localhost:8000".to_string());

    let client = reqwest::blocking::Client::builder()
        .timeout(Duration::from_secs(2))
        .build()
        .ok();

    if let Some(client) = client {
        if let Ok(response) = client.get(format!("{}/v1/models", server_url)).send() {
            return response.status().is_success();
        }
    }

    false
}

fn interact_cli(user_query: &str) -> Result<Vec<String>> {
    let model_path = env::var("KOLLZSH_LLAMACPP_MODEL").unwrap_or_default();
    let n_ctx = env::var("KOLLZSH_LLAMACPP_N_CTX").unwrap_or_else(|_| "2048".to_string());
    let n_gpu_layers =
        env::var("KOLLZSH_LLAMACPP_N_GPU_LAYERS").unwrap_or_else(|_| "-1".to_string());

    if model_path.is_empty() {
        log::debug!("KOLLZSH_LLAMACPP_MODEL not set");
        return Ok(Vec::new());
    }

    if !Path::new(&model_path).is_file() {
        log::debug!("Model file not found: {}", model_path);
        return Ok(Vec::new());
    }

    let llama_cli = match find_llama_cli() {
        Some(path) => path,
        None => {
            log::debug!("llama-cli not found");
            return Ok(Vec::new());
        }
    };

    log::debug!("Using llama-cli: {}", llama_cli);
    log::debug!("Using model: {}", model_path);

    let formatted_query = format_query(user_query);
    log::debug!("Sending query: {}", formatted_query);

    let output = Command::new(&llama_cli)
        .args([
            "-m",
            &model_path,
            "-c",
            &n_ctx,
            "-ngl",
            &n_gpu_layers,
            "-n",
            "512",
            "--temp",
            "0.7",
            "-p",
            &formatted_query,
            "--no-display-prompt",
        ])
        .output()
        .context("Failed to execute llama-cli")?;

    if !output.status.success() {
        log::debug!(
            "llama-cli failed with code {:?}",
            output.status.code()
        );
        log::debug!("stderr: {}", String::from_utf8_lossy(&output.stderr));
        return Ok(Vec::new());
    }

    let content = String::from_utf8_lossy(&output.stdout).to_string();
    log::debug!("Raw output: {}", content);

    let commands = extract_commands(&content);
    log::debug!("Extracted commands: {:?}", commands);

    Ok(commands)
}

fn interact_server_chat(user_query: &str) -> Result<Vec<String>> {
    let server_url =
        env::var("KOLLZSH_LLAMACPP_SERVER_URL").unwrap_or_else(|_| "http://localhost:8080".to_string());

    log::debug!("Connecting to llama.cpp server (chat API) at: {}", server_url);

    let formatted_query = format_query(user_query);
    log::debug!("Sending query: {}", formatted_query);

    let client = reqwest::blocking::Client::builder()
        .timeout(Duration::from_secs(60))
        .build()?;

    let payload = json!({
        "messages": [{
            "role": "user",
            "content": formatted_query
        }],
        "temperature": 0.7,
        "max_tokens": 512
    });

    let response = client
        .post(format!("{}/v1/chat/completions", server_url))
        .json(&payload)
        .send();

    match response {
        Ok(resp) => {
            if resp.status().as_u16() == 404 {
                // Fall back to completion endpoint
                log::debug!("Chat API not available, falling back to completion endpoint");
                return interact_server_completion(user_query);
            }

            let data: ChatResponse = resp.json().context("Failed to parse chat response")?;
            log::debug!("Received chat response: {:?}", data);

            if let Some(choice) = data.choices.first() {
                if let Some(content) = &choice.message.content {
                    let commands = extract_commands(content);
                    log::debug!("Extracted commands: {:?}", commands);
                    return Ok(commands);
                }
            }
        }
        Err(e) => {
            log::debug!("Connection error: {}", e);
        }
    }

    Ok(Vec::new())
}

fn interact_server_completion(user_query: &str) -> Result<Vec<String>> {
    let server_url =
        env::var("KOLLZSH_LLAMACPP_SERVER_URL").unwrap_or_else(|_| "http://localhost:8080".to_string());

    log::debug!("Connecting to llama.cpp server at: {}", server_url);

    let formatted_query = format_query(user_query);
    log::debug!("Sending query: {}", formatted_query);

    let client = reqwest::blocking::Client::builder()
        .timeout(Duration::from_secs(60))
        .build()?;

    let payload = json!({
        "prompt": formatted_query,
        "n_predict": 512,
        "temperature": 0.7,
        "stop": ["\n\n", "```\n\n"]
    });

    let response = client
        .post(format!("{}/completion", server_url))
        .json(&payload)
        .send()
        .context("Failed to send request to llama.cpp server")?;

    let data: CompletionResponse = response.json().context("Failed to parse response")?;
    log::debug!("Received response: {:?}", data);

    if let Some(content) = data.content {
        log::debug!("Raw content: {}", content);
        let commands = extract_commands(&content);
        log::debug!("Extracted commands: {:?}", commands);
        return Ok(commands);
    }

    log::debug!("No content in response");
    Ok(Vec::new())
}

pub fn interact(user_query: &str) -> Result<Vec<String>> {
    let result = if is_server_running() {
        log::debug!("Server is running, using server mode");
        interact_server_chat(user_query)
    } else {
        log::debug!("Server not running, using CLI mode");
        interact_cli(user_query)
    };

    // If llama.cpp failed or returned empty results, try vLLM as fallback
    match &result {
        Ok(commands) if commands.is_empty() => {
            if is_vllm_running() {
                log::debug!("llama.cpp returned no results, falling back to vLLM");
                return vllm::interact(user_query);
            }
        }
        Err(e) => {
            log::debug!("llama.cpp failed with error: {}", e);
            if is_vllm_running() {
                log::debug!("Falling back to vLLM");
                return vllm::interact(user_query);
            }
        }
        _ => {}
    }

    result
}
