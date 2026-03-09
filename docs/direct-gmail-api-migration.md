# Direct Gmail API Migration

This document maps the current `gog`-based transport layer to a future direct Gmail API integration while preserving the triage contracts that the OpenClaw agent already uses.

## Goal

Keep the agent-facing JSON contracts stable while replacing only the Gmail transport and auth layer.

Contracts to preserve:

- `cache/gmail-inbox-index.json`
- `cache/gmail-thread-details.json`
- `cache/gmail-triage-plan.json`

If those files stay stable, the prompt and reasoning loop can stay mostly unchanged.

## Current transport boundary

Today the repo uses `gog` for all Gmail operations:

- [scripts/triage-and-draft.sh](../scripts/triage-and-draft.sh)
- [scripts/fetch-thread-details.sh](../scripts/fetch-thread-details.sh)
- [scripts/apply-labels.sh](../scripts/apply-labels.sh)
- [scripts/create-drafts.sh](../scripts/create-drafts.sh)

These scripts already separate:

- Gmail access
- normalized JSON output
- agent reasoning
- label/draft mutation

That is the part to preserve.

## Proposed replacement files

If you migrate away from `gog`, add a small first-party Gmail adapter such as:

- `scripts/lib/google-auth.js`
- `scripts/lib/gmail-client.js`
- `scripts/auth/login-gmail.sh`

Responsibilities:

- `google-auth.js`
  - Load client credentials
  - Run OAuth login/bootstrap
  - Store and refresh tokens
- `gmail-client.js`
  - List messages/threads
  - Fetch thread details
  - List/create labels
  - Modify thread labels
  - Create/update drafts
- `login-gmail.sh`
  - User-facing bootstrap command for first authorization

## Script-by-script replacement map

### `scripts/triage-and-draft.sh`

Current dependency:

- `gog gmail messages search ... --json`

Future direct Gmail API behavior:

- Use `users.messages.list` or `users.threads.list`
- Fetch the latest message metadata needed for:
  - `threadId`
  - `messageId`
  - `subject`
  - `from`
  - `date`
  - `snippet`
  - `labelIds`
  - `hasUnread`

Keep output stable:

- `cache/gmail-inbox-index.json`
- `cache/gmail-inbox-summaries.json`

### `scripts/fetch-thread-details.sh`

Current dependency:

- `gog gmail thread get <threadId> --json`

Future direct Gmail API behavior:

- Use `users.threads.get`
- Normalize each message into the existing shape:
  - `messageId`
  - `threadId`
  - `from`
  - `to`
  - `cc`
  - `bcc`
  - `date`
  - `subject`
  - `snippet`
  - `bodyText`
  - `bodyTextTruncated`

Keep output stable:

- `cache/gmail-thread-details.json`

### `scripts/apply-labels.sh`

Current dependency:

- `gog gmail labels list`
- `gog gmail labels create`
- `gog gmail labels modify`

Future direct Gmail API behavior:

- Use `users.labels.list`
- Use `users.labels.create`
- Use `users.threads.modify`

Keep input stable:

- `cache/gmail-triage-plan.json`

Keep output stable:

- `cache/gmail-label-apply-report.json`

### `scripts/create-drafts.sh`

Current dependency:

- `gog gmail drafts create`
- `gog gmail drafts update`

Future direct Gmail API behavior:

- Use `users.drafts.create`
- Use `users.drafts.update`
- Build RFC 2822 / MIME raw draft payloads as needed

Keep input stable:

- `cache/gmail-triage-plan.json`

Keep output stable:

- `cache/gmail-drafts.md`
- `cache/gmail-draft-results.json`

## Auth changes

Moving off `gog` means the repo now owns Google auth.

You will need to implement:

- OAuth Desktop App client setup
- Auth bootstrap flow
- Refresh token storage
- Token refresh logic
- Token revocation/error handling

For a single-user local assistant, use:

- OAuth 2.0 user auth
- offline access / refresh token
- host-local secure storage

Do not change the trust model:

- The user authorizes the local host
- The agent does not talk directly to Google
- The host scripts remain the only Gmail boundary

## Suggested scope order

If you build the direct adapter later, implement in this order:

1. Read-only inbox index generation
2. Full thread fetch
3. Label read/create/modify
4. Draft create/update

That keeps the riskiest user-visible mutation steps until after the read path is stable.

## Risks introduced by direct Gmail API

- You own token security.
- You own refresh and retry behavior.
- You own MIME draft formatting details.
- You own Google client dependency and version maintenance.

## Recommendation

Do not migrate yet unless you specifically want to own the Gmail transport layer.

For a single-user OpenClaw deployment, the current `gog` path remains the practical default. Migrate only when the benefits of first-party control outweigh the added auth and maintenance burden.
