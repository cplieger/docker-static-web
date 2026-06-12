# docker-static-web

[![CI](https://github.com/cplieger/docker-static-web/actions/workflows/ci.yaml/badge.svg)](https://github.com/cplieger/docker-static-web/actions/workflows/ci.yaml)
[![GitHub release](https://img.shields.io/github/v/release/cplieger/docker-static-web)](https://github.com/cplieger/docker-static-web/releases)
[![Image Size](https://ghcr-badge.egpl.dev/cplieger/docker-static-web/size)](https://github.com/cplieger/docker-static-web/pkgs/container/docker-static-web)
![Platforms](https://img.shields.io/badge/platforms-amd64%20%7C%20arm64-blue)
![base: scratch](https://img.shields.io/badge/base-scratch-2496ED?logo=docker)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/cplieger/docker-static-web/badge)](https://scorecard.dev/viewer/?uri=github.com/cplieger/docker-static-web)

A static file server in **~30 KB**: [darkhttpd](https://github.com/emikulic/darkhttpd) compiled statically with hardening flags, UPX-compressed, on `scratch`.

## What it does

Serves static files over HTTP. That's it. The image is essentially a single ~30 KB binary on a scratch base — no shell, no libc, no package manager, no auth, no TLS, no fancy config. Mount your document root at `/www` and darkhttpd serves it on port `8567`.

This is the smallest viable container for serving static content. Use it for:

- **Internal-only static sites** behind a reverse proxy (which handles TLS, auth, and rate-limiting)
- **Health-check landing pages**
- **`/.well-known/` ACME challenges** when you need a separate webroot
- **CI/test fixtures** where you want to serve files without spinning up nginx

### Why this design

- **Scratch base** — image is essentially the binary itself, ~30 KB compressed. No shell to exec, no package manager to attack
- **UPX-compressed binary** — runtime memory is tiny; the binary unpacks itself in-process
- **Hardening flags** — `-D_FORTIFY_SOURCE=2`, `-fstack-clash-protection`, `-fstack-protector-strong`, RELRO + BIND_NOW + NOEXEC stack at link time
- **Static linking** — `--static` so the binary has zero dependencies, runs identically on amd64 and arm64
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

The build pins `DARKHTTPD_SHA256` and verifies the upstream tarball before extracting. **When Renovate bumps `DARKHTTPD_VERSION`**, you must manually update `DARKHTTPD_SHA256` in the same PR — Renovate is configured to require manual approval for darkhttpd bumps for exactly this reason. Compute the new hash with:

```bash
curl -sL https://github.com/emikulic/darkhttpd/archive/refs/tags/v<N>.tar.gz | sha256sum
```

## Image size

The image is roughly 30 KB compressed (see the badge at the top). The binary is the entire image — there's no Alpine layer, no `/etc`, no `/lib`, nothing else. `docker run --rm ghcr.io/cplieger/docker-static-web ls /` won't work (no `ls` in `scratch`).

## Dependencies

All dependencies are updated automatically via [Renovate](https://github.com/renovatebot/renovate) and pinned by digest or version for reproducibility.

| Dependency | Version | Source |
|------------|---------|--------|
| alpine (builder) | `3.23.4` | [Docker Hub](https://hub.docker.com/_/alpine) |
| build-base | `0.5-r3` (Alpine 3.23 meta-package) | [Alpine](https://pkgs.alpinelinux.org/package/v3.23/main/x86_64/build-base) |
| upx | `5.0.2-r0` (Alpine 3.23 package) | [Alpine](https://pkgs.alpinelinux.org/package/v3.23/main/x86_64/upx) |
| darkhttpd | `v1.17` | [GitHub](https://github.com/emikulic/darkhttpd) |

## Credits

This project packages [darkhttpd](https://github.com/emikulic/darkhttpd) by [@emikulic](https://github.com/emikulic) into a `scratch`-based container. All credit for the web server itself goes to the upstream maintainer — darkhttpd has been "small, secure, and fast" since 2003.

## Contributing

Issues and pull requests are welcome. Please open an issue first for larger changes so the approach can be discussed before implementation.

## Disclaimer

This image is built with care and follows security best practices, but it is intended for **homelab use**. No guarantees of fitness for production environments. Use at your own risk.

This project was built with AI-assisted tooling using [Claude Opus](https://www.anthropic.com/claude) and [Kiro](https://kiro.dev). The human maintainer defines architecture, supervises implementation, and makes all final decisions.

## License

This project is licensed under the [GNU General Public License v3.0](LICENSE).
