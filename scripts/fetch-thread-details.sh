#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

gs_require_config
gs_prepare_cache_dir

REQUESTS_FILE="${1:-$CACHE_DIR/gmail-thread-fetch-requests.json}"
OUT_FILE="$CACHE_DIR/gmail-thread-details.json"

if [[ ! -f "$REQUESTS_FILE" ]]; then
  echo "No thread request file found at $REQUESTS_FILE" >&2
  exit 1
fi

REQUESTS_FILE="$REQUESTS_FILE" OUT_FILE="$OUT_FILE" ACCOUNT="$GOG_ACCOUNT" GOG_BIN="$GOG_BIN" node - <<'NODE'
const fs = require('fs');
const cp = require('child_process');

const requestsPath = process.env.REQUESTS_FILE;
const outPath = process.env.OUT_FILE;
const account = process.env.ACCOUNT;
const gogBin = process.env.GOG_BIN || 'gog';
const maxThreads = Number(process.env.GMAIL_SECRETARY_MAX_THREAD_FETCH || 10);
const maxBodyChars = Number(process.env.GMAIL_SECRETARY_MAX_BODY_CHARS || 4000);

function readJson(path) {
  return JSON.parse(fs.readFileSync(path, 'utf8'));
}

function run(args) {
  return cp.execFileSync(gogBin, args, {
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe']
  });
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
    return '';
  }
  const match = headers.find((header) => String(header?.name || '').toLowerCase() === name.toLowerCase());
  return String(match?.value || '');
}

function decodeBase64Url(value) {
  if (typeof value !== 'string' || value === '') {
    return '';
  }
  try {
    const normalized = value.replace(/-/g, '+').replace(/_/g, '/');
    return Buffer.from(normalized, 'base64').toString('utf8');
  } catch {
    return '';
  }
}

function extractBody(message) {
  if (typeof message?.body === 'string' && message.body.trim() !== '') {
    return message.body;
  }

  const collected = [];
  const queue = [];
  if (message?.payload) {
    queue.push(message.payload);
  }

  while (queue.length > 0) {
    const part = queue.shift();
    if (!part) {
      continue;
    }
    if (typeof part?.body === 'string' && part.body.trim() !== '') {
      collected.push(part.body);
    }
    if (typeof part?.text === 'string' && part.text.trim() !== '') {
      collected.push(part.text);
    }
    if (typeof part?.body?.data === 'string') {
      const decoded = decodeBase64Url(part.body.data);
      if (decoded.trim() !== '') {
        collected.push(decoded);
      }
    }
    if (Array.isArray(part?.parts)) {
      queue.push(...part.parts);
    }
  }

  return collected.join('\n').replace(/\0/g, '').trim();
}

function normalizeRequests(input) {
  const items = Array.isArray(input) ? input : (Array.isArray(input?.items) ? input.items : []);
  return items
    .map((item) => {
      if (typeof item === 'string') {
        return { threadId: item.trim(), reason: '' };
      }
      if (item && typeof item === 'object') {
        return {
          threadId: String(item.threadId || '').trim(),
          reason: String(item.reason || '').trim()
        };
      }
      return { threadId: '', reason: '' };
    })
    .filter((item) => item.threadId !== '');
}

const requests = normalizeRequests(readJson(requestsPath));
if (requests.length === 0) {
  throw new Error(`No thread IDs found in ${requestsPath}`);
}
if (requests.length > maxThreads) {
  throw new Error(`Refusing to fetch ${requests.length} threads; set GMAIL_SECRETARY_MAX_THREAD_FETCH to raise the limit.`);
}

const items = requests.map((request) => {
  const rawText = run(['gmail', 'thread', 'get', request.threadId, '--account', account, '--json']);
  const raw = JSON.parse(rawText);
  const thread = raw?.thread || raw;
  const sourceMessages = Array.isArray(thread?.messages) ? thread.messages : [];
  const messages = sourceMessages.map((message) => {
    const fullBody = extractBody(message).replace(/\r/g, '').trim();
    const bodyText = fullBody.slice(0, maxBodyChars);
    return {
      messageId: String(pick(message, ['id', 'messageId']) || ''),
      threadId: String(pick(message, ['threadId']) || request.threadId),
      from: headerValue(message, 'From'),
      to: headerValue(message, 'To'),
      cc: headerValue(message, 'Cc'),
      bcc: headerValue(message, 'Bcc'),
      date: headerValue(message, 'Date'),
      subject: headerValue(message, 'Subject') || String(pick(message, ['subject']) || ''),
      snippet: String(pick(message, ['snippet', 'preview']) || '').replace(/\s+/g, ' ').trim(),
      bodyText,
      bodyTextTruncated: bodyText.length < fullBody.length
    };
  });

  const latestMessage = messages[messages.length - 1] || {};
  return {
    threadId: request.threadId,
    reason: request.reason,
    subject: latestMessage.subject || '',
    latestMessageId: latestMessage.messageId || '',
    messageCount: messages.length,
    messages
  };
});

const payload = {
  generatedAt: new Date().toISOString(),
  requestCount: requests.length,
  items
};

fs.writeFileSync(outPath, JSON.stringify(payload, null, 2) + '\n');
console.log(`Fetched ${items.length} thread detail payloads`);
NODE

gs_secure_file "$OUT_FILE"

echo "Thread details written to $OUT_FILE"
