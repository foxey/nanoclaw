#!/usr/bin/env bash
#
# nanoclaw-update.sh — scripted in-place update of a v2 install to a git ref
# (V2_MIGRATION §7.2 item 6; docs/upgrade-recovery.md).
#
# For anything non-trivial, prefer running `/update-nanoclaw` over SSH — the
# upstream skill does worktree staging, skill refresh, and richer rollback. This
# wrapper is for simple, unattended ref bumps. The load-bearing step is the
# upgrade marker stamp (scripts/upgrade-state.ts set, §4.1): without it the host
# refuses to boot on the next start.
#
# Flow:  backup -> record current SHA -> fetch -> checkout <ref> (as a SHA)
#        -> pnpm install --frozen-lockfile -> pnpm run build -> pnpm run migrate
#        -> container/build.sh -> upgrade-state set -> restart -> health-check.
# On ANY failure after the checkout, roll back to the recorded SHA, rebuild,
# re-stamp, and restart — then exit non-zero.
#
# Usage:
#   bin/nanoclaw-update.sh <ref> [--skip-image] [--skip-migrate]
#
#   <ref>           git tag/branch/SHA to update to (required)
#   --skip-image    don't rebuild the agent image (faster; only if unchanged)
#   --skip-migrate  don't run DB migrations (only if you know there are none)
set -euo pipefail

SCRIPT="${BASH_SOURCE[0]}"
while [ -h "$SCRIPT" ]; do
  DIR="$(cd -P "$(dirname "$SCRIPT")" && pwd)"
  SCRIPT="$(readlink "$SCRIPT")"
  [[ "$SCRIPT" != /* ]] && SCRIPT="$DIR/$SCRIPT"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SCRIPT")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

REF=""
SKIP_IMAGE=0
SKIP_MIGRATE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --skip-image) SKIP_IMAGE=1; shift ;;
    --skip-migrate) SKIP_MIGRATE=1; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    -*) echo "unknown arg: $1" >&2; exit 2 ;;
    *) if [ -z "$REF" ]; then REF="$1"; shift; else echo "unexpected arg: $1" >&2; exit 2; fi ;;
  esac
done
[ -n "$REF" ] || { echo "FAILED: a target ref is required (usage: nanoclaw-update.sh <ref>)" >&2; exit 2; }

cd "$PROJECT_ROOT"
# shellcheck source=/dev/null
source "$PROJECT_ROOT/setup/lib/install-slug.sh"
UNIT="$(systemd_unit)"

run_as_owner() { sudo -u "$(stat -c '%U' "$PROJECT_ROOT/.git")" bash -lc "cd '$PROJECT_ROOT' && $1"; }

echo "=== nanoclaw-update -> $REF ==="
echo "unit=$UNIT"

# --- 1. Backup first (leave service stopped; we control restart below) ---
echo "--- Backup ---"
"$SCRIPT_DIR/nanoclaw-backup.sh" --no-restart

# --- 2. Record the current SHA for rollback ---
PREV_SHA="$(run_as_owner 'git rev-parse HEAD')"
echo "current SHA: $PREV_SHA"

# --- 3. Fetch + resolve the target ref to a concrete SHA ---
# Resolving to a SHA avoids `git checkout --detach <branch>` failing with
# `'--detach' cannot be used with -b` for a branch ref (V2_MIGRATION §9 spike).
run_as_owner 'git fetch --tags --prune origin'
NEW_SHA="$(run_as_owner "git rev-parse --verify --quiet 'origin/${REF}^{commit}' || git rev-parse --verify --quiet '${REF}^{commit}'")"
[ -n "$NEW_SHA" ] || { echo "FAILED: cannot resolve ref '$REF'" >&2; exit 1; }
echo "target SHA:  $NEW_SHA"

if [ "$NEW_SHA" = "$PREV_SHA" ]; then
  echo "Already at $NEW_SHA — nothing to do."
  sudo systemctl start "$UNIT" 2>/dev/null || true
  exit 0
fi

# --- Build/stamp/restart helper, reused for the forward path and rollback ---
build_stamp_restart() {
  local sha="$1"
  run_as_owner "git checkout --detach '$sha'"
  run_as_owner 'corepack enable && pnpm install --frozen-lockfile'
  run_as_owner 'pnpm run build'
  [ "$SKIP_MIGRATE" = "1" ] || run_as_owner 'pnpm run migrate'
  [ "$SKIP_IMAGE" = "1" ] || run_as_owner 'bash container/build.sh'
  # Stamp ONLY after build (+migrate/+image) succeeded — else the tripwire is
  # decoration (§4.1). If any step above failed, set -e already aborted.
  run_as_owner 'pnpm exec tsx scripts/upgrade-state.ts set'
  sudo systemctl start "$UNIT"
}

# --- Health check: service active + the ncl socket present within a window ---
health_ok() {
  local deadline=$(( $(date +%s) + 60 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if systemctl is-active --quiet "$UNIT" && [ -S "$PROJECT_ROOT/data/ncl.sock" ]; then
      return 0
    fi
    sleep 3
  done
  return 1
}

# --- 4. Forward update, with rollback on failure ---
rollback() {
  echo "!!! Update failed — rolling back to $PREV_SHA" >&2
  sudo systemctl stop "$UNIT" 2>/dev/null || true
  if build_stamp_restart "$PREV_SHA" && health_ok; then
    echo "Rolled back to $PREV_SHA and healthy." >&2
  else
    echo "ROLLBACK ALSO FAILED — manual intervention required. Backup is under the backups dir." >&2
  fi
  exit 1
}

echo "--- Applying $NEW_SHA ---"
sudo systemctl stop "$UNIT" 2>/dev/null || true
if ! build_stamp_restart "$NEW_SHA"; then
  rollback
fi

echo "--- Health check ---"
if ! health_ok; then
  echo "Health check failed after update." >&2
  rollback
fi

echo "=== nanoclaw-update complete: now at $NEW_SHA ($REF) ==="
