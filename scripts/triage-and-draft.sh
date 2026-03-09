#!/usr/bin/env bash
set -euo pipefail

# Resolve workspace root from script path (so we don't rely on HOME when gateway runs without shell env)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
WORKSPACE="${OPENCLAW_WORKSPACE:-$WORKSPACE_ROOT}"

# Load GOG vars from file if not in environment (gateway often has no GOG_* when not started from your shell)
if [[ -z "${GOG_ACCOUNT:-}" || -z "${GOG_KEYRING_PASSWORD:-}" ]]; then
  for envfile in "$WORKSPACE_ROOT/gmail-secretary.env" \
                 "${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/gmail-secretary.env"; do
    if [[ -r "$envfile" ]]; then
      set -a
      source "$envfile"
      set +a
      break
    fi
  done
fi

GOG_BIN="${GOG_BIN:-gog}"
ACCOUNT="${GOG_ACCOUNT:?Set GOG_ACCOUNT and create workspace/gmail-secretary.env (see skill SKILL.md)}"
export GOG_KEYRING_PASSWORD="${GOG_KEYRING_PASSWORD:?Set GOG_KEYRING_PASSWORD in workspace/gmail-secretary.env}"

CACHE="$WORKSPACE/cache"
INBOX_CACHE="$CACHE/gmail-inbox-raw.json"
SUMMARIES_OUT="$CACHE/gmail-inbox-summaries.json"
mkdir -p "$CACHE"

# Step 1: Fetch inbox
"$GOG_BIN" gmail messages search \
  'in:inbox (is:unread OR newer_than:2d)' \
  --max 20 \
  --account "$ACCOUNT" \
  --json > "$INBOX_CACHE"

# Step 2: Extract summaries for LLM classification
node -e "
const fs=require('fs');
const raw=JSON.parse(fs.readFileSync('$INBOX_CACHE','utf8'));
const msgs=Array.isArray(raw)?raw:(raw?.messages||raw?.items||[]);
const out=msgs.slice(0,12).map((m,i)=>{
  function pick(o,ks){for(const k of ks){if(o&&o[k]!=null)return o[k]}return null}
  function hdr(o,n){const hs=o?.payload?.headers||o?.headers;if(Array.isArray(hs)){const h=hs.find(x=>(x?.name||'').toLowerCase()===n.toLowerCase());return h?.value||null}return null}
  const subj=hdr(m,'Subject')||pick(m,['subject'])||'(no subject)';
  const from=hdr(m,'From')||pick(m,['from'])||'(unknown)';
  const snip=(pick(m,['snippet','text','preview'])||'').replace(/\s+/g,' ').trim().slice(0,200);
  const id=pick(m,['id','messageId'])||'';
  const threadId=pick(m,['threadId'])||id;
  const date=hdr(m,'Date')||pick(m,['date','internalDate'])||'';
  return {i,id,threadId,subj,from,snip,date};
});
fs.writeFileSync('$SUMMARIES_OUT',JSON.stringify(out,null,2));
console.log('Extracted '+out.length+' email summaries');
"

echo "Inbox fetched. Ready for agent classification."
