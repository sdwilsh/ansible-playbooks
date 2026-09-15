#!/bin/sh
# Take the place of `llama-server` in the end-to-end test.  Report the
# arguments, then answer `/health`.
set -eu

echo "starting $*"

host=127.0.0.1
port=8080
while [ "$#" -gt 0 ]; do
  case "$1" in
    --host) host="$2"; shift 2 ;;
    --port) port="$2"; shift 2 ;;
    *) shift ;;
  esac
done

echo "listening on $host:$port"

exec /command/s6-tcpserver "$host" "$port" /bin/sh -c \
  'printf "HTTP/1.1 200 OK\r\nContent-Length: 3\r\nConnection: close\r\n\r\nok\n"'
