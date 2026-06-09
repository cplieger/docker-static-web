# check=error=true
FROM alpine:3.24.0@sha256:660e0827bd401543d81323d4886abbd08fda0fe3ba84337837d0b11a67251283 AS builder

# renovate: datasource=github-tags depName=emikulic/darkhttpd
ARG DARKHTTPD_VERSION=v1.17
# When DARKHTTPD_VERSION is bumped, update this SHA256 to match the new tarball.
# curl -sL https://github.com/emikulic/darkhttpd/archive/refs/tags/v<N>.tar.gz | sha256sum
ARG DARKHTTPD_SHA256=4fee9927e2d8bb0a302f0dd62f9ff1e075748fa9f5162c9481a7a58b41462b56

SHELL ["/bin/ash", "-eo", "pipefail", "-c"]
RUN apk add --no-cache build-base=0.5-r3 upx=5.0.2-r0 \
 && wget -q --tries=3 --timeout=30 \
    "https://github.com/emikulic/darkhttpd/archive/refs/tags/${DARKHTTPD_VERSION}.tar.gz" \
 && echo "${DARKHTTPD_SHA256}  ${DARKHTTPD_VERSION}.tar.gz" | sha256sum -c - \
 && tar xf "${DARKHTTPD_VERSION}.tar.gz" --no-same-owner \
 && mv "darkhttpd-${DARKHTTPD_VERSION#v}" /src \
 && rm "${DARKHTTPD_VERSION}.tar.gz"

WORKDIR /src
ENV CFLAGS="-static -O2 -flto -D_FORTIFY_SOURCE=2 \
  -fstack-clash-protection -fstack-protector-strong -pipe \
  -Wall -Werror=format-security \
  -Werror=implicit-function-declaration"
ENV LDFLAGS="-Wl,-z,defs -Wl,-z,now -Wl,-z,relro -Wl,-z,noexecstack"
RUN make darkhttpd \
 && strip --strip-all darkhttpd \
 && upx --best --lzma darkhttpd

FROM scratch

COPY --from=builder /src/darkhttpd /darkhttpd

WORKDIR /www
EXPOSE 8567

ENTRYPOINT ["/darkhttpd"]
CMD [".", "--port", "8567", "--maxconn", "128", "--no-listing", "--no-server-id"]
