#!/bin/sh
# Ask each model in `MODELS` for one answer, and exit 1 when one fails.  Skip a
# StatefulSet stopped on purpose (`spec.replicas` 0).  Env: MODELS, SERVICE
# (host of the Service) and STATEFULSET.
set -u

ATTEMPTS=3
PAUSE=15
TIMEOUT=180
BODY=/tmp/body

log() { echo "$(date -u +%H:%M:%S) $*"; }

[ -n "${MODELS:-}" ] && [ -n "${SERVICE:-}" ] && [ -n "${STATEFULSET:-}" ] || {
  log "FAIL: MODELS, SERVICE and STATEFULSET need a value"
  exit 1
}

sa=/var/run/secrets/kubernetes.io/serviceaccount
code=$(curl -sS --max-time 20 -o "$BODY" -w '%{http_code}' \
  --cacert "$sa/ca.crt" -H "Authorization: Bearer $(cat "$sa/token")" \
  "https://kubernetes.default.svc/apis/apps/v1/namespaces/$(cat "$sa/namespace")/statefulsets/$STATEFULSET/scale") || code=000
if [ "$code" != 200 ]; then
  log "FAIL: scale of $STATEFULSET answered HTTP $code"
  exit 1
fi
# The API server pretty-prints JSON, so drop the white space first.  It omits
# `replicas` from `spec` when the value is 0.
if tr -d ' \n\t' < "$BODY" | grep -Eq '"spec":\{(\}|"replicas":0[,}])'; then
  log "SKIP: $STATEFULSET has 0 replicas"
  exit 0
fi

# Print nothing on success.  Print the reason on failure.
check() {
  alias=$1 port=$2 kind=$3
  : > "$BODY"
  base="http://$SERVICE:$port"
  case "$kind" in
    asr)
      code=$(curl -sS --max-time "$TIMEOUT" -o "$BODY" -w '%{http_code}' "$base/health") || code=000
      [ "$code" = 200 ] || { echo "GET /health answered HTTP $code"; return 1; }
      ;;
    embedding)
      code=$(curl -sS --max-time "$TIMEOUT" -o "$BODY" -w '%{http_code}' \
        -H 'Content-Type: application/json' \
        -d "{\"model\":\"$alias\",\"input\":\"hello world\"}" "$base/v1/embeddings") || code=000
      [ "$code" = 200 ] || { echo "POST /v1/embeddings answered HTTP $code: $(head -c 200 "$BODY")"; return 1; }
      grep -Eq '"embedding"[[:space:]]*:[[:space:]]*\[[[:space:]]*-?[0-9]' "$BODY" ||
        { echo "no embedding in: $(head -c 200 "$BODY")"; return 1; }
      ;;
    *)
      code=$(curl -sS --max-time "$TIMEOUT" -o "$BODY" -w '%{http_code}' \
        -H 'Content-Type: application/json' \
        -d "{\"model\":\"$alias\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with the single word: ready\"}],\"max_tokens\":200,\"temperature\":0,\"reasoning_effort\":\"none\"}" \
        "$base/v1/chat/completions") || code=000
      [ "$code" = 200 ] || { echo "POST /v1/chat/completions answered HTTP $code: $(head -c 200 "$BODY")"; return 1; }
      grep -Eq '"content"[[:space:]]*:[[:space:]]*"[^"]' "$BODY" ||
        { echo "empty content in: $(head -c 200 "$BODY")"; return 1; }
      ;;
  esac
}

failed=0
# The record has the same fields for each script.
# shellcheck disable=SC2034
while IFS='|' read -r alias base shards port ctx extra kind; do
  [ -n "$alias" ] || continue
  attempt=1
  while :; do
    if reason=$(check "$alias" "$port" "${kind:-llm}"); then
      log "PASS: $alias port $port"
      break
    fi
    log "attempt $attempt of $ATTEMPTS failed for $alias: $reason"
    if [ "$attempt" -ge "$ATTEMPTS" ]; then
      log "FAIL: $alias port $port"
      failed=1
      break
    fi
    attempt=$((attempt + 1))
    sleep "$PAUSE"
  done
done <<EOT
$MODELS
EOT

exit "$failed"
