# default shortcut as Ctrl-o
(( ! ${+KOLLZSH_HOTKEY} )) && typeset -g KOLLZSH_HOTKEY='^o'
# default thinking shortcut as Ctrl-t
(( ! ${+KOLLZSH_THINKING_HOTKEY} )) && typeset -g KOLLZSH_THINKING_HOTKEY='^t'
# default REPL shortcut as Ctrl-x Ctrl-o (two-key sequence, more reliable)
(( ! ${+KOLLZSH_REPL_HOTKEY} )) && typeset -g KOLLZSH_REPL_HOTKEY='^x^o'
# default Claude Code agent shortcut as Ctrl-x Ctrl-s
(( ! ${+KOLLZSH_CLAUDE_HOTKEY} )) && typeset -g KOLLZSH_CLAUDE_HOTKEY='^x^s'
# default Claude Code Sonnet shortcut as Ctrl-\ (backslash)
(( ! ${+KOLLZSH_CLAUDE_SONNET_HOTKEY} )) && typeset -g KOLLZSH_CLAUDE_SONNET_HOTKEY='^\\'
# default platform (ollama, mlx, llamacpp, vllm, claude, or codex)
(( ! ${+KOLLZSH_PLATFORM} )) && KOLLZSH_PLATFORM='claude'
# default model (for MLX, use e.g. Qwen/Qwen3-14B-MLX-4bit)
(( ! ${+KOLLZSH_MODEL} )) && KOLLZSH_MODEL='Qwen/Qwen3-14B-MLX-4bit'
# default max tokens
(( ! ${+KOLLZSH_MAX_TOKENS} )) && KOLLZSH_MAX_TOKENS='2048'
# default response number as 5
(( ! ${+KOLLZSH_COMMAND_COUNT} )) && KOLLZSH_COMMAND_COUNT='5'
# default ollama server host
(( ! ${+KOLLZSH_URL} )) && KOLLZSH_URL='http://localhost:11434'
# llama.cpp settings
(( ! ${+KOLLZSH_LLAMACPP_PATH} )) && KOLLZSH_LLAMACPP_PATH=''
(( ! ${+KOLLZSH_LLAMACPP_MODEL} )) && KOLLZSH_LLAMACPP_MODEL=''
(( ! ${+KOLLZSH_LLAMACPP_SERVER_URL} )) && KOLLZSH_LLAMACPP_SERVER_URL='http://localhost:8080'
(( ! ${+KOLLZSH_LLAMACPP_N_CTX} )) && KOLLZSH_LLAMACPP_N_CTX='2048'
(( ! ${+KOLLZSH_LLAMACPP_N_GPU_LAYERS} )) && KOLLZSH_LLAMACPP_N_GPU_LAYERS='-1'
# vLLM settings
(( ! ${+KOLLZSH_VLLM_SERVER_URL} )) && KOLLZSH_VLLM_SERVER_URL='http://localhost:8000'
(( ! ${+KOLLZSH_VLLM_MODEL} )) && KOLLZSH_VLLM_MODEL=''
# Claude Code CLI settings (leave BASE_URL and AUTH_TOKEN empty to use Anthropic API directly)
(( ! ${+KOLLZSH_CLAUDE_MODEL} )) && KOLLZSH_CLAUDE_MODEL='sonnet'
(( ! ${+KOLLZSH_CLAUDE_BASE_URL} )) && KOLLZSH_CLAUDE_BASE_URL=''
(( ! ${+KOLLZSH_CLAUDE_AUTH_TOKEN} )) && KOLLZSH_CLAUDE_AUTH_TOKEN=''
# Codex CLI settings (uses OAuth from `codex login`; empty model = use ~/.codex/config.toml default)
(( ! ${+KOLLZSH_CODEX_MODEL} )) && KOLLZSH_CODEX_MODEL=''

# Export all KOLLZSH variables so subprocesses can access them
export KOLLZSH_PLATFORM KOLLZSH_MODEL KOLLZSH_COMMAND_COUNT KOLLZSH_URL KOLLZSH_API_KEY KOLLZSH_MAX_TOKENS
export KOLLZSH_LLAMACPP_PATH KOLLZSH_LLAMACPP_MODEL KOLLZSH_LLAMACPP_SERVER_URL KOLLZSH_LLAMACPP_N_CTX KOLLZSH_LLAMACPP_N_GPU_LAYERS
export KOLLZSH_VLLM_SERVER_URL KOLLZSH_VLLM_MODEL
export KOLLZSH_CLAUDE_MODEL KOLLZSH_CLAUDE_BASE_URL KOLLZSH_CLAUDE_AUTH_TOKEN
export KOLLZSH_CODEX_MODEL

# Use venv Python if available, otherwise fall back to system python3
_KOLLZSH_VENV="${0:A:h}/.venv/bin/python3"
if [[ -x "$_KOLLZSH_VENV" ]]; then
  KOLLZSH_PYTHON="$_KOLLZSH_VENV"
else
  KOLLZSH_PYTHON="python3"
fi

# Path to the Rust binary (built with `cargo build --release`)
KOLLZSH_BIN="${0:A:h}/target/release/kollzsh"

