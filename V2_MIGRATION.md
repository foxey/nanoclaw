# V2_MIGRATION.md — upgrading the AWS deployment from nanoclaw v1 to v2

> **Revised 2026-09-23** for upstream v2.4.0 (prepared 2026-09-23, 233 commits
> past v2.3.0; release content on `upstream/release/v2.4.0`, tag not yet landed).
> The target base is now **`v2.4.0`**, which moves the credential gateway out of
> core into the `/add-onecli` skill and changes the default model. Affected
> sections are marked **v2.4.0**. The v1→v2 migration mechanics
> (`migrate-v2.sh`, `/migrate-from-v1`, the state inventory) are unchanged.
> Rationale for the base change: UPDATE_FORK.md §10.

Infrastructure side of the v1 → v2 move. The repository side is
[UPDATE_FORK.md](UPDATE_FORK.md); do §3 of that document (freeze v1, pin the ref
in the IaC) **before** anything here.

IaC lives in `../lovelace-ai`: a single-stack CDK v2 app
(`lib/nanoclaw-ec2-stack.ts`, entry `bin/nanoclaw-ec2.ts`, region hardcoded
`eu-central-1`) plus six ordered bootstrap scripts shipped as an S3 asset.

> A copy of this file belongs in `../lovelace-ai` alongside the code it changes.
> It is written here because that is where the investigation happened.

---

## 1. What the deployment looks like today

| | Current (v1.2.52) |
|---|---|
| Instance | `t3.medium`, x86_64, AL2023, public subnet, `requireImdsv2` |
| Root volume | 30 GiB gp3 encrypted, destroyed with the instance |
| Data volume | 10 GiB gp3 encrypted, `RemovalPolicy.RETAIN`, tag `DLMBackup=true`, self-attached from UserData at `/dev/xvdf` → mounted `/data/nanoclaw` |
| Snapshots | DLM daily 03:00, retain 7 |
| Checkout | `/opt/nanoclaw`, cloned from `foxey/nanoclaw`, **default-branch HEAD, no ref pin** |
| Runtime | Node 22 (NodeSource), `npm install && npm run build`, `node dist/index.js` |
| Service | system unit `nanoclaw.service`, `User=ec2-user`, `EnvironmentFile=/opt/nanoclaw/.env` |
| Agent image | `docker build -t nanoclaw-agent:latest ./container` |
| LLM path | LiteLLM venv on `0.0.0.0:4000` as root → Bedrock via instance profile; iptables allows only `127.0.0.1` + `172.17.0.0/16` |
| Credentials | Secrets Manager (`nanoclaw/discord-bot-token`, `nanoclaw/github-deploy-key`); `.env` = `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN=dummy`, `DISCORD_BOT_TOKEN`, `TRIGGER_WORD`, `ASSISTANT_NAME`, `ONECLI_URL` |
| OneCLI | installed unpinned from `onecli.sh/install`, gateway at `http://172.17.0.1:10254`, docker volume dirs symlinked onto the EBS |
| Persistence trick | `store`, `groups`, `logs`, `data` in `/opt/nanoclaw` are symlinks to `/data/nanoclaw/*` (`store`/`groups`/`logs` are committed symlinks in the fork; `data` is created by bootstrap) |
| Ops tooling | `bin/ada-connect.sh`, `bin/onecli-backup.sh`, `bin/onecli-restore.sh`. **No nanoclaw backup/restore and no upgrade path.** |

### What changes under v2

| | v2.3.0 |
|---|---|
| Package manager | **pnpm 10.34.5** via corepack (`pnpm-lock.yaml`) — not npm |
| Node | 22+ required (already satisfied) |
| Service name | slug-derived: `nanoclaw-v2-<sha1(projectRoot)[:8]>.service`. For `/opt/nanoclaw-v2` that is **`nanoclaw-v2-2e602aa0.service`** |
| Agent image tag | slug-derived: **`nanoclaw-agent-v2-2e602aa0:latest`** — so v1 and v2 images coexist without clobbering |
| Central DB | `data/v2.db` (was `store/messages.db`) |
| Session state | `data/v2-sessions/<id>/{inbound,outbound}.db` + `.claude-shared/` |
| Group folders | `groups/<folder>/` with `instructions.prepend.md`, `memory/`, composed `CLAUDE.md` (do not edit), `container.json` |
| Container runtime | behind `src/drivers/`; `create` + `start --attach`, `ncl-…` names, match by label (`docker ps --filter label=nanoclaw-session`) |
| Credentials | Gateway vault, **mandatory**. **v2.4.0:** the gateway is a *skill* (`/add-onecli`), not core — the host refuses to boot without one registered. Pins moved to `.claude/skills/add-onecli/versions.json`: gateway `1.41.0`, CLI `2.2.5`, SDK `2.2.1`. Core `versions.json` now holds only `agent-image`. |
| Model | **v2.4.0:** unset-model default is **Opus 5.5**. Our LiteLLM serves one model name, so `NANOCLAW_DEFAULT_MODEL` must be pinned (§2.12). |
| Extra surface | `ncl` CLI over `data/ncl.sock`; webhook server on `0.0.0.0:3000` when a channel registers routes |
| Boot guard | `data/upgrade-state.json` tripwire — see §4.1 |

---

## 2. Blockers found during investigation

These change the shape of the plan, so read them before choosing an approach.
Each is verified against `../nanocoai-nanoclaw` at `v2.3.0`.

**2.1 `migrate-v2.sh` cannot run from cloud-init.** First thing it does:

```bash
if ! [ -t 0 ] || ! [ -t 1 ]; then
  echo "This script requires an interactive terminal."
  exit 1
fi
```

UserData has no TTY. The migration is therefore a **human-driven SSH step**, not
a bootstrap step. Use `ssh -t ec2-user@$ADA 'bash -lc "cd /opt/nanoclaw-v2 && bash migrate-v2.sh"'`.
`bash -lc` matters: the Bedrock exports for Claude Code live in `~/.bashrc`.

**2.2 `migrate-v2.sh`'s Discord install step is stale at v2.3.0.** Phase 2c does
`INSTALL_SCRIPT="setup/install-${ch}.sh"`, but those installers were deleted in
2.1.54 (*"the bespoke non-interactive channel installers … are deleted"*). Only
`install-claude.sh`, `install-docker.sh`, `install-github.sh`, `install-node.sh`,
`install-signal-cli.sh` remain. The step will report `Install discord (no install
script)` and record `failed`. **Mitigation:** install Discord *before* running
`migrate-v2.sh` (it is idempotent and the script skips already-installed
channels), i.e. bake `/add-discord` into the fork per UPDATE_FORK.md §6c so the
adapter is already in the checkout.

**2.3 `migrate-v2.sh`'s service switchover will silently no-op.** It probes
`systemctl --user is-active nanoclaw`. Our v1 is a **system** unit, so
`V1_RUNNING=false` and it prints *"v1 service not running — nothing to switch"*.
Do the stop/start by hand (§7). Not a defect for us — it means the script will
not touch the running v1 service, which is exactly what we want.

**2.4 v2 fails closed without a gateway.** On v2.3.0 that is
`src/gateway-providers/onecli.ts`:

```ts
if (!applied) {
  throw new Error('OneCLI gateway not applied — refusing to spawn container without credentials');
}
```

**v2.4.0 is stricter: the host refuses to boot**, not just to spawn —
`No gateway provider is registered in this build`
(`src/gateway-providers/index.ts:22`). The fork's "OneCLI unreachable → inject
`dummy` as `ANTHROPIC_API_KEY`" fallback has no equivalent either way, and the
driver admission rules reject credential values in container env. The gateway is
load-bearing, and its data (`/data/nanoclaw/onecli/{app-data,pgdata}`) is
critical state.

