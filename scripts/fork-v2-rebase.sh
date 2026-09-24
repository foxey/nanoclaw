#!/usr/bin/env bash
#
# fork-v2-rebase.sh — automate the merge strategy from UPDATE_FORK.md.
#
# Rebases foxey/nanoclaw from its v1 line onto upstream nanocoai/nanoclaw
# v2.3.0, re-applying the fork's customizations the v2 way instead of merging
# 1931 commits across seams that no longer exist.
#
#   ./scripts/fork-v2-rebase.sh status          # where am I, what would run
#   ./scripts/fork-v2-rebase.sh freeze --apply --push
#   ./scripts/fork-v2-rebase.sh all --apply
#   ./scripts/fork-v2-rebase.sh promote --apply --push --i-have-pinned-the-iac
#
# DRY RUN IS THE DEFAULT. Nothing mutates without --apply. Nothing reaches a
# remote without --push. `promote` additionally refuses to run until you assert
# that the CDK stack pins nanoclawRef to the frozen v1 tag AND that deploy is
# live — see UPDATE_FORK.md §3 for why that ordering is not optional.
#
# Self-relocating: the script copies itself out of the worktree and re-execs,
# because `git checkout v2.3.0` would otherwise delete the file mid-run.
#
# What this script deliberately does NOT do (each needs a human):
#   §6a  re-applying the .gitignore / .env.example / .husky/pre-commit deltas
#        — it extracts them as reviewable patches and stops
#   §6e  re-implementing emoji-reaction approvals on the v2 approval seam
#   §6f  re-registering MCP servers (`ncl groups config add-mcp-server`)
#        — instance-side, needs a running v2 host
#   the Discord bot token, the OneCLI vault secret, and the agent wiring
#        — instance-side; see V2_MIGRATION.md §7
#
set -uo pipefail

# Corepack's first-use "Do you want to continue? [Y/n]" blocks on stdin even
# when its output is redirected, which reads as a hang rather than a prompt.
export COREPACK_ENABLE_DOWNLOAD_PROMPT=0

# ─── self-relocation ────────────────────────────────────────────────────
# `git checkout` of an upstream tag removes this file if it is tracked, and
# bash reads the script incrementally — the run would die mid-phase. Copy to a
# temp dir and re-exec from there, the same trick /update-nanoclaw uses to load
# its controller before mutating the tree.
if [ -z "${FORK_V2_RELOCATED:-}" ]; then
  _self="${BASH_SOURCE[0]}"
  [ -f "$_self" ] || { echo "cannot locate self ($_self)" >&2; exit 1; }
  _origin_repo="$(cd "$(dirname "$_self")/.." && pwd)"
  _tmp="$(mktemp -d "${TMPDIR:-/tmp}/fork-v2-rebase.XXXXXX")"
  cp "$_self" "$_tmp/fork-v2-rebase.sh"
  export FORK_V2_RELOCATED=1
  export FORK_V2_ORIGIN_REPO="$_origin_repo"
  export FORK_V2_TMP="$_tmp"
  trap 'rm -rf "$_tmp"' EXIT
  bash "$_tmp/fork-v2-rebase.sh" "$@"
  exit $?
fi

# ─── configuration (override via environment) ───────────────────────────

REPO="${FORK_V2_REPO:-${FORK_V2_ORIGIN_REPO:-$PWD}}"

# The v1 commit to freeze. Defaults to the fork HEAD recorded in UPDATE_FORK.md
# §1; validated below to actually be a v1.x tree before anything is tagged.
V1_COMMIT="${FORK_V2_V1_COMMIT:-1ac21d23}"
V1_TAG="${FORK_V2_V1_TAG:-v1.2.52-lovelace}"
V1_BRANCH="${FORK_V2_V1_BRANCH:-v1-maintenance}"

# Recommended base: v2.4.0 (2026-09-23) — it carries the gateway-seam change, so
# basing on v2.3.0 buys a second breaking migration straight afterwards. See
# UPDATE_FORK.md §10.
UPSTREAM_TAG="${FORK_V2_UPSTREAM_TAG:-v2.4.0}"
WORK_BRANCH="${FORK_V2_WORK_BRANCH:-v2-base}"
# Derived from the base after argument parsing, so --upstream-tag stays coherent.
V2_TAG="${FORK_V2_V2_TAG:-}"

UPSTREAM_REMOTE="${FORK_V2_UPSTREAM_REMOTE:-upstream}"
ORIGIN_REMOTE="${FORK_V2_ORIGIN_REMOTE:-origin}"
MAIN_BRANCH="${FORK_V2_MAIN_BRANCH:-main}"

# LiteLLM endpoint as seen from inside an agent container (V2_MIGRATION.md §1).
ANTHROPIC_BASE_URL_DEFAULT="${FORK_V2_BASE_URL:-http://host.docker.internal:4000}"

# Model the agent groups should use. Upstream moved the unset-model default to
# Opus 5.5 after v2.3.0; our LiteLLM registers exactly one model name, so leaving
# this blank means the agent asks for a model the proxy does not serve. Pin it.
DEFAULT_MODEL="${FORK_V2_DEFAULT_MODEL:-claude-sonnet-5}"

# Fork assets carried forward verbatim (UPDATE_FORK.md §4 item 6), plus the
# migration plan and this script itself — `promote` replaces main's tree with the
# v2 one, so anything not carried is silently dropped from main.
CARRY_PATHS="
container/skills/wiki
container/skills/use-imaprest-rest
.claude/skills/add-imaprest
UPDATE_FORK.md
V2_MIGRATION.md
scripts/fork-v2-rebase.sh
"

# Small config deltas that must be re-applied BY HAND — extracted as patches.
REVIEW_PATHS="
.gitignore
.env.example
.husky/pre-commit
"

# Fork customizations that must NOT survive the rebase (UPDATE_FORK.md §4).
# Checked in `verify` — their presence means something was ported that should
# have been deleted.
declare_obsolete() {
  cat <<'EOF'
src/session-commands.ts|/compact — runner-native in v2 (CHANGELOG 2.1.17)
src/session-commands.test.ts|test for the above
src/channels/registry.ts|v1 channel registry — v2 uses src/channels/channel-registry.ts
src/db.ts|v1 single-DB layer — v2 splits central + per-session
src/ipc.ts|v1 filesystem IPC — v2 uses session DB pairs
EOF
}

# State that must survive `git checkout` of an upstream tag, so it cannot live
# inside the worktree.
STATE_DIR="${FORK_V2_STATE_DIR:-$(dirname "$REPO")/.fork-v2-rebase}"

APPLY=0
PUSH=0
ASSUME_YES=0
IAC_PINNED=0
SKIP_TOOLCHAIN=0
NO_VERIFY_COMMITS=0
PHASE=""

# ─── output ─────────────────────────────────────────────────────────────

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_DIM=$'\033[2m'; C_RED=$'\033[31m'; C_GRN=$'\033[32m'
  C_YEL=$'\033[33m'; C_BLD=$'\033[1m'; C_OFF=$'\033[0m'
else
  C_DIM=""; C_RED=""; C_GRN=""; C_YEL=""; C_BLD=""; C_OFF=""
fi

say()   { printf '%s\n' "$*"; }
head1() { printf '\n%s%s%s\n\n' "$C_BLD" "$*" "$C_OFF"; }
ok()    { printf '%s✓%s  %s\n' "$C_GRN" "$C_OFF" "$*"; }
skip()  { printf '%s–%s  %s\n' "$C_DIM" "$C_OFF" "$*"; }
info()  { printf '%s·%s  %s\n' "$C_DIM" "$C_OFF" "$*"; }
warn()  { printf '%s!%s  %s\n' "$C_YEL" "$C_OFF" "$*"; }
die()   { printf '%s✗  %s%s\n' "$C_RED" "$*" "$C_OFF" >&2; exit 1; }

# Report a mutation. Under --apply it happened; in a dry run it did not, and
# saying "✓ tagged" either way is how a dry run gets mistaken for a real one.
did() {
  if [ "$APPLY" = 1 ]; then
    ok "$*"
  else
    printf '   %s→ pending: %s%s\n' "$C_DIM" "$*" "$C_OFF"
  fi
}

# Render argv the way a shell would accept it back, so a dry-run transcript is
# copy-pasteable and multi-word arguments don't read as separate ones.
quote_cmd() {
  local out="" a
  for a in "$@"; do
    case "$a" in
      *[!A-Za-z0-9._/=:@-]*|"") out="$out '$(printf '%s' "$a" | sed "s/'/'\\\\''/g")'" ;;
      *) out="$out $a" ;;
    esac
  done
  printf '%s' "${out# }"
}