# Source utility functions
source "${0:A:h}/utils.zsh"

# Set up logging with proper permissions
KOLLZSH_LOG_FILE="/tmp/kollzsh_debug.log"
touch "$KOLLZSH_LOG_FILE"
chmod 666 "$KOLLZSH_LOG_FILE"
typeset -g KOLLZSH_LAST_ERROR=""

log_debug() {
  local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  {
    echo "[${timestamp}] $1"
    if [ -n "$2" ]; then
      echo "Data: $2"
      echo "----------------------------------------"
    fi
  } >> "$KOLLZSH_LOG_FILE" 2>&1
}

kollzsh_show_error() {
  local msg="$1"
  local detail="$2"

  log_debug "$msg" "$detail"

  # Show a one-line message in the ZLE prompt area when possible
  if [[ -n "$WIDGET" ]]; then
    zle -M "$msg"
  fi

  # Print full details to stderr so it's visible even if ZLE clears output
  print -u2 -- "$msg"
  if [[ -n "$detail" ]]; then
    print -u2 -- "$detail"
  fi
  print -u2 -- "Log: $KOLLZSH_LOG_FILE"
}

_kollzsh_capture_cmd() {
  local errfile
  errfile=$(mktemp "${TMPDIR:-/tmp}/kollzsh_err.XXXXXX" 2>/dev/null) || errfile="${TMPDIR:-/tmp}/kollzsh_err.$$"
  : > "$errfile"

  local output
  output=$("$@" 2>"$errfile")
  local exit_code=$?

  local err=""
  if [[ -s "$errfile" ]]; then
    err=$(<"$errfile")
  fi
  rm -f "$errfile" 2>/dev/null

  KOLLZSH_LAST_ERROR="$err"
  if [[ -n "$err" ]]; then
    log_debug "Backend stderr:" "$err"
  fi

  print -r -- "$output"
  return $exit_code
}

