# Server Hardener — Design

## What

A single bash script that hardens Ubuntu VPS boxes through an interactive wizard. Two security modes based on whether Tailscale is used. Ends with a health check that verifies everything worked.

Target: solo devs deploying to Hetzner/DO/Vultr.

## Wizard

Four questions, then a dry-run summary before executing:

1. **Admin username** — default: `ubuntu`
2. **Use Tailscale?** — default: yes
3. **SSH port** — only asked if no Tailscale, default: `2222`
4. **Extra TCP ports to open** — default: `80 443`

After questions: print a summary of what will happen, ask for confirmation.

## Two Modes

### Tailscale Mode (default)

- Install and configure Tailscale (user runs `tailscale up` after)
- SSH restricted to Tailscale interface only (`tailscale0`)
- UFW: allow 80/443 publicly, allow SSH only on tailscale0
- No fail2ban (SSH unreachable from public internet)
- No SSH rate limiting

### No-Tailscale Mode

- SSH moved to custom port (default 2222)
- UFW: allow custom SSH port + 80/443
- SSH rate limited via UFW
- Fail2ban installed and configured for sshd on custom port

### Shared (both modes)

- Admin user: create if missing, passwordless sudo, seed authorized_keys
- SSH: key-only auth, root login disabled, hardened config
- Sysctl: network + kernel hardening
- Unattended upgrades: enabled with auto-reboot at 03:30
- Time sync: systemd-timesyncd enabled

## Health Check

Runs after hardening. Verifies each component and prints pass/fail:

- SSH config valid, root login disabled
- UFW active with expected rules
- Fail2ban running + sshd jail active (no-Tailscale only)
- Sysctl values applied
- Unattended upgrades enabled
- Admin user exists, sudo works, authorized_keys present
- Tailscale connected + IP assigned (Tailscale mode only)

## Script Structure

```
harden.sh (single file, ~300 lines)
├── Preconditions (root, ubuntu, etc.)
├── Helpers (write_if_changed, enable_service_now, apt_update_retry)
├── Wizard (ask questions, build config vars)
├── Summary + Confirmation
├── Modules (functions, called based on mode):
│   ├── setup_admin_user
│   ├── setup_packages
│   ├── setup_unattended_upgrades
│   ├── setup_sysctl
│   ├── setup_ssh
│   ├── setup_ufw
│   ├── setup_fail2ban        (no-Tailscale only)
│   └── setup_tailscale       (Tailscale only)
└── Health Check (verify everything)
```

Each module is an idempotent function. This makes it testable — you can source the script and call individual functions in tests.

## Testing

A `test.sh` script that can run on a fresh Ubuntu VM or container:

- Source `harden.sh` without executing (functions only)
- Test individual module functions
- Test health check against known-good state
- Test wizard input parsing

For CI: use a Docker container with Ubuntu 24.04 to run integration tests.

## Non-goals

- No config files (wizard is the config)
- No multi-OS support (Ubuntu only)
- No daemon/service mode
- No web UI