# Echo a command, then run it only when --apply is set.
#
# FATAL ON FAILURE, deliberately. `set -e` is not used here (the phases need to
# inspect exit codes), so an unchecked failure would otherwise sail straight
# past — which is how `git fetch <missing-branch>` once produced two empty files
# and a "✓ copied" for each. Callers that can legitimately fail use run_try.
run() {
  if [ "$APPLY" = 1 ]; then
    printf '   %s$ %s%s\n' "$C_DIM" "$(quote_cmd "$@")" "$C_OFF"
    "$@" || die "command failed (exit $?): $(quote_cmd "$@")"
  else
    printf '   %s[dry-run] %s%s\n' "$C_DIM" "$(quote_cmd "$@")" "$C_OFF"
  fi
}

# Same, for a shell pipeline that needs redirection. Also fatal on failure.
run_sh() {
  if [ "$APPLY" = 1 ]; then
    printf '   %s$ %s%s\n' "$C_DIM" "$1" "$C_OFF"
    bash -c "$1" || die "command failed (exit $?): $1"
  else
    printf '   %s[dry-run] %s%s\n' "$C_DIM" "$1" "$C_OFF"
  fi
}

# Non-fatal variants, for the few steps where a non-zero exit is expected or
# where the caller reports the failure itself.
run_try() {
  if [ "$APPLY" = 1 ]; then
    printf '   %s$ %s%s\n' "$C_DIM" "$(quote_cmd "$@")" "$C_OFF"
    "$@"
  else
    printf '   %s[dry-run] %s%s\n' "$C_DIM" "$(quote_cmd "$@")" "$C_OFF"
  fi
}

run_sh_try() {
  if [ "$APPLY" = 1 ]; then
    printf '   %s$ %s%s\n' "$C_DIM" "$1" "$C_OFF"
    bash -c "$1"
  else
    printf '   %s[dry-run] %s%s\n' "$C_DIM" "$1" "$C_OFF"
  fi
}

# A redirected write leaves an empty file when the producing command fails,
# because the shell truncates the target before running it. Assert content.
assert_nonempty() {
  [ "$APPLY" = 1 ] || return 0
  [ -s "$1" ] || die "$1 is empty — the command that wrote it failed"
}

# Wrap a step that can run for many minutes, so silence doesn't read as a hang.
slow() {
  local label="$1"; shift
  info "$label — this can take a while; output follows"
  local start; start="$(date +%s)"
  # run_sh_try, not run_sh: every caller of `slow` supplies its own failure
  # message, and a fatal run_sh would make those unreachable.
  run_sh_try "$1" || return $?
  [ "$APPLY" = 1 ] && info "$label finished in $(( $(date +%s) - start ))s"
  return 0
}

# Guard for pnpm install / build / test. Returns 1 when the caller should skip.
toolchain_enabled() {
  if [ "$SKIP_TOOLCHAIN" = 1 ]; then
    skip "$1 (--skip-toolchain)"
    return 1
  fi
  return 0
}

# Which mechanism does the checked-out base use to get ANTHROPIC_BASE_URL into a
# container? Upstream changed this after v2.3.0, so the endpoint phase has to ask
# the tree rather than assume.
#
#   providers-claude  v2.3.0 and earlier. src/providers/claude.ts contributes
#                     ANTHROPIC_BASE_URL + ANTHROPIC_AUTH_TOKEN=placeholder; you
#                     register it by appending an import to src/providers/index.ts.
#                     Auth step: `setup/index.ts --step auth`.
#
#   gateway-skill     post-v2.3.0 main. Core ships only the gateway CONTRACT;
#                     src/providers/claude.ts and src/gateway-providers/onecli.ts
#                     are gone. The /add-onecli skill materializes the adapter and
#                     its withProviderEnv() sets ANTHROPIC_BASE_URL +
#                     ANTHROPIC_AUTH_TOKEN=gateway-managed. Auth step:
#                     `--step gateway` then `--step gateway-auth`.
#                     The host fails closed: "No gateway provider is registered
#                     in this build".
# Is upstream cutting a release newer than our base? A `release/vX.Y.Z` branch
# whose package.json is already version-bumped means the tag is imminent, and
# basing on the older tag buys a second migration immediately afterwards.
check_pending_release() {
  local branch ver newest
  newest=""
  for branch in $(git branch -r --list "$UPSTREAM_REMOTE/release/v*" 2>/dev/null); do
    ver="$(git show "$branch:package.json" 2>/dev/null | grep -m1 '"version"' | sed -E 's/.*"([^"]+)".*/\1/')"
    [ -n "$ver" ] || continue
    tag_exists "v$ver" && continue          # already released
    newest="$branch|$ver"
  done
  if [ -z "$newest" ]; then
    say "  ${C_DIM}no unreleased release/* branch ahead of $UPSTREAM_TAG${C_OFF}"
    return 0
  fi
  branch="${newest%%|*}"; ver="${newest##*|}"
  # Already targeting it? Then say so instead of advising a switch to itself.
  if [ "v$ver" = "$UPSTREAM_TAG" ] || [ "$ver" = "$UPSTREAM_TAG" ]; then
    say "  ${C_BLD}Base v$ver is upstream's pending release ($branch)${C_OFF}"
    say "    version-bumped but ${C_BLD}not yet tagged${C_OFF}; last commit $(git log -1 --format='%cs' "$branch")"
    say "    The base phase will refuse until the tag exists, and will offer the"
    say "    release branch or v2.3.0 as alternatives."
    return 0
  fi
  say "  ${C_BLD}${C_YEL}A release is being cut upstream: v$ver ($branch)${C_OFF}"
  if ref_exists "$UPSTREAM_TAG"; then
    say "    version-bumped, not yet tagged, $(git rev-list --count "$UPSTREAM_TAG..$branch" 2>/dev/null) commit(s) ahead of $UPSTREAM_TAG"
  else
    say "    version-bumped, not yet tagged"
  fi
  say "    last commit $(git log -1 --format='%cs' "$branch")"
  say ""
  say "    ${C_BLD}Prefer basing on v$ver once it is tagged.${C_OFF} It carries the gateway-seam"
  say "    change, so basing on $UPSTREAM_TAG means doing the v1→v2 migration and then"
  say "    a second gateway migration right after. See UPDATE_FORK.md §10."
  say ""
  say "    When tagged:  ${C_BLD}--upstream-tag v$ver${C_OFF}   (or FORK_V2_UPSTREAM_TAG=v$ver)"
}

detect_endpoint_flavor() {
  if [ -f src/providers/claude.ts ]; then
    echo "providers-claude"
  elif [ -d .claude/skills/add-onecli ] || [ -f src/gateway-providers/installed.ts ]; then
    echo "gateway-skill"
  else
    echo "unknown"
  fi
}

# Phases after `base` only make sense on the work branch. Fatal under --apply;
# advisory in a dry run, where `base` never actually checked it out.
require_work_branch() {
  [ "$(current_branch)" = "$WORK_BRANCH" ] && return 0
  if [ "$APPLY" = 0 ]; then
    warn "not on $WORK_BRANCH (dry run — base has not created it yet)"
    return 0
  fi
  die "expected to be on $WORK_BRANCH — run the base phase first"
}

confirm() {
  [ "$ASSUME_YES" = 1 ] && return 0
  [ "$APPLY" = 0 ] && return 0
  printf '%s%s%s [y/N] ' "$C_BLD" "$1" "$C_OFF"
  read -r reply < /dev/tty || return 1
  case "$reply" in [yY]|[yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}

# ─── argument parsing ───────────────────────────────────────────────────

usage() {
  cat <<EOF
${C_BLD}fork-v2-rebase.sh${C_OFF} — apply UPDATE_FORK.md's merge strategy

usage: scripts/fork-v2-rebase.sh <phase> [options]

phases
  status     report current state; run no mutations at all
  preflight  check toolchain (node 22+, pnpm, git) and repo shape
  freeze     §3   tag ${V1_TAG}, branch ${V1_BRANCH}
  base       §6a+b create ${WORK_BRANCH} from ${UPSTREAM_TAG}, carry assets, install, build, test
  discord    §6c  install the Discord adapter from the channels branch
  endpoint   §6d  register the custom Anthropic endpoint provider (source side)
  verify     §6g+h detectors, removal assertions, build, test, final delta
  promote    §6h  join histories, fast-forward ${MAIN_BRANCH}, tag ${V2_TAG}
  all        preflight -> freeze -> base -> discord -> endpoint -> verify

options
  --apply                   perform mutations (default: dry run)
  --push                    allow pushing to ${ORIGIN_REMOTE}
  -y, --yes                 skip confirmation prompts
  --i-have-pinned-the-iac   assert the CDK stack pins nanoclawRef to ${V1_TAG}
                            and that change is DEPLOYED (required by promote)
  --no-verify-commits       skip git hooks for this script's own commits. Needed
                            when v2's husky pre-commit hook can't find pnpm.
  --skip-toolchain          skip pnpm install / build / test. Use to iterate on
                            the git-side work; a cold pnpm install of the v2
                            tree takes >10 min, so never leave this on for the
                            run you actually trust.
  --repo PATH               fork checkout (default: this script's repo)
  --upstream-tag REF        upstream tag to base on (default ${UPSTREAM_TAG})
  --base-url URL            ANTHROPIC_BASE_URL to write (default ${ANTHROPIC_BASE_URL_DEFAULT})
  -h, --help                this text

Nothing is pushed, committed, or checked out without --apply.
EOF
}

[ $# -eq 0 ] && { usage; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    status|preflight|freeze|base|discord|endpoint|verify|promote|all) PHASE="$1"; shift ;;
    --apply) APPLY=1; shift ;;
    --push) PUSH=1; shift ;;
    -y|--yes) ASSUME_YES=1; shift ;;
    --i-have-pinned-the-iac) IAC_PINNED=1; shift ;;
    --skip-toolchain) SKIP_TOOLCHAIN=1; shift ;;
    --no-verify-commits) NO_VERIFY_COMMITS=1; shift ;;
    --repo) REPO="$2"; shift 2 ;;
    --upstream-tag) UPSTREAM_TAG="$2"; shift 2 ;;
    --base-url) ANTHROPIC_BASE_URL_DEFAULT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1  (see --help)" ;;
  esac
