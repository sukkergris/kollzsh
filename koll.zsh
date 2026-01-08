# default shortcut as Ctrl-o
(( ! ${+KOLLZSH_HOTKEY} )) && typeset -g KOLLZSH_HOTKEY='^o'
# default thinking shortcut as Ctrl-t
(( ! ${+KOLLZSH_THINKING_HOTKEY} )) && typeset -g KOLLZSH_THINKING_HOTKEY='^t'
# default REPL shortcut as Ctrl-x Ctrl-o (two-key sequence, more reliable)
(( ! ${+KOLLZSH_REPL_HOTKEY} )) && typeset -g KOLLZSH_REPL_HOTKEY='^x^o'
# default platform (ollama, mlx, llamacpp, or vllm)
(( ! ${+KOLLZSH_PLATFORM} )) && KOLLZSH_PLATFORM='ollama'
# default ollama model as qwen2.5-coder:3b (for MLX, use e.g. Qwen/Qwen3-14B-MLX-4bit)
(( ! ${+KOLLZSH_MODEL} )) && KOLLZSH_MODEL='qwen2.5-coder:3b'
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

# Export all KOLLZSH variables so subprocesses can access them
export KOLLZSH_PLATFORM KOLLZSH_MODEL KOLLZSH_COMMAND_COUNT KOLLZSH_URL KOLLZSH_API_KEY KOLLZSH_MAX_TOKENS
export KOLLZSH_LLAMACPP_PATH KOLLZSH_LLAMACPP_MODEL KOLLZSH_LLAMACPP_SERVER_URL KOLLZSH_LLAMACPP_N_CTX KOLLZSH_LLAMACPP_N_GPU_LAYERS
export KOLLZSH_VLLM_SERVER_URL KOLLZSH_VLLM_MODEL

# Path to the Rust binary (built with `cargo build --release`)
KOLLZSH_BIN="${0:A:h}/target/release/kollzsh"

# Source utility functions
source "${0:A:h}/utils.zsh"

# Set up logging with proper permissions
KOLLZSH_LOG_FILE="/tmp/kollzsh_debug.log"
touch "$KOLLZSH_LOG_FILE"
chmod 666 "$KOLLZSH_LOG_FILE"

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

