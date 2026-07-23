#!/usr/bin/env bash
# Server Hardener — Interactive wizard for Ubuntu VPS hardening.
# https://github.com/karloscodes/server-hardener

set -euo pipefail

# --- Colors & Output ---------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }

ask() {
  local prompt="$1" default="${2:-}"
  if [[ -n "$default" ]]; then
    read -rp "$(echo -e "${BOLD}${prompt}${NC} [${default}]: ")" answer
    echo "${answer:-$default}"
  else
    read -rp "$(echo -e "${BOLD}${prompt}${NC}: ")" answer
    echo "$answer"
  fi
}

ask_yn() {
  local prompt="$1" default="${2:-y}"
  local answer
  read -rp "$(echo -e "${BOLD}${prompt} (y/n)${NC} [${default}]: ")" answer
  answer="${answer:-$default}"
  [[ "${answer,,}" == "y" || "${answer,,}" == "yes" ]]
}

# --- Helpers ------------------------------------------------------------------
write_if_changed() {
  local dest="$1"; local tmp; tmp="$(mktemp /tmp/wic.XXXXXX)"
  cat > "$tmp"
  if [[ ! -f "$dest" ]] || ! cmp -s "$tmp" "$dest"; then
    install -m "$(stat -c '%a' "$dest" 2>/dev/null || echo 644)" \
      -o root -g root /dev/null "$dest" 2>/dev/null || true
    mv "$tmp" "$dest"
  else
    rm -f "$tmp"
  fi
}

enable_service_now() {
  local unit="$1"
  systemctl enable --now "$unit" >/dev/null 2>&1 \
    || systemctl restart "$unit" >/dev/null 2>&1 || true
}

apt_update_retry() {
  for i in {1..5}; do
    apt-get update -y && return 0 || { warn "apt update retry $i/5"; sleep 3; }
  done
  return 1
}

# --- Preconditions ------------------------------------------------------------
check_preconditions() {
  if [[ $EUID -ne 0 ]]; then
    error "Run as root: sudo bash $0"
    exit 1
  fi
  . /etc/os-release || { error "Cannot detect OS"; exit 1; }
  if [[ "${ID}" != "ubuntu" ]]; then
    error "Ubuntu only (detected: ${ID})"
    exit 1
  fi
  export DEBIAN_FRONTEND=noninteractive
}

# --- Wizard -------------------------------------------------------------------
run_wizard() {
  echo -e "\n${BOLD}=== Server Hardener ===${NC}\n"

  ADMIN_USER="$(ask "Admin username" "ubuntu")"

  echo -e "  ${BLUE}Tip: Generate an auth key at https://login.tailscale.com/admin/settings/keys${NC}"
  TS_AUTHKEY="$(ask "Tailscale auth key (leave empty to authenticate manually)" "")"

  echo -e "  ${BLUE}Tailscale node keys expire by default (~180 days). Since SSH here is${NC}"
  echo -e "  ${BLUE}Tailscale-only, an expired key disconnects the device and locks you out${NC}"
  echo -e "  ${BLUE}of SSH with no fallback. Disabling expiry removes that risk, at the${NC}"
  echo -e "  ${BLUE}cost of a leaked auth key staying valid until you revoke it by hand.${NC}"
  if ask_yn "Disable Tailscale key expiry for this device?" "y"; then
    DISABLE_KEY_EXPIRY="yes"
    TS_API_TOKEN="$(ask "Tailscale API access token (admin console > Settings > Keys; leave empty to disable manually later)" "")"
  else
    DISABLE_KEY_EXPIRY="no"
    TS_API_TOKEN=""
  fi

  echo -e "  ${BLUE}Public ingress is Cloudflare Tunnel only — no port 80/443 is opened on${NC}"
  echo -e "  ${BLUE}this box. Create a tunnel + Public Hostname route at${NC}"
  echo -e "  ${BLUE}https://one.dash.cloudflare.com/ > Networks > Tunnels, then paste its token.${NC}"
  CF_TUNNEL_TOKEN="$(ask "Cloudflare Tunnel token (leave empty to configure manually later)" "")"
}

