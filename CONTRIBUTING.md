# Contributing to docker-static-web

This image packages upstream [darkhttpd](https://github.com/emikulic/darkhttpd)
into a `scratch`-based container. There is no application source here — the
whole repo is a single multi-stage `Dockerfile` plus CI config — so most
contributions are build/Dockerfile changes. A few things are easy to trip over.

## Layout

- `Dockerfile` — the only build artifact. An Alpine `builder` stage compiles
  darkhttpd statically (hardening flags + UPX), then copies the single binary
  onto `scratch`.
- `compose.yaml` — reference deployment (mounts `./www:/www:ro`, serves on
  `8567`).
- `cliff.toml` — git-cliff changelog/version policy.
- `.github/workflows/` — CI, release, CodeQL, security. **Synced from
  `cplieger/ci` and marked `DO NOT EDIT`** — change the central templates
  there, not these copies.

## Bumping darkhttpd (the main gotcha)

The `Dockerfile` pins both `DARKHTTPD_VERSION` and `DARKHTTPD_SHA256`, and
verifies the tarball with `sha256sum -c` before extracting. **When you change
`DARKHTTPD_VERSION`, you must update `DARKHTTPD_SHA256` in the same change** —
otherwise the build fails the integrity check. Renovate is deliberately
configured to require manual approval on darkhttpd bumps for this reason.

Compute the new hash with:

```bash
curl -sL https://github.com/emikulic/darkhttpd/archive/refs/tags/v<N>.tar.gz \
  | sha256sum
```

## Build and validate locally

CI runs centrally, but everything validates with a plain build — the
`sha256sum -c` check and the C compile both run inside it:

```bash
docker build -t docker-static-web .
```

Lint the Dockerfile with [hadolint](https://github.com/hadolint/hadolint)
(this repo has no Go/TypeScript toolchain, so the generic golangci-lint /
eslint guidance does not apply):

```bash
hadolint Dockerfile
```

Smoke-test the running image with an off-host probe. The `scratch` base has no
shell, `wget`, `curl`, or `nc`, so you cannot exec a check inside the
container — probe it from the host:

```bash
docker run --rm -p 8567:8567 -v "$PWD/www:/www:ro" docker-static-web
curl -sf http://localhost:8567/ -o /dev/null && echo OK
```

## Conventions

- Keep the image minimal: no shell, no extra layers, nothing beyond the binary
  on `scratch`. Behavior is configured via the darkhttpd command line (see the
  `CMD`), not env vars.
- The `CFLAGS` / `LDFLAGS` hardening set (`-D_FORTIFY_SOURCE=2`,
  `-fstack-clash-protection`, `-fstack-protector-strong`, RELRO + BIND_NOW +
  NOEXEC stack) and `--static` linking are intentional. Don't drop them
  casually — they keep the binary dependency-free and identical across
  amd64/arm64.
- Pin new build dependencies by version or digest, matching the existing
  Alpine package and base-image pins.

## Commits and PRs

Commits follow [Conventional Commits](https://www.conventionalcommits.org/);
git-cliff parses them for the release notes and version bump (see `cliff.toml`).
A darkhttpd or base-image bump is `chore(deps):` and triggers a release; `docs:`
and `ci:` do not. Open an issue first for larger changes so the approach can be
discussed.

## Conduct & security

By participating you agree to the org-wide
[Code of Conduct](https://github.com/cplieger/.github/blob/main/CODE_OF_CONDUCT.md).
Report security issues through the
[security policy](https://github.com/cplieger/.github/blob/main/SECURITY.md) —
never in a public issue.
