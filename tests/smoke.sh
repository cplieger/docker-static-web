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
log() { printf '%s\n' "$*"; }

root=$(mktemp -d)
printf 'smoke-ok\n' >"$root/index.html"

"$BIN" "$root" --port 8567 --addr 127.0.0.1 >/dev/null 2>&1 &
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

kill "$pid" 2>/dev/null || true

if [ "$body" != "smoke-ok" ]; then
	log "FAIL: darkhttpd did not serve the expected body (got: '$body')"
	fail=1
fi

[ "$fail" -eq 0 ] && log "static-web smoke: ok"
exit "$fail"
