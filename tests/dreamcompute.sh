#!/usr/bin/env bash
# End-to-end test against a real DreamCompute server.
#
# Usage: source ./<project>-openrc.sh
#        tests/dreamcompute.sh [--server algo-test-NAME] [--keep] [--with-dns]
#
# Creates a randomly named algo-test-* server (or reuses --server), checks it
# from outside and through the tunnel, re-runs to check that nothing changes,
# reboots it and checks again, then destroys it unless --keep is given.
# Only servers named algo-test-* are touched. Test deploys leave DNS records alone
# unless --with-dns is given, which also needs ENDPOINT_HOSTNAME. Destroying always
# uses config.cfg's endpoint_hostname, so a record pointing at the test server is
# removed with it; that needs CLOUDFLARE_API_TOKEN when endpoint_hostname is set.
set -uo pipefail
SUITE=dc
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"

NAME=algo-test-$(openssl rand -hex 3)
KEEP=false
WITH_DNS=false
while [ $# -gt 0 ]; do
  case $1 in
    --server) NAME=$2; shift 2 ;;
    --keep) KEEP=true; shift ;;
    --with-dns) WITH_DNS=true; shift ;;
    *) echo "Usage: $0 [--server algo-test-NAME] [--keep] [--with-dns]" >&2; exit 2 ;;
  esac
done
case $NAME in algo-test-*) ;; *) echo "Refusing to test '$NAME': test servers must be named algo-test-*" >&2; exit 2 ;; esac
[ -n "${OS_AUTH_URL:-}" ] || { echo "OpenStack credentials are not set. Run: source ./<project>-openrc.sh" >&2; exit 2; }

DEPLOY_ARGS=(-e provider=openstack -e "server_name=$NAME")
# No override: never leave endpoint_hostname pointing at a destroyed server
DESTROY_ARGS=(-e "server_name=$NAME" -e confirm_destroy=true)
if [ "$WITH_DNS" = true ]; then
  [ -n "${ENDPOINT_HOSTNAME:-}" ] && [ -n "${CLOUDFLARE_API_TOKEN:-}" ] ||
    { echo "--with-dns needs ENDPOINT_HOSTNAME and CLOUDFLARE_API_TOKEN" >&2; exit 2; }
  DEPLOY_ARGS+=(-e "endpoint_hostname=$ENDPOINT_HOSTNAME" -e "cloudflare_api_token={{ lookup('env', 'CLOUDFLARE_API_TOKEN') }}")
fi
SSH_PORT=$(sed -n 's/^ssh_port: *//p' "$REPO/config.cfg")
SSH_KEY="$REPO/configs/algo.pem"
CLOUD=true
CLIENTS=(algo-dc-c1 algo-dc-c2 algo-dc-outside)
TAG="dreamcompute-$NAME"

server_exists() {
  (cd "$REPO" && uv run python -I -c '
import sys, openstack
sys.exit(0 if openstack.connect().compute.find_server(sys.argv[1]) else 1)' "$1") 2>/dev/null
}

# save_console : keeps the server's console log (boot and cloud-init output) for diagnosis
save_console() {
  (cd "$REPO" && uv run python -I -c '
import sys, openstack
c = openstack.connect()
s = c.compute.find_server(sys.argv[1])
print(c.compute.get_server_console_output(s)["output"] if s else "no server")' "$NAME") >"$WORK/$TAG-console.log" 2>/dev/null
  echo "Console log saved to $WORK/$TAG-console.log"
}

cleanup() {
  client_down "${CLIENTS[@]}"
  [ "$FAIL" -gt 0 ] && server_exists "$NAME" && save_console
  if [ "$KEEP" = false ] && server_exists "$NAME"; then
    log "Destroying $NAME"
    (cd "$REPO" && ./algo destroy "${DESTROY_ARGS[@]}") </dev/null >"$WORK/$TAG-destroy.log" 2>&1
    if server_exists "$NAME"; then echo "FAIL destroy: $NAME still exists"; else echo "PASS $NAME destroyed"; fi
    [ -n "${IP:-}" ] && rm -rf "${REPO:?}/configs/$IP"
  fi
  unlock
}
lock perf
trap cleanup EXIT

existed=false
server_exists "$NAME" && existed=true
log "Deploying $NAME (existing server: $existed)"
deploy "$TAG-1.log" "${DEPLOY_ARGS[@]}"
IP=$(sed -n 's/^ *"IP_subject_alt_name": "\([0-9.]*\)".*/\1/p' "$WORK/$TAG-1.log" | head -1)
check "deploy succeeded" grep -qE "^${IP//./\\.} +:.* failed=0 " "$WORK/$TAG-1.log"
[ -n "$IP" ] || { echo "No server address in $WORK/$TAG-1.log"; summary; exit 1; }
echo "server address: $IP"
WG="$REPO/configs/$IP/wireguard"
SSH_TARGET="algo@$IP"
KNOWN_HOSTS="$REPO/configs/$IP/known_hosts"
if [ "$existed" = false ]; then
  check "host key was saved before the first connection" fails grep -q 'No SSH host key is saved' "$WORK/$TAG-1.log"
fi

log "From outside the tunnel"
build_client_image && ensure_network
client_down algo-dc-outside
docker run -d --name algo-dc-outside --network "$NET" "$CLIENT_IMAGE" >/dev/null
tcp_open() { docker exec algo-dc-outside timeout 5 bash -c "exec 3<>/dev/tcp/$IP/$1"; }
check "SSH answers on $SSH_PORT" has_line '^SSH-2\.0-' docker exec algo-dc-outside timeout 5 bash -c "exec 3<>/dev/tcp/$IP/$SSH_PORT; head -1 <&3"
for port in 22 53 80 443; do check "TCP $port is closed" fails tcp_open "$port"; done
check "DNS is not answered from outside" fails docker exec algo-dc-outside dig +time=3 +tries=1 @"$IP" example.com

log "Server and tunnel"
server_checks 3
client_up algo-dc-c1 "$WG/alpha.conf"
client_up algo-dc-c2 "$WG/beta.conf"
tunnel_checks algo-dc-c1 algo-dc-c2 "$WG/alpha.conf" "$IP"

log "Re-run (idempotency)"
daily_cleanup_checks
snapshot_configs "$WG" >"$WORK/$TAG-snapshot"
deploy "$TAG-2.log" "${DEPLOY_ARGS[@]}"
idempotency_checks "$TAG-2.log" "$IP" "$WORK/$TAG-snapshot" "$WG"

log "Reboot (reboot survival)"
boot_before=$(ssh_server cat /proc/sys/kernel/random/boot_id)
ssh_server sudo systemctl reboot >/dev/null 2>&1
sleep 20
check "server accepts SSH after the reboot" wait_for_ssh 600
check "the server really rebooted" fails test "$(ssh_server cat /proc/sys/kernel/random/boot_id)" = "$boot_before"
server_checks 3
tunnel_checks algo-dc-c1 algo-dc-c2 "$WG/alpha.conf" "$IP"

summary
