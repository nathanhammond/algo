# CLAUDE.md - LLM Guidance for Algo VPN (WireGuard on DreamCompute)

A trimmed fork of Algo VPN. It deploys a WireGuard VPN with dnscrypt-proxy to one Ubuntu 26.04
server on DreamHost DreamCompute (OpenStack), or to an existing Ubuntu server (`provider: local`).
IPsec, SSH tunneling, Apple profiles, ad blocking, and all other cloud providers were removed in
the first commit of this fork; requests to bring them back belong upstream.

### Philosophy
- Stability over features
- Security over convenience
- Clarity over cleverness
- Test everything
- Stay in scope - solve exactly what the issue asks, nothing more
- Test assumptions - run the code before committing
- Resist new dependencies - each one is attack surface and maintenance

## Architecture and Structure

```
main.yml            # preflight checks -> input.yml -> cloud.yml -> server.yml
input.yml           # prompts, skipped when variables are set in config.cfg or with -e
cloud.yml           # provisioning on localhost: cloud-pre (SSH key), cloud-openstack or local, cloud-post
server.yml          # configures the vpn-host: common, dns, wireguard, privacy
destroy.yml         # deletes endpoint_hostname's A record if it points here, then the server and security group
config.cfg          # everything users edit
roles/
  cloud-openstack/  # security group, flavor/image/network lookup, server, cloud-init
  local/            # existing server: asks for server, ssh_user, endpoint
  common/           # updates, reboot, sysctl, iptables (nftables backend)
  dns/              # dnscrypt-proxy on local_service_ip via systemd socket activation
  wireguard/        # keys via the wg CLI on the controller, wg0.conf, client .conf + QR
  privacy/          # log retention/filtering, history clearing, cleanup
files/cloud-init/   # user-data template and sshd_config for new servers
configs/<ip>/wireguard/  # client configs; .pki/ holds keys (same layout as upstream Algo)
```

Users are added and removed by re-running `./algo`; there is no separate users playbook.

## Development Workflow

### Quality Gates (MANDATORY)

```bash
uv run ansible-lint && uv run yamllint . && uvx --from shellcheck-py shellcheck algo
uv run ansible-playbook main.yml --syntax-check
uv run ansible-playbook destroy.yml --syntax-check
```

There are no unit tests. Verify behavior by deploying to systemd-enabled Ubuntu 26.04 and 24.04 containers
(`provider=local`) and connecting real WireGuard clients, then re-running the playbook to check
that keys and addresses are unchanged. The OpenStack path can be exercised with test doubles for
the openstack.cloud modules that return openstacksdk resource dicts.

### Zero-Tolerance Warning Policy

**No warnings are tolerated in CI.** Every linter finding must be either fixed or explicitly allowlisted in the tool's config file (`.ansible-lint`, `pyproject.toml`, etc.).

Why this matters for Algo:
- **Security tool** - VPN misconfigurations silently break privacy guarantees. A "cosmetic" warning today hides a real bug tomorrow.
- **Ansible complexity** - YAML+Jinja2 linting catches real runtime failures (wrong key order breaks `when` evaluation, spacing errors cause template failures). Warnings in Ansible are not style nits.
- **CI signal integrity** - If 30 warnings scroll by on every run, the 31st one (a real regression) goes unnoticed. Zero warnings means every new finding gets human attention.

Resolution order of preference:
1. **Fix it** - Preferred. Most findings have straightforward fixes.
2. **Allowlist in config** - If the rule is wrong for this project, add to `skip_list` with a comment explaining why.
3. **Inline suppress** - Last resort. Use `# noqa: rule-name` with a comment justifying the exception.

Never use `warn_list` in `.ansible-lint` — it exists as a migration tool, not a permanent home. Rules either pass or are explicitly skipped.

### Design Requirements

When adding or modifying features, verify these before requesting review:

1. **Validate inputs early** - Check for empty lists, missing configs, permission mismatches before expensive operations
2. **Explicit file modes** - Always specify `mode:` on file/directory tasks (never rely on umask)
3. **Fail vs warn** - Permission/security issues should fail; optional features can warn
4. **Actionable errors** - Include fix commands in error messages: `"Run: sudo chown -R $USER configs/"`
5. **Follow existing patterns** - Search codebase first: `rg "when:.*localhost" --type yaml`

