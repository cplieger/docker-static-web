#!/bin/sh
# Build-time smoke test for docker-static-web.
#
# Runs in the Dockerfile `test` stage (FROM the builder, which has the compiled
# binary + busybox wget/nc), so the centralized `ci / validate` docker
# build-ability gate executes it on every PR and push. Launches darkhttpd with
# the image's shipped default flags and asserts, end-to-end against the
# stripped, UPX-compressed binary, the behaviors the README advertises:
#
#   1. serves a file — proves the statically linked, UPX-compressed binary
#      actually executes and serves (a bad static-PIE link or UPX corruption
#      produces a binary that fails only at runtime, which the scratch final
#      image cannot otherwise catch)
#   2. --no-listing: a directory without an index must not leak its entries
#   3. --no-server-id: responses must not carry a Server: header
#   4. a malformed request must not kill the server
#
# Before any of that, check 0 pins the Dockerfile's literal ENTRYPOINT/CMD/
# WORKDIR/USER directives (assert_docker_directive; requires DOCKERFILE) so
# the hand-mirrored launch flags below cannot silently drift from the shipped
# image command.
#
# Run locally:  DARKHTTPD_BIN=/path/to/darkhttpd DOCKERFILE=./Dockerfile sh tests/smoke.sh
set -eu

BIN="${DARKHTTPD_BIN:-/src/darkhttpd}"
fail=0
log() { printf '%s\n' "$*"; }     # progress + final verdict -> stdout
err() { printf '%s\n' "$*" >&2; } # failures + captured output -> stderr

# --- 0. Dockerfile runtime-directive assertions: the launch below mirrors the
# image CMD by hand, so pin the shipped ENTRYPOINT/CMD lines against the
# Dockerfile itself — a future edit that drops a default flag from CMD must
# fail here instead of drifting silently past the test's independent copy.
: "${DOCKERFILE:?DOCKERFILE must name the Dockerfile under test}"
assert_docker_directive() {
  if ! grep -Fqx -- "$1" "$DOCKERFILE"; then
    err "FAIL: Dockerfile does not ship expected directive: $1"
    exit 1
  fi
}
assert_docker_directive 'ENTRYPOINT ["/darkhttpd"]'
assert_docker_directive 'CMD [".", "--port", "8567", "--maxconn", "128", "--no-listing", "--no-server-id"]'
# The CMD's "." document root resolves against WORKDIR, and the non-root
# contract lives in USER; pin both so a final-stage edit cannot silently
# change the served root or drop the non-root default.
assert_docker_directive 'WORKDIR /www'
assert_docker_directive 'USER 65534:65534'

root=$(mktemp -d)
srv_log=$(mktemp)
trap 'kill "${pid:-}" 2>/dev/null || true; rm -rf "$root" "$srv_log"' EXIT

# Require a valid HTTP status line on the FIRST response line only, so stray
# "HTTP/1" text in a header or body cannot satisfy the liveness prerequisite.
has_http_status() {
  printf '%s\n' "$1" | head -n 1 | grep -Eq '^HTTP/1\.[01] [0-9][0-9][0-9] '
}

# Dump the captured darkhttpd output on any runtime-failure branch so every
# failure path carries the same process diagnostic.
dump_server_log() {
  err '--- darkhttpd output (srv_log) ---'
  err "$(cat "$srv_log")"
  err '--- end darkhttpd output ---'
}
printf 'smoke-ok\n' >"$root/index.html"
mkdir "$root/nolist"
printf 'leak-check\n' >"$root/nolist/secret.txt"

# Capture darkhttpd's own output so a startup failure (bad static-PIE link or
# UPX corruption) shows WHY on failure instead of only a bare empty body.
# The flags mirror the image CMD (plus a test-only --addr 127.0.0.1 to keep
# the listener loopback-bound inside the build container; the CMD itself sets
# no --addr) so the test asserts the shipped defaults.
"$BIN" "$root" --port 8567 --addr 127.0.0.1 \
  --maxconn 128 --no-listing --no-server-id >"$srv_log" 2>&1 &
pid=$!

# --- 1. Happy path: poll until the listener answers (bounded), fetch the file.
body=''
i=0
while [ "$i" -lt 25 ]; do
  if body=$(wget -T 2 -qO- http://127.0.0.1:8567/index.html 2>/dev/null); then
    break
  fi
  i=$((i + 1))
  sleep 0.2
done

if [ "$body" != "smoke-ok" ]; then
  err "FAIL: darkhttpd did not serve the expected body (got: '$body')"
  dump_server_log
  fail=1
fi

# --- 2. --no-listing: require an observable response (404 = correctly denied;
# any 200 body must not name the directory contents). Fetch over nc and demand
# the status line so a dead/hung server or transient fetch failure is a hard
# FAIL, never a vacuous pass.
nolist_resp=$(printf 'GET /nolist/ HTTP/1.0\r\n\r\n' | nc -w 2 127.0.0.1 8567 || true)
if ! has_http_status "$nolist_resp"; then
  err "FAIL: could not capture a response to verify --no-listing"
  dump_server_log
  fail=1
elif printf '%s\n' "$nolist_resp" | grep -qF 'secret.txt'; then
  err "FAIL: directory listing leaked filenames despite --no-listing"
  err "$(printf '%s\n' "$nolist_resp" | head -n 10)"
  dump_server_log
  fail=1
fi

# --- 3. --no-server-id: the raw response must not carry a Server: header.
# Fetch over nc so the headers are captured verbatim (no wget quiet-flag
# interplay), and require the status line so a failed capture cannot
# vacuously pass the grep below.
resp=$(printf 'GET /index.html HTTP/1.0\r\n\r\n' | nc -w 2 127.0.0.1 8567 || true)
if ! has_http_status "$resp"; then
  err "FAIL: could not capture response headers to verify --no-server-id"
  dump_server_log
  fail=1
elif printf '%s\n' "$resp" | grep -qi '^server:'; then
  err "FAIL: response carries a Server: header despite --no-server-id"
  err "$(printf '%s\n' "$resp" | head -n 10)"
  dump_server_log
  fail=1
fi

# --- 4. Malformed request: the server must remain alive and keep serving.
printf 'not-a-http-request\r\n\r\n' | nc -w 2 127.0.0.1 8567 >/dev/null 2>&1 || true
after=$(wget -T 2 -qO- http://127.0.0.1:8567/index.html 2>/dev/null) || after=''
if [ "$after" != "smoke-ok" ]; then
  err "FAIL: server stopped serving after a malformed request"
  dump_server_log
  fail=1
fi

[ "$fail" -eq 0 ] && log "static-web smoke: ok"
exit "$fail"
