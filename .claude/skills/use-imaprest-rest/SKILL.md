---
name: use-imaprest-rest
description: Use the imaprest REST API directly with curl or Python — bypasses MCP/OneCLI TLS issues by calling the HTTP endpoint directly. Useful when mcp__imaprest__* tools are unavailable or broken.
---

# Use imaprest REST API (curl / Python)

This skill shows how to call the imaprest REST API directly, without MCP. Useful when the MCP transport has TLS issues (common with OneCLI + undici), when you want to script email operations in Python, or when you need to inspect raw responses.

**REST base URL**: `http://localhost:3000` (host) or `http://172.17.0.1:3000` (from a Docker container)

**Discover the full API**: `GET /openapi.json` returns an OpenAPI 3.0 spec for all endpoints.

---

## Authentication

Every request (except `/health` and `/openapi.json`) requires mail credentials.

**Option A — HTTP Basic auth (recommended for curl/Python):**

```bash
# Encode credentials
AUTH=$(echo -n "user@example.com:password" | base64)
# Use in header
curl -H "Authorization: Basic $AUTH" http://localhost:3000/mailboxes
```

**Option B — Custom headers (used by MCP/OneCLI injection):**

```bash
curl -H "X-Mail-User: user@example.com" \
     -H "X-Mail-Password: password" \
     http://localhost:3000/mailboxes
```

Both methods work; Basic auth is simpler for direct use and visible in the OpenAPI spec.

---

## Mail server headers

Include IMAP headers for read operations, SMTP headers for sending:

| Header | Default | Example |
|--------|---------|---------|
| `X-IMAP-Host` | *(required)* | `imap.example.com` |
| `X-IMAP-Port` | `993` | `993` |
| `X-IMAP-TLS` | `true` | `true` |
| `X-SMTP-Host` | *(required for send)* | `smtp.example.com` |
| `X-SMTP-Port` | `587` | `465` |
| `X-SMTP-TLS` | `false` | `true` |

Define shared header args in shell to avoid repetition:

```bash
BASE_URL="http://localhost:3000"
AUTH=$(echo -n "user@example.com:password" | base64)
IMAP_HEADERS=(
  -H "Authorization: Basic $AUTH"
  -H "X-IMAP-Host: imap.example.com"
)
SMTP_HEADERS=(
  "${IMAP_HEADERS[@]}"
  -H "X-SMTP-Host: smtp.example.com"
  -H "X-SMTP-Port: 465"
  -H "X-SMTP-TLS: true"
)
```

---

## Common operations

### List mailboxes

```bash
curl -s "${IMAP_HEADERS[@]}" "$BASE_URL/mailboxes"
```

### List messages

```bash
# Optional query params: ?limit=20&page=1&unseen=true
curl -s "${IMAP_HEADERS[@]}" "$BASE_URL/mailboxes/INBOX/messages?limit=10"
```

### Search messages

```bash
curl -s "${IMAP_HEADERS[@]}" \
  "$BASE_URL/mailboxes/INBOX/messages/search?query=from%3Aexample.com"
```

### Get a message (full body + attachments list)

```bash
curl -s "${IMAP_HEADERS[@]}" "$BASE_URL/mailboxes/INBOX/messages/1234"
```

### Mark as read / set flags

```bash
curl -s -X PATCH "${IMAP_HEADERS[@]}" \
  -H "Content-Type: application/json" \
  -d '{"flags": {"seen": true}}' \
  "$BASE_URL/mailboxes/INBOX/messages/1234"
```

### Delete a message

```bash
curl -s -X DELETE "${IMAP_HEADERS[@]}" \
  "$BASE_URL/mailboxes/INBOX/messages/1234"
```

### Move a message

```bash
curl -s -X POST "${IMAP_HEADERS[@]}" \
  -H "Content-Type: application/json" \
  -d '{"destination": "Archive"}' \
  "$BASE_URL/mailboxes/INBOX/messages/1234/move"
```

### Download an attachment

```bash
# index is 0-based from the attachments array in the message response
curl -s "${IMAP_HEADERS[@]}" \
  "$BASE_URL/mailboxes/INBOX/messages/1234/attachments/0" \
  -o attachment.pdf
```

### Send an email

```bash
curl -s -X POST "${SMTP_HEADERS[@]}" \
  -H "Content-Type: application/json" \
  -d '{"to": [{"address": "recipient@example.com", "name": "Recipient"}], "subject": "Hello", "text": "Plain text body", "html": "<p>HTML body</p>"}' \
  "$BASE_URL/send"
```

---

## Python usage

```python
import urllib.request
import urllib.parse
import json
import base64
import ssl
import os

BASE_URL = "http://localhost:3000"

# Encode credentials
user = "user@example.com"
password = "password"
auth = base64.b64encode(f"{user}:{password}".encode()).decode()

HEADERS = {
    "Authorization": f"Basic {auth}",
    "X-IMAP-Host": "imap.example.com",
    "Content-Type": "application/json",
}

def api(path, method="GET", body=None):
    url = BASE_URL + path
    data = json.dumps(body).encode() if body else None
    req = urllib.request.Request(url, data=data, headers=HEADERS, method=method)
    with urllib.request.urlopen(req) as resp:
        return json.loads(resp.read())

# List mailboxes
mailboxes = api("/mailboxes")
print([m["path"] for m in mailboxes])

# List unread messages in INBOX
messages = api("/mailboxes/INBOX/messages?limit=10&unseen=true")
for msg in messages.get("messages", []):
    print(f"[{msg['uid']}] {msg['subject']} — {msg['from'][0]['address']}")

# Get full message
msg = api("/mailboxes/INBOX/messages/1234")
print(msg["text"])
```

### Through OneCLI proxy (from a Docker container)

When running inside a container that has the OneCLI proxy configured, use it for imaprest calls too — Basic auth works without MCP header injection:

```python
proxy = os.environ.get("HTTPS_PROXY", "")
if proxy:
    proxy_handler = urllib.request.ProxyHandler({"http": proxy})
    ctx = ssl.create_default_context(cafile=os.environ.get("SSL_CERT_FILE"))
    opener = urllib.request.build_opener(proxy_handler, urllib.request.HTTPSHandler(context=ctx))
    urllib.request.install_opener(opener)
# Then call api() as above — works for http:// URLs without TLS issues
```

**Why curl works when MCP/undici does not:** curl uses GET-style forwarding for `http://` URLs through a proxy; Node.js/undici always uses HTTP CONNECT tunneling, which triggers OneCLI's TLS MITM and fails for plain HTTP backends.

---

## OpenAPI spec

Fetch the full spec for all endpoints, parameters, and response schemas:

```bash
curl -s http://localhost:3000/openapi.json | python3 -m json.tool | less
```

Or from a container:

```bash
curl -s http://172.17.0.1:3000/openapi.json
```

The spec documents all security schemes, request/response formats, and is suitable for import into API clients like Insomnia, Postman, or Bruno.
