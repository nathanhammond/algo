#!/usr/bin/env bash
# Shared helpers for tests/docker.sh, tests/dreamcompute.sh and tests/perf.sh.
# Sourced, not run. Callers set: SSH_TARGET (user@host), SSH_PORT, SSH_KEY, KNOWN_HOSTS.

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TESTS="$REPO/tests"
WORK="$TESTS/.work"
NET=algotest
CLIENT_IMAGE=algo-test-client
mkdir -p "$WORK"
# The deploy runs from the repository's own uv environment
unset VIRTUAL_ENV

PASS=0
FAIL=0
FAILED=()

log() { printf '\n== %s\n' "$*"; }

# check NAME COMMAND... : runs COMMAND, records PASS or FAIL
check() {
  local name=$1; shift
  if "$@" >/dev/null 2>&1; then
    echo "PASS $name"; PASS=$((PASS + 1))
  else
    echo "FAIL $name"; FAIL=$((FAIL + 1)); FAILED+=("$name")
  fi
}

summary() {
  echo
  echo "passed=$PASS failed=$FAIL"
  for f in "${FAILED[@]}"; do echo "  failed: $f"; done
  [ "$FAIL" -eq 0 ]
}

# ssh_server COMMAND : runs COMMAND on the server, verifying its saved host key
ssh_server() {
  ssh -i "$SSH_KEY" -p "$SSH_PORT" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10 \
    -o UserKnownHostsFile="$KNOWN_HOSTS" -o StrictHostKeyChecking=yes -o LogLevel=ERROR \
    "$SSH_TARGET" "$@"
}

# deploy LOG ARGS... : runs the playbook, keeping the output in $WORK/LOG
deploy() {
  local log=$1; shift
  (cd "$REPO" && uv run ansible-playbook main.yml -e @"$TESTS/test-vars.yml" "$@") </dev/null >"$WORK/$log" 2>&1
}

# recap_changed LOG HOST : the changed= count for HOST in LOG's play recap
recap_changed() {
  awk -v h="$2" '/PLAY RECAP/ {r = 1} r && $1 == h {for (i = 1; i <= NF; i++) if ($i ~ /^changed=/) {sub("changed=", "", $i); print $i}}' "$WORK/$1"
}

# changed_tasks LOG : names of the tasks that reported changed
changed_tasks() {
  awk '/^(TASK|RUNNING HANDLER) \[/ {t = $0} /^changed:/ {print t}' "$WORK/$1" | sort -u
}

# Files that must never change across re-runs: keys, the user index, client configs
snapshot_configs() {
  (cd "$1" && find . -type f ! -name '*.png' | sort | xargs shasum)
}

build_client_image() {
  docker build -q -t "$CLIENT_IMAGE" -f "$TESTS/docker/client.Dockerfile" "$TESTS/docker" >/dev/null
}

ensure_network() {
  docker network inspect "$NET" >/dev/null 2>&1 || docker network create --subnet 172.30.0.0/24 "$NET" >/dev/null
}

# client_up NAME CONF : starts a WireGuard client container using CONF
client_up() {
  docker rm -f "$1" >/dev/null 2>&1
  docker run -d --name "$1" --network "$NET" --privileged "$CLIENT_IMAGE" >/dev/null
  # DNS = would make wg-quick rewrite the container's resolv.conf; dig queries the resolver directly
  grep -v '^DNS' "$2" | docker exec -i "$1" sh -c 'umask 077; cat > /etc/wireguard/wg0.conf && wg-quick up wg0' >/dev/null 2>&1
}

client_down() { docker rm -f "$@" >/dev/null 2>&1; }

# Address of the server's DNS resolver, from a client config
conf_dns() { sed -n 's/^DNS = *\([^, ]*\).*/\1/p' "$1"; }
conf_has_ipv6() { sed -n 's/^Address = //p' "$1" | grep -q ':'; }

# Predicates for check
has_line() { local re=$1; shift; "$@" 2>/dev/null | grep -qE -- "$re"; }
lacks_line() { ! has_line "$@"; }
fails() { ! "$@"; }

handshake_done() {
  docker exec "$1" ping -c3 -W3 1.1.1.1 >/dev/null 2>&1
  [ "$(docker exec "$1" wg show wg0 latest-handshakes | cut -f2)" -gt 0 ]
}