**2.4a The gateway is a skill on v2.4.0, and bootstrap must apply it.** Core ships
only the contract. `bootstrap/60-install-nanoclaw-v2.sh` has to run

```bash
pnpm exec tsx setup/lib/skill-driver.ts .claude/skills/add-onecli
```

before the service ever starts, and record `NANOCLAW_GATEWAY_PROVIDER=onecli` in
`.env` **after** that succeeds. Upstream is explicit that the variable alone does
nothing. A deploy that sets the variable and skips the skill produces an instance
that will not boot. `docs/gateway-seam.md § Migrating an existing installation`
is the authoritative procedure; `/update-nanoclaw` does it automatically, a
hand-rolled bootstrap does not.

**2.5 Egress lockdown is incompatible with host-local LiteLLM.** Leave
`NANOCLAW_EGRESS_LOCKDOWN` unset. `src/egress-lockdown.ts` aliases
`host.docker.internal` **to the OneCLI gateway container** on an `--internal`
network, which makes LiteLLM on the host's port 4000 unreachable at that name.

**2.6 `PT15M` resource-signal timeout will be exceeded on a fresh v2 install.**
The stack sets `resourceSignal: { timeout: 'PT15M' }` and the README already
notes bootstrap takes 10–15 minutes. v2 adds `pnpm install`, a `tsc` build, and a
Chromium-based agent image build (`container/Dockerfile` installs `chromium`,
Bun 1.3.12, and pnpm; upstream estimates 3–10 minutes for the image alone on a
developer machine, and this is a 2-vCPU t3.medium). Raise the timeout and/or the
instance size for the fresh-install path.

**2.7 Memory and disk are marginal.** 4 GiB RAM + 4 GiB swap already needed a
swapfile for v1's `npm install`. Side-by-side means two checkouts, two
node_modules trees, a pnpm store, and two agent images. Root is 30 GiB.
Recommend 60 GiB root and a temporary `t3.large` (or larger) for the migration
window — the README already documents the instance-type resize procedure, and the
data volume reattaches.

**2.8 The `DLMBackup` tag is not applied to a reused volume.** The tag is set on
the CDK-managed `ec2.Volume`. Pass `--context dataVolumeId=vol-…` and CDK stops
managing the volume, so nothing re-applies the tag. **Verify the tag exists on
the live volume before relying on daily snapshots**, and take an explicit
snapshot regardless.

**2.9 State on the ephemeral root volume.** Not on `/data/nanoclaw`, lost on
instance replacement:

- `~/.config/nanoclaw/mount-allowlist.json`, `sender-allowlist.json` — outside
  `PROJECT_ROOT` by design (`src/config.ts`), **not regenerated by bootstrap**
- `/opt/nanoclaw/.env` — regenerated by bootstrap, but any hand-added key is lost
- `~/.ssh/github_deploy_key` — regenerated
- `/var/log/nanoclaw-bootstrap.log`

**2.10 Bootstrap's clone is guarded and its symlink step is destructive.**

```bash
if [ ! -d /opt/nanoclaw ]; then ... git clone ... else echo "already exists, skipping clone"; fi
...
rm -rf store groups logs data
```

Re-running bootstrap on a live instance never updates the code, and the `rm -rf`
is only safe because the real data is behind the symlinks. Both need attention
for v2 (§6).

**2.11 The `container-runner.ts` UserData patch is now dead code, and dangerous.**
It matches on `args.push(...hostGatewayArgs())`, which moved into
`src/drivers/`. `content.replace` with a missing marker is a silent no-op and the
script still exits 0. It is also already redundant — the fork committed the same
change. **Delete the patch and add an explicit assertion instead** (§6.3).

**2.12 Model coverage — worse on v2.4.0.** LiteLLM registers exactly one model,
`claude-sonnet-5` (`bootstrap/30-install-litellm.sh`), and the IAM policy covers
only the sonnet-5 inference profile. Three ways that bites:

- **v2.4.0 moves the unset-model default to Opus 5.5.** Any migrated group with no
  model of its own will ask LiteLLM for Opus, which it does not serve. This is the
  most likely cause of a migration that completes cleanly and then answers nothing.
  **Pin `NANOCLAW_DEFAULT_MODEL=claude-sonnet-5` in `.env`** (a group's own model
  still wins). Both new knobs are read from the host `.env` when `container.json`
  is materialized, so a change takes effect at the next container start — no host
  restart needed.
- `~/.bashrc` exports a haiku default for Claude Code that the IAM policy does
  **not** permit, so interactive haiku calls get AccessDenied.
- Per-group `--model` / `--effort` overrides can request anything.

Decide once whether to widen the LiteLLM `model_list` and the Bedrock statement,
or to pin narrowly and keep both surfaces single-model. Leave
`NANOCLAW_FAST_MODE` unset — it bills every agent at the fast tier.

**2.13 The webhook server binds `0.0.0.0:3000`** (`src/webhook-server.ts:164`)
when a channel registers raw routes. Discord is outbound-only so it should not
start, but the security group is the only thing preventing exposure on a public
subnet. Confirm it is not listening after cutover (`ss -ltnp`), and if it is,
either bind it to localhost or add an iptables rule matching the port-4000
pattern.

---

## 3. State inventory

### Must survive (this is the whole point of the exercise)

| State | Location | v2 handling |
|---|---|---|
| Agent memory | `/data/nanoclaw/groups/*/CLAUDE.md` | Copied to `groups/<folder>/CLAUDE.local.md` by `setup/migrate-v2/groups.ts`, then distilled into `memory/` by `/migrate-memory`. **The volume is the only copy — the fork no longer tracks these files.** |
| Registered groups / channels / wiring | `store/messages.db:registered_groups` | Rewritten into `agent_groups` + `messaging_groups` + `messaging_group_agents`. `dc:12345` → `channel_type='discord'`, `platform_id='discord:12345'`. |
| Conversation continuity | `data/sessions/<folder>/.claude/projects/-workspace-group/*.jsonl` | Copied to `data/v2-sessions/<ag>/.claude-shared/projects/-workspace-agent/`, and the newest session id written as `continuation:claude` in `outbound.db` so the agent **resumes the same conversation**. |
| Active scheduled tasks | `store/messages.db:scheduled_tasks` | Become `messages_in` rows with `kind='task'` in the session `inbound.db`. Inactive/completed rows exported to `logs/setup-migration/inactive-tasks.json`. |
| `.env` keys | `/opt/nanoclaw/.env` | Copied verbatim, never overwriting existing v2 keys. |
| Per-group container config | `registered_groups.container_config` | `groups/<folder>/container.json`, or `.v1-container-config.json` if unparseable. Since 2.0.48 the DB is authoritative and filesystem configs are backfilled at startup. |
| Custom container skills | `container/skills/*/` | Copied for any skill v2 doesn't already have. |
| OneCLI vault | `/data/nanoclaw/onecli/{app-data,pgdata}` | Unchanged, but now mandatory. Back up with `bin/onecli-backup.sh`. |
| Mount / sender allowlists | `~/.config/nanoclaw/*.json` | **Not migrated by anything.** Copy by hand (§2.9). |

### Explicitly not migrated

Per `docs/v1-to-v2-changes.md`: **chat history** (`messages`, `chats` tables),
`router_state`, and v1 `sessions` rows. The v1 DB is left untouched at
`/data/nanoclaw/store/messages.db`, so history remains queryable — but it never
appears in v2. If chat history matters to you, that is a reason to keep the v1
volume contents indefinitely rather than reformatting.

`migrate-v2.sh` is idempotent and safe to re-run. Group folders use rsync-style
never-overwrite semantics.

---

## 4. Non-negotiable IaC requirements

### 4.1 The upgrade tripwire

v2.1.0 made this a boot requirement:

> *"Startup now requires an upgrade marker. The host refuses to boot unless
> `data/upgrade-state.json` records that this install reached the current version
> through a sanctioned path."*

`docs/upgrade-recovery.md` addresses our exact situation:

> *"If you've built your own way to upgrade — a custom skill, a deploy script, a
> CI job, a service that pulls and restarts — it won't stamp the marker, so the
> host will trip on the next start. Add the stamp after validation and required
> migrations succeed, immediately before the health-gated restart."*

**Every bootstrap path must end with, after build + migrations succeed and before
starting the service:**

```bash
sudo -u ec2-user bash -lc 'cd /opt/nanoclaw-v2 && pnpm exec tsx scripts/upgrade-state.ts set'
```

Guard it: only stamp if `pnpm run build` exited 0. Stamping unconditionally
turns the tripwire into decoration.

### 4.2 Ref pinning

Add `nanoclawRef` and pass it through to a `git checkout` after clone. Without
it there is no way to deploy a known version, and no way to roll back
(UPDATE_FORK.md §3, §7).

### 4.3 Version pins — relocated in v2.4.0

`bootstrap/40-install-onecli.sh` installs from unpinned `onecli.sh/install`, so
the gateway drifts on every rebuild — and per `docs/onecli-upgrades.md`, *"Docker
never re-pulls a tag — the server freezes at whatever `latest` meant on install
day."* Read the pins out of the checkout and pass `ONECLI_VERSION` explicitly.

**Where the pins live depends on the base:**

| Base | Gateway pins |
|---|---|
| `v2.3.0` | `versions.json` → `onecli-gateway`, `onecli-cli`; enforced by `--step onecli` |
| `v2.4.0` | `.claude/skills/add-onecli/versions.json` → `onecli-gateway 1.41.0`, `onecli-cli 2.2.5`, `onecli-sdk 2.2.1`; enforced by `--step gateway`. Core `versions.json` keeps only `agent-image`. |

Anything in the IaC that greps core `versions.json` for `onecli-gateway` returns
empty on a v2.4.0 base — and an empty pin silently means "latest". Read from the
skill path, and fail the bootstrap if the pin is missing rather than defaulting.

---

## 5. Where the v2 checkout should live

The persistence trick has to change. Today `store`/`groups`/`logs` are **committed
symlinks** in the fork, and `setup/migrate-v2/groups.ts` deliberately **skips
symlinks** when copying — plus upstream v2 ships `groups/` as a real directory
with tracked content. Keeping the committed symlinks fights both.

Three options for `/opt/nanoclaw-v2`:

**(a) Bind-mount the state dirs.** Keep the checkout on the root volume, create
real directories, and bind-mount from the EBS volume via `/etc/fstab`:

```
/data/nanoclaw-v2/data   /opt/nanoclaw-v2/data   none  bind,nofail  0 0
/data/nanoclaw-v2/groups /opt/nanoclaw-v2/groups none  bind,nofail  0 0
/data/nanoclaw-v2/logs   /opt/nanoclaw-v2/logs   none  bind,nofail  0 0
```

No symlinks in Git, works with v2's copy semantics, `RequiresMountsFor` in the
unit still guards startup. **Recommended.**

**(b) Put the entire checkout on the volume** (`/data/nanoclaw-v2` is the
checkout, `/opt/nanoclaw-v2` a symlink to it). Simplest conceptually, and the
code survives instance replacement — but then `git`, `node_modules`, and the
pnpm store all live on the 10 GiB data volume, and the checkout stops being
disposable. Grow the volume substantially if you pick this.

**(c) Bootstrap-created symlinks, not committed ones** — today's mechanism minus
the Git part. Works, but you inherit the `rm -rf store groups logs data`
hazard (§2.10) and the migration script's symlink-skipping.

Whichever you pick, remember `data/` is no longer incidental: it holds `v2.db`,
every session DB, `upgrade-state.json`, and `ncl.sock`. It must be persistent.

---

## 6. Three approaches

### Approach A — in-place upgrade of the live instance

Stop `nanoclaw.service`, `git fetch && git checkout v2.4.0-lovelace` in
`/opt/nanoclaw`, `pnpm install`, build, run migrations, stamp, restart.

- **Pro:** no new instance, no new volume, no CDK change to get started.
- **Con:** *`migrate-v2.sh` does not support this.* It requires a **separate v1
  checkout** to read from — `find_v1` scans siblings for `store/messages.db`, and
  `NANOCLAW_V1_PATH` must point at a directory that still holds v1 state.
  Checking out v2 over v1 destroys the source the migration reads. You would have
  to hand-roll the equivalent of five migration steps.
- **Con:** rollback means a reverse checkout plus reverting DB and folder changes
  in place. No clean revert point.
- **Verdict: do not use.** It fights the tooling upstream built for exactly this.

### Approach B — side-by-side on the same instance ★ recommended

`/opt/nanoclaw` (v1, stopped) and `/opt/nanoclaw-v2` (v2) coexist.
`migrate-v2.sh` reads v1 and writes v2. Cut over by swapping systemd units.

- **Pro:** this is the shape upstream designed for — sibling checkouts, an
  idempotent re-runnable migration, and a documented rollback that is a service
  restart. `/migrate-from-v1` Phase 0 is explicitly built around it: *"v1 is
  paused, not touched — flipping back is a service restart."*
- **Pro:** service names and image tags are slug-derived, so v1
  (`nanoclaw.service` / `nanoclaw-agent:latest`) and v2
  (`nanoclaw-v2-2e602aa0.service` / `nanoclaw-agent-v2-2e602aa0:latest`) cannot
  collide.
- **Pro:** rollback is seconds, and v1's state is never mutated.
- **Pro:** the interactive-TTY requirement (§2.1) and Claude-driven
  `/migrate-from-v1` follow-up both work naturally over SSH.
- **Con:** needs headroom — disk, RAM, and a bigger instance for the window
  (§2.7). Resize before, resize back after.
- **Con:** the instance carries two installs until you clean up. Deliberate
  decommissioning step required.
- **Con:** CDK doesn't create `/opt/nanoclaw-v2` today; either provision it via a
  new bootstrap script or do the first migration by hand and then codify it.

### Approach C — backup → fresh instance → import

Snapshot the volume, `cdk destroy`, `cdk deploy` a v2-only stack against a
**new** volume restored from the snapshot, run the migration against a restored
copy of the v1 tree.

- **Pro:** cleanest end state. No v1 residue, no accumulated drift, and it
  forces the IaC to be genuinely reproducible — which is the real long-term win.
- **Pro:** the old instance and volume stay untouched as the rollback, so the
  blast radius is genuinely zero if you keep them.
- **Con:** you still need a v1 tree on the new instance for `migrate-v2.sh` to
  read. So you must either clone `v1.2.52-lovelace` there purely as a migration
  source (with its `store`/`groups` pointed at the restored data), or run the
  migration on the old instance first and then move only v2 state across. Both
  are more moving parts than B, not fewer.
- **Con:** the public IP changes; anything pinned to it breaks.
- **Con:** the `PT15M` timeout and the cold agent-image build land on the
  critical path (§2.6).
- **Verdict: the right shape for a *new* deployment** (§8), and the right shape
  for the *second* environment once the IaC is v2-native. Not the cheapest way
  to move this install.

### Recommendation

**B for this upgrade, then C to prove the result.** Migrate side-by-side, verify,
decommission v1, and only then do a from-scratch `cdk deploy` into a throwaway
stack to confirm the v2 bootstrap path actually works unattended. That sequencing
gets the running install onto v2 with a fast rollback, and still leaves you with
IaC you can trust — without betting the live agent on an untested fresh-install
script.

---

## 7. Runbook — Approach B

### Phase 0 — prerequisites