validate_required() {
  # Check required tools are installed
  check_command "fzf" || return 1

  # Check if Rust binary exists
  if [[ ! -x "$KOLLZSH_BIN" ]]; then
    # Fall back to Python if Rust binary not built
    check_command "python3" || return 1
  fi

  if [[ "${KOLLZSH_PLATFORM:l}" == "mlx" ]]; then
    # MLX platform - check if uv is installed (MLX still uses Python)
    check_command "uv" || return 1
  elif [[ "${KOLLZSH_PLATFORM:l}" == "llamacpp" ]]; then
    # llama.cpp platform
    check_llamacpp_running || return 1
  elif [[ "${KOLLZSH_PLATFORM:l}" == "vllm" ]]; then
    # vLLM platform
    check_vllm_running || return 1
  else
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
  validate_required
  if [ $? -eq 1 ]; then
    return 1
  fi

  KOLLZSH_USER_QUERY=$BUFFER

  zle end-of-line
  zle reset-prompt

  print
  print -u1 "👻Please wait..."

  log_debug "Raw response:" "$KOLLZSH_RESPONSE"

  # Get absolute path to the script directory
  PLUGIN_DIR=${${(%):-%x}:A:h}

  # Select backend based on platform
  if [[ "${KOLLZSH_PLATFORM:l}" == "mlx" ]]; then
    # MLX still uses Python (requires mlx-lm library)
    KOLLZSH_COMMANDS=$("$PLUGIN_DIR/mlx_util.py" "$KOLLZSH_USER_QUERY" 2>/dev/null)
  elif [[ -x "$KOLLZSH_BIN" ]]; then
    # Use Rust binary if available
    if [[ "${KOLLZSH_PLATFORM:l}" == "llamacpp" ]]; then
      KOLLZSH_COMMANDS=$("$KOLLZSH_BIN" llamacpp "$KOLLZSH_USER_QUERY" 2>/dev/null)
    elif [[ "${KOLLZSH_PLATFORM:l}" == "vllm" ]]; then
      KOLLZSH_COMMANDS=$("$KOLLZSH_BIN" vllm "$KOLLZSH_USER_QUERY" 2>/dev/null)
    else
      KOLLZSH_COMMANDS=$("$KOLLZSH_BIN" ollama "$KOLLZSH_USER_QUERY" 2>/dev/null)
    fi
  else
    # Fall back to Python scripts
    if [[ "${KOLLZSH_PLATFORM:l}" == "llamacpp" ]]; then
      KOLLZSH_COMMANDS=$(python3 "$PLUGIN_DIR/llamacpp_util.py" "$KOLLZSH_USER_QUERY")
    elif [[ "${KOLLZSH_PLATFORM:l}" == "vllm" ]]; then
      KOLLZSH_COMMANDS=$(python3 "$PLUGIN_DIR/vllm_util.py" "$KOLLZSH_USER_QUERY")
    else
      KOLLZSH_COMMANDS=$(python3 "$PLUGIN_DIR/ollama_util.py" "$KOLLZSH_USER_QUERY")
    fi
  fi
  
  if [ $? -ne 0 ] || [ -z "$KOLLZSH_COMMANDS" ]; then
    log_debug "Failed to parse commands"
    echo "Error: Failed to parse commands"
    return 1
  fi
  
  log_debug "Extracted commands:" "$KOLLZSH_COMMANDS"

  tput cuu 1 # cleanup waiting message

  # Use echo to pipe the commands to fzf
  KOLLZSH_SELECTED=$(echo "$KOLLZSH_COMMANDS" | fzf --ansi --height=~10 --cycle)
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

  zle end-of-line
  zle reset-prompt

  print
  print -u1 "🧠 Thinking..."

  # Get absolute path to the script directory
  PLUGIN_DIR=${${(%):-%x}:A:h}

  # Run MLX in thinking mode
  KOLLZSH_RESPONSE=$("$PLUGIN_DIR/mlx_util.py" "$KOLLZSH_USER_QUERY" --thinking 2>/dev/null)

  if [ $? -ne 0 ] || [ -z "$KOLLZSH_RESPONSE" ]; then
    log_debug "Thinking mode failed"
    echo "Error: Thinking mode failed"
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

  if [[ "${KOLLZSH_PLATFORM:l}" == "mlx" ]]; then
    commands=$("$plugin_dir/mlx_util.py" "$user_query" 2>/dev/null)
  elif [[ -x "$KOLLZSH_BIN" ]]; then
    if [[ "${KOLLZSH_PLATFORM:l}" == "llamacpp" ]]; then
      commands=$("$KOLLZSH_BIN" llamacpp "$user_query" 2>/dev/null)
    elif [[ "${KOLLZSH_PLATFORM:l}" == "vllm" ]]; then
      commands=$("$KOLLZSH_BIN" vllm "$user_query" 2>/dev/null)
    else
      commands=$("$KOLLZSH_BIN" ollama "$user_query" 2>/dev/null)
    fi
  else
    if [[ "${KOLLZSH_PLATFORM:l}" == "llamacpp" ]]; then
      commands=$(python3 "$plugin_dir/llamacpp_util.py" "$user_query")
    elif [[ "${KOLLZSH_PLATFORM:l}" == "vllm" ]]; then
      commands=$(python3 "$plugin_dir/vllm_util.py" "$user_query")
    else
      commands=$(python3 "$plugin_dir/ollama_util.py" "$user_query")
    fi
  fi

  echo "$commands"
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
    selected=$(echo "$commands" | fzf --ansi --height=~15 --cycle \
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

# Only validate on startup for platforms that don't require a server to be running
# For llamacpp/vllm, validation happens when the hotkey is pressed
if [[ "${KOLLZSH_PLATFORM:l}" != "llamacpp" && "${KOLLZSH_PLATFORM:l}" != "vllm" ]]; then
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

# Direct command alias for REPL mode
alias kollzsh-repl='kollzsh_repl'
