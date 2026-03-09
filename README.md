# Gmail Secretary

This repo is a host-side Gmail skill for OpenClaw. It is designed for a single trusted user mailbox first, using local scripts plus `gog` for Gmail access.

## Recommended path

For your own Gmail or Google Workspace inbox, use the current `gog`-based setup first.

Why:

- It matches the existing scripts in this repo.
- It keeps Gmail access on the gateway host.
- It avoids building first-party OAuth and token refresh code before the workflow is proven.

The agent should never authenticate to Google directly. It should only run local scripts that produce and consume normalized JSON files in `cache/`.

## How authorization works

Authorization is between your Google account and the local `gog` client on the machine where the OpenClaw gateway runs.

Flow:

1. You create a Google OAuth Desktop App client.
2. You register that OAuth client with `gog`.
3. You sign in to your Google account once and grant Gmail access.
4. `gog` stores and refreshes the token locally.
5. OpenClaw runs the repo scripts on that same host.

## One-time setup on your OpenClaw host

### 1. Install `gog`

```bash
brew install steipete/tap/gogcli
gog --help
```

### 2. Create Google OAuth credentials

In Google Cloud Console:

1. Create or select a project.
2. Enable the Gmail API.
3. Go to `APIs & Services -> Credentials`.
4. Create an `OAuth 2.0 Client ID`.
5. Choose `Desktop app`.
6. Download the credentials JSON file.

If prompted for the consent screen:

- Choose the Google account owner you want to use.
- Add your own Gmail/Workspace account as a test user if required.

### 3. Register the client with `gog`

```bash
gog auth credentials /path/to/credentials.json
```

### 4. Authorize access to your inbox

```bash
gog auth add your-email@yourdomain.com --services gmail
```

For a headless machine:

```bash
GOG_KEYRING_PASSWORD="your-secret" gog auth add your-email@yourdomain.com --services gmail --manual --force-consent
```

### 5. Create the local skill config

Create `gmail-secretary.env` in the OpenClaw workspace root:

```bash
GOG_ACCOUNT="your-email@yourdomain.com"
GOG_KEYRING_PASSWORD="your-keyring-password"
```

Rules:

- Use only `KEY=value`.
- Supported keys are `GOG_ACCOUNT`, `GOG_KEYRING_PASSWORD`, and optional `GOG_BIN`.
- Restrict access with `chmod 600 gmail-secretary.env`.
- Do not commit this file.

### 6. Make sure OpenClaw runs on the same host

Your OpenClaw setup needs to run these scripts on the gateway host, not inside an isolated environment that cannot see your local credentials or `gog` installation.

Operational expectations:

- `tools.exec.host` should point to the gateway host.
- The PATH for that host should include the location of `gog`.
- The host should be able to read `gmail-secretary.env`.

## Verify your setup

From the repo root on the gateway host:

```bash
./scripts/check-gmail-auth.sh
```

This checks:

- `node` exists
- `gog` exists
- the config file is present
- permissions are restricted
- `gog auth list` works
- the inbox can be queried

## Normal workflow

For the exact OpenClaw handoff and a ready-to-use agent prompt, see `docs/openclaw-agent-workflow.md`.

### 1. Build the inbox index

```bash
./scripts/triage-and-draft.sh
```

This writes:

- `cache/gmail-inbox-index.json`
- `cache/gmail-inbox-summaries.json`

### 2. Optionally fetch full threads

Create `cache/gmail-thread-fetch-requests.json`, then run:

```bash
./scripts/fetch-thread-details.sh
```

This writes:

- `cache/gmail-thread-details.json`

### 3. Have the agent write the triage plan

The agent should write:

- `cache/gmail-triage-plan.json`

### 4. Apply labels and create drafts

```bash
./scripts/apply-labels.sh
./scripts/create-drafts.sh
```

These write:

- `cache/gmail-label-apply-report.json`
- `cache/gmail-drafts.md`
- `cache/gmail-draft-results.json`

## Safety rules

- Never auto-send email.
- Prefer labels over destructive mailbox actions.
- Fetch full message bodies only for selected threads.
- Keep generated mailbox-derived files local.

## Future direction

If you later want to replace `gog` with a first-party Gmail API integration, keep these file contracts stable:

- `cache/gmail-inbox-index.json`
- `cache/gmail-thread-details.json`
- `cache/gmail-triage-plan.json`

See `docs/direct-gmail-api-migration.md` for the migration map.
