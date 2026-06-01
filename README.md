# docker-static-web

A tiny static file server: [darkhttpd](https://github.com/emikulic/darkhttpd)
compiled statically (with hardening flags + UPX) and shipped on a `scratch`
base — the image is essentially just the `darkhttpd` binary.

## Image

```
ghcr.io/cplieger/docker-static-web
```

Multi-arch, signed (cosign) and SBOM-attested via the shared
[`cplieger/ci`](https://github.com/cplieger/ci) workflows.

## Usage

See [`compose.yaml`](./compose.yaml). Mount your document root at `/www`;
darkhttpd serves it on port `8567`.