# --- Summary ------------------------------------------------------------------
show_summary() {
  echo -e "\n${BOLD}=== What will happen ===${NC}\n"
  info "Admin user:          ${ADMIN_USER} (sudo, passwordless, key-only)"
  info "SSH access:          Tailscale only (not reachable from public internet)"
  info "Tailscale:           installed and connected"
  if [[ -n "$TS_AUTHKEY" ]]; then
    info "Tailscale auth:      auth key provided"
  else
    info "Tailscale auth:      manual (you'll run 'tailscale up --ssh' after)"
  fi
  if [[ "$DISABLE_KEY_EXPIRY" == "yes" ]]; then
    if [[ -n "$TS_API_TOKEN" ]]; then
      info "Tailscale key expiry: disabled via API"
    else
      info "Tailscale key expiry: disable manually (no API token given)"
    fi
  else
    info "Tailscale key expiry: left at default (~180 days)"
  fi
  info "Fail2ban:            removed if installed (redundant behind Tailscale)"
  if [[ -n "$CF_TUNNEL_TOKEN" ]]; then
    info "Public ingress:      Cloudflare Tunnel (no listening port)"
  else
    info "Public ingress:      none configured (add a tunnel token and re-run)"
  fi
  info "Firewall:            UFW (deny incoming, allow outgoing; no public ports)"
  info "Unattended upgrades: enabled (auto-reboot 03:30)"
  info "Sysctl hardening:    enabled"
  echo ""

  if ! ask_yn "Proceed?"; then
    warn "Aborted."
    exit 0
  fi
  echo ""
}

# --- Module: Admin User -------------------------------------------------------
setup_admin_user() {
  info "Setting up admin user '${ADMIN_USER}'..."

  if ! id "$ADMIN_USER" >/dev/null 2>&1; then
    adduser --disabled-password --gecos "" "$ADMIN_USER"
  fi
  usermod -aG sudo "$ADMIN_USER"

  local admin_home admin_ssh_dir admin_auth_keys source_keys
  admin_home="$(getent passwd "$ADMIN_USER" | cut -d: -f6)"
  admin_ssh_dir="${admin_home}/.ssh"
  admin_auth_keys="${admin_ssh_dir}/authorized_keys"
  source_keys="${SOURCE_AUTHORIZED_KEYS:-/root/.ssh/authorized_keys}"

  if [[ -n "$admin_home" ]]; then
    install -d -m 700 -o "$ADMIN_USER" -g "$ADMIN_USER" "$admin_ssh_dir"

    if [[ -f "$source_keys" && ! -s "$admin_auth_keys" ]]; then
      install -m 600 -o "$ADMIN_USER" -g "$ADMIN_USER" "$source_keys" "$admin_auth_keys"
    elif [[ -f "$admin_auth_keys" ]]; then
      chown "$ADMIN_USER":"$ADMIN_USER" "$admin_auth_keys"
      chmod 600 "$admin_auth_keys"
    fi
  fi

  local sudoers_file="/etc/sudoers.d/90-${ADMIN_USER}-nopasswd"
  mkdir -p /etc/sudoers.d
  write_if_changed "$sudoers_file" <<EOF
${ADMIN_USER} ALL=(ALL) NOPASSWD:ALL
EOF
  chmod 440 "$sudoers_file"
  visudo -cf "$sudoers_file"

  success "Admin user '${ADMIN_USER}' configured."
}

# --- Module: Packages ---------------------------------------------------------
setup_packages() {
  info "Updating system and installing packages..."
  apt_update_retry || true

  command -v add-apt-repository >/dev/null 2>&1 \
    || apt-get install -y software-properties-common || true
  if ! grep -Rq "^deb .*universe" /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null; then
    add-apt-repository -y universe || true
    apt_update_retry || true
  fi

  apt-get -y full-upgrade || true

  apt-get -y install ufw unattended-upgrades systemd-timesyncd jq

  success "Packages installed."
}

