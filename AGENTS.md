# orca-docker — project context

Docker image for the Orca remote server (`orca-ide serve`), aimed at a Synology NAS. The Orca
desktop app pairs with it. See [README.md](README.md) for users.

## Layout

```
Dockerfile                 node:22-bookworm-slim + Orca .deb (pinned version + SHA-256) + toolbox
entrypoint.sh              nss_wrapper files, machine-id, git identity, agent install, startup.sh, exec serve
healthcheck.sh             HTTP GET / on ORCA_PORT
orca-pairing               prints pairing links from ~/.config/orca-docker/serve.log
install-agents             agent CLI installer (copy of claude-syno-nas terminal/install-agents)
docker-compose.yml         default deploy (GHCR image, or --build)
docker-compose.docker.yml  opt-in overlay: host Docker socket
portainer/orca-stack.yml   image-only stack for Portainer
test/smoke.sh              end-to-end test: start, pair a CLI client, restart, reconnect
bin/bump-orca              set ORCA_VERSION and .deb checksums from a GitHub release
.github/workflows/build.yml  smoke test on every push; main and v* tags publish amd64+arm64 to GHCR
```

## Key facts

- `ORCA_SERVE_RUNTIME=electron`. orcad cannot serve SSH targets. In the 1.4.227 Linux
  packages the orcad selector is also missing from `app.asar.unpacked`, so auto mode falls back
  to Electron after a MODULE_NOT_FOUND trace.
- `orca-ide serve` starts Xvfb on `:99` and Chromium with `--no-sandbox` itself. The image
  clears the setuid bit of `chrome-sandbox`.
- Non-root `PUID:PGID`, `cap_drop: ALL`, `no-new-privileges`. `LD_PRELOAD=nss_wrapper` is image
  ENV (after the last RUN). It reads `/var/lib/orca-docker/{passwd,group}`: copies of the
  image files (mode 0666), rewritten by the entrypoint on every start.
- `/etc/machine-id` links to `/home/.config/orca-docker/machine-id` (Orca credential key).
- Unix socket paths under `$HOME/.config/orca` must stay under 108 bytes, so `HOME=/home`.
- eCryptfs (Synology encrypted shares) rejects Orca's long temporary file names.
- A pairing link pairs one client; a restart prints a new link once the old one is used.
  Paired grants persist in `~/.config/orca`.
- Stop takes up to about 30 s; compose uses `stop_grace_period: 60s`.

## Local testing without Docker

The development host has no Docker. `.local-test/` (gitignored) holds throwaway homes for
running the Orca binaries directly. Use CI (`test/smoke.sh`) for the image.

## Conventions

Docs and comments: ASD-STE100 Simplified Technical English. Commits on feature branches, PRs
to `main`.
