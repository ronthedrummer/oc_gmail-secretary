#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

gs_require_config
gs_prepare_cache_dir

PLAN_FILE="${GMAIL_SECRETARY_PLAN_FILE:-$CACHE_DIR/gmail-triage-plan.json}"
OUT_MD="$CACHE_DIR/gmail-drafts.md"
OUT_JSON="$CACHE_DIR/gmail-draft-results.json"

if [[ ! -f "$PLAN_FILE" ]]; then
  echo "No triage plan found at $PLAN_FILE" >&2
  exit 1
fi

PLAN_FILE="$PLAN_FILE" OUT_MD="$OUT_MD" OUT_JSON="$OUT_JSON" ACCOUNT="$GOG_ACCOUNT" GOG_BIN="$GOG_BIN" node - <<'NODE'
const fs = require('fs');
const cp = require('child_process');

const planPath = process.env.PLAN_FILE;
const outMarkdown = process.env.OUT_MD;
const outJson = process.env.OUT_JSON;
const account = process.env.ACCOUNT;
const gogBin = process.env.GOG_BIN || 'gog';

function readJson(path) {
  return JSON.parse(fs.readFileSync(path, 'utf8'));
}

function run(args) {
  return cp.execFileSync(gogBin, args, {
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe']
  });
}

function normalizeAddresses(value) {
  if (value == null) {
    return [];
  }
  const items = Array.isArray(value) ? value : [value];
  return items.map((item) => String(item).trim()).filter(Boolean);
}

function normalizePlan(input) {
  const items = Array.isArray(input) ? input : (Array.isArray(input?.items) ? input.items : []);
  return items.map((entry, index) => {
    if (!entry || typeof entry !== 'object') {
      throw new Error(`Plan entry ${index} is not an object`);
    }

    const action = entry.action == null ? (entry.needsReply ? 'reply' : 'none') : String(entry.action);
    const draft = entry.draft && typeof entry.draft === 'object' ? entry.draft : null;
    const wantsDraft = action === 'reply' || draft != null;
    if (!wantsDraft) {
      return null;
    }

    const threadId = String(entry.threadId || '').trim();
    const messageId = String(draft?.replyToMessageId || entry.messageId || '').trim();
    const subject = String(draft?.subject || entry.subject || '').trim();
    const body = String(draft?.body || '').trim();

    if (threadId === '') {
      throw new Error(`Plan entry ${index} is missing threadId`);
    }
    if (subject === '') {
      throw new Error(`Plan entry ${index} is missing draft.subject`);
    }
    if (body === '') {
      throw new Error(`Plan entry ${index} is missing draft.body`);
    }

    return {
      threadId,
      messageId,
      summary: String(entry.summary || '').trim(),
      subject,
      body,
      to: normalizeAddresses(draft?.to),
      cc: normalizeAddresses(draft?.cc),
      bcc: normalizeAddresses(draft?.bcc),
      quote: draft?.quote !== false,
      draftId: String(draft?.draftId || '').trim()
    };
  }).filter(Boolean);
}

function parseResult(text) {
  try {
    return JSON.parse(text);
  } catch {
    return { raw: text.trim() };
  }
}

const drafts = normalizePlan(readJson(planPath));
const results = [];
const failures = [];

for (const draft of drafts) {
  const args = ['gmail', 'drafts'];
  if (draft.draftId) {
    args.push('update', draft.draftId);
  } else {
    args.push('create');
  }

  if (draft.messageId) {
    args.push('--reply-to-message-id', draft.messageId);
    if (draft.quote) {
      args.push('--quote');
    }
  }

  if (draft.to.length > 0) {
    args.push('--to', draft.to.join(', '));
  }
  if (draft.cc.length > 0) {
    args.push('--cc', draft.cc.join(', '));
  }
  if (draft.bcc.length > 0) {
    args.push('--bcc', draft.bcc.join(', '));
  }

  args.push('--subject', draft.subject, '--body', draft.body, '--account', account, '--json');

  try {
    const response = parseResult(run(args));
    results.push({
      threadId: draft.threadId,
      subject: draft.subject,
      summary: draft.summary,
      replyToMessageId: draft.messageId,
      draftId: response?.id || response?.draftId || response?.draft?.id || draft.draftId || '',
      response
    });
  } catch (error) {
    failures.push({
      threadId: draft.threadId,
      subject: draft.subject,
      message: error.stderr ? String(error.stderr).trim() : String(error.message || error)
    });
  }
}

const markdownLines = [
  '# Gmail drafts',
  '',
  `Generated: ${new Date().toISOString()}`,
  `Draft count: ${results.length}`,
  ''
];

for (const result of results) {
  markdownLines.push(`## ${result.subject}`);
  markdownLines.push(`- Thread: ${result.threadId}`);
  if (result.replyToMessageId) {
    markdownLines.push(`- Reply target: ${result.replyToMessageId}`);
  }
  if (result.draftId) {
    markdownLines.push(`- Draft ID: ${result.draftId}`);
  }
  if (result.summary) {
    markdownLines.push(`- Summary: ${result.summary}`);
  }
  markdownLines.push('');
}

const payload = {
  generatedAt: new Date().toISOString(),
  draftCount: results.length,
  results,
  failures
};

fs.writeFileSync(outJson, JSON.stringify(payload, null, 2) + '\n');
fs.writeFileSync(outMarkdown, markdownLines.join('\n') + '\n');

if (failures.length > 0) {
  throw new Error(`Failed to create ${failures.length} drafts. See ${outJson}`);
}

console.log(`Created or updated ${results.length} drafts`);
NODE

gs_secure_file "$OUT_MD"
gs_secure_file "$OUT_JSON"

echo "Draft summaries written to $OUT_MD"
echo "Draft results written to $OUT_JSON"