## Ansible Pitfalls

### with_items vs loop

`with_items` auto-flattens lists; `loop` does not. **Never mechanically convert:**

```yaml
# WRONG - treats list as single item, creates file named "['alice', 'bob']"
loop:
  - "{{ users }}"

# CORRECT - iterates over list contents
loop: "{{ users }}"

# CORRECT - combining lists (with_items did this automatically)
loop: "{{ users + [server_name] }}"
```

**Always test loop conversions** - verify the task creates expected files.

### Path Variables

Never include trailing slashes - causes double-slash bugs:

```yaml
# WRONG - creates paths like /etc/ipsec.d//private
ipsec_path: "configs/{{ server }}/ipsec/"

# CORRECT
ipsec_path: "configs/{{ server }}/ipsec"
```

### ignore_errors vs failed_when

```yaml
# WRONG - ansible-lint failure
- name: Clear history
  command: some_command
  ignore_errors: true

# CORRECT - explicit about expected failures
- name: Clear history
  command: some_command
  failed_when: false
```

### changed_when on Read-Only Tasks

Handlers and check commands that don't modify state need `changed_when: false`:

```yaml
- name: Check service status
  command: systemctl status foo
  changed_when: false
```

### Jinja2 Native Mode (Ansible 12+)

Ansible 12 enables `jinja2_native` by default, changing how values are evaluated:

**Boolean conditionals require actual booleans:**
```yaml
# WRONG - string "true" is not boolean
ipv6_support: "{% if ipv6 %}true{% else %}false{% endif %}"

# CORRECT - return actual boolean
ipv6_support: "{{ ipv6 is defined }}"
```

**No nested templates in lookup():**
```yaml
# WRONG - deprecated double-templating
key: "{{ lookup('file', '{{ SSH_keys.public }}') }}"

# CORRECT - pass variable directly
key: "{{ lookup('file', SSH_keys.public) }}"
```

**JSON files need explicit parsing:**
```yaml
# WRONG - returns string in native mode
creds: "{{ lookup('file', 'credentials.json') }}"

# CORRECT - parse JSON explicitly
creds: "{{ lookup('file', 'credentials.json') | from_json }}"
```

**default() doesn't trigger on empty strings:**
```yaml
# WRONG - empty string '' is not undefined
key: "{{ lookup('env', 'AWS_KEY') | default('fallback') }}"

# CORRECT - add true to handle falsy values
key: "{{ lookup('env', 'AWS_KEY') | default('fallback', true) }}"
```

**Complex Jinja loops break in set_fact:**
```yaml
# WRONG - list comprehension fails in native mode
servers: "[{% for s in configs %}{{ s.name }},{% endfor %}]"

# CORRECT - use Ansible loop
servers: "{{ servers | default([]) + [item.name] }}"
loop: "{{ configs }}"
```

**Use tests (not filters) for boolean checks:**
```yaml
# WRONG - filters return transformed data, not booleans
that: my_ip | ansible.utils.ipv4

# CORRECT - tests return native booleans
that: my_ip is ansible.utils.ipv4_address
```

## DNS Architecture

Algo uses a randomly generated IP in 172.16.0.0/12 on the loopback interface (`local_service_ip`) for DNS. This provides consistency across WireGuard and IPsec but requires understanding systemd socket activation.

### Why This Design

- Consistent DNS IP across both VPN protocols
- Survives interface changes and restarts
- Works identically across all cloud providers
- Trade-off: Requires `route_localnet=1` sysctl

### systemd Socket Activation

Ubuntu's dnscrypt-proxy uses socket activation which **completely ignores** the `listen_addresses` config setting. You must configure the socket, not the service:

```ini
# /etc/systemd/system/dnscrypt-proxy.socket.d/10-algo-override.conf
[Socket]
ListenStream=              # Clear defaults first
ListenDatagram=
ListenStream=172.x.x.x:53  # Then set VPN IP
ListenDatagram=172.x.x.x:53
```

