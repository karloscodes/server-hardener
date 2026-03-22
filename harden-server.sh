#!/usr/bin/env bash
# Harden Ubuntu 24.04 LTS (Hetzner-friendly), idempotent.
# - Keep SSH on port 22.
# - Disable root SSH login + password/KbdInteractive auth (key-only).
# - Ensure ADMIN_USER is sudo + passwordless (NOPASSWD).
# - Configure UFW, Fail2ban, unattended upgrades, and safe sysctls.
# - No DNS changes.

set -euo pipefail

SSH_PORT=22
ADMIN_USER="${ADMIN_USER:-ubuntu}"

# --- Preconditions ---
if [[ $EUID -ne 0 ]]; then echo "Run as root (sudo bash $0)"; exit 1; fi
. /etc/os-release || { echo "Unsupported OS"; exit 1; }
[[ "${ID}" == "ubuntu" ]] || { echo "Ubuntu only"; exit 1; }

export DEBIAN_FRONTEND=noninteractive

# --- Helpers ---
write_if_changed() {
  # write_if_changed <dest>
  local dest="$1"; local tmp; tmp="$(mktemp /tmp/wic.XXXXXX)"
  cat > "$tmp"
  if [[ ! -f "$dest" ]] || ! cmp -s "$tmp" "$dest"; then
    install -m "$(stat -c '%a' "$dest" 2>/dev/null || echo 644)" -o root -g root /dev/null "$dest" 2>/dev/null || true
    mv "$tmp" "$dest"
  else
    rm -f "$tmp"
  fi
}

enable_service_now() {
  local unit="$1"
  systemctl enable --now "$unit" >/dev/null 2>&1 || systemctl restart "$unit" >/dev/null 2>&1 || true
}

apt_update_retry() {
  for i in {1..5}; do
    apt-get update -y && return 0 || { echo "apt update retry $i/5"; sleep 3; }
  done
  return 1
}

# --- Ensure admin user exists + passwordless sudo ---------------------------
echo "==> Ensuring admin user '${ADMIN_USER}' is sudo + passwordless..."
if ! id "$ADMIN_USER" >/dev/null 2>&1; then
  adduser --disabled-password --gecos "" "$ADMIN_USER"
fi
usermod -aG sudo "$ADMIN_USER"

ADMIN_HOME="$(getent passwd "$ADMIN_USER" | cut -d: -f6)"
ADMIN_SSH_DIR="${ADMIN_HOME}/.ssh"
ADMIN_AUTH_KEYS="${ADMIN_SSH_DIR}/authorized_keys"
SOURCE_AUTH_KEYS="${SOURCE_AUTHORIZED_KEYS:-/root/.ssh/authorized_keys}"

# Seed admin authorized_keys if missing (copy from SOURCE_AUTHORIZED_KEYS when available)
if [[ -n "${ADMIN_HOME}" ]]; then
  install -d -m 700 -o "$ADMIN_USER" -g "$ADMIN_USER" "$ADMIN_SSH_DIR"

  if [[ -f "$SOURCE_AUTH_KEYS" && ! -s "$ADMIN_AUTH_KEYS" ]]; then
    install -m 600 -o "$ADMIN_USER" -g "$ADMIN_USER" "$SOURCE_AUTH_KEYS" "$ADMIN_AUTH_KEYS"
  elif [[ -f "$ADMIN_AUTH_KEYS" ]]; then
    chown "$ADMIN_USER":"$ADMIN_USER" "$ADMIN_AUTH_KEYS"
    chmod 600 "$ADMIN_AUTH_KEYS"
  fi
fi

SUDOERS_D="/etc/sudoers.d"
SUDOERS_FILE="${SUDOERS_D}/90-${ADMIN_USER}-nopasswd"
mkdir -p "$SUDOERS_D"
write_if_changed "$SUDOERS_FILE" <<EOF
${ADMIN_USER} ALL=(ALL) NOPASSWD:ALL
EOF
chmod 440 "$SUDOERS_FILE"
# Validate sudoers syntax (fail safely if bad)
visudo -cf "$SUDOERS_FILE"

# --- Enable 'universe' (Fail2ban lives here) --------------------------------
echo "==> Ensuring 'universe' repository is enabled..."
apt_update_retry || true
command -v add-apt-repository >/dev/null 2>&1 || apt-get install -y software-properties-common || true
if ! grep -Rq "^deb .*universe" /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null; then
  add-apt-repository -y universe || true
  apt_update_retry || true
fi

# --- Packages & updates ------------------------------------------------------
echo "==> Updating system and installing packages..."
apt-get -y full-upgrade || true
apt-get -y install ufw fail2ban unattended-upgrades systemd-timesyncd

