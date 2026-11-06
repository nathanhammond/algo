#!/usr/bin/env bash
# Measures what limits VPN performance on a deployed server, and whether a change would help.
#
# Usage: tests/perf.sh <server-ip> <client-config> [--name SERVER_NAME] [--runs N] [--site URL] [--idle]
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
# --idle adds about three minutes: it measures the first packet after the tunnel
# has been idle long enough for WireGuard to need a new handshake.
#
# Environment: SSH_HOST (default: the server IP), SSH_PORT (default: config.cfg),
# SSH_KEY (default: configs/algo.pem).
set -uo pipefail
SUITE=perf
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"

[ $# -ge 2 ] || { sed -n '3,4p' "$0" | sed 's/^# //' >&2; exit 2; }
IP=$1; CONF=$2; shift 2
NAME=""; RUNS=3; SITE=https://www.youtube.com/; IDLE=false
while [ $# -gt 0 ]; do
  case $1 in
    --name) NAME=$2; shift 2 ;;
    --site) SITE=$2; shift 2 ;;
    --idle) IDLE=true; shift ;;
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
# The other suites deploy servers and push traffic from this computer, which would skew
# the measurements, so perf.sh runs alone
lock test dc
trap 'unlock; client_down $IN $OUT' EXIT

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
# ping_loss CONTAINER HOST : packet loss over 100 pings, as "N%"
ping_loss() { docker exec "$1" ping -c 100 -i 0.05 -W 2 "$2" 2>/dev/null | awk '/packet loss/ {for (i = 1; i <= NF; i++) if ($i ~ /%$/) print $i}'; }
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
# wall_ms CONTAINER COMMAND... : "exit-status milliseconds" for COMMAND, retries and timeouts included
wall_ms() {
  local c=$1; shift
  docker exec "$c" sh -c 's=$(date +%s%N); "$@" >/tmp/out 2>&1; r=$?; e=$(date +%s%N); echo "$r $(( (e - s) / 1000000 ))"' sh "$@"
}
# server_ping SIZE TARGET : "loss% avg_ms" for 20 pings of SIZE bytes from the server
server_ping() {
  ssh_server ping -c 20 -i 0.2 -W 2 -s "$1" "$2" 2>/dev/null |
    awk '/packet loss/ {for (i = 1; i <= NF; i++) if ($i ~ /%$/) l = $i} /^rtt/ {split($4, r, "/"); a = r[2]} END {printf "%s %s", l, (a == "" ? "-" : a)}'
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
dev=$(ip -4 route show default | awk '{print $5; exit}')
s=/sys/class/net/$dev/statistics
a=$(head -1 /proc/stat); ra=$(cat $s/rx_packets); da=$(cat $s/rx_dropped)
sleep 10
b=$(head -1 /proc/stat); rb=$(cat $s/rx_packets); db=$(cat $s/rx_dropped)
echo "idle_sample $a|$b"
echo "idle_rx_pps $(( (rb - ra) / 10 )) $(( (db - da) / 10 ))"
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
f = s and (s.flavor.get("original_name") or c.compute.get_flavor(s.flavor["id"]).name)
print(s.host_id, f) if s else print()' "$NAME" 2>/dev/null)"
fi
kv "CPU" "$(hw cpu_model), $(hw vcpus) vCPU, $(hw mhz) MHz"
kv "SIMD for ChaCha20 (WireGuard)" "$(hw simd)"
kv "Virtualisation" "$(hw virt)"
kv "Flavor" "${FLAVOR:-unknown (pass --name with OpenStack credentials loaded)}"
kv "Memory, kernel, clock source" "$(hw mem_mb) MB, $(hw kernel), $(hw clocksource)"
kv "OpenStack host ID" "${HOST_ID:-unknown (pass --name with OpenStack credentials loaded)}"
kv "CPU busy / steal while idle (10 s)" "$idle_busy% / $idle_steal%"
read -r idle_pps idle_drops <<<"$(hw idle_rx_pps)"
kv "Packets arriving while idle" "$idle_pps/s ($idle_drops/s dropped as unhandled, such as STP)"
kv "ChaCha20-Poly1305, 1420-byte packets" "$bench_mbs MB/s ($(mbps "$bench_mean") Mbit/s), variation $bench_cv% over 5 runs"
if awk "BEGIN {exit !($idle_steal > 2)}"; then
  verdict CHANGE "CPU steal is $idle_steal% at idle: the hypervisor is busy with other tenants. Recreate the server (a new one may land elsewhere) and compare host IDs."
elif awk "BEGIN {exit !($bench_cv > 10)}"; then
  verdict NOTE "CPU speed varied $bench_cv% between runs, a sign of contention. Re-run later; persistent variation means noisy neighbours."
else
  verdict OK "No sign of CPU contention."
fi
if [ "${idle_pps:-0}" -gt 2000 ]; then
  verdict NOTE "$idle_pps packets/s arrive while the server is idle, mostly other tenants' broadcasts on the shared network. Compare with other servers; a much busier segment costs CPU."
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
loss_server=$(ping_loss $OUT "$IP"); loss_tunnel=$(ping_loss $IN "$WG_SERVER")
kv "Packet loss to the server: direct / tunnel" "$loss_server / $loss_tunnel (100 pings)"
overhead=$(calc "${rtt_tunnel:-0} - ${rtt_server:-0}" 1)
if awk "BEGIN {exit !($overhead > 10)}"; then
  verdict CHANGE "The tunnel adds $overhead ms over the plain path: look at server CPU (below) and packet drops."
else
  verdict OK "The tunnel adds $overhead ms to the path itself."
fi
if awk "BEGIN {exit !(${loss_tunnel%\%} >= 1)}"; then
  verdict NOTE "Loss through the tunnel is $loss_tunnel. At this distance even 1% loss sharply limits TCP throughput; compare with the direct figure to see whether the path or the VPN loses packets."
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
du=(); for _ in $(seq "$RUNS"); do du+=("$(upload $OUT)"); done
read -r direct_mean direct_cv <<<"$(stats "${d[@]}")"
read -r server_mean _ <<<"$(stats "${s[@]}")"
read -r tunnel_mean tunnel_cv <<<"$(stats "${t[@]}")"
read -r up_mean _ <<<"$(stats "${u[@]}")"
read -r dup_mean _ <<<"$(stats "${du[@]}")"
read -r load_busy load_softirq load_steal <<<"$(cpu_delta "$before" "$after")"
kv "This computer, direct" "$(mbps "$direct_mean") Mbit/s down (variation $direct_cv%), $(mbps "$dup_mean") Mbit/s up"
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
up_ratio=$(calc "100 * $up_mean / ($dup_mean > 0 ? $dup_mean : 1)" 0)
if [ "$up_ratio" -lt 70 ]; then
  verdict NOTE "Upload through the tunnel is $up_ratio% of this computer's direct upload."
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
CLIENT_IP=$(awk -F'[ =/,]+' '/^Address/ {print $2}' "$CONF")
read -r big_loss big_avg <<<"$(server_ping 1472 "$CLIENT_IP")"
read -r small_loss small_avg <<<"$(server_ping 1372 "$CLIENT_IP")"
kv "Server to client, 1500-byte packets" "loss $big_loss, ${big_avg} ms"
kv "Server to client, 1400-byte packets" "loss $small_loss, ${small_avg} ms (fit the client either way)"
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
read -r tcp_rc tcp_ms <<<"$(wall_ms $IN dig +tcp +time=3 +tries=1 "@$VPN_DNS" example.com)"
tcp_ok=no; [ "$tcp_rc" = 0 ] && tcp_ok=yes
# TXT answers of 1.9 and 2.5 KB: too large for one UDP response (1232 bytes), so
# the client must retry over TCP. dnscrypt-proxy drops answers over 4096 bytes
# (its fixed MaxDNSPacketSize), so larger ones are checked separately.
big_ok=0; big_t=()
for n in github.com cloudflare.com github.com cloudflare.com; do
  read -r _ ms <<<"$(wall_ms $IN dig +time=5 +tries=1 "@$VPN_DNS" TXT "$n")"
  docker exec $IN grep -q 'ANSWER: [1-9]' /tmp/out && big_ok=$((big_ok + 1))
  big_t+=("$ms")
done
read -r big_ms _ <<<"$(stats "${big_t[@]}")"
huge_ok=no; docker exec $IN dig +time=5 +tries=1 "@$VPN_DNS" TXT microsoft.com 2>/dev/null | grep -q 'ANSWER: [1-9]' && huge_ok=yes
kv "Cached lookup through the tunnel" "${cached:-?} ms (the round trip to the server)"
kv "Uncached lookup through the tunnel" "$uncached ms"
kv "Uncached lookup, direct to 1.1.1.1" "$direct_dns ms"
kv "DNS over TCP through the tunnel" "$tcp_ok (${tcp_ms} ms)"
kv "Answers of 1.9-2.5 KB (TCP retry)" "$big_ok of 4 answered, $big_ms ms on average"
kv "Answer over 4 KB (TXT microsoft.com)" "$huge_ok"
if [ "$huge_ok" = no ]; then
  verdict NOTE "Answers over 4096 bytes fail: dnscrypt-proxy drops them (a fixed limit). They are rare: large TXT record sets such as microsoft.com's."
fi
if [ "$tcp_ok" = no ]; then
  verdict CHANGE "DNS over TCP is blocked, so answers too large for UDP (some TXT and DNSSEC records) fail after a timeout. Allow TCP port 53 from wg0 in the firewall."
else
  verdict OK "DNS over TCP works, so large answers do too."
fi
if awk "BEGIN {exit !($uncached > ${rtt_tunnel:-0} + 100)}"; then
  verdict NOTE "Uncached lookups take $uncached ms, well over the ${rtt_tunnel} ms round trip: the upstream resolver is slow from the server."
fi

section "Page load ($SITE, $RUNS x)"
# page_times CONTAINER RESOLVER : "dns connect tls ttfb total" in ms for one load of $SITE.
# DNS goes to RESOLVER (the VPN's resolver through the tunnel, 1.1.1.1 directly);
# curl then connects to that address, so each phase is measured on its own path.
page_times() {
  docker exec "$1" sh -c '
    host=$(echo "$2" | sed -E "s#^https?://([^/:]+).*#\1#")
    s=$(date +%s%N); ip=$(dig +short +time=5 +tries=1 "@$1" "$host" A | grep -E "^[0-9.]+$" | head -1); e=$(date +%s%N)
    [ -n "$ip" ] || exit 1
    curl -s -o /dev/null -m 30 --resolve "$host:443:$ip" -w "%{time_connect} %{time_appconnect} %{time_starttransfer} %{time_total}" "$2" |
      awk -v d=$(( (e - s) / 1000000 )) "{printf \"%d %.0f %.0f %.0f %.0f\", d, \$1 * 1000, (\$2 - \$1) * 1000, (\$3 - \$2) * 1000, d + \$4 * 1000}"
  ' sh "$2" "$SITE"
}
# page_stats CONTAINER RESOLVER : mean of each phase over $RUNS loads
page_stats() {
  local out=""
  for _ in $(seq "$RUNS"); do out="$out$(page_times "$1" "$2")"$'\n'; done
  awk 'NF == 5 {for (i = 1; i <= 5; i++) s[i] += $i; n++} END {if (n) printf "%.0f %.0f %.0f %.0f %.0f %d", s[1]/n, s[2]/n, s[3]/n, s[4]/n, s[5]/n, n; else print "- - - - - 0"}' <<<"$out"
}
read -r pd_dns pd_tcp pd_tls pd_ttfb pd_total pd_n <<<"$(page_stats $OUT 1.1.1.1)"
read -r pt_dns pt_tcp pt_tls pt_ttfb pt_total pt_n <<<"$(page_stats $IN "$VPN_DNS")"
kv "Phase (ms)" "$(printf '%7s %7s %7s %7s %7s' dns connect tls ttfb total)"
kv "Direct ($pd_n loads)" "$(printf '%7s %7s %7s %7s %7s' "$pd_dns" "$pd_tcp" "$pd_tls" "$pd_ttfb" "$pd_total")"
kv "Through the tunnel ($pt_n loads)" "$(printf '%7s %7s %7s %7s %7s' "$pt_dns" "$pt_tcp" "$pt_tls" "$pt_ttfb" "$pt_total")"
verdict NOTE "This times the page's HTML request, not a browser loading every image and script; each extra connection a page opens costs about another connect + tls."

if [ "$IDLE" = true ]; then
  section "First packet after idle"
  ka=$(sed -n 's/^PersistentKeepalive = *//p' "$CONF"); ka=${ka:-0}
  # WireGuard drops session keys after 180 s without traffic (REJECT_AFTER_TIME)
  sleep 185
  first=$(docker exec $IN ping -c 1 -W 5 "$WG_SERVER" | sed -n 's/.*time=\([0-9.]*\).*/\1/p')
  second=$(docker exec $IN ping -c 1 -W 5 "$WG_SERVER" | sed -n 's/.*time=\([0-9.]*\).*/\1/p')
  kv "PersistentKeepalive" "$ka"
  kv "First / second ping after 185 s idle" "${first:-lost} / ${second:-lost} ms"
  if [ "$ka" = 0 ] && awk "BEGIN {exit !(${first:-0} > ${second:-0} * 1.5)}"; then
    verdict NOTE "After 3 minutes idle, the first packet waited for a new handshake (+$(calc "${first:-0} - ${second:-0}" 0) ms). A non-zero wireguard_PersistentKeepalive (25 by default) avoids this, at the cost of a small packet every 25 s from each device (some battery on phones)."
  else
    verdict OK "No handshake delay after idle."
  fi
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
printf '{"time":"%s","name":"%s","ip":"%s","host_id":"%s","flavor":"%s","cpu":"%s","vcpus":%s,"bench_bps":%s,"bench_cv":%s,"steal_idle":%s,"idle_rx_pps":%s,"steal_load":%s,"busy_load":%s,"rtt_server_ms":%s,"rtt_tunnel_ms":%s,"direct_bps":%s,"server_bps":%s,"tunnel_down_bps":%s,"tunnel_up_bps":%s,"path_mtu":%s,"tunnel_payload":%s,"dns_cached_ms":%s,"dns_uncached_ms":%s,"dns_tcp":"%s","dns_large_ok":%s,"page_direct_ms":"%s","page_tunnel_ms":"%s","dns_large_ms":%s,"big_packet_loss":"%s","big_packet_ms":"%s","wg_mtu":%s}\n' \
  "$(date -u +%FT%TZ)" "$NAME" "$IP" "$HOST_ID" "$FLAVOR" "$(hw cpu_model)" "$(hw vcpus)" "$bench_mean" "$bench_cv" \
  "$idle_steal" "${idle_pps:-0}" "$load_steal" "$load_busy" "${rtt_server:-0}" "${rtt_tunnel:-0}" "$direct_mean" "$server_mean" "$tunnel_mean" \
  "$up_mean" "$((outer + 28))" "$inner" "${cached:-0}" "$uncached" "$tcp_ok" "$big_ok" "$pd_total" "$pt_total" "$big_ms" "$big_loss" "$big_avg" "$wg_mtu" >>"$RESULTS/perf.jsonl"

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
