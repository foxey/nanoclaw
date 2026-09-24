# UPDATE_FORK.md — bringing `foxey/nanoclaw` from v1 to upstream v2.3.0

Companion document: [V2_MIGRATION.md](V2_MIGRATION.md) covers the infrastructure
side (CDK in `../lovelace-ai`). This document covers only the Git repository.

---

> **Revised 2026-09-23.** Upstream prepared **v2.4.0** on 2026-09-23. It moves the
> credential gateway out of core and into a skill, which changes §5 and §6d
> materially. **Base on `v2.4.0`, not `v2.3.0`** — see
> [§10](#10-upstream-changes-since-v230) for what moved and why.
>
> As of this revision the release content is on `upstream/release/v2.4.0`
> (`package.json` 2.4.0, `CHANGELOG` entry dated 2026-09-23) but **the `v2.4.0`
> tag has not landed yet** — `v2.3.0` is still the newest published tag. The
> script refuses to base on a missing tag and offers the release branch or
> `v2.3.0` instead; `scripts/fork-v2-rebase.sh status` tells you which state
> you are in. Every `v2.3.0` instruction below still works on a `v2.3.0` base;
> the ones that differ are marked.

## 1. Where the fork actually stands

Verified against this checkout and `../nanocoai-nanoclaw` on 2026-09-08,
re-verified 2026-09-23:

| Fact | Value |
|---|---|
| Fork `main` HEAD | `1ac21d23` |
| `package.json` version | `1.2.52` |
| Merge base with `upstream/main` | `934f063a` ("update deps", 2026-04-07) |
| Commits on `main` after the merge base (our work) | 83 |
| Commits in `v2.3.0` not in `main` | 1931 |
| Commits in `upstream/main` not in `main` | 2063 |
| Newest published upstream tag | `v2.3.0` (`54d9d9a5`, 2026-08-24) |
| **Prepared release (recommended base)** | **`v2.4.0` — `upstream/release/v2.4.0` @ `5e6a1d38`, 2026-09-23, not yet tagged** |
| Commits in `release/v2.4.0` not in `v2.3.0` | 233 (contains all of `upstream/main` plus 8) |
| Remotes | `origin` = `foxey/nanoclaw`, `upstream` = `nanocoai/nanoclaw` |
| Working tree | clean |

Files that diverge from the merge base, excluding `repo-tokens/`:

```
 .env.example                                |    1 +
 .github/workflows/bump-version.yml          |   33 -      (deleted)
 .github/workflows/update-tokens.yml         |   43 -      (deleted)
 .gitignore                                  |    1 +
 .husky/pre-commit                           |    1 +
 container/agent-runner/src/index.ts         |  125 +      mcpServers merge
 container/skills/use-imaprest-rest/SKILL.md |  183 +
 container/skills/wiki/SKILL.md              |   86 +
 groups                                      |    1 +      symlink -> /data/nanoclaw/groups
 groups/global/CLAUDE.md                     |  115 -      (deleted, replaced by symlink)
 groups/main/CLAUDE.md                       |  309 -      (deleted, replaced by symlink)
 logs                                        |    1 +      symlink -> /data/nanoclaw/logs
 store                                       |    1 +      symlink -> /data/nanoclaw/store
 package-lock.json                           |  296 +
 package.json                                |    3 +-
 src/channels/discord.ts                     |  521 +
 src/channels/discord.test.ts                | 1125 +
 src/channels/index.ts                       |    1 +
 src/config.ts                               |    2 +-     Andy -> Ada
 src/container-runner.ts                     |   29 +-     LiteLLM env + auth fallback
 src/container-runner.test.ts                |    2 +-
 src/db.test.ts                              |   52 +-
 src/index.ts                                |   95 +-     session commands + mcp merge
 src/session-commands.ts                     |  163 +      /compact
 src/session-commands.test.ts                |  247 +
 .claude/skills/add-imaprest/SKILL.md        |  163 +
```

That is a small, well-scoped divergence — about 8 real features. The problem is
not the size of our delta, it is that v2 rewrote every seam those features touch.

---

## 2. Why a plain merge is the wrong tool

v2 is not v1 plus commits. Concretely, from upstream's own
`docs/v1-to-v2-changes.md` and `CHANGELOG.md`:

- **Package manager changed.** `package-lock.json` → `pnpm-lock.yaml` +
  `pnpm-workspace.yaml`, `packageManager: pnpm@10.34.5`. Our 296-line
  `package-lock.json` delta has no merge target.
- **Node 22 is now a hard floor** (`engines.node >= 22`, `better-sqlite3`).
- **Channels left trunk.** `src/channels/discord.ts` does not exist on
  `upstream/main` at all. It lives on the long-lived `origin/channels` branch,
  is 3958 bytes instead of our 521 lines, and is a thin wrapper over
  `@chat-adapter/discord@4.29.0` through `createChatSdkBridge(...)`. Our
  `discord.ts` + 1125-line test have no counterpart to merge into.
- **The container seam moved behind a driver.** `hostGatewayArgs`,
  `buildContainerArgs`, `stopContainer` moved into `src/drivers/`. Our
  `container-runner.ts` patch targets symbols that no longer exist there, and
  the new spec validator *refuses credential values in container env by design*.
  Upstream retired the `use-native-credential-proxy` skill for the same reason.
- **State layout changed.** One `store/messages.db` became `data/v2.db` plus
  `data/v2-sessions/<id>/{inbound,outbound}.db`. `registered_groups` became
  `agent_groups` + `messaging_groups` + `messaging_group_agents`.
- **Committed symlinks.** We committed `groups`, `logs`, `store` as symlinks to
  `/data/nanoclaw/*` and deleted the tracked `groups/*/CLAUDE.md`. Upstream v2
  ships `groups/` as a real directory with a different internal shape
  (`instructions.prepend.md`, `memory/`, `container.json`). Git will report a
  file/symlink type conflict on all three paths, and v2's own
  `setup/migrate-v2/groups.ts` explicitly *skips* symlinks when copying.

A 1931-commit ort merge across those seams produces a conflict set that is
larger than rewriting our 8 features, and — worse — parts will auto-merge
cleanly while being semantically wrong. Upstream warns about exactly this in
`docs/BRANCH-FORK-MAINTENANCE.md`: *"auto-merged code can be silently wrong …
always build and test after every forward merge."*

**Recommended strategy: adopt upstream v2.3.0 as the new base and re-apply our
customizations on top, using the v2 mechanisms.** Keep v1 reachable as a frozen,
installable ref. Details below.

---

## 3. Step 1 — freeze v1 so it stays installable

Do this **before** anything else, and treat it as the hard prerequisite.

> **Why it is urgent:** `../lovelace-ai/bootstrap/50-install-nanoclaw.sh` clones
> the fork with **no `--branch` and no ref pinning** — it takes the default
> branch HEAD:
>
> ```bash
> sudo -u ec2-user git clone "${NANOCLAW_REPO:-git@github.com:foxey/nanoclaw.git}" /opt/nanoclaw
> ```
>
> The moment `main` moves to v2, every fresh `cdk deploy` installs v2. There is
> currently no way to deploy v1 again. Freeze first, add a ref parameter to the
> IaC second (see V2_MIGRATION.md §6), then move `main`.

```bash
cd /Users/michielf/Projects/lovelace-agent/nanoclaw
git fetch origin --prune
git fetch upstream --prune --tags

# Immutable tag on the deployed v1 tree.
git tag -a v1.2.52-lovelace -m "Frozen v1 fork as deployed on EC2 (Bedrock/LiteLLM + Discord)" <commit>
git push origin v1.2.52-lovelace

# Long-lived maintenance branch, so security fixes to v1 remain possible.
git branch v1-maintenance <commit>
git push -u origin v1-maintenance
```

> **As executed (2026-09-23):** `<commit>` is **`f3050ba5`**, not the deployed
> `1ac21d23`. `f3050ba5` is `1ac21d23` plus this plan and its script — three files,
> `+3010` lines, all documentation:
>
> ```
> UPDATE_FORK.md  V2_MIGRATION.md  scripts/fork-v2-rebase.sh
> ```
>
> `git diff --name-only 1ac21d23 v1.2.52-lovelace -- src/ container/ setup/
> package.json package-lock.json .env.example` is **empty**, so the frozen tree is
> runtime-identical to what is deployed — `npm install && npm run build` and the
> container build are unaffected.
>
> Why include them: `base` carries assets from `v1-maintenance`, and `promote`
> replaces `main`'s tree wholesale. Anything not reachable from the frozen branch
> is silently dropped from `main` at promote — including this document. Freezing
> the plan alongside the code it describes also makes the rollback ref
> self-documenting. If you need a tag that is byte-identical to the deployment,
> `1ac21d23` is still there and still reachable.

Then in `../lovelace-ai`, add a `nanoclawRef` context parameter and pin the
current stack to `v1.2.52-lovelace` **and deploy that change**, verifying a
`cdk diff` shows only the UserData/clone change. Only after that is live should
`main` move.

Optional but cheap: protect `v1-maintenance` on GitHub against force-push.

---

## 4. Step 2 — decide what each customization becomes in v2

Go through this table before writing any code. Four of the eight items simply
disappear, which is most of the work gone.

| # | Fork customization | v2 disposition | Mechanism |
|---|---|---|---|
| 1 | `src/channels/discord.ts` (+ test) — Discord adapter | **Replace.** Do not port. | `/add-discord` skill fetches the adapter from `origin/channels` and pins `@chat-adapter/discord@4.29.0`. |
| 1a | Thread routing (reply in the originating thread, route thread → parent channel group) | **Native.** | Chat SDK bridge has first-class thread ids and per-thread sessions; wirings carry a thread policy. `normalizeDmThreadId` in `chat-sdk-bridge.ts`. |
| 1b | `EMOJI_REACTIONS` approval map + `MessageReactionAdd` handler | **Re-implement on the new seam** if still wanted. | v2 has a generic approval flow (`pending_approvals`, approval cards, `guard()`) and the bridge already emits `operation === 'reaction'`. Emoji-as-approval is a small adapter-level addition on top, not a core patch. |
| 1c | `DirectMessageReactions` / `Partials` intents | **Gone.** Adapter-owned. | `@chat-adapter/discord` sets its own intents. |
| 2 | `src/session-commands.ts` — `/compact` (+ 247-line test) | **Delete.** | Runner-handled natively: *"Slash commands interrupt an in-flight turn. Runner-handled commands such as `/clear`, `/compact`, and `/cost`"* (CHANGELOG 2.1.17). |
| 3 | `container/agent-runner/src/index.ts` — merge `mcpServers` from `settings.json`, and the matching part of `src/index.ts` | **Delete, migrate the data.** | MCP servers live in the `container_configs` table since 2.0.48. Re-add each server with `ncl groups config add-mcp-server --name … [--url …]`. |
| 4 | `src/container-runner.ts` — pass `ANTHROPIC_BASE_URL`, `NO_PROXY`, and fall back to `ANTHROPIC_AUTH_TOKEN` as `ANTHROPIC_API_KEY` | **Delete. Use the supported path.** | See §5 — this is the single most important item. On a **v2.4.0** base the replacement is pure `.env` + the `/add-onecli` skill, so the fork keeps **zero core lines** here. |
| 4a | *(new)* model selection | **Pin it in `.env`.** | v2.4.0 moves the unset-model default to **Opus 5.5**. Our LiteLLM registers exactly one model name, so an unpinned group asks for a model the proxy does not serve. Set `NANOCLAW_DEFAULT_MODEL`. See §5.2. |
| 5 | `src/config.ts` — default `ASSISTANT_NAME` `Andy` → `Ada` | **Delete the patch.** | `ASSISTANT_NAME=Ada` in `.env`; already set by the IaC. Do not re-patch source. |
| 6 | `container/skills/wiki/`, `container/skills/use-imaprest-rest/`, `.claude/skills/add-imaprest/` | **Carry forward as-is, then conform.** | Plain `cp -r`. Then align each `SKILL.md` to the v2 contract (`nc:` directives — see `docs/skill-directives.md`) so `scripts/skill-apply.ts` can apply them deterministically and re-application on future updates works. |
| 7 | Committed `groups`/`logs`/`store` symlinks, deleted `groups/*/CLAUDE.md` | **Do not carry forward.** | Bind-mount or move the whole checkout onto the data volume instead. See V2_MIGRATION.md §5. `data/` must also be persistent in v2 — it holds `v2.db` and all session DBs. |
| 8 | Deleted `.github/workflows/{bump-version,update-tokens}.yml`, `.husky/pre-commit` tweak, `.gitignore`, `.env.example` | **Re-apply by hand after the reset.** Trivial, but easy to forget. | |

### 4.1 Also inventory the live install, not just the repo

Two things live only on the instance and are invisible in this diff:

- `~/.config/nanoclaw/mount-allowlist.json` and `sender-allowlist.json` — outside
  `PROJECT_ROOT` by design, on the **ephemeral root volume**. Copy them off the
  instance before you touch anything.
- `groups/*/CLAUDE.md` on `/data/nanoclaw/groups` — the actual agent memory. The
  repo no longer tracks these; the volume is the only copy.

---

## 5. Step 3 — the Bedrock/LiteLLM path in v2

This deserves its own section because it is where our fork is most likely to
break silently.

**What we do today.** LiteLLM runs unauthenticated on `0.0.0.0:4000` (iptables
restricted to `127.0.0.1` + `172.17.0.0/16`), fronting Bedrock with the EC2
instance profile. `.env` carries `ANTHROPIC_BASE_URL=http://host.docker.internal:4000`
and `ANTHROPIC_AUTH_TOKEN=dummy`. Our `container-runner.ts` patch pushes both
into the container and, when OneCLI is unreachable, injects `dummy` as
`ANTHROPIC_API_KEY`.

**Why that stops working in v2:**

1. `src/drivers/` admission rules reject credential values in container env on
   every lane. The only tolerated form is the literal placeholder — see the
   comment at `src/drivers/types.ts:485`.
2. The gateway **fails closed**. On a v2.3.0 base that is
   `src/gateway-providers/onecli.ts`:
   ```ts
   if (!applied) {
     throw new Error('OneCLI gateway not applied — refusing to spawn container without credentials');
   }
   ```
   On v2.4.0 it is stricter still — the host refuses to *boot* without a
   registered gateway: `No gateway provider is registered in this build`
   (`src/gateway-providers/index.ts:22`). Either way, our "OneCLI not reachable →
   fall back" branch has no equivalent.
3. `hostGatewayArgs` moved into the driver module, so the patch would not compile
   even if we kept it.

**The supported replacement differs by base.** Pick the row for the tag you are
basing on; the script detects this for you (`detect_endpoint_flavor`).

| | `v2.3.0` base — *providers-claude* | `v2.4.0` base — *gateway-skill* |
|---|---|---|
| Who injects `ANTHROPIC_BASE_URL` | `src/providers/claude.ts` | the gateway adapter's `withProviderEnv()` |
| Token the container sees | `ANTHROPIC_AUTH_TOKEN=placeholder` | `ANTHROPIC_AUTH_TOKEN=gateway-managed` |
| Core edit required | append `import './claude.js';` to `src/providers/index.ts` | **none** |
| How it gets installed | ships in core | `/add-onecli` skill copies the adapter, appends `import './onecli.js';` to `src/gateway-providers/installed.ts`, pins `@onecli-sh/sdk@2.2.1` |
| Auth step | `setup/index.ts --step auth` | `--step gateway`, then `--step gateway-auth` |
| Fork core lines | 1 | **0** |

On **v2.4.0**, `src/providers/claude.ts` and `src/gateway-providers/onecli.ts` no
longer exist in core. Core ships only the gateway *contract*; the implementation
arrives from `.claude/skills/add-onecli/payload/`. That is strictly better for us
— the endpoint becomes configuration rather than a patch.

### 5.1 Setting it up

Both bases still honour the same two environment variables, so the shape of the
command is stable:

```bash
# v2.4.0 base
pnpm exec tsx setup/lib/skill-driver.ts .claude/skills/add-onecli   # materialize the gateway
pnpm exec tsx setup/index.ts --step gateway
NANOCLAW_ANTHROPIC_BASE_URL=http://host.docker.internal:4000 \
NANOCLAW_ANTHROPIC_AUTH_TOKEN=<litellm-key> \
pnpm exec tsx setup/index.ts --step gateway-auth

# v2.3.0 base
NANOCLAW_ANTHROPIC_BASE_URL=http://host.docker.internal:4000 \
NANOCLAW_ANTHROPIC_AUTH_TOKEN=<litellm-key> \
pnpm exec tsx setup/index.ts --step auth
```

`NANOCLAW_GATEWAY_PROVIDER=onecli` belongs in `.env` on a v2.4.0 base **after**
the skill is applied. Upstream is explicit that the variable alone does nothing:
*"setting `NANOCLAW_GATEWAY_PROVIDER` alone does not install its implementation,
and the host refuses to start without a registered gateway."*

### 5.2 Pin the model — new in v2.4.0

v2.4.0 moves the default for groups with no model set to **Opus 5.5**, and adds
two install-wide knobs read from `.env`:

- `NANOCLAW_DEFAULT_MODEL` — fills in the model for groups that have not set one
- `NANOCLAW_FAST_MODE=1` — fast serving tier at a higher per-token price

`bootstrap/30-install-litellm.sh` registers exactly one `model_name`
(`claude-sonnet-5`), and the Bedrock IAM policy only covers sonnet-5
inference profiles. So on a v2.4.0 base an unpinned group asks LiteLLM for a
model it does not serve. **Set the model explicitly:**

```bash
NANOCLAW_DEFAULT_MODEL=claude-sonnet-5    # must match LiteLLM's model_name
```

Leave `NANOCLAW_FAST_MODE` unset. If you do want Opus, that is a three-place
change — LiteLLM `model_list`, the Bedrock IAM statement, and this variable — not
a one-place change.


### 5.3 Two open decisions, both to be settled in a spike

**(a) Does LiteLLM need a real key?** Today it has none, and the OneCLI vault
needs a value to inject. Two options:

- *Keep it unauthenticated.* Register the vault secret with a throwaway value
  (or none) and rely on the placeholder bearer reaching LiteLLM, which ignores
  it. Least change. Must be verified: confirm `applyContainerConfig` still
  returns `applied === true` with no Anthropic secret present, otherwise every
  spawn throws.
- *Give LiteLLM a master key* (`LITELLM_MASTER_KEY`), store it in Secrets
  Manager, register it as the OneCLI generic secret above. More moving parts,
  but it removes the "any process on the docker bridge can spend Bedrock money"
  property and makes the vault path real rather than decorative. **Preferred.**

Either way, verify whether OneCLI's proxy actually intercepts plain-HTTP
`host.docker.internal:4000` and injects the header. If the gateway's contributed
`NO_PROXY` includes `host.docker.internal`, the traffic bypasses the proxy and no
header is injected — which is fine for the unauthenticated option and fatal for
the master-key option.

**(b) Egress lockdown is incompatible with host-local LiteLLM.** Leave
`NANOCLAW_EGRESS_LOCKDOWN` unset/`false`. `src/egress-lockdown.ts` puts
containers on a `--internal` Docker network and **aliases `host.docker.internal`
to the OneCLI gateway container** — which makes a host-local LiteLLM on port
4000 unreachable at that name. If we ever want lockdown, LiteLLM has to become a
container attached to `nanoclaw-egress`.

---

## 6. Step 4 — the rebase itself

> **Automated.** `scripts/fork-v2-rebase.sh` implements §3 and §6 of this
> document, one phase per step. Dry run is the default; nothing mutates without
> `--apply` and nothing is pushed without `--push`.
>
> ```bash
> scripts/fork-v2-rebase.sh status      # where you are
> scripts/fork-v2-rebase.sh all         # dry run the whole sequence
> scripts/fork-v2-rebase.sh all --apply
> ```
>
> It stops before `promote`, which is gated behind `--i-have-pinned-the-iac`
> (§3) and the real-instance verification in V2_MIGRATION.md §7. It does not do
> §6a's hand-review patches (it extracts them for you), §6e's reaction
> approvals, or §6f's MCP re-registration. Read the sections below anyway — the
> script enforces the plan, it does not explain it.

Work on a branch. `main` does not move until the result is verified on a real
instance (see V2_MIGRATION.md §7).

```bash
cd /Users/michielf/Projects/lovelace-agent/nanoclaw
git fetch upstream --prune --tags

# Start from upstream's exact release. Not a merge — a new base.
git checkout -b v2-base v2.4.0
```

Every reference to `v2.3.0` below reads `v2.4.0` on the recommended base. The
script takes it as a parameter:

```bash
scripts/fork-v2-rebase.sh base --apply --upstream-tag v2.4.0
# or: export FORK_V2_UPSTREAM_TAG=v2.4.0
```

Then re-apply, in this order:

**6a. Repo hygiene** (cheap, do it first so the tree builds)

```bash
# 1. Carry the container skills over verbatim.
git checkout v1-maintenance -- \
  container/skills/wiki \
  container/skills/use-imaprest-rest \
  .claude/skills/add-imaprest

# 2. Re-apply the small config deltas BY HAND, reviewing each hunk.
#    Do NOT `git checkout` these files — v2's versions are different.
git diff v1-maintenance -- .gitignore .env.example .husky/pre-commit
```

Deliberately **not** carried over: the `groups`/`logs`/`store` symlinks, the
deleted `groups/*/CLAUDE.md`, `package-lock.json`, `src/config.ts`, and the two
deleted GitHub workflows (check whether v2's workflow set already covers version
bumping and token counting before re-deleting anything).

**6b. Toolchain**

```bash
corepack enable
pnpm install --frozen-lockfile
pnpm run build
pnpm exec vitest run
```

Fix anything that fails here before continuing. A clean baseline matters — you
need to be able to tell your breakage from upstream's.

Two things that will look like your fault and are not:

- **A husky `pre-commit` failure with exit 127** once `pnpm install` has run.
  v2's `prepare: husky` installs a hook that shells out to `pnpm`; if `pnpm` is
  not on the hook's PATH it blocks every commit. Fix the PATH rather than
  reaching for `--no-verify`. Applies to both bases.
- **On a `v2.3.0` base only: 4 failures in
  `scripts/update/transaction.e2e.test.ts` on macOS**, all reporting *"Update
  state contains mismatched or unsafe paths"*. Upstream's own bug: the fixture
  builds its install under `os.tmpdir()` (`/var/folders/…`, where `/var` is a
  symlink to `/private/var`), `prepareUpdate()` stores `fs.realpathSync()` of that
  path, the test passes the raw path back in, and `hasSafeStatePaths()` compares
  them with `path.resolve()` — which does not resolve symlinks. Reproducible from
  both `/tmp` and a real path, so it is not about where you put the checkout, and
  it does not reproduce on Linux.
  **v2.4.0 fixes this** (`realResolve()` + `fs.realpathSync`), and its suite is
  green on macOS — one more reason to prefer that base.

**6c. Install Discord the v2 way**

Apply only the skill's **code-carrying** steps (1–4). Do not run the whole
document locally — see the note below.

```bash
remote=$(source setup/lib/channels-remote.sh; resolve_channels_remote)
git fetch "$remote" channels

git show "$remote/channels:src/channels/discord.ts"                  > src/channels/discord.ts
git show "$remote/channels:src/channels/discord-registration.test.ts" > src/channels/discord-registration.test.ts

grep -qF "import './discord.js';" src/channels/index.ts \
  || echo "import './discord.js';" >> src/channels/index.ts

pnpm add @chat-adapter/discord@4.29.0     # read the exact pin from the skill's nc:dep block
pnpm run build
pnpm exec vitest run src/channels/discord-registration.test.ts
```

`discord-registration.test.ts` imports the real channel barrel and asserts the
registry contains `discord`, so it also covers the dependency install. All four
steps are idempotent.

> **Why not just run the skill engine.** `scripts/skill-apply.ts` invoked as a
> CLI is **plan-only** — its `main` block calls `planSkill` and prints a table;
> it never writes. The applier is `setup/lib/skill-driver.ts`, but that applies
> the *whole* document, and `add-discord` also carries `nc:prompt bot_token`,
> `nc:operator` browser steps, `nc:env-set`, `effect:restart`, and the agent
> wire. Those are instance-side (V2_MIGRATION.md §7/§8), not part of a local
> rebase.

> **Remote resolution is already fork-aware.** `setup/lib/channels-remote.sh`
> walks `git remote -v` for a URL matching `nanocoai/nanoclaw` (or the old
> `qwibitai/nanoclaw`) and returns that remote, adding `upstream` as a fallback.
> Our layout — `origin` = `foxey/nanoclaw`, `upstream` = `nanocoai/nanoclaw` —
> resolves to `upstream` correctly. Override with `NANOCLAW_CHANNELS_REMOTE` if
> needed, but **unset it before running the test suite**: `slack-auto.test.ts`
> asserts on remote resolution and fails when it is set.

**6d. Configure the LiteLLM endpoint** — per §5, and **base-dependent**:

- On a **v2.4.0** base there is *no source change at all*. The endpoint is
  `ANTHROPIC_BASE_URL` + `NANOCLAW_DEFAULT_MODEL` in `.env`, and the gateway
  adapter arrives from `/add-onecli` (applied on the instance, since its setup
  step talks to a live gateway). Fork core delta for the endpoint: **zero lines**.
- On a **v2.3.0** base, `appendProviderImport('./claude.js')` writes to
  `src/providers/index.ts`, so it becomes a tracked one-line fork change. That is
  the same shape upstream's own setup produces.

Either way, do **not** write `ANTHROPIC_AUTH_TOKEN` into `.env` — the provider
(v2.3.0) or the gateway (v2.4.0) supplies the placeholder itself, and a real
credential value there can trip the driver's credential-in-env admission rules.

**6e. Re-implement emoji-reaction approvals** (item 1b) *only if you still want
them.* Treat it as a new feature against the v2 approval seam, not a port. Best
shape: a small addition in the Discord adapter copy plus a `guard()`-routed
approval, with its own test. Consider contributing it upstream to the `channels`
branch rather than carrying it as a fork delta — that is what
`docs/BRANCH-FORK-MAINTENANCE.md` asks for and it is how you avoid this exact
document next year.

**6f. Re-register MCP servers as data, not code** (item 3) — after v2 is running,
`ncl groups config add-mcp-server` per server. Nothing to commit.

**6g. Run upstream's own detectors**

```bash
bun scripts/detect-driver-migration.ts   # container-seam customizations
```

Empty output means nothing left to fix. Also skim, in order:
`docs/v1-to-v2-changes.md`, `docs/agent-mailbox-seam-migration.md`,
`docs/central-db-async-migration.md`, `docs/host-lifecycle-migration.md`.

**6h. Verify, then promote**

```bash
pnpm run build && pnpm exec vitest run
git push -u origin v2-base
```

Promote to `main` only after V2_MIGRATION.md §7 has passed on a real instance.
When you do, keep the linear history honest:

```bash
git tag -a v2.4.0-lovelace -m "First v2 fork release" v2-base
git push origin v2.4.0-lovelace
```

Then move `main`. Because `v2-base` is not a descendant of `main`, this is a
history replacement, not a fast-forward. Two options:

- **Preferred:** join the histories from the v2 side, then fast-forward `main`.
  Merging *into* `v2-base` with `-s ours` keeps v2's tree and records `main` as a
  second parent, which is exactly the shape you want — and unlike the reverse
  direction it needs no index surgery:
  ```bash
  git checkout v2-base
  git merge -s ours main -m "feat!: adopt upstream nanoclaw v2.3.0 as the new fork base"
  git log --oneline --graph -3        # confirm two parents, v2 tree
  git diff --stat v2.3.0 HEAD        # confirm only our intended delta vs upstream

  git checkout main
  git merge --ff-only v2-base        # now a genuine fast-forward
  ```
  `main` ends up with v2's tree while both histories stay reachable, so
  `v1.2.52-lovelace` and `git log` across the boundary still resolve.
- **Alternative:** make `v2-base` the new default branch on GitHub and leave
  `main` frozen. Cleaner history, but requires updating `nanoclawRepo`/branch in
  the IaC and any tooling that assumes `main`.

Pick one and write it down; do not leave it ambiguous.

---

## 7. Rollback

Because v1 is frozen at a tag and a branch, rollback is not a Git operation at
all — it is redeploying the pinned ref:

```bash
cd ../lovelace-ai
cdk deploy --context nanoclawRef=v1.2.52-lovelace --context dataVolumeId=vol-…
```

This only works if §3 was done first and the `nanoclawRef` parameter exists.

---

## 8. Ongoing maintenance after this

Stop hand-merging. v2 ships the tooling for this:

- **`/update-nanoclaw`** for routine upstream updates. It stages the merge in a
  separate worktree, refreshes installed skills, snapshots `.env`/`data/`/
  `groups/`/`store/`, gates breaking migrations, stamps the upgrade marker, and
  rolls back automatically on health failure. It self-updates its controller from
  upstream before mutating anything.
- **The upgrade tripwire.** v2 refuses to boot unless `data/upgrade-state.json`
  matches the running checkout. Any `git pull`-based deploy — including our CDK
  bootstrap — must end with:
  ```bash
  pnpm exec tsx scripts/upgrade-state.ts set
  ```
  See `docs/upgrade-recovery.md`. This is a hard requirement for the IaC; it is
  called out again in V2_MIGRATION.md §4.
- **Gateways must be materialized on every update.** Since v2.4.0 the gateway is
  a skill, not core. `/update-nanoclaw` re-applies the selected gateway's skill
  before cutover, but a hand-merge does not — and the host will not boot without
  it. If you ever merge by hand, re-apply `/add-onecli` before restarting.
- **Contribute upstream** where possible (emoji approvals → `channels` branch;
  the imaprest skill → a `/add-imaprest` PR). Every feature that lands upstream
  is one less thing to re-port.

Target steady state: our fork delta is `.env`-level configuration, one
`src/providers/index.ts` import line, and our own skills. Nothing in core.

---

## 9. Checklist

Freeze:
- [ ] `v1.2.52-lovelace` tag pushed
- [ ] `v1-maintenance` branch pushed and protected
- [ ] `nanoclawRef` context parameter added to the CDK stack, pinned to
      `v1.2.52-lovelace`, **deployed and verified**
- [ ] `~/.config/nanoclaw/*-allowlist.json` copied off the instance
- [ ] `/data/nanoclaw` snapshot confirmed (see V2_MIGRATION.md §7)

Rebase:
- [ ] Base tag chosen and confirmed newest (`scripts/fork-v2-rebase.sh status`
      reports upstream drift and any release being cut) — **`v2.4.0` recommended**
- [ ] `v2-base` branched from the chosen tag; `pnpm install && build && vitest` green
- [ ] Container skills + `add-imaprest` carried over
- [ ] `.gitignore` / `.env.example` / `.husky/pre-commit` deltas reviewed and re-applied
- [ ] `/add-discord` applied; `discord-registration.test.ts` green
- [ ] `channels` branch resolution confirmed for our remote layout
- [ ] LiteLLM endpoint configured for the chosen base (§5): on v2.4.0 the gateway
      skill is applied and `NANOCLAW_GATEWAY_PROVIDER=onecli` recorded *after*;
      on v2.3.0 `src/providers/index.ts` imports `./claude.js`
- [ ] `NANOCLAW_DEFAULT_MODEL` pinned to a model LiteLLM serves **and** the
      Bedrock IAM policy allows (§5.2); `NANOCLAW_FAST_MODE` left unset
- [ ] `ANTHROPIC_AUTH_TOKEN` confirmed **absent** from `.env`
- [ ] LiteLLM key decision made (§5.3a) and the no-secret spawn path verified
- [ ] `NANOCLAW_EGRESS_LOCKDOWN` confirmed unset (§5.3b)
- [ ] `scripts/detect-driver-migration.ts` output empty
- [ ] `session-commands.ts`, the `mcpServers` merge, and the `container-runner`
      patch confirmed **absent** (deleted, not ported)
- [ ] Emoji-reaction approvals: decided (re-implement / drop) and, if kept, tested

Promote:
- [ ] V2_MIGRATION.md §7 passed on a real instance
- [ ] `v2.4.0-lovelace` tagged
- [ ] `main` promotion strategy chosen and executed (§6h)
- [ ] MCP servers re-registered via `ncl groups config add-mcp-server`

---

## 10. Upstream changes since v2.3.0

Added 2026-09-23. Verified against `upstream/release/v2.4.0` (`5e6a1d38`, version
`2.4.0`, 233 commits ahead of `v2.3.0`) and `upstream/main` (`0ab3794a`, 225
commits ahead — `release/v2.4.0` contains all of `main` plus 8 commits).
The `v2.4.0` tag had not landed at the time of writing; re-run
`scripts/fork-v2-rebase.sh status` to see whether it has.

### 10.1 Why base on v2.4.0 instead of v2.3.0

The gateway-seam change is not optional — it is *in* v2.4.0. Basing on `v2.3.0`
means performing the v1→v2 migration and then, on the very next update, a second
breaking gateway migration. Basing on `v2.4.0` is one step, and it makes our
endpoint wiring simpler rather than harder (zero core lines instead of one).

Verified compatible with a v2.4.0 base, so nothing else in this plan has to move:

- `channels:src/channels/discord.ts` is **byte-identical** to what §6c was
  validated against (3958 bytes), and `add-discord` still pins
  `@chat-adapter/discord@4.29.0` on both tags.
- That adapter **compiles against v2.4.0 core** (`pnpm run build` → `tsc` exit 0)
  and `discord-registration.test.ts` passes. `ChatSdkBridgeConfig`'s only
  non-optional fields are still `adapter` and `supportsThreads`.
- `migrate-v2.sh`, the `/migrate-from-v1` skill, `docs/v1-to-v2-changes.md`,
  `scripts/upgrade-state.ts`, `setup/lib/channels-remote.sh`, and
  `setup/lib/install-slug.sh` are unchanged or cosmetically changed. The
  v1→v2 migration mechanics in V2_MIGRATION.md still hold.

### 10.2 What actually changed

**[BREAKING] Credential gateways install through skills.** Core now ships only
the gateway contract. `src/providers/claude.ts` and
`src/gateway-providers/onecli.ts` are **deleted from core**; `/add-onecli` (default)
and `/add-iron-proxy` supply implementations. The host fails closed at boot:
`No gateway provider is registered in this build`. `ANTHROPIC_BASE_URL` now
reaches containers via the adapter's `withProviderEnv()`, paired with
`ANTHROPIC_AUTH_TOKEN=gateway-managed`. Full procedure in
`docs/gateway-seam.md § Migrating an existing installation`. This is the change
that rewrites §5 and §6d.

**Setup step names moved.** `--step onecli` and `--step auth` are gone, replaced
by `--step gateway` and `--step gateway-auth`. `migrate-v2.sh` was updated to
match, and its handoff field `onecli_healthy` is now `gateway_healthy`.

**OneCLI version pins relocated.** Core `versions.json` now carries only
`agent-image` (and its digest moved). The gateway pins live in
`.claude/skills/add-onecli/versions.json`:
`onecli-gateway 1.41.0`, `onecli-cli 2.2.5`, `onecli-sdk 2.2.1`.

**[BREAKING] Default model moves to Opus 5.5**, plus `NANOCLAW_DEFAULT_MODEL` and
`NANOCLAW_FAST_MODE`. Agents run Claude Code 2.1.280. Directly affects our
single-model LiteLLM and sonnet-only IAM policy — see §5.2.

**[BREAKING] Agents now receive their capability instructions.**
`src/claude-md-compose.ts` → `src/project-doc-compose.ts`;
`composeGroupClaudeMd(group)` → `composeGroupProjectDoc(group, groupDir, spec)`.
The `/app/CLAUDE.md` and `/workspace/agent/.claude-fragments` mounts are gone.
We do not touch these symbols, so there is nothing to port — but the one-time
cleanup applies after migrating:
```bash
rm -rf groups/*/.claude-fragments groups/*/.claude-shared.md
```

**Other, non-blocking for us:** a Mattermost channel; reworked OpenCode provider;
`/add-codex` repinned to `@openai/codex` 0.155.1 with new threads on
`gpt-6-astra`; community-portal setup for Echo's hardened image and a managed
Slack app; an optional `extractRawText` hook on `ChatSdkBridgeConfig` (the Discord
adapter does not set it); quoted `.env` values now parse consistently via
`envValue` in `src/env.ts`.

### 10.3 Still true, still worth re-checking each time

- **No newer tag than the one you pick.** Run
  `scripts/fork-v2-rebase.sh status` — it reports how far `upstream/main` is
  ahead of your base and flags any version-bumped `release/*` branch that is not
  yet tagged.
- **The upgrade tripwire** (`data/upgrade-state.json`) is unchanged and still
  mandatory for any bootstrap-driven deploy (§8, V2_MIGRATION.md §4.1).
- **The macOS test failures are FIXED in v2.4.0.** Correcting an earlier note in
  this document: `scripts/update/transaction.ts` *did* move. Upstream replaced the
  `path.resolve()` comparisons with a `realResolve()` helper that calls
  `fs.realpathSync`, and `loadState` now passes a resolved project root. Verified
  on a v2.4.0 base: the full suite is green — **256 files, 2929 tests, 0
  failures**, including `scripts/update/transaction.e2e.test.ts`. The caveat in
  §6b now applies only to a `v2.3.0` base.
