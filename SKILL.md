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

Skill version: 0.1.1

Capsules are shared context stores for agent handoff.

Use Capsules for three jobs:

- Create a capsule and save its one-time read token.
- Ingest text or JSON payloads into a capsule.
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

Before any `create`, `ingest`, or token rotation, check auth:

```bash
./scripts/capsules.sh auth status
```

If `write_credential=missing`, do not create a fallback brief or pretend a real
capsule exists. Start the login flow:

```bash
./scripts/capsules.sh auth login
```

Ask the user to open the printed URL, sign in or create an account, generate an
agent API key, and paste the key back into the chat. After receiving the key,
save it yourself:

```bash
./scripts/capsules.sh auth save "{CAPSULES_API_KEY}"
```

Then rerun `auth status` and continue the requested Capsules operation.

Store a credential:

```bash
./scripts/capsules.sh auth save "{CAPSULES_API_KEY_OR_SESSION_TOKEN}"
```

Never commit credentials or local state files:

- `~/.capsules/credentials`
- `.capsules/state.json`

## Create

```bash
./scripts/capsules.sh create "Project handoff"
```

The script prints JSON and saves the returned read token in
`.capsules/state.json`. The full read token is only available when creating or
rotating a token, so preserve it.

## Ingest

Plain text file:

```bash
./scripts/capsules.sh ingest {capsule-id} --from ./handoff.md --source codex
```

Exact API payload:

```bash
./scripts/capsules.sh ingest {capsule-id} --payload ./ingest.json
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

- For `create`, include the capsule id and remind them the read token was saved
  locally by the script.
- For `ingest`, include the document id and chunk count.
- For `query`, summarize the returned chunks instead of dumping huge JSON unless
  the user asked for raw output.
- For `handoff`, tell the user the read token grants query access to that
  capsule.