done

[ -n "$PHASE" ] || { usage; exit 2; }

# Keep the fork's release tag in step with whatever base was selected.
: "${V2_TAG:=${UPSTREAM_TAG}-lovelace}"
[ -d "$REPO/.git" ] || die "not a git repo: $REPO"
cd "$REPO" || die "cannot cd to $REPO"

# ─── shared helpers ─────────────────────────────────────────────────────

git_q() { git "$@" >/dev/null 2>&1; }

ref_exists()    { git_q rev-parse --verify --quiet "$1"; }
branch_exists() { git_q show-ref --verify --quiet "refs/heads/$1"; }
tag_exists()    { git_q show-ref --verify --quiet "refs/tags/$1"; }

current_branch() { git rev-parse --abbrev-ref HEAD 2>/dev/null; }

tree_clean() { [ -z "$(git status --porcelain 2>/dev/null)" ]; }

require_clean() {
  tree_clean && return 0
  # A dry run mutates nothing, so a dirty tree is not a hazard yet — warn and
  # keep going so the whole sequence can be previewed in one pass.
  if [ "$APPLY" = 0 ]; then
    warn "working tree is dirty — would block this phase under --apply"
    return 0
  fi
  say ""
  git status --short | sed 's/^/     /'
  say ""
  say "  ${C_DIM}Untracked files count too — this check matches upstream's${C_OFF}"
  say "  ${C_DIM}/update-nanoclaw, which also requires an empty git status.${C_OFF}"
  say ""
  die "working tree is not clean — commit or stash first"
}

