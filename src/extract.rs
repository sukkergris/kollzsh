use regex::Regex;
use serde_json::Value;

/// Extract shell commands from model response text.
/// Tries multiple strategies: JSON in code blocks, raw JSON arrays, code blocks, inline code.
pub fn extract_commands(text: &str) -> Vec<String> {
    // Try to find JSON array in code blocks first (```json ... ```)
    if let Some(commands) = extract_json_from_code_block(text) {
        if !commands.is_empty() {
            return commands;
        }
    }

    // Try to find JSON array anywhere in text
    if let Some(commands) = extract_json_array(text) {
        if !commands.is_empty() {
            return commands;
        }
    }

    // Try to find commands in bash/sh code blocks
    if let Some(commands) = extract_from_code_blocks(text) {
        if !commands.is_empty() {
            return commands;
        }
    }

    // Try to find inline code commands
    if let Some(commands) = extract_inline_commands(text) {
        if !commands.is_empty() {
            return commands;
        }
    }

    Vec::new()
}

fn extract_json_from_code_block(text: &str) -> Option<Vec<String>> {
    let re = Regex::new(r"(?is)```(?:json)?\s*\n?([\[\{].*?[\]\}])\s*\n?```").ok()?;

    for cap in re.captures_iter(text) {
        if let Some(json_str) = cap.get(1) {
            if let Ok(commands) = parse_json_array(json_str.as_str()) {
                return Some(commands);
            }
        }
    }
    None
}

fn extract_json_array(text: &str) -> Option<Vec<String>> {
    let re = Regex::new(r"\[.*?\]").ok()?;

    for mat in re.find_iter(text) {
        if let Ok(commands) = parse_json_array(mat.as_str()) {
            return Some(commands);
        }
    }
    None
}

fn parse_json_array(json_str: &str) -> Result<Vec<String>, ()> {
    let value: Value = serde_json::from_str(json_str).map_err(|_| ())?;

    if let Value::Array(arr) = value {
        let commands: Vec<String> = arr
            .into_iter()
            .filter_map(|v| {
                if let Value::String(s) = v {
                    Some(s)
                } else {
                    None
                }
            })
            .collect();

        if !commands.is_empty() {
            return Ok(commands);
        }
    }
    Err(())
}

fn extract_from_code_blocks(text: &str) -> Option<Vec<String>> {
    let re = Regex::new(r"(?is)```(?:bash|sh|shell|zsh)?\s*\n(.*?)```").ok()?;
    let mut commands = Vec::new();

    for cap in re.captures_iter(text) {
        if let Some(block) = cap.get(1) {
            for line in block.as_str().lines() {
                let line = line.trim();
                if !line.is_empty() && !line.starts_with('#') {
                    commands.push(line.to_string());
                }
            }
        }
    }

    if commands.is_empty() {
        None
    } else {
        Some(commands)
    }
}

fn extract_inline_commands(text: &str) -> Option<Vec<String>> {
    let re = Regex::new(r"`([^`]+)`").ok()?;
    let shell_prefixes = [
        "ls", "cd", "cat", "grep", "find", "mkdir", "rm", "cp", "mv",
        "echo", "pwd", "chmod", "chown", "curl", "wget", "git", "docker",
        "npm", "pip", "python", "node", "brew", "apt", "sudo", "jq",
        "tar", "sed", "awk", "sort", "uniq", "head", "tail", "wc",
    ];

    let commands: Vec<String> = re
        .captures_iter(text)
        .filter_map(|cap| cap.get(1))
        .map(|m| m.as_str().to_string())
        .filter(|cmd| {
            shell_prefixes.iter().any(|prefix| {
                cmd.starts_with(prefix) || cmd.starts_with(&format!("./{}", prefix))
            })
        })
        .collect();

    if commands.is_empty() {
        None
    } else {
        Some(commands)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_extract_json_array() {
        let text = r#"["ls -la", "pwd"]"#;
        let commands = extract_commands(text);
        assert_eq!(commands, vec!["ls -la", "pwd"]);
    }

    #[test]
    fn test_extract_json_in_code_block() {
        let text = r#"```json
["ls -la", "pwd"]
```"#;
        let commands = extract_commands(text);
        assert_eq!(commands, vec!["ls -la", "pwd"]);
    }

    #[test]
    fn test_extract_bash_code_block() {
        let text = r#"```bash
ls -la
pwd
```"#;
        let commands = extract_commands(text);
        assert_eq!(commands, vec!["ls -la", "pwd"]);
    }
}