# --- Module: Unattended Upgrades ----------------------------------------------
setup_unattended_upgrades() {
  info "Configuring unattended upgrades..."
  write_if_changed /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Verbose "1";
EOF
  # 04:30 (not 03:30) so we don't race with app cron jobs that commonly
  # fire at the top/half of the 3 AM hour.
  write_if_changed /etc/apt/apt.conf.d/50unattended-upgrades-local <<'EOF'
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:30";
EOF
  enable_service_now unattended-upgrades
  enable_service_now systemd-timesyncd
  success "Unattended upgrades configured."
}

# --- Module: Sysctl -----------------------------------------------------------
setup_sysctl() {
  info "Applying sysctl hardening..."

  write_if_changed /etc/sysctl.d/60-net-hardening.conf <<'EOF'
net.ipv4.ip_forward=1
# Let sshd / ssh.socket bind the Tailscale IP before tailscaled has assigned
# it. Without this, the 04:30 auto-reboot can race: if ssh.socket binds
# 100.x:22 before tailscale0 exists, the bind fails and SSH never comes up.
net.ipv4.ip_nonlocal_bind=1
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
kernel.kptr_restrict=2
kernel.dmesg_restrict=1
fs.protected_hardlinks=1
fs.protected_symlinks=1
EOF
  sysctl --system >/dev/null
  success "Sysctl hardening applied."
}

# --- Module: SSH --------------------------------------------------------------
setup_ssh() {
  info "Hardening SSH (port 22, Tailscale-only)..."

  local ssh_dir="/etc/ssh/sshd_config.d"
  mkdir -p "$ssh_dir"

  local dropin="$ssh_dir/99-hardening.conf"
  local backup="${dropin}.$(date +%F_%H%M%S).bak"
  [[ -f "$dropin" ]] && cp -a "$dropin" "$backup" || true

  # AuthenticationMethods=publickey is the authoritative source of truth;
  # it implies PubkeyAuthentication and forbids everything else, even if a
  # later drop-in tries to re-enable passwords. So we don't list
  # PubkeyAuthentication separately — single source of truth.
  write_if_changed "$dropin" <<EOF
# Managed by server-hardener
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
AuthenticationMethods publickey
AllowUsers ${ADMIN_USER}
MaxAuthTries 3
LoginGraceTime 30
MaxStartups 10:30:100
X11Forwarding no
PermitEmptyPasswords no
ClientAliveInterval 300
ClientAliveCountMax 2
EOF

  mkdir -p /run/sshd
  if ! sshd -t; then
    error "sshd config test failed — restoring backup."
    [[ -f "$backup" ]] && cp -a "$backup" "$dropin" || rm -f "$dropin"
    exit 1
  fi
  systemctl reload ssh || systemctl reload sshd
  success "SSH hardened."
}

# --- Module: UFW --------------------------------------------------------------
# No public TCP ports at all — public ingress is Cloudflare Tunnel, which is
# an outbound-only connection from this box, so it needs no inbound allow
# rule. Only Tailscale-sourced SSH is ever allowed in.
setup_ufw() {
  info "Configuring UFW..."

  ufw --force reset
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow in on tailscale0 to any port 22 proto tcp
  ufw --force enable
  success "UFW configured."
}

# --- Module: Cloudflare Tunnel -------------------------------------------------
# Sole public-ingress path — no UFW allow rule needed since the tunnel is an
# outbound-only connection from this box to Cloudflare's edge.
#
# Deliberately does NOT use `cloudflared service install <token>`: that
# command bakes the raw token into the generated systemd unit's ExecStart
# line, so it sits in plaintext in the unit file and stays visible in
# `ps`/`/proc/<pid>/cmdline` for the life of the service. Instead we store
# the token in a root-only file and point cloudflared at it with
# --token-file (supported since cloudflared 2025.4.0), same file-based
# secret pattern used for TS_AUTHKEY and the Tailscale API token above.
setup_cloudflare_tunnel() {
  if [[ -z "${CF_TUNNEL_TOKEN:-}" ]]; then
    warn "No Cloudflare Tunnel token given — skipping. Add one and re-run this wizard to enable public ingress."
    return 0
  fi

  info "Installing Cloudflare Tunnel (cloudflared)..."

  if ! command -v cloudflared >/dev/null 2>&1; then
    local arch deb
    arch="$(dpkg --print-architecture)"
    deb="$(mktemp /tmp/cloudflared.XXXXXX.deb)"
    curl --fail --silent --show-error --location \
      -o "$deb" \
      "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}.deb"
    dpkg -i "$deb"
    rm -f "$deb"
  fi

  local cloudflared_bin
  cloudflared_bin="$(command -v cloudflared)"

  install -d -m 700 -o root -g root /etc/cloudflared
  printf '%s' "$CF_TUNNEL_TOKEN" > /etc/cloudflared/token
  chmod 600 /etc/cloudflared/token
  chown root:root /etc/cloudflared/token

  write_if_changed /etc/systemd/system/cloudflared.service <<EOF
[Unit]
Description=Cloudflare Tunnel
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
ExecStart=${cloudflared_bin} --no-autoupdate tunnel run --token-file /etc/cloudflared/token
Restart=on-failure
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  enable_service_now cloudflared.service
  success "Cloudflare Tunnel running."
}

