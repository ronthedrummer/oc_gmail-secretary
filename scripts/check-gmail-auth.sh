#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

function check_command() {
  local name="$1"
  if ! command -v "$name" >/dev/null 2>&1; then
    echo "[fail] Missing command: $name" >&2
    return 1
  fi
  echo "[ok] Found command: $name"
}

check_command node

if [[ -n "${GOG_BIN:-}" ]]; then
  check_command "$GOG_BIN"
else
  check_command gog
fi

gs_require_config

ENV_PATH="$(gs_resolve_env_path || true)"
if [[ -n "$ENV_PATH" ]]; then
  echo "[ok] Found config file: $ENV_PATH"
  PERMS="$(stat -f '%Sp' "$ENV_PATH")"
  if [[ "$PERMS" != "-rw-------" ]]; then
    echo "[warn] Expected permissions 600 on $ENV_PATH, found $PERMS" >&2
  else
    echo "[ok] Config permissions are restricted"
  fi
else
  echo "[warn] No gmail-secretary.env file found; relying on current environment" >&2
fi

echo "[ok] Loaded Gmail account: $GOG_ACCOUNT"

if ! "$GOG_BIN" auth list >/dev/null 2>&1; then
  echo "[fail] gog auth list failed. Check your OAuth credentials and keyring password." >&2
  exit 1
fi
echo "[ok] gog auth list succeeded"

if ! "$GOG_BIN" gmail messages search "in:inbox" --max 1 --account "$GOG_ACCOUNT" --json >/dev/null 2>&1; then
  echo "[fail] Inbox query failed for $GOG_ACCOUNT" >&2
  echo "       Re-run 'gog auth add $GOG_ACCOUNT --services gmail' or verify your keyring password." >&2
  exit 1
fi
echo "[ok] Inbox access verified for $GOG_ACCOUNT"

cat <<EOF

Next steps:
1. ./scripts/triage-and-draft.sh
2. Review cache/gmail-inbox-index.json
3. Optionally create cache/gmail-thread-fetch-requests.json and run ./scripts/fetch-thread-details.sh
4. Have the agent write cache/gmail-triage-plan.json
5. Run ./scripts/apply-labels.sh and ./scripts/create-drafts.sh
EOF
