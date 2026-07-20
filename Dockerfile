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
 && printf '%s  %s\n' "${DARKHTTPD_SHA256}" "${DARKHTTPD_VERSION}.tar.gz" | sha256sum -c - \
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
#
# readelf output is written to a file and then grepped, NOT piped into
# `grep -q`: `grep -q` exits at the first match and closes the pipe, so the
# large `readelf -sW` symbol-table dump dies on SIGPIPE writing to it, which
# `pipefail` (set via SHELL above) turns into a spurious exit 141 even though
# the symbol was found. Grepping a regular file has no pipe and no race.
# hadolint ignore=DL3018
RUN apk add --no-cache binutils \
 # Prove the compiler actually ran in strong mode: basic -fstack-protector
 # also emits __stack_chk_fail, so the symbol grep below cannot tell the
 # levels apart. __SSP_STRONG__=3 is predefined only by
 # -fstack-protector-strong, so this gate rejects a silent downgrade.
 && cc ${CFLAGS} -dM -E - </dev/null > /tmp/cc-macros \
 && grep -q '^#define __SSP_STRONG__ 3$' /tmp/cc-macros \
 && make darkhttpd 2>&1 | tee /tmp/make-log \
 # Couple the macro gate to the real compile: assert make's echoed cc line
 # carries the strong flag. v1.17's Makefile uses `CFLAGS?=-O` so the env
 # flags win today, but a future version bump whose Makefile hard-assigns
 # CFLAGS (or substitutes basic -fstack-protector) would pass BOTH the
 # compiler-capability probe above AND the __stack_chk_fail symbol grep
 # (basic mode also emits that symbol) while silently downgrading.
 && grep -q -- '-fstack-protector-strong' /tmp/make-log \
 # stack-protector lives in .symtab; verify BEFORE strip removes the symbol
 # table, otherwise the symbol can never be found and the build breaks.
 && readelf -sW darkhttpd > /tmp/elf-syms \
 && grep -q '__stack_chk_fail' /tmp/elf-syms \
 && strip --strip-all darkhttpd \
 && readelf -hW darkhttpd > /tmp/elf-hdr \
 && grep -q 'Type:.*DYN' /tmp/elf-hdr \
 && readelf -dW darkhttpd > /tmp/elf-dyn \
 && grep -q 'BIND_NOW' /tmp/elf-dyn \
 && ! grep -q 'NEEDED' /tmp/elf-dyn \
 && readelf -lW darkhttpd > /tmp/elf-seg \
 && grep -q 'GNU_RELRO' /tmp/elf-seg \
 && grep -q 'GNU_STACK' /tmp/elf-seg \
 && ! grep -q 'GNU_STACK.*RWE' /tmp/elf-seg \
 && rm -f /tmp/cc-macros /tmp/make-log /tmp/elf-syms /tmp/elf-hdr /tmp/elf-dyn /tmp/elf-seg \
 && upx --best --lzma darkhttpd \
 # Re-verify the PACKED stub: at execve the kernel takes stack permissions and
 # the ELF type (PIE/ASLR) from the SHIPPED file's headers, and upx rewrites
 # them, so the pre-pack assertions above prove the link, not the artifact.
 # Only header-level claims survive packing (the stub has no .dynamic), so
 # re-assert noexec stack + DYN here; RELRO/BIND_NOW stay link-time claims
 # proven pre-pack. If a upx bump ever rewrites these headers, this gate goes
 # red and the bump must be inspected before shipping.
 && readelf -hW darkhttpd > /tmp/upx-hdr \
 && grep -q 'Type:.*DYN' /tmp/upx-hdr \
 && readelf -lW darkhttpd > /tmp/upx-seg \
 && grep -q 'GNU_STACK' /tmp/upx-seg \
 && ! grep -q 'GNU_STACK.*RWE' /tmp/upx-seg \
 && rm -f /tmp/upx-hdr /tmp/upx-seg

# ---------------------------------------------------------------------------
# Test stage — runs the build-time smoke test against the final (stripped,
# UPX-compressed) binary: it serves a file end-to-end and asserts the shipped
# default flags (--no-listing, --no-server-id, malformed-request resilience),
# proving the static-PIE link and UPX packing produced a working executable. A
# failure here fails the centralized `ci / validate` docker build gate, because
# the scratch final stage copies the binary from this stage. The builder base
# has busybox wget + nc.
# ---------------------------------------------------------------------------
FROM builder AS test
COPY tests/ /tmp/tests/
RUN sh /tmp/tests/smoke.sh

FROM scratch

COPY --from=test --chmod=755 /src/darkhttpd /darkhttpd

WORKDIR /www
EXPOSE 8567

# Run as a non-root, no-/etc/passwd numeric uid:gid (nobody:nogroup). darkhttpd
# binds a high port (8567) and only reads files, so it never needs root.
USER 65534:65534

ENTRYPOINT ["/darkhttpd"]
CMD [".", "--port", "8567", "--maxconn", "128", "--no-listing", "--no-server-id"]