# tunnel_checks C1 C2 CONF1 [EGRESS_IP] : C1 and C2 are connected clients; CONF1 is C1's config
tunnel_checks() {
  local c1=$1 c2=$2 conf=$3 egress=${4:-} dns c2ip
  dns=$(conf_dns "$conf")
  docker exec "$c2" ping -c2 -W3 1.1.1.1 >/dev/null 2>&1
  check "handshake" handshake_done "$c1"
  check "internet through the tunnel" docker exec "$c1" curl -s -m 10 -o /dev/null https://1.1.1.1/cdn-cgi/trace
  if [ -n "$egress" ]; then
    check "egress address is the server's ($egress)" has_line "^ip=${egress//./\\.}\$" docker exec "$c1" curl -s -m 10 https://1.1.1.1/cdn-cgi/trace
  fi
  if conf_has_ipv6 "$conf"; then
    check "IPv6 through the tunnel" has_line '^ip=' docker exec "$c1" curl -6 -s -m 10 'https://[2606:4700:4700::1111]/cdn-cgi/trace'
  fi
  check "DNS through dnscrypt-proxy ($dns)" has_line '^[0-9.]+$' docker exec "$c1" dig +short +time=5 +tries=2 @"$dns" example.com
  check "custom record nas.example.test" has_line '^192\.0\.2\.10$' docker exec "$c1" dig +short @"$dns" nas.example.test
  # Only this server's dnscrypt-proxy knows nas.example.test, so getting it from
  # "8.8.8.8" shows the query was answered by dnscrypt-proxy (dns_force_dnscrypt)
  check "DNS sent to other resolvers is answered by dnscrypt-proxy" has_line '^192\.0\.2\.10$' docker exec "$c1" dig +short +time=5 @8.8.8.8 nas.example.test
  check "... over TCP too" has_line '^192\.0\.2\.10$' docker exec "$c1" dig +short +tcp +time=5 @8.8.8.8 nas.example.test
  check "DNS over TCP works" has_line '^[0-9.]+$' docker exec "$c1" dig +short +tcp +time=5 @"$dns" example.com
  # 2.5 KB: too large for UDP, so dig retries over TCP (dnscrypt-proxy drops answers over 4 KB)
  check "answers too large for UDP arrive (TXT cloudflare.com)" has_line 'ANSWER: [1-9]' docker exec "$c1" dig +time=5 @"$dns" TXT cloudflare.com
  check "custom record is exact-match only" lacks_line '^192\.0\.2\.10$' docker exec "$c1" dig +short @"$dns" x.nas.example.test
  # sslip.io names resolve to the address they spell out
  check "DNS answers with private addresses are blocked" lacks_line '^10\.1\.2\.3$' docker exec "$c1" dig +short +time=5 @"$dns" 10-1-2-3.sslip.io
  check "DNS answers with CGNAT addresses are blocked" lacks_line '^100\.64\.1\.2$' docker exec "$c1" dig +short +time=5 @"$dns" 100-64-1-2.sslip.io
  check "public names still resolve (sslip.io)" has_line '^1\.2\.3\.4$' docker exec "$c1" dig +short +time=5 @"$dns" 1-2-3-4.sslip.io
  c2ip=$(docker exec "$c2" sh -c "ip -4 -br addr show wg0 | awk '{print \$3}' | cut -d/ -f1")
  check "client-to-client traffic is blocked ($c2ip)" fails docker exec "$c1" ping -c2 -W2 "$c2ip"
  check "metadata service is blocked" fails docker exec "$c1" curl -s -m 5 http://169.254.169.254/
}

SERVER_STATE=""
# state KEY : a value from the last server_checks inspection
state() { awk -v k="$1" '$1 == k {$1 = ""; sub(/^ /, ""); print}' <<<"$SERVER_STATE"; }
state_is() { [ "$(state "$1")" = "$2" ]; }
service_active() { [ "$(awk -v u="$1" '$1 == "active" && $2 == u {print $3}' <<<"$SERVER_STATE")" = active ]; }