- [ ] UPDATE_FORK.md §3 done: `v1.2.52-lovelace` tagged, `nanoclawRef` in the
      stack, pinned to v1, **deployed**
- [ ] UPDATE_FORK.md §6 done: `v2.4.0-lovelace` exists and builds clean locally
- [ ] `bootstrap/60-install-nanoclaw-v2.sh` written (§7.2) — or accept a manual
      first run and codify afterwards
- [ ] Maintenance window agreed; tell anyone using the Discord bot

### Phase 1 — back up everything

```bash
source bin/ada-connect.sh   # exports $ADA, opens SSH from your current /32

# 1. Confirm the DLM tag actually exists on the volume (§2.8)
VOL=$(aws ec2 describe-volumes --region eu-central-1 \
  --filters Name=attachment.instance-id,Values=<instance-id> Name=size,Values=10 \
  --query 'Volumes[0].VolumeId' --output text)
aws ec2 describe-tags --region eu-central-1 --filters Name=resource-id,Values=$VOL

# 2. Explicit pre-migration snapshot — this is the real rollback point
aws ec2 create-snapshot --region eu-central-1 --volume-id $VOL \
  --description "pre-v2-migration $(date -u +%FT%TZ)" \
  --tag-specifications 'ResourceType=snapshot,Tags=[{Key=Purpose,Value=pre-v2-migration}]'
# WAIT for state=completed before proceeding.

# 3. OneCLI vault
ssh ec2-user@$ADA "sudo bash -s" < bin/onecli-backup.sh

# 4. The bits that live only on the ephemeral root volume (§2.9)
mkdir -p ./backup-v1
scp -r ec2-user@$ADA:'~/.config/nanoclaw' ./backup-v1/
scp ec2-user@$ADA:/opt/nanoclaw/.env ./backup-v1/env.v1

# 5. A file-level copy of the state, independent of the snapshot
ssh ec2-user@$ADA 'sudo tar czf /tmp/nanoclaw-v1-state.tgz \
  -C /data/nanoclaw store groups data'
scp ec2-user@$ADA:/tmp/nanoclaw-v1-state.tgz ./backup-v1/
```

Do not continue until the snapshot reports `completed` and the local copies
exist. Treat `backup-v1/env.v1` as a secrets-bearing file.

### Phase 2 — headroom

```bash
cd ../lovelace-ai
# Edit lib/nanoclaw-ec2-stack.ts: T3.MEDIUM -> T3.LARGE, root 30 -> 60 GiB
cdk diff     # expect: instance type, root volume size, nothing else
cdk deploy
```

An instance-type change replaces the instance; the data volume self-reattaches on
the next boot (README documents this). Root volume growth needs a filesystem
grow after the block device grows — check the type first rather than assuming:

```bash
ssh ec2-user@$ADA 'df -hT / && lsblk'
sudo growpart /dev/nvme0n1 1
sudo xfs_growfs /        # if xfs (AL2023 default)
sudo resize2fs /dev/nvme0n1p1   # if ext4
```

If the 10 GiB data volume is above ~60% used, grow it too:

```bash
aws ec2 modify-volume --region eu-central-1 --volume-id $VOL --size 30
ssh ec2-user@$ADA 'sudo resize2fs /dev/nvme1n1'   # ext4, per bootstrap
```

### Phase 3 — provision the v2 checkout

Either run `60-install-nanoclaw-v2.sh` (§7.2) or, for a hand-driven first pass:

```bash
ssh -t ec2-user@$ADA 'bash -lc "
  set -e
  sudo mkdir -p /opt/nanoclaw-v2 /data/nanoclaw-v2/{data,groups,logs}
  sudo chown -R ec2-user:ec2-user /opt/nanoclaw-v2 /data/nanoclaw-v2
  git clone --branch v2.4.0-lovelace git@github.com:foxey/nanoclaw.git /opt/nanoclaw-v2
  cd /opt/nanoclaw-v2
  corepack enable && pnpm install --frozen-lockfile && pnpm run build
"'
```

Then add the bind mounts from §5(a) to `/etc/fstab` and `mount -a`.

Sanity check the slug before going further — every later command depends on it:

```bash
ssh ec2-user@$ADA 'cd /opt/nanoclaw-v2 && source setup/lib/install-slug.sh && systemd_unit'
# expect: nanoclaw-v2-2e602aa0
```

### Phase 4 — stop v1 (leave it installed)

```bash
ssh ec2-user@$ADA 'sudo systemctl stop nanoclaw && sudo systemctl disable nanoclaw'
```

Leave the unit file on disk. That file *is* the rollback.

### Phase 5 — run the migration

```bash
ssh -t ec2-user@$ADA 'bash -lc "
  cd /opt/nanoclaw-v2
  NANOCLAW_V1_PATH=/opt/nanoclaw \
  NANOCLAW_CHANNELS=discord \
  NANOCLAW_ANTHROPIC_BASE_URL=http://host.docker.internal:4000 \
  NANOCLAW_ANTHROPIC_AUTH_TOKEN=<litellm-key-or-placeholder> \
  bash migrate-v2.sh
"'
```

`ssh -t` for the TTY (§2.1). `NANOCLAW_V1_PATH` is explicit rather than relying
on the sibling scan. `NANOCLAW_CHANNELS` skips the interactive multiselect. The
two `NANOCLAW_ANTHROPIC_*` variables make the auth step take the custom-endpoint
path non-interactively — on v2.3.0 that is `--step auth` (`setup/auto.ts:1516`),
on **v2.4.0** it is `--step gateway-auth`
(`.claude/skills/add-onecli/scripts/auth.ts:111`). Both read the same two
variables, so this command is unchanged across bases.

Expect, and do not be alarmed by:

- `Install discord (no install script)` recorded as failed — §2.2. Harmless if
  the adapter is already in the checkout; verify with
  `pnpm exec vitest run src/channels/discord-registration.test.ts`.
- `v1 service not running — nothing to switch` — §2.3, expected.
- It will `exec claude "/migrate-from-v1"` at the end if `claude` is on PATH.

Read `logs/setup-migration/handoff.json` and `logs/migrate-steps/*.log`. The
five Phase-1 steps (`1a-env` … `1e-tasks`) all need `status: success`.

**v2.4.0 field renames in the handoff:** the infrastructure step is `3b-gateway`
(was `3b-onecli`) and the JSON field is `gateway_healthy` (was `onecli_healthy`).
Anything that greps the handoff for the old names silently reports nothing.

**v2.4.0 — confirm the gateway is actually registered** before starting the
service, because the host will not boot otherwise:

```bash
ssh ec2-user@$ADA 'grep -n "onecli" /opt/nanoclaw-v2/src/gateway-providers/installed.ts'
# expect: import './onecli.js';
```

If empty, apply the skill and record the selection:

```bash
ssh -t ec2-user@$ADA 'bash -lc "cd /opt/nanoclaw-v2 && \
  pnpm exec tsx setup/lib/skill-driver.ts .claude/skills/add-onecli && \
  grep -q NANOCLAW_GATEWAY_PROVIDER .env || echo NANOCLAW_GATEWAY_PROVIDER=onecli >> .env"'
```

### Phase 6 — stamp and start v2

```bash
ssh ec2-user@$ADA 'bash -lc "cd /opt/nanoclaw-v2 && pnpm run build \
  && pnpm exec tsx scripts/upgrade-state.ts set"'
```

Install the service. Two choices:

- **Let upstream write it** (`pnpm exec tsx setup/index.ts --step service`) — as
  `ec2-user` this produces a *user* unit at
  `~/.config/systemd/user/nanoclaw-v2-2e602aa0.service` and needs a live user
  systemd session, so `loginctl enable-linger ec2-user` must come first and the
  invocation needs `XDG_RUNTIME_DIR=/run/user/1000`. Note that running it as
  **root** instead writes a system unit with *no* `User=`, so the host would run
  as root and agent containers would inherit uid 0 — don't.
