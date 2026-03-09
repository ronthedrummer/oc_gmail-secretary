---
name: gmail-secretary
description: Gmail triage assistant using the main agent (OpenAI) for classification, label application, and draft replies (uses gog CLI; never auto-sends).
metadata:
  {"openclaw": {"always": true}}
---

# Gmail Secretary

## Setup & Gmail auth

Do this once before using the skill.

### 1. Install gog

```bash
brew install steipete/tap/gogcli
gog --help
```

### 2. Create Google OAuth credentials

1. Open [Google Cloud Console](https://console.cloud.google.com/) → APIs & Services → Credentials.
2. Create project (or pick one) → Create credentials → **OAuth 2.0 Client ID**.
3. If prompted, configure the OAuth consent screen (External, add your Gmail as test user).
4. Application type: **Desktop app**. Download the JSON (e.g. `credentials.json`).

### 3. Register credentials and add your account

```bash
# Point gog at your client secret (copy to ~/.config/gogcli/)
gog auth credentials /path/to/credentials.json

# Add your Gmail account and request Gmail scope
gog auth add your-email@gmail.com --services gmail
```

A browser window opens; sign in and allow access. For a headless/server machine use:

```bash
GOG_KEYRING_PASSWORD="your-secret" gog auth add your-email@gmail.com --services gmail --manual --force-consent
```

Then open the URL it prints, approve, and paste the authorization code back.

### 4. Set GOG variables (required for the agent)

The gateway process usually **does not** inherit your shell’s environment, so `GOG_ACCOUNT` and `GOG_KEYRING_PASSWORD` are often missing when the agent runs the skill. Use a **env file** so the scripts can load them:

1. Create **`gmail-secretary.env` in your OpenClaw workspace root** (e.g. `~/.openclaw/workspace/gmail-secretary.env`). The scripts resolve this path from the script location, so it works even when `HOME` is not what you expect. Copy from `skills/gmail-secretary/gmail-secretary.env.example` and fill in your values.
   ```bash
   GOG_ACCOUNT="your-email@gmail.com"
   GOG_KEYRING_PASSWORD="your-keyring-password"
   ```
2. Restrict access: **`chmod 600 .../workspace/gmail-secretary.env`**
3. The workspace `.gitignore` already includes `gmail-secretary.env`; do not commit this file.

The scripts look for the env file in the workspace root first, then in `~/.openclaw/`. Prefer the workspace file so the path is always found.

**Why it works for others but not you:** Many people start the gateway from a terminal where they’ve run `export GOG_ACCOUNT=...` and `export GOG_KEYRING_PASSWORD=...` (e.g. in `~/.zshrc`). The gateway then inherits those. If you start the gateway from Cursor, launchd, or similar, it has no GOG vars, so the skill needs the env file in the workspace.

### 5. Verify

```bash
export GOG_ACCOUNT="your-email@gmail.com"
export GOG_KEYRING_PASSWORD="your-keyring-password"
gog auth list
gog gmail messages search "in:inbox" --max 1 --account "$GOG_ACCOUNT" --json
```

If that returns one message (or an empty list), auth is working. Then run from the workspace:

```bash
cd ~/.openclaw/workspace/skills/gmail-secretary
./scripts/triage-and-draft.sh
```

### 6. When the agent runs the skill (OpenClaw chat)

- **Env file in workspace:** Create `gmail-secretary.env` in the workspace root (step 4). The scripts look there first so the agent can run gog even when the gateway was not started from your shell.

- **Exec on host:** In `openclaw.json`, set `tools.exec.host` to `"gateway"` so exec runs on the same machine as the gateway (not in a sandbox). The script then sees your real filesystem and can read the workspace env file and run `gog` from your PATH (or `pathPrepend`).

- **PATH:** If `gog` is from Homebrew, `tools.exec.pathPrepend: ["/opt/homebrew/bin"]` in `openclaw.json` ensures exec finds it. On Intel Mac use `/usr/local/bin` if needed.

If the CLI works but the agent does not, the usual cause is either (1) no env file where the script can find it (use workspace root), or (2) exec running in a context that cannot see the file (use `tools.exec.host: "gateway"`).

---

## Safety rules (non-negotiable)
- **Never send email automatically.** Only create drafts + summaries.
- Prefer **labels** over moving/deleting.
- Keep the voice reference **style-focused** (patterns + a few short redacted snippets), not a full archive.

## Labels (user-friendly)
Use/create these labels:
- Urgent
- Needs Reply
- Waiting On
- Read Later
- Receipt / Billing
- Admin / Accounts

## Classification: Main agent (OpenAI)
Classification uses the **main OpenClaw agent** (your configured OpenAI model). No separate Haiku or other provider.
- `scripts/triage-and-draft.sh` fetches inbox → writes summaries to `cache/gmail-inbox-summaries.json`
- You (or a tool) ask the main agent to read `cache/gmail-inbox-summaries.json`, classify each email, and write results to `cache/gmail-triage-labels.json`
- `scripts/apply-labels.sh` reads classification results and applies Gmail labels via `gog`

### Classification output format
Write JSON to `cache/gmail-triage-labels.json` as an array of objects. Each object: `threadId` (string), `label` or `labels` (string or array), optional `needsReply` (boolean). Use only the labels listed above.

### Classification context (customize for your inbox)
When classifying, apply context that fits the user (e.g. work vs personal, domains, newsletters). Examples:
- Newsletters / promos → Read Later
- Account security / password / verification → Admin / Accounts
- Time-sensitive or action-required → Urgent or Needs Reply as appropriate

### Summary / notification rules (special handling)
When summarizing or reporting emails, use these formats so the user gets a short, consistent line:

- **Mansfield Business Alliance invoice paid:** If the subject contains `Mansfield Business Alliance — Invoice payment received`, summarize as: **MBA Invoice paid - [business_name]** where `[business_name]` is the business name taken from the email body (e.g. from the payment or merchant line). If no clear business name is in the body/snippet, use "MBA Invoice paid" or "MBA Invoice paid - (see email)".

## Files
- Voice reference (auto-maintained): `references/voice.md`
- Draft queue (generated): `cache/gmail-drafts.md`
- Triage digest (generated): `cache/gmail-triage.md`
- Inbox summaries (intermediate): `cache/gmail-inbox-summaries.json`
- Classification results: `cache/gmail-triage-labels.json`

Paths are relative to the OpenClaw workspace (e.g. `~/.openclaw/workspace`).

## Scripts
- Build/refresh voice reference from Sent mail:
  - `scripts/build-voice-reference.sh` (samples last 50 sent messages)
- Fetch inbox + extract summaries:
  - `scripts/triage-and-draft.sh`
- Apply labels from classification:
  - `scripts/apply-labels.sh`

## Workflow
1) Run `triage-and-draft.sh` — fetches inbox, extracts summaries to `cache/gmail-inbox-summaries.json`
2) Ask the main agent to classify emails from that file and write `cache/gmail-triage-labels.json`
3) Run `apply-labels.sh` — applies labels to Gmail threads via `gog`
4) Optionally ask the agent to write a triage digest to `cache/gmail-triage.md` for nudges
