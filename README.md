# Server Hardener

Interactive wizard to harden Ubuntu VPS boxes. Tailscale-only.

## Quick Start

```bash
curl -fsSL https://raw.githubusercontent.com/karloscodes/server-hardener/main/harden.sh -o /tmp/harden.sh && sudo bash /tmp/harden.sh
```

## What it does

The wizard asks a handful of questions, shows a summary of changes, and asks for confirmation before touching anything.

> **Looking for Cloudflare Tunnel-only ingress instead of open ports?** That approach was tried and rolled back — see the `cloudflare-tunnel` branch and its history for why. Short version: it surfaced a real Cloudflare edge-routing issue we couldn't resolve, so this branch stays on the open-ports/Cloudflare-IP-restrict model below.

### SSH

- Admin user with key-only SSH + passwordless sudo
- `AllowUsers <admin>` — only the configured admin can SSH
- `AuthenticationMethods publickey` — cannot be silently weakened by another drop-in
- Root login disabled, password auth disabled
- sshd bound to the Tailscale IP (defense-in-depth on top of UFW)

### Network

- Tailscale installed, optionally auto-authenticated with an auth key
- SSH restricted to the `tailscale0` interface — **not reachable from the public internet**
- UFW: deny incoming, allow outgoing — public ports are always **restricted to Cloudflare's IP ranges**, not opened to the whole internet
- Fail2ban is **removed if present** — redundant on tailnet-only SSH and risks self-lockout
- If Docker is present, also closes the [Docker/UFW bypass](https://github.com/chaifeng/ufw-docker) — Docker publishes container ports via its own iptables rules that ignore UFW entirely, so a container's `-p 80:80` can stay reachable from the whole internet even while `ufw status` reports traffic restricted to Cloudflare. This mirrors the same Cloudflare-IP allowlist at the `DOCKER-USER` chain, which Docker actually respects.

### Box

- Kernel/network sysctl hardening
- Unattended security upgrades with auto-reboot at 03:30
- Health check at the end verifies everything

> **Operational note:** the Tailscale account is the single point of failure for SSH access to every box. Enable 2FA on the Tailscale account and review your tailnet ACLs to ensure only the right devices can reach `port:22`.
>
> **Key expiry:** Tailscale node keys expire by default (~180 days). Since SSH is Tailscale-only, an expired key disconnects the box and locks you out with no fallback. The wizard offers to disable expiry for you (needs an API access token); if you skip that, disable it manually per-device in the admin console, or re-authenticate (`sudo tailscale up --ssh`) before it lapses. Either way, keep your VPS provider's out-of-band console (serial/VNC) enabled as a break-glass path — Tailscale being the sole SSH route means it's also the sole recovery route if something goes wrong with it.

## Wizard

| Question | Default | Notes |
|----------|---------|-------|
| Admin username | `ubuntu` | Created if missing, seeded with root's SSH keys |
| Tailscale auth key | empty | Optional — generate at [Tailscale admin](https://login.tailscale.com/admin/settings/keys). If empty, run `sudo tailscale up --ssh` after the script finishes. |
| Disable Tailscale key expiry? | yes | Avoids SSH lockout when the node key would otherwise expire. Needs an API access token to apply automatically — leave the token empty to disable it manually later instead. |
| TCP ports to open | `80 443` | Public-facing ports — always locked to Cloudflare's [published IP ranges](https://www.cloudflare.com/ips/), including at the Docker/iptables layer if Docker is present |

## Re-running

The script is idempotent — re-run it anytime to:

- Roll out new hardening defaults to existing servers
- Refresh Cloudflare IP ranges in UFW (and the Docker/UFW bypass fix, if applicable)
- Remove fail2ban from boxes hardened with an older version

It also detects what's already configured and skips re-asking for it: the Tailscale auth key question is skipped if already connected, the key-expiry question is skipped if already disabled, and the admin username / public ports default to whatever's already configured instead of the stock defaults.

## Doctor / Fix

```bash
sudo bash harden.sh doctor   # read-only health check, no prompts, no changes
sudo bash harden.sh fix      # re-applies the self-contained hardening steps, then re-checks
```

Both auto-detect the admin user (from the existing `AllowUsers` line) and open ports (from existing UFW rules) instead of asking. `fix` re-applies everything that doesn't need a new secret — UFW, sysctl, admin user/SSH, unattended upgrades, fail2ban cleanup, the Tailscale IP binding, and the Docker/UFW fix. Anything that genuinely needs a fresh secret (Tailscale auth key, API token) isn't touched — run the full wizard (`sudo bash harden.sh`) for those instead.

## Requirements

- Ubuntu 24.04 LTS
- Root access
- SSH key in `/root/.ssh/authorized_keys` (or set `SOURCE_AUTHORIZED_KEYS`)
- Your domain proxied through Cloudflare (orange-cloud DNS) — public ports are locked to Cloudflare's IP ranges, so direct requests to the origin IP won't reach it either way

## License

MIT