- **Have the IaC write a system unit** named `nanoclaw-v2-2e602aa0.service` with
  `User=ec2-user`. Keeps the current pattern (starts at boot, no login session),
  and `/update-nanoclaw` explicitly supports system-systemd mode.
  **Preferred** — see §7.2.

```bash
ssh ec2-user@$ADA 'sudo systemctl enable --now nanoclaw-v2-2e602aa0'
ssh ec2-user@$ADA 'tail -f /opt/nanoclaw-v2/logs/nanoclaw.log'
```

### Phase 7 — verify

```bash
ssh ec2-user@$ADA 'bash -lc "
  cd /opt/nanoclaw-v2
  systemctl is-active nanoclaw-v2-2e602aa0
  test -S data/ncl.sock && echo socket-ok
  bin/ncl groups list
  bin/ncl tasks list
  curl -sf http://127.0.0.1:10254/v1/health
  docker images | grep nanoclaw-agent-v2
  ss -ltnp | grep -E \":3000|:4000\"
  grep -n \"import './onecli.js';\" src/gateway-providers/installed.ts   # v2.4.0
  grep -E '^(NANOCLAW_DEFAULT_MODEL|NANOCLAW_GATEWAY_PROVIDER|ANTHROPIC_BASE_URL)=' .env
  grep -c '^ANTHROPIC_AUTH_TOKEN=' .env || echo 'auth token absent (correct)'
"'
```

Then, functionally:

- [ ] Send a real Discord message; the bot replies
- [ ] Reply inside a thread; the answer lands in the thread
- [ ] The agent remembers something from before the migration (proves the
      `continuation:claude` handoff worked)
- [ ] A container actually spawns:
      `docker ps --filter label=nanoclaw-session`
- [ ] **v2.4.0** — the agent answers with the *pinned* model, not Opus 5.5. Check
      `ncl groups config get --id <group>` and the LiteLLM log for the model name
      it was asked for. A group that answers nothing at all is the §2.12 symptom.
- [ ] `bin/ncl tasks list` shows the previously-active scheduled tasks with
      sensible next runs
- [ ] Container reaches the gateway:
      `docker run --rm --add-host=host.docker.internal:host-gateway curlimages/curl -s -o /dev/null -w '%{http_code}' http://host.docker.internal:10254/v1/health`

### Phase 8 — finish with `/migrate-from-v1`

```bash
ssh -t ec2-user@$ADA 'bash -lc "cd /opt/nanoclaw-v2 && claude /migrate-from-v1"'
```

This covers what the deterministic script cannot: granting yourself the `owner`
role (`discord:<snowflake>`), choosing `unknown_sender_policy` (the script leaves
it `public` so the smoke test passes — tighten it to `strict` or
`request_approval`), running `/migrate-memory` on the staged `CLAUDE.local.md`
files, and reconciling `container.json` mounts.

**Do not skip the policy tightening.** `public` on a Discord bot means anyone who
can see the channel can spend your Bedrock budget.

Caveat: `~/.bashrc` sets `ANTHROPIC_DEFAULT_HAIKU_MODEL` to a model the IAM
policy does not allow (§2.12). If Claude Code errors on haiku calls during this
step, add haiku to the Bedrock policy or unset that export first.

Also restore what nothing migrates:

```bash
scp -r ./backup-v1/nanoclaw ec2-user@$ADA:'~/.config/'   # mount/sender allowlists
```

and re-register MCP servers as data (UPDATE_FORK.md §4, item 3):

```bash
ssh ec2-user@$ADA 'cd /opt/nanoclaw-v2 && bin/ncl groups config add-mcp-server --name … '
```

### Phase 9 — settle

Leave v1 in place for at least one full week, including a weekend, so recurring
scheduled tasks have all fired at least once under v2. Then:

```bash
ssh ec2-user@$ADA 'sudo rm /etc/systemd/system/nanoclaw.service && sudo systemctl daemon-reload'
ssh ec2-user@$ADA 'docker rmi nanoclaw-agent:latest'
# Keep /opt/nanoclaw and /data/nanoclaw/store — the v1 DB is your only chat history (§3).
```

Resize back to `t3.medium` if v2 runs comfortably. Watch memory first: v2 runs a
Bun container per session rather than one process, so the working set is
different. Measure before shrinking.

### Rollback

At any point before Phase 9:

```bash
ssh ec2-user@$ADA 'sudo systemctl stop nanoclaw-v2-2e602aa0 && sudo systemctl disable nanoclaw-v2-2e602aa0'
ssh ec2-user@$ADA 'sudo systemctl enable --now nanoclaw'
```

v1 state was never mutated — `migrate-v2.sh` opens the v1 DB
`{ readonly: true }`. If something did go wrong at the volume level, restore the
Phase-1 snapshot and redeploy the pinned v1 ref:

```bash
cdk deploy --context nanoclawRef=v1.2.52-lovelace --context dataVolumeId=vol-<restored>
```

---

## 7.2 IaC change list (`../lovelace-ai`)

Do these as reviewable commits, in this order. `test/nanoclaw-ec2.test.ts` (633
lines of template assertions) will need updating alongside — it asserts instance
type, volume sizes, UserData contents, and the CreationPolicy.

> ### As-built (2026-09-25) — items 1, 2, 4 done; deviations noted
>
> Items 1, 2, and 4 are implemented and committed to `../lovelace-ai` (`main`).
> Two structural decisions changed the shape of the literal list below; the
> per-item notes call out where each one deviates.
>
> **Deviation A — one context-gated stack, not an always-v2 stack.** Rather than
> bump `NanoclawEc2Stack` to the v2 config outright (which would force yet
> another live-v1 instance replacement and drop v1 as a clean rollback), the
> stack takes a `deployTarget` context: `v1` (default) keeps today's config
> byte-for-byte; `deployTarget=v2` switches to the v2 config. A v1 `cdk diff` is
> clean — confirmed. The capacity numbers in item 2 apply on the v2 branch only.
> Extra context: `nanoclawV2Ref` (default `v2.4.0-lovelace`) and `freshV2`
> (green-field service auto-start per §8).
>
> **Deviation B — the v2 installer ships in a separate S3 asset.** Because
> `userDataCausesReplacement` hashes UserData (which embeds the bootstrap asset
> key), *any* change to `bootstrap/` forces a v1 replacement. So `bootstrap/`
> stays frozen (05..50) and `60-install-nanoclaw-v2.sh` lives in a new
> `bootstrap-v2/`, published + downloaded only when `deployTarget=v2`. Both
> assets unzip into `/tmp/bootstrap`; the shared 05..30 scripts come from the
> frozen v1 asset, guaranteeing identical infra on both paths.
>
> **Item 3 is intentionally NOT applied to v1** — see the item-3 note below.

**1. `lib/nanoclaw-ec2-stack.ts` — ref pinning (ship this first, on its own)**

```typescript
const nanoclawRef = app.node.tryGetContext('nanoclawRef') ?? 'v1.2.52-lovelace';
userData.addCommands(`export NANOCLAW_REF="${nanoclawRef}"`);
```

and in `50-install-nanoclaw.sh`, after the clone:

```bash
sudo -u ec2-user git -C /opt/nanoclaw fetch --tags origin
sudo -u ec2-user git -C /opt/nanoclaw checkout --detach "${NANOCLAW_REF}"
```

Note this also fixes §2.10's clone guard for the *code* — an existing checkout
now gets moved to the requested ref instead of being skipped.

**2. `lib/nanoclaw-ec2-stack.ts` — capacity**