# --- Module: Fail2ban cleanup -------------------------------------------------
# Tailscale is the perimeter — fail2ban on top is redundant and risks
# self-lockout. If a previous run installed it, take it out cleanly and
# remove any leftover iptables chain.
cleanup_fail2ban() {
  if ! dpkg -l fail2ban 2>/dev/null | grep -q '^ii'; then
    return 0
  fi
  info "Removing fail2ban (redundant on tailnet-only SSH)..."
  systemctl disable --now fail2ban >/dev/null 2>&1 || true
  apt-get -y purge fail2ban >/dev/null 2>&1 || true
  iptables -F f2b-sshd 2>/dev/null || true
  iptables -X f2b-sshd 2>/dev/null || true
  rm -f /etc/fail2ban/jail.local
  success "Fail2ban removed."
}

# --- Module: Tailscale --------------------------------------------------------
setup_tailscale() {
  info "Installing Tailscale..."

  if ! command -v tailscale >/dev/null 2>&1; then
    curl -fsSL https://tailscale.com/install.sh | sh
  fi

  if [[ -n "${TS_AUTHKEY:-}" ]]; then
    info "Authenticating Tailscale..."
    # Pass the key via file, not argv — CLI args are visible to any local
    # user through `ps` / /proc/<pid>/cmdline for the life of the process.
    local keyfile
    keyfile="$(mktemp /tmp/ts-authkey.XXXXXX)"
    chmod 600 "$keyfile"
    printf '%s' "$TS_AUTHKEY" > "$keyfile"
    tailscale up --authkey="file:${keyfile}" --ssh
    shred -u "$keyfile" 2>/dev/null || rm -f "$keyfile"
    success "Tailscale connected."
  else
    success "Tailscale installed."
    warn "Run 'sudo tailscale up --ssh' to authenticate."
  fi

  bind_ssh_to_tailscale
  disable_key_expiry
}

# Disables node key expiry via the Tailscale API so SSH (Tailscale-only)
# can't be locked out by an unattended device silently disconnecting.
# Requires the device to already be connected (to read its ID) and an
# API access token (separate from the auth key) supplied in the wizard.
disable_key_expiry() {
  [[ "${DISABLE_KEY_EXPIRY:-no}" == "yes" ]] || return 0

  if [[ -z "${TS_API_TOKEN:-}" ]]; then
    warn "No API token given — disable key expiry manually: admin console > Machines > '...' > Disable key expiry."
    return 0
  fi

  local device_id
  device_id="$(tailscale status --json 2>/dev/null | jq -r '.Self.ID // empty')"
  if [[ -z "$device_id" ]]; then
    warn "Tailscale not connected yet — can't disable key expiry. Re-run this script after 'tailscale up --ssh'."
    return 0
  fi

  info "Disabling Tailscale key expiry via API..."

  # Token goes in a netrc file, not a curl argv flag — same reasoning as
  # the auth key: argv is visible to any local user via ps/proc.
  local netrc
  netrc="$(mktemp /tmp/ts-netrc.XXXXXX)"
  chmod 600 "$netrc"
  printf 'machine api.tailscale.com\nlogin %s\npassword\n' "$TS_API_TOKEN" > "$netrc"

  local ok=0
  curl --fail --silent --show-error --netrc-file "$netrc" -X POST \
    -H "Content-Type: application/json" \
    --data '{"keyExpiryDisabled": true}' \
    "https://api.tailscale.com/api/v2/device/${device_id}/key" >/dev/null || ok=1

  shred -u "$netrc" 2>/dev/null || rm -f "$netrc"

  if [[ $ok -eq 0 ]]; then
    success "Key expiry disabled for this device."
  else
    error "Failed to disable key expiry via API — do it manually via the admin console."
  fi
}

