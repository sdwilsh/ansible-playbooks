#!/bin/sh
# Write one s6 service for each record in `MODELS`.  A record is one line
# with five fields, and a "|" between each field:
#   alias|base URL|shard names|port|context size
# The shard names have a space between each name.  The server finds the
# other shards from the first name.
#
# `rc.init` runs this script as `S6_STAGE2_HOOK`, before it compiles the
# service database.  s6 removes the environment first, so `printcontenv`
# reads each value.
set -eu

fatal() {
  echo "generate-model-services.sh: fatal: $*" >&2
  exit 1
}

bundledir=$(printcontenv S6_RUNTIME_BUNDLEDIR || true)
[ -n "$bundledir" ] || fatal "S6_RUNTIME_BUNDLEDIR has no value"
models=$(printcontenv MODELS || true)
[ -n "$models" ] || fatal "MODELS has no value"
pod_ip=$(printcontenv POD_IP || true)
[ -n "$pod_ip" ] || fatal "POD_IP has no value"

# `/run` lives through a container restart.  A tree from the last boot
# starts a model that `MODELS` no longer holds.
rm -rf "$bundledir"
mkdir -p "$bundledir/user/contents.d" "$bundledir/user2/contents.d"
echo bundle > "$bundledir/user/type"
echo bundle > "$bundledir/user2/type"

ports=""

# The record has the same fields for each script.
# shellcheck disable=SC2034
while IFS='|' read -r alias base shards port ctx; do
  [ -n "$alias" ] || continue

  case "$ctx" in
    *'|'*) fatal "record $alias has more than five fields" ;;
  esac
  for field in "$base" "$shards" "$port" "$ctx"; do
    [ -n "$field" ] || fatal "record $alias does not have five fields"
  done

  # The `run` script takes the alias as a word.  Another character
  # truncates the argument list.
  case "$alias" in
    *[!a-zA-Z0-9_-]*) fatal "alias $alias has a character that s6 rejects" ;;
  esac
  # This script writes `user`, `user2` and `<alias>-log` of its own.  An
  # alias with one of these names replaces that file.
  case "$alias" in
    user|user2|*-log) fatal "alias $alias is a name that s6-overlay uses" ;;
  esac
  case "$port" in
    *[!0-9]*) fatal "port $port of $alias is not a number" ;;
    0*) fatal "port $port of $alias has a leading zero" ;;
  esac
  { [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; } ||
    fatal "port $port of $alias is out of range"
  case " $ports " in
    *" $port "*) fatal "port $port belongs to two records" ;;
  esac
  ports="$ports $port"
  case "$ctx" in
    *[!0-9]*) fatal "context size $ctx of $alias is not a number" ;;
  esac

  # shellcheck disable=SC2086
  set -- $shards
  [ -f "/models/$1" ] || fatal "/models/$1 of $alias is missing"

  mkdir -p "$bundledir/$alias/dependencies.d" \
    "$bundledir/$alias-log/dependencies.d"
  echo longrun > "$bundledir/$alias/type"
  echo "$alias-log" > "$bundledir/$alias/producer-for"
  : > "$bundledir/$alias/dependencies.d/base"
  cat > "$bundledir/$alias/run" <<EOF
#!/command/with-contenv sh
cd /app
exec 2>&1
exec ./llama-server -m /models/$1 -a $alias --host "\$POD_IP" --port $port --ctx-size $ctx --metrics -fa on -ngl 999 --parallel 1
EOF

  # The "1" sends each line to standard output.
  echo longrun > "$bundledir/$alias-log/type"
  echo "$alias" > "$bundledir/$alias-log/consumer-for"
  echo "$alias-pipeline" > "$bundledir/$alias-log/pipeline-name"
  : > "$bundledir/$alias-log/dependencies.d/base"
  cat > "$bundledir/$alias-log/run" <<EOF
#!/command/with-contenv sh
exec /command/s6-log -b -- "p[$alias]" 1
EOF

  chmod 0755 "$bundledir/$alias/run" "$bundledir/$alias-log/run"

  # This file starts the pipeline.
  : > "$bundledir/user/contents.d/$alias-pipeline"
done <<EOF
$models
EOF

[ -n "$ports" ] || fatal "MODELS has no record"

# `rc.init` compiles the same tree.  A fatal there leaves the container up
# with no service.  A fatal here stops the container.
rm -rf /tmp/s6-rc-db-check
s6-rc-compile /tmp/s6-rc-db-check /etc/s6-overlay/s6-rc.d "$bundledir" \
  /package/admin/s6-overlay/etc/s6-rc/sources
rm -rf /tmp/s6-rc-db-check

echo "generate-model-services.sh: wrote a service for each of$ports" >&2