- `T3.MEDIUM` → `T3.LARGE` (revisit after §7 Phase 9)
- root `ebs(30, …)` → `ebs(60, …)`
- data volume `gibibytes(10)` → `gibibytes(30)` (only takes effect on a
  CDK-managed volume; a reused `dataVolumeId` must be grown with
  `modify-volume` + `resize2fs`)
- `resourceSignal: { timeout: 'PT15M' }` → `'PT45M'`

**3. `bootstrap/50-install-nanoclaw.sh` — delete the source patch (§2.11)**

> **As-built: NOT applied to v1 — folded into the v2 installer instead.** Under
> Deviation B `bootstrap/` is a frozen asset: editing `50-install-nanoclaw.sh`
> changes its hash and forces a live-v1 instance replacement. The dead `node -e`
> patch is already a harmless no-op on the running v1 (it matches nothing and
> exits 0), so removing it buys nothing operationally while costing the clean-v1
> guarantee. It is left as-is. The equivalent loud assertions live in the **v2**
> installer (`bootstrap-v2/60-install-nanoclaw-v2.sh`), which is where the LLM
> endpoint + registered provider actually matter:
>
> ```bash
> grep -q '^ANTHROPIC_BASE_URL=' /opt/nanoclaw-v2/.env || { echo "FAILED: ANTHROPIC_BASE_URL missing"; exit 1; }
> grep -q "import './claude.js'" /opt/nanoclaw-v2/src/providers/index.ts || { echo "FAILED: claude provider not registered"; exit 1; }
> ```

Original intent (kept for the record): remove the `node -e` block entirely and
replace it with an assertion that the configuration it was faking is present.
Fail loudly — a silent no-op means agents come up with no LLM endpoint and you
find out from a user, not from CloudFormation.

**4. New `bootstrap/60-install-nanoclaw-v2.sh`**

Responsibilities, in order:

1. `mkdir -p /data/nanoclaw-v2/{data,groups,logs}`, chown `ec2-user`
2. Clone `$NANOCLAW_REPO` to `/opt/nanoclaw-v2`, then detach to the ref. **Resolve
   the ref to a SHA first** — `git checkout --detach <branch>` fails with
   `'--detach' cannot be used with -b` for a *branch* ref (§9 spike). Use
   `SHA=$(git rev-parse --verify "origin/$NANOCLAW_V2_REF^{commit}" || git
   rev-parse --verify "$NANOCLAW_V2_REF^{commit}"); git checkout --detach "$SHA"`.
   A tag (`v2.4.0-lovelace`) is unaffected, but keep the SHA form so a branch ref
   can't break the bootstrap.
3. Real directories + `/etc/fstab` bind mounts per §5(a), then `mount -a`.
   Make the state-volume mount idempotent for re-runs: `mountpoint -q <mnt> ||
   mount …` — `mount` returns non-zero when already mounted and aborts under
   `set -e` on an instance replacement (§9 spike).
4. `corepack enable`; `pnpm install --frozen-lockfile`; `pnpm run build`
5. Write `.env`: `ANTHROPIC_BASE_URL=http://host.docker.internal:4000`,
   **`NANOCLAW_DEFAULT_MODEL=claude-sonnet-5`** (§2.12 — without this, v2.4.0
   groups ask for Opus 5.5 and LiteLLM 400s), `DISCORD_BOT_TOKEN` from Secrets
   Manager, `ASSISTANT_NAME`, `TRIGGER_WORD`, `ONECLI_URL=http://172.17.0.1:10254`,
   `TZ`. **Do not write `ANTHROPIC_AUTH_TOKEN`** — the provider (v2.3.0) or the
   gateway (v2.4.0) contributes the placeholder itself, and a real value in `.env`
   risks tripping the driver's credential-in-env admission check. Do not set
   `NANOCLAW_FAST_MODE`.
6. **v2.4.0 — materialize the gateway (§2.4a).** This is a new, mandatory step:
   ```bash
   pnpm exec tsx setup/lib/skill-driver.ts .claude/skills/add-onecli
   grep -q "import './onecli.js';" src/gateway-providers/installed.ts \
     || { echo "FAILED: no gateway registered — host will not boot"; exit 1; }
   echo "NANOCLAW_GATEWAY_PROVIDER=onecli" >> .env
   ```
   Record the variable only *after* the skill succeeds.
7. Gateway install: read the pins from
   `.claude/skills/add-onecli/versions.json` on v2.4.0, core `versions.json` on
   v2.3.0 (§4.3), and **fail if the pin is absent** rather than defaulting to
   `latest`. Ensure the volume symlink hack is in place *before* compose creates
   the named volumes. **Two prerequisites the §9 spike proved are load-bearing —
   miss either and the gateway can't serve credentialed egress:**
   - **`app-data` ownership.** After the symlink hack but *before* compose starts
     the `onecli` service, `chown -R 1000:1000 <ebs>/onecli/app-data` — the
     container runs as `node` (uid 1000) and otherwise dies with `can't create
     /app/data/secret-encryption-key: Permission denied` (unhealthy → install
     fails). `pgdata` needs no chown.
   - **`host.docker.internal` resolution inside the gateway container.** On Linux
     the gateway compose needs `extra_hosts: ["host.docker.internal:host-gateway"]`
     on the `onecli` service, or every proxied agent→LiteLLM call fails
     (`Empty reply` / `dns error: Name does not resolve`). The skill's
     `setup.ts` (`ensureLocalGatewayHostAccess`) does this when its install path
     runs; if the bootstrap installs the gateway another way, replicate it and
     recreate the container. This is because the contributed proxy env carries
     **no `NO_PROXY`**, so LiteLLM traffic goes *through* the gateway (§9 item 2).
8. Auth step — `--step gateway` then `--step gateway-auth` on v2.4.0,
   `--step auth` on v2.3.0, with `NANOCLAW_ANTHROPIC_BASE_URL` /
   `NANOCLAW_ANTHROPIC_AUTH_TOKEN` exported
9. `bash container/build.sh` (tag is slug-derived, no collision with v1)
10. Assertions from item 3
11. `pnpm exec tsx scripts/upgrade-state.ts set` — **only if the build, the
    gateway registration, and the image acquisition all succeeded**
12. Write `/etc/systemd/system/nanoclaw-v2-<slug>.service`, deriving the slug at
    runtime rather than hardcoding it:
    ```bash
    source /opt/nanoclaw-v2/setup/lib/install-slug.sh
    UNIT="$(systemd_unit)"   # nanoclaw-v2-2e602aa0
    ```
    Unit body: `User=ec2-user`, `WorkingDirectory=/opt/nanoclaw-v2`,
    `ExecStart=/usr/bin/node dist/index.js`, `After=/Requires=` docker (LiteLLM
    is only needed once containers spawn, but keeping the ordering is harmless),
    `RequiresMountsFor=/data/nanoclaw-v2`, `Restart=always`. **Omit
    `EnvironmentFile`** — v2 reads `.env` itself via `readEnvFile`, and systemd's
    parser chokes on values systemd doesn't expect.
13. Do **not** `enable --now` on the migration path — Phase 6 does that after the
    migration has run. Gate on a context flag so the fresh-install path (§8) can
    start it and the upgrade path can't.

Everything must be idempotent; bootstrap re-runs on every instance replacement.

**5. `bootstrap/30-install-litellm.sh` — model coverage (§2.12)**

