#!/usr/bin/env bash
#
# nanoclaw-backup.sh — on-demand, service-quiesced, file-level backup of a v2
# install (V2_MIGRATION §7.2 item 6). Complements the block-level DLM snapshots:
# this is the thing you run right before a risky change.
#
# Stops the host, tars the application state, restarts. Writes to
#   <backup-root>/nanoclaw/<UTC-timestamp>/nanoclaw-state.tgz
# where <backup-root> defaults to <data-dir>/backups (i.e. on the persistent
# EBS volume, so backups survive instance replacement).
#
# What is captured: data/, groups/, store/ (if present), .env, and
# ~/.config/nanoclaw/ (mount/sender allowlists live outside PROJECT_ROOT).
# data/ncl.sock is excluded — a live socket cannot be archived meaningfully
# (upstream's /update-nanoclaw omits sockets for the same reason).
#
# Usage:
#   bin/nanoclaw-backup.sh [--backup-root DIR] [--keep N] [--no-restart]
#
#   --backup-root DIR  where to write (default: $DATA_DIR/backups or
#                      /data/nanoclaw-v2/backups)
#   --keep N           prune all but the newest N backups afterward (default: keep all)
#   --no-restart       leave the service stopped after the backup (for chaining
#                      into an update flow that restarts itself)
#
# Exit non-zero on any failure; always attempts to restart the service on the
# way out unless --no-restart was given.
set -euo pipefail

# --- Resolve PROJECT_ROOT from this script (symlink-safe), like bin/ncl ---
SCRIPT="${BASH_SOURCE[0]}"
while [ -h "$SCRIPT" ]; do
  DIR="$(cd -P "$(dirname "$SCRIPT")" && pwd)"
  SCRIPT="$(readlink "$SCRIPT")"
  [[ "$SCRIPT" != /* ]] && SCRIPT="$DIR/$SCRIPT"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SCRIPT")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# --- Args ---
BACKUP_ROOT=""
KEEP=0
RESTART=1
while [ $# -gt 0 ]; do
  case "$1" in
    --backup-root) BACKUP_ROOT="$2"; shift 2 ;;
    --keep) KEEP="$2"; shift 2 ;;
    --no-restart) RESTART=0; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

cd "$PROJECT_ROOT"

# --- Derive the systemd unit + a sensible backup root ---
# shellcheck source=/dev/null
source "$PROJECT_ROOT/setup/lib/install-slug.sh"
UNIT="$(systemd_unit)"

# DATA_DIR mirrors the host's resolution; default matches the v2 bind-mount.
DATA_DIR="${DATA_DIR:-$PROJECT_ROOT/data}"
if [ -z "$BACKUP_ROOT" ]; then
  # Prefer the persistent volume so backups outlive the instance.
  if [ -d /data/nanoclaw-v2 ]; then
    BACKUP_ROOT="/data/nanoclaw-v2/backups"
  else
    BACKUP_ROOT="$DATA_DIR/backups"
  fi
fi

TS="$(date -u +%Y%m%dT%H%M%SZ)"
DEST_DIR="$BACKUP_ROOT/nanoclaw/$TS"
ARCHIVE="$DEST_DIR/nanoclaw-state.tgz"
mkdir -p "$DEST_DIR"

echo "=== nanoclaw-backup: $TS ==="
echo "PROJECT_ROOT=$PROJECT_ROOT"
echo "unit=$UNIT"
echo "archive=$ARCHIVE"

# --- Service control: stop, then guarantee a restart attempt on exit ---
was_active=0
if systemctl is-active --quiet "$UNIT" 2>/dev/null; then
  was_active=1
fi

restart_if_needed() {
  if [ "$RESTART" = "1" ] && [ "$was_active" = "1" ]; then
    echo "--- Restarting $UNIT ---"
    sudo systemctl start "$UNIT" || echo "WARN: failed to restart $UNIT — start it manually" >&2
  fi
}
trap restart_if_needed EXIT

if [ "$was_active" = "1" ]; then
  echo "--- Stopping $UNIT for a consistent snapshot ---"
  sudo systemctl stop "$UNIT"
else
  echo "--- $UNIT not active; backing up in place ---"
fi

# --- Build the tar member list from what actually exists ---
# Paths are relative to PROJECT_ROOT where possible; ~/.config/nanoclaw is
# absolute (it lives outside the checkout by design).
members=()
for rel in data groups store .env; do
  [ -e "$PROJECT_ROOT/$rel" ] && members+=("$rel")
done

CONFIG_DIR="${HOME}/.config/nanoclaw"

if [ "${#members[@]}" -eq 0 ] && [ ! -d "$CONFIG_DIR" ]; then
  echo "FAILED: nothing to back up (no data/groups/store/.env or ~/.config/nanoclaw)" >&2
  exit 1
fi

echo "--- Archiving: ${members[*]}$( [ -d "$CONFIG_DIR" ] && echo ' + ~/.config/nanoclaw' ) ---"

# Build the tar argument list explicitly. Two -C blocks: PROJECT_ROOT members,
# then (if present) the absolute ~/.config/nanoclaw. Exclude live sockets.
# --ignore-failed-read so a file vanishing mid-run doesn't abort the whole
# backup; a genuinely empty/failed archive is caught by the verify step below.
tar_args=(
  czf "$ARCHIVE"
  --exclude='data/ncl.sock'
  --exclude='data/cli.sock'
  --ignore-failed-read
)
if [ "${#members[@]}" -gt 0 ]; then
  tar_args+=(-C "$PROJECT_ROOT" "${members[@]}")
fi
if [ -d "$CONFIG_DIR" ]; then
  tar_args+=(-C "$HOME" .config/nanoclaw)
fi
tar "${tar_args[@]}"

# --- Verify the archive is real ---
if [ ! -s "$ARCHIVE" ] || ! tar tzf "$ARCHIVE" >/dev/null 2>&1; then
  echo "FAILED: backup archive missing or unreadable: $ARCHIVE" >&2
  exit 1
fi
SIZE="$(du -h "$ARCHIVE" | cut -f1)"
echo "Backup OK: $ARCHIVE ($SIZE)"

# --- Optional retention prune ---
if [ "$KEEP" -gt 0 ]; then
  echo "--- Pruning to newest $KEEP backups ---"
  # List timestamped dirs newest-first, drop the first $KEEP, remove the rest.
  ls -1dt "$BACKUP_ROOT/nanoclaw"/*/ 2>/dev/null | tail -n +"$((KEEP + 1))" | while read -r old; do
    echo "  removing $old"
    rm -rf "$old"
  done
fi

echo "=== nanoclaw-backup complete ==="
# restart_if_needed runs via the EXIT trap.
