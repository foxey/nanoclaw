---
name: add-imaprest
description: Deploy the imaprest Docker service and configure it as an MCP email server for one or more nanoclaw groups. Gives those groups IMAP/SMTP access via mcp__imaprest__* tools.
---

# Add imaprest Email Integration

This skill deploys the imaprest Docker service and wires it up as an MCP server for the nanoclaw groups you choose.

**No nanoclaw code changes are required.** MCP integration is purely configuration: add a `mcpServers` entry to each group's `settings.json`.

## Phase 1: Pre-flight

### Check if imaprest-mcp is already running

```bash
docker ps --format '{{.Names}}' | grep imaprest
```

If `imaprest-mcp` appears, the Docker service is already up — skip to Phase 3.

### Find the imaprest repo on disk

```bash
find ~ /opt /srv /home -maxdepth 4 -name "docker-compose.yml" 2>/dev/null \
  | xargs grep -l "imaprest" 2>/dev/null \
  | head -5
```

Note the directory — call it `$IMAPREST_DIR`. If nothing is found, continue to Phase 2 to clone it.

## Phase 2: Deploy imaprest

### Clone the repo (if not present)

```bash
git clone https://github.com/foxey/imaprest.git ~/imaprest
IMAPREST_DIR=~/imaprest
```

If it was already found above, just set the variable:

```bash
IMAPREST_DIR=<path from Phase 1>
```

### Configure credentials

Ask for the mail account details and create `$IMAPREST_DIR/.env`:

```
MAIL_USER=<email address>
MAIL_PASSWORD=<email password>
MAIL_IMAP_HOST=<imap hostname>
MAIL_IMAP_PORT=993
MAIL_IMAP_TLS=true
MAIL_SMTP_HOST=<smtp hostname>
MAIL_SMTP_PORT=465
MAIL_SMTP_TLS=true
```

Common port defaults: IMAP 993 (TLS) or 143 (STARTTLS); SMTP 465 (TLS) or 587 (STARTTLS). Adjust to match the mail provider.

### Start the containers

```bash
cd "$IMAPREST_DIR" && docker compose up -d
```

This starts two services:
- **imaprest** — REST API on `localhost:3000`
- **imaprest-mcp** — MCP server bound to `172.17.0.1:3001` (Docker gateway IP, reachable from nanoclaw containers)

### Verify health

```bash
sleep 3
curl -sf http://172.17.0.1:3001/health && echo "MCP: OK" || echo "MCP: FAIL"
curl -sf http://localhost:3000/health    && echo "REST: OK" || echo "REST: FAIL"
```

If health fails, check container logs:

```bash
cd "$IMAPREST_DIR"
docker compose logs imaprest-mcp --tail 30
docker compose logs imaprest --tail 30
```

## Phase 3: Configure nanoclaw groups

### List registered groups

```bash
ls /workspace/project/data/sessions/
```

Show the available group folders and ask which ones should have email access. Each folder name matches a registered nanoclaw group (e.g. `discord_general`, `whatsapp_main`).

### Add the MCP config to each chosen group

For each group folder, the file to update is:

```
/workspace/project/data/sessions/<folder>/.claude/settings.json
```

This file already contains an `env` section created by nanoclaw. Add `mcpServers` alongside it without touching the existing content. Use Python to merge safely:

```python
import json, os

# Edit this list:
groups = ["discord_general"]  # add more folders as needed

imaprest_config = {
    "type": "http",
    "url": "http://172.17.0.1:3001/mcp"
}

base = "/workspace/project/data/sessions"
for folder in groups:
    path = os.path.join(base, folder, ".claude", "settings.json")
    with open(path) as f:
        settings = json.load(f)
    settings.setdefault("mcpServers", {})["imaprest"] = imaprest_config
    with open(path, "w") as f:
        json.dump(settings, f, indent=2)
        f.write("\n")
    print(f"Updated {path}")
```

If the write fails with a permission error (EROFS), run the same commands directly on the nanoclaw host.

### Verify the resulting settings

```bash
cat /workspace/project/data/sessions/<folder>/.claude/settings.json
```

Expected output:

```json
{
  "env": {
    "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1",
    "CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD": "1",
    "CLAUDE_CODE_DISABLE_AUTO_MEMORY": "0"
  },
  "mcpServers": {
    "imaprest": {
      "type": "http",
      "url": "http://172.17.0.1:3001/mcp"
    }
  }
}
```

Both `env` and `mcpServers` must be present.

## Phase 4: Verify

The `mcp__imaprest__*` tools become available in the configured groups **on the next agent invocation** — the agent runner reads `settings.json` at container startup.

Tell the user:

> imaprest MCP is now configured for: **[list the groups]**
>
> The email tools will be available from the next message. Try asking me to check your inbox!

## Troubleshooting

### MCP container not reachable at `172.17.0.1:3001`

The MCP service binds to the Docker bridge gateway (`172.17.0.1`), only reachable from other Docker containers on the default bridge network.

Test reachability from the nanoclaw container:

```bash
curl -sf http://172.17.0.1:3001/health
```

From the host, use `localhost:3001` instead. If the nanoclaw container uses a non-default Docker network, it may not share the `172.17.0.1` gateway — in that case, adjust the URL in `docker-compose.yml` or connect both containers to the same network.

### imaprest containers not starting

```bash
cd "$IMAPREST_DIR"
docker compose logs --tail 40
```

Common causes: `.env` missing or malformed, port 3001 already in use, Docker daemon not running.

### Authentication errors from IMAP/SMTP

Verify credentials are correct for the mail provider. Some providers require an app-specific password rather than the main account password. Check container logs:

```bash
docker logs imaprest --tail 30
```

If credentials are wrong, edit `.env` and restart:

```bash
cd "$IMAPREST_DIR" && docker compose restart
```

### Removing imaprest from a group

```python
import json
path = "/workspace/project/data/sessions/<folder>/.claude/settings.json"
with open(path) as f:
    s = json.load(f)
s.get("mcpServers", {}).pop("imaprest", None)
with open(path, "w") as f:
    json.dump(s, f, indent=2)
    f.write("\n")
print("Removed imaprest from", path)
```
