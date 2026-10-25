#!/bin/sh
# Write one s6 service for each record in `MODELS`.  A record is one line
# with seven fields, and a "|" between each field:
#   alias|base URL|shard names|port|context size|extra arguments|kind
# The shard names have a space between each name.  The server finds the
# other shards from the first name.  The extra arguments and the kind are
# optional.  The kind is `llm`, `asr` or `embedding`, and empty means `llm`.
# An `asr` or `embedding` record has a model directory in place of the
# shard names.  An `embedding` record has no context size.
# This script puts the extra arguments at the end of the command line.
# An argument there replaces the same argument from this script.
# The script rejects `--host` and `--port` there.  It also rejects the short
# forms `-i` and `-p`.
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
while IFS='|' read -r alias base shards port ctx extra kind; do
  [ -n "$alias" ] || continue

  case "$kind" in
    *'|'*) fatal "record $alias has more than seven fields" ;;
  esac
  for field in "$base" "$shards" "$port"; do
    [ -n "$field" ] || fatal "record $alias has an empty field"
  done
  case "$kind" in
    ''|llm) kind=llm ;;
    asr|embedding) ;;
    *) fatal "kind $kind of $alias is not llm, asr or embedding" ;;
  esac
  # `gufo serve asr` has a default context.  `gufo serve embedding` has
  # no context option.
  { [ -n "$ctx" ] || [ "$kind" != llm ]; } ||
    fatal "record $alias has an empty field"
  { [ -z "$ctx" ] || [ "$kind" != embedding ]; } ||
    fatal "record $alias is embedding and has a context size"

  # The alias becomes a service directory name and an argument of the
  # `run` script.  A canonical model name holds a dot.
  case "$alias" in
    *[!a-zA-Z0-9._-]*)
      fatal "alias $alias has a character outside A-Z a-z 0-9 . _ -" ;;
  esac
  # `gufo` takes the argument after `--served-model-name` as the alias,
  # even an option.  A dash at the start gives the wrong alias, or the server
  # does not start.
  case "$alias" in
    -*) fatal "alias $alias starts with a dash" ;;
  esac
  # A dot at the edge of the alias is a directory entry of its own, or it
  # hides the service directory from `s6-rc-compile`.  Two dots together
  # belong to no model name.
  case "$alias" in
    .*) fatal "alias $alias starts with a dot" ;;
    *.) fatal "alias $alias ends with a dot" ;;
    *..*) fatal "alias $alias has two dots together" ;;
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
  # The `run` script below holds the extra arguments, and a shell reads
  # that file.  This list allows only letters, numbers, a space and the
  # five symbols that an option needs.
  case "$extra" in
    *[!A-Za-z0-9\ ._=/-]*)
      fatal "extra arguments of $alias have a character outside A-Z a-z 0-9 space . _ = / -" ;;
  esac
  # The script sets the address of the server.  The probes use that address.
  # shellcheck disable=SC2086
  for word in $extra; do
    case "$word" in
      --host|--host=*|--port|--port=*|-i|-p)
        fatal "extra arguments of $alias repeat --host or --port" ;;
    esac
  done

  # shellcheck disable=SC2086
  set -- $shards
  if [ "$kind" != llm ]; then
    [ -d "/models/$1" ] || fatal "/models/$1 of $alias is not a directory"
    command="gufo serve $kind"
    context=""
    [ -z "$ctx" ] || context="--context $ctx"
  else
    [ -f "/models/$1" ] || fatal "/models/$1 of $alias is missing"
    command="gufo serve llm"
    context="--context $ctx"
  fi

  mkdir -p "$bundledir/$alias/dependencies.d" \
    "$bundledir/$alias-log/dependencies.d"
  echo longrun > "$bundledir/$alias/type"
  echo "$alias-log" > "$bundledir/$alias/producer-for"
  : > "$bundledir/$alias/dependencies.d/base"
  # `gufo` stops at start if `TMPDIR` is not a directory.  The `run` script
  # makes one directory for each service.
  cat > "$bundledir/$alias/run" <<EOF
#!/command/with-contenv sh
exec 2>&1
TMPDIR=/tmp/gufo-$alias
export TMPDIR
mkdir -p "\$TMPDIR"
exec $command --host "\$POD_IP" --port $port --model /models/$1 $context --served-model-name "$alias" $extra
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