Common mistakes:
- Trying to disable/mask the socket (breaks service dependency)
- Only setting ListenStream (need ListenDatagram for UDP)
- Forgetting to restart socket after config changes

### Debugging DNS

Many "routing" issues are actually DNS issues. Start here:

```bash
ss -lnup | grep :53                      # Should show local_service_ip:53
systemctl status dnscrypt-proxy.socket   # Check for config warnings
sysctl net.ipv4.conf.all.route_localnet  # Must be 1
dig @172.x.x.x google.com                # Test resolution
```

For comprehensive diagnostics, see [docs/troubleshooting.md](docs/troubleshooting.md#diagnostic-commands).

## Fork-Specific Gotchas

- **Re-runs must be idempotent.** They are how users are edited. Existing keys in
  `configs/<ip>/wireguard/.pki/{private,public,preshared}/` are never regenerated, and `index.txt`
  is only appended to, so addresses never shift.
- **`creates:` with `chdir:`**: the shell/command modules evaluate `creates` after changing
  directory. A relative path there must be relative to `chdir`, or every run regenerates keys.
- **Facts**: `inject_facts_as_vars = False`; read facts from `ansible_facts['...']`.
- **Ubuntu 24.04+ SSH** is socket-activated. Changing the port needs `systemctl daemon-reload`
  and `systemctl restart ssh.socket`; `files/cloud-init/base.yml` does this.
- **openstack.cloud 2.x** returns `server`, `images`, `flavors`, `networks`, `security_group`
  (openstacksdk attribute names such as `is_router_external`). The 1.x keys no longer exist.
- **dnscrypt-proxy** is 2.1.14 on Ubuntu 26.04 and 2.0.45 on 24.04. Use keys both accept (check
  with `dnscrypt-proxy -config <file> -check` on each): 2.1 rejects `fallback_resolver`, 2.0.45
  rejects `bootstrap_resolvers`, and both accept `fallback_resolvers`.
  `dnscrypt-proxy-resolvconf` is masked so the server keeps resolving through systemd-resolved.
- **rsyslog**: Ubuntu's `/etc/rsyslog.conf` already loads imuxsock and imklog; loading them again
  in `rsyslog.d` makes `rsyslogd -N1` fail on the next run.
- **Privacy role** needs `cron` on the server; keep it in the common role's package list.

## Time Wasters to Avoid

Lessons learned - don't spend time on these unless absolutely necessary:

1. **Converting MASQUERADE to SNAT** - MASQUERADE works fine for Algo's use case
2. **Fighting systemd socket activation** - Configure it properly instead of disabling
3. **Debugging NAT before checking DNS** - Most "routing" issues are DNS issues
4. **Complex IPsec policy matching** - Keep NAT rules simple
5. **Testing on existing servers** - Always test on fresh deployments
6. **Interface-specific route_localnet** - WireGuard interface doesn't exist until service starts
7. **DNAT for loopback addresses** - Packets to local IPs don't traverse PREROUTING

## What to Avoid

- **Speculative features** - Don't add "might be useful" functionality. Open an issue instead.
- **New dependencies without justification** - Vanilla Ansible/Python can do most things.
- **Bundling unrelated fixes** - One PR, one purpose. Separate issues get separate PRs.
- **Assuming behavior** - If converting `with_items` to `loop`, test that it still works. If adding a firewall rule, verify packets flow.
- **Configuration options** - Don't add flags unless users actively need them. Each option doubles testing surface.
- **Undocumented workarounds** - When working around broken upstream modules, file an issue and add a comment linking to it. Future maintainers need to know why workarounds exist.

## Quick Reference

```bash
source ./<project>-openrc.sh   # DreamCompute credentials
./algo                         # deploy, or re-run after editing users in config.cfg
./algo destroy                 # delete the server (prompts; -e confirm_destroy=true to skip)
ansible-playbook main.yml -vvv # debug
```

## Security Considerations

- **Never expose secrets** - No passwords/keys in commits
- **CVE Response** - Update immediately when security issues found
- **Least Privilege** - Minimal permissions, dropped capabilities
- **Secure Defaults** - Strong crypto (secp384r1), no logging, strict firewall
