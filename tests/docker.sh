#!/usr/bin/env bash
# End-to-end test against an Ubuntu server running in Docker (provider: local).
#
# Usage: tests/docker.sh [--ubuntu 26.04|24.04] [--keep]
#
# Deploys, connects WireGuard clients and checks the VPN, re-runs to check that
# nothing changes, adds and removes users, then restarts the server to check
# that everything comes back. --keep leaves the containers and configs/172.30.0.10.
# Docker Desktop's kernel has no AppArmor, so that is only checked by tests/dreamcompute.sh.
set -uo pipefail
SUITE="test"
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"

UBUNTU=26.04
KEEP=false
while [ $# -gt 0 ]; do
  case $1 in
    --ubuntu) UBUNTU=$2; shift 2 ;;
    --keep) KEEP=true; shift ;;
    *) echo "Usage: $0 [--ubuntu 26.04|24.04] [--keep]" >&2; exit 2 ;;
  esac
done

SERVER=algo-test-server
SERVER_IP=172.30.0.10
NET_SUBNET=172.30.0.0/24
# IPv6 lets the server route clients' IPv6 traffic, so the IPv6 checks run
NET_SUBNET6=fd00:a160:1::/64
CONFIGS="$REPO/configs/$SERVER_IP"
WG="$CONFIGS/wireguard"
SSH_KEY="$WORK/ssh-key"
SSH_TARGET=algo@127.0.0.1
SSH_PORT=4160
KNOWN_HOSTS="$CONFIGS/known_hosts"
CLIENTS=(algo-test-c1 algo-test-c2 algo-test-c3)
DEPLOY_ARGS=(-e provider=local -e server=127.0.0.1 -e "endpoint=$SERVER_IP" -e ssh_user=algo
  -e local_install_confirmed=true -e ansible_ssh_port=4160 -e "ansible_ssh_private_key_file=$SSH_KEY"
  -e apparmor_enabled=false)
TAG="docker-$UBUNTU"

cleanup() {
  if [ "$KEEP" = false ]; then
    docker rm -f "$SERVER" "${CLIENTS[@]}" >/dev/null 2>&1
    rm -rf "$CONFIGS"
  fi
  unlock
}
lock perf
trap cleanup EXIT

# The container uses Docker's DNS, which needs NAT rules that the VPN's firewall
# replaces; a real server resolves through systemd-resolved instead.
fix_resolv() { docker exec "$SERVER" sh -c 'echo "nameserver 1.1.1.1" > /etc/resolv.conf'; }

# wait_for_boot : waits until systemd has finished starting the server
wait_for_boot() {
  local state deadline=$((SECONDS + 180))
  while [ $SECONDS -lt $deadline ]; do
    state=$(docker exec "$SERVER" systemctl is-system-running 2>/dev/null)
    case $state in running | degraded) return 0 ;; esac
    sleep 2
  done
  return 1
}

boot_server() {
  docker rm -f "$SERVER" >/dev/null 2>&1
  docker run -d --name "$SERVER" --hostname algo-test --network "$NET" --ip "$SERVER_IP" --privileged \
    --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw --tmpfs /run --tmpfs /run/lock -p 4160:4160 \
    -e "TEST_SSH_PUBLIC_KEY=$(cat "$SSH_KEY.pub")" "algo-test-server:$UBUNTU" >/dev/null
  wait_for_boot && fix_resolv
}

log "Building images (Ubuntu $UBUNTU)"
[ -f "$SSH_KEY" ] || ssh-keygen -q -t ed25519 -N '' -C algo-test -f "$SSH_KEY"
docker build -q --build-arg "UBUNTU_VERSION=$UBUNTU" -t "algo-test-server:$UBUNTU" \
  -f "$TESTS/docker/server.Dockerfile" "$TESTS/docker" >/dev/null || exit 1
build_client_image || exit 1
ensure_network

log "Booting a fresh server"
rm -rf "$CONFIGS"
check "server booted" boot_server

log "First deploy"
deploy "$TAG-1.log" "${DEPLOY_ARGS[@]}"
check "deploy succeeded" grep -qE "^127\.0\.0\.1 +:.* failed=0 " "$WORK/$TAG-1.log"
check "the server's host key was saved on first contact" test -s "$KNOWN_HOSTS"
server_checks 3
client_up algo-test-c1 "$WG/alpha.conf"
client_up algo-test-c2 "$WG/beta.conf"
tunnel_checks algo-test-c1 algo-test-c2 "$WG/alpha.conf"

log "Re-run (idempotency)"
daily_cleanup_checks
snapshot_configs "$WG" >"$WORK/$TAG-snapshot"
deploy "$TAG-2.log" "${DEPLOY_ARGS[@]}"
idempotency_checks "$TAG-2.log" 127.0.0.1 "$WG" "$WORK/$TAG-snapshot"

log "Remove beta, add delta"
alpha_before=$(shasum <"$WG/alpha.conf")
deploy "$TAG-3.log" "${DEPLOY_ARGS[@]}" -e '{"users": ["alpha", "gamma", "delta"]}'
check "deploy succeeded" grep -qE "^127\.0\.0\.1 +:.* failed=0 " "$WORK/$TAG-3.log"
check "alpha's config is unchanged" test "$(shasum <"$WG/alpha.conf")" = "$alpha_before"
check "delta got the next address (10.49.0.5)" grep -q '^Address = 10\.49\.0\.5' "$WG/delta.conf"
check "beta stays in the user index, so addresses never shift" grep -qx beta "$WG/.pki/index.txt"
server_checks 3
check "beta can no longer use the VPN" fails docker exec algo-test-c2 ping -c2 -W3 1.1.1.1
client_up algo-test-c3 "$WG/delta.conf"
check "delta can use the VPN" handshake_done algo-test-c3

log "Restart the server (reboot survival)"
docker restart "$SERVER" >/dev/null
check "server finished booting after the restart" wait_for_boot
fix_resolv
check "server accepts SSH after the restart" wait_for_ssh 180
server_checks 3
tunnel_checks algo-test-c1 algo-test-c3 "$WG/alpha.conf"

summary