> **Reframed after the §9 spike.** Haiku coverage is **not** needed for the
> agent: v2 pins `NANOCLAW_DEFAULT_MODEL=claude-sonnet-5`, which LiteLLM serves
> and IAM permits, so a migrated group with no model of its own answers fine
> (proven end-to-end in the spike). The only surface that requests Haiku today
> is **interactive Claude Code on the host** via the `~/.bashrc`
> `ANTHROPIC_DEFAULT_HAIKU_MODEL` export, which the IAM policy does not permit
> (AccessDenied). That never touches the agent.
>
> **Cheapest fix — pin narrow (recommended for the migration):** leave LiteLLM
> and the Bedrock IAM single-model, and **remove (or correct) the stale
> `~/.bashrc` Haiku export** so interactive Claude Code stops erroring. No new
> IAM surface, no `model_list` change.
>
> **Widen (optional, post-migration):** only if you want a cheap Haiku tier
> available (interactively, or for a group you deliberately point at Haiku) —
> add it to `model_list` **and** extend the Bedrock IAM statement to the Haiku
> inference profile. Tie this to the complexity-routing question, which is
> explicitly deferred to post-migration.
>
> **`LITELLM_MASTER_KEY` — not required (spike 1).** The gateway reports
> ready/applied and the model answers with no Anthropic secret registered, so a
> master key stays *optional*, not mandatory. If ever adopted (UPDATE_FORK.md
> §5.3a): add a `nanoclaw/litellm-master-key` secret, grant read, feed it to
> `NANOCLAW_ANTHROPIC_AUTH_TOKEN` — and note the gateway then needs a matching
> host secret so its injected `Authorization` header carries the key (§9 item 2).

**6. Two new ops scripts in `bin/` — the current gap**

> **Split into two decisions.** These are day-2 ops tools, not part of standing
> up v2, and they live in the **fork's** `bin/` (shipped in the checkout,
> alongside `ada-connect.sh`), not in `../lovelace-ai`. The backup half is
> unambiguously worth having; the update half overlaps with upstream's
> `/update-nanoclaw` and is really only for scripted/simple bumps.

- `bin/nanoclaw-backup.sh` — **build it.** Stop the service, `tar` `data/`,
  `groups/`, `store/`, `.env`, and `~/.config/nanoclaw/`, to
  `/data/nanoclaw-v2/backups/nanoclaw/<ts>/`, restart. Skip
  `data/ncl.sock` (`/update-nanoclaw` omits sockets from its snapshots for the
  same reason). This is the on-demand, service-quiesced, file-level backup v1
  never had (the DLM snapshots are block-level and scheduled).
- `bin/nanoclaw-update.sh` — **decide first: build vs. just use
  `/update-nanoclaw`.** The wrapper described in `docs/upgrade-recovery.md`:
  backup → `git fetch`/`checkout <ref>` → `pnpm install` → build →
  `pnpm run migrate` → `container/build.sh` → `upgrade-state.ts set` → restart →
  health-check → roll back on failure. For anything non-trivial, prefer running
  `/update-nanoclaw` over SSH; it already does the worktree staging, skill
  refresh, and automatic rollback. A thin scripted wrapper is still useful for
  simple, unattended ref bumps — but the marker stamp (`upgrade-state.ts set`,
  §4.1) is the load-bearing step either way.

**7. README + `.kiro/specs`**

Update the operational runbook. While you're there, fix the two stale sections
the current README carries: bootstrap script numbering is `05-/10-/20-/30-/40-/50-`
(not `00-`…`03-`), and the *"Future: OneCLI"* section is wrong — OneCLI is
installed today and is mandatory under v2.

---

## 8. Fresh v2 install (Approach C / new environment)

Once the changes in §7.2 are in, a green-field deploy is:

```bash
cd ../lovelace-ai
cdk deploy \
  --context nanoclawV2Ref=v2.4.0-lovelace \
  --context freshV2=true \
  --context budgetEmail="you@example.com"
```

Bootstrap runs `05` → `60`, `60` starts the service, and then the one-time
seeding happens over SSH because it needs real identifiers:

```bash
ssh -t ec2-user@$ADA 'bash -lc "cd /opt/nanoclaw-v2 && \
  pnpm exec tsx scripts/init-first-agent.ts \
    --channel discord \
    --user-id discord:<your-user-snowflake> \
    --platform-id discord:@me:<dm-channel-id> \
    --display-name \"Michiel\" \
    --agent-name Ada \
    --role owner"'
```

`init-first-agent.ts` creates the user, grants `owner`, creates the agent group
and its folder, creates the messaging group and wiring, and hands a welcome
message to the running service over `data/ncl.sock`. **It requires the service to
be up** and fails loudly otherwise. This replaces v1's
`setup/index.ts --step register --jid dc:… --folder … --is-main`.

To import v1 state into a fresh install instead of seeding empty, you still need a
v1 tree for `migrate-v2.sh` to read:

```bash
# On the new instance, restore v1 state and give it a matching checkout
sudo tar xzf nanoclaw-v1-state.tgz -C /data/nanoclaw
git clone --branch v1.2.52-lovelace git@github.com:foxey/nanoclaw.git /opt/nanoclaw
# its committed store/groups/logs symlinks resolve to /data/nanoclaw/* — no build needed
NANOCLAW_V1_PATH=/opt/nanoclaw bash /opt/nanoclaw-v2/migrate-v2.sh
```

The v1 checkout needs no `npm install` — the migration only reads
`store/messages.db`, `groups/`, `data/sessions/`, `.env`, and
`container/skills/`. That is what makes C workable, and also why C ends up
looking a lot like B with extra steps.

---

## 9. Open items to verify before committing to a date

Ordered by how much they'd hurt if the answer is the bad one.

> ### Spike results — items 0–3 answered (2026-09-24, on a throwaway v2 stack)
>
> Run on a deliberately isolated CDK stack (`NanoclawSpikeStack`, own blank
> volume, no Discord, no budget — never touches the live stack or
> `vol-0014aca44c3193e99`) against the fork at `v2-base` (`9962a59c`,
> `v2.4.0`-equivalent), OneCLI gateway `1.41.0` + `@onecli-sh/sdk@2.2.1`, the
> same LiteLLM→Bedrock topology as production. IaC lives in `../lovelace-ai`
> (`lib/nanoclaw-spike-stack.ts`, `bootstrap-spike/`).
>
> **The v2 OneCLI credential path is viable against our unauthenticated,
> host-local LiteLLM. No LiteLLM master key is required.** Two concrete
> bootstrap gaps must be closed first (both fold into §7.2 item 4 / §5):
>
> **A. The OneCLI gateway container must be able to resolve
> `host.docker.internal`.** Out of the box its compose has no `extra_hosts`;
> inside the container `getent hosts host.docker.internal` returns nothing, and
> every proxied agent→LiteLLM call fails (`Empty reply` with no matching secret,
> `dns error: Name does not resolve` with one). Fix: `extra_hosts:
> ["host.docker.internal:host-gateway"]` on the `onecli` service, then recreate
> it. This is exactly what `.claude/skills/add-onecli/scripts/setup.ts`
> (`ensureLocalGatewayHostAccess` / `withLinuxHostGateway`) already does on
> Linux — but only when its gateway-install step runs to completion. A
> hand-rolled bootstrap that installs the gateway another way must replicate it.
>
> **B. The gateway's `app-data` volume must be owned by uid 1000 (`node`).** The
> persistence hack that symlinks `/var/lib/docker/volumes/onecli_app-data/_data`
> onto the EBS pre-creates the backing dir as `root`, but the `onecli` container
> runs as `node` (uid 1000) and dies with `can't create
> /app/data/secret-encryption-key: Permission denied` → container unhealthy →
> install fails. Fix: `chown -R 1000:1000 <ebs>/onecli/app-data` before compose
> brings the gateway up. (`pgdata` is fine — Postgres chowns its own.)
>
> With A and B in place: gateway healthy, host boots with the provider
> registered, and a real `claude-sonnet-5` completion returns 200 through the
> proxy with no Anthropic secret registered (details per item below).
>
> Not blockers, but confirmed en route: `better-sqlite3`'s ignored build script
> (pnpm `onlyBuiltDependencies`) is harmless — it loads from a prebuilt binary;
> `docker-compose v5.1.2` installs fine (the gateway's "needs ≥ 2.19" hint on
> failure is a red herring); and `git checkout --detach <branch>` fails
> (`'--detach' cannot be used with -b`) for a **branch** ref — resolve the ref to
> a SHA first (`rev-parse origin/<ref>^{commit}`). A tag ref (our
> `v2.4.0-lovelace`) is unaffected, but any branch ref in the v2 bootstrap hits
> this.

