#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

gs_require_config
gs_prepare_cache_dir

PLAN_FILE="${GMAIL_SECRETARY_PLAN_FILE:-$CACHE_DIR/gmail-triage-plan.json}"
LEGACY_FILE="$CACHE_DIR/gmail-triage-labels.json"
REPORT_FILE="$CACHE_DIR/gmail-label-apply-report.json"

if [[ ! -f "$PLAN_FILE" ]]; then
  if [[ -f "$LEGACY_FILE" ]]; then
    PLAN_FILE="$LEGACY_FILE"
  else
    echo "No triage plan found at $PLAN_FILE or $LEGACY_FILE" >&2
    exit 1
  fi
fi

PLAN_FILE="$PLAN_FILE" REPORT_FILE="$REPORT_FILE" GOG_BIN="$GOG_BIN" ACCOUNT="$GOG_ACCOUNT" node - <<'NODE'
const fs = require('fs');
const cp = require('child_process');

const account = process.env.ACCOUNT;
const gogBin = process.env.GOG_BIN || 'gog';
const planPath = process.env.PLAN_FILE;
const reportPath = process.env.REPORT_FILE;
const allowedLabels = ['Urgent', 'Needs Reply', 'Waiting On', 'Read Later', 'Receipt / Billing', 'Admin / Accounts'];
const allowedActions = new Set(['none', 'review', 'reply']);

function readJson(path) {
  return JSON.parse(fs.readFileSync(path, 'utf8'));
}

function run(args) {
  return cp.execFileSync(gogBin, args, {
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe']
  });
}

function normalizePlan(input) {
  const items = Array.isArray(input) ? input : (Array.isArray(input?.items) ? input.items : []);
  return items.map((entry, index) => {
    if (!entry || typeof entry !== 'object') {
      throw new Error(`Plan entry ${index} is not an object`);
    }
    const threadId = String(entry.threadId || '').trim();
    if (threadId === '') {
      throw new Error(`Plan entry ${index} is missing threadId`);
    }

    const labels = [];
    if (Array.isArray(entry.labels)) {
      labels.push(...entry.labels);
    } else if (typeof entry.label === 'string' && entry.label.trim() !== '') {
      labels.push(entry.label);
    }

    const action = entry.action == null ? (entry.needsReply ? 'reply' : 'none') : String(entry.action);
    if (!allowedActions.has(action)) {
      throw new Error(`Plan entry ${index} has unsupported action '${action}'`);
    }

    const normalizedLabels = [...new Set(labels.map((label) => String(label).trim()).filter(Boolean))];
    for (const label of normalizedLabels) {
      if (!allowedLabels.includes(label)) {
        throw new Error(`Plan entry ${index} uses unsupported label '${label}'`);
      }
    }

    if (action === 'reply' && !normalizedLabels.includes('Needs Reply')) {
      normalizedLabels.push('Needs Reply');
    }

    return {
      threadId,
      labels: normalizedLabels
    };
  });
}

const plan = normalizePlan(readJson(planPath));
const mergedByThread = new Map();

for (const entry of plan) {
  const existing = mergedByThread.get(entry.threadId) || new Set();
  for (const label of entry.labels) {
    existing.add(label);
  }
  mergedByThread.set(entry.threadId, existing);
}

const threadSummaries = Array.from(mergedByThread.entries()).map(([threadId, labels]) => ({
  threadId,
  labels: Array.from(labels)
}));
const labelOperations = threadSummaries.flatMap((entry) =>
  entry.labels.map((label) => ({ threadId: entry.threadId, label }))
);

const existingLabelResponse = JSON.parse(run(['gmail', 'labels', 'list', '--account', account, '--json']));
const existingLabels = new Set((existingLabelResponse?.labels || existingLabelResponse || []).map((item) => item?.name).filter(Boolean));

for (const label of allowedLabels) {
  if (!existingLabels.has(label)) {
    run(['gmail', 'labels', 'create', label, '--account', account, '--json']);
    existingLabels.add(label);
  }
}

const failures = [];
let applied = 0;
for (const op of labelOperations) {
  try {
    run(['gmail', 'labels', 'modify', op.threadId, '--add', op.label, '--account', account, '--json']);
    applied += 1;
  } catch (error) {
    failures.push({
      threadId: op.threadId,
      label: op.label,
      message: error.stderr ? String(error.stderr).trim() : String(error.message || error)
    });
  }
}

const report = {
  generatedAt: new Date().toISOString(),
  applied,
  threadCount: threadSummaries.length,
  operations: threadSummaries,
  failures
};

fs.writeFileSync(reportPath, JSON.stringify(report, null, 2) + '\n');
if (failures.length > 0) {
  throw new Error(`Failed to apply ${failures.length} label updates. See ${reportPath}`);
}

console.log(`Applied ${applied} labels across ${threadSummaries.length} threads`);
NODE

gs_secure_file "$REPORT_FILE"

echo "Label report written to $REPORT_FILE"
