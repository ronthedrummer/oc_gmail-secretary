---
name: gmail-secretary
description: Gmail triage assistant using the main agent (OpenAI) for metadata-first triage, selective thread fetches, label application, and draft replies (uses gog CLI; never auto-sends).
metadata:
  {"openclaw": {"always": true}}
---

# Gmail Secretary

## Recommended architecture

For a single mailbox, this skill uses **user OAuth** through `gog` and keeps Gmail access on the trusted host machine. The agent should reason over normalized JSON files, not over direct Gmail API calls.

If this grows into a shared inbox or multi-user Workspace tool, revisit the auth model and likely move to a service account plus domain-wide delegation or a dedicated backend.

## Trust boundary

Treat this skill as a narrow host-side Gmail bridge:

- `gog` runs on the gateway host and is the only component that talks to Gmail.
- The agent reads and writes normalized files in `cache/`.
- Raw Gmail API output should stay ephemeral whenever possible.
- `gmail-secretary.env` is parsed as plain `KEY=value` data. It is **not** sourced as shell code.

Persisted local artifacts:

- `cache/gmail-inbox-index.json`: metadata-first triage input.
- `cache/gmail-thread-details.json`: selected full-thread context only.
- `cache/gmail-triage-plan.json`: structured agent decisions.
- `cache/gmail-draft-results.json`: draft creation results.
- `cache/gmail-drafts.md`: human-readable draft summary.
- `cache/gmail-label-apply-report.json`: label mutation report.
- `cache/gmail-voice-reference.md`: local drafting-style reference.

Do not commit any of the files above.

## Setup & Gmail auth

Do this once before using the skill.

If you want a user-facing setup walkthrough tailored to the OpenClaw gateway host, start with `README.md`.

### 1. Install gog

```bash
brew install steipete/tap/gogcli
gog --help
```

### 2. Create Google OAuth credentials

