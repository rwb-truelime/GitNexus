#!/bin/sh
# GitNexus Docker Entrypoint
#
# Scans /repos/ for indexed repositories (.gitnexus/ directories) and:
#   1. Creates an OverlayFS mount for each repo's .gitnexus/ directory
#      - Lower (read-only): /repos/<name>/.gitnexus  (host files, bind-mounted)
#      - Upper (writable):  tmpfs in /tmp/overlay/<name>/upper  (WAL/lock files)
#      - Work:              tmpfs in /tmp/overlay/<name>/work
#      - Merged:            /repos-data/<name>  (what the backend reads from)
#   2. Builds ~/.gitnexus/registry.json pointing to the merged paths
#
# This lets LadybugDB write WAL/lock files without modifying host files.
# When `gitnexus analyze` updates the host's lbug file, the change is visible
# through the overlay immediately. Restart the backend to re-open connections.

set -e

# Entrypoint runs as root (for mount); app runs as node user (UID 1000)
APP_USER="node"
GITNEXUS_HOME="/home/$APP_USER"
REGISTRY_DIR="$GITNEXUS_HOME/.gitnexus"
REGISTRY_FILE="$REGISTRY_DIR/registry.json"
OVERLAY_BASE="/tmp/overlay"
DATA_BASE="/repos-data"

mkdir -p "$REGISTRY_DIR"

echo "Scanning /repos/ for indexed repositories..."

# Start JSON array
echo "[" > "$REGISTRY_FILE"

first=true
for meta_file in /repos/*/.gitnexus/meta.json; do
    [ -f "$meta_file" ] || continue

    repo_dir=$(dirname "$(dirname "$meta_file")")
    repo_name=$(basename "$repo_dir")
    lower_dir="$repo_dir/.gitnexus"
    upper_dir="$OVERLAY_BASE/$repo_name/upper"
    work_dir="$OVERLAY_BASE/$repo_name/work"
    merged_dir="$DATA_BASE/$repo_name"

    # Create overlay directories
    mkdir -p "$upper_dir" "$work_dir" "$merged_dir"

    # Mount a single tmpfs for overlay upper+work (must be on same filesystem)
    # Writes (WAL/lock files) go to RAM, not disk
    mount -t tmpfs tmpfs "$OVERLAY_BASE/$repo_name"

    # Recreate subdirs inside the tmpfs
    mkdir -p "$upper_dir" "$work_dir"

    # Make writable by app user (LadybugDB creates .wal/.lock files here)
    chown $APP_USER:$APP_USER "$upper_dir" "$work_dir" "$merged_dir"

    # Create the OverlayFS mount
    mount -t overlay overlay \
        -o "lowerdir=$lower_dir,upperdir=$upper_dir,workdir=$work_dir" \
        "$merged_dir"

    echo "  Overlay: $lower_dir -> $merged_dir (writes to tmpfs)"

    # Extract fields from meta.json (read from merged view)
    indexed_at=$(cat "$merged_dir/meta.json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('indexedAt',''))" 2>/dev/null || echo "")
    last_commit=$(cat "$merged_dir/meta.json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('lastCommit',''))" 2>/dev/null || echo "")

    # Extract stats
    stats=$(cat "$merged_dir/meta.json" | python3 -c "
import sys, json
m = json.load(sys.stdin)
s = m.get('stats', {})
print(json.dumps({
    'files': s.get('files', 0),
    'nodes': s.get('nodes', 0),
    'edges': s.get('edges', 0),
    'communities': s.get('communities', 0),
    'processes': s.get('processes', 0),
    'embeddings': s.get('embeddings', 0)
}))
" 2>/dev/null || echo '{}')

    if [ "$first" = true ]; then
        first=false
    else
        echo "," >> "$REGISTRY_FILE"
    fi

    # storagePath points to the MERGED overlay (read from host, write to tmpfs)
    # path points to the original repo (for source file access)
    cat >> "$REGISTRY_FILE" <<ENTRY
  {
    "name": "$repo_name",
    "path": "$repo_dir",
    "storagePath": "$merged_dir",
    "indexedAt": "$indexed_at",
    "lastCommit": "$last_commit",
    "stats": $stats
  }
ENTRY

    echo "  Found: $repo_name (storage: $merged_dir)"
done

echo "]" >> "$REGISTRY_FILE"

repo_count=$(cat "$REGISTRY_FILE" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
echo "Registry: $repo_count repo(s) registered."
echo ""

# Make registry readable by the app user
chown $APP_USER:$APP_USER "$REGISTRY_FILE"

# Drop privileges and execute the main command (gitnexus serve)
exec gosu $APP_USER "$@"