# Commit an explicit set of paths. Never `git add -A`: a blanket stage on a
# half-migrated tree is how an untracked .env or a stray backup ends up in the
# history. Each phase names exactly what it touched.
commit_if_changed() {
  local message="$1"; shift
  local existing=() p
  for p in "$@"; do
    [ -e "$p" ] && existing+=("$p")
  done
  if [ ${#existing[@]} -eq 0 ]; then
    skip "nothing to commit for: $message"
    return 0
  fi
  run git add -- "${existing[@]}"
  if [ "$APPLY" = 1 ]; then
    if git diff --cached --quiet; then
      skip "no staged changes — already committed"
      return 0
    fi
  fi

  local -a commit_cmd=(git commit -m "$message")
  [ "$NO_VERIFY_COMMITS" = 1 ] && commit_cmd=(git commit --no-verify -m "$message")

  if run_try "${commit_cmd[@]}"; then
    did "committed: $message"
    return 0
  fi

  # v2 installs a husky pre-commit hook (package.json `prepare: husky`) that
  # shells out to `pnpm`. Once `pnpm install` has run, that hook is live — and it
  # exits 127 when pnpm isn't on the hook's PATH, which blocks every commit here.
  # Don't bypass hooks silently; say what happened and make the bypass explicit.
  say ""
  warn "The commit was rejected — most likely by the husky pre-commit hook."
  say  "     v2's hook runs pnpm; if pnpm isn't on the hook's PATH it exits 127."
  say ""
  say  "     Fix the PATH (preferred — the hook then actually runs):"
  say  "       ${C_BLD}export PATH=\"\$(dirname \"\$(command -v pnpm)\"):\$PATH\"${C_OFF}"
  say  "       ${C_DIM}with corepack: corepack enable, then confirm 'command -v pnpm'${C_OFF}"
  say ""
  say  "     Or re-run this phase with ${C_BLD}--no-verify-commits${C_OFF} to skip hooks for the"
  say  "     script's own mechanical commits. Your changes are already staged, so"
  say  "     nothing is lost either way."
  die "commit failed: $message"
}

pkg_version() {
  # package.json version at a ref, without checking it out.
  git show "$1:package.json" 2>/dev/null \
    | grep -m1 '"version"' | sed -E 's/.*"([^"]+)".*/\1/'
}

# Node/pnpm resolution. The local shell here has pnpm behind corepack and node
# behind a mise shim with no global default — a bare `pnpm` fails cryptically,
# so resolve explicitly and fail with the actual fix.
PNPM=""
resolve_pnpm() {
  [ -n "$PNPM" ] && return 0
  if command -v pnpm >/dev/null 2>&1; then PNPM="pnpm"; return 0; fi
  if command -v corepack >/dev/null 2>&1; then
    if [ "$APPLY" = 1 ]; then
      COREPACK_ENABLE_DOWNLOAD_PROMPT=0 corepack enable >/dev/null 2>&1 || true
    fi
    command -v pnpm >/dev/null 2>&1 && { PNPM="pnpm"; return 0; }
    PNPM="corepack pnpm"
    return 0
  fi
  return 1
}

check_node() {
  local v major
  v="$(node --version 2>/dev/null | sed 's/^v//')" || v=""
  if [ -z "$v" ]; then
    warn "node is not runnable"
    if command -v mise >/dev/null 2>&1; then
      local avail
      avail="$(mise ls node 2>/dev/null | awk 'NR==1{print $2}')"
      say "     mise has node installed but no version selected."
      say "     Fix with one of:"
      say "       ${C_BLD}mise use node@${avail:-22}${C_OFF}      (this directory)"
      say "       ${C_BLD}mise use -g node@${avail:-22}${C_OFF}   (global default)"
    else
      say "     Install Node 22+ (the repo pins 22 in .nvmrc)."
    fi
    return 1
  fi
  major="${v%%.*}"
  if [ "$major" -lt 22 ] 2>/dev/null; then
    warn "node $v is too old — v2 requires 22+ (better-sqlite3; CHANGELOG 2.3.0)"
    return 1
  fi
  ok "node $v"
  return 0
}

# Write a file only under --apply, with a dry-run preview.
write_file() {
  local path="$1" content="$2"
  if [ "$APPLY" = 1 ]; then
    printf '%s' "$content" > "$path"
    printf '   %s$ wrote %s (%s bytes)%s\n' "$C_DIM" "$path" "${#content}" "$C_OFF"
  else
    printf '   %s[dry-run] write %s (%s bytes)%s\n' "$C_DIM" "$path" "${#content}" "$C_OFF"
  fi
}

# ─── phase: preflight ───────────────────────────────────────────────────

phase_preflight() {
  head1 "Preflight"
  local fail=0

  command -v git >/dev/null 2>&1 && ok "git $(git --version | awk '{print $3}')" || { warn "git missing"; fail=1; }
  check_node || fail=1

  if resolve_pnpm; then
    ok "pnpm resolvable as: $PNPM"
  else
    warn "pnpm not resolvable (no pnpm, no corepack) — v2 requires pnpm 10.34.5"
    say  "     Node 22+ ships corepack; enable it with: ${C_BLD}corepack enable${C_OFF}"
    fail=1
  fi

  if command -v bun >/dev/null 2>&1; then
    ok "bun $(bun --version)"
  else
    info "bun missing — scripts/detect-driver-migration.ts will run via tsx instead"
  fi

  # Remotes
  if git remote get-url "$UPSTREAM_REMOTE" >/dev/null 2>&1; then
    ok "remote $UPSTREAM_REMOTE = $(git remote get-url "$UPSTREAM_REMOTE")"
  else
    warn "remote '$UPSTREAM_REMOTE' missing"; fail=1
  fi
  if git remote get-url "$ORIGIN_REMOTE" >/dev/null 2>&1; then
    ok "remote $ORIGIN_REMOTE = $(git remote get-url "$ORIGIN_REMOTE")"
  else
    warn "remote '$ORIGIN_REMOTE' missing"; fail=1
  fi

  tree_clean && ok "working tree clean" || warn "working tree dirty (blocks base/promote)"

  run mkdir -p "$STATE_DIR"
  info "state dir: $STATE_DIR"

  [ "$fail" = 0 ] || die "preflight failed — fix the above before continuing"
  ok "preflight passed"
}

# ─── phase: status ──────────────────────────────────────────────────────

phase_status() {
  head1 "Status"
  local head_sha head_ver
  head_sha="$(git rev-parse --short HEAD)"
  head_ver="$(pkg_version HEAD)"

  say "  repo            $REPO"
  say "  branch          $(current_branch) @ $head_sha  (package.json $head_ver)"
  say "  tree            $(tree_clean && echo clean || echo DIRTY)"
  say ""
  say "  ${C_BLD}freeze targets${C_OFF}"
  say "    v1 commit     $V1_COMMIT $(ref_exists "$V1_COMMIT" && echo "(present, package.json $(pkg_version "$V1_COMMIT"))" || echo "${C_RED}(MISSING)${C_OFF}")"
  say "    tag           $V1_TAG $(tag_exists "$V1_TAG" && echo "${C_GRN}exists${C_OFF}" || echo "${C_DIM}not created${C_OFF}")"
  say "    branch        $V1_BRANCH $(branch_exists "$V1_BRANCH" && echo "${C_GRN}exists${C_OFF}" || echo "${C_DIM}not created${C_OFF}")"
  say ""
  say "  ${C_BLD}rebase targets${C_OFF}"
  say "    upstream tag  $UPSTREAM_TAG $(ref_exists "$UPSTREAM_TAG" && echo "(present, package.json $(pkg_version "$UPSTREAM_TAG"))" || echo "${C_YEL}not fetched${C_OFF}")"
  say "    work branch   $WORK_BRANCH $(branch_exists "$WORK_BRANCH" && echo "${C_GRN}exists${C_OFF}" || echo "${C_DIM}not created${C_OFF}")"
  say "    release tag   $V2_TAG $(tag_exists "$V2_TAG" && echo "${C_GRN}exists${C_OFF}" || echo "${C_DIM}not created${C_OFF}")"

  # Upstream drift. The base is a TAG on purpose, but a tag that is far behind
  # upstream's main means the next /update-nanoclaw carries whatever landed in
  # between — including breaking changes. Report it rather than let it surprise.
  say ""
  say "  ${C_BLD}upstream drift${C_OFF}"
  local newest_tag ahead
  newest_tag="$(git tag --list 'v2*' --sort=-creatordate | head -1)"
  if ! ref_exists "$UPSTREAM_TAG"; then
    say "    ${C_YEL}base $UPSTREAM_TAG does not exist yet${C_OFF} (newest published v2 tag: ${newest_tag:-none})"
  elif [ -n "$newest_tag" ] && [ "$newest_tag" = "$UPSTREAM_TAG" ]; then
    say "    base $UPSTREAM_TAG is the newest v2 tag"
  elif [ -n "$newest_tag" ]; then
    say "    ${C_YEL}base $UPSTREAM_TAG is NOT the newest tag — $newest_tag is${C_OFF}"
  fi
  if ! ref_exists "$UPSTREAM_REMOTE/main"; then
    say "    ${C_DIM}$UPSTREAM_REMOTE/main not fetched — run: git fetch $UPSTREAM_REMOTE --tags${C_OFF}"
  elif ref_exists "$UPSTREAM_TAG"; then
    ahead="$(git rev-list --count "$UPSTREAM_TAG..$UPSTREAM_REMOTE/main" 2>/dev/null)"
    say "    $UPSTREAM_REMOTE/main is ${ahead:-?} commit(s) ahead of $UPSTREAM_TAG"
    if [ "${ahead:-0}" -gt 0 ] 2>/dev/null; then
      say "    ${C_DIM}unreleased breaking changes queued there are summarised in${C_OFF}"
      say "    ${C_DIM}UPDATE_FORK.md §10. Re-read it before the next update.${C_OFF}"
    fi
  fi
  say ""
  check_pending_release

  if branch_exists "$WORK_BRANCH"; then
    say ""
    say "  ${C_BLD}endpoint mechanism on $WORK_BRANCH${C_OFF}"
    if [ "$(current_branch)" = "$WORK_BRANCH" ]; then
      say "    $(detect_endpoint_flavor)"
    else
      say "    ${C_DIM}(checkout $WORK_BRANCH to detect)${C_OFF}"
    fi
  fi

  if branch_exists "$WORK_BRANCH" && ref_exists "$UPSTREAM_TAG"; then
    say ""
    say "  ${C_BLD}fork delta vs $UPSTREAM_TAG${C_OFF}"
    git diff --stat "$UPSTREAM_TAG" "$WORK_BRANCH" 2>/dev/null | tail -25 | sed 's/^/    /'
  fi

  if [ -d "$STATE_DIR/review" ]; then
    say ""
    say "  ${C_BLD}pending hand-review patches${C_OFF}  ($STATE_DIR/review)"
    ls -1 "$STATE_DIR/review" 2>/dev/null | sed 's/^/    /'
  fi
  say ""
}

# ─── phase: freeze (§3) ─────────────────────────────────────────────────

phase_freeze() {
  head1 "Phase: freeze v1  (UPDATE_FORK.md §3)"

  warn "The CDK bootstrap clones the fork's DEFAULT BRANCH HEAD with no ref pin."
  say  "     Until nanoclawRef exists in the stack AND is deployed, moving ${MAIN_BRANCH}"
  say  "     to v2 makes v1 undeployable. This phase creates the ref to pin to;"
  say  "     wiring + deploying it in ../lovelace-ai is yours."
  say ""

  run git fetch "$ORIGIN_REMOTE" --prune
  run git fetch "$UPSTREAM_REMOTE" --prune --tags

  ref_exists "$V1_COMMIT" || die "v1 commit $V1_COMMIT not found — set FORK_V2_V1_COMMIT"

  # Guard against freezing the wrong thing: the tree must actually be v1.x.
  local ver
  ver="$(pkg_version "$V1_COMMIT")"
  case "$ver" in
    1.*) ok "$V1_COMMIT is a v1 tree (package.json $ver)" ;;
    "")  die "cannot read package.json at $V1_COMMIT" ;;
    *)   die "$V1_COMMIT reports package.json $ver — refusing to tag it as v1" ;;
  esac

  if tag_exists "$V1_TAG"; then
    local at; at="$(git rev-parse --short "$V1_TAG^{commit}")"
    if [ "$at" = "$(git rev-parse --short "$V1_COMMIT")" ]; then
      skip "tag $V1_TAG already at $at"
    else
      die "tag $V1_TAG exists but points at $at, not $V1_COMMIT — resolve by hand"
    fi
  else
    run git tag -a "$V1_TAG" -m "Frozen v1 fork as deployed on EC2 (Bedrock/LiteLLM + Discord)" "$V1_COMMIT"
    did "tagged $V1_TAG"
  fi

  if branch_exists "$V1_BRANCH"; then
    skip "branch $V1_BRANCH already exists"
  else
    run git branch "$V1_BRANCH" "$V1_COMMIT"
    did "created branch $V1_BRANCH"
  fi

  if [ "$PUSH" = 1 ]; then
    if confirm "Push $V1_TAG and $V1_BRANCH to $ORIGIN_REMOTE?"; then
      run git push "$ORIGIN_REMOTE" "refs/tags/$V1_TAG"
      run git push "$ORIGIN_REMOTE" "refs/heads/$V1_BRANCH:refs/heads/$V1_BRANCH"
      did "pushed"
    else
      skip "push declined"
    fi
  else
    info "not pushing (pass --push). v1 is not safe until the tag is on $ORIGIN_REMOTE."
  fi

  say ""
  warn "NEXT, before any promote: in ../lovelace-ai add a nanoclawRef context"
  say  "     parameter, pin it to $V1_TAG, and ${C_BLD}cdk deploy${C_OFF} that change."
  say  "     Verify cdk diff shows only the UserData/clone change."
}