_kollzsh_claude_cmd() {
  local user_query="$1"
  local cmd_count="${KOLLZSH_COMMAND_COUNT:-5}"
  local claude_model="${KOLLZSH_CLAUDE_MODEL}"
  local claude_base_url="${KOLLZSH_CLAUDE_BASE_URL}"
  local claude_auth_token="${KOLLZSH_CLAUDE_AUTH_TOKEN}"

  local sys_prompt="You are a shell command generator. Given a task description, return exactly ${cmd_count} shell commands that accomplish the task on $(uname -s). Return ONLY a JSON array of command strings, no explanation. Example: [\"ls -la\", \"pwd\"]"

  # Build env overrides — only set BASE_URL/AUTH_TOKEN when configured (empty = use Anthropic API)
  local -a env_prefix=(CLAUDECODE=)
  if [[ -n "$claude_base_url" ]]; then
    env_prefix+=(ANTHROPIC_BASE_URL="$claude_base_url")
  fi
  if [[ -n "$claude_auth_token" ]]; then
    env_prefix+=(ANTHROPIC_AUTH_TOKEN="$claude_auth_token")
  fi

  local output
  output=$(env "${env_prefix[@]}" \
    claude -p \
    --model "$claude_model" \
    --system-prompt "$sys_prompt" \
    --no-session-persistence \
    --tools "" \
    "$user_query" 2>/dev/null)
  local exit_code=$?

  if [[ $exit_code -ne 0 ]] || [[ -z "$output" ]]; then
    log_debug "Claude CLI failed (exit: $exit_code)" "$output"
    return 1
  fi

  log_debug "Claude raw response:" "$output"

  # Extract JSON array from response and output one command per line
  local commands
  commands=$(echo "$output" | python3 -c '
import sys, json, re
text = sys.stdin.read()
# Try to find a JSON array in the response
match = re.search(r"\[.*\]", text, re.DOTALL)
if match:
    try:
        cmds = json.loads(match.group())
        for c in cmds:
            print(c)
        sys.exit(0)
    except: pass
# Fallback: extract lines that look like commands from code blocks
in_block = False
for line in text.splitlines():
    stripped = line.strip()
    if stripped.startswith("```"):
        in_block = not in_block
        continue
    if in_block and stripped and not stripped.startswith("#"):
        print(stripped)
' 2>/dev/null)

  if [[ -z "$commands" ]]; then
    log_debug "Failed to parse commands from Claude response"
    return 1
  fi

  print -r -- "$commands"
  return 0
}

_kollzsh_codex_cmd() {
  local user_query="$1"
  local cmd_count="${KOLLZSH_COMMAND_COUNT:-5}"
  local codex_model="${KOLLZSH_CODEX_MODEL}"

  local prompt="You are a shell command generator. Given a task description, return exactly ${cmd_count} shell commands that accomplish the task on $(uname -s). Return ONLY the commands, no explanation.

Task: ${user_query}"

  # Constrain the response shape so we get parseable JSON back
  local schema_file
  schema_file=$(mktemp -t kollzsh_codex_schema) || return 1
  local out_file
  out_file=$(mktemp -t kollzsh_codex_out) || { rm -f "$schema_file"; return 1; }

  print -r -- '{"type":"object","properties":{"commands":{"type":"array","items":{"type":"string"}}},"required":["commands"],"additionalProperties":false}' > "$schema_file"

  local -a model_args=()
  [[ -n "$codex_model" ]] && model_args=(--model "$codex_model")

  # NOTE: stdin must be redirected from /dev/null. When stdin is not a TTY,
  # `codex exec` blocks on "Reading additional input from stdin..." forever,
  # which would hang the zle widget.
  local err
  err=$(codex exec \
    "${model_args[@]}" \
    --skip-git-repo-check \
    --ephemeral \
    --sandbox read-only \
    --color never \
    --output-schema "$schema_file" \
    --output-last-message "$out_file" \
    "$prompt" < /dev/null 2>&1 > /dev/null)
  local exit_code=$?

  local output
  output=$(<"$out_file")

  KOLLZSH_LAST_ERROR="$err"
  if [[ $exit_code -ne 0 ]] || [[ -z "$output" ]]; then
    rm -f "$schema_file" "$out_file" 2>/dev/null
    log_debug "Codex CLI failed (exit: $exit_code)" "$err"
    return 1
  fi

  log_debug "Codex raw response:" "$output"

  # NOTE: feed the file straight to python. Piping via `echo "$output"` would
  # collapse backslash escapes (e.g. `\\;` -> `\;`) and corrupt the JSON.
  local commands
  commands=$(python3 -c '
import sys, json, re
text = sys.stdin.read()
# Preferred path: the --output-schema object
try:
    obj = json.loads(text)
    if isinstance(obj, dict) and isinstance(obj.get("commands"), list):
        for c in obj["commands"]:
            print(c)
        sys.exit(0)
except Exception: pass
# Fallback: a bare JSON array somewhere in the text
match = re.search(r"\[.*\]", text, re.DOTALL)
if match:
    try:
        for c in json.loads(match.group()):
            print(c)
        sys.exit(0)
    except Exception: pass
# Last resort: fenced code block lines
in_block = False
for line in text.splitlines():
    stripped = line.strip()
    if stripped.startswith("```"):
        in_block = not in_block
        continue
    if in_block and stripped and not stripped.startswith("#"):
        print(stripped)
' < "$out_file" 2>/dev/null)

  rm -f "$schema_file" "$out_file" 2>/dev/null

  if [[ -z "$commands" ]]; then
    log_debug "Failed to parse commands from Codex response"
    return 1
  fi

  print -r -- "$commands"
  return 0
}

check_codex_auth() {
  # Codex uses OAuth credentials stored in $CODEX_HOME (default ~/.codex)
  local codex_home="${CODEX_HOME:-$HOME/.codex}"
  if [[ ! -f "$codex_home/auth.json" ]]; then
    echo "🚨 Codex is not authenticated!"
    echo "Please sign in with: codex login"
    return 1
  fi
  return 0
}

validate_required() {
  # Check required tools are installed
  check_command "fzf" || return 1

  if [[ "${KOLLZSH_PLATFORM:l}" == "codex" ]]; then
    # Codex CLI platform - check codex is installed and authenticated
    check_command "codex" || return 1
    check_codex_auth || return 1
  elif [[ "${KOLLZSH_PLATFORM:l}" == "claude" ]]; then
    # Claude Code CLI platform - check claude is installed
    check_command "claude" || return 1
    check_claude_server || return 1
  elif [[ "${KOLLZSH_PLATFORM:l}" == "mlx" ]]; then
    # Check if Rust binary exists (not needed for claude/mlx)
    if [[ ! -x "$KOLLZSH_BIN" ]]; then
      check_command "python3" || return 1
    fi
    # MLX platform - check if uv is installed (MLX still uses Python)
    check_command "uv" || return 1
  elif [[ "${KOLLZSH_PLATFORM:l}" == "llamacpp" ]]; then
    if [[ ! -x "$KOLLZSH_BIN" ]]; then
      check_command "python3" || return 1
    fi
    # llama.cpp platform
    check_llamacpp_running || return 1
  elif [[ "${KOLLZSH_PLATFORM:l}" == "vllm" ]]; then
    if [[ ! -x "$KOLLZSH_BIN" ]]; then
      check_command "python3" || return 1
    fi
    # vLLM platform
    check_vllm_running || return 1
  else
    if [[ ! -x "$KOLLZSH_BIN" ]]; then
      check_command "python3" || return 1
    fi
    # Ollama platform
    check_ollama_running || return 1

    # Check if the specified model exists
    if ! curl -s "${KOLLZSH_URL}/api/tags" | grep -q $KOLLZSH_MODEL; then
      echo "🚨 Model ${KOLLZSH_MODEL} not found!"
      echo "Please pull it with: ollama pull ${KOLLZSH_MODEL}"
      return 1
    fi
  fi
}

fzf_kollzsh() {
  setopt extendedglob
  local validate_out
  validate_out=$(validate_required 2>&1)
  local validate_status=$?
  if [[ $validate_status -ne 0 ]]; then
    kollzsh_show_error "kollzsh: requirements check failed" "$validate_out"
    return 1
  fi

  KOLLZSH_USER_QUERY=$BUFFER

  if [[ -z "${KOLLZSH_USER_QUERY//[[:space:]]}" ]]; then
    zle -M "kollzsh: type a request first, then press the shortcut"
    return 1
  fi

  log_debug "User query:" "$KOLLZSH_USER_QUERY"

  zle end-of-line
  zle reset-prompt

  print
  print -u1 "👻Please wait..."

  # Get absolute path to the script directory
  PLUGIN_DIR=${${(%):-%x}:A:h}

  # Select backend based on platform
  local cmd_status=0
  if [[ "${KOLLZSH_PLATFORM:l}" == "codex" ]]; then
    # Codex CLI (OAuth via `codex login`)
    KOLLZSH_COMMANDS=$(_kollzsh_codex_cmd "$KOLLZSH_USER_QUERY")
    cmd_status=$?
  elif [[ "${KOLLZSH_PLATFORM:l}" == "claude" ]]; then
    # Claude Code CLI with local LM Studio backend
    KOLLZSH_COMMANDS=$(_kollzsh_claude_cmd "$KOLLZSH_USER_QUERY")
    cmd_status=$?
  elif [[ "${KOLLZSH_PLATFORM:l}" == "mlx" ]]; then
    # MLX still uses Python (requires mlx-lm library)
    KOLLZSH_COMMANDS=$(_kollzsh_capture_cmd "$PLUGIN_DIR/mlx_util.py" "$KOLLZSH_USER_QUERY")
    cmd_status=$?
  elif [[ -x "$KOLLZSH_BIN" ]]; then
    # Use Rust binary if available
    if [[ "${KOLLZSH_PLATFORM:l}" == "llamacpp" ]]; then
      KOLLZSH_COMMANDS=$(_kollzsh_capture_cmd "$KOLLZSH_BIN" llamacpp "$KOLLZSH_USER_QUERY")
      cmd_status=$?
    elif [[ "${KOLLZSH_PLATFORM:l}" == "vllm" ]]; then
      KOLLZSH_COMMANDS=$(_kollzsh_capture_cmd "$KOLLZSH_BIN" vllm "$KOLLZSH_USER_QUERY")
      cmd_status=$?
    else
      KOLLZSH_COMMANDS=$(_kollzsh_capture_cmd "$KOLLZSH_BIN" ollama "$KOLLZSH_USER_QUERY")
      cmd_status=$?
    fi
  else
    # Fall back to Python scripts
    if [[ "${KOLLZSH_PLATFORM:l}" == "llamacpp" ]]; then
      KOLLZSH_COMMANDS=$(_kollzsh_capture_cmd "$KOLLZSH_PYTHON" "$PLUGIN_DIR/llamacpp_util.py" "$KOLLZSH_USER_QUERY")
      cmd_status=$?
    elif [[ "${KOLLZSH_PLATFORM:l}" == "vllm" ]]; then
      KOLLZSH_COMMANDS=$(_kollzsh_capture_cmd "$KOLLZSH_PYTHON" "$PLUGIN_DIR/vllm_util.py" "$KOLLZSH_USER_QUERY")
      cmd_status=$?
    else
      KOLLZSH_COMMANDS=$(_kollzsh_capture_cmd "$KOLLZSH_PYTHON" "$PLUGIN_DIR/ollama_util.py" "$KOLLZSH_USER_QUERY")
      cmd_status=$?
    fi
  fi
  
  if [[ $cmd_status -ne 0 ]] || [[ -z "$KOLLZSH_COMMANDS" ]]; then
    log_debug "Failed to parse commands (exit: $cmd_status)"
    tput cuu 1 2>/dev/null
    kollzsh_show_error "kollzsh: backend failed to return commands" "$KOLLZSH_LAST_ERROR"
    return 1
  fi
  
  log_debug "Extracted commands:" "$KOLLZSH_COMMANDS"

  tput cuu 1 # cleanup waiting message

  # Use echo to pipe the commands to fzf
  KOLLZSH_SELECTED=$(print -r -- "$KOLLZSH_COMMANDS" | fzf --ansi --height=~10 --cycle)
  if [ -n "$KOLLZSH_SELECTED" ]; then
    BUFFER="$KOLLZSH_SELECTED"
    CURSOR=${#BUFFER}  # Move cursor to end of buffer
    
    # Ensure we're not accepting the line
    zle -R
    zle reset-prompt
    
    log_debug "Selected command:" "$KOLLZSH_SELECTED"
  else
    log_debug "No command selected"
  fi
  
  return 0
}

fzf_kollzsh_thinking() {
  setopt extendedglob

  # Thinking mode only works with MLX platform
  if [[ "${KOLLZSH_PLATFORM:l}" != "mlx" ]]; then
    echo "🚨 Thinking mode requires MLX platform!"
    echo "Set: export KOLLZSH_PLATFORM=MLX"
    return 1
  fi

  # Check uv is installed
  if ! command -v uv &> /dev/null; then
    echo "🚨 uv not found! Install it from: https://docs.astral.sh/uv/"
    return 1
  fi

  KOLLZSH_USER_QUERY=$BUFFER

  if [[ -z "${KOLLZSH_USER_QUERY//[[:space:]]}" ]]; then
    zle -M "kollzsh: type a request first, then press the shortcut"
    return 1
  fi

  zle end-of-line
  zle reset-prompt

  print
  print -u1 "🧠 Thinking..."

  # Get absolute path to the script directory
  PLUGIN_DIR=${${(%):-%x}:A:h}

  # Run MLX in thinking mode
  KOLLZSH_RESPONSE=$(_kollzsh_capture_cmd "$PLUGIN_DIR/mlx_util.py" "$KOLLZSH_USER_QUERY" --thinking)
  local cmd_status=$?

  if [[ $cmd_status -ne 0 ]] || [[ -z "$KOLLZSH_RESPONSE" ]]; then
    log_debug "Thinking mode failed (exit: $cmd_status)"
    tput cuu 1 2>/dev/null
    kollzsh_show_error "kollzsh: thinking mode failed" "$KOLLZSH_LAST_ERROR"
    return 1
  fi

  log_debug "Thinking response:" "$KOLLZSH_RESPONSE"

  # Display the response
  print
  print "============================================================"
  print "Response:"
  print "============================================================"
  print "$KOLLZSH_RESPONSE"
  print "============================================================"

  # Clear the buffer and reset
  BUFFER=""
  zle -R
  zle reset-prompt

  return 0
}

# REPL history file
KOLLZSH_REPL_HISTORY_FILE="${XDG_DATA_HOME:-$HOME/.local/share}/kollzsh/repl_history"

# Ensure history directory exists
mkdir -p "$(dirname "$KOLLZSH_REPL_HISTORY_FILE")" 2>/dev/null

# Get commands from AI (shared helper)
_kollzsh_get_commands() {
  local user_query="$1"
  local plugin_dir="${0:A:h}"
  local commands=""

  if [[ "${KOLLZSH_PLATFORM:l}" == "codex" ]]; then
    commands=$(_kollzsh_codex_cmd "$user_query")
  elif [[ "${KOLLZSH_PLATFORM:l}" == "claude" ]]; then
    commands=$(_kollzsh_claude_cmd "$user_query")
  elif [[ "${KOLLZSH_PLATFORM:l}" == "mlx" ]]; then
    commands=$(_kollzsh_capture_cmd "$plugin_dir/mlx_util.py" "$user_query")
  elif [[ -x "$KOLLZSH_BIN" ]]; then
    if [[ "${KOLLZSH_PLATFORM:l}" == "llamacpp" ]]; then
      commands=$(_kollzsh_capture_cmd "$KOLLZSH_BIN" llamacpp "$user_query")
    elif [[ "${KOLLZSH_PLATFORM:l}" == "vllm" ]]; then
      commands=$(_kollzsh_capture_cmd "$KOLLZSH_BIN" vllm "$user_query")
    else
      commands=$(_kollzsh_capture_cmd "$KOLLZSH_BIN" ollama "$user_query")
    fi
  else
    if [[ "${KOLLZSH_PLATFORM:l}" == "llamacpp" ]]; then
      commands=$(_kollzsh_capture_cmd "$KOLLZSH_PYTHON" "$plugin_dir/llamacpp_util.py" "$user_query")
    elif [[ "${KOLLZSH_PLATFORM:l}" == "vllm" ]]; then
      commands=$(_kollzsh_capture_cmd "$KOLLZSH_PYTHON" "$plugin_dir/vllm_util.py" "$user_query")
    else
      commands=$(_kollzsh_capture_cmd "$KOLLZSH_PYTHON" "$plugin_dir/ollama_util.py" "$user_query")
    fi
  fi
  local backend_status=$?

  # Propagate backend failure; otherwise callers see exit 0 with empty output.
  (( backend_status != 0 )) && return $backend_status
  [[ -z "$commands" ]] && return 1

  print -r -- "$commands"
}

# REPL mode function
kollzsh_repl() {
  # Color codes
  local CYAN='\033[0;36m'
  local GREEN='\033[0;32m'
  local YELLOW='\033[0;33m'
  local RED='\033[0;31m'
  local BLUE='\033[0;34m'
  local MAGENTA='\033[0;35m'
  local BOLD='\033[1m'
  local DIM='\033[2m'
  local RESET='\033[0m'

  # Load history into array
  local -a repl_history
  if [[ -f "$KOLLZSH_REPL_HISTORY_FILE" ]]; then
    repl_history=("${(@f)$(cat "$KOLLZSH_REPL_HISTORY_FILE")}")
  fi

  local history_index=${#repl_history[@]}
  local current_input=""
  local saved_input=""

  print
  print "${BOLD}${CYAN}╔════════════════════════════════════════════════════════════╗${RESET}"
  print "${BOLD}${CYAN}║${RESET}  ${BOLD}${MAGENTA}🍺 KOLLZSH REPL${RESET}  ${DIM}(AI-powered command suggestions)${RESET}        ${BOLD}${CYAN}║${RESET}"
  print "${BOLD}${CYAN}╠════════════════════════════════════════════════════════════╣${RESET}"
  print "${BOLD}${CYAN}║${RESET}  ${DIM}• Type a task description and press Enter${RESET}                ${BOLD}${CYAN}║${RESET}"
  print "${BOLD}${CYAN}║${RESET}  ${DIM}• Use ↑/↓ arrows to navigate history${RESET}                     ${BOLD}${CYAN}║${RESET}"
  print "${BOLD}${CYAN}║${RESET}  ${DIM}• Select a command with fzf, then choose to run it${RESET}       ${BOLD}${CYAN}║${RESET}"
  print "${BOLD}${CYAN}║${RESET}  ${DIM}• Type 'exit', 'quit', or press Ctrl-C/Ctrl-D to exit${RESET}    ${BOLD}${CYAN}║${RESET}"
  print "${BOLD}${CYAN}╚════════════════════════════════════════════════════════════╝${RESET}"
  print

  while true; do
    # Use vared for line editing with history support
    local input=""
    print -n "${BOLD}${GREEN}kollzsh>${RESET} "

    # Read with line editing
    if ! read -r input; then
      # Ctrl-D pressed
      print
      print "${DIM}Exiting REPL...${RESET}"
      break
    fi

    # Trim whitespace
    input="${input#"${input%%[![:space:]]*}"}"
    input="${input%"${input##*[![:space:]]}"}"

    # Check for exit commands
    if [[ -z "$input" ]]; then
      continue
    fi

    if [[ "$input" == "exit" || "$input" == "quit" || "$input" == "q" ]]; then
      print "${DIM}Exiting REPL...${RESET}"
      break
    fi

    # Add to history
    repl_history+=("$input")
    echo "$input" >> "$KOLLZSH_REPL_HISTORY_FILE"

    # Show loading indicator
    print "${DIM}🔍 Generating commands...${RESET}"

    # Get commands from AI
    local commands
    commands=$(_kollzsh_get_commands "$input")

    if [[ -z "$commands" ]]; then
      print "${RED}No commands generated. Try rephrasing your query.${RESET}"
      continue
    fi

    # Clear loading message
    tput cuu 1
    tput el

    # Show commands with fzf
    local selected
    selected=$(print -r -- "$commands" | fzf --ansi --height=~15 --cycle \
      --header="Select a command (Enter to choose, Esc to cancel)" \
      --preview="echo 'Command preview:'; echo {}; echo; echo 'Press Enter to select, then choose to run or edit'" \
      --preview-window=down:3:wrap)

    if [[ -z "$selected" ]]; then
      print "${DIM}No command selected.${RESET}"
      continue
    fi

    print "${CYAN}Selected:${RESET} ${BOLD}$selected${RESET}"
    print

    # Ask what to do with the command
    local action
    print "${YELLOW}What would you like to do?${RESET}"
    print "  ${BOLD}[r]${RESET}un  - Execute the command and show output"
    print "  ${BOLD}[e]${RESET}dit - Edit the command before running"
    print "  ${BOLD}[c]${RESET}opy - Copy to clipboard"
    print "  ${BOLD}[s]${RESET}kip - Skip and continue"
    print -n "${YELLOW}Choice [r/e/c/s]:${RESET} "
    read -r action

    case "${action:l}" in
      r|run|"")
        print
        print "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
        print "${BOLD}${BLUE}▶ Running:${RESET} ${DIM}$selected${RESET}"
        print "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
        print

        # Execute and capture output
        local output exit_code
        output=$(eval "$selected" 2>&1)
        exit_code=$?

        if [[ -n "$output" ]]; then
          echo "$output"
        fi

        print
        print "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
        if [[ $exit_code -eq 0 ]]; then
          print "${GREEN}✓ Command completed successfully (exit code: $exit_code)${RESET}"
        else
          print "${RED}✗ Command failed (exit code: $exit_code)${RESET}"
        fi
        print "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
        print
        ;;
      e|edit)
        print -n "${YELLOW}Edit command:${RESET} "
        local edited="$selected"
        vared edited

        if [[ -n "$edited" ]]; then
          print
          print "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
          print "${BOLD}${BLUE}▶ Running:${RESET} ${DIM}$edited${RESET}"
          print "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
          print

          local output exit_code
          output=$(eval "$edited" 2>&1)
          exit_code=$?

          if [[ -n "$output" ]]; then
            echo "$output"
          fi

          print
          print "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
          if [[ $exit_code -eq 0 ]]; then
            print "${GREEN}✓ Command completed successfully (exit code: $exit_code)${RESET}"
          else
            print "${RED}✗ Command failed (exit code: $exit_code)${RESET}"
          fi
          print "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
          print
        fi
        ;;
      c|copy)
        if command -v xclip &>/dev/null; then
          echo -n "$selected" | xclip -selection clipboard
          print "${GREEN}✓ Copied to clipboard (xclip)${RESET}"
        elif command -v xsel &>/dev/null; then
          echo -n "$selected" | xsel --clipboard
          print "${GREEN}✓ Copied to clipboard (xsel)${RESET}"
        elif command -v wl-copy &>/dev/null; then
          echo -n "$selected" | wl-copy
          print "${GREEN}✓ Copied to clipboard (wl-copy)${RESET}"
        elif command -v pbcopy &>/dev/null; then
          echo -n "$selected" | pbcopy
          print "${GREEN}✓ Copied to clipboard (pbcopy)${RESET}"
        else
          print "${RED}No clipboard tool found (install xclip, xsel, wl-copy, or pbcopy)${RESET}"
        fi
        print
        ;;
      s|skip)
        print "${DIM}Skipped.${RESET}"
        print
        ;;
      *)
        print "${DIM}Unknown action, skipping.${RESET}"
        print
        ;;
    esac
  done
}

