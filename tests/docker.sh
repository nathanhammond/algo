#!/usr/bin/env bash
# End-to-end test against an Ubuntu server running in Docker (provider: local).
#
# Usage: tests/docker.sh [--ubuntu 26.04|24.04|all] [--keep]
#
# Deploys, connects WireGuard clients and checks the VPN, re-runs to check that
# nothing changes, adds and removes users, then restarts the server to check
# that everything comes back. --keep leaves the containers and configs/172.30.<N>.10
# (N is 26 or 24). --ubuntu all runs both versions at once, each with its output in
# tests/.work/docker-<version>.out, and prints their results.
# Docker Desktop's kernel has no AppArmor, so that is only checked by tests/dreamcompute.sh.
set -uo pipefail
VERSIONS=(26.04 24.04)
USAGE="Usage: $0 [--ubuntu 26.04|24.04|all] [--keep]"

UBUNTU=26.04
KEEP=false
while [ $# -gt 0 ]; do
  case $1 in
    --ubuntu) UBUNTU=$2; shift 2 ;;
    --keep) KEEP=true; shift ;;
    *) echo "$USAGE" >&2; exit 2 ;;
  esac
done

if [ "$UBUNTU" = all ]; then
  work="$(dirname "$0")/.work"
  mkdir -p "$work"
  args=(); [ "$KEEP" = true ] && args+=(--keep)
  pids=()
  for v in "${VERSIONS[@]}"; do
    "$0" --ubuntu "$v" "${args[@]}" >"$work/docker-$v.out" 2>&1 &
    pids+=($!)
  done
  rc=0
  for i in "${!VERSIONS[@]}"; do
    wait "${pids[$i]}" || rc=1
    echo "== Ubuntu ${VERSIONS[$i]} (tests/.work/docker-${VERSIONS[$i]}.out)"
    grep -E '^(FAIL|  failed:|passed=)|in progress' "$work/docker-${VERSIONS[$i]}.out"
  done
  exit $rc
fi
case " ${VERSIONS[*]} " in *" $UBUNTU "*) ;; *) echo "$USAGE" >&2; exit 2 ;; esac

# Each version is its own suite (test-26, test-24), with its own network, addresses,
# SSH port and containers, so both can run at once
N=${UBUNTU%%.*}
SUITE="test-$N"
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"

SERVER=algo-$SUITE-server
SERVER_IP=172.30.$N.10
NET_SUBNET=172.30.$N.0/24
# IPv6 lets the server route clients' IPv6 traffic, so the IPv6 checks run
NET_SUBNET6=fd00:a160:$N::/64
CONFIGS="$REPO/configs/$SERVER_IP"
# Keys shared the way every real server shares configs/default, in a directory of the suite's own
SHARED="$SUITE-shared"
SHARED_PKI="$REPO/configs/$SHARED/wireguard/.pki"
WG="$CONFIGS/wireguard"
SSH_KEY="$WORK/$SUITE-ssh-key"
SSH_TARGET=algo@127.0.0.1
# The server's sshd listens on this port too (the firewall opens ansible_ssh_port)
SSH_PORT=$((4100 + N))
KNOWN_HOSTS="$CONFIGS/known_hosts"
C1=algo-$SUITE-c1 C2=algo-$SUITE-c2 C3=algo-$SUITE-c3
CLIENTS=("$C1" "$C2" "$C3")
DEPLOY_ARGS=(-e provider=local -e server=127.0.0.1 -e "endpoint=$SERVER_IP" -e ssh_user=algo
  -e local_install_confirmed=true -e "ansible_ssh_port=$SSH_PORT" -e "ansible_ssh_private_key_file=$SSH_KEY"
  -e apparmor_enabled=false -e "wireguard_shared_pki=$SHARED")
TAG="docker-$UBUNTU"

cleanup() {
  if [ "$KEEP" = false ]; then
    docker rm -f "$SERVER" "${CLIENTS[@]}" >/dev/null 2>&1
    rm -rf "$CONFIGS" "${REPO:?}/configs/$SHARED"
  fi
  unlock
}
lock perf
trap cleanup EXIT

