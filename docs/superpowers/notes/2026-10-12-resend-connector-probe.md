# Resend connector probe (Task 10)

Probed 2026-10-12 from a Claude Code session with the claude.ai Resend connector
(`https://mcp.resend.com/mcp`, OAuth) connected.

## Server prefix

Tool names appear as `mcp__claude_ai_Resend__<tool>`. The server segment,
lowercased, is `claude_ai_resend`. The tool's `server_match` is `resend`: the
engine matches it as a substring of the server segment, so it also covers a
locally configured server named `resend`.

## Tools

Every tool the connector exposes at probe time, marked `send` (puts mail in
the post, directly or by triggering something that does), `read`, or
`other write`.

### send

| Tool | Why it is a send |
|---|---|
| `send-email` | Single transactional email. **The `owner_notify` tool.** |
| `send-batch-emails` | Up to 100 emails, each with its own `to`/`cc`/`bcc`/`from`. |
| `send-broadcast` | Sends a broadcast to a whole segment. |
| `reply-to-inbox-thread-email` | Inboxes beta. Recipients come from the thread (`replyAll`), plus `cc`/`bcc`. |
| `forward-inbox-thread-email` | Inboxes beta. Forwards a stored message to any `to`/`cc`/`bcc`. |
| `send-inbox-draft` | Inboxes beta. Sends a stored draft to the recipients it already carries. |
| `send-event` | Fires a contact event; automations listening for it can send email. |

### read

`get-automation`, `get-automation-runs`, `get-broadcast`, `get-contact`,
`get-contact-import`, `get-contact-property`, `get-domain`, `get-domain-claim`,
`get-email`, `get-email-metrics`, `get-inbox`, `get-inbox-agent`,
`get-inbox-draft`, `get-inbox-thread`, `get-inbox-thread-email`, `get-log`,
`get-received-email`, `get-received-email-attachment`, `get-segment`,
`get-sent-email-attachment`, `get-suppression`, `get-template`,
`get-tiptap-json-content`, `get-topic`, `get-usage`, `get-webhook`,
`get-webhook-event`, `list-api-keys`, `list-broadcast-clicked-links`,
`list-broadcast-recipients`, `list-broadcasts`, `list-contact-imports`,
`list-contact-properties`, `list-contact-segments`, `list-contact-topics`,
`list-contacts`, `list-domains`, `list-emails`, `list-inbox-drafts`,
`list-inbox-labels`, `list-inbox-threads`, `list-inboxes`, `list-logs`,
`list-oauth-grants`, `list-received-email-attachments`, `list-received-emails`,
`list-segments`, `list-sent-email-attachments`, `list-suppressions`,
`list-templates`, `list-topics`, `list-webhook-event-attempts`,
`list-webhook-events`, `list-webhooks`, `search-inbox-threads`.

`get_more_tools` is a discovery tool: it asks the server for tools beyond the
current list. It sends nothing itself, but it means the tool list is **not
fixed** (see Findings).

### other write

`add-contact-to-segment`, `add-suppression`, `batch-add-suppressions`,
`batch-remove-suppressions`, `cancel-broadcast`, `cancel-email`,
`compose-broadcast`, `compose-template`, `connect-to-editor`, `create-api-key`,
`create-automation`, `create-broadcast`, `create-contact`,
`create-contact-import`, `create-contact-property`, `create-domain`,
`create-domain-claim`, `create-inbox`, `create-inbox-draft`,
`create-inbox-label`, `create-segment`, `create-template`, `create-topic`,
`create-webhook`, `disconnect-from-editor`, `duplicate-automation`,
`duplicate-broadcast`, `duplicate-template`, `manage-events`,
`publish-template`, `remove-api-key`, `remove-automation`, `remove-broadcast`,
`remove-contact`, `remove-contact-from-segment`, `remove-contact-property`,
`remove-domain`, `remove-inbox`, `remove-inbox-draft`, `remove-inbox-label`,
`remove-inbox-thread`, `remove-segment`, `remove-suppression`,
`remove-template`, `remove-topic`, `remove-webhook`, `replay-webhook-event`,
`revoke-oauth-grant`, `rotate-webhook-signing-secret`, `share-email`,
`update-api-key`, `update-automation`, `update-broadcast`, `update-contact`,
`update-contact-property`, `update-contact-topics`, `update-domain`,
`update-email`, `update-inbox`, `update-inbox-agent`, `update-inbox-draft`,
`update-inbox-label`, `update-inbox-thread`, `update-segment`,
`update-template`, `update-topic`, `update-webhook`, `verify-domain`,
`verify-domain-claim`.

