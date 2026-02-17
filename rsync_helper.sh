#!/usr/bin/env bash
# Requires Bash 4.4+
set -euo pipefail

# -- Colors --
if [[ -t 1 ]]; then
  RED=$(tput setaf 1)
  GREEN=$(tput setaf 2)
  YELLOW=$(tput setaf 3)
  BOLD=$(tput bold)
  RESET=$(tput sgr0)
else
  RED="" GREEN="" YELLOW="" BOLD="" RESET=""
fi

# -- Helper Functions --

# Trap interrupts for cleaner exit
cleanup() {
  trap - SIGINT SIGTERM ERR EXIT
  # Any specific cleanup code can go here
}
trap cleanup SIGINT SIGTERM ERR EXIT

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

prompt() {
  local var_name="$1"
  local msg="$2"
  local default="${3:-}"
  local required="${4:-true}"
  local input=""

  # Prepare prompt string using colors
  local prompt_str="${BOLD}${msg}${RESET}"
  if [[ -n "$default" ]]; then
    prompt_str+=" [${YELLOW}${default}${RESET}]"
  fi
  prompt_str+=": "

  read -r -p "$prompt_str" input >&2
  input="$(trim "$input")"
  
  if [[ -z "$input" ]]; then
    if [[ -n "$default" ]]; then
      input="$default"
    elif [[ "$required" == "true" ]]; then
      die "Input for '$msg' cannot be empty."
    fi
  fi

  printf -v "$var_name" '%s' "$input"
}

confirm() {
  local msg="$1"
  local input=""
  read -r -p "${BOLD}${msg}${RESET} [y/N]: " input >&2
  [[ "${input,,}" == "y" || "${input,,}" == "yes" ]]
}

die() { 
  echo "${RED}Error: $*${RESET}" >&2
  exit 1 
}

info() {
  echo "${GREEN}==> $*${RESET}"
}

warn() {
  echo "${YELLOW}WARNING: $*${RESET}"
}

# -- Main Script --

echo "${BOLD}=== rsync network transfer (local -> remote) ===${RESET}"

command -v rsync >/dev/null 2>&1 || die "rsync is not installed locally."

prompt LOCAL_DIR "Local folder to send (e.g. /mnt/home/transfer)"
[[ -d "$LOCAL_DIR" ]] || die "Local folder does not exist: $LOCAL_DIR"
# Normalize path: remove trailing slash
LOCAL_DIR="${LOCAL_DIR%/}"

echo
echo "Copy mode:"
echo "  1) Copy the ${BOLD}folder itself${RESET} (remote will contain .../$(basename "$LOCAL_DIR")/...)"
echo "  2) Copy only the ${BOLD}contents${RESET} (remote will contain the contents directly)"
prompt COPY_MODE "Choose 1 or 2" "1"
[[ "$COPY_MODE" == "1" || "$COPY_MODE" == "2" ]] || die "Invalid choice: $COPY_MODE"

prompt REMOTE_USER "Remote SSH user" "root"
prompt REMOTE_HOST "Remote host/IP" 
prompt REMOTE_DIR  "Remote destination folder" "/tmp"

prompt SSH_KEY "Path to SSH private key (leave blank to use agent/default)" "" "false"

# Build SSH base command
SSH_BASE=(ssh)
if [[ -n "$SSH_KEY" ]]; then
  [[ -f "$SSH_KEY" ]] || die "SSH key file not found: $SSH_KEY"
  SSH_BASE+=(-i "$SSH_KEY")
fi

prompt SSH_PORT "SSH port" "22"
if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || (( SSH_PORT < 1 || SSH_PORT > 65535 )); then
  die "Invalid SSH port: $SSH_PORT"
fi
[[ "$SSH_PORT" != "22" ]] && SSH_BASE+=(-p "$SSH_PORT")

# Add SSH options
SSH_BASE+=(-o StrictHostKeyChecking=accept-new)

# Config - Dry Run
DRY_RUN=false
confirm "Do a dry run first (recommended)?" && DRY_RUN=true

# Config - Sudo
USE_SUDO=false
echo
echo "Does the remote user ($REMOTE_USER) need sudo rights to write to $REMOTE_DIR?"
confirm "Use 'sudo rsync' on remote?" && USE_SUDO=true

# Config - Delete
USE_DELETE=false
echo
confirm "Mirror mode: delete files on remote that don't exist locally? (DANGEROUS)" && USE_DELETE=true

