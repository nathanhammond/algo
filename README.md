# Algo VPN (WireGuard on DreamCompute)

A trimmed fork of [Algo VPN](https://github.com/trailofbits/algo). It creates an Ubuntu 24.04
server on DreamHost DreamCompute (OpenStack) and runs a WireGuard VPN on it, with encrypted DNS
from dnscrypt-proxy. IPsec, SSH tunneling, and the other cloud providers have been removed.

## Requirements

On your computer:

- [uv](https://docs.astral.sh/uv/): `brew install uv`
- WireGuard tools, which create the keys: `brew install wireguard-tools`
- Your DreamCompute openrc file, from the dashboard under Project > API Access

## Configure

Edit `config.cfg`:

```yaml
users:
  - phone
  - laptop

provider: openstack
server_name: vpn

endpoint_hostname: vpn.example.com

dns_records:
  nas.example.com: 192.168.1.10
```

`provider: openstack` skips the provider prompt. The other two settings are optional:

- `endpoint_hostname`: client configs connect to this name instead of the server's IP address.
  Point its DNS A record at the server. Each run reports whether the name resolves to that
  server.
- `dns_records`: VPN clients that look up exactly that name get that address, and subdomains are
  not matched.

## Switch to another server

With `endpoint_hostname` set, deploy the new server with a different `server_name`, give each
device that server's config from `configs/<new-server-ip>/wireguard/`, then change the
hostname's A record to the new server's IP. Each server has its own keys, so a device keeps
using its old server until it has the new server's config.

## Deploy

```bash
source ./<project>-openrc.sh
./algo
```

This creates the security group and server, then configures it. Client configs end up in
`configs/<server-ip>/wireguard/`. Each user gets a `.conf` file and a `.png` QR code for the
WireGuard app.

## Add or remove users

Edit `users` in `config.cfg` and run `./algo` again. The existing server is found by
`server_name` and reused. Existing users keep their keys and addresses, and their client configs
don't change. Removed users lose access.

Keep `configs/`: it holds the keys. The layout matches upstream Algo, so a `configs/` folder from
an upstream deployment (including `algo.pem`) works here too.

## SSH into the server

```bash
ssh -i configs/algo.pem -p 4160 algo@<server-ip>
```

## Destroy

```bash
./algo destroy
```

This deletes the server named `server_name` and its security group after asking for confirmation.
Local configs are kept.

## Deploy to an existing Ubuntu server

```bash
./algo -e "provider=local server=<ip> endpoint=<ip> ssh_user=<user> local_install_confirmed=true"
```

This replaces the server's firewall rules, so only use it on a server dedicated to the VPN.

## What runs on the server

- **WireGuard** on UDP `wireguard_port`
- **dnscrypt-proxy** on a private address on `lo` (`local_service_ip`), reachable only through
  the VPN. It forwards to `dnscrypt_servers` over DNSCrypt/DoH, never logs queries, and answers
  `dns_records`.
- **iptables** (legacy backend) allows only SSH, WireGuard, and ping. It also blocks
  client-to-client traffic, the cloud metadata service, and SMB/NetBIOS.
- **Privacy settings:** short log retention, VPN messages filtered from syslog, shell history
  cleared, and daily cleanup.
- **unattended-upgrades** installs security updates automatically.

## License

GNU Affero General Public License v3.0; see [LICENSE](LICENSE).
