# check=error=true
FROM alpine:3.24.1@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b AS builder

# renovate: datasource=github-tags depName=emikulic/darkhttpd
ARG DARKHTTPD_VERSION=v1.17
# When DARKHTTPD_VERSION is bumped, update this SHA256 to match the new tarball.
# Renovate can't recompute it (github-tags exposes the git sha, not the archive
# hash), so it labels the bump PR `manual-sha-bump` and puts this command in the
# PR body — run it, paste the result here, push:
# curl -sL https://github.com/emikulic/darkhttpd/archive/refs/tags/v<N>.tar.gz | sha256sum
ARG DARKHTTPD_SHA256=4fee9927e2d8bb0a302f0dd62f9ff1e075748fa9f5162c9481a7a58b41462b56

SHELL ["/bin/ash", "-eo", "pipefail", "-c"]
# build-base/upx are build-only (absent from the scratch final image), so their
# exact versions never reach the shipped artifact and are intentionally left
# unpinned — they track whatever the Alpine 3.24 repo serves at build time (the
# digest pins the base image, not the apk repository index). darkhttpd stays
# version+SHA pinned below — it is the shipped artifact.
# hadolint ignore=DL3018
RUN apk add --no-cache build-base upx \
 && wget -q --tries=3 --timeout=30 \
    "https://github.com/emikulic/darkhttpd/archive/refs/tags/${DARKHTTPD_VERSION}.tar.gz" \
 && echo "${DARKHTTPD_SHA256}  ${DARKHTTPD_VERSION}.tar.gz" | sha256sum -c - \
 && tar xf "${DARKHTTPD_VERSION}.tar.gz" --no-same-owner \
 && mv "darkhttpd-${DARKHTTPD_VERSION#v}" /src \
 && rm "${DARKHTTPD_VERSION}.tar.gz"

WORKDIR /src
ENV CFLAGS="-fPIE -O2 -flto -D_FORTIFY_SOURCE=2 \
  -fstack-clash-protection -fstack-protector-strong -pipe \
  -Wall -Werror=format-security \
  -Werror=implicit-function-declaration"
ENV LDFLAGS="-static-pie -Wl,-z,defs -Wl,-z,now -Wl,-z,relro -Wl,-z,noexecstack"
# The stack-protector symbol check runs on the unstripped binary; the four
# program-header / .dynamic checks run after strip (strip preserves those, so
# they still see the real hardened ELF). upx then rewrites it into a packed
# stub. Each grep is fail-closed: a dropped protection breaks the chained
# `&&` and fails the centralized `ci / validate` docker-build gate, so the
# README/steering hardening claims (static-PIE, RELRO/BIND_NOW, noexec stack,
# stack-protector) become enforced instead of aspirational. binutils is
# build-only and never reaches the scratch final image, matching the existing
# build-base/upx pattern.
# hadolint ignore=DL3018
RUN apk add --no-cache binutils \
 && make darkhttpd \
 # stack-protector lives in .symtab; verify BEFORE strip removes the symbol
 # table, otherwise this grep can never match and breaks the build.
 && readelf -sW darkhttpd | grep -q '__stack_chk_fail' \
 && strip --strip-all darkhttpd \
 && readelf -hW darkhttpd | grep -q 'Type:.*DYN' \
 && readelf -dW darkhttpd | grep -q 'BIND_NOW' \
 && readelf -lW darkhttpd | grep -q 'GNU_RELRO' \
 && ! readelf -lW darkhttpd | grep 'GNU_STACK' | grep -q 'RWE' \
 && upx --best --lzma darkhttpd

# ---------------------------------------------------------------------------
# Test stage — runs the build-time smoke test against the final (stripped,
# UPX-compressed) binary: it serves a file end-to-end, proving the static-PIE
# link and UPX packing produced a working executable. A failure here fails the
# centralized `ci / validate` docker build gate, because the scratch final
# stage depends on this stage's marker. The builder base has busybox wget.
# ---------------------------------------------------------------------------
FROM builder AS test
COPY tests/ /tmp/tests/
RUN sh /tmp/tests/smoke.sh && touch /tests-passed

FROM scratch

COPY --from=builder /src/darkhttpd /darkhttpd
# 0-byte marker carried over only to force the test stage to build and pass.
COPY --from=test /tests-passed /tests-passed

WORKDIR /www
EXPOSE 8567

# Run as a non-root, no-/etc/passwd numeric uid:gid (nobody:nogroup). darkhttpd
# binds a high port (8567) and only reads files, so it never needs root.
USER 65534:65534

ENTRYPOINT ["/darkhttpd"]
CMD [".", "--port", "8567", "--maxconn", "128", "--no-listing", "--no-server-id"]
