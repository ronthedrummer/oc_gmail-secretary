# OpenClaw Agent Workflow

This document shows the exact handoff between the host-side Gmail scripts and the OpenClaw agent.

## Goal

The agent should not call Gmail directly. It should:

1. Read normalized inbox data from `cache/`
2. Decide which threads need deeper context
3. Write a structured triage plan
4. Let the host-side scripts apply labels and create drafts

## Step 1: Build the inbox index

Run:

```bash
./scripts/triage-and-draft.sh
```

This creates:

- `cache/gmail-inbox-index.json`
- `cache/gmail-inbox-summaries.json`

The primary file is `cache/gmail-inbox-index.json`.

## Step 2: Agent reviews the inbox index

Ask the OpenClaw agent to read `cache/gmail-inbox-index.json` and do two things:

1. Identify which threads can be triaged from metadata/snippet alone
2. Identify which threads need full thread context before making a reliable decision

When more context is needed, the agent should write:

- `cache/gmail-thread-fetch-requests.json`

Example:

```json
[
  {
    "threadId": "thread-123",
    "reason": "Need full context before drafting a reply"
  },
  {
    "threadId": "thread-456",
    "reason": "Snippet is ambiguous and may be urgent"
  }
]
```

## Step 3: Fetch full thread details when needed

Run:

```bash
./scripts/fetch-thread-details.sh
```

This creates:

- `cache/gmail-thread-details.json`

The agent should then use:

- `cache/gmail-inbox-index.json`
- `cache/gmail-thread-details.json` if present

## Step 4: Agent writes the triage plan

The agent should write:

- `cache/gmail-triage-plan.json`

Example:

```json
{
  "generatedAt": "2026-03-08T12:00:00Z",
  "items": [
    {
      "threadId": "thread-123",
      "messageId": "message-123",
      "subject": "Re: Meeting follow-up",
      "summary": "Needs a short reply confirming availability next week.",
      "labels": ["Needs Reply"],
      "action": "reply",
      "draft": {
        "subject": "Re: Meeting follow-up",
        "body": "Thanks for the note. Next Tuesday afternoon works well for me.",
        "replyToMessageId": "message-123",
        "quote": true
      }
    },
    {
      "threadId": "thread-456",
      "messageId": "message-456",
      "subject": "Security alert",
      "summary": "Account-related security message that should be reviewed soon.",
      "labels": ["Admin / Accounts", "Urgent"],
      "action": "review"
    }
  ]
}
```

Rules:

- `action` must be `none`, `review`, or `reply`
- Use only approved labels
- Include `draft` only when a draft should be created or updated
- Never instruct the system to send mail automatically

## Suggested agent prompt

Use a prompt along these lines in OpenClaw:

```text
Read cache/gmail-inbox-index.json.

Goal:
- Triage each thread for urgency and action
- Request full thread details only when metadata/snippet is not enough
- Write cache/gmail-thread-fetch-requests.json only if needed
- After full thread details are available, write cache/gmail-triage-plan.json

Rules:
- Never send email
- Use only these labels: Urgent, Needs Reply, Waiting On, Read Later, Receipt / Billing, Admin / Accounts
- Use action values: none, review, reply
- Keep summaries short and user-facing
- Only include a draft when a reply is clearly appropriate
- Prefer metadata-first decisions; fetch full thread content only when needed
```

## Step 5: Apply the plan

Run:

```bash
./scripts/apply-labels.sh
./scripts/create-drafts.sh
```

These consume `cache/gmail-triage-plan.json` and write:

- `cache/gmail-label-apply-report.json`
- `cache/gmail-drafts.md`
- `cache/gmail-draft-results.json`

## Operational recommendation

The most reliable loop is:

1. `./scripts/check-gmail-auth.sh`
2. `./scripts/triage-and-draft.sh`
3. Agent reviews `cache/gmail-inbox-index.json`
4. If needed, agent writes `cache/gmail-thread-fetch-requests.json`
5. `./scripts/fetch-thread-details.sh`
6. Agent writes `cache/gmail-triage-plan.json`
7. `./scripts/apply-labels.sh`
8. `./scripts/create-drafts.sh`
