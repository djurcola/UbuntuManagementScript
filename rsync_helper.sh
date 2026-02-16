#!/usr/bin/env bash
set -euo pipefail

prompt() {
  local var_name="$1"
  local msg="$2"
  local default="${3:-}"
  local input=""
  if [[ -n "$default" ]]; then
    read -r -p "$msg [$default]: " input
    input="${input:-$default}"
  else
    read -r -p "$msg: " input
  fi
  printf -v "$var_name" '%s' "$input"
}

confirm() {
  local msg="$1"
  local input=""
  read -r -p "$msg [y/N]: " input
  [[ "${input,,}" == "y" || "${input,,}" == "yes" ]]
}

die() { echo "Error: $*" >&2; exit 1; }

echo "=== rsync network transfer (local -> remote) ==="

prompt LOCAL_DIR "Local folder to send (e.g. /mnt/home/transfer)"
[[ -d "$LOCAL_DIR" ]] || die "Local folder does not exist: $LOCAL_DIR"
LOCAL_DIR="${LOCAL_DIR%/}"   # normalize

echo
echo "Copy mode:"
echo "  1) Copy the folder itself (remote will contain .../$(basename "$LOCAL_DIR")/...)"
echo "  2) Copy only the folder contents (remote will contain the contents directly)"
prompt COPY_MODE "Choose 1 or 2" "1"
[[ "$COPY_MODE" == "1" || "$COPY_MODE" == "2" ]] || die "Invalid choice: $COPY_MODE"

prompt REMOTE_USER "Remote SSH user (e.g. dietpi)"
prompt REMOTE_HOST "Remote host/IP (e.g. 192.168.20.12)"
prompt REMOTE_DIR  "Remote destination folder (e.g. /home/dietpi/docker/zwavejs2mqtt)"

prompt SSH_KEY "Path to SSH private key (leave blank to use default ssh agent/key)" ""
SSH_OPTS=()
if [[ -n "$SSH_KEY" ]]; then
  [[ -f "$SSH_KEY" ]] || die "SSH key file not found: $SSH_KEY"
  SSH_OPTS+=(-i "$SSH_KEY")
fi

prompt SSH_PORT "SSH port" "22"
if [[ "$SSH_PORT" != "22" ]]; then
  SSH_OPTS+=(-p "$SSH_PORT")
fi

DRY_RUN=false
confirm "Do a dry run first (recommended)?" && DRY_RUN=true

USE_DELETE=false
confirm "Mirror mode: delete files on remote that don't exist locally? (DANGEROUS)" && USE_DELETE=true

REMOTE="${REMOTE_USER}@${REMOTE_HOST}"
REMOTE_DIR="${REMOTE_DIR%/}"  # normalize

RSYNC_SSH=(ssh "${SSH_OPTS[@]}" -o BatchMode=no -o StrictHostKeyChecking=accept-new)

RSYNC_OPTS=(-a -v -z --numeric-ids --partial --info=progress2 --human-readable)
$USE_DELETE && RSYNC_OPTS+=(--delete --delete-delay)
$DRY_RUN && RSYNC_OPTS+=(--dry-run)

# Decide source/destination + what remote dir to create
if [[ "$COPY_MODE" == "1" ]]; then
  # Copy the directory itself: /srcdir -> remote:/destdir/
  # Result: /destdir/srcdir/...
  SRC="$LOCAL_DIR"              # no trailing slash
  DEST="${REMOTE}:${REMOTE_DIR}/"
  REMOTE_MKDIR="$REMOTE_DIR"    # ensure container exists; rsync will create srcdir under it
  RESULT_PATH="${REMOTE}:${REMOTE_DIR}/$(basename "$LOCAL_DIR")/"
else
  # Copy contents: /srcdir/ -> remote:/destdir/
  # Result: /destdir/<contents>...
  SRC="${LOCAL_DIR}/"           # trailing slash means "contents"
  DEST="${REMOTE}:${REMOTE_DIR}/"
  REMOTE_MKDIR="$REMOTE_DIR"    # destination itself must exist
  RESULT_PATH="${REMOTE}:${REMOTE_DIR}/"
fi

MKDIR_CMD=(ssh "${SSH_OPTS[@]}" -o BatchMode=no -o StrictHostKeyChecking=accept-new "$REMOTE" "mkdir -p -- \"${REMOTE_MKDIR}\"")
RSYNC_CMD=(rsync "${RSYNC_OPTS[@]}" -e "${RSYNC_SSH[*]}" "$SRC" "$DEST")

echo
echo "=== Overview ==="
echo "Copy mode:         $([[ "$COPY_MODE" == "1" ]] && echo "folder itself" || echo "contents only")"
echo "Local source:      $SRC"
echo "Remote target dir: $DEST"
echo "Result path:       $RESULT_PATH"
echo "SSH key:           ${SSH_KEY:-"(default)"}"
echo "SSH port:          $SSH_PORT"
echo "Dry run:           $DRY_RUN"
echo "Remote delete:     $USE_DELETE"
echo
echo "Will run (1) ensure remote directory exists:"
printf '  %q ' "${MKDIR_CMD[@]}"; echo
echo
echo "Will run (2) rsync:"
printf '  %q ' "${RSYNC_CMD[@]}"; echo
echo

confirm "Proceed?" || { echo "Aborted."; exit 0; }

"${MKDIR_CMD[@]}"
"${RSYNC_CMD[@]}"

echo
echo "Done."