echo "==> Configuring unattended upgrades..."
write_if_changed /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Verbose "1";
EOF
write_if_changed /etc/apt/apt.conf.d/50unattended-upgrades-local <<'EOF'
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "03:30";
EOF
enable_service_now unattended-upgrades
enable_service_now systemd-timesyncd

# --- UFW firewall ------------------------------------------------------------
echo "==> Configuring UFW (port ${SSH_PORT})..."
ufw --force reset
ufw default deny incoming
ufw default allow outgoing

UFW_ALLOW_TCP_PORTS="${UFW_ALLOW_TCP_PORTS:-80 443}"
for port in $UFW_ALLOW_TCP_PORTS; do
  ufw allow "${port}/tcp"
done

ufw limit ${SSH_PORT}/tcp
ufw --force enable
ufw status verbose || true

# --- Fail2ban ---------------------------------------------------------------
echo "==> Configuring Fail2ban for sshd on port ${SSH_PORT}..."
write_if_changed /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5
bantime.increment = true
bantime.factor = 1.5
bantime.formula = bantime * (1 + (failures / 6))
# Add trusted IPs if desired:
# ignoreip = 127.0.0.1/8 ::1

[sshd]
enabled = true
port = ${SSH_PORT}
logpath = %(sshd_log)s
backend = systemd
mode = aggressive
EOF
enable_service_now fail2ban
fail2ban-client reload || true
fail2ban-client status sshd || true

# --- Sysctl hardening --------------------------------------------------------
echo "==> Applying sysctl hardening..."
write_if_changed /etc/sysctl.d/60-net-hardening.conf <<'EOF'
net.ipv4.ip_forward=0
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.default.accept_redirects=0
net.ipv4.conf.all.send_redirects=0
net.ipv4.conf.default.send_redirects=0
net.ipv4.conf.all.accept_source_route=0
net.ipv4.conf.default.accept_source_route=0
net.ipv4.tcp_syncookies=1
net.ipv4.conf.all.rp_filter=2
net.ipv4.conf.default.rp_filter=2
net.ipv4.conf.all.log_martians=1
net.ipv4.conf.default.log_martians=1
net.ipv6.conf.all.accept_redirects=0
net.ipv6.conf.default.accept_redirects=0
# If your IPv6 setup relies on RA/DHCPv6, set these back to 1:
# net.ipv6.conf.all.accept_ra=1
# net.ipv6.conf.default.accept_ra=1
kernel.kptr_restrict=2
kernel.dmesg_restrict=1
fs.protected_hardlinks=1
fs.protected_symlinks=1
EOF
sysctl --system >/dev/null

# --- SSH hardening (stay on 22, key-only, no root) ---------------------------
echo "==> Hardening SSH (port ${SSH_PORT}, disable root login, key-only auth)..."
SSH_DIR="/etc/ssh/sshd_config.d"; mkdir -p "$SSH_DIR"
DROPIN="$SSH_DIR/99-hardening.conf"
BACKUP="${DROPIN}.$(date +%F_%H%M%S).bak"
[[ -f "$DROPIN" ]] && cp -a "$DROPIN" "$BACKUP" || true

# (No 'Port' line: we keep default 22)
write_if_changed "$DROPIN" <<'EOF'
# Managed by harden.sh
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PubkeyAuthentication yes
MaxAuthTries 3
LoginGraceTime 30
MaxStartups 10:30:100
X11Forwarding no
PermitEmptyPasswords no
ClientAliveInterval 300
ClientAliveCountMax 2
EOF

# Validate and reload sshd
if ! sshd -t; then
  echo "ERROR: sshd config test failed. Restoring previous drop-in..."
  [[ -f "$BACKUP" ]] && cp -a "$BACKUP" "$DROPIN" || rm -f "$DROPIN"
  exit 1
fi
systemctl reload ssh || systemctl reload sshd

cat <<NOTE

✅ Hardening complete.

- SSH remains on port ${SSH_PORT}.
- Root SSH login is disabled; password/KbdInteractive auth disabled (key-only).
- Admin user: ${ADMIN_USER} (sudo + passwordless via /etc/sudoers.d/90-${ADMIN_USER}-nopasswd)
- Firewall: UFW allows 80/443, rate-limits SSH on ${SSH_PORT}.
- Fail2ban protects sshd on port ${SSH_PORT}.
- Unattended upgrades & safe sysctl applied.

Test:
  ssh ${ADMIN_USER}@<server-ip>
  sudo -n true && echo "Passwordless sudo OK"

Troubleshoot:
  sudo journalctl -u ssh -n 100 --no-pager
  sudo fail2ban-client status sshd
  sudo ufw status verbose
NOTE
