# docker-static-web

[![Image Size](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/cplieger/docker-static-web/badges/size.json)](https://github.com/cplieger/docker-static-web/pkgs/container/docker-static-web)
![Platforms](https://img.shields.io/badge/platforms-amd64%20%7C%20arm64-blue)
![base: scratch](https://img.shields.io/badge/base-scratch-2496ED?logo=docker)
[![OpenSSF Best Practices](https://www.bestpractices.dev/projects/13211/badge)](https://www.bestpractices.dev/projects/13211)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/cplieger/docker-static-web/badge)](https://scorecard.dev/viewer/?uri=github.com/cplieger/docker-static-web)
[![SBOM](https://img.shields.io/badge/SBOM-SPDX-1D4ED8)](https://github.com/cplieger/docker-static-web/releases)

A tiny static file server: [darkhttpd](https://github.com/emikulic/darkhttpd) compiled statically with hardening flags, UPX-compressed, on `scratch`.

## What it does

Serves static files over HTTP. That's it. The image is essentially a single tiny binary on a scratch base: no shell, no libc, no package manager, no auth, no TLS, no fancy config. Mount your document root at `/www` and darkhttpd serves it on port `8567`.

This is the smallest viable container for serving static content. Use it for:

- **Internal-only static sites** behind a reverse proxy (which handles TLS, auth, and rate-limiting)
- **Health-check landing pages**
- **`/.well-known/` ACME challenges** when you need a separate webroot
- **CI/test fixtures** where you want to serve files without spinning up nginx

### Why this design

- **Scratch base:** the image is essentially the binary itself. No shell to exec, no package manager to attack
- **UPX-compressed binary:** runtime memory is tiny; the binary unpacks itself in-process
- **Hardening flags:** `-D_FORTIFY_SOURCE=2`, `-fstack-clash-protection`, `-fstack-protector-strong`, RELRO + BIND_NOW + NOEXEC stack at link time
- **Static-PIE linking:** `-static-pie` (with `-fPIE`) so the binary has zero dependencies and runs identically on amd64 and arm64, while keeping ASLR for the main executable
- **Non-root by default:** runs as `USER 65534:65534` (nobody); binds a high port and only reads files, so it never needs root. Override via compose `user:`
- **Sane darkhttpd defaults:** `--maxconn 128 --no-listing --no-server-id`. `--maxconn` bounds the `listen()` backlog, not concurrent connections ([darkhttpd#9](https://github.com/emikulic/darkhttpd/issues/9)); DoS limiting belongs to the reverse proxy in front. No directory indexes, no `Server:` header leaking the version
- **Tarball integrity check:** the Dockerfile pins `DARKHTTPD_SHA256` so a tampered tarball fails the build

## Quick start

Available from both `ghcr.io/cplieger/docker-static-web` and `docker.io/cplieger/docker-static-web`; identical images and tags.

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
      - "./www:/www:ro"
```

> **SELinux hosts (Fedora, RHEL):** with SELinux enforcing, an unlabeled bind mount is invisible to the container process, so every request returns `403 Forbidden` with no other symptom: darkhttpd logs only the 403 access line, and `scratch` has no shell to inspect from inside. Label the mount with `- "./www:/www:ro,z"` in compose, or pre-label the directory with `chcon -Rt container_file_t ./www`. Only use `z` on a directory dedicated to this container; it relabels the host files.

## Configuration reference

### Volumes

| Mount  | Description                                                       |
| ------ | ----------------------------------------------------------------- |
| `/www` | Document root. Mount read-only. darkhttpd serves files from here. |

### Ports

| Port   | Description                                              |
| ------ | -------------------------------------------------------- |
| `8567` | HTTP (TCP). Override the `command:` to change the port.  |

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
      - "./www:/www:ro"
```

See [`darkhttpd --help`](https://unix4lyfe.org/darkhttpd/) for all available flags.

> **Note:** if you enable `--auth`, `--forward`, or `--forward-https`, be aware of [darkhttpd#94](https://github.com/emikulic/darkhttpd/issues/94) (header names are matched by substring anywhere in the request, so crafted header _values_ can spoof them). The default command enables none of these, which keeps the affected code paths inert.

### Running as non-root

The image runs as `USER 65534:65534` (`nobody:nogroup`) by default; darkhttpd binds a high port and only reads files, so it never needs root. To run as a different uid:gid, set `user:` in compose. Use numeric ids (`scratch` has no `/etc/passwd` to resolve names), and pick a uid with read access to the files mounted at `/www`.

### Logging and log rotation

darkhttpd writes one Common Log Format line per request to stdout. Docker's default `json-file` driver does not rotate, so on a busy server the logs can grow until they fill the host disk. Cap the driver in compose, as the shipped [`compose.yaml`](compose.yaml) does with `max-size`/`max-file`, or in the daemon's `log-opts`.

If a reverse proxy in front already records access logs, silence darkhttpd's request log entirely by appending `--no-log` to the command:

```yaml
    command: [".", "--port", "8567", "--maxconn", "128", "--no-listing", "--no-server-id", "--no-log"]
```

## Healthcheck

**No built-in healthcheck, deliberately.** The scratch base has no shell, no `wget`, no `curl`, no `nc`. A static probe binary could be baked in (see [`cplieger/health`](https://github.com/cplieger/health)'s `probe/cmd/probe`), but at ~8 MB it would be many times the ~30 KB server it probes, defeating this image's whole point. Derived images that don't care about size can add one.

For a Docker-visible health status, run a sidecar or derive an image with a probe; for most deployments an off-host probe is simpler and also verifies the network path. Use Uptime Kuma, Prometheus blackbox exporter, or any other external HTTP monitor:

```bash
curl -sf http://your-host:8567/ -o /dev/null && echo OK
```

## What it doesn't do

- **No TLS:** put it behind a reverse proxy that terminates HTTPS
- **No auth:** same; let your reverse proxy handle access control
- **No directory listings:** disabled by default (`--no-listing`)
- **No CGI / dynamic content:** it's a static file server
- **No HTTP/2 or HTTP/3:** HTTP/1.1 only; let your reverse proxy upgrade the public-facing connection

If you need any of these, use Caddy / nginx / a real web server.

## Security

The image is published with [cosign](https://github.com/sigstore/cosign) signatures and SBOM attestations, and the build verifies the darkhttpd tarball SHA-256 before extracting, so a tampered tarball fails the build. Live scan results are on the repository's Security tab.

One accepted lint finding: hadolint `DL3018` (unpinned `apk add`) is ignored inline for the `build-base`/`upx`/`binutils` builder packages, because they never reach the shipped `scratch` image.

## Dependencies

All dependencies are updated automatically via [Renovate](https://github.com/renovatebot/renovate). The base image is pinned by SHA digest and `darkhttpd` by tag + SHA-256; the `build-base`/`upx`/`binutils` build packages are installed unpinned so they track the digest-pinned base.

| Dependency       | Source                                                          |
| ---------------- | --------------------------------------------------------------- |
| alpine (builder) | [Docker Hub](https://hub.docker.com/_/alpine)                   |
| build-base       | [Alpine](https://pkgs.alpinelinux.org/packages?name=build-base) |
| upx              | [Alpine](https://pkgs.alpinelinux.org/packages?name=upx)        |
| binutils         | [Alpine](https://pkgs.alpinelinux.org/packages?name=binutils)   |
| darkhttpd        | [GitHub](https://github.com/emikulic/darkhttpd)                 |

## Credits

This project packages [darkhttpd](https://github.com/emikulic/darkhttpd) by [@emikulic](https://github.com/emikulic) into a `scratch`-based container. All credit for the web server itself goes to the upstream maintainer; darkhttpd has been "small, secure, and fast" since 2003.

## Contributing

Issues and pull requests are welcome. Please open an issue first for larger changes so the approach can be discussed before implementation.

## Disclaimer

This project is built with care and follows security best practices, but it is intended for personal / self-hosted use. No guarantees of fitness for production environments. Use at your own risk.

This project was built with AI-assisted tooling using [Claude](https://claude.com), [GPT](https://openai.com), and [Kiro](https://kiro.dev). The human maintainer defines architecture, supervises implementation, and makes all final decisions.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