# Docker points resolv.conf at its own DNS, which needs NAT rules that the VPN's
# firewall replaces; a real server resolves through systemd-resolved instead.
fix_resolv() { docker exec "$SERVER" sh -c 'printf "nameserver 127.0.0.53\noptions edns0 trust-ad\n" > /etc/resolv.conf'; }

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
    --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw --tmpfs /run --tmpfs /run/lock -p "$SSH_PORT:$SSH_PORT" \
    -e "TEST_SSH_PUBLIC_KEY=$(cat "$SSH_KEY.pub")" -e "TEST_SSH_PORT=$SSH_PORT" "algo-test-server:$UBUNTU" >/dev/null
  wait_for_boot && fix_resolv
}

log "Building images (Ubuntu $UBUNTU)"
[ -f "$SSH_KEY" ] || ssh-keygen -q -t ed25519 -N '' -C algo-test -f "$SSH_KEY"
docker build -q --build-arg "UBUNTU_VERSION=$UBUNTU" -t "algo-test-server:$UBUNTU" \
  -f "$TESTS/docker/server.Dockerfile" "$TESTS/docker" >/dev/null || exit 1
build_client_image || exit 1
ensure_network

log "Booting a fresh server"
rm -rf "$CONFIGS" "${REPO:?}/configs/$SHARED"
check "server booted" boot_server

log "First deploy"
deploy "$TAG-1.log" "${DEPLOY_ARGS[@]}"
check "deploy succeeded" grep -qE "^127\.0\.0\.1 +:.* failed=0 " "$WORK/$TAG-1.log"
check "the server's host key was saved on first contact" test -s "$KNOWN_HOSTS"
check "client keys come from the shared directory" grep -qxF "PrivateKey = $(cat "$SHARED_PKI/private/alpha" 2>/dev/null)" "$WG/alpha.conf"
check "the server key is the shared one" test "$(ssh_server sudo wg show wg0 public-key 2>/dev/null)" = "$(cat "$SHARED_PKI/public/_server" 2>/dev/null)"
check "the user list is the shared one" test "$(cat "$SHARED_PKI/index.txt" 2>/dev/null)" = "$(printf 'alpha\nbeta\ngamma')"
check "no keys are kept per server" test ! -e "$WG/.pki"
server_checks 3
client_up "$C1" "$WG/alpha.conf"
client_up "$C2" "$WG/beta.conf"
tunnel_checks "$C1" "$C2" "$WG/alpha.conf"

log "Re-run (idempotency)"
daily_cleanup_checks
snapshot_configs "$WG" "$SHARED_PKI" >"$WORK/$TAG-snapshot"
deploy "$TAG-2.log" "${DEPLOY_ARGS[@]}"
idempotency_checks "$TAG-2.log" 127.0.0.1 "$WORK/$TAG-snapshot" "$WG" "$SHARED_PKI"

log "Remove beta, add delta"
alpha_before=$(shasum <"$WG/alpha.conf")
deploy "$TAG-3.log" "${DEPLOY_ARGS[@]}" -e '{"users": ["alpha", "gamma", "delta"]}'
check "deploy succeeded" grep -qE "^127\.0\.0\.1 +:.* failed=0 " "$WORK/$TAG-3.log"
check "alpha's config is unchanged" test "$(shasum <"$WG/alpha.conf")" = "$alpha_before"
check "delta got the next address (10.49.0.5)" grep -q '^Address = 10\.49\.0\.5' "$WG/delta.conf"
check "beta stays in the user index, so addresses never shift" grep -qx beta "$SHARED_PKI/index.txt"
server_checks 3
check "beta can no longer use the VPN" fails docker exec "$C2" ping -c2 -W3 1.1.1.1
client_up "$C3" "$WG/delta.conf"
check "delta can use the VPN" handshake_done "$C3"

log "Restart the server (reboot survival)"
docker restart "$SERVER" >/dev/null
check "server finished booting after the restart" wait_for_boot
fix_resolv
check "server accepts SSH after the restart" wait_for_ssh 180
server_checks 3
tunnel_checks "$C1" "$C3" "$WG/alpha.conf"

summary