# Bind sshd to the Tailscale IP (defense-in-depth on top of the UFW
# tailscale0-only allow rule). UFW already prevents public traffic from
# reaching port 22, but if UFW were ever flushed, an unbound sshd would
# accept it. Binding to the tailnet address removes that footgun.
#
# Reboot-safe via net.ipv4.ip_nonlocal_bind=1 (see setup_sysctl): the bind
# succeeds even when tailscale0 hasn't come up yet, so a boot ordering race
# can't lock SSH out.
bind_ssh_to_tailscale() {
  local ts_ip
  ts_ip="$(tailscale ip -4 2>/dev/null | head -1 || true)"
  if [[ -z "$ts_ip" ]]; then
    warn "Tailscale IP not yet assigned — skipping ListenAddress binding."
    warn "After 'sudo tailscale up --ssh', re-run this script to apply."
    return 0
  fi

  # Guard against garbage (warning lines, partial output) being written as
  # ListenAddress — a malformed value makes 'sshd -t' fail and can lock SSH.
  # Tailnet IPv4 always lives in 100.64.0.0/10 (CGNAT range).
  if [[ ! "$ts_ip" =~ ^100\.([6-9][4-9]|[7-9][0-9]|1[0-1][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    warn "Unexpected Tailscale IP '${ts_ip}' — skipping ListenAddress binding."
    return 0
  fi

  local dropin="/etc/ssh/sshd_config.d/99-hardening.conf"
  if grep -qE "^ListenAddress[[:space:]]+${ts_ip}\b" "$dropin" 2>/dev/null; then
    return 0
  fi

  info "Binding sshd to Tailscale IP ${ts_ip}..."
  # Strip any previous ListenAddress and append the current one. Idempotent
  # across re-runs even if the Tailscale IP rotates.
  sed -i '/^ListenAddress\b/d' "$dropin"
  printf '\nListenAddress %s\n' "$ts_ip" >> "$dropin"

  if ! sshd -t; then
    error "sshd config test failed after adding ListenAddress — reverting."
    sed -i '/^ListenAddress\b/d' "$dropin"
    return 1
  fi
  systemctl reload ssh || systemctl reload sshd

  # On socket-activated sshd (Ubuntu 24.04 default), the actual port
  # binding lives in ssh.socket — generated from sshd_config's
  # ListenAddress by systemd-sshd-generator. Generators only run at
  # boot or on daemon-reload, and the socket itself needs a restart
  # to pick up the new bind. Existing SSH sessions survive both.
  if systemctl is-active --quiet ssh.socket; then
    systemctl daemon-reload
    systemctl restart ssh.socket
  fi
  success "sshd now bound to ${ts_ip} only."
}

# --- Health Check -------------------------------------------------------------
run_healthcheck() {
  echo -e "\n${BOLD}=== Health Check ===${NC}\n"
  local passed=0 failed=0

  check() {
    local label="$1"; shift
    local out
    if out="$(eval "$@" 2>&1)"; then
      success "$label"
      ((passed++))
    else
      error "FAIL: $label"
      [[ -n "$out" ]] && echo "$out" | sed 's/^/         /' >&2
      ((failed++))
    fi
  }

  # SSH
  check "SSH config valid" "sshd -t"
  check "Root login disabled" "grep -q 'PermitRootLogin no' /etc/ssh/sshd_config.d/99-hardening.conf"
  check "Password auth disabled" "grep -q 'PasswordAuthentication no' /etc/ssh/sshd_config.d/99-hardening.conf"
  check "AuthenticationMethods=publickey" "grep -q 'AuthenticationMethods publickey' /etc/ssh/sshd_config.d/99-hardening.conf"
  check "AllowUsers ${ADMIN_USER}" "grep -q 'AllowUsers ${ADMIN_USER}' /etc/ssh/sshd_config.d/99-hardening.conf"

  # UFW
  check "UFW active" "ufw status | grep -q 'Status: active'"

  # Admin user
  check "Admin user '${ADMIN_USER}' exists" "id '$ADMIN_USER'"
  check "Admin user has sudo" "groups '$ADMIN_USER' | grep -q sudo"
  check "Sudoers file valid" "visudo -cf '/etc/sudoers.d/90-${ADMIN_USER}-nopasswd'"

  # Sysctl
  check "Sysctl hardening applied" "test -f /etc/sysctl.d/60-net-hardening.conf"

  # Unattended upgrades
  check "Unattended upgrades enabled" "systemctl is-enabled unattended-upgrades"

  # Tailscale
  check "Tailscale installed" "command -v tailscale"
  if tailscale status >/dev/null 2>&1; then
    check "Tailscale connected" "tailscale status"
    local ts_ip
    ts_ip="$(tailscale ip -4 2>/dev/null | head -1 || true)"
    if [[ -n "$ts_ip" ]]; then
      success "Tailscale IP: ${ts_ip}"
      ((passed++))
      check "sshd bound to Tailscale IP" "ss -tlnp | grep -q \"${ts_ip}:22\""
    else
      warn "Tailscale IP not assigned yet (run 'sudo tailscale up --ssh')"
    fi

    if [[ "${DISABLE_KEY_EXPIRY:-no}" == "yes" && -n "${TS_API_TOKEN:-}" ]]; then
      local device_id netrc expiry_disabled
      device_id="$(tailscale status --json 2>/dev/null | jq -r '.Self.ID // empty')"
      if [[ -n "$device_id" ]]; then
        netrc="$(mktemp /tmp/ts-netrc.XXXXXX)"
        chmod 600 "$netrc"
        printf 'machine api.tailscale.com\nlogin %s\npassword\n' "$TS_API_TOKEN" > "$netrc"
        expiry_disabled="$(curl --fail --silent --netrc-file "$netrc" \
          "https://api.tailscale.com/api/v2/device/${device_id}" 2>/dev/null \
          | jq -r '.keyExpiryDisabled // false')"
        shred -u "$netrc" 2>/dev/null || rm -f "$netrc"
        check "Tailscale key expiry disabled" "[[ '$expiry_disabled' == 'true' ]]"
      fi
    fi
  else
    warn "Tailscale not connected yet (run 'sudo tailscale up --ssh')"
  fi
  check "UFW allows SSH on tailscale0" "ufw status | grep -q tailscale0"
  check "Fail2ban not installed" "! dpkg -l fail2ban 2>/dev/null | grep -q '^ii'"

  # Cloudflare Tunnel
  if [[ -n "${CF_TUNNEL_TOKEN:-}" ]]; then
    check "cloudflared installed" "command -v cloudflared"
    check "Cloudflare Tunnel service active" "systemctl is-active --quiet cloudflared"
  fi

  echo -e "\n${BOLD}Results: ${GREEN}${passed} passed${NC}, ${RED}${failed} failed${NC}\n"

  if [[ $failed -gt 0 ]]; then
    warn "Some checks failed. Review the output above."
    return 1
  fi
  return 0
}

# --- Main ---------------------------------------------------------------------
main() {
  check_preconditions
  run_wizard
  show_summary

  setup_admin_user
  setup_packages
  setup_unattended_upgrades
  setup_sysctl
  setup_ssh
  setup_ufw
  setup_cloudflare_tunnel
  cleanup_fail2ban
  setup_tailscale

  run_healthcheck

  echo -e "${BOLD}=== Done ===${NC}\n"
  info "Admin user: ${ADMIN_USER}"
  if [[ -z "${TS_AUTHKEY:-}" ]]; then
    warn "Next step: sudo tailscale up --ssh"
  fi
  echo -e "\n  Test: ${BOLD}ssh ${ADMIN_USER}@<tailscale-host>${NC}\n"
}

[[ "${BASH_SOURCE[0]}" == "$0" ]] && main "$@"
