# default shortcut as Ctrl-o
(( ! ${+KOLLZSH_HOTKEY} )) && typeset -g KOLLZSH_HOTKEY='^o'
# default thinking shortcut as Ctrl-t
(( ! ${+KOLLZSH_THINKING_HOTKEY} )) && typeset -g KOLLZSH_THINKING_HOTKEY='^t'
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

# Export all KOLLZSH variables so Python scripts can access them
export KOLLZSH_PLATFORM KOLLZSH_MODEL KOLLZSH_COMMAND_COUNT KOLLZSH_URL KOLLZSH_API_KEY KOLLZSH_MAX_TOKENS
export KOLLZSH_LLAMACPP_PATH KOLLZSH_LLAMACPP_MODEL KOLLZSH_LLAMACPP_SERVER_URL KOLLZSH_LLAMACPP_N_CTX KOLLZSH_LLAMACPP_N_GPU_LAYERS
export KOLLZSH_VLLM_SERVER_URL KOLLZSH_VLLM_MODEL

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
  check_command "jq" || return 1
  check_command "fzf" || return 1
  check_command "python3" || return 1

  if [[ "${KOLLZSH_PLATFORM:l}" == "mlx" ]]; then
    # MLX platform - check if uv is installed
    check_command "uv" || return 1
  elif [[ "${KOLLZSH_PLATFORM:l}" == "llamacpp" ]]; then
    # llama.cpp platform
    check_command "curl" || return 1

    # Check if llama.cpp server is running or if we should start it
    check_llamacpp_running || return 1
  elif [[ "${KOLLZSH_PLATFORM:l}" == "vllm" ]]; then
    # vLLM platform
    check_command "curl" || return 1

    # Check if vLLM server is running
    check_vllm_running || return 1
  else
    # Ollama platform
    check_command "curl" || return 1

    # Check if Ollama is running
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

  # Select utility script based on platform
  if [[ "${KOLLZSH_PLATFORM:l}" == "mlx" ]]; then
    KOLLZSH_COMMANDS=$("$PLUGIN_DIR/mlx_util.py" "$KOLLZSH_USER_QUERY" 2>/dev/null)
  elif [[ "${KOLLZSH_PLATFORM:l}" == "llamacpp" ]]; then
    KOLLZSH_COMMANDS=$(python3 "$PLUGIN_DIR/llamacpp_util.py" "$KOLLZSH_USER_QUERY")
  elif [[ "${KOLLZSH_PLATFORM:l}" == "vllm" ]]; then
    KOLLZSH_COMMANDS=$(python3 "$PLUGIN_DIR/vllm_util.py" "$KOLLZSH_USER_QUERY")
  else
    KOLLZSH_COMMANDS=$(python3 "$PLUGIN_DIR/ollama_util.py" "$KOLLZSH_USER_QUERY")
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
