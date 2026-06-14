# docker-static-web

[![CI](https://github.com/cplieger/docker-static-web/actions/workflows/ci.yaml/badge.svg)](https://github.com/cplieger/docker-static-web/actions/workflows/ci.yaml)
[![GitHub release](https://img.shields.io/github/v/release/cplieger/docker-static-web)](https://github.com/cplieger/docker-static-web/releases)
[![Image Size](https://ghcr-badge.egpl.dev/cplieger/docker-static-web/size)](https://github.com/cplieger/docker-static-web/pkgs/container/docker-static-web)
![Platforms](https://img.shields.io/badge/platforms-amd64%20%7C%20arm64-blue)
![base: scratch](https://img.shields.io/badge/base-scratch-2496ED?logo=docker)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/cplieger/docker-static-web/badge)](https://scorecard.dev/viewer/?uri=github.com/cplieger/docker-static-web)
[![OpenSSF Best Practices](https://www.bestpractices.dev/projects/13211/badge)](https://www.bestpractices.dev/projects/13211)

A static file server in **~30 KB**: [darkhttpd](https://github.com/emikulic/darkhttpd) compiled statically with hardening flags, UPX-compressed, on `scratch`.

## What it does

Serves static files over HTTP. That's it. The image is essentially a single tiny binary on a scratch base — no shell, no libc, no package manager, no auth, no TLS, no fancy config. Mount your document root at `/www` and darkhttpd serves it on port `8567`.

This is the smallest viable container for serving static content. Use it for:

- **Internal-only static sites** behind a reverse proxy (which handles TLS, auth, and rate-limiting)
- **Health-check landing pages**
- **`/.well-known/` ACME challenges** when you need a separate webroot
- **CI/test fixtures** where you want to serve files without spinning up nginx

### Why this design

- **Scratch base** — image is essentially the binary itself. No shell to exec, no package manager to attack
- **UPX-compressed binary** — runtime memory is tiny; the binary unpacks itself in-process
- **Hardening flags** — `-D_FORTIFY_SOURCE=2`, `-fstack-clash-protection`, `-fstack-protector-strong`, RELRO + BIND_NOW + NOEXEC stack at link time
- **Static-PIE linking** — `-static-pie` (with `-fPIE`) so the binary has zero dependencies and runs identically on amd64 and arm64, while keeping ASLR for the main executable
- **Non-root by default** — runs as `USER 65534:65534` (nobody); binds a high port and only reads files, so it never needs root. Override via compose `user:`
- **Sane darkhttpd defaults** — `--maxconn 128 --no-listing --no-server-id`: connection cap to limit DoS impact, no directory indexes, no `Server:` header leaking the version
- **Tarball integrity check** — Dockerfile pins `DARKHTTPD_SHA256` so a tampered tarball fails the build

## Quick start

Available from both `ghcr.io/cplieger/docker-static-web` and `docker.io/cplieger/docker-static-web` — identical images and tags.

```yaml
services:
  static-web:
    image: ghcr.io/cplieger/docker-static-web:latest
    container_name: static-web
    restart: unless-stopped

    ports:
      - "8567:8567"

    # Mount your document root read-only.
    volumes:
      - ./www:/www:ro
```

Behind a reverse proxy (e.g. Caddy):

```caddy
static.example.com {
    reverse_proxy static-web:8567
}
```

## Configuration reference

### Volumes

| Mount | Description |
|-------|-------------|
| `/www` | Document root. Mount read-only. darkhttpd serves files from here. |

### Ports

| Port | Protocol | Purpose |
|------|----------|---------|
| `8567` | TCP | HTTP — change in `command:` if you want a different port |

### Default command

The Dockerfile's `CMD` is:

```dockerfile
CMD [".", "--port", "8567", "--maxconn", "128", "--no-listing", "--no-server-id"]
```

Override the entire command if you want different darkhttpd flags:

```yaml
services:
  static-web:
    image: ghcr.io/cplieger/docker-static-web:latest
    command: [".", "--port", "80", "--maxconn", "256", "--no-listing"]
    ports:
      - "80:80"
    volumes:
      - ./www:/www:ro
```

See [`darkhttpd --help`](https://unix4lyfe.org/darkhttpd/) for all available flags.

### Running as non-root

The image runs as a non-root user by default: the Dockerfile sets `USER 65534:65534` (the `nobody:nogroup` numeric uid:gid — numeric because `scratch` has no `/etc/passwd`). darkhttpd binds a high port (8567) and only reads files, so it never needs root. A plain `docker run` is non-root automatically.

To run as a different uid:gid, set `user:` in compose — the compose value overrides the image default, no rebuild needed:

```yaml
services:
  static-web:
    image: ghcr.io/cplieger/docker-static-web:latest
    user: "1000:1000"
    volumes:
      - ./www:/www:ro
```

Whatever uid you pick must have read access to the files mounted at `/www`.

### Logging and log rotation

darkhttpd writes one Common Log Format line per request to stdout. Docker's default `json-file` driver does **not** rotate, so on a busy server the logs can grow until they fill the host disk. Log rotation is a runtime/daemon setting and cannot be baked into the image — set it in compose (or in the daemon's `log-opts`):

```yaml
services:
  static-web:
    image: ghcr.io/cplieger/docker-static-web:latest
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    volumes:
      - ./www:/www:ro
```

If a reverse proxy in front (e.g. Caddy) already records access logs, you can instead silence darkhttpd's request log entirely by appending `--no-log` to the command:

```yaml
    command: [".", "--port", "8567", "--maxconn", "128", "--no-listing", "--no-server-id", "--no-log"]
```

## Healthcheck

**No built-in healthcheck.** The scratch base has no shell, no `wget`, no `curl`, no `nc`. Docker can't run a healthcheck inside the container without one of those.

For external monitoring, use Uptime Kuma, Prometheus blackbox exporter, or any other off-host probe:

```bash
curl -sf http://your-host:8567/ -o /dev/null && echo OK
```

If you really need a Docker-level healthcheck, the typical pattern is to run a sidecar that hits the static-web container — but for most homelab uses, an external HTTP probe is simpler and more meaningful (it verifies the network path too).

## What it doesn't do

- **No TLS** — put it behind a reverse proxy that terminates HTTPS
- **No auth** — same; let your reverse proxy handle access control
- **No directory listings** — disabled by default (`--no-listing`)
- **No CGI / dynamic content** — it's a static file server
- **No HTTP/2 or HTTP/3** — HTTP/1.1 only; let your reverse proxy upgrade the public-facing connection

If you need any of these, use Caddy / nginx / a real web server.

## Security

| Tool | Result |
|------|--------|
| [hadolint](https://github.com/hadolint/hadolint) | Clean |
| [gitleaks](https://github.com/gitleaks/gitleaks) | No secrets detected |
| [trivy](https://trivy.dev/) | 0 vulnerabilities (scratch base, no OS packages to scan) |

The image is published with [cosign](https://github.com/sigstore/cosign) signatures and SBOM attestations.

The build pins `DARKHTTPD_SHA256` and verifies the upstream tarball before extracting. **When Renovate bumps `DARKHTTPD_VERSION`**, you must manually update `DARKHTTPD_SHA256` in the same PR — Renovate bumps only the version, not the hash, so the bump PR fails the `sha256sum -c` integrity check until you update the SHA by hand. Compute the new hash with:

```bash
curl -sL https://github.com/emikulic/darkhttpd/archive/refs/tags/v<N>.tar.gz | sha256sum
```

## Image size

The image is essentially just the binary (see the Image Size badge at the top) — there's no Alpine layer, no `/etc`, no `/lib`, nothing else. `docker run --rm ghcr.io/cplieger/docker-static-web ls /` won't work (no `ls` in `scratch`).

## Dependencies

All dependencies are updated automatically via [Renovate](https://github.com/renovatebot/renovate). The base image is pinned by SHA digest and `darkhttpd` by tag + SHA-256; the `build-base`/`upx` build packages are installed unpinned so they track the digest-pinned base.

| Dependency | Source |
|------------|--------|
| alpine (builder) | [Docker Hub](https://hub.docker.com/_/alpine) |
| build-base | [Alpine](https://pkgs.alpinelinux.org/packages?name=build-base) |
| upx | [Alpine](https://pkgs.alpinelinux.org/packages?name=upx) |
| darkhttpd | [GitHub](https://github.com/emikulic/darkhttpd) |

## Credits

This project packages [darkhttpd](https://github.com/emikulic/darkhttpd) by [@emikulic](https://github.com/emikulic) into a `scratch`-based container. All credit for the web server itself goes to the upstream maintainer — darkhttpd has been "small, secure, and fast" since 2003.

## Contributing

Issues and pull requests are welcome. Please open an issue first for larger changes so the approach can be discussed before implementation.

## Disclaimer

This image is built with care and follows security best practices, but it is intended for **homelab use**. No guarantees of fitness for production environments. Use at your own risk.

This project was built with AI-assisted tooling using [Claude Opus](https://www.anthropic.com/claude) and [Kiro](https://kiro.dev). The human maintainer defines architecture, supervises implementation, and makes all final decisions.

## License

This project is licensed under the [GNU General Public License v3.0](LICENSE).
