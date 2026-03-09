#!/usr/bin/env bash
# Apply labels from agent classification results
# Input: cache/gmail-triage-labels.json (written by the agent)
# Format: [{"index":0,"id":"...","threadId":"...","label":"...","needsReply":true/false}, ...]
set -euo pipefail

# Resolve workspace root from script path
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
WORKSPACE="${OPENCLAW_WORKSPACE:-$WORKSPACE_ROOT}"

# Load GOG vars from file if not in environment
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
ACCOUNT="${GOG_ACCOUNT:?Set GOG_ACCOUNT and create workspace/gmail-secretary.env}"
export GOG_KEYRING_PASSWORD="${GOG_KEYRING_PASSWORD:?Set GOG_KEYRING_PASSWORD in workspace/gmail-secretary.env}"

LABELS_FILE="$WORKSPACE/cache/gmail-triage-labels.json"

if [ ! -f "$LABELS_FILE" ]; then
  echo "No labels file found at $LABELS_FILE"
  exit 1
fi

LABELS_FILE="$LABELS_FILE" GOG_BIN="$GOG_BIN" ACCOUNT="$ACCOUNT" node -e "
const fs=require('fs');
const cp=require('child_process');
const path=require('path');
const account=process.env.ACCOUNT;
const gogBin=process.env.GOG_BIN||'gog';
const labelsPath=process.env.LABELS_FILE;

const labels=JSON.parse(fs.readFileSync(labelsPath,'utf8'));

function run(args){
  try{return cp.execFileSync(gogBin,args,{encoding:'utf8',stdio:['ignore','pipe','pipe']})}catch{return ''}
}

// Ensure labels exist (skill defaults; add more in LABELS if needed)
const LABELS=['Urgent','Needs Reply','Waiting On','Read Later','Receipt / Billing','Admin / Accounts'];
let existing=[];
try{const t=run(['gmail','labels','list','--account',account,'--json']);const o=JSON.parse(t);existing=(o.labels||o||[]).map(x=>x.name).filter(Boolean)}catch{}
for(const name of LABELS){if(!existing.includes(name)){try{run(['gmail','labels','create',name,'--account',account,'--json'])}catch{}}}

// Apply — supports both formats:
// Old: {label:\"X\", needsReply:bool}
// New: {labels:[\"X\",\"Y\"], action:\"review\"|\"reply\"|\"none\"}
let applied=0;
for(const l of labels){
  if(!l.threadId)continue;
  let toApply=[];
  if(Array.isArray(l.labels)){toApply=l.labels.filter(x=>LABELS.includes(x))}
  else if(l.label&&LABELS.includes(l.label)){toApply=[l.label]}
  const needsReply=l.needsReply||(l.action==='reply');
  if(needsReply&&!toApply.includes('Needs Reply')){toApply.push('Needs Reply')}
  for(const lab of toApply){
    try{run(['gmail','labels','modify',l.threadId,'--add',lab,'--account',account,'--json']);applied++}catch{}
  }
}
console.log('Applied labels to '+applied+' threads');
"