# ZLE widget wrapper for REPL mode
fzf_kollzsh_repl() {
  # Clear the current line and run REPL
  BUFFER=""
  zle reset-prompt

  # Run REPL in a subshell-like environment
  kollzsh_repl

  # Reset prompt after REPL exits
  zle reset-prompt
}

# Claude Code agent mode - runs claude as an autonomous agent that executes commands
kollzsh_claude_agent() {
  local user_query="$BUFFER"

  if [[ -z "${user_query//[[:space:]]}" ]]; then
    zle -M "kollzsh: type a prompt first, then press Ctrl-l"
    return 1
  fi

  # Check claude CLI is available
  if ! command -v claude &> /dev/null; then
    zle -M "kollzsh: claude CLI not found! Install: npm install -g @anthropic-ai/claude-code"
    return 1
  fi

  # Check local server is reachable (only if a custom base URL is configured)
  local claude_base_url="${KOLLZSH_CLAUDE_BASE_URL}"
  if [[ -n "$claude_base_url" ]]; then
    if ! curl -s --connect-timeout 2 "${claude_base_url}/v1/models" &> /dev/null; then
      zle -M "kollzsh: server not running at ${claude_base_url} - start it first"
      return 1
    fi
  fi

  log_debug "Claude agent query:" "$user_query"

  # Clear buffer and drop into claude agent
  BUFFER=""
  zle reset-prompt

  local model_info="${KOLLZSH_CLAUDE_MODEL}"
  [[ -n "$claude_base_url" ]] && model_info+=" via ${claude_base_url}" || model_info+=" via Anthropic API"

  print
  print "\033[1m\033[35m🤖 Launching Claude Code agent...\033[0m"
  print "\033[2mPrompt: ${user_query}\033[0m"
  print "\033[2mModel: ${model_info}\033[0m"
  print

  # Build env overrides — only set BASE_URL/AUTH_TOKEN when configured
  local -a env_prefix=(CLAUDECODE=)
  if [[ -n "$claude_base_url" ]]; then
    env_prefix+=(ANTHROPIC_BASE_URL="$claude_base_url")
  fi
  if [[ -n "${KOLLZSH_CLAUDE_AUTH_TOKEN}" ]]; then
    env_prefix+=(ANTHROPIC_AUTH_TOKEN="${KOLLZSH_CLAUDE_AUTH_TOKEN}")
  fi

  # Launch claude interactively with the prompt pre-set
  env "${env_prefix[@]}" \
    claude \
    --model "${KOLLZSH_CLAUDE_MODEL}" \
    --system-prompt "" \
    --dangerously-skip-permissions \
    --tools "Bash,Read" \
    -- "$user_query"

  local exit_code=$?

  print
  if [[ $exit_code -eq 0 ]]; then
    print "\033[32m✓ Claude agent finished\033[0m"
  else
    print "\033[31m✗ Claude agent exited with code $exit_code\033[0m"
  fi

  log_debug "Claude agent finished (exit: $exit_code)"

  zle reset-prompt
  return 0
}