1. Open [Google Cloud Console](https://console.cloud.google.com/) -> APIs & Services -> Credentials.
2. Create project (or pick one) -> Create credentials -> **OAuth 2.0 Client ID**.
3. If prompted, configure the OAuth consent screen (External, add your Gmail as test user).
4. Application type: **Desktop app**. Download the JSON (for example `credentials.json`).

### 3. Register credentials and add your account

```bash
gog auth credentials /path/to/credentials.json
gog auth add your-email@gmail.com --services gmail
```

For a headless machine:

```bash
GOG_KEYRING_PASSWORD="your-secret" gog auth add your-email@gmail.com --services gmail --manual --force-consent
```

### 4. Create `gmail-secretary.env`

Create `gmail-secretary.env` in the OpenClaw workspace root (preferred) or `~/.openclaw/`:

```bash
GOG_ACCOUNT="your-email@gmail.com"
GOG_KEYRING_PASSWORD="your-keyring-password"
```

Rules:

- Use only `KEY=value` entries.
- Supported keys are `GOG_ACCOUNT`, `GOG_KEYRING_PASSWORD`, and optional `GOG_BIN`.
- Restrict access with `chmod 600 gmail-secretary.env`.
- Do not add shell commands, backticks, or substitutions; the parser rejects them.

### 5. Verify

```bash
export GOG_ACCOUNT="your-email@gmail.com"
export GOG_KEYRING_PASSWORD="your-keyring-password"
gog auth list
gog gmail messages search "in:inbox" --max 1 --account "$GOG_ACCOUNT" --json
```

Or run the repo health check:

```bash
./scripts/check-gmail-auth.sh
```

### 6. OpenClaw runtime notes

- Keep exec on the host machine (`tools.exec.host: "gateway"`).
- Ensure the host PATH can find `gog`.
- If the CLI works manually but the skill does not, the usual causes are a missing `gmail-secretary.env` or exec running outside the gateway host context.

## Safety rules (non-negotiable)

- Never send email automatically. Only create drafts and summaries.
- Prefer labels over moving or deleting mail.
- Fetch full thread bodies only for selected threads that need deeper reasoning.
- Keep the voice reference style-focused and local-only.

## Labels

Use only these labels:

- Urgent
- Needs Reply
- Waiting On
- Read Later
- Receipt / Billing
- Admin / Accounts

## Files

Paths are relative to the OpenClaw workspace:

- `cache/gmail-inbox-index.json`: metadata-first inbox index.
- `cache/gmail-inbox-summaries.json`: compatibility array for older prompts.
- `cache/gmail-thread-fetch-requests.json`: thread detail fetch requests.
- `cache/gmail-thread-details.json`: selected full-thread context.
- `cache/gmail-triage-plan.json`: structured triage and draft plan.
- `cache/gmail-label-apply-report.json`: label mutation report.
- `cache/gmail-drafts.md`: generated draft summary.
- `cache/gmail-draft-results.json`: raw draft creation results.
- `cache/gmail-triage.md`: optional human digest written by the agent.
- `cache/gmail-voice-reference.md`: local style reference from Sent mail.

## Scripts

- `scripts/check-gmail-auth.sh`: verify host-side `gog`, config loading, and inbox access in one command.
- `scripts/triage-and-draft.sh`: fetch inbox metadata and write the triage index.
- `scripts/fetch-thread-details.sh`: fetch full thread context for requested thread IDs.
- `scripts/apply-labels.sh`: validate the triage plan, ensure labels exist, and apply them.
- `scripts/create-drafts.sh`: validate the triage plan and create or update Gmail drafts.
- `scripts/build-voice-reference.sh`: build a local voice reference from recent Sent mail.

## Future migration

If you later want to replace `gog` with a first-party Gmail API adapter, keep the current JSON contracts stable and see `docs/direct-gmail-api-migration.md`.

## Agent workflow

Classification uses the main OpenClaw agent.

For a more explicit host-script to agent handoff, plus a ready-to-use prompt outline, see `docs/openclaw-agent-workflow.md`.

### Step 1. Build the inbox index

Run:

```bash
./scripts/triage-and-draft.sh
```

Read `cache/gmail-inbox-index.json`. It contains one item per thread with:

- `threadId`
- `messageId`
- `subject`
- `from`
- `date`
- `snippet`
- `labelIds`
- `hasUnread`

### Step 2. Fetch deeper context only when needed

If a thread needs deeper reasoning, write `cache/gmail-thread-fetch-requests.json` as either:

```json
["thread-id-1", "thread-id-2"]
```

or:

```json
[
  {"threadId": "thread-id-1", "reason": "Need full body to draft a reply"}
]
```

Then run:

```bash
./scripts/fetch-thread-details.sh
```

Read `cache/gmail-thread-details.json` for the selected full-thread context.

### Step 3. Write the triage plan

Write JSON to `cache/gmail-triage-plan.json` using this shape:

```json
{
  "generatedAt": "2026-03-08T12:00:00Z",
  "items": [
    {
      "threadId": "thread-id",
      "messageId": "latest-message-id",
      "subject": "Re: Example",
      "summary": "Short user-facing summary.",
      "labels": ["Needs Reply"],
      "action": "reply",
      "draft": {
        "subject": "Re: Example",
        "body": "Thanks for the update. I can do Tuesday afternoon.",
        "replyToMessageId": "latest-message-id",
        "quote": true
      }
    }
  ]
}
```

Rules:

- `action` must be `none`, `review`, or `reply`.
- Use only the labels listed above.
- `summary` should be concise and user-facing.
- Include `draft` only when you want a Gmail draft created or updated.
- When drafting a reply, prefer `replyToMessageId`.

Legacy compatibility: `scripts/apply-labels.sh` still accepts the old `cache/gmail-triage-labels.json` format, but new work should use `cache/gmail-triage-plan.json`.

### Step 4. Apply labels

Run:

```bash
./scripts/apply-labels.sh
```

This validates the plan, creates missing labels, applies labels, and writes `cache/gmail-label-apply-report.json`.

### Step 5. Create drafts

Run:

```bash
./scripts/create-drafts.sh
```

This validates the plan, creates or updates drafts, and writes:

- `cache/gmail-drafts.md`
- `cache/gmail-draft-results.json`

## Classification context

Apply inbox-specific context when classifying:

- Newsletters and promos -> Read Later
- Account security, password, or verification mail -> Admin / Accounts
- Time-sensitive or action-required mail -> Urgent or Needs Reply

## Summary rules

- If the subject contains `Mansfield Business Alliance — Invoice payment received`, summarize as `MBA Invoice paid - [business_name]` when the business name is available.
