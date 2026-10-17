#!/usr/bin/env bash
# Start the Orca remote server: `orca-ide serve` in the foreground, as the
# container user, with $HOME (/home) as the only persistent state.
set -euo pipefail

log() { echo "[orca-docker] $*"; }
die() { echo "[orca-docker] ERROR: $*" >&2; exit 1; }

STATE_DIR="${HOME}/.config/orca-docker"
SERVE_LOG="${STATE_DIR}/serve.log"

# Clients dial this address. It must be reachable from the client computers:
# the NAS LAN address, its Tailscale name or IP, or a full ws:// / wss:// URL.
if [ -z "${ORCA_PAIRING_ADDRESS:-}" ]; then
  die "ORCA_PAIRING_ADDRESS is not set.
Set it to an address your desktop can reach, for example the NAS LAN IP
(192.168.1.10), its Tailscale name (nas.tailnet-name.ts.net), or a full URL
(ws://nas.local:6768). Do not use 127.0.0.1 or 0.0.0.0."
fi

[ -w "${HOME}" ] || die "${HOME} is not writable by uid $(id -u). Give HOME_DIR to PUID:PGID (chown -R)."

if [ "$(id -u)" = "0" ]; then
  log "WARNING: running as root. Set PUID and PGID (user: \"\${PUID}:\${PGID}\") to run as your NAS user."
fi

# has_id <id> <file>: true when field 3 of a line in an /etc/group-style file is <id>.
has_id() { awk -F: -v id="$1" '$3 == id { found = 1 } END { exit !found }' "$2"; }

# The container runs as an arbitrary PUID:PGID with no /etc/passwd entry.
# ssh, git and the agent CLIs refuse a uid they cannot resolve. The image
# preloads nss_wrapper (ENV LD_PRELOAD), which reads these two files. They are
# also in effect for `docker exec` shells.
#
# The current uid always gets home ${HOME}: OpenSSH reads ~/.ssh from the
# passwd entry, not from $HOME (the base image has uid 1000 = /home/node).
# The files are rewritten in place: the container user cannot create files
# in /var/lib/orca-docker.
if [ "$(id -u)" = "0" ]; then
  passwd_lines="$(awk -F: -v OFS=: -v h="${HOME}" '$3 == 0 { $6 = h } 1' /etc/passwd)"
else
  passwd_lines="$(awk -F: -v id="$(id -u)" '$3 != id' /etc/passwd)
orca:x:$(id -u):$(id -g):Orca:${HOME}:/bin/bash"
fi
group_lines="$(cat /etc/group)"
for gid in $(id -G); do
  has_id "${gid}" /etc/group || group_lines="${group_lines}
group${gid}:x:${gid}:"
done
printf '%s\n' "${passwd_lines}" > "${NSS_WRAPPER_PASSWD}"
printf '%s\n' "${group_lines}" > "${NSS_WRAPPER_GROUP}"

mkdir -p "${STATE_DIR}" "${HOME}/.local/bin" "${NPM_CONFIG_PREFIX}"

# A stable machine ID. /etc/machine-id links here (see Dockerfile). Orca's
# credential store is bound to it, so it must not change between containers.
if [ ! -s "${STATE_DIR}/machine-id" ]; then
  od -An -N16 -tx1 /dev/urandom | tr -d ' \n' > "${STATE_DIR}/machine-id"
  echo >> "${STATE_DIR}/machine-id"
  log "created machine ID in ${STATE_DIR}/machine-id"
fi

# Git identity. Orca refuses to create a project without one.
if [ -n "${GIT_USER_NAME:-}" ]; then
  git config --global user.name "${GIT_USER_NAME}"
elif ! git config --global user.name >/dev/null 2>&1; then
  git config --global user.name "Orca"
  log "git user.name is not set; using \"Orca\". Set GIT_USER_NAME to change it."
fi
if [ -n "${GIT_USER_EMAIL:-}" ]; then
  git config --global user.email "${GIT_USER_EMAIL}"
elif ! git config --global user.email >/dev/null 2>&1; then
  git config --global user.email "orca@localhost"
  log "git user.email is not set; using orca@localhost. Set GIT_USER_EMAIL to change it."
fi

# gh reads GH_TOKEN itself. This also lets plain `git push` over https use it.
if [ -n "${GH_TOKEN:-}" ]; then
  gh auth setup-git >/dev/null 2>&1 || log "WARNING: gh auth setup-git failed"
fi

# Agent CLIs: install the missing ones from ORCA_AGENTS into $HOME. Later
# starts find them on the mount and skip this. A failure does not stop Orca.
agent_command() {
  case "$1" in
    cursor) echo cursor-agent ;;
    *) echo "$1" ;;
  esac
}
agents="${ORCA_AGENTS:-}"
[ "${agents}" = "all" ] && agents="$(install-agents list | awk '{ print $1 }')"
if [ -n "${agents}" ] && [ "${agents}" != "none" ]; then
  for agent in ${agents}; do
    command -v "$(agent_command "${agent}")" >/dev/null 2>&1 && continue
    log "installing agent CLI: ${agent} (log: ${STATE_DIR}/install-agents.log)"
    if ! install-agents "${agent}" >> "${STATE_DIR}/install-agents.log" 2>&1; then
      log "WARNING: could not install ${agent}. Run 'install-agents ${agent}' in the container to retry."
    fi
  done
fi

# User startup hook: runs on every start, as the container user, in the
# background, before Orca starts. Output goes to a log next to it.
STARTUP_SCRIPT="${HOME}/.config/startup.sh"
if [ -f "${STARTUP_SCRIPT}" ]; then
  log "running ${STARTUP_SCRIPT} (log: ${HOME}/.config/startup.log)"
  (cd "${HOME}" && nohup bash "${STARTUP_SCRIPT}" > "${HOME}/.config/startup.log" 2>&1 &)
fi

# Keep the first lines of this run's output for `orca-pairing`. They hold the
# pairing secret, so only the owner can read the file. head writes each line
# at once (stdbuf -oL); cat then drains the rest, so tee never gets SIGPIPE and
# the file does not grow. The server keeps its PID (exec), so it gets the stop
# signal from tini directly.
( umask 077; : > "${SERVE_LOG}" )
exec > >(tee >({ stdbuf -oL head -n 1000 >> "${SERVE_LOG}"; cat > /dev/null; })) 2>&1

# Extra flags, for example ORCA_SERVE_ARGS="--mobile-pairing".
read -r -a extra_args <<< "${ORCA_SERVE_ARGS:-}"

log "Orca $(dpkg-query -W -f='${Version}' orca-ide) serve: port ${ORCA_PORT}, pairing address ${ORCA_PAIRING_ADDRESS}"
cd "${HOME}"
exec orca-ide serve --port "${ORCA_PORT}" --pairing-address "${ORCA_PAIRING_ADDRESS}" "${extra_args[@]}"