if $USE_DELETE && ! $DRY_RUN; then
  warn "Mirror/delete mode WITHOUT a dry run!"
  confirm "Are you ${BOLD}absolutely sure${RESET}?" || { echo "Aborted."; exit 0; }
fi

# Config - Compression
USE_COMPRESSION=false
confirm "Enable compression (-z)? (Recommended for Internet, skip for LAN)" && USE_COMPRESSION=true

# Config - Verbose
VERBOSE=false
confirm "Show per-file verbose output (instead of overall progress bar)?" && VERBOSE=true

REMOTE="${REMOTE_USER}@${REMOTE_HOST}"
REMOTE_DIR="${REMOTE_DIR%/}"

# -- Check connectivity & remote rsync --
info "Checking for rsync on remote host ($REMOTE)..."

# We add ConnectTimeout here so the check doesn't hang forever
if ! "${SSH_BASE[@]}" -o ConnectTimeout=10 "$REMOTE" "command -v rsync" >/dev/null 2>&1; then
  die "Cannot connect to $REMOTE or rsync is not installed there."
fi

# -- Construct Commands --

# Escape SSH arguments for passing into rsync's -e flag
SSH_CMD_STRING=""
for arg in "${SSH_BASE[@]}"; do
  printf -v arg_q '%q' "$arg"
  SSH_CMD_STRING+="${SSH_CMD_STRING:+ }${arg_q}"
done

# Rsync options
RSYNC_OPTS=(-a --numeric-ids --partial --human-readable)
if $VERBOSE; then
  RSYNC_OPTS+=(-v)
else
  RSYNC_OPTS+=(--info=progress2)
fi

$USE_DELETE && RSYNC_OPTS+=(--delete --delete-delay)
$DRY_RUN && RSYNC_OPTS+=(--dry-run)
$USE_COMPRESSION && RSYNC_OPTS+=(-z)

# Handle Sudo Rsync
if $USE_SUDO; then
  RSYNC_OPTS+=(--rsync-path="sudo rsync")
fi

# Path logic setup
if [[ "$COPY_MODE" == "1" ]]; then
  SRC="$LOCAL_DIR"
  DEST="${REMOTE}:${REMOTE_DIR}/"
  # We only need to ensure the parent folder exists, rsync will create the folder itself
  REMOTE_MKDIR="$REMOTE_DIR"
  RESULT_PATH="${REMOTE}:${REMOTE_DIR}/$(basename "$LOCAL_DIR")/"
else
  SRC="${LOCAL_DIR}/"
  DEST="${REMOTE}:${REMOTE_DIR}/"
  REMOTE_MKDIR="$REMOTE_DIR"
  RESULT_PATH="${REMOTE}:${REMOTE_DIR}/"
fi

# Remote Directory Creation Command
# If using sudo, we need to mkdir with sudo as well
MKDIR_COMMAND_STR="mkdir -p -- $(printf %q "$REMOTE_MKDIR")"
if $USE_SUDO; then
  MKDIR_COMMAND_STR="sudo $MKDIR_COMMAND_STR"
fi
MKDIR_CMD=("${SSH_BASE[@]}" "$REMOTE" "$MKDIR_COMMAND_STR")

# Main Rsync Command
RSYNC_CMD=(rsync "${RSYNC_OPTS[@]}" -e "$SSH_CMD_STRING" "$SRC" "$DEST")

echo
echo "${BOLD}=== Overview ===${RESET}"
echo "Local source:      $SRC"
echo "Remote target dir: $DEST"
echo "Result path:       ${GREEN}$RESULT_PATH${RESET}"
echo "Dry run:           $DRY_RUN"
echo "Remote delete:     $USE_DELETE"
echo "Sudo on remote:    $USE_SUDO"
echo
echo "Will run (1) ensure remote directory exists:"
echo "  ${YELLOW}${MKDIR_CMD[*]@Q}${RESET}"
echo
echo "Will run (2) rsync:"
echo "  ${YELLOW}${RSYNC_CMD[*]@Q}${RESET}"
echo

confirm "Proceed?" || { echo "Aborted."; exit 0; }

info "Step 1: Creating remote directory..."
"${MKDIR_CMD[@]}"

info "Step 2: Running Rsync..."
"${RSYNC_CMD[@]}"

info "Done."