# ─── phase: base (§6a + §6b) ────────────────────────────────────────────

phase_base() {
  head1 "Phase: new base from $UPSTREAM_TAG  (UPDATE_FORK.md §6a, §6b)"
  require_clean

  run git fetch "$UPSTREAM_REMOTE" --prune --tags
  if ! ref_exists "$UPSTREAM_TAG"; then
    say ""
    warn "$UPSTREAM_TAG is not a tag on $UPSTREAM_REMOTE."
    check_pending_release
    say ""
    say "  Options:"
    say "    • wait for the tag, then re-run unchanged"
    say "    • base on the release branch and pin its SHA:"
    say "        ${C_BLD}--upstream-tag $UPSTREAM_REMOTE/release/<version>${C_OFF}"
    say "    • base on the previous release: ${C_BLD}--upstream-tag v2.3.0${C_OFF}"
    say "      ${C_DIM}(then expect a gateway migration right after — UPDATE_FORK.md §10)${C_OFF}"
    say ""
    # Advisory in a dry run so `all` can still preview the remaining phases,
    # consistent with require_clean / require_work_branch. Fatal under --apply.
    [ "$APPLY" = 1 ] && die "base ref $UPSTREAM_TAG not found"
    warn "continuing the dry run anyway — later phases will read the v1 tree"
  fi

  # Surface an imminent release before committing to an older base — switching
  # later means redoing this phase.
  check_pending_release
  say ""

  if ! branch_exists "$V1_BRANCH"; then
    # In a dry run the freeze phase only printed what it would do, so the branch
    # legitimately does not exist yet.
    [ "$APPLY" = 1 ] && die "$V1_BRANCH missing — run the freeze phase first"
    warn "$V1_BRANCH does not exist yet (dry run — freeze would have created it)"
  fi

  # Create or re-enter the work branch.
  if branch_exists "$WORK_BRANCH"; then
    if [ "$(current_branch)" != "$WORK_BRANCH" ]; then
      run git checkout "$WORK_BRANCH"
    fi
    if git merge-base --is-ancestor "$UPSTREAM_TAG" "$WORK_BRANCH" 2>/dev/null; then
      skip "$WORK_BRANCH already based on $UPSTREAM_TAG"
    else
      die "$WORK_BRANCH exists but is not a descendant of $UPSTREAM_TAG — delete it or pick another --upstream-tag"
    fi
  else
    run git checkout -b "$WORK_BRANCH" "$UPSTREAM_TAG"
    did "created $WORK_BRANCH at $UPSTREAM_TAG"
  fi

  # ── carry the fork assets that transfer verbatim (§4 item 6)
  head1 "Carrying fork assets forward"
  local carried=0 path
  for path in $CARRY_PATHS; do
    if [ "$APPLY" = 1 ] && [ -e "$path" ]; then
      skip "$path already present"
      continue
    fi
    if ! git cat-file -e "$V1_BRANCH:$path" 2>/dev/null && \
       ! git ls-tree -d --name-only "$V1_BRANCH" -- "$path" 2>/dev/null | grep -q .; then
      warn "$path not found on $V1_BRANCH — skipping"
      continue
    fi
    run git checkout "$V1_BRANCH" -- "$path"
    did "carried $path"
    carried=$((carried + 1))
  done
  [ "$carried" = 0 ] && info "nothing new to carry"

  # ── extract the hand-review deltas instead of applying them (§6a step 2)
  head1 "Extracting hand-review patches"
  run mkdir -p "$STATE_DIR/review"
  local reviewed=0
  for path in $REVIEW_PATHS; do
    local out="$STATE_DIR/review/$(printf '%s' "$path" | tr '/' '_').patch"
    if [ "$APPLY" = 1 ]; then
      if git diff "$V1_BRANCH" "$UPSTREAM_TAG" -- "$path" > "$out" 2>/dev/null && [ -s "$out" ]; then
        did "wrote $out"
        reviewed=$((reviewed + 1))
      else
        rm -f "$out"
        skip "$path — no difference to review"
      fi
    else
      printf '   %s[dry-run] git diff %s %s -- %s > %s%s\n' \
        "$C_DIM" "$V1_BRANCH" "$UPSTREAM_TAG" "$path" "$out" "$C_OFF"
    fi
  done
  if [ "$reviewed" -gt 0 ]; then
    warn "$reviewed patch(es) need HUMAN review — do NOT git checkout these files,"
    say  "     v2's versions differ. Read each patch and re-apply only your intent:"
    say  "       ${C_BLD}ls $STATE_DIR/review${C_OFF}"
  fi

  # ── assert the things that must NOT come along (§4 item 7)
  head1 "Asserting v1-only artifacts are absent"
  local bad=0
  for path in store groups logs; do
    if [ -L "$path" ]; then
      warn "$path is a symlink — the v1 persistence trick must not survive (§4 item 7, V2_MIGRATION.md §5)"
      bad=1
    else
      ok "$path is not a symlink"
    fi
  done
  if [ -f package-lock.json ]; then
    warn "package-lock.json present — v2 uses pnpm-lock.yaml"
    bad=1
  else
    ok "no package-lock.json"
  fi
  [ -f pnpm-lock.yaml ] && ok "pnpm-lock.yaml present" || warn "pnpm-lock.yaml missing"
  [ "$bad" = 0 ] || warn "resolve the above before trusting a build"

  # Commit BEFORE the toolchain runs. The git-side work is complete and correct
  # regardless of whether the upstream suite is green in this environment, and a
  # red suite must not leave the carried assets staged-but-uncommitted — that
  # dirty tree then blocks every later phase's require_clean.
  head1 "Commit the carried assets"
  # shellcheck disable=SC2086 -- CARRY_PATHS is a deliberate word list.
  commit_if_changed "chore: carry fork container skills and add-imaprest onto the v2 base" $CARRY_PATHS

  # ── toolchain + build + test (§6b)
  head1 "Install, build, test"
  if toolchain_enabled "install/build/test"; then
    check_node || die "fix Node before building"
    resolve_pnpm || die "pnpm unavailable"
    run_sh_try "corepack enable" || info "corepack enable non-zero — continuing if pnpm resolves"
    slow "pnpm install" "$PNPM install --frozen-lockfile" || die "pnpm install failed"
    slow "build" "$PNPM run build" \
      || die "build failed on a clean $UPSTREAM_TAG tree — fix before continuing"
    if ! slow "test suite" "$PNPM exec vitest run"; then
      say ""
      warn "The upstream test suite is RED on this base."
      say  "     Triage before porting anything — §6b exists so you can tell your"
      say  "     breakage from upstream's."
      say ""
      say  "     ${C_BLD}On a v2.3.0 base only${C_OFF} — 4 cases in"
      say  "     scripts/update/transaction.e2e.test.ts reporting \"Update state"
      say  "     contains mismatched or unsafe paths\" are upstream's bug, not yours:"
      say  "     the fixture builds under os.tmpdir() (/var/folders/… on macOS, where"
      say  "     /var is a symlink), prepareUpdate() realpaths it, the test passes the"
      say  "     raw path back, and hasSafeStatePaths() compares with path.resolve()."
      say  "     ${C_BLD}v2.4.0 fixes this${C_OFF} (realResolve + fs.realpathSync); its suite is"
      say  "     green on macOS. If you see these, you are on the older base."
      say ""
      say  "     Confirm any OTHER failure is upstream's before touching it — compare"
      say  "     against a pristine checkout:"
      say  "       ${C_DIM}git clone -b $UPSTREAM_TAG <upstream> /tmp/baseline${C_OFF}"
      say  "       ${C_DIM}cd /tmp/baseline && pnpm install --frozen-lockfile && pnpm exec vitest run${C_OFF}"
      say ""
      say  "     Once the remaining failures are accounted for, continue with"
      say  "     ${C_BLD}--skip-toolchain${C_OFF} — the carried assets are already committed."
      die "tests failed on the new base"
    fi
  fi

  did "base ready on $WORK_BRANCH"
  say ""
  info "A clean baseline here matters — it is how you tell your breakage from upstream's."

  # This script is tracked on the v1 line, so checking out an upstream tag
  # removed it from the worktree. Later phases run from the relocated copy.
  if [ ! -f scripts/fork-v2-rebase.sh ]; then
    say ""
    info "This script is not on the $UPSTREAM_TAG tree. Run later phases from:"
    say  "     ${C_BLD}bash ${FORK_V2_TMP:-<temp>}/fork-v2-rebase.sh discord --apply${C_OFF}"
    say  "     ${C_DIM}or re-add it: git checkout $V1_BRANCH -- scripts/fork-v2-rebase.sh${C_OFF}"
  fi
}