# Claude Code Sonnet mode - runs claude with latest Sonnet via Anthropic API
kollzsh_claude_sonnet() {
  local user_query="$BUFFER"

  if [[ -z "${user_query//[[:space:]]}" ]]; then
    zle -M "kollzsh: type a prompt first, then press Ctrl-\\"
    return 1
  fi

  # Check claude CLI is available
  if ! command -v claude &> /dev/null; then
    zle -M "kollzsh: claude CLI not found! Install: npm install -g @anthropic-ai/claude-code"
    return 1
  fi

  log_debug "Claude Sonnet query:" "$user_query"

  # Clear buffer and drop into claude agent
  BUFFER=""
  zle reset-prompt

  print
  print "\033[1m\033[35m🤖 Launching Claude Code (Sonnet)...\033[0m"
  print "\033[2mPrompt: ${user_query}\033[0m"
  print "\033[2mModel: sonnet (latest)\033[0m"
  print

  # Launch claude with Sonnet via Anthropic API (no custom base URL)
  claude \
    --model "sonnet" \
    --system-prompt "" \
    --dangerously-skip-permissions \
    --tools "Bash,Read" \
    -- "$user_query"

  local exit_code=$?

  print
  if [[ $exit_code -eq 0 ]]; then
    print "\033[32m✓ Claude Sonnet agent finished\033[0m"
  else
    print "\033[31m✗ Claude Sonnet agent exited with code $exit_code\033[0m"
  fi

  log_debug "Claude Sonnet agent finished (exit: $exit_code)"

  zle reset-prompt
  return 0
}

