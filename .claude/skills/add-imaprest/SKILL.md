---
name: add-imaprest
description: Deploy the imaprest Docker service and configure nanoclaw groups to access email via the REST API. OneCLI injects Basic Auth credentials at request time.
---

# Add imaprest Email Integration

This skill deploys the imaprest Docker service and enables email access for nanoclaw groups via the REST API at `http://172.17.0.1:3000/imaprest`. OneCLI injects Basic Auth credentials — no credentials are stored in group config.

**No nanoclaw code changes are required.** The agent uses the REST API directly with curl.

## Phase 1: Pre-flight

### Check if imaprest is already running

```bash
docker ps --format '{{.Names}}' | grep imaprest
```

If an imaprest container appears, skip to Phase 3.

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

### Configure mail server settings

Ask for the mail server details and create `$IMAPREST_DIR/.env`. Credentials (username/password) are **not** stored here — they are injected by OneCLI at runtime.

```
MAIL_IMAP_HOST=<imap hostname>
MAIL_IMAP_PORT=993
MAIL_IMAP_TLS=true
MAIL_SMTP_HOST=<smtp hostname>
MAIL_SMTP_PORT=465
MAIL_SMTP_TLS=true
```

Common port defaults: IMAP 993 (TLS) or 143 (STARTTLS); SMTP 465 (TLS) or 587 (STARTTLS). Adjust to match the mail provider.

### Check port reachability

Before starting the container, verify the IMAP and SMTP ports are reachable from this host:

```bash
source "$IMAPREST_DIR/.env"
for entry in "IMAP $MAIL_IMAP_HOST $MAIL_IMAP_PORT" "SMTP $MAIL_SMTP_HOST $MAIL_SMTP_PORT"; do
  read -r label host port <<< "$entry"
  if nc -zw5 "$host" "$port" 2>/dev/null; then
    echo "$label ($host:$port): reachable"
  else
    echo "$label ($host:$port): BLOCKED"
  fi
done
```

If a port shows as **BLOCKED**, resolve the firewall issue before continuing:
- Check outbound rules: `sudo ufw status` / `sudo iptables -L OUTPUT -n`
- Some ISPs block port 465 outbound — try switching to 587 (STARTTLS) in `.env`
- Confirm the mail server hostname is correct and DNS resolves: `nslookup $MAIL_IMAP_HOST`

### Start the container

```bash
cd "$IMAPREST_DIR" && docker compose up -d
```

This starts the **imaprest** REST API, reachable at `http://172.17.0.1:3000/imaprest` from nanoclaw agent containers.

### Verify health

```bash
curl -sf http://172.17.0.1:3000/imaprest/health && echo "OK" || echo "FAIL"
```

If health fails, check container logs:

```bash
cd "$IMAPREST_DIR" && docker compose logs --tail 30
```

## Phase 3: Install the container skill

The `use-imaprest-rest` skill provides curl and Python examples for all email operations. Copy it into `container/skills/` so it is synced into every agent container at startup:

```bash
mkdir -p /opt/nanoclaw/container/skills/use-imaprest-rest
cp /opt/nanoclaw/.claude/skills/use-imaprest-rest/SKILL.md \
   /opt/nanoclaw/container/skills/use-imaprest-rest/SKILL.md
```

Verify it is in place:

```bash
ls /opt/nanoclaw/container/skills/use-imaprest-rest/SKILL.md
```

## Phase 4: Verify from a nanoclaw agent

The agent accesses email via the REST API directly using curl. The OpenAPI spec documents all available endpoints:

```bash
curl -s http://172.17.0.1:3000/imaprest/openapi.json
```

OneCLI injects the `Authorization: Basic ...` header automatically. The agent uses the `use-imaprest-rest` skill to construct curl calls with the appropriate `X-IMAP-Host` / `X-SMTP-Host` headers.

Tell the user:

> imaprest is now running and the `use-imaprest-rest` skill is available in all agent containers.
>
> Try asking your agent to check your inbox!

## Troubleshooting

### imaprest not reachable at `172.17.0.1:3000`

The service binds to the Docker bridge gateway (`172.17.0.1`), only reachable from other Docker containers on the default bridge network.

Test reachability from the nanoclaw container:

```bash
curl -sf http://172.17.0.1:3000/imaprest/health
```

From the host, use `localhost:3000` instead. If the nanoclaw container uses a non-default Docker network, it may not share the `172.17.0.1` gateway — adjust the URL in `docker-compose.yml` or connect both containers to the same network.

### imaprest container not starting

```bash
cd "$IMAPREST_DIR" && docker compose logs --tail 40
```

Common causes: `.env` missing or malformed, port 3000 already in use, Docker daemon not running.

### Authentication errors from IMAP/SMTP

OneCLI injects the `Authorization: Basic ...` header. If you're getting auth errors, verify the OneCLI credential entry for imaprest is correct. Check container logs:

```bash
docker logs imaprest --tail 30
```