Notable: `share-email` makes a public link to any sent or received email
(an exfiltration path, not a send); `create-api-key` mints account-wide keys;
`create-webhook`/`update-webhook` can push email events to any URL;
`create-automation`/`update-automation` can build flows that send.

## `send-email` input schema (verbatim)

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "properties": {
    "attachments": {"description": "Array of file attachments. Each needs filename plus one of: url or content. Max 40MB total.", "items": {"properties": {"content": {"description": "Base64-encoded file content", "type": "string"}, "contentId": {"description": "Content ID for inline images. Reference in HTML with cid:<contentId>", "type": "string"}, "contentType": {"description": "MIME type (e.g., \"application/pdf\"). Auto-derived from filename if not set", "type": "string"}, "filename": {"description": "Name of the file with extension (e.g., \"report.pdf\")", "type": "string"}, "url": {"description": "URL where the file is hosted (Resend will fetch it)", "type": "string"}}, "required": ["filename"], "type": "object"}, "type": "array"},
    "bcc": {"description": "Optional array of BCC email addresses. You MUST ask the user for this parameter. Under no circumstance provide it yourself", "items": {"format": "email", "pattern": "^[a-zA-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$", "type": "string"}, "type": "array"},
    "cc": {"description": "Optional array of CC email addresses. You MUST ask the user for this parameter. Under no circumstance provide it yourself", "items": {"format": "email", "pattern": "^[a-zA-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$", "type": "string"}, "type": "array"},
    "context": {"description": "Explain in 15-25 words, in third person, why this tool is called and how it supports the user's goal. For analytics only. You MUST describe only the abstract purpose of the tool call. NEVER include, repeat, paraphrase, or infer personal, sensitive, or identifying information from the user request or tool results, including names, emails, phone numbers, IPs, IDs, or credentials. You MUST generalize specific entities into roles such as \"a user\", \"the customer\", or \"an account\". Example: \"Retrieving a customer's recent orders to investigate a billing issue and help support determine the appropriate resolution.\"", "type": "string"},
    "conversation_id": {"description": "Pass the exact conversation_id from the server's previous response, unchanged. The server provides it on the first call — never invent one, and do not issue parallel tool calls until you have it. Keep passing the same conversation_id for the rest of the conversation, including after later user messages or on a different task; do not reset it when the user starts a new request.", "type": "string"},
    "from": {"description": "Sender email address (e.g. \"onboarding@resend.com\" or \"Acme <onboarding@resend.com>\"). You MUST ask the user for this parameter. Under no circumstance provide it yourself", "minLength": 1, "type": "string"},
    "headers": {"additionalProperties": {"type": "string"}, "description": "Optional custom email headers as key/value pairs (e.g. {\"List-Unsubscribe\": \"<https://example.com/unsubscribe>\", \"X-Entity-Ref-ID\": \"unique-id\"}). Use for one-click unsubscribe, preventing Gmail threading, or other MIME headers Resend accepts.", "propertyNames": {"type": "string"}, "type": "object"},
    "html": {"description": "HTML email content. When provided, the plain text argument MUST be provided as well.", "type": "string"},
    "idempotencyKey": {"description": "Optional unique key that prevents duplicate sends on retries (sent as the Idempotency-Key header). Use the same key when retrying the same logical email; use a new key for a different email. Max 256 characters.", "maxLength": 256, "type": "string"},
    "llm_model": {"description": "The exact model identifier you (the assistant) are running as, taken from your system prompt or environment (e.g. \"claude-opus-4-8\", \"gpt-5.2\"). Used for analytics only. If you do not know your model identifier with certainty, pass \"unknown\" — never guess.", "type": "string"},
    "replyTo": {"description": "Optional email addresses for the email readers to reply to (e.g. \"support@example.com\" or \"Support Team <support@example.com>\"). You MUST ask the user for this parameter. Under no circumstance provide it yourself", "items": {"type": "string"}, "type": "array"},
    "scheduledAt": {"description": "Optional parameter to schedule the email. This uses natural language. Examples would be 'tomorrow at 10am' or 'in 2 hours' or 'next day at 9am PST' or 'Friday at 3pm ET'.", "type": "string"},
    "subject": {"description": "Email subject line", "type": "string"},
    "tags": {"description": "Array of custom tags for tracking/analytics. Each tag has a name and value.", "items": {"properties": {"name": {"description": "Tag name (key)", "type": "string"}, "value": {"description": "Tag value", "type": "string"}}, "required": ["name", "value"], "type": "object"}, "type": "array"},
    "text": {"description": "Plain text email content", "type": "string"},
    "to": {"description": "Array of recipient email addresses (1-50 recipients)", "items": {"format": "email", "pattern": "^[a-zA-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$", "type": "string"}, "maxItems": 50, "minItems": 1, "type": "array"},
    "topicId": {"description": "Topic ID for subscription-based sending. When set, the email respects contact subscription preferences for this topic.", "type": "string"}
  },
  "required": ["to", "subject", "text", "from", "context", "llm_model"],
  "type": "object"
}
```

## Arguments of `send-email` that matter to the guard

**(a) Can add a recipient**
- `to` — array, 1–50. Pin every element to an owner binding.
- `cc`, `bcc` — arrays. Refuse.
- `headers` — free-form map. A `Cc`, `Bcc` or `To` header could add
  recipients if Resend passes it through; unverified, so refuse the whole
  argument.
- `replyTo` — adds no recipient, but redirects the owner's replies anywhere.
  Refuse (or pin to an owner binding if replies are wanted).

**(b) Can change the sender**
- `from` — required, free string, may carry a display name
  (`"Name <addr>"`). Pin to a binding on the verified domain.

**(c) Can send something other than the given body**
- `scheduledAt` — a scheduled send can later be moved by `update-email` or
  sent after the run that made it is gone. Refuse.
- `attachments` — `url` makes Resend fetch any URL; `content` carries
  arbitrary files. Refuse.
- `topicId` — ties the send to a contact topic's subscription rules. Refuse.
- No template, draft, audience, segment or batch argument on this tool; those
  live on other tools, which stay denied.

**Harmless:** `subject`, `text`, `html`, `tags`, `idempotencyKey` (worth
using for retries), and the analytics-only `context`, `llm_model`,
`conversation_id`.

## Domain verification

Read-only: `list-domains` (status per domain) and `get-domain` (one domain,
with DNS records). At probe time `list-domains` returned one domain,
`notify.webspenser.com`: status `verified`, sending enabled, receiving
disabled, region `us-east-1`.

## Team members

The operator checked resend.com/pricing: the free plan sets no strict limit
on team members, so the client can own the account and add Webspenser as a
second member. The plan's assumption holds.

## Findings for Task 11

1. **Allow exactly `send-email`.** Every other send tool in the list above
   (`send-batch-emails`, `send-broadcast`, the three Inboxes-beta tools,
   `send-event`) has its own recipient path and must stay denied.
2. **Pin** `to` and `from`. **Refuse** `cc`, `bcc`, `replyTo`, `headers`,
   `scheduledAt`, `attachments`, `topicId`.
3. **The tool list moves.** `get_more_tools` and the Inboxes beta show the
   server adds tools over time. The allow list must name tools exactly
   (already the 7.0 rule); never allow by prefix or pattern.
4. **The tool descriptions tell the model to ask the user for `from`, `cc`,
   `bcc` and `replyTo`.** In an unattended routine nobody can answer; the
   skill must state that these come from the bound values, and the guard is
   what enforces it.
5. `context`, `llm_model` and `conversation_id` are required or expected on
   every call. `conversation_id` comes from the server's first response, so
   the first call of a run cannot carry it; the skill must not invent one.