# ─── phase: discord (§6c) ───────────────────────────────────────────────

phase_discord() {
  head1 "Phase: Discord adapter from the channels branch  (UPDATE_FORK.md §6c)"

  require_work_branch

  local skill=".claude/skills/add-discord"
  [ -d "$skill" ] || die "$skill missing — is this really a v2 checkout?"

  # Why not just run the skill engine: `scripts/skill-apply.ts` invoked as a CLI
  # is PLAN-ONLY (it never writes), and `setup/lib/skill-driver.ts` applies the
  # WHOLE document — which for add-discord includes `nc:prompt bot_token`,
  # `nc:operator` browser steps, `nc:env-set`, `effect:restart` and the agent
  # wire. Those are instance-side (V2_MIGRATION.md §7/§8), not part of a local
  # rebase. So apply only the code-carrying steps 1-4, verbatim from SKILL.md.
  info "applying only SKILL.md steps 1-4 (copy, register, dep, build+test)"
  info "credentials, restart and wiring stay instance-side — see V2_MIGRATION.md §7"
  say ""

  # Step 0: resolve the remote that actually carries `channels`. Upstream ships
  # a fork-aware resolver for exactly this; prefer it over hardcoding a remote.
  local remote=""
  if [ -f setup/lib/channels-remote.sh ]; then
    remote="$(bash -c 'source setup/lib/channels-remote.sh; resolve_channels_remote' 2>/dev/null)"
  fi
  [ -n "$remote" ] && ok "channels remote resolved: $remote" || {
    remote="$UPSTREAM_REMOTE"
    warn "resolver unavailable — falling back to $remote"
  }

  # Fatal if the branch isn't there: a missing `channels` ref means every copy
  # below silently produces an empty file.
  run git fetch "$remote" channels
  if [ "$APPLY" = 1 ]; then
    git rev-parse --verify --quiet "$remote/channels" >/dev/null \
      || die "$remote has no 'channels' branch — the adapter cannot be copied.
     Set NANOCLAW_CHANNELS_REMOTE=<remote> to a remote that carries it, or add one:
       git remote add upstream https://github.com/nanocoai/nanoclaw.git"
  fi

  # Step 1: copy the adapter and its registration test (overwrite — the branch
  # is canonical, per the skill).
  local f
  for f in src/channels/discord.ts src/channels/discord-registration.test.ts; do
    run_sh "git show '$remote/channels:$f' > '$f'"
    assert_nonempty "$f"
    did "copied $f"
  done

  # Step 2: register the adapter in the barrel (idempotent).
  local barrel="src/channels/index.ts" line="import './discord.js';"
  if [ -f "$barrel" ] && grep -qF "$line" "$barrel"; then
    skip "barrel already imports ./discord.js"
  else
    run_sh "printf '%s\n' \"$line\" >> '$barrel'"
    did "appended $line to $barrel"
  fi

  # Step 3: install the pinned adapter package. Read the pin out of the skill
  # rather than hardcoding it, so it cannot drift from upstream's supply-chain
  # policy (which rejects ranges and `latest`).
  local dep
  dep="$(awk '/^```nc:dep$/{f=1;next} f&&/^```/{exit} f&&NF{print $0;exit}' "$skill/SKILL.md" | tr -d '[:space:]')"
  if [ -z "$dep" ]; then
    # Under --apply we are on the v2 tree and the pin must be there. In a dry run
    # `base` has not checked v2 out yet, so we are still reading the v1 skill,
    # which has no nc:dep block.
    [ "$APPLY" = 1 ] && die "could not parse the nc:dep pin from $skill/SKILL.md"
    warn "no nc:dep pin in the current $skill/SKILL.md (dry run — this is the v1 copy)"
    dep="<pin-from-v2-skill>"
  else
    case "$dep" in
      *@[0-9]*) ok "pinned dependency from SKILL.md: $dep" ;;
      *) die "parsed dep '$dep' is not an exact pin — refusing" ;;
    esac
  fi
  if toolchain_enabled "pnpm add + build + registration test"; then
    resolve_pnpm || die "pnpm unavailable"
    slow "pnpm add $dep" "$PNPM add '$dep'" || die "could not install $dep"
    slow "build" "$PNPM run build" || die "build failed after installing the adapter"
    # The skill's own gate: this test imports the real barrel and asserts the
    # registry contains `discord`, so it also covers the dependency install.
    slow "registration test" "$PNPM exec vitest run src/channels/discord-registration.test.ts" \
      || die "discord-registration.test.ts failed — the adapter is not registered"
  fi

  head1 "Commit the adapter install"
  commit_if_changed "feat(discord): install the v2 adapter from the channels branch ($dep)" \
    src/channels/discord.ts \
    src/channels/discord-registration.test.ts \
    src/channels/index.ts \
    package.json \
    pnpm-lock.yaml

  did "Discord adapter installed"
  say ""
  warn "Fork Discord features NOT carried over (UPDATE_FORK.md §4):"
  say  "     • thread routing        → native in the Chat SDK bridge, nothing to do"
  say  "     • intents / Partials    → owned by @chat-adapter/discord, nothing to do"
  say  "     • EMOJI_REACTIONS + MessageReactionAdd approvals → ${C_BLD}decide (§6e)${C_OFF}"
  say  "       re-implement on the v2 approval seam (guard() + pending_approvals),"
  say  "       or drop it. Do not port the v1 handler."
}

# ─── phase: endpoint (§6d) ──────────────────────────────────────────────

