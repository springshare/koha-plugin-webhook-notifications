# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.8] - 2026-07-13
### Added
- Payloads over 3MB are gzip-compressed and sent as `application/octet-stream`, so
  the webhook doesn't send enormous payloads. Smaller payloads are
  unchanged (plain JSON). Needs the matching `ppregisterfilenotices` update (BAUL3-1789).

## [1.0.7] - 2026-06-23
### Fixed
- Prefixed plugin API `operationId`s (`WebHookUpdateMessageStatus`,
  `WebHookUpdateMessageContent`) to avoid collisions with other plugins/core
  routes sharing the generic `updateMessageStatus` / `updateMessageContent` names.

## [1.0.6] - 2026-06-17
### Fixed
- **Client secret no longer clobbered on save.** The configure form pre-fills the
  secret field with a masked placeholder (`••••••••••••`), never the real secret.
  Saving the form while changing any unrelated setting (archive dir, payload
  format, the skip-overdue toggle) submitted that placeholder back, and the save
  path stored it verbatim — overwriting the real `client_secret` with the mask and
  breaking OAuth2 authentication. Submissions equal to the placeholder (or empty)
  are now treated as "unchanged" and the stored secret is preserved. A genuinely
  retyped secret still replaces the old one.

## [1.0.5] - 2026-06-02
### Added
- Cancellation reason description included in hold data sent to the webhook.

### Fixed
- Strip pound (`#`) comments and wrapped continuation lines from notice YAML before
  parsing, so commented-out content no longer corrupts the payload.

## [1.0.4] - 2026-05-01
### Fixed
- Correct formatting of checkout digest (DGST) notices.
- README clarifications for notice types and digest shapes.

## [1.0.3] - 2026-04-28
### Added
- YAML parsing and merging for digest notices (`HOLDDGST`, `PREDUEDGST`, `DUEDGST`,
  `AUTO_RENEWALS_DGST`), with documented YAML structure and hold/checkout merging.

### Fixed
- Handle newline breaks in digest notices that previously broke parsing.

## [1.0.2] - 2026-02-20
### Fixed
- Do not attempt to decrypt credentials when none are configured.
- Do not re-decode an already-unmarshalled credentials syspref (decryption bug).

## [1.0.1] - 2026-01
### Added
- OAuth2 credential configuration form in the plugin settings.
- Secure, encrypted credential storage via `Koha::Encryption` (AES-256) as an
  encrypted system preference, replacing plain-text storage in koha-conf.xml.
- Automatic migration of credentials from koha-conf.xml on install/upgrade.

## [1.0.0] - 2025-12-03
### Changed
- **BREAKING**: Restructured the MessageBee plugin into a generic
  WebhookNotifications plugin — replaced SFTP upload with an OAuth2 + HTTP webhook
  (REST) transport, changed the YAML trigger to `webhook: yes`, and renamed the
  API namespace to `/webhook_notifications/`.

### Added
- Configurable payload format (full enriched data or minimal IDs only).
- Optional `customer-id` header support.
