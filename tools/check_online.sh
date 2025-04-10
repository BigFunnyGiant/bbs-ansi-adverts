#!/bin/bash
#
# -----------------------------------------------------------------------------
# check_adverts.sh - BBS Telnet Checker and Dead Advert Handler
#
# DESCRIPTION:
#   This script checks each BBS entry in a JSON file (`adverts.json`) for 
#   reachability via telnet (using netcat). If a BBS is unreachable, the script:
#     - Moves the listed advert files to a `dead/` folder
#     - Appends the BBS entry to a `dead_adverts.json` archive
#     - Updates the live `adverts.json` to exclude dead entries
#
#   The script also supports:
#     - DRY RUN mode (to simulate the process)
#     - UNDO mode (to reverse the last run and restore advert files and JSONs)
#     - Command-line path input to work on any specified directory
#
# USAGE:
#   ./check_online.sh [DIRECTORY] [--dry-run|--undo]
#
# ARGUMENTS:
#   DIRECTORY   Optional. Directory containing adverts.json and advert files.
#              If omitted, the script’s own directory is used.
#
#   --dry-run   Optional. Simulates the actions without modifying any files.
#
#   --undo      Optional. Reverts the last file moves and JSON modifications.
#
# DEPENDENCIES:
#   - jq (for JSON parsing)
#   - nc (netcat, for host/port testing)
#
# OUTPUT:
#   - Updates `adverts.json` and `dead_adverts.json` in the specified directory
#   - Logs all operations to `check_adverts.log`
#   - Stores backups and undo information in a `backup/` directory
#
# -----------------------------------------------------------------------------

# === COMMAND-LINE ARGUMENTS ===
TARGET_DIR="$1"
DRY_RUN=0
UNDO_MODE=0

# === HELP MESSAGE ===
usage() {
    echo "Usage: $0 [DIRECTORY] [--dry-run|--undo]"
    echo "  DIRECTORY: Path to folder containing adverts.json & files (optional)"
    echo "  --dry-run: Run without making changes"
    echo "  --undo:    Undo the last operation"
    exit 1
}

# === HANDLE ARGUMENTS ===
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --undo) UNDO_MODE=1 ;;
        -*)
            echo "Unknown option: $arg"
            usage
            ;;
        *)
            if [[ -z "$TARGET_DIR_SET" ]]; then
                TARGET_DIR="$arg"
                TARGET_DIR_SET=true
            fi
            ;;
    esac
done

# If no directory given, use the script's directory
[[ -z "$TARGET_DIR" ]] && TARGET_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="$(realpath "$TARGET_DIR")"

# === PATH SETUP ===
INPUT_JSON="$TARGET_DIR/adverts.json"
DEAD_JSON="$TARGET_DIR/dead_adverts.json"
DEAD_DIR="$TARGET_DIR/dead"
BACKUP_DIR="$TARGET_DIR/backup"
LOG_FILE="$TARGET_DIR/check_adverts.log"
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
UNDO_FILE="$BACKUP_DIR/$TIMESTAMP.undo"

# === FUNCTIONS ===
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $*" >> "$LOG_FILE"
}

ensure_dirs() {
    mkdir -p "$DEAD_DIR" "$BACKUP_DIR"
    touch "$LOG_FILE"
    [[ ! -f "$DEAD_JSON" ]] && echo "[]" > "$DEAD_JSON"
}

undo_last_run() {
    latest_undo=$(ls -t "$BACKUP_DIR"/*.undo 2>/dev/null | head -n 1)
    [[ -z "$latest_undo" ]] && { log "❌ No undo file found."; exit 1; }

    log "⏪ Undoing last run from file: $latest_undo"

    while IFS= read -r line; do
        src_file=$(echo "$line" | cut -d '|' -f1)
        dest_file=$(echo "$line" | cut -d '|' -f2)

        if [[ -f "$src_file" ]]; then
            mv "$src_file" "$dest_file"
            log "↩️ Restored $src_file → $dest_file"
        else
            log "⚠️ File missing for undo: $src_file"
        fi
    done < "$latest_undo"

    json_backup="${latest_undo/.undo/.json}"
    dead_backup="${latest_undo/.undo/_dead.json}"

    if [[ -f "$json_backup" && -f "$dead_backup" ]]; then
        cp "$json_backup" "$INPUT_JSON"
        cp "$dead_backup" "$DEAD_JSON"
        log "✅ JSON files restored from backup."
    else
        log "⚠️ JSON backups not found. Cannot fully undo."
    fi

    exit 0
}

# === BEGIN ===
ensure_dirs
log "===== Script started at $TIMESTAMP in $TARGET_DIR ====="

[[ "$UNDO_MODE" -eq 1 ]] && undo_last_run

# Backup current state
cp "$INPUT_JSON" "$BACKUP_DIR/$TIMESTAMP.json"
cp "$DEAD_JSON" "$BACKUP_DIR/${TIMESTAMP}_dead.json"

# Temp files
TMP_LIVE=$(mktemp)
TMP_DEAD=$(mktemp)

jq -c '.[]' "$INPUT_JSON" | while read -r entry; do
    telnet=$(echo "$entry" | jq -r '.telnet')
    host=$(echo "$telnet" | cut -d':' -f1)
    port=$(echo "$telnet" | cut -s -d':' -f2)
    [[ -z "$port" ]] && port=23

    log "🔍 Checking $host:$port"

    if nc -z -w 3 "$host" "$port" 2>/dev/null; then
        log "✅ $host:$port is alive"
        echo "$entry" >> "$TMP_LIVE"
    else
        log "❌ $host:$port is dead"

        for advert in $(echo "$entry" | jq -r '.adverts[]'); do
            src="$TARGET_DIR/$advert"
            dest="$DEAD_DIR/$(basename "$advert")"

            if [[ -f "$src" ]]; then
                if [[ "$DRY_RUN" -eq 1 ]]; then
                    log "🧪 Would move $src → $dest"
                else
                    mv "$src" "$dest"
                    log "📦 Moved $src → $dest"
                    echo "$dest|$src" >> "$UNDO_FILE"
                fi
            else
                log "⚠️ File not found or already moved: $src"
            fi
        done

        echo "$entry" >> "$TMP_DEAD"
    fi
done

if [[ "$DRY_RUN" -eq 0 ]]; then
    jq -s '.' "$TMP_LIVE" > "$INPUT_JSON"
    jq -s '.[0] + .[1]' "$DEAD_JSON" "$TMP_DEAD" > "${DEAD_JSON}.tmp" && mv "${DEAD_JSON}.tmp" "$DEAD_JSON"
else
    log "🧪 DRY RUN: Skipped updating JSON files."
fi

rm "$TMP_LIVE" "$TMP_DEAD"
log "✅ Script finished."