# ZLE widget for Claude agent mode
fzf_kollzsh_claude() {
  kollzsh_claude_agent
}

# ZLE widget for Claude Sonnet mode
fzf_kollzsh_claude_sonnet() {
  kollzsh_claude_sonnet
}

# Only validate on startup for platforms that don't require a server to be running
# For llamacpp/vllm, validation happens when the hotkey is pressed
if [[ "${KOLLZSH_PLATFORM:l}" != "llamacpp" && "${KOLLZSH_PLATFORM:l}" != "vllm" && "${KOLLZSH_PLATFORM:l}" != "claude" && "${KOLLZSH_PLATFORM:l}" != "codex" ]]; then
  validate_required
fi

autoload -U fzf_kollzsh
zle -N fzf_kollzsh
bindkey "$KOLLZSH_HOTKEY" fzf_kollzsh

autoload -U fzf_kollzsh_thinking
zle -N fzf_kollzsh_thinking
bindkey "$KOLLZSH_THINKING_HOTKEY" fzf_kollzsh_thinking

autoload -U fzf_kollzsh_repl
zle -N fzf_kollzsh_repl
bindkey "$KOLLZSH_REPL_HOTKEY" fzf_kollzsh_repl

autoload -U fzf_kollzsh_claude
zle -N fzf_kollzsh_claude
bindkey "$KOLLZSH_CLAUDE_HOTKEY" fzf_kollzsh_claude

