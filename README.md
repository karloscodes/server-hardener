# Server Hardener

Interactive wizard to harden Ubuntu VPS boxes. Tailscale-only.

## Quick Start

```bash
curl -fsSL https://raw.githubusercontent.com/karloscodes/server-hardener/main/harden.sh -o /tmp/harden.sh && sudo bash /tmp/harden.sh
```

## What it does

The wizard asks 3 questions, shows a summary of changes, and asks for confirmation before touching anything.

### SSH

- Admin user with key-only SSH + passwordless sudo
- `AllowUsers <admin>` — only the configured admin can SSH
- `AuthenticationMethods publickey` — cannot be silently weakened by another drop-in
- Root login disabled, password auth disabled
- sshd bound to the Tailscale IP (defense-in-depth on top of UFW)

### Network

- Tailscale installed, optionally auto-authenticated with an auth key
- SSH restricted to the `tailscale0` interface — **not reachable from the public internet**
- UFW: deny incoming, allow outgoing, only your specified ports open publicly
- Fail2ban is **removed if present** — redundant on tailnet-only SSH and risks self-lockout
- Optional: restrict public TCP ports to Cloudflare's IP ranges

### Box

- Kernel/network sysctl hardening
- Unattended security upgrades with auto-reboot at 03:30
- Health check at the end verifies everything

> **Operational note:** the Tailscale account is the single point of failure for SSH access to every box. Enable 2FA on the Tailscale account and review your tailnet ACLs to ensure only the right devices can reach `port:22`.

## Wizard

| Question | Default | Notes |
|----------|---------|-------|
| Admin username | `ubuntu` | Created if missing, seeded with root's SSH keys |
| Tailscale auth key | empty | Optional — generate at [Tailscale admin](https://login.tailscale.com/admin/settings/keys). If empty, run `sudo tailscale up --ssh` after the script finishes. |
| TCP ports to open | `80 443` | Public-facing ports |
| Restrict to Cloudflare IPs? | no | Locks the open ports to Cloudflare's [published IP ranges](https://www.cloudflare.com/ips/) |

## Re-running

The script is idempotent — re-run it anytime to:

- Roll out new hardening defaults to existing servers
- Refresh Cloudflare IP ranges in UFW
- Remove fail2ban from boxes hardened with an older version

## Requirements

- Ubuntu 24.04 LTS
- Root access
- SSH key in `/root/.ssh/authorized_keys` (or set `SOURCE_AUTHORIZED_KEYS`)

## License

MIT
