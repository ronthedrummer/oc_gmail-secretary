#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

gs_require_config
gs_prepare_cache_dir

QUERY="${GMAIL_SECRETARY_QUERY:-in:inbox (is:unread OR newer_than:2d)}"
FETCH_MAX="${GMAIL_SECRETARY_FETCH_MAX:-30}"
THREAD_LIMIT="${GMAIL_SECRETARY_THREAD_LIMIT:-20}"
INDEX_OUT="$CACHE_DIR/gmail-inbox-index.json"
SUMMARIES_OUT="$CACHE_DIR/gmail-inbox-summaries.json"
TMP_INBOX="$(mktemp)"
trap 'rm -f "$TMP_INBOX"' EXIT

TRIAGE_FILTERS_JSON="${GMAIL_SECRETARY_TRIAGE_FILTERS:-$SKILL_DIR/triage-filters.json}"
export TRIAGE_FILTERS_JSON

"$GOG_BIN" gmail messages search \
  "$QUERY" \
  --max "$FETCH_MAX" \
  --account "$GOG_ACCOUNT" \
  --json > "$TMP_INBOX"

TMP_INBOX="$TMP_INBOX" INDEX_OUT="$INDEX_OUT" SUMMARIES_OUT="$SUMMARIES_OUT" QUERY="$QUERY" THREAD_LIMIT="$THREAD_LIMIT" node - <<'NODE'
const fs = require('fs');

function readJson(path) {
  return JSON.parse(fs.readFileSync(path, 'utf8'));
}

function pick(o, keys) {
  for (const key of keys) {
    if (o && o[key] != null) {
      return o[key];
    }
  }
  return null;
}

function headerValue(message, name) {
  const headers = message?.payload?.headers || message?.headers;
  if (!Array.isArray(headers)) {
    return null;
  }
  const match = headers.find((header) => String(header?.name || '').toLowerCase() === name.toLowerCase());
  return match?.value || null;
}

function parseTimestamp(message) {
  const raw = pick(message, ['internalDate', 'internal_date', 'timestamp']);
  if (raw == null || raw === '') {
    return 0;
  }
  const value = Number(raw);
  if (Number.isFinite(value) && value > 0) {
    return value > 1000000000000 ? value : value * 1000;
  }
  const parsed = Date.parse(String(raw));
  return Number.isFinite(parsed) ? parsed : 0;
}

function normalizeMessage(message) {
  const messageId = pick(message, ['id', 'messageId']) || '';
  const threadId = pick(message, ['threadId']) || messageId;
  const subject = headerValue(message, 'Subject') || pick(message, ['subject']) || '(no subject)';
  const from = headerValue(message, 'From') || pick(message, ['from']) || '(unknown)';
  const date = headerValue(message, 'Date') || pick(message, ['date']) || '';
  const snippet = String(pick(message, ['snippet', 'preview', 'text']) || '')
    .replace(/\s+/g, ' ')
    .trim()
    .slice(0, 240);
  const labelIds = Array.isArray(message?.labelIds) ? message.labelIds : [];
  const internalDate = parseTimestamp(message);
  return {
    threadId,
    messageId,
    subject,
    from,
    date,
    snippet,
    labelIds,
    internalDate,
    hasUnread: labelIds.includes('UNREAD')
  };
}

function loadTriageFilterRules(configPath) {
  if (!configPath || !fs.existsSync(configPath)) {
    return [];
  }
  try {
    const raw = JSON.parse(fs.readFileSync(configPath, 'utf8'));
    const rules = Array.isArray(raw.rules) ? raw.rules : [];
    return rules
      .filter((r) => r && typeof r.id === 'string')
      .map((r) => ({
        id: r.id,
        description: typeof r.description === 'string' ? r.description : '',
        fromMatchesAny: Array.isArray(r.fromMatchesAny) ? r.fromMatchesAny : [],
        _re: (Array.isArray(r.subjectOrSnippetMatchesAny) ? r.subjectOrSnippetMatchesAny : [])
          .map((s) => {
            try {
              return new RegExp(String(s), 'i');
            } catch {
              return null;
            }
          })
          .filter(Boolean)
      }))
      .filter((r) => r.fromMatchesAny.length > 0 && r._re.length > 0);
  } catch (err) {
    console.warn(`triage-filters.json: ${err.message}`);
    return [];
  }
}

function matchingIgnoreRule(normalized, rules) {
  const fromLower = String(normalized.from || '').toLowerCase();
  const blob = `${String(normalized.subject || '').toLowerCase()} ${String(normalized.snippet || '').toLowerCase()}`;
  for (const rule of rules) {
    if (!rule.fromMatchesAny.some((t) => fromLower.includes(String(t).toLowerCase()))) {
      continue;
    }
    if (rule._re.some((re) => re.test(blob))) {
      return rule;
    }
  }
  return null;
}

const filterRules = loadTriageFilterRules(process.env.TRIAGE_FILTERS_JSON);

const raw = readJson(process.env.TMP_INBOX);
const sourceMessages = Array.isArray(raw) ? raw : (raw?.messages || raw?.items || raw?.threads || []);
const perThread = new Map();

for (const message of sourceMessages) {
  const normalized = normalizeMessage(message);
  if (!normalized.threadId) {
    continue;
  }
  const previous = perThread.get(normalized.threadId);
  if (!previous || normalized.internalDate >= previous.internalDate) {
    perThread.set(normalized.threadId, normalized);
  }
}

const ignoredSamples = [];
let ignoredThreadCount = 0;
for (const [threadId, normalized] of perThread) {
  const matched = matchingIgnoreRule(normalized, filterRules);
  if (!matched) {
    continue;
  }
  ignoredThreadCount += 1;
  if (ignoredSamples.length < 12) {
    ignoredSamples.push({
      threadId,
      subject: normalized.subject,
      from: normalized.from,
      ruleId: matched.id
    });
  }
  perThread.delete(threadId);
}

const threadLimit = Number(process.env.THREAD_LIMIT || 20);
const items = Array.from(perThread.values())
  .sort((left, right) => right.internalDate - left.internalDate)
  .slice(0, threadLimit)
  .map((item, index) => ({
    index,
    threadId: item.threadId,
    messageId: item.messageId,
    subject: item.subject,
    from: item.from,
    date: item.date,
    snippet: item.snippet,
    labelIds: item.labelIds,
    hasUnread: item.hasUnread
  }));

const indexPayload = {
  generatedAt: new Date().toISOString(),
  query: process.env.QUERY,
  itemCount: items.length,
  ignoredFilter: {
    config: process.env.TRIAGE_FILTERS_JSON || null,
    ruleCount: filterRules.length,
    ignoredThreadCount,
    sample: ignoredSamples
  },
  items
};

fs.writeFileSync(process.env.INDEX_OUT, JSON.stringify(indexPayload, null, 2) + '\n');
fs.writeFileSync(process.env.SUMMARIES_OUT, JSON.stringify(items, null, 2) + '\n');
NODE

gs_secure_file "$INDEX_OUT"
gs_secure_file "$SUMMARIES_OUT"

echo "Inbox index written to $INDEX_OUT"
echo "Compatibility summaries written to $SUMMARIES_OUT"
echo "Next step: review the index, fetch full threads only when needed, then write cache/gmail-triage-plan.json."
