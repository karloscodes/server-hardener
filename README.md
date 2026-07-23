# Server Hardener

Interactive wizard to harden Ubuntu VPS boxes. SSH is Tailscale-only, public ingress is Cloudflare Tunnel-only — no ports are ever opened to the internet.

## Quick Start

```bash
curl -fsSL https://raw.githubusercontent.com/karloscodes/server-hardener/main/harden.sh -o /tmp/harden.sh && sudo bash /tmp/harden.sh
```

## What it does

The wizard asks a handful of questions, shows a summary of changes, and asks for confirmation before touching anything.

### SSH

- Admin user with key-only SSH + passwordless sudo
- `AllowUsers <admin>` — only the configured admin can SSH
- `AuthenticationMethods publickey` — cannot be silently weakened by another drop-in
- Root login disabled, password auth disabled
- sshd bound to the Tailscale IP (defense-in-depth on top of UFW)

### Network

- Tailscale installed, optionally auto-authenticated with an auth key
- SSH restricted to the `tailscale0` interface — **not reachable from the public internet**
- UFW: deny incoming, allow outgoing — **no public TCP ports at all**
- Fail2ban is **removed if present** — redundant on tailnet-only SSH and risks self-lockout
- Public ingress (if any) is Cloudflare Tunnel — an outbound-only connection to Cloudflare's edge, so there's nothing listening publicly for the IP-allowlist bypass that plain "restrict to Cloudflare IPs" firewall rules are still vulnerable to (someone else's Cloudflare zone, pointed at your origin IP with a forged `Host` header, still arrives from a real Cloudflare IP)

### Box

- Kernel/network sysctl hardening
- Unattended security upgrades with auto-reboot at 03:30
- Health check at the end verifies everything

> **Operational note:** the Tailscale account is the single point of failure for SSH access to every box. Enable 2FA on the Tailscale account and review your tailnet ACLs to ensure only the right devices can reach `port:22`.
>
> **Key expiry:** Tailscale node keys expire by default (~180 days). Since SSH is Tailscale-only, an expired key disconnects the box and locks you out with no fallback. The wizard offers to disable expiry for you (needs an API access token); if you skip that, disable it manually per-device in the admin console, or re-authenticate (`sudo tailscale up --ssh`) before it lapses. Either way, keep your VPS provider's out-of-band console (serial/VNC) enabled as a break-glass path — Tailscale being the sole SSH route means it's also the sole recovery route if something goes wrong with it.
>
> **Deploy tools that manage their own TLS (e.g. Kamal):** since no port 80 is ever reachable from the public internet, Let's Encrypt's HTTP-01 challenge can never complete. Turn off your deploy tool's automatic SSL/ACME and let Cloudflare terminate TLS at the edge instead (Full or Flexible SSL mode on the zone). Point the Cloudflare Tunnel's Public Hostname route at your app's/proxy's local port over plain HTTP — that routing lives in the Cloudflare dashboard, not in this script.

## Wizard

| Question | Default | Notes |
|----------|---------|-------|
| Admin username | `ubuntu` | Created if missing, seeded with root's SSH keys |
| Tailscale auth key | empty | Optional — generate at [Tailscale admin](https://login.tailscale.com/admin/settings/keys). If empty, run `sudo tailscale up --ssh` after the script finishes. |
| Disable Tailscale key expiry? | yes | Avoids SSH lockout when the node key would otherwise expire. Needs an API access token to apply automatically — leave the token empty to disable it manually later instead. |
| Cloudflare Tunnel token | empty | Create a tunnel + Public Hostname route at [Cloudflare Zero Trust](https://one.dash.cloudflare.com/) > Networks > Tunnels, then paste its token here. Leave empty to skip public ingress for now and add it on a later re-run. |

## Re-running

The script is idempotent — re-run it anytime to:

- Roll out new hardening defaults to existing servers
- Add a Cloudflare Tunnel token you skipped the first time
- Remove fail2ban from boxes hardened with an older version

## Requirements

- Ubuntu 24.04 LTS
- Root access
- SSH key in `/root/.ssh/authorized_keys` (or set `SOURCE_AUTHORIZED_KEYS`)

## License

MIT
