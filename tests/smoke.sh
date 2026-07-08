#!/bin/sh
# Build-time smoke test for docker-static-web.
#
# Runs in the Dockerfile `test` stage (FROM the builder, which has the compiled
# binary + busybox wget), so the centralized `ci / validate` docker
# build-ability gate executes it on every PR and push. Serves a file
# end-to-end, which proves the statically linked, UPX-compressed darkhttpd
# binary actually executes and serves — the real risk for this image (a bad
# static-PIE link or UPX corruption produces a binary that fails only at
# runtime, which the scratch final image cannot otherwise catch).
#
# Run locally:  DARKHTTPD_BIN=/path/to/darkhttpd sh tests/smoke.sh
set -eu

BIN="${DARKHTTPD_BIN:-/src/darkhttpd}"
fail=0
log() { printf '%s\n' "$*"; }     # progress + final verdict -> stdout
err() { printf '%s\n' "$*" >&2; } # failures + captured output -> stderr

root=$(mktemp -d)
srv_log=$(mktemp)
trap 'kill "${pid:-}" 2>/dev/null || true; rm -rf "$root" "$srv_log"' EXIT
printf 'smoke-ok\n' >"$root/index.html"

# Capture darkhttpd's own output so a startup failure (bad static-PIE link or
# UPX corruption) shows WHY on failure instead of only a bare empty body.
"$BIN" "$root" --port 8567 --addr 127.0.0.1 >"$srv_log" 2>&1 &
pid=$!

# Poll until the listener answers (bounded), then fetch the file.
body=''
i=0
while [ "$i" -lt 25 ]; do
  if body=$(wget -qO- http://127.0.0.1:8567/index.html 2>/dev/null); then
    break
  fi
  i=$((i + 1))
  sleep 0.2
done

if [ "$body" != "smoke-ok" ]; then
  err "FAIL: darkhttpd did not serve the expected body (got: '$body')"
  err "$(cat "$srv_log")"
  fail=1
fi

[ "$fail" -eq 0 ] && log "static-web smoke: ok"
exit "$fail"
