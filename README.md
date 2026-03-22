# Server Hardener

Interactive wizard to harden Ubuntu VPS boxes. Tailscale-first.

## Quick Start

```bash
curl -fsSL https://raw.githubusercontent.com/karloscodes/server-hardener/main/harden.sh -o /tmp/harden.sh && sudo bash /tmp/harden.sh
```

## What it does

The wizard asks 4 questions, shows a summary of changes, and asks for confirmation before touching anything.

### Tailscale mode (default)

- Installs Tailscale, optionally authenticates with an auth key
- SSH restricted to Tailscale interface only — **not reachable from the public internet**
- No Fail2ban needed (nobody can reach SSH)
- UFW opens only 80/443 publicly

### No-Tailscale mode

- Moves SSH to a custom port (default 2222)
- Fail2ban protects SSH with progressive bans
- UFW rate-limits SSH

### Both modes

- Admin user with key-only SSH + passwordless sudo
- Root login disabled, password auth disabled
- Kernel/network sysctl hardening
- Unattended security upgrades (auto-reboot at 03:30)
- Health check verifies everything at the end

## Wizard

| Question | Default | Notes |
|----------|---------|-------|
| Admin username | `ubuntu` | Created if missing, seeded with root's SSH keys |
| Enable Tailscale? | yes | Restricts SSH to Tailscale network |
| Tailscale auth key | empty | Optional — generate at [Tailscale admin](https://login.tailscale.com/admin/settings/keys) |
| SSH port | 2222 | Only asked if Tailscale is disabled |
| TCP ports to open | 80 443 | Public-facing ports |

## Requirements

- Ubuntu 24.04 LTS
- Root access
- SSH key in `/root/.ssh/authorized_keys` (or set `SOURCE_AUTHORIZED_KEYS`)

## License

MIT