autoload -U fzf_kollzsh_claude_sonnet
zle -N fzf_kollzsh_claude_sonnet
bindkey "$KOLLZSH_CLAUDE_SONNET_HOTKEY" fzf_kollzsh_claude_sonnet

# Direct command alias for REPL mode
alias kollzsh-repl='kollzsh_repl'

# ── bare "# <task>" intercept ────────────────────────────────────────
# Typing  # upgrade flutter  and pressing Enter asks the LLM for a single
# best command, runs it, and records it in history as:
#   <command> # <original comment>
#
# Set KOLLZSH_COMMENT_RUN=0 to disable this intercept entirely.
(( ! ${+KOLLZSH_COMMENT_RUN} )) && KOLLZSH_COMMENT_RUN=1
export KOLLZSH_COMMENT_RUN

# Ask the backend for exactly one command (no fzf picker).
_kollzsh_single_command() {
  local user_query="$1"
  local saved_count="$KOLLZSH_COMMAND_COUNT"
  # Ask for one candidate; take the first line regardless of what comes back.
  KOLLZSH_COMMAND_COUNT=1
  local out
  out=$(_kollzsh_get_commands "$user_query")
  local status_code=$?
  KOLLZSH_COMMAND_COUNT="$saved_count"

  (( status_code != 0 )) && return $status_code

  # First non-empty line
  local line
  for line in ${(f)out}; do
    line="${line#"${line%%[![:space:]]*}"}"
    [[ -n "$line" ]] && { print -r -- "$line"; return 0; }
  done
  return 1
}