# server_checks USERS : USERS is the number of users the server should have
server_checks() {
  local users=$1 u
  SERVER_STATE=$(ssh_server 'sudo bash -s' <<'REMOTE'
for u in wg-quick@wg0 dnscrypt-proxy.socket dnscrypt-proxy netfilter-persistent rsyslog cron; do
  echo "active $u $(systemctl is-active "$u")"
done
echo "failed_units $(systemctl --failed --no-legend | wc -l)"
echo "peers $(wg show wg0 peers | wc -l)"
echo "backend $(iptables -V)"
echo "legacy_rules $(iptables-legacy-save 2>/dev/null | grep -c '^-A')"
echo "input_policy $(iptables -S INPUT | head -1)"
echo "dns_rule $(iptables -S INPUT | grep -c -- '-i wg0 .*--dport 53')"
echo "rp_filter $(sysctl -n net.ipv4.conf.all.rp_filter)"
echo "ip_forward $(sysctl -n net.ipv4.ip_forward)"
echo "reboot $(apt-config dump | sed -n 's/^Unattended-Upgrade::Automatic-Reboot "\(.*\)";/\1/p')"
echo "reboot_time $(apt-config dump | sed -n 's/^Unattended-Upgrade::Automatic-Reboot-Time "\(.*\)";/\1/p')"
echo "query_log_lines $(cat /var/log/dnscrypt-proxy/query.log /var/log/dnscrypt-proxy/nx.log 2>/dev/null | wc -l)"
echo "rsyslog $(rsyslogd -N1 >/dev/null 2>&1 && echo valid || echo invalid)"
echo "bashrc_blocks $(grep -c 'BEGIN ALGO: disable bash history' /root/.bashrc)"
echo "x11 $(sshd -T 2>/dev/null | sed -n 's/^x11forwarding //p')"
echo "apparmor_dnscrypt $(aa-status 2>/dev/null | sed -n '/in enforce mode/,/in complain mode/p' | grep -c dnscrypt-proxy)"
REMOTE
)
  for u in wg-quick@wg0 dnscrypt-proxy.socket dnscrypt-proxy netfilter-persistent rsyslog cron; do
    check "service $u is active" service_active "$u"
  done
  check "no failed systemd units" state_is failed_units 0
  check "WireGuard has $users peers" state_is peers "$users"
  check "iptables uses the nftables backend" has_line nf_tables state backend
  check "no rules in the legacy iptables tables" state_is legacy_rules 0
  check "INPUT drops by default" state_is input_policy "-P INPUT DROP"
  check "DNS (UDP and TCP) is accepted only from wg0" state_is dns_rule 2
  check "strict reverse-path filtering" state_is rp_filter 1
  check "IP forwarding is on" state_is ip_forward 1
  check "automatic reboots are on" state_is reboot true
  check "automatic reboots at 21:00 UTC" state_is reboot_time 21:00
  check "dnscrypt-proxy has logged no queries" state_is query_log_lines 0
  check "rsyslog configuration is valid" state_is rsyslog valid
  check "bash history settings appear once" state_is bashrc_blocks 1
  if [ "${CLOUD:-false}" = true ]; then
    check "X11 forwarding is off" state_is x11 no
    check "AppArmor enforces dnscrypt-proxy" fails state_is apparmor_dnscrypt 0
  fi
}

# wait_for_ssh SECONDS : waits until the server accepts SSH again
wait_for_ssh() {
  local deadline=$((SECONDS + $1))
  while [ $SECONDS -lt $deadline ]; do
    ssh_server true 2>/dev/null && return 0
    sleep 5
  done
  return 1
}

# idempotency_checks LOG HOST CONFIG_DIR SNAPSHOT : after a re-run
idempotency_checks() {
  local changed
  changed=$(recap_changed "$1" "$2")
  check "re-run succeeded" grep -qE "^$2 +:.* failed=0 " "$WORK/$1"
  check "re-run changed nothing on the server (changed=$changed)" test "$changed" = 0
  [ "$changed" = 0 ] || changed_tasks "$1" | sed 's/^/    changed: /'
  check "keys, user index and client configs are unchanged" diff <(snapshot_configs "$3") "$4"
  check "re-run verified the saved host key" fails grep -q 'No SSH host key is saved' "$WORK/$1"
}
