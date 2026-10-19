#!/bin/sh
# Take the place of `gufo` in the end-to-end test.  Check the arguments,
# report them, then answer `/health`.  A fault in the arguments exits
# with status 2, and no server starts.
set -eu

fail() {
  echo "stub-gufo: $*" >&2
  exit 2
}

echo "starting $*"

[ "${1:-}" = serve ] || fail "the first argument is not serve"
kind=${2:-}
case "$kind" in
  llm | asr) ;;
  *) fail "the subcommand $kind is not llm or asr" ;;
esac
shift 2

host=""
port=""
model=""
context=""
name=""
speculative=""
draft=""
mmproj=""
while [ "$#" -gt 0 ]; do
  # These options take no value.
  case "$1" in
    -v | --log-progress)
      shift
      continue
      ;;
  esac
  [ "$#" -ge 2 ] || fail "the option $1 has no value"
  case "$1" in
    --host) host="$2" ;;
    --port) port="$2" ;;
    --model) model="$2" ;;
    --context) context="$2" ;;
    --served-model-name) name="$2" ;;
    --speculative) speculative="$2" ;;
    --dflash-model) draft="$2" ;;
    --mmproj) mmproj="$2" ;;
    *) fail "the option $1 is unknown" ;;
  esac
  shift 2
done

for pair in host:"$host" port:"$port" model:"$model" name:"$name"; do
  [ -n "${pair#*:}" ] || fail "the option ${pair%%:*} has no value"
done
[ -n "${TMPDIR:-}" ] && [ -d "$TMPDIR" ] || fail "TMPDIR is not a directory"

if [ "$kind" = asr ]; then
  [ -d "$model" ] || fail "the ASR model $model is not a directory"
  [ -z "$speculative$draft$mmproj" ] || fail "asr takes no LLM option"
else
  [ -f "$model" ] || fail "the model $model is not a file"
  [ -n "$context" ] || fail "llm needs --context"
fi
if [ -n "$speculative" ]; then
  [ "$speculative" = dflash2 ] || fail "the mode $speculative is unknown"
  [ -f "$draft" ] || fail "the draft model $draft is not a file"
fi
if [ -n "$mmproj" ]; then
  [ -f "$mmproj" ] || fail "the projector $mmproj is not a file"
fi

echo "tmpdir $TMPDIR"
echo "listening on $host:$port"

exec /command/s6-tcpserver "$host" "$port" /bin/sh -c \
  'printf "HTTP/1.1 200 OK\r\nContent-Length: 3\r\nConnection: close\r\n\r\nok\n"'
