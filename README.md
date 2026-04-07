# Webhook Notifications plugin for Koha

This plugin enables Koha to forward message/notice data to a webhook endpoint for processing and sending via external services.

## Features

- OAuth2 authentication (client credentials flow)
- Configurable payload format (full enriched data or minimal IDs)
- Support for all Koha notice types
- Optional inbound API for asynchronous webhook workflows
- Archive/logging for debugging

## Downloading

From the [release page](https://github.com/springshare/koha-plugin-webhook-notifications/releases) you can download the latest release in `kpz` format.

## Installation

This plugin requires no special installation beyond the standard Koha plugin installation process.

## Configuration

### Required Environment Variables

The following environment variables must be set for the plugin to function:

| Variable | Description |
|----------|-------------|
| `WEBHOOK_AUTH_URL` | OAuth2 token endpoint (e.g., AWS Cognito) |
| `WEBHOOK_CLIENT_ID` | OAuth2 client ID |
| `WEBHOOK_CLIENT_SECRET` | OAuth2 client secret |
| `WEBHOOK_NOTICE_URL` | Webhook endpoint URL for sending notices |

### Optional Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `WEBHOOK_CUSTOMER_ID` | Customer ID sent in the `customer-id` header (required by some APIs) | Not set |
| `WEBHOOK_ARCHIVE_PATH` | Directory to store copies of sent notifications | `/var/lib/koha/<instance>/webhook_notifications_archive` |
| `WEBHOOK_TEST_MODE` | Set to `1` to generate JSON without sending or updating message status | Not set |
| `WEBHOOK_VERBOSE` | Set to `1` for verbose logging output | Not set |

### Plugin Configuration (Admin UI)

Additional settings are available in the Koha plugin configuration:

- **Payload Format**: Choose between full enriched data or minimal IDs only
- **Archive Directory**: Override the default archive path
- **Skip Overdue Calls**: Option to skip phone calls for overdues if patron has email/SMS

## Security

OAuth2 credentials are securely stored in encrypted form using Koha's encryption system (AES-256). Credentials can be configured via the plugin's admin interface or through environment variables in `koha-conf.xml`. When configured via `koha-conf.xml`, credentials are automatically migrated to encrypted system preferences during plugin install or upgrade. Client secrets are masked for security in the admin interface.

## Authentication Flow

The plugin uses OAuth2 client credentials flow:

1. Plugin requests access token from `WEBHOOK_AUTH_URL` using client credentials
2. Token is used in `Authorization: Bearer <token>` header for notice requests
3. Notices are POSTed to `WEBHOOK_NOTICE_URL` with optional `customer-id` header

## Payload Formats

### Full Format (default)

Sends complete enriched data including patron details, item information, bibliographic data, etc.

### Minimal Format

Sends only identifiers, useful when the receiving service will fetch details itself:

```json
{
    "notice_type": "HOLD",
    "transport_type": "email",
    "message_id": 12345,
    "patron_id": 67890,
    "hold_id": 1053025
}
```

## Notice Templates

To send a message via webhook instead of having Koha process and send the notice locally, the message content must be a YAML blob of key/value pairs. The only required key is `webhook: yes`.

### Digest notices (`----`) and multiple YAML stanzas

[Koha digest notices](https://manual.koha-community.org/) queue a single message and **append** content until `process_message_queue.pl` runs. Repeating parts of the letter often use Koha’s **`----` block** rules (a line of four or more dashes separating sections).

**How the plugin parses content**

1. If the **entire** message body is valid YAML (including [multi-document YAML](http://yaml.org/spec/1.2/spec.html#id28023445) with multiple `---` documents), it is loaded as usual.
2. If the body contains lines of **four or more dashes** on their own (digest-style boundaries), the plugin splits on those lines and runs the YAML loader on **each segment**. Valid YAML mappings are collected from the segments (plain prose or HTML outside YAML is ignored).
3. Every mapping with `webhook: yes` is **merged** into one logical request: `checkout` / `checkouts`, `hold` / `holds`, `old_checkout`, and `old_hold` identifiers are combined (comma-separated values are trimmed and de-duplicated). **`patron`**, **`library`**, **`item`**, **`biblio`**, and **`biblioitem`** are taken from the first stanza that sets them. The plugin then sends **one** OAuth POST and marks the message **sent** once on success.

**Recommended template shape for digests**

Prefer **one** YAML mapping with a **comma-separated list** of issue or hold IDs so the accumulated body stays easy to read and machine-parseable:

```yaml
---
webhook: yes
checkouts: [% FOREACH c IN checkouts %][% c.issue_id %],[% END %]
---
```

Do **not** repeat `checkout:` twice in the same mapping (duplicate keys are invalid YAML); use `checkouts` with multiple IDs instead. The same idea applies to `holds` for multi-hold digests.

After merge, `old_checkout` and `old_hold` may be passed as comma-separated IDs when several digest stanzas are merged.

### Available Keys

| Key | Description |
|-----|-------------|
| `webhook` | Required. Must be `yes` to enable webhook processing |
| `patron` | borrowers.borrowernumber |
| `biblio` | biblio.biblionumber |
| `biblioitem` | biblioitems.biblioitemnumber |
| `item` | items.itemnumber |
| `library` | branches.branchcode |
| `checkout` | issues.issue_id (auto-imports patron, library, item, biblio, biblioitem) |
| `checkouts` | Comma-delimited list of issues.issue_id |
| `old_checkout` | old_issues.issue_id (for check-in notices) |
| `hold` | reserves.reserve_id |
| `holds` | Comma-delimited list of reserves.reserve_id |
| `old_hold` | old_reserves.reserve_id (for cancelled holds) |

### Example Notice Templates

**CHECKOUT:**
```yaml
---
webhook: yes
checkout: [% checkout.id %]
library: [% branch.id %]
---
```

**RENEWAL:**
```yaml
---
webhook: yes
checkout: [% checkout.id %]
library: [% branch.id %]
---
```

**CHECKIN:**
```yaml
---
webhook: yes
old_checkout: [% old_checkout.issue_id %]
patron: [% borrower.borrowernumber %]
library: [% branch.id %]
---
```

**HOLD:**
```yaml
---
webhook: yes
hold: [% hold.id %]
---
```

**HOLDDGST:**
```yaml
---
webhook: yes
hold: [% hold.id %]
---
```

**HOLD_REMINDER:**
```yaml
---
webhook: yes
holds: [% FOREACH h IN holds %][% h.id %],[% END %]
---
```

**HOLD_CANCELLATION:**
```yaml
---
webhook: yes
old_hold: [% hold.id %]
library: [% branch.id %]
patron: [% borrower.id %]
---
```

**CANCEL_HOLD_ON_LOST:**
```yaml
---
webhook: yes
old_hold: [% hold.id %]
library: [% branch.id %]
patron: [% borrower.id %]
---
```

**PREDUE:** (requires Koha bug 29100)
```yaml
---
webhook: yes
patron: [% borrower.id %]
checkout: [% checkout.issue_id %]
---
```

**PREDUEDGST:**
```yaml
---
webhook: yes
patron: [% borrower.id %]
checkouts: [% FOREACH c IN checkouts %][% c.issue_id %],[% END %]
---
```

**DUE:**
```yaml
---
webhook: yes
checkout: [% checkout.issue_id %]
---
```

**DUEDGST:**
```yaml
---
webhook: yes
checkouts: [% FOREACH c IN checkouts %][% c.issue_id %],[% END %]
---
```

**AUTO_RENEWALS:**
```yaml
---
webhook: yes
checkout: [% checkout.id %]
---
```

**AUTO_RENEWALS_DGST:**
```yaml
---
webhook: yes
checkouts: [% FOREACH c IN checkouts %][% c.issue_id %],[% END %]
---
```

**OVERDUE NOTICES:**
```yaml
---
webhook: yes
checkouts: [% FOREACH o IN overdues %][% o.id %],[% END %]
---
```

**MEMBERSHIP_EXPIRY:**
```yaml
---
webhook: yes
patron: [% borrower.borrowernumber %]
---
```

**WELCOME:**
```yaml
---
webhook: yes
patron: [% borrower.id %]
library: [% branch.id %]
---
```

## Inbound API (Optional)

For asynchronous webhook workflows, the plugin provides API endpoints that external services can call to update message status in Koha:

### Update Message Status
```
POST /api/v1/contrib/webhook_notifications/message/{message_id}/status
Query Parameters:
  - status (required): 'sent' or 'failed'
  - subject (optional): Update message subject
  - content (optional): Update message content
```

### Update Message Content
```
POST /api/v1/contrib/webhook_notifications/message/{message_id}/content
Query Parameters:
  - content (required): New message content
  - subject (optional): New message subject
```

These endpoints are useful when your webhook service processes messages asynchronously and needs to report delivery status back to Koha.