phase_endpoint() {
  head1 "Phase: Bedrock/LiteLLM endpoint  (UPDATE_FORK.md §5, §6d)"

  require_work_branch

  local flavor; flavor="$(detect_endpoint_flavor)"
  local -a commit_paths=()

  case "$flavor" in
    providers-claude)
      ok "base uses the ${C_BLD}providers-claude${C_OFF} mechanism (v2.3.0 and earlier)"
      info "src/providers/claude.ts contributes ANTHROPIC_BASE_URL + ANTHROPIC_AUTH_TOKEN=placeholder"
      local index="src/providers/index.ts" line="import './claude.js';"
      if [ -f "$index" ] && grep -qF "$line" "$index"; then
        skip "$index already imports ./claude.js"
      else
        run_sh "printf '%s\n' \"$line\" >> '$index'"
        did "appended $line to $index"
      fi
      commit_paths=(src/providers/index.ts)
      ;;

    gateway-skill)
      ok "base uses the ${C_BLD}gateway-skill${C_OFF} mechanism (post-v2.3.0 main)"
      say ""
      warn "This base ships only the gateway CONTRACT. src/providers/claude.ts and"
      say  "     src/gateway-providers/onecli.ts are gone from core, and the host fails"
      say  "     closed with \"No gateway provider is registered in this build\"."
      say ""
      say  "     ANTHROPIC_BASE_URL now reaches the container through the GATEWAY:"
      say  "     the /add-onecli payload's withProviderEnv() sets it alongside"
      say  "     ANTHROPIC_AUTH_TOKEN=gateway-managed. There is no provider import to"
      say  "     append — so the fork carries ${C_BLD}zero core lines${C_OFF} for the endpoint."
      say ""
      say  "     Apply the gateway skill (it copies the adapter, appends one import to"
      say  "     src/gateway-providers/installed.ts, pins @onecli-sh/sdk, then builds"
      say  "     and tests). Its setup step reaches a live gateway, so run it on the"
      say  "     instance, not here:"
      say  "       ${C_BLD}pnpm exec tsx setup/lib/skill-driver.ts .claude/skills/add-onecli${C_OFF}"
      say ""
      say  "     Then record the selection in .env:"
      say  "       ${C_BLD}NANOCLAW_GATEWAY_PROVIDER=onecli${C_OFF}"
      say  "     Setting that variable alone does NOT install the implementation."
      say ""
      info "Full procedure: docs/gateway-seam.md § Migrating an existing installation"
      ;;

    *)
      [ "$APPLY" = 1 ] && die "cannot tell which endpoint mechanism this base uses —
     neither src/providers/claude.ts nor .claude/skills/add-onecli is present.
     Check UPDATE_FORK.md §5 against the upstream tree before continuing."
      warn "endpoint mechanism undetectable (dry run — the v2 base is not checked out yet)"
      ;;
  esac

  # .env is gitignored, so this only helps a local run — the instance gets its
  # .env from bootstrap. Write the base URL but NEVER a token: a real credential
  # value in .env risks tripping the driver's credential-in-env admission check.
  if [ -f .env ] && grep -q '^ANTHROPIC_BASE_URL=' .env 2>/dev/null; then
    skip ".env already sets ANTHROPIC_BASE_URL"
  else
    run_sh "printf 'ANTHROPIC_BASE_URL=%s\n' '$ANTHROPIC_BASE_URL_DEFAULT' >> .env"
    did "set ANTHROPIC_BASE_URL=$ANTHROPIC_BASE_URL_DEFAULT in .env (local only; .env is gitignored)"
  fi

  # Pin the model. Upstream moved the unset-model default to Opus 5.5 after
  # v2.3.0, and our LiteLLM registers exactly one model name — an unpinned group
  # asks for a model the proxy does not serve and the turn 400s.
  if [ -f .env ] && grep -q '^NANOCLAW_DEFAULT_MODEL=' .env 2>/dev/null; then
    skip ".env already sets NANOCLAW_DEFAULT_MODEL"
  else
    run_sh "printf 'NANOCLAW_DEFAULT_MODEL=%s\n' '$DEFAULT_MODEL' >> .env"
    did "set NANOCLAW_DEFAULT_MODEL=$DEFAULT_MODEL in .env"
    info "must match a model_name in LiteLLM's config.yaml AND the Bedrock IAM policy"
  fi

  if [ -f .env ] && grep -q '^ANTHROPIC_AUTH_TOKEN=' .env 2>/dev/null; then
    warn "ANTHROPIC_AUTH_TOKEN is set in .env — remove it."
    say  "     The provider (v2.3.0) or the gateway (later) supplies the placeholder"
    say  "     itself, and a real value here can trip the driver's credential-in-env"
    say  "     admission rules."
  fi
  if [ -f .env ] && grep -qE '^NANOCLAW_FAST_MODE=(1|true)' .env 2>/dev/null; then
    warn "NANOCLAW_FAST_MODE is on — it bills every agent at the fast serving tier."
  fi

  # Confirm the v1 patch is gone rather than assuming it.
  if grep -q 'ANTHROPIC_BASE_URL' src/container-runner.ts 2>/dev/null; then
    warn "src/container-runner.ts still references ANTHROPIC_BASE_URL —"
    say  "     the v1 patch must not be ported (§4 item 4). Remove it."
  else
    ok "src/container-runner.ts carries no v1 LiteLLM patch"
  fi

  if [ ${#commit_paths[@]} -gt 0 ]; then
    head1 "Commit the provider registration"
    commit_if_changed "feat(providers): register the custom Anthropic endpoint (LiteLLM/Bedrock)" \
      "${commit_paths[@]}"
  else
    info "nothing to commit — on this base the endpoint is pure .env + gateway skill"
  fi

  say ""
  info "Instance-side remainder (V2_MIGRATION.md §7 Phase 5), needs a live gateway:"
  if [ "$flavor" = "gateway-skill" ]; then
    say  "     pnpm exec tsx setup/index.ts --step gateway"
    say  "     NANOCLAW_ANTHROPIC_BASE_URL=$ANTHROPIC_BASE_URL_DEFAULT \\"
    say  "     NANOCLAW_ANTHROPIC_AUTH_TOKEN=<litellm-key> \\"
    say  "     pnpm exec tsx setup/index.ts --step gateway-auth"
  else
    say  "     NANOCLAW_ANTHROPIC_BASE_URL=$ANTHROPIC_BASE_URL_DEFAULT \\"
    say  "     NANOCLAW_ANTHROPIC_AUTH_TOKEN=<litellm-key> \\"
    say  "     pnpm exec tsx setup/index.ts --step auth"
    say  "     ${C_DIM}(the 'onecli' and 'auth' steps become 'gateway' and 'gateway-auth'${C_OFF}"
    say  "     ${C_DIM} in the release after v2.3.0 — check before copy-pasting)${C_OFF}"
  fi
  say ""
  warn "Two unresolved questions gate this (V2_MIGRATION.md §9 items 1-3):"
  say  "     • does the gateway report applied/ready with NO Anthropic secret?"
  say  "       if not, every spawn throws and a LiteLLM master key is mandatory"
  say  "     • does the gateway proxy intercept plain-HTTP host.docker.internal:4000?"
  say  "     Answer both on a scratch instance, not in the migration window."
  say ""
  warn "Leave NANOCLAW_EGRESS_LOCKDOWN unset: it aliases host.docker.internal to"
  say  "     the gateway container, which makes host-local LiteLLM unreachable (§5.3b)."
}

# ─── phase: verify (§6g + §6h) ──────────────────────────────────────────

phase_verify() {
  head1 "Phase: verify  (UPDATE_FORK.md §6g, §6h)"

  if [ "$APPLY" = 0 ]; then
    warn "Dry run: the assertions below are evaluated against the CURRENT tree,"
    say  "     which is still v1 — so they will fail and the delta will show the whole"
    say  "     v1→v2 difference. Only ${C_BLD}--apply${C_OFF} produces a real verdict."
    say ""
  fi

  require_work_branch
  resolve_pnpm || die "pnpm unavailable"

  # Cheap filesystem assertions first: they need no node_modules, and they are
  # the part worth seeing even when the expensive steps below can't run.

  # ── the deletions that must have happened
  head1 "Obsolete v1 surfaces must be absent"
  local failures=0 entry file why
  while IFS='|' read -r file why; do
    [ -n "$file" ] || continue
    if [ -e "$file" ]; then
      warn "$file still present — $why"
      failures=$((failures + 1))
    else
      ok "$file absent  ${C_DIM}($why)${C_OFF}"
    fi
  done <<EOF
$(declare_obsolete)
EOF

  if grep -q "|| 'Ada'" src/config.ts 2>/dev/null; then
    warn "src/config.ts hardcodes 'Ada' — use ASSISTANT_NAME in .env instead (§4 item 5)"
    failures=$((failures + 1))
  else
    ok "src/config.ts carries no hardcoded assistant name"
  fi

  # ── the additions that must have happened
  head1 "Required v2 surfaces must be present"
  local required="
src/channels/discord.ts|Discord adapter from the channels branch (§6c)
container/skills/wiki|carried fork skill (§4 item 6)
container/skills/use-imaprest-rest|carried fork skill (§4 item 6)
.claude/skills/add-imaprest|carried fork skill (§4 item 6)
"
  while IFS='|' read -r file why; do
    [ -n "$file" ] || continue
    if [ -e "$file" ]; then
      ok "$file present  ${C_DIM}($why)${C_OFF}"
    else
      warn "$file MISSING — $why"
      failures=$((failures + 1))
    fi
  done <<EOF
$required
EOF

  grep -qF "import './discord.js';" src/channels/index.ts 2>/dev/null \
    && ok "channel barrel registers discord" \
    || { warn "src/channels/index.ts does not import ./discord.js"; failures=$((failures+1)); }

  # The endpoint assertion depends on which mechanism the base ships (§6d).
  local flavor; flavor="$(detect_endpoint_flavor)"
  case "$flavor" in
    providers-claude)
      if grep -qF "import './claude.js';" src/providers/index.ts 2>/dev/null; then
        ok "provider barrel registers claude  ${C_DIM}(providers-claude base)${C_OFF}"
      else
        warn "src/providers/index.ts does not import ./claude.js"
        failures=$((failures + 1))
      fi
      ;;
    gateway-skill)
      # Core carries only the contract here; the adapter arrives via /add-onecli
      # and is applied on the instance, so its absence locally is expected.
      if grep -qF "import './onecli.js';" src/gateway-providers/installed.ts 2>/dev/null; then
        ok "gateway barrel registers onecli  ${C_DIM}(gateway-skill base)${C_OFF}"
      else
        warn "no gateway registered in src/gateway-providers/installed.ts yet"
        say  "     Expected if /add-onecli has not been applied. The host WILL refuse to"
        say  "     start until it is: \"No gateway provider is registered in this build\"."
        say  "     Apply it on the instance, then re-verify there."
      fi
      ;;
    *)
      warn "endpoint mechanism undetectable — cannot assert the endpoint wiring"
      failures=$((failures + 1))
      ;;
  esac

  # ── upstream's own customization detector (needs node_modules)
  head1 "Driver-seam detector"
  if ! toolchain_enabled "driver-seam detector"; then
    :
  elif [ ! -f scripts/detect-driver-migration.ts ]; then
    warn "scripts/detect-driver-migration.ts not found in this checkout"
  else
    # Diagnostic, not a gate: report a crash and keep going so the build/test
    # result below is still produced.
    if command -v bun >/dev/null 2>&1; then
      run_sh_try "bun scripts/detect-driver-migration.ts" \
        || { warn "detector did not run cleanly — run it by hand"; failures=$((failures + 1)); }
    else
      info "bun missing — running via tsx"
      run_sh_try "$PNPM exec tsx scripts/detect-driver-migration.ts" \
        || { warn "detector did not run cleanly — run it by hand"; failures=$((failures + 1)); }
    fi
    info "empty output above means nothing left to fix"
  fi

  # ── build + full test suite
  head1 "Build and test"
  if toolchain_enabled "build/test"; then
    slow "build" "$PNPM run build" || { warn "build FAILED"; failures=$((failures + 1)); }
    # NANOCLAW_CHANNELS_REMOTE is a discord-phase override, but the suite
    # asserts on remote resolution — leaving it set makes
    # setup/channels/slack-auto.test.ts fail for the wrong reason.
    if [ -n "${NANOCLAW_CHANNELS_REMOTE:-}" ]; then
      info "unsetting NANOCLAW_CHANNELS_REMOTE for the test run (it skews remote-resolution tests)"
    fi
    if ! slow "test suite" "unset NANOCLAW_CHANNELS_REMOTE; $PNPM exec vitest run"; then
      warn "tests FAILED"
      say  "     ${C_DIM}On a v2.3.0 base, 4 failures in scripts/update/transaction.e2e.test.ts"
      say  "     are upstream's own macOS path-comparison bug, fixed in v2.4.0. On a"
      say  "     v2.4.0 base the suite is expected GREEN, so treat any failure here as"
      say  "     real and triage it before porting anything further.${C_OFF}"
      failures=$((failures + 1))
    fi
  else
    warn "build/test skipped — this verify result is NOT trustworthy"
    failures=$((failures + 1))
  fi

  # ── the final delta, which is the real deliverable of the rebase
  head1 "Fork delta vs $UPSTREAM_TAG"
  git diff --stat "$UPSTREAM_TAG" HEAD | sed 's/^/   /'
  say ""
  info "Target steady state: .env-level config, one provider import line, and our"
  info "own skills. Anything in core here is future merge pain (§8)."

  if [ "$failures" -gt 0 ]; then
    say ""
    die "$failures assertion(s) failed — do not promote"
  fi
  ok "verify passed"

  if [ "$PUSH" = 1 ]; then
    if confirm "Push $WORK_BRANCH to $ORIGIN_REMOTE?"; then
      run git push -u "$ORIGIN_REMOTE" "$WORK_BRANCH"
    else
      skip "push declined"
    fi
  else
    info "not pushing (pass --push)"
  fi
}

