#!/bin/sh
set -eu

SOCKS_HOST="${SOCKS_HOST:-127.0.0.1}"
SOCKS_PORT="${SOCKS_PORT:-9150}"
HEALTHCHECK_URL="${HEALTHCHECK_URL:-https://check.torproject.org/api/ip}"
HEALTHCHECK_EXPECTED="${HEALTHCHECK_EXPECTED:-\"IsTor\":true}"
HEALTHCHECK_MAX_TIME="${HEALTHCHECK_MAX_TIME:-30}"

output="$(
  curl \
    --fail \
    --silent \
    --show-error \
    --max-time "$HEALTHCHECK_MAX_TIME" \
    --socks5-hostname "$SOCKS_HOST:$SOCKS_PORT" \
    "$HEALTHCHECK_URL"
)"

if [ -n "$HEALTHCHECK_EXPECTED" ]; then
  printf '%s' "$output" | grep -q "$HEALTHCHECK_EXPECTED"
fi
