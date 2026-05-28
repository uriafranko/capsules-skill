#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${CAPSULES_BASE_URL:-http://localhost:3000}"
CREDENTIALS_FILE="$HOME/.capsules/credentials"
AUTH_TOKEN="${CAPSULES_API_KEY:-${CAPSULES_AUTH_TOKEN:-}}"
AUTH_TOKEN_SOURCE="none"
READ_TOKEN="${CAPSULES_READ_TOKEN:-}"
ALLOW_INSECURE_BASE_URL=0
STATE_DIR=".capsules"
STATE_FILE="$STATE_DIR/state.json"

if [[ -n "${CAPSULES_API_KEY:-}" ]]; then
  AUTH_TOKEN_SOURCE="env:CAPSULES_API_KEY"
elif [[ -n "${CAPSULES_AUTH_TOKEN:-}" ]]; then
  AUTH_TOKEN_SOURCE="env:CAPSULES_AUTH_TOKEN"
fi

usage() {
  cat <<'USAGE'
Usage: capsules.sh [global options] <command> [args]

Global options:
  --base-url <url>             API base URL (default: $CAPSULES_BASE_URL or http://localhost:3000)
  --api-key <key>              Capsules API key for write APIs
  --auth-token <token>         Bearer token for write APIs
  --read-token <token>         Capsule read token for query/handoff
  --credentials-file <path>    Write credential file (default: ~/.capsules/credentials)
  --allow-insecure-base-url    Allow sending credentials to non-local http:// URLs

Commands:
  auth save <token>
  auth status
  create <name> [--metadata-json <json>]
  ingest <capsule-id> (--from <file> | --raw-text <text> | --payload <json-file>)
    [--title <title>] [--source <source>] [--document-id <id>] [--metadata-json <json>]
  query <capsule-id> <question> [--limit <1-25>] [--read-token <token>]
  token rotate <capsule-id>
  rotate-token <capsule-id>
  handoff <capsule-id> [--read-token <token>]
USAGE
  exit 1
}

die() {
  echo "error: $1" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "requires $1"
}

need_cmd curl
need_cmd jq

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-url) BASE_URL="$2"; shift 2 ;;
    --api-key) AUTH_TOKEN="$2"; AUTH_TOKEN_SOURCE="flag:api-key"; shift 2 ;;
    --auth-token) AUTH_TOKEN="$2"; AUTH_TOKEN_SOURCE="flag:auth-token"; shift 2 ;;
    --read-token) READ_TOKEN="$2"; shift 2 ;;
    --credentials-file) CREDENTIALS_FILE="$2"; shift 2 ;;
    --allow-insecure-base-url) ALLOW_INSECURE_BASE_URL=1; shift ;;
    --help|-h) usage ;;
    --*) die "unknown global option: $1" ;;
    *) break ;;
  esac
done

CMD="${1:-}"
[[ -n "$CMD" ]] || usage
shift || true

if [[ -z "$AUTH_TOKEN" && -f "$CREDENTIALS_FILE" ]]; then
  AUTH_TOKEN=$(tr -d '[:space:]' < "$CREDENTIALS_FILE")
  [[ -n "$AUTH_TOKEN" ]] && AUTH_TOKEN_SOURCE="credentials"
fi

BASE_URL="${BASE_URL%/}"

