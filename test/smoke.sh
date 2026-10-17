#!/usr/bin/env bash
# End-to-end smoke test of the image:
#   1. the server starts as a non-root PUID with all capabilities dropped;
#   2. it installs the agent CLIs into the home mount;
#   3. a client container pairs with the printed link and reaches the runtime;
#   4. after a restart the paired client still connects and a new link is printed;
#   5. the server stops cleanly within the compose grace period.
#
#   test/smoke.sh <image>
set -euo pipefail

IMAGE="${1:?usage: test/smoke.sh <image>}"
NAME="orca-smoke-$$"
NET="${NAME}-net"
WORK="$(mktemp -d)"
SERVER_HOME="${WORK}/server-home"
CLIENT_HOME="${WORK}/client-home"
PORT=6768
READY_TIMEOUT=300

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*" >&2; docker logs "${NAME}" 2>&1 | tail -60 >&2 || true; exit 1; }

cleanup() {
  docker rm -f "${NAME}" >/dev/null 2>&1 || true
  docker network rm "${NET}" >/dev/null 2>&1 || true
  # Server and client run as the test uid, so a plain rm works.
  rm -rf "${WORK}" || echo "WARN: could not remove ${WORK}" >&2
}
trap cleanup EXIT

mkdir -p "${SERVER_HOME}" "${CLIENT_HOME}"
docker network create "${NET}" >/dev/null

start_server() {
  docker run -d --name "${NAME}" --network "${NET}" \
    --user "$(id -u):$(id -g)" --cap-drop ALL --security-opt no-new-privileges:true \
    -e ORCA_PAIRING_ADDRESS="${NAME}" \
    -e ORCA_AGENTS="${ORCA_AGENTS:-claude codex}" \
    -e ORCA_PROFILE_BACKUP=on \
    -v "${SERVER_HOME}:/home" \
    "${IMAGE}" >/dev/null
}

# wait_ready <since-marker-count>: wait until the log shows one more
# "Orca server ready" than the given count.
wait_ready() {
  local before="$1" deadline=$((SECONDS + READY_TIMEOUT))
  while [ "${SECONDS}" -lt "${deadline}" ]; do
    [ "$(docker inspect -f '{{.State.Running}}' "${NAME}")" = "true" ] || fail "server container exited"
    if [ "$(docker logs "${NAME}" 2>&1 | grep -c '^Orca server ready')" -gt "${before}" ]; then
      return 0
    fi
    sleep 3
  done
  fail "server not ready after ${READY_TIMEOUT}s"
}

pairing_url() { docker exec "${NAME}" orca-pairing | sed -n 's/^Pairing URL: //p' | tail -1; }

# client <args...>: run the Orca CLI in a separate container with its own home.
# The CLI finds its data through $HOME and needs no passwd entry.
client() {
  docker run --rm --network "${NET}" --user "$(id -u):$(id -g)" -v "${CLIENT_HOME}:/home" \
    --entrypoint orca-ide "${IMAGE}" "$@"
}

echo "== start server"
start_server
wait_ready 0
pass "server ready"

uid="$(docker exec "${NAME}" id -u)"
[ "${uid}" = "$(id -u)" ] || fail "server runs as uid ${uid}, expected $(id -u)"
home="$(docker exec "${NAME}" sh -c 'getent passwd "$(id -u)" | cut -d: -f6')"
[ "${home}" = "/home" ] || fail "uid ${uid} does not resolve to home /home in docker exec (got '${home}')"
pass "runs as uid ${uid}, passwd home /home"

docker exec "${NAME}" sh -c 'grep -q "^CapEff:\s*0*$" /proc/1/status' || fail "capabilities not dropped"
pass "no capabilities"

docker exec "${NAME}" healthcheck.sh || fail "healthcheck.sh fails on a ready server"
pass "healthcheck"

docker exec "${NAME}" sh -c 'cmp -s /etc/machine-id /home/.config/orca-docker/machine-id && [ -s /etc/machine-id ]' \
  || fail "machine-id is not persisted in the home mount"
pass "machine-id in home mount"

if [ "${ORCA_AGENTS:-claude codex}" != "none" ]; then
  for agent in ${ORCA_AGENTS:-claude codex}; do
    docker exec "${NAME}" "${agent}" --version >/dev/null 2>&1 || fail "agent CLI '${agent}' not installed"
    pass "agent CLI '${agent}' installed"
  done
fi

for tool in git gh ssh docker node npm python3 rg Xvfb; do
  docker exec "${NAME}" sh -c "command -v ${tool}" >/dev/null || fail "tool '${tool}' missing"
done
pass "toolbox present"

echo "== pair a client"
url1="$(pairing_url)"
[ -n "${url1}" ] || fail "no Pairing URL printed"
case "${url1}" in orca://pair\?code=*) ;; *) fail "unexpected Pairing URL: ${url1}" ;; esac
client environment add --name smoke --pairing-code "${url1}" --json > "${WORK}/add.json" \
  || { cat "${WORK}/add.json" >&2; fail "environment add"; }
grep -q "\"endpoint\": \"ws://${NAME}:${PORT}\"" "${WORK}/add.json" || fail "endpoint not advertised as ws://${NAME}:${PORT}"
client status --environment smoke --json > "${WORK}/status1.json" || { cat "${WORK}/status1.json" >&2; fail "status"; }
grep -q '"connectionState": "connected"' "${WORK}/status1.json" || { cat "${WORK}/status1.json" >&2; fail "client not connected"; }
grep -q '"state": "ready"' "${WORK}/status1.json" || fail "runtime not ready"
pass "client paired and connected"

