# orca-docker

Run [Orca](https://www.onorca.dev) as a **Remote Orca Server** in Docker, for example on a
Synology NAS. Your Orca desktop app connects to it. Projects, worktrees, terminals and agent
sessions stay on the server and keep running when your laptop sleeps.

```text
Laptop · Orca desktop app ──── ws://nas:6768 ────▶ NAS · orca-docker
  shows the UI                                     orca-ide serve (Electron + Xvfb)
                                                   repos, worktrees, terminals, agents
                                                        │
                                       SSH targets, other Orca servers, Docker
                                                        ▼
                                              other machines and containers
```

The image contains all that the server needs:

- Orca (official `.deb`, pinned version and SHA-256), its Electron libraries and Xvfb
- Node.js 22, `git`, `gh`, `ssh`, `docker` CLI with compose, `build-essential`, `python3`,
  `ripgrep`, `jq`, `tmux` and other dev tools
- `install-agents`, which installs agent CLIs (`claude`, `codex`, and 13 more) into the
  home folder. The entrypoint installs `ORCA_AGENTS` on first start

Orca is an independent project by [stablyai](https://github.com/stablyai/orca) (MIT). This
repository only packages it.

## Quick start (Synology NAS)

You need DSM 7.2 or newer with Container Manager, and SSH access to the NAS.

1. Make the home folder (over SSH) and give it to your user. Run `id` to find your uid and
   gid; `1026:100` is typical for the first admin user.

   ```sh
   sudo mkdir -p /volume1/docker/orca/home
   sudo chown -R 1026:100 /volume1/docker/orca/home
   ```

   Do **not** put it on an encrypted shared folder. Orca writes file names of about 200
   bytes, and eCryptfs allows about 143 (`ENAMETOOLONG`).

2. Copy this repository to the NAS (for example `/volume1/docker/orca`) and make `.env`:

   ```sh
   cp .env.example .env
   ```

   Set `ORCA_PAIRING_ADDRESS` to an address your laptop can reach: the NAS LAN IP, or its
   Tailscale name or IP. Set `PUID`, `PGID` and `HOME_DIR`.

3. Start it. This pulls `ghcr.io/dluxhu/orca-docker:latest`:

   ```sh
   sudo docker compose up -d
   ```

   The first start installs the agent CLIs and takes a few minutes. Wait for
   `Orca server ready` in `sudo docker logs -f orca-server`.

4. Get the pairing link:

   ```sh
   sudo docker exec orca-server orca-pairing
   ```

5. In the Orca desktop app: **Settings → Remote Orca Servers → Add Server**. Give it a name
   and paste the `Pairing URL`. When it shows **Connected**, select it and use Orca as usual.

Portainer users: use [`portainer/orca-stack.yml`](portainer/orca-stack.yml).

## Connect clients

| Client | How |
|---|---|
| Orca desktop | Paste the `Pairing URL` (`orca://pair?code=…`) in **Settings → Remote Orca Servers → Add Server** |
| Browser | Open the `Web client URL` that `orca-pairing` prints |
| Orca Mobile | Set `ORCA_SERVE_ARGS=--mobile-pairing`, restart, scan the QR code in the log |
| Orca CLI | `orca environment add --name nas --pairing-code '<Pairing URL>'`, then `--environment nas` on any command |

A pairing link pairs **one** client. Each paired client keeps its own revocable grant across
restarts. For the next client, restart the container: it prints a new link.

The link grants full access to the server. Treat it like a password. Keep the port on your
LAN or tailnet. Do not forward it to the internet (Orca's advice too).

## Agents and accounts

The agents run on the server, so they log in on the server:

```sh
sudo docker exec -it orca-server bash
orca account add                 # Claude (managed account for Orca)
orca account add --agent codex
gh auth login                    # or set GH_TOKEN in .env
install-agents list              # more agent CLIs; install-agents gemini opencode …
```

Agent CLIs live in the home folder (`~/.local/bin`, `~/.npm-global/bin`). They survive image
updates and update themselves.

## Delegate work to other machines and containers

**SSH targets.** The server connects to other hosts over SSH and runs worktrees, terminals and
agents there. Put keys and `config` in `<HOME_DIR>/.ssh/` (the container's `~/.ssh`). Then, in
the desktop app connected to this server, **Settings → SSH → Add Target** (or import from
`~/.ssh/config`). On first connect Orca installs a small relay on the target. For remote
terminals the target needs `node`, `make`, a C++ compiler and `python3`. See
[SSH worktrees](https://www.onorca.dev/docs/ssh).

Example: a [claude-nas](https://github.com/dluxhu/claude-syno-nas) terminal container with
`SSHD=1` is a target at `ssh -p 2222 claude@<nas-ip>`. Build it with
`EXTRA_PACKAGES=build-essential` so remote terminals work.

**Other Orca servers.** Run more orca-docker containers (or Orca on other machines) and pair
them with this one: `orca environment add --name gpu-box --pairing-code '…'` inside this
container. Orca's orchestration can then start workers there
(`orca orchestration worker-start`, see [Orchestration](https://www.onorca.dev/docs/cli/orchestration)).

**Docker containers.** For per-workspace containers ([recipes in `orca.yaml`](https://www.onorca.dev/docs/ways-to-run)),
give the server the host's Docker:

```sh
stat -c %g /var/run/docker.sock          # put this number in .env as DOCKER_GID
sudo docker compose -f docker-compose.yml -f docker-compose.docker.yml up -d
```

The Docker socket is root access to the NAS for everything that runs in Orca. Add it only when
you need it.

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `ORCA_PAIRING_ADDRESS` | (required) | Address clients dial: host, IP, or `ws://` / `wss://` URL. Use a URL when the published port differs from `ORCA_PORT` |
| `PUID`, `PGID` | | User and group the container runs as |
| `HOME_DIR` | | Host folder mounted at `/home` (`$HOME`) |
| `ORCA_PORT` | `6768` | Server port, inside and outside the container |
| `ORCA_AGENTS` | `claude codex` | Agent CLIs installed on first start. `none` skips |
| `ORCA_SERVE_ARGS` | | Extra `orca-ide serve` flags, e.g. `--mobile-pairing` |
| `GIT_USER_NAME`, `GIT_USER_EMAIL` | `Orca`, `orca@localhost` if unset | Git identity on the server |
| `GH_TOKEN` | | Token for `gh` and `git push` over https |
| `CLAUDE_CODE_OAUTH_TOKEN` | | Token from `claude setup-token` |
| `TZ` | `UTC` | Time zone |
| `EXTRA_PACKAGES` | | Extra apt packages, only with `docker compose up -d --build` |
| `DOCKER_GID` | | Only with `docker-compose.docker.yml` |

Each start also runs `<HOME_DIR>/.config/startup.sh` if it exists (as your user, in the
background, log in `.config/startup.log`).

## The home folder

The container sees only `HOME_DIR`, mounted at `/home`:

| Path | Contents |
|---|---|
| `.config/orca/` | Orca profile: projects, worktrees, paired clients, settings |
| `.orca/` | Orca credentials and runtime data |
| `.config/orca-docker/` | machine ID, `serve.log` (this run's output, holds the pairing link), agent install log |
| `.local/bin`, `.npm-global/bin` | agent CLIs, the `orca` CLI shim |
| `.ssh/` | keys and config for SSH targets |
| anything else | your repositories, e.g. `~/src` |

## How it works

- `orca-ide serve` runs the Orca runtime without a window. The image sets
  `ORCA_SERVE_RUNTIME=electron`: the Electron runtime serves SSH targets, the lighter orcad
  runtime does not (yet). In the 1.4.227 Linux packages the orcad selector also is not found
  (`Cannot find module …/app.asar.unpacked/out/main/orcad/orcad-local-serve-selection-entry.js`),
  so `serve` uses Electron anyway.
- Orca starts its own Xvfb on `:99` for browser panes, and Chromium with `--no-sandbox`.
- The container runs as `PUID:PGID` with all capabilities dropped and `no-new-privileges`.
  `nss_wrapper` gives that uid a passwd entry (`orca`, home `/home`), also in `docker exec`.
- `/etc/machine-id` links to the home folder, so Orca's credential key stays valid across
  image updates.
- `tini` is PID 1. Orca needs up to about 30 s to stop, so compose waits 60 s.

Orca 1.4.227 `serve` was run on a Synology NAS (DSM, Linux 4.4 kernel) as a non-root user with
all capabilities dropped and nss_wrapper, the same settings as this image. CI tests the image:
`test/smoke.sh` starts it as a non-root user, pairs a CLI client, restarts the server and
checks that the client reconnects.

## Updating

```sh
sudo docker compose pull && sudo docker compose up -d
```

Image tags: `latest`, `orca-<version>` (e.g. `orca-1.4.227`), `sha-<commit>`. To package a new
Orca release, run `bin/bump-orca [version]` and push to `main`; CI tests and publishes it.

## Troubleshooting

- **Desktop shows Disconnected.** Check that `ORCA_PAIRING_ADDRESS` and the port are reachable
  from the laptop (`curl http://<address>:6768/` returns HTML).
- **`ENAMETOOLONG` in the log.** `HOME_DIR` is on an encrypted shared folder. Move it.
- **`Failed to connect to the bus` lines.** Harmless: there is no D-Bus in the container.
- **`secrets are stored unencrypted`.** The Electron runtime has no keyring in a container, so
  integration credentials (Linear, Jira) are stored in plain files in `HOME_DIR`. Protect
  that folder.
- **An agent CLI is missing.** See `.config/orca-docker/install-agents.log`, then run
  `install-agents <name>` in the container.

## Build it yourself

```sh
docker compose up -d --build        # or: docker build -t orca-docker .
test/smoke.sh orca-docker           # end-to-end test against any image
```

CI ([`.github/workflows/build.yml`](.github/workflows/build.yml)) runs the smoke test on every
push. Pushes to `main` and `v*` tags publish `linux/amd64` and `linux/arm64` images to GHCR.
