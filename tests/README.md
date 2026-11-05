# Tests

End-to-end tests that deploy Algo and use the VPN with real WireGuard clients in Docker.
They use their own users and DNS records ([test-vars.yml](test-vars.yml)), so they never
depend on the personal values in `config.cfg` and never change DNS records.

| Script | What it tests | Needs |
|---|---|---|
| `tests/docker.sh [--ubuntu 26.04\|24.04] [--keep]` | An Ubuntu server in Docker (`provider: local`) | Docker |
| `tests/dreamcompute.sh [--server algo-test-NAME] [--keep] [--with-dns]` | A real DreamCompute server, created and destroyed | Docker, DreamCompute credentials |
| `tests/perf.sh <server-ip> <client-config> [--name NAME]` | What limits VPN performance on a deployed server | Docker |

Each check prints `PASS` or `FAIL`, and the script exits non-zero if any failed. Logs of every
deploy are kept in `tests/.work/`.

## What the end-to-end tests check

- **Deploy:** a fresh server deploys without errors, and its SSH host key is saved before
  (DreamCompute) or on (Docker) the first connection.
- **Server:** WireGuard, dnscrypt-proxy, netfilter-persistent, rsyslog and cron are running with
  no failed units. The firewall uses the nftables backend, drops by default and accepts DNS
  only from `wg0`. Reverse-path filtering is strict, automatic reboots are set for 21:00
  UTC, dnscrypt-proxy logs no queries, and on DreamCompute AppArmor enforces
  dnscrypt-proxy and X11 forwarding is off.
- **Connectability:** two clients complete handshakes and reach the internet (and IPv6 when
  the server has it) through the tunnel, with the server's address as the egress address
  (DreamCompute). DNS goes through dnscrypt-proxy, `dns_records` answer by exact name only,
  answers containing private or CGNAT addresses are blocked, clients cannot reach each other,
  and the metadata service is blocked. On DreamCompute: from outside the tunnel only SSH
  answers, and DNS is not served.
- **Idempotency:** a second deploy reports no changes on the server, verifies the saved host
  key, and leaves every key, the user index and every client config byte-for-byte the same.
- **Users (Docker):** removing a user stops their access; a new user gets the next address;
  other users' configs do not change.
- **Reboot survival:** after a restart (Docker) or a real reboot (DreamCompute), every server
  check passes again and clients reconnect.

## DreamCompute

```bash
source ./<project>-openrc.sh
export CLOUDFLARE_API_TOKEN=<your Cloudflare API token>   # if endpoint_hostname is set
tests/dreamcompute.sh
```

Only servers named `algo-test-*` are created or destroyed. The server is destroyed at the end
unless `--keep` is given. Destroying uses `config.cfg`'s `endpoint_hostname`, so if the test
server holds that record it is removed with it, which needs the Cloudflare token.

## Performance

```bash
tests/perf.sh <server-ip> configs/<server-ip>/wireguard/<user>.conf --name <server-name> [--site URL] [--idle]
```

Use a client config that no device is connected with at the same time. Disconnect any VPN on
this computer first, or the direct and tunnel figures include it (the script warns when it
looks that way). Each section ends with a verdict:

- `OK`: nothing to change.
- `NOTE`: worth knowing.
- `CHANGE`: a setting or server change is likely to help.

The script measures:

- the server's hardware, CPU steal time and encryption speed, to show noisy neighbours or
  different hardware;
- latency and packet loss, and throughput (down and up) split into this computer's direct path,
  the server's direct path and the tunnel, with the server's CPU load;
- how long a page (`--site`, default youtube.com) takes to load directly and through the tunnel,
  by phase;
- with `--idle`, whether the first packet after three idle minutes waits for a new handshake;
- the MTU of the path and the tunnel;
- DNS latency, and whether DNS over TCP works;
- connection tracking, packet drops and NIC settings.

Results are appended to `tests/results/perf.jsonl` with the OpenStack host ID (with `--name`
and credentials loaded), so runs on different servers or days can be compared.
