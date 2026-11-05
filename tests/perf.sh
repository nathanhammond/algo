#!/usr/bin/env bash
# Measures what limits VPN performance on a deployed server, and whether a change would help.
#
# Usage: tests/perf.sh <server-ip> <client-config> [--name SERVER_NAME] [--runs N]
#
# <client-config> is a WireGuard client config for that server. Use one no device
# is connected with at the same time (a test user): two clients sharing a key keep
# taking the session from each other. A WireGuard client runs in Docker on this
# computer, so the results describe the path from here.
#
# Each section prints its measurements and a verdict: OK, NOTE (worth knowing) or
# CHANGE (a setting or server change is likely to help). Results are appended to
# tests/results/perf.jsonl, so servers and runs can be compared; with
# --name and OpenStack credentials loaded, they include the OpenStack host ID, which
# changes when a server lands on different hardware.
#
# Environment: SSH_HOST (default: the server IP), SSH_PORT (default: config.cfg),
# SSH_KEY (default: configs/algo.pem).
set -uo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"

[ $# -ge 2 ] || { sed -n '3,4p' "$0" | sed 's/^# //' >&2; exit 2; }
IP=$1; CONF=$2; shift 2
NAME=""; RUNS=3
while [ $# -gt 0 ]; do
  case $1 in
    --name) NAME=$2; shift 2 ;;
    --runs) RUNS=$2; shift 2 ;;
    *) echo "Unknown option $1" >&2; exit 2 ;;
  esac
done
[ -f "$CONF" ] || { echo "No client config at $CONF" >&2; exit 2; }
SSH_TARGET="algo@${SSH_HOST:-$IP}"
SSH_PORT=${SSH_PORT:-$(sed -n 's/^ssh_port: *//p' "$REPO/config.cfg")}
SSH_KEY=${SSH_KEY:-$REPO/configs/algo.pem}
KNOWN_HOSTS="$REPO/configs/$IP/known_hosts"
RESULTS="$TESTS/results"
mkdir -p "$RESULTS"
IN=algo-perf-tunnel
OUT=algo-perf-direct
DL_BYTES=25000000
DL_URL="https://speed.cloudflare.com/__down?bytes=$DL_BYTES"
UP_URL="https://speed.cloudflare.com/__up"
trap 'client_down $IN $OUT' EXIT

calc() { awk "BEGIN {printf \"%.${2:-1}f\", $1}"; }
# stats VALUES... : prints "mean cv%" (coefficient of variation)
stats() { printf '%s\n' "$@" | awk '{s += $1; q += $1 * $1; n++} END {m = s / n; v = q / n - m * m; if (v < 0) v = 0; printf "%.1f %.1f", m, (m > 0 ? 100 * sqrt(v) / m : 0)}'; }
mbps() { calc "$1 * 8 / 1000000" 1; }
verdict() { printf '  %-7s %s\n' "$1" "$2"; }
section() { printf '\n== %s\n' "$1"; }
kv() { printf '  %-34s %s\n' "$1" "$2"; }
# ping_avg CONTAINER HOST : average round trip in ms
ping_avg() { docker exec "$1" ping -c 20 -i 0.2 -W 2 "$2" 2>/dev/null | awk -F/ '/^rtt|^round-trip/ {print $5}'; }
ping_mdev() { docker exec "$1" ping -c 20 -i 0.2 -W 2 "$2" 2>/dev/null | awk -F/ '/^rtt|^round-trip/ {sub(/ ms/, "", $7); print $7}'; }
# download CONTAINER : bytes per second
download() { docker exec "$1" curl -s -m 60 -o /dev/null -w '%{speed_download}' "$DL_URL"; }
upload() { docker exec "$1" sh -c "head -c 10000000 /dev/zero | curl -s -m 60 -o /dev/null -w '%{speed_upload}' --data-binary @- '$UP_URL'"; }
# max_payload CONTAINER HOST : the largest ping payload that passes unfragmented
max_payload() {
  local s
  for s in 1472 1452 1432 1412 1392 1372 1352 1312 1272 1232 1200; do
    docker exec "$1" ping -c 1 -W 2 -M "do" -s "$s" "$2" >/dev/null 2>&1 && { echo "$s"; return; }
  done
  echo 0
}
# dig_ms CONTAINER RESOLVER NAME [ARGS] : query time in ms
dig_ms() { docker exec "$1" dig +time=5 +tries=1 "@$2" "$3" "${@:4}" | awk '/Query time:/ {print $4}'; }
# cpu_sample : the server's aggregate /proc/stat cpu line
cpu_sample() { ssh_server head -1 /proc/stat; }
# cpu_delta BEFORE AFTER : "busy% softirq% steal%" between two samples
cpu_delta() {
  awk -v a="$1" -v b="$2" 'BEGIN {
    split(a, x); split(b, y); t = 0
    for (i = 2; i <= 9; i++) t += y[i] - x[i]
    if (t <= 0) {print "0 0 0"; exit}
    idle = (y[5] - x[5]) + (y[6] - x[6])
    printf "%.1f %.1f %.1f", 100 * (t - idle) / t, 100 * (y[8] - x[8]) / t, 100 * (y[9] - x[9]) / t
  }'
}

