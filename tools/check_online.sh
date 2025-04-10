#!/usr/bin/env bash

# this script checks each entry in adverts.json if they're not reachable it moves the file to the dead directory, and moves the entry to a second json file for manual checking.

INPUT_JSON="adverts.json"
DEAD_JSON="dead_adverts.json"
DEAD_DIR="dead"
LOG_FILE="check_adverts.log"

# Flags
DRY_RUN=0

# Check for dry-run argument
if [[ "$1" == "--dry-run" ]]; then
    DRY_RUN=1
    echo "🧪 Running in DRY RUN mode – no files will be moved or modified."
fi

# Ensure log and dead directory
mkdir -p "$DEAD_DIR"
touch "$LOG_FILE"

# Initialize dead JSON if needed
if [[ ! -f "$DEAD_JSON" ]]; then
    echo "[]" > "$DEAD_JSON"
fi

# Temp files
TMP_LIVE=$(mktemp)
TMP_DEAD=$(mktemp)

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $*" | tee -a "$LOG_FILE"
}

jq -c '.[]' "$INPUT_JSON" | while read -r entry; do
    telnet=$(echo "$entry" | jq -r '.telnet')
    host=$(echo "$telnet" | cut -d':' -f1)
    port=$(echo "$telnet" | cut -s -d':' -f2)
    [[ -z "$port" ]] && port=23

    log "Checking $host:$port..."

    if nc -z -w 3 "$host" "$port" 2>/dev/null; then
        log "✅ $host:$port is alive."
        echo "$entry" >> "$TMP_LIVE"
    else
        log "❌ $host:$port is dead."

        # Move files if they exist
        for advert in $(echo "$entry" | jq -r '.adverts[]'); do
            if [[ -f "$advert" ]]; then
                if [[ "$DRY_RUN" -eq 1 ]]; then
                    log "🧪 Would move $advert → $DEAD_DIR/"
                else
                    log "📦 Moving $advert → $DEAD_DIR/"
                    mv "$advert" "$DEAD_DIR/"
                fi
            else
                log "⚠️ File missing or already moved: $advert"
            fi
        done

        echo "$entry" >> "$TMP_DEAD"
    fi
done

# Update JSON files (skip if dry-run)
if [[ "$DRY_RUN" -eq 0 ]]; then
    jq -s '.' "$TMP_LIVE" > "$INPUT_JSON"
    jq -s '.[0] + .[1]' "$DEAD_JSON" "$TMP_DEAD" > "${DEAD_JSON}.tmp" && mv "${DEAD_JSON}.tmp" "$DEAD_JSON"
else
    log "🧪 DRY RUN: Not updating $INPUT_JSON or $DEAD_JSON."
fi

# Cleanup
rm "$TMP_LIVE" "$TMP_DEAD"

log "✅ Script completed."