echo "== orca-profile-backup"
# CI has no eCryptfs, so Orca's own backup job works here too. Force the
# script with age 0 and check each path by its log line.
backup_now() { docker exec -e ORCA_PROFILE_BACKUP_MAX_AGE_MS=0 "${NAME}" orca-profile-backup; }
db_revision() {
  docker exec "${NAME}" sh -c 'sqlite3 -batch -init /dev/null /home/.config/orca/profiles/*/profile-state.db \
    "SELECT value FROM profile_state_meta WHERE key = '"'revision'"';"'
}
out="$(backup_now)"; echo "${out}"
echo "${out}" | grep -Eq '(wrote|renamed) profile-state\.db\.backup\.' || fail "first forced pass made no backup"
# A profile change: register a project through the paired client.
docker exec "${NAME}" sh -c 'git init -q -b main /home/smoke-repo && git -C /home/smoke-repo commit -q --allow-empty -m init'
rev_before="$(db_revision)"
client repo add --environment smoke --path /home/smoke-repo --json > "${WORK}/repo.json" || { cat "${WORK}/repo.json" >&2; fail "repo add"; }
# Orca saves profile state after a short delay, maybe more than once. Wait
# until the revision has changed and then stays the same for 5 s.
deadline=$((SECONDS + 90))
rev="${rev_before}"
while :; do
  [ "${SECONDS}" -lt "${deadline}" ] || fail "profile revision did not settle after repo add"
  sleep 5
  now_rev="$(db_revision)"
  [ "${now_rev}" != "${rev_before}" ] && [ "${now_rev}" = "${rev}" ] && break
  rev="${now_rev}"
done
out="$(backup_now)"; echo "${out}"
echo "${out}" | grep -Eq "wrote profile-state\.db\.backup\.[0-9]+-[0-9a-f-]{36}\.db \(revision ${rev}\)" \
  || fail "no backup copy of revision ${rev} after a profile change"
docker exec "${NAME}" sh -c 'for f in /home/.config/orca/profiles/*/profile-state.db.backup.*.db; do
    [ "$(sqlite3 -batch -init /dev/null "$f" "PRAGMA quick_check;")" = ok ] || exit 1; done' || fail "a backup is not a valid database"
if [ "$(db_revision)" = "${rev}" ]; then
  out="$(backup_now)"; echo "${out}"
  echo "${out}" | grep -q "renamed .*(revision ${rev} unchanged)" || fail "unchanged database was copied, not renamed"
fi
# Pruning: add 6 copies with old timestamps (year 2001), force a pass, and
# expect the newest 5 to remain: all real backups (a pass may rename one, so
# count them), and not the oldest copy.
list_backups() { docker exec "${NAME}" sh -c 'ls /home/.config/orca/profiles/*/' | grep '^profile-state\.db\.backup\.' || true; }
count_real() { list_backups | grep -c '^profile-state\.db\.backup\.1[7-9][0-9]\{11\}-' || true; }
real_before="$(count_real)"
docker exec "${NAME}" sh -c 'cd /home/.config/orca/profiles/* && src=$(ls profile-state.db.backup.*.db | head -n 1) &&
  for i in 1 2 3 4 5 6; do cp "$src" "profile-state.db.backup.100000000000$i-$(cat /proc/sys/kernel/random/uuid).db"; done'
backup_now > /dev/null
total="$(list_backups | grep -c . || true)"
[ "${total}" = "5" ] || fail "expected 5 backups after pruning, found ${total}"
# At least as many: a pass copies instead of renaming if Orca saved state meanwhile.
[ "$(count_real)" -ge "${real_before}" ] || fail "pruning removed a real backup (${real_before} before, $(count_real) after)"
list_backups | grep -q '^profile-state\.db\.backup\.1000000000001-' && fail "pruning kept the oldest backup"
# The entrypoint runs the loop (ORCA_PROFILE_BACKUP=on).
docker exec "${NAME}" pgrep -f 'orca-profile-backup --loop' > /dev/null || fail "orca-profile-backup loop is not running"
docker logs "${NAME}" 2>&1 | grep 'writing Orca profile backups' > /dev/null || fail "entrypoint did not start orca-profile-backup"
pass "orca-profile-backup: copy on change, rename when unchanged, valid databases, keeps 5, loop running"

echo "== restart"
ready_count="$(docker logs "${NAME}" 2>&1 | grep -c '^Orca server ready')"
start=$SECONDS
docker stop -t 60 "${NAME}" >/dev/null
stop_secs=$((SECONDS - start))
exit_code="$(docker inspect -f '{{.State.ExitCode}}' "${NAME}")"
echo "stop took ${stop_secs}s, exit code ${exit_code}"
[ "${stop_secs}" -lt 60 ] || fail "server did not stop within 60s"
case "${exit_code}" in
  0|143) ;;
  *) fail "server exit code ${exit_code} on SIGTERM" ;;
esac
pass "clean stop in ${stop_secs}s"

docker start "${NAME}" >/dev/null
wait_ready "${ready_count}"
url2="$(pairing_url)"
if [ -z "${url2}" ] || [ "${url2}" = "${url1}" ]; then
  fail "no new pairing link after the first one was used"
fi
pass "new pairing link after restart"
client status --environment smoke --json > "${WORK}/status2.json" || { cat "${WORK}/status2.json" >&2; fail "status after restart"; }
grep -q '"connectionState": "connected"' "${WORK}/status2.json" || { cat "${WORK}/status2.json" >&2; fail "paired client lost access after restart"; }
pass "paired client reconnects after restart"

echo "ALL PASS"