if [[ -n "$AUTH_TOKEN" && "$BASE_URL" == http://* && "$ALLOW_INSECURE_BASE_URL" -ne 1 ]]; then
  case "$BASE_URL" in
    http://localhost|http://localhost:*|http://127.0.0.1|http://127.0.0.1:*|http://[::1]|http://[::1]:*) ;;
    *) die "refusing to send credentials to non-local http URL; pass --allow-insecure-base-url to override" ;;
  esac
fi

json_object_or_die() {
  local value="$1"
  local field="$2"
  printf '%s' "$value" | jq -e 'type == "object"' >/dev/null || die "$field must be a JSON object"
}

require_auth() {
  [[ -n "$AUTH_TOKEN" ]] || die "missing write credential; set CAPSULES_API_KEY, CAPSULES_AUTH_TOKEN, or run auth save"
}

api_json_with_token() {
  local method="$1"
  local path="$2"
  local token="$3"
  local body="${4:-}"
  local tmp code url
  tmp=$(mktemp)
  url="$BASE_URL$path"

  if [[ -n "$body" ]]; then
    code=$(curl -sS -o "$tmp" -w "%{http_code}" -X "$method" "$url" \
      -H "authorization: Bearer $token" \
      -H "content-type: application/json" \
      -d "$body")
  else
    code=$(curl -sS -o "$tmp" -w "%{http_code}" -X "$method" "$url" \
      -H "authorization: Bearer $token")
  fi

  if [[ "$code" -lt 200 || "$code" -ge 300 ]]; then
    local err
    err=$(jq -r '.error // .message // empty' "$tmp" 2>/dev/null || true)
    [[ -n "$err" ]] || err="$(cat "$tmp")"
    rm -f "$tmp"
    die "HTTP $code: $err"
  fi

  cat "$tmp"
  rm -f "$tmp"
}

api_json() {
  require_auth
  api_json_with_token "$1" "$2" "$AUTH_TOKEN" "${3:-}"
}

state_json() {
  if [[ -f "$STATE_FILE" ]] && jq -e 'type == "object"' "$STATE_FILE" >/dev/null 2>&1; then
    cat "$STATE_FILE"
  else
    printf '{"capsules":{}}\n'
  fi
}

save_capsule_response() {
  local response="$1"
  local capsule_id now state updated
  capsule_id=$(printf '%s' "$response" | jq -r '.capsule.id // .capsuleId // empty')
  [[ -n "$capsule_id" ]] || return 0

  mkdir -p "$STATE_DIR"
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  state=$(state_json)
  updated=$(printf '%s' "$state" | jq \
    --arg id "$capsule_id" \
    --arg now "$now" \
    --argjson response "$response" '
      .capsules[$id] as $old
      | .capsules[$id] = {
          capsuleId: $id,
          name: ($response.capsule.name // $old.name // null),
          readToken: ($response.readToken // $old.readToken // null),
          readTokenPreview: ($response.capsule.readTokenPreview // $old.readTokenPreview // null),
          updatedAt: $now
        }
    ')
  printf '%s\n' "$updated" | jq '.' > "$STATE_FILE"
}

lookup_read_token() {
  local capsule_id="$1"
  local token="$READ_TOKEN"

  if [[ -z "$token" && -f "$STATE_FILE" ]]; then
    token=$(jq -r --arg id "$capsule_id" '.capsules[$id].readToken // empty' "$STATE_FILE" 2>/dev/null || true)
  fi

  [[ -n "$token" ]] || die "missing read token; pass --read-token, set CAPSULES_READ_TOKEN, or create/rotate this capsule with the script"
  printf '%s' "$token"
}

emit_capsule_result() {
  local response="$1"
  local action="$2"
  local capsule_id read_preview
  capsule_id=$(printf '%s' "$response" | jq -r '.capsule.id // .capsuleId // empty')
  read_preview=$(printf '%s' "$response" | jq -r '.capsule.readTokenPreview // empty')

  echo "" >&2
  echo "capsule_result.action=$action" >&2
  [[ -n "$capsule_id" ]] && echo "capsule_result.capsule_id=$capsule_id" >&2
  [[ -n "$read_preview" ]] && echo "capsule_result.read_token_preview=$read_preview" >&2
  echo "capsule_result.auth_token_source=$AUTH_TOKEN_SOURCE" >&2
}

cmd_auth() {
  local sub="${1:-}"
  shift || true

  case "$sub" in
    save)
      [[ $# -eq 1 ]] || die "usage: capsules.sh auth save <token>"
      mkdir -p "$(dirname "$CREDENTIALS_FILE")"
      printf '%s\n' "$1" > "$CREDENTIALS_FILE"
      chmod 600 "$CREDENTIALS_FILE"
      echo "saved credential to $CREDENTIALS_FILE"
      ;;
    status)
      if [[ -n "$AUTH_TOKEN" ]]; then
        echo "write_credential=present"
        echo "source=$AUTH_TOKEN_SOURCE"
      else
        echo "write_credential=missing"
      fi
      echo "base_url=$BASE_URL"
      ;;
    *)
      die "usage: capsules.sh auth save <token> | auth status"
      ;;
  esac
}

cmd_create() {
  local name="" metadata="{}" response

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --metadata-json) metadata="$2"; shift 2 ;;
      --*) die "unknown create option: $1" ;;
      *) [[ -z "$name" ]] && name="$1" || die "unexpected create argument: $1"; shift ;;
    esac
  done

  [[ -n "$name" ]] || die "usage: capsules.sh create <name> [--metadata-json <json>]"
  json_object_or_die "$metadata" "metadata"

  body=$(jq -n --arg name "$name" --argjson metadata "$metadata" '{name:$name, metadata:$metadata}')
  response=$(api_json POST "/api/capsules" "$body")
  save_capsule_response "$response"
  printf '%s\n' "$response" | jq '.'
  emit_capsule_result "$response" "create"
  echo "capsule_result.read_token_saved=true" >&2
}

cmd_ingest() {
  local capsule_id="${1:-}"
  [[ -n "$capsule_id" ]] || die "usage: capsules.sh ingest <capsule-id> (--from <file> | --raw-text <text> | --payload <json-file>)"
  shift

  local from="" raw_text="" payload="" title="" source="capsules.sh" document_id="" metadata="{}" body response

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --from) from="$2"; shift 2 ;;
      --raw-text) raw_text="$2"; shift 2 ;;
      --payload) payload="$2"; shift 2 ;;
      --title) title="$2"; shift 2 ;;
      --source) source="$2"; shift 2 ;;
      --document-id) document_id="$2"; shift 2 ;;
      --metadata-json) metadata="$2"; shift 2 ;;
      --*) die "unknown ingest option: $1" ;;
      *) die "unexpected ingest argument: $1" ;;
    esac
  done

  if [[ -n "$payload" ]]; then
    [[ -f "$payload" ]] || die "payload file does not exist: $payload"
    body=$(cat "$payload")
    printf '%s' "$body" | jq -e 'type == "object"' >/dev/null || die "payload must be a JSON object"
  else
    [[ -z "$from" || -z "$raw_text" ]] || die "use either --from or --raw-text, not both"
    if [[ -n "$from" ]]; then
      [[ -f "$from" ]] || die "input file does not exist: $from"
      raw_text=$(cat "$from")
      [[ -n "$title" ]] || title=$(basename "$from")
    fi

    [[ -n "$raw_text" ]] || die "ingest requires --from, --raw-text, or --payload"
    json_object_or_die "$metadata" "metadata"
    body=$(jq -n \
      --arg source "$source" \
      --arg title "$title" \
      --arg rawText "$raw_text" \
      --arg documentId "$document_id" \
      --argjson metadata "$metadata" '
        {
          source: $source,
          title: $title,
          rawText: $rawText,
          metadata: $metadata
        }
        + (if $documentId == "" then {} else {documentId: $documentId} end)
      ')
  fi

  response=$(api_json POST "/api/capsules/$capsule_id/ingest" "$body")
  printf '%s\n' "$response" | jq '.'
  echo "" >&2
  echo "capsule_result.action=ingest" >&2
  echo "capsule_result.capsule_id=$capsule_id" >&2
  echo "capsule_result.document_id=$(printf '%s' "$response" | jq -r '.documentId // empty')" >&2
  echo "capsule_result.chunk_count=$(printf '%s' "$response" | jq -r '.chunkCount // empty')" >&2
  echo "capsule_result.auth_token_source=$AUTH_TOKEN_SOURCE" >&2
}

