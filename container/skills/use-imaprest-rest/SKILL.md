---
name: use-imaprest-rest
description: Use the imaprest REST API directly with curl or Node — bypasses MCP/OneCLI TLS issues by calling the HTTP endpoint directly. Useful when mcp__imaprest__* tools are unavailable or broken.
---

# Use imaprest REST API (curl / Node)

This skill shows how to call the imaprest REST API directly, without MCP. Useful when the MCP transport has TLS issues (common with OneCLI + undici), when you want to script email operations in Node, or when you need to inspect raw responses.

**REST base URL**: `http://172.17.0.1:3000/imaprest`

**Discover the full API**: `GET /imaprest/openapi.json` returns an OpenAPI 3.0 spec for all endpoints.

---

## Authentication

Every request (except `/health` and `/openapi.json`) requires Basic Auth credentials. **OneCLI injects the `Authorization: Basic ...` header automatically** — no manual credential handling is needed. Just make requests to the base URL through the OneCLI proxy and auth is added transparently.

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
BASE_URL="http://172.17.0.1:3000/imaprest"
IMAP_HEADERS=(
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

## Node usage

OneCLI injects Basic Auth automatically when requests route through its proxy. Node 22 has global `fetch`; honor the proxy env vars with undici's `ProxyAgent` when present:

```js
import { ProxyAgent } from 'undici';

const BASE_URL = 'http://172.17.0.1:3000/imaprest';

const HEADERS = {
  'X-IMAP-Host': 'imap.example.com',
  'Content-Type': 'application/json',
};

const proxy = process.env.HTTPS_PROXY || process.env.HTTP_PROXY || '';
const dispatcher = proxy ? new ProxyAgent(proxy) : undefined;

async function api(apiPath, method = 'GET', body) {
  const res = await fetch(BASE_URL + apiPath, {
    method,
    headers: HEADERS,
    body: body ? JSON.stringify(body) : undefined,
    dispatcher,
  });
  return res.json();
}

// List mailboxes
const mailboxes = await api('/mailboxes');
console.log(mailboxes.map((m) => m.path));

// List unread messages in INBOX
const messages = await api('/mailboxes/INBOX/messages?limit=10&unseen=true');
for (const msg of messages.messages ?? []) {
  console.log('[' + msg.uid + '] ' + msg.subject + ' — ' + msg.from[0].address);
}

// Get full message
const msg = await api('/mailboxes/INBOX/messages/1234');
console.log(msg.text);
```

**Why curl works when MCP/undici does not:** curl uses GET-style forwarding for `http://` URLs through a proxy; Node.js/undici always uses HTTP CONNECT tunneling, which triggers OneCLI's TLS MITM and fails for plain HTTP backends.

---

## OpenAPI spec

Fetch the full spec for all endpoints, parameters, and response schemas:

```bash
curl -s http://172.17.0.1:3000/imaprest/openapi.json | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.stringify(JSON.parse(s),null,2)))' | less
```

The spec documents all security schemes, request/response formats, and is suitable for import into API clients like Insomnia, Postman, or Bruno.