0. **✅ ANSWERED — YES.** The `/add-onecli` directives (copy `onecli.ts` /
   `onecli-files.ts`, append `import './onecli.js';` to
   `src/gateway-providers/installed.ts`, install `@onecli-sh/sdk@2.2.1`, build,
   validate) all applied cleanly; only the gateway-*container* bring-up failed,
   for the two infra reasons above (A, B) — not the skill. After fixing those and
   stamping the upgrade marker (§4.1, `scripts/upgrade-state.ts set`, otherwise
   the tripwire stops boot — confirmed), the host boots with `Gateway provider
   selected gatewayProvider="onecli"`, migrations run, `NanoClaw running`,
   `ncl.sock` present. Original text (still the procedure):
   ~~does the gateway skill apply cleanly on the EC2 instance, and does the host
   boot with it registered?~~ (§2.4, §2.4a).
1. **✅ ANSWERED — YES, ready with no Anthropic secret.** With `/v1/secrets` empty,
   `getContainerConfig({agent})` does **not** throw; it returns a full config and
   injects `ANTHROPIC_API_KEY=placeholder`. A real `/v1/messages` completion
   (`claude-sonnet-5`) returned 200 through the proxy with no Anthropic secret
   registered. So spawns do **not** throw (§2.4 fear does not materialise) and the
   **LiteLLM-master-key option stays optional, not mandatory.** A registered
   secret only matters for the credentialed-egress side (item 2, keyed case).
2. **✅ ANSWERED — YES, it intercepts; there is no `NO_PROXY` at all.**
   `getContainerConfig().env` sets both `HTTP_PROXY` and `HTTPS_PROXY` (upper- and
   lower-case) to `http://x:<agent-token>@host.docker.internal:10255`, plus
   `NODE_USE_ENV_PROXY=1` and the gateway CA (`NODE_EXTRA_CA_CERTS` /
   `SSL_CERT_FILE` / `DENO_CERT`). It contributes **no** `NO_PROXY`, so *all*
   agent egress — including plain-HTTP to `host.docker.internal:4000` — routes
   through the gateway, which MITMs it (`scheme=http`, `injections_applied=1`,
   status 200). The §2 fear was inverted: the risk is not that `NO_PROXY` excludes
   LiteLLM, it's that **everything** goes through the proxy, so the gateway *must*
   reach LiteLLM (prerequisite A). Harmless for our unauthenticated LiteLLM (the
   injected `Authorization` header is ignored); for a keyed LiteLLM a matching
   host secret is what supplies that header.
3. **✅ ANSWERED — YES (same evidence as item 2).** Under v2's driver the agent
   container reaches LiteLLM through the injected `HTTP_PROXY`; `NO_PROXY` is not
   needed and not set. Verified with a `docker run` curl (with the contributed
   proxy env + `--add-host=host.docker.internal:host-gateway`) hitting
   `/health`, `/v1/models`, and `/v1/messages` on :4000 — all 200 once
   prerequisite A is in place.
4. **Agent image build on `t3.large`** — time it and watch memory. If it OOMs or
   blows the signal timeout, the fallback is `NANOCLAW_HARDENED_IMAGE=true` with
   `NANOCLAW_AGENT_IMAGE_REF`, but note the pinned image is ~800 MB served from
   `us-east-1` with no CDN, upstream says the pull from Europe can be slower than
   building, and the NanoClaw-account path is gated behind
   `setup/registry-login.sh`. A private ECR mirror in `eu-central-1` is the
   better answer if you go that way.
5. **`versions.json` `agent-image` is a single reference, not a per-platform
   map** — confirm it is `linux/amd64` before considering the pull path. (Our
   instance is x86_64, so this is a "check, don't assume".)
6. **Does the webhook server start?** (§2.13) Discord shouldn't trigger it. Verify
   with `ss -ltnp`.
7. **`request_approval` needs a working approval delivery path.** v2's Discord
   defaults are `dm: request_approval` / `group: mention-sticky`. Confirm
   approval cards actually reach you before tightening
   `unknown_sender_policy` off `public`.
8. **Migration duration on real data** — how many groups, sessions, and JSONL
   transcripts are on the volume? Measure it against a restored snapshot on a
   scratch instance so the window is a number, not a guess.
9. **Bedrock haiku** — add to IAM + LiteLLM, or remove the `.bashrc` export
   (§2.12).
10. **v2.4.0 model default** — confirm a migrated group with no model of its own
    actually resolves to the pinned `NANOCLAW_DEFAULT_MODEL` and not Opus 5.5
    (§2.12). Cheapest check: one real message, then read the LiteLLM access log.

---

## 10. Checklist

Pre-work:
- [ ] UPDATE_FORK.md §3 (v1 frozen, `nanoclawRef` deployed) — hard prerequisite
- [ ] Base tag confirmed newest (UPDATE_FORK.md §10) — **`v2.4.0`**
- [ ] UPDATE_FORK.md §6 (`v2.4.0-lovelace` builds and tests clean)
- [x] §9 items **0**–3 answered on a scratch instance (2026-09-24 — all YES; two
      bootstrap prerequisites surfaced: gateway `app-data` chown to uid 1000, and
      `host.docker.internal:host-gateway` in the onecli compose. Folded into §7.2
      item 4 step 7.)
- [ ] §7.2 changes 1–4 merged, including the gateway-materialization step (§2.4a)
      and the `NANOCLAW_DEFAULT_MODEL` pin (§2.12); `test/nanoclaw-ec2.test.ts`
      updated; `cdk diff` reviewed

Migration window:
- [ ] Snapshot `completed`; OneCLI backup taken; allowlists + `.env` copied off
- [ ] Instance resized; disk headroom confirmed (`df -h`)
- [ ] `/opt/nanoclaw-v2` provisioned, built, slug verified as `nanoclaw-v2-2e602aa0`
- [ ] v1 stopped and disabled, unit file **kept**
- [ ] `migrate-v2.sh` run; `handoff.json` steps `1a`–`1e` all `success`
- [ ] **v2.4.0** — `/add-onecli` applied; `src/gateway-providers/installed.ts`
      imports `./onecli.js`; `NANOCLAW_GATEWAY_PROVIDER=onecli` recorded after
- [ ] `NANOCLAW_DEFAULT_MODEL` pinned; `ANTHROPIC_AUTH_TOKEN` absent from `.env`
- [ ] `upgrade-state.ts set` stamped after a green build
- [ ] v2 service enabled and active; `data/ncl.sock` present
- [ ] Phase 7 verification passed, including in-container gateway *and* LiteLLM reachability
- [ ] `/migrate-from-v1`: owner granted, `unknown_sender_policy` tightened off
      `public`, `/migrate-memory` run
- [ ] Allowlists restored; MCP servers re-registered

Post:
- [ ] One week + a weekend of clean operation, all recurring tasks fired
- [ ] v1 unit and image removed; `/data/nanoclaw/store` **kept** (only chat history)
- [ ] Instance resized back if the numbers support it
- [ ] `bin/nanoclaw-backup.sh` + `bin/nanoclaw-update.sh` committed and exercised once
- [ ] Fresh `cdk deploy` into a throwaway stack proves the v2 bootstrap works unattended
- [ ] README and `.kiro/specs` updated; stale sections fixed