_kollzsh_comment_run() {
  local comment="$1"

  print
  print -u1 "👻Please wait..."

  local cmd
  cmd=$(_kollzsh_single_command "$comment")
  local gen_status=$?

  tput cuu 1 2>/dev/null # cleanup waiting message

  if (( gen_status != 0 )) || [[ -z "$cmd" ]]; then
    kollzsh_show_error "kollzsh: backend failed to return a command" "$KOLLZSH_LAST_ERROR"
    return 1
  fi

  # Record as "<command> # <comment>" so history explains itself.
  local hist_entry="${cmd} # ${comment}"
  print -s -- "$hist_entry"
  fc -AI 2>/dev/null

  log_debug "Comment-run:" "$hist_entry"

  # Show what is about to run, then execute it.
  print -r -- "$ ${cmd}"
  eval "$cmd"
  return $?
}

# ── #@ prefix intercept ──────────────────────────────────────────────
# Typing  #@ <query>  and pressing Enter triggers kollzsh automatically.
# The overhead for normal commands is a single string prefix check (~0ms).
_kollzsh_accept_line() {
  # Bare "# <task>" (but NOT "#@", handled below) — generate and run.
  if (( KOLLZSH_COMMENT_RUN )) && [[ "$BUFFER" == '#'* && "$BUFFER" != '#@'* ]]; then
    local comment="${BUFFER#\#}"
    comment="${comment#"${comment%%[![:space:]]*}"}"

    if [[ -n "$comment" ]]; then
      # Clear the prompt line, then run outside of zle.
      BUFFER=""
      zle .accept-line
      _kollzsh_comment_run "$comment"
      return 0
    fi
  fi

  if [[ "$BUFFER" == '#@'* ]]; then
    # Strip the "#@" prefix and optional leading whitespace after it
    BUFFER="${BUFFER#\#@}"
    BUFFER="${BUFFER#"${BUFFER%%[![:space:]]*}"}"

    if [[ -z "$BUFFER" ]]; then
      # Bare "#@" with no query — just clear and return
      zle reset-prompt
      return 0
    fi

    # Invoke kollzsh with the query
    fzf_kollzsh
    return $?
  fi

  # Normal command — pass through to the real accept-line
  zle .accept-line
}

zle -N accept-line _kollzsh_accept_line
