#!/bin/sh
set -eu

if [ -z "${SOCKS_USERNAME:-}" ] || [ -z "${SOCKS_PASSWORD:-}" ]; then
  echo "SOCKS_USERNAME and SOCKS_PASSWORD are required" >&2
  exit 1
fi

ARTI_SOCKS_HOST="${ARTI_SOCKS_HOST:-127.0.0.1}"
ARTI_SOCKS_PORT="${ARTI_SOCKS_PORT:-9151}"
DNS_LISTEN="${DNS_LISTEN:-127.0.0.1:8853}"

export UPSTREAM_SOCKS_HOST="$ARTI_SOCKS_HOST"
export UPSTREAM_SOCKS_PORT="$ARTI_SOCKS_PORT"

arti proxy \
  -o "proxy.socks_listen=\"$ARTI_SOCKS_HOST:$ARTI_SOCKS_PORT\"" \
  -o "proxy.dns_listen=\"$DNS_LISTEN\"" \
  "$@" &
arti_pid="$!"

python3 /usr/local/bin/auth-socks5-proxy.py &
auth_pid="$!"

stop_children() {
  kill "$arti_pid" "$auth_pid" 2>/dev/null || true
  wait "$arti_pid" "$auth_pid" 2>/dev/null || true
}

trap 'stop_children; exit 0' INT TERM

while kill -0 "$arti_pid" 2>/dev/null && kill -0 "$auth_pid" 2>/dev/null; do
  sleep 2
done

stop_children
exit 1