printf 'Performance of %s%s, measured from this computer, %s\n' "$IP" "${NAME:+ ($NAME)}" "$(date -u '+%Y-%m-%d %H:%M UTC')"
build_client_image && ensure_network || exit 1
client_down $IN $OUT
docker run -d --name $OUT --network "$NET" "$CLIENT_IMAGE" >/dev/null
client_up $IN "$CONF"
handshake_done $IN || { echo "The tunnel did not come up with $CONF" >&2; exit 1; }
VPN_DNS=$(conf_dns "$CONF")
WG_SERVER=$(awk -F'[ =/,]+' '/^Address/ {print $2}' "$CONF" | awk -F. '{print $1"."$2"."$3".1"}')

# --- The server --------------------------------------------------------------
section "Server hardware (differing hardware, noisy neighbours)"
HW=$(ssh_server 'sudo bash -s' <<'REMOTE'
echo "cpu_model $(lscpu | sed -n 's/^Model name: *//p' | head -1)"
echo "vcpus $(nproc)"
echo "mhz $(awk -F: '/^cpu MHz/ {printf "%.0f", $2; exit}' /proc/cpuinfo)"
echo "simd $(grep -o -w -E 'avx512f|avx2|aes' /proc/cpuinfo | sort -u | tr '\n' ' ')"
echo "virt $(systemd-detect-virt) $(cat /sys/class/dmi/id/sys_vendor /sys/class/dmi/id/product_name 2>/dev/null | tr '\n' ' ')"
echo "clocksource $(cat /sys/devices/system/clocksource/clocksource0/current_clocksource)"
echo "mem_mb $(awk '/MemTotal/ {printf "%.0f", $2 / 1024}' /proc/meminfo)"
echo "kernel $(uname -r)"
a=$(head -1 /proc/stat); sleep 10; b=$(head -1 /proc/stat)
echo "idle_sample $a|$b"
for i in 1 2 3 4 5; do
  openssl speed -mr -seconds 1 -bytes 1420 -evp chacha20-poly1305 2>/dev/null | awk -F: '/^\+F:/ {printf "%.0f\n", $4}'
done | tr '\n' ' ' | sed 's/^/bench /'; echo
REMOTE
)
hw() { awk -v k="$1" '$1 == k {$1 = ""; sub(/^ /, ""); print}' <<<"$HW"; }
idle=$(hw idle_sample)
read -r idle_busy _ idle_steal <<<"$(cpu_delta "${idle%%|*}" "${idle##*|}")"
# shellcheck disable=SC2046
read -r bench_mean bench_cv <<<"$(stats $(hw bench))"
bench_mbs=$(calc "$bench_mean / 1000000" 0)
HOST_ID=""; FLAVOR=""
if [ -n "$NAME" ] && [ -n "${OS_AUTH_URL:-}" ]; then
  # host_id identifies the hypervisor (hashed per project); it changes with the hardware
  read -r HOST_ID FLAVOR <<<"$(cd "$REPO" && uv run python -I -c '
import sys, openstack
c = openstack.connect()
s = c.compute.find_server(sys.argv[1])
s = s and c.compute.get_server(s.id)
print(s.host_id, s.flavor.get("original_name") or s.flavor.get("id")) if s else print()' "$NAME" 2>/dev/null)"
fi
kv "CPU" "$(hw cpu_model), $(hw vcpus) vCPU, $(hw mhz) MHz"
kv "SIMD for ChaCha20 (WireGuard)" "$(hw simd)"
kv "Virtualisation" "$(hw virt)"
kv "Flavor" "${FLAVOR:-unknown (pass --name with OpenStack credentials loaded)}"
kv "Memory, kernel, clock source" "$(hw mem_mb) MB, $(hw kernel), $(hw clocksource)"
kv "OpenStack host ID" "${HOST_ID:-unknown (pass --name with OpenStack credentials loaded)}"
kv "CPU busy / steal while idle (10 s)" "$idle_busy% / $idle_steal%"
kv "ChaCha20-Poly1305, 1420-byte packets" "$bench_mbs MB/s ($(mbps "$bench_mean") Mbit/s), variation $bench_cv% over 5 runs"
if awk "BEGIN {exit !($idle_steal > 2)}"; then
  verdict CHANGE "CPU steal is $idle_steal% at idle: the hypervisor is busy with other tenants. Recreate the server (a new one may land elsewhere) and compare host IDs."
elif awk "BEGIN {exit !($bench_cv > 10)}"; then
  verdict NOTE "CPU speed varied $bench_cv% between runs, a sign of contention. Re-run later; persistent variation means noisy neighbours."
else
  verdict OK "No sign of contention."
fi

# --- Paths -------------------------------------------------------------------
section "This computer's own connection"
trace() { docker exec "$1" curl -s -m 10 https://1.1.1.1/cdn-cgi/trace | awk -F= '$1 == "ip" || $1 == "colo" {printf "%s ", $2}'; }
kv "Direct: address, Cloudflare site" "$(trace $OUT)"
kv "Through the tunnel" "$(trace $IN)"
direct_cf=$(ping_avg $OUT 1.1.1.1)
if awk "BEGIN {exit !(${direct_cf:-0} > 60)}"; then
  verdict NOTE "1.1.1.1 is ${direct_cf} ms away directly; it normally answers from nearby. This computer's traffic probably already goes through another VPN or proxy, so the direct and tunnel figures below include it. Disconnect it for a true measurement."
else
  verdict OK "Direct traffic reaches Cloudflare nearby (${direct_cf} ms)."
fi

section "Latency"
rtt_server=$(ping_avg $OUT "$IP"); jitter=$(ping_mdev $OUT "$IP")
rtt_tunnel=$(ping_avg $IN "$WG_SERVER")
rtt_inet_direct=$(ping_avg $OUT 1.1.1.1); rtt_inet_tunnel=$(ping_avg $IN 1.1.1.1)
rtt_server_inet=$(ssh_server ping -c 10 -i 0.2 -W 2 1.1.1.1 2>/dev/null | awk -F/ '/^rtt/ {print $5}')
kv "To the server (outside the tunnel)" "${rtt_server:-?} ms (jitter ${jitter:-?} ms)"
kv "To the server through the tunnel" "${rtt_tunnel:-?} ms"
kv "To 1.1.1.1: direct / tunnel / server" "${rtt_inet_direct:-?} / ${rtt_inet_tunnel:-?} / ${rtt_server_inet:-?} ms"
overhead=$(calc "${rtt_tunnel:-0} - ${rtt_server:-0}" 1)
if awk "BEGIN {exit !($overhead > 10)}"; then
  verdict CHANGE "The tunnel adds $overhead ms over the plain path: look at server CPU (below) and packet drops."
else
  verdict OK "The tunnel adds $overhead ms to the path itself."
fi
if awk "BEGIN {exit !(${rtt_server:-0} > 100)}"; then
  verdict NOTE "The server is ${rtt_server} ms away. Every new connection and uncached DNS lookup pays this; only a closer region would reduce it."
fi

section "Throughput (download $((DL_BYTES / 1000000)) MB x $RUNS, upload 10 MB x $RUNS)"
d=(); for _ in $(seq "$RUNS"); do d+=("$(download $OUT)"); done
s=(); for _ in $(seq "$RUNS"); do s+=("$(ssh_server curl -s -m 60 -o /dev/null -w '%{speed_download}' "$DL_URL")"); done
before=$(cpu_sample)
t=(); for _ in $(seq "$RUNS"); do t+=("$(download $IN)"); done
after=$(cpu_sample)
u=(); for _ in $(seq "$RUNS"); do u+=("$(upload $IN)"); done
read -r direct_mean direct_cv <<<"$(stats "${d[@]}")"
read -r server_mean _ <<<"$(stats "${s[@]}")"
read -r tunnel_mean tunnel_cv <<<"$(stats "${t[@]}")"
read -r up_mean _ <<<"$(stats "${u[@]}")"
read -r load_busy load_softirq load_steal <<<"$(cpu_delta "$before" "$after")"
kv "This computer, direct" "$(mbps "$direct_mean") Mbit/s (variation $direct_cv%)"
kv "The server, direct" "$(mbps "$server_mean") Mbit/s"
kv "Through the tunnel, download" "$(mbps "$tunnel_mean") Mbit/s (variation $tunnel_cv%)"
kv "Through the tunnel, upload" "$(mbps "$up_mean") Mbit/s"
kv "Server CPU during tunnel download" "busy $load_busy%, softirq $load_softirq%, steal $load_steal% (of $(hw vcpus) vCPU)"
limit=$(awk "BEGIN {print ($direct_mean < $server_mean ? $direct_mean : $server_mean)}")
ratio=$(calc "100 * $tunnel_mean / ($limit > 0 ? $limit : 1)" 0)
kv "Tunnel vs the slower direct path" "$ratio%"
if awk "BEGIN {exit !($load_busy > 85)}"; then
  verdict CHANGE "The server's CPU is the limit ($load_busy% busy). A flavor with more or faster vCPUs would help; so might UDP GRO forwarding (below)."
elif awk "BEGIN {exit !($load_steal > 5)}"; then
  verdict CHANGE "CPU steal reached $load_steal% under load: other tenants are slowing the server. Recreate it and compare host IDs."
elif [ "$ratio" -lt 70 ]; then
  verdict NOTE "The tunnel reaches $ratio% of the slower direct path without a busy CPU: the client-to-server path is the limit (distance, packet loss or MTU; see below)."
else
  verdict OK "The tunnel runs near the speed of the slower direct path; the network, not the VPN, is the limit."
fi
if awk "BEGIN {exit !($bench_mean * 8 < 2 * $tunnel_mean * 8)}"; then
  verdict NOTE "Encryption capacity ($(mbps "$bench_mean") Mbit/s in user space) is under twice the measured throughput."
fi

section "MTU"
outer=$(max_payload $OUT "$IP"); inner=$(max_payload $IN 1.1.1.1)
NET_INFO=$(ssh_server 'sudo bash -s' <<'REMOTE'
dev=$(ip -4 route show default | awk '{print $5; exit}')
echo "dev $dev"
echo "dev_mtu $(cat /sys/class/net/$dev/mtu)"
echo "wg_mtu $(cat /sys/class/net/wg0/mtu)"
echo "qdisc $(tc qdisc show dev $dev | head -1 | awk '{print $2}')"
echo "cc $(sysctl -n net.ipv4.tcp_congestion_control)"
echo "conntrack $(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo 0) $(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo 0)"
echo "driver $(basename "$(readlink -f /sys/class/net/$dev/device/driver)") queues $(ls /sys/class/net/$dev/queues | grep -c rx-)"
echo "gro $(ethtool -k $dev 2>/dev/null | sed -n 's/^\(rx-udp-gro-forwarding\|rx-gro-list\|generic-receive-offload\): \([a-z]*\).*/\1=\2/p' | tr '\n' ' ')"
echo "drops $(ip -s -s link show $dev | awk '/RX:/ {getline; print "rx_dropped=" $4} /TX:/ {getline; print "tx_dropped=" $4}' | tr '\n' ' ')"
echo "softnet_dropped $(awk '{s += strtonum("0x" $2)} END {print s}' /proc/net/softnet_stat)"
REMOTE
)
ni() { awk -v k="$1" '$1 == k {$1 = ""; sub(/^ /, ""); print}' <<<"$NET_INFO"; }
client_mtu=$(sed -n 's/^MTU = *//p' "$CONF"); client_mtu=${client_mtu:-1420}
path=$((outer + 28)); wg_mtu=$(ni wg_mtu)
kv "Largest unfragmented ping: path / tunnel" "$outer / $inner bytes (packets of $path / $((inner + 28)))"
kv "Client tunnel MTU" "$client_mtu (tunnel packets of $((client_mtu + 80)))"
kv "Server MTU: $(ni dev) / wg0" "$(ni dev_mtu) / $wg_mtu"
if [ "$outer" -gt 0 ] && [ "$path" -lt $((client_mtu + 80)) ]; then
  verdict CHANGE "The path to the server carries $path-byte packets, but the client's tunnel packets are $((client_mtu + 80)). Set reduce_mtu: $((client_mtu + 80 - path)) in config.cfg so clients use smaller packets."
elif [ "$inner" -eq 0 ]; then
  verdict NOTE "Pings with the don't-fragment flag did not pass through the tunnel; the MTU could not be measured."
else
  verdict OK "Full-size tunnel packets from the client reach the server unfragmented."
fi
if [ "$wg_mtu" -gt "$client_mtu" ]; then
  verdict CHANGE "wg0's MTU ($wg_mtu, from $(ni dev)'s $(ni dev_mtu)) is larger than the clients' ($client_mtu). Packets from the internet that fit wg0 but not the client are sent as oversized tunnel packets that fragment on the way, instead of the sender being told to use smaller ones. Set MTU = $client_mtu in wg0.conf."
fi

section "DNS"
random_name() { echo "algo-perf-$(openssl rand -hex 6).example.com"; }
dig_ms $IN "$VPN_DNS" example.com >/dev/null
cached=$(dig_ms $IN "$VPN_DNS" example.com)
unc=(); dir=()
for _ in 1 2 3 4 5; do
  n=$(random_name); unc+=("$(dig_ms $IN "$VPN_DNS" "$n")")
  n=$(random_name); dir+=("$(dig_ms $OUT 1.1.1.1 "$n")")
done
read -r uncached _ <<<"$(stats "${unc[@]}")"
read -r direct_dns _ <<<"$(stats "${dir[@]}")"
tcp_ok=no; docker exec $IN dig +tcp +time=3 +tries=1 "@$VPN_DNS" example.com >/dev/null 2>&1 && tcp_ok=yes
# A TXT answer larger than one UDP response, so the resolver must retry over TCP
big=$(docker exec $IN dig +time=5 +tries=1 "@$VPN_DNS" TXT microsoft.com 2>&1 | awk '/ANSWER:/ {gsub(",", ""); for (i = 1; i <= NF; i++) if ($i == "ANSWER:") print $(i + 1)}')
kv "Cached lookup through the tunnel" "${cached:-?} ms (the round trip to the server)"
kv "Uncached lookup through the tunnel" "$uncached ms"
kv "Uncached lookup, direct to 1.1.1.1" "$direct_dns ms"
kv "DNS over TCP through the tunnel" "$tcp_ok"
kv "Large answer (TXT microsoft.com)" "${big:-0} records"
if [ "$tcp_ok" = no ]; then
  verdict CHANGE "DNS over TCP is blocked, so answers too large for UDP (some TXT and DNSSEC records) fail after a timeout. Allow TCP port 53 from wg0 in the firewall."
else
  verdict OK "DNS over TCP works, so large answers do too."
fi
if awk "BEGIN {exit !($uncached > ${rtt_tunnel:-0} + 100)}"; then
  verdict NOTE "Uncached lookups take $uncached ms, well over the ${rtt_tunnel} ms round trip: the upstream resolver is slow from the server."
fi

section "Server network settings"
read -r ct_count ct_max <<<"$(ni conntrack)"
kv "Queueing discipline / TCP congestion control" "$(ni qdisc) / $(ni cc)"
kv "Connection tracking" "$ct_count of $ct_max entries"
kv "NIC driver" "$(ni driver)"
kv "GRO settings" "$(ni gro)"
kv "Drops: interface / softnet" "$(ni drops)/ softnet_dropped=$(ni softnet_dropped)"
verdict NOTE "Congestion control (such as BBR) only affects TCP that ends on the server, not forwarded VPN traffic, so it is not worth changing for VPN speed."
if [ "$ct_max" -gt 0 ] && [ $((100 * ct_count / ct_max)) -gt 50 ]; then
  verdict CHANGE "The connection table is over half full; raise net.netfilter.nf_conntrack_max."
else
  verdict OK "The connection table has room."
fi
if grep -q 'rx-udp-gro-forwarding=off' <<<"$(ni gro)" && awk "BEGIN {exit !($load_busy > 85)}"; then
  verdict NOTE "UDP GRO forwarding is off while the CPU is the limit. Turning it on (ethtool -K $(ni dev) rx-udp-gro-forwarding on) is worth an experiment."
fi
if [ "$(ni softnet_dropped)" != 0 ]; then
  verdict NOTE "The kernel has dropped packets because it could not keep up (softnet). Watch whether this grows during load."
fi

# --- Record --------------------------------------------------------------------
printf '{"time":"%s","name":"%s","ip":"%s","host_id":"%s","flavor":"%s","cpu":"%s","vcpus":%s,"bench_bps":%s,"bench_cv":%s,"steal_idle":%s,"steal_load":%s,"busy_load":%s,"rtt_server_ms":%s,"rtt_tunnel_ms":%s,"direct_bps":%s,"server_bps":%s,"tunnel_down_bps":%s,"tunnel_up_bps":%s,"path_mtu":%s,"tunnel_payload":%s,"dns_cached_ms":%s,"dns_uncached_ms":%s,"dns_tcp":"%s"}\n' \
  "$(date -u +%FT%TZ)" "$NAME" "$IP" "$HOST_ID" "$FLAVOR" "$(hw cpu_model)" "$(hw vcpus)" "$bench_mean" "$bench_cv" \
  "$idle_steal" "$load_steal" "$load_busy" "${rtt_server:-0}" "${rtt_tunnel:-0}" "$direct_mean" "$server_mean" "$tunnel_mean" \
  "$up_mean" "$((outer + 28))" "$inner" "${cached:-0}" "$uncached" "$tcp_ok" >>"$RESULTS/perf.jsonl"

section "Earlier runs (tests/results/perf.jsonl)"
(cd "$REPO" && uv run python -I - "$RESULTS/perf.jsonl" <<'PY'
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
print(f"  {'time':20} {'name':18} {'host id':10} {'cpu':28} {'crypto MB/s':>11} {'steal%':>6} {'tunnel Mbit/s':>13}")
for r in rows[-10:]:
    print(f"  {r['time']:20} {r['name'] or r['ip']:18.18} {(r['host_id'] or '-')[:10]:10} {r['cpu']:28.28} "
          f"{r['bench_bps'] / 1e6:11.0f} {r['steal_idle']:6.1f} {r['tunnel_down_bps'] * 8 / 1e6:13.1f}")
cpus = {r["cpu"] for r in rows}
if len(cpus) > 1:
    print(f"  NOTE    These runs used {len(cpus)} different CPU models; compare like with like.")
PY
)
