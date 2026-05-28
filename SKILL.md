---
name: capsules
description: >
  Capsules lets agents create shared context stores, ingest project notes or
  handoff text, and query focused chunks later. Use when asked to "make a
  capsule", "save this context for another agent", "send context to another
  agent", "query a capsule", "ingest this into Capsules", "create a handoff",
  or "use Capsules memory".
---

# Capsules

Skill version: 0.1.4

Capsules are shared context stores for agent handoff.

Use Capsules for three jobs:

- Push chunked handoff context into a new capsule.
- Ingest additional chunked JSON payloads into an existing capsule.
- Query a capsule with the read token and return ranked chunks.

## Requirements

- Required binaries: `curl`, `jq`
- Optional write credential: `$CAPSULES_API_KEY`
- Optional current bearer credential: `$CAPSULES_AUTH_TOKEN`
- Optional query credential: `$CAPSULES_READ_TOKEN`
- Optional credentials file: `~/.capsules/credentials`
- Optional API base: `$CAPSULES_BASE_URL`
- Bundled helper: `./scripts/capsules.sh`

Until the public production URL is finalized, `capsules.sh` defaults to
`https://capsules-bay.vercel.app`. For hosted environments, set `CAPSULES_BASE_URL` or pass
`--base-url`.

## Auth

Write APIs accept a Capsules API key or signed-in session bearer token. The
script reads it in this order:

1. `--api-key {key}` or `--auth-token {token}`
2. `$CAPSULES_API_KEY`
3. `$CAPSULES_AUTH_TOKEN`
4. `~/.capsules/credentials`

Send API keys as `Authorization: Bearer <capsules-api-key>`. If the key has
explicit scopes, it needs `capsules:write` for create, ingest, and token
rotation. API keys without explicit scopes are treated as allowed for capsule
read and write operations.

Before any `create`, `ingest`, token rotation, project read, or summary
preparation for a capsule, check auth:

```bash
./scripts/capsules.sh auth status
```

If `write_credential=missing`, do not create a fallback brief or pretend a real
capsule exists. Start the login flow:

```bash
./scripts/capsules.sh auth login
```

The `auth login` output is addressed to you, the agent. Treat it as a hard
stop. Do not paste the raw output as the final answer. Do not inspect files,
read project context, prepare summaries, or do any background work while waiting
for auth. Tell the user to open the auth URL, sign in or create an account,
click Generate key, copy the generated API key, and paste it into the chat.
Then stop and wait.

After receiving the key, do not echo it back. Save it yourself:

```bash
./scripts/capsules.sh auth save "{CAPSULES_API_KEY}"
```

Then rerun `auth status`. If `write_credential=present`, continue the requested
Capsules operation.

Store a credential:

```bash
./scripts/capsules.sh auth save "{CAPSULES_API_KEY_OR_SESSION_TOKEN}"
```

Never commit credentials or local state files:

- `~/.capsules/credentials`
- `.capsules/state.json`

## Create

For a new handoff capsule, use `push`, not separate `create` then `ingest`.
`push` creates the capsule, ingests a required chunked payload, saves the read
token locally, and returns the handoff block in one command.

Prepare a temporary JSON payload with explicit chunks. Do not write one large
markdown file and ingest it with `--from` for handoff work.

```json
{
  "title": "Project handoff",
  "source": "codex",
  "metadata": {
    "purpose": "friend-friendly project summary"
  },
  "chunks": [
    {
      "key": "purpose",
      "title": "What this project is",
      "text": "Plain-language summary of the project.",
      "tags": ["overview"]
    },
    {
      "key": "how-it-works",
      "title": "How it works",
      "text": "Focused explanation of the main flow and moving parts.",
      "tags": ["architecture"]
    },
    {
      "key": "handoff-next-steps",
      "title": "What to do next",
      "text": "Concrete next steps or caveats for the receiving agent.",
      "tags": ["handoff"]
    }
  ]
}
```

Then run one command:

```bash
./scripts/capsules.sh push "Project handoff" --payload /tmp/capsules-ingest.json
```

Use 3-12 chunks for normal handoffs. Each chunk should answer one likely future
question and should usually stay under 1,500 words. Include stable `key`,
descriptive `title`, concise `text`, and useful `tags`.

Use separate `create` only when the user explicitly wants an empty capsule:

```bash
./scripts/capsules.sh create "Project handoff"
```

The script prints JSON and saves the returned read token in
`.capsules/state.json`. The full read token is only available when creating or
rotating a token, so preserve it.

## Ingest

Prefer exact chunked payloads:

```bash
./scripts/capsules.sh ingest {capsule-id} --payload /tmp/capsules-ingest.json
```

Use plain text fallback only for quick one-off notes where chunk quality does
not matter:

```bash
./scripts/capsules.sh ingest {capsule-id} --from ./note.md --source codex
```

## Query

```bash
./scripts/capsules.sh query {capsule-id} "How do I deploy this project?"
```

The script uses `$CAPSULES_READ_TOKEN`, `--read-token`, or the read token saved
for that capsule in `.capsules/state.json`.

## Rotate Read Token

```bash
./scripts/capsules.sh token rotate {capsule-id}
```

This invalidates the old read token and saves the new one locally.

## Handoff

```bash
./scripts/capsules.sh handoff {capsule-id}
```

Share the generated block with the receiving agent. It contains the capsule id,
API base, query endpoint, and read token.

## Script Output

Commands write machine-readable JSON or a handoff block to stdout. They also
write `capsule_result.*` lines to stderr for agents that need stable summaries.

When reporting results to the user:

- For `push`, include the capsule id, document id, chunk count, and handoff
  block. This is the preferred successful result for a new handoff.
- For `create`, include the capsule id and remind them the read token was saved
  locally by the script.
- For `ingest`, include the document id and chunk count.
- For `query`, summarize the returned chunks instead of dumping huge JSON unless
  the user asked for raw output.
- For `handoff`, tell the user the read token grants query access to that
  capsule.
