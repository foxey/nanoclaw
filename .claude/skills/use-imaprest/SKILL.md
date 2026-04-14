---
name: use-imaprest
description: Use the imaprest MCP tools to read, search, send, and manage emails. Reference guide for all available tools and common workflows. Use when the user asks you to interact with email via imaprest.
---

# imaprest — Email MCP Reference

imaprest is an IMAP/SMTP REST API exposed as MCP tools. Use this guide when you have `mcp__imaprest__*` tools available and need to work with email.

## Available Tools

### Mailboxes
- **`list_mailboxes`** — List all folders/mailboxes for the configured account

### Reading
- **`list_messages`** — List messages in a mailbox with optional filters (`unseen`, `from`, `since`, `sort`, `cursor`, `limit`)
- **`search_messages`** — Full-text search across a mailbox (`q`, `from`, `subject`, `since`, `before`, `unseen`, `sort`)
- **`get_message`** — Fetch the full content of a single message by UID
- **`get_thread`** — Retrieve all messages in a conversation by `Message-ID`
- **`download_attachment`** — Download a specific attachment by index (returns base64)

### Sending
- **`send_email`** — Compose and send a new email (supports attachments)
- **`reply_to_message`** — Reply to an existing message by UID (supports attachments)

### Managing
- **`mark_message`** — Mark a single message as `seen`/`unseen`
- **`bulk_mark_messages`** — Mark multiple messages as `seen`/`unseen` and/or `flagged`/`unflagged` (max 100 UIDs)
- **`delete_message`** — Move a message to Trash
- **`move_message`** — Move a single message to another mailbox
- **`copy_message`** — Copy a single message to another mailbox
- **`bulk_move_messages`** — Move multiple messages at once (max 100 UIDs)
- **`bulk_copy_messages`** — Copy multiple messages at once (max 100 UIDs)

## Pagination

`list_messages` and `search_messages` use cursor-based pagination:

- `limit` — page size, default 50, max 100
- `cursor` — UID to page from (exclusive; returns messages older than this UID)
- `sort` — `desc` (newest first, default) or `asc` (oldest first)

To page through results, pass `nextCursor` from the response as the next `cursor`.

## Attachments

Attachments are passed as base64-encoded content:

```json
{
  "filename": "report.pdf",
  "contentType": "application/pdf",
  "content": "<base64>"
}
```

When downloading, `download_attachment` returns raw base64 content. Use the attachment `index` (zero-based) from the message's `attachments` array.

## Common Workflows

### Check unread messages

```
list_messages(mailbox: "INBOX", unseen: true, limit: 20)
```

### Read a specific message

```
get_message(mailbox: "INBOX", uid: 1234)
```

### Find emails from someone

```
search_messages(mailbox: "INBOX", from: "boss@example.com", limit: 10)
```

### Reply to a message

```
reply_to_message(mailbox: "INBOX", uid: 1234, text: "Thanks!")
```

### Send a new email

```
send_email(
  to: ["alice@example.com"],
  subject: "Hello",
  text: "Plain text body"
)
```

### Archive a batch of messages

```
bulk_move_messages(mailbox: "INBOX", uids: [10, 11, 12], destination: "Archive")
```

### Mark messages as read

```
bulk_mark_messages(mailbox: "INBOX", uids: [10, 11, 12], seen: true)
```

## Tips

- Always call `list_mailboxes` first if you're unsure of folder names — mailbox names are case-sensitive and vary by provider (e.g. `INBOX`, `Sent`, `[Gmail]/Sent Mail`).
- Prefer `search_messages` over `list_messages` when filtering by subject or full-text — it uses dedicated IMAP search rather than client-side filtering.
- When paging, `sort: "asc"` with cursor gives you messages in chronological order.
- Attachments are returned inline in `get_message` as base64 strings in the `attachments` array. Use `download_attachment` only when you need the raw binary.