cmd_query() {
  local capsule_id="${1:-}"
  [[ -n "$capsule_id" ]] || die "usage: capsules.sh query <capsule-id> <question> [--limit <1-25>]"
  shift

  local limit=8 query_parts=() token body response

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --limit) limit="$2"; shift 2 ;;
      --read-token) READ_TOKEN="$2"; shift 2 ;;
      --*) die "unknown query option: $1" ;;
      *) query_parts+=("$1"); shift ;;
    esac
  done

  [[ "${#query_parts[@]}" -gt 0 ]] || die "query text is required"
  query="${query_parts[*]}"
  token=$(lookup_read_token "$capsule_id")
  body=$(jq -n --arg query "$query" --argjson limit "$limit" '{query:$query, limit:$limit}')
  response=$(api_json_with_token POST "/api/public/capsules/$capsule_id/query" "$token" "$body")
  printf '%s\n' "$response" | jq '.'
  echo "" >&2
  echo "capsule_result.action=query" >&2
  echo "capsule_result.capsule_id=$capsule_id" >&2
  echo "capsule_result.result_count=$(printf '%s' "$response" | jq -r '.results | length')" >&2
}

cmd_rotate_token() {
  local capsule_id="${1:-}" response
  [[ -n "$capsule_id" && $# -eq 1 ]] || die "usage: capsules.sh token rotate <capsule-id>"
  response=$(api_json POST "/api/capsules/$capsule_id/read-token" "")
  save_capsule_response "$response"
  printf '%s\n' "$response" | jq '.'
  emit_capsule_result "$response" "rotate-token"
  echo "capsule_result.read_token_saved=true" >&2
}

cmd_handoff() {
  local capsule_id="${1:-}"
  [[ -n "$capsule_id" ]] || die "usage: capsules.sh handoff <capsule-id> [--read-token <token>]"
  shift || true

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --read-token) READ_TOKEN="$2"; shift 2 ;;
      --*) die "unknown handoff option: $1" ;;
      *) die "unexpected handoff argument: $1" ;;
    esac
  done

  local token endpoint
  token=$(lookup_read_token "$capsule_id")
  endpoint="$BASE_URL/api/public/capsules/$capsule_id/query"

  cat <<EOF
capsule_handoff:
  api_base: $BASE_URL
  capsule_id: $capsule_id
  query_endpoint: $endpoint
  read_token: $token
  instruction: Query this Capsule before you start, then use the returned chunks as context.
EOF
}

case "$CMD" in
  auth)
    cmd_auth "$@"
    ;;
  create)
    cmd_create "$@"
    ;;
  ingest)
    cmd_ingest "$@"
    ;;
  query)
    cmd_query "$@"
    ;;
  token)
    sub="${1:-}"
    shift || true
    [[ "$sub" == "rotate" ]] || die "usage: capsules.sh token rotate <capsule-id>"
    cmd_rotate_token "$@"
    ;;
  rotate-token)
    cmd_rotate_token "$@"
    ;;
  handoff)
    cmd_handoff "$@"
    ;;
  *)
    die "unknown command: $CMD"
    ;;
esac