# ─── phase: promote (§6h) ───────────────────────────────────────────────

phase_promote() {
  head1 "Phase: promote $WORK_BRANCH to $MAIN_BRANCH  (UPDATE_FORK.md §6h)"

  if [ "$IAC_PINNED" != 1 ]; then
    say "This phase makes v2 the default branch. The CDK bootstrap clones the"
    say "default branch HEAD, so the moment this lands, every fresh deploy is v2."
    say ""
    say "Required first, per UPDATE_FORK.md §3:"
    say "  1. $V1_TAG pushed to $ORIGIN_REMOTE"
    say "  2. nanoclawRef context parameter added to ../lovelace-ai"
    say "  3. pinned to $V1_TAG and ${C_BLD}cdk deploy${C_OFF}ed — not just committed"
    say ""
    say "Also required, per V2_MIGRATION.md §7: the migration verified on a real"
    say "instance. Promoting before that leaves you with no tested rollback."
    say ""
    die "re-run with --i-have-pinned-the-iac once all of the above is true"
  fi

  require_clean
  branch_exists "$WORK_BRANCH" || die "$WORK_BRANCH missing"
  branch_exists "$MAIN_BRANCH" || die "$MAIN_BRANCH missing"
  tag_exists "$V1_TAG" || die "$V1_TAG missing — run freeze first"

  # Join the histories from the v2 side: `-s ours` keeps v2's tree and records
  # main as a second parent, so the follow-up on main is a genuine fast-forward
  # and needs no index surgery.
  run git checkout "$WORK_BRANCH"
  if git merge-base --is-ancestor "$MAIN_BRANCH" "$WORK_BRANCH" 2>/dev/null; then
    skip "$MAIN_BRANCH already an ancestor of $WORK_BRANCH"
  else
    run git merge -s ours "$MAIN_BRANCH" \
      -m "feat!: adopt upstream nanoclaw $UPSTREAM_TAG as the new fork base"
    did "recorded $MAIN_BRANCH as a second parent, kept v2's tree"
  fi

  # Prove the tree really is v2's before touching main.
  if [ "$APPLY" = 1 ]; then
    head1 "Sanity: tree must still be v2 plus only our delta"
    git log --oneline --graph -3 | sed 's/^/   /'
    say ""
    git diff --stat "$UPSTREAM_TAG" HEAD | sed 's/^/   /'
    say ""
    confirm "Does that delta look like ONLY your intended customizations?" \
      || die "aborted at the sanity gate"
  fi

  run git checkout "$MAIN_BRANCH"
  run git merge --ff-only "$WORK_BRANCH"
  did "$MAIN_BRANCH fast-forwarded to $WORK_BRANCH"

  if tag_exists "$V2_TAG"; then
    skip "tag $V2_TAG already exists"
  else
    run git tag -a "$V2_TAG" -m "First v2 fork release" "$WORK_BRANCH"
    did "tagged $V2_TAG"
  fi

  if [ "$PUSH" = 1 ]; then
    if confirm "Push $MAIN_BRANCH and $V2_TAG to $ORIGIN_REMOTE?"; then
      run git push "$ORIGIN_REMOTE" "$MAIN_BRANCH"
      run git push "$ORIGIN_REMOTE" "refs/tags/$V2_TAG"
      did "pushed"
    else
      skip "push declined"
    fi
  else
    info "not pushing (pass --push)"
  fi

  say ""
  head1 "Remaining, instance-side"
  say "  • V2_MIGRATION.md §7  — the EC2 migration runbook"
  say "  • ncl groups config add-mcp-server …   re-register MCP servers (§4 item 3)"
  say "  • scripts/upgrade-state.ts set          stamp the boot tripwire (§8)"
  say "  • /update-nanoclaw                      use this for all future updates"
}

# ─── dispatch ───────────────────────────────────────────────────────────

if [ "$APPLY" = 0 ] && [ "$PHASE" != "status" ] && [ "$PHASE" != "preflight" ]; then
  warn "DRY RUN — nothing will change. Add --apply to execute."
fi

case "$PHASE" in
  status)    phase_status ;;
  preflight) phase_preflight ;;
  freeze)    phase_freeze ;;
  base)      phase_base ;;
  discord)   phase_discord ;;
  endpoint)  phase_endpoint ;;
  verify)    phase_verify ;;
  promote)   phase_promote ;;
  all)
    phase_preflight
    phase_freeze
    phase_base
    phase_discord
    phase_endpoint
    phase_verify
    say ""
    head1 "Done — stopped before promote, deliberately"
    say "  promote is gated on: the IaC nanoclawRef pin being DEPLOYED, and the"
    say "  migration verified on a real instance (V2_MIGRATION.md §7)."
    say ""
    say "  Then: ${C_BLD}scripts/fork-v2-rebase.sh promote --apply --push --i-have-pinned-the-iac${C_OFF}"
    ;;
  *) die "unhandled phase: $PHASE" ;;
esac
