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

  if ask_yn "Enable Tailscale?" "y"; then
    USE_TAILSCALE="yes"
    SSH_PORT=22

    echo -e "  ${BLUE}Tip: Generate an auth key at https://login.tailscale.com/admin/settings/keys${NC}"
    TS_AUTHKEY="$(ask "Tailscale auth key (leave empty to authenticate manually)" "")"
  else
    USE_TAILSCALE="no"
    TS_AUTHKEY=""
    SSH_PORT="$(ask "SSH port" "2222")"
  fi

  OPEN_PORTS="$(ask "TCP ports to open publicly" "80 443")"

  if ask_yn "Restrict public TCP ports to Cloudflare IPs only?" "n"; then
    CLOUDFLARE_ONLY="yes"
  else
    CLOUDFLARE_ONLY="no"
  fi
}

# --- Summary ------------------------------------------------------------------
show_summary() {
  echo -e "\n${BOLD}=== What will happen ===${NC}\n"
  info "Admin user:          ${ADMIN_USER} (sudo, passwordless, key-only)"
  info "SSH port:            ${SSH_PORT}"
  if [[ "$USE_TAILSCALE" == "yes" ]]; then
    info "SSH access:          Tailscale only (not reachable from public internet)"
    info "Tailscale:           yes"
    info "Fail2ban:            removed if installed (redundant behind Tailscale)"
    if [[ -n "$TS_AUTHKEY" ]]; then
      info "Tailscale auth:      auth key provided"
    else
      info "Tailscale auth:      manual (you'll run 'tailscale up' after)"
    fi
  else
    info "SSH access:          Public (protected by Fail2ban)"
    info "Tailscale:           no"
  fi
  if [[ "$CLOUDFLARE_ONLY" == "yes" ]]; then
    info "Public TCP ports:    ${OPEN_PORTS} (restricted to Cloudflare IP ranges)"
  else
    info "Public TCP ports:    ${OPEN_PORTS} (open to the internet)"
  fi
  info "Firewall:            UFW (deny incoming, allow outgoing)"
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

  local packages="ufw unattended-upgrades systemd-timesyncd"
  [[ "$USE_TAILSCALE" == "no" ]] && packages="$packages fail2ban"
  apt-get -y install $packages

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
  write_if_changed /etc/apt/apt.conf.d/50unattended-upgrades-local <<'EOF'
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "03:30";
EOF
  enable_service_now unattended-upgrades
  enable_service_now systemd-timesyncd
  success "Unattended upgrades configured."
}

# --- Module: Sysctl -----------------------------------------------------------
setup_sysctl() {
  info "Applying sysctl hardening..."

  local ip_forward=0
  [[ "$USE_TAILSCALE" == "yes" ]] && ip_forward=1

  write_if_changed /etc/sysctl.d/60-net-hardening.conf <<EOF
net.ipv4.ip_forward=${ip_forward}
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
  info "Hardening SSH (port ${SSH_PORT})..."

  local ssh_dir="/etc/ssh/sshd_config.d"
  mkdir -p "$ssh_dir"

  local dropin="$ssh_dir/99-hardening.conf"
  local backup="${dropin}.$(date +%F_%H%M%S).bak"
  [[ -f "$dropin" ]] && cp -a "$dropin" "$backup" || true

  local port_line=""
  if [[ "$USE_TAILSCALE" == "no" && "$SSH_PORT" != "22" ]]; then
    port_line="Port ${SSH_PORT}"
  fi

  write_if_changed "$dropin" <<EOF
# Managed by server-hardener
${port_line}
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PubkeyAuthentication yes
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
  success "SSH hardened (port ${SSH_PORT})."
}

# --- Module: UFW --------------------------------------------------------------
# Fetches Cloudflare's published IP ranges. Sources:
#   https://www.cloudflare.com/ips-v4
#   https://www.cloudflare.com/ips-v6
# These are the canonical endpoints documented at https://www.cloudflare.com/ips/.
# Plain text, one CIDR per line.
#
# Fails loud if the endpoint is unreachable, returns non-200, or returns
# anything that doesn't look like CIDR blocks. We never apply garbage to
# UFW — better to leave the firewall untouched than to enable it with
# rules that would lock everyone out.
fetch_cloudflare_ranges() {
  local v4 v6 cidr_re='^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$|^[0-9a-fA-F:]+/[0-9]{1,3}$'

  v4="$(curl --fail --silent --show-error --max-time 10 https://www.cloudflare.com/ips-v4)" \
    || { error "Could not fetch https://www.cloudflare.com/ips-v4"; return 1; }
  v6="$(curl --fail --silent --show-error --max-time 10 https://www.cloudflare.com/ips-v6)" \
    || { error "Could not fetch https://www.cloudflare.com/ips-v6"; return 1; }

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    [[ "$line" =~ $cidr_re ]] || { error "Unexpected response from ips-v4 (not a CIDR): $line"; return 1; }
  done <<< "$v4"

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    [[ "$line" =~ $cidr_re ]] || { error "Unexpected response from ips-v6 (not a CIDR): $line"; return 1; }
  done <<< "$v6"

  CF_V4_RANGES="$v4"
  CF_V6_RANGES="$v6"
}

setup_ufw() {
  info "Configuring UFW..."

  # Pre-flight: if the operator chose Cloudflare-only, pull the ranges
  # BEFORE we reset existing rules. A failure here leaves the firewall
  # untouched instead of half-applied.
  if [[ "$CLOUDFLARE_ONLY" == "yes" ]]; then
    fetch_cloudflare_ranges || { error "Cloudflare-only mode aborted; firewall unchanged."; return 1; }
  fi

  ufw --force reset
  ufw default deny incoming
  ufw default allow outgoing

  for port in $OPEN_PORTS; do
    if [[ "$CLOUDFLARE_ONLY" == "yes" ]]; then
      while IFS= read -r cidr; do
        [[ -z "$cidr" ]] && continue
        ufw allow from "$cidr" to any port "$port" proto tcp comment "cloudflare-v4"
      done <<< "$CF_V4_RANGES"
      while IFS= read -r cidr; do
        [[ -z "$cidr" ]] && continue
        ufw allow from "$cidr" to any port "$port" proto tcp comment "cloudflare-v6"
      done <<< "$CF_V6_RANGES"
    else
      ufw allow "${port}/tcp"
    fi
  done

  if [[ "$USE_TAILSCALE" == "yes" ]]; then
    ufw allow in on tailscale0 to any port 22 proto tcp
  else
    ufw limit "${SSH_PORT}/tcp"
  fi

  ufw --force enable
  if [[ "$CLOUDFLARE_ONLY" == "yes" ]]; then
    success "UFW configured (public ports restricted to Cloudflare ranges)."
    warn "Cloudflare publishes new ranges occasionally. Re-run this wizard when the list at https://www.cloudflare.com/ips/ changes."
  else
    success "UFW configured."
  fi
}

# --- Module: Fail2ban (no-Tailscale only) -------------------------------------
setup_fail2ban() {
  if [[ "$USE_TAILSCALE" == "yes" ]]; then
    # Tailscale is the perimeter — fail2ban on top is redundant and just
    # bans you from your own tailnet. If a previous hardening run left it
    # installed, take it out cleanly and clear any leftover iptables chain.
    if dpkg -l fail2ban 2>/dev/null | grep -q '^ii'; then
      info "Tailscale enabled — removing fail2ban (redundant on tailnet-only SSH)..."
      systemctl disable --now fail2ban >/dev/null 2>&1 || true
      apt-get -y purge fail2ban >/dev/null 2>&1 || true
      iptables -F f2b-sshd 2>/dev/null || true
      iptables -X f2b-sshd 2>/dev/null || true
      rm -f /etc/fail2ban/jail.local
      success "Fail2ban removed."
    fi
    return 0
  fi

  info "Configuring Fail2ban for sshd on port ${SSH_PORT}..."
  write_if_changed /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5
bantime.increment = true
bantime.factor = 1.5
bantime.formula = bantime * (1 + (failures / 6))

[sshd]
enabled = true
port = ${SSH_PORT}
logpath = %(sshd_log)s
backend = systemd
mode = aggressive
EOF
  enable_service_now fail2ban
  fail2ban-client reload || true
  success "Fail2ban configured."
}

# --- Module: Tailscale --------------------------------------------------------
setup_tailscale() {
  [[ "$USE_TAILSCALE" != "yes" ]] && return 0

  info "Installing Tailscale..."

  if ! command -v tailscale >/dev/null 2>&1; then
    curl -fsSL https://tailscale.com/install.sh | sh
  fi

  if [[ -n "${TS_AUTHKEY:-}" ]]; then
    info "Authenticating Tailscale..."
    tailscale up --authkey="$TS_AUTHKEY" --ssh
    success "Tailscale connected."
  else
    success "Tailscale installed."
    warn "Run 'sudo tailscale up --ssh' to authenticate."
  fi

  bind_ssh_to_tailscale
}

# Bind sshd to the Tailscale IP (defense-in-depth on top of the UFW
# tailscale0-only allow rule). UFW already prevents public traffic from
# reaching port 22, but if UFW were ever flushed, an unbound sshd would
# accept it. Binding to the tailnet address removes that footgun.
bind_ssh_to_tailscale() {
  local ts_ip
  ts_ip="$(tailscale ip -4 2>/dev/null | head -1 || true)"
  if [[ -z "$ts_ip" ]]; then
    warn "Tailscale IP not yet assigned — skipping ListenAddress binding."
    warn "After 'sudo tailscale up --ssh', re-run this script to apply."
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
  success "sshd now bound to ${ts_ip} only."
}

# --- Health Check -------------------------------------------------------------
run_healthcheck() {
  echo -e "\n${BOLD}=== Health Check ===${NC}\n"
  local passed=0 failed=0

  check() {
    local label="$1"; shift
    if eval "$@" >/dev/null 2>&1; then
      success "$label"
      ((passed++))
    else
      error "FAIL: $label"
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
  if [[ "$CLOUDFLARE_ONLY" == "yes" ]]; then
    check "UFW has Cloudflare allow rules" "ufw status | grep -q cloudflare-v4"
  fi

  # Admin user
  check "Admin user '${ADMIN_USER}' exists" "id '$ADMIN_USER'"
  check "Admin user has sudo" "groups '$ADMIN_USER' | grep -q sudo"
  check "Sudoers file valid" "visudo -cf '/etc/sudoers.d/90-${ADMIN_USER}-nopasswd'"

  # Sysctl
  check "Sysctl hardening applied" "test -f /etc/sysctl.d/60-net-hardening.conf"

  # Unattended upgrades
  check "Unattended upgrades enabled" "systemctl is-enabled unattended-upgrades"

  # Mode-specific
  if [[ "$USE_TAILSCALE" == "yes" ]]; then
    check "Tailscale installed" "command -v tailscale"
    if tailscale status >/dev/null 2>&1; then
      check "Tailscale connected" "tailscale status"
      local ts_ip
      ts_ip="$(tailscale ip -4 2>/dev/null || true)"
      if [[ -n "$ts_ip" ]]; then
        success "Tailscale IP: ${ts_ip}"
        ((passed++))
      else
        warn "Tailscale IP not assigned yet (run 'sudo tailscale up --ssh')"
      fi
    else
      warn "Tailscale not connected yet (run 'sudo tailscale up --ssh')"
    fi
    check "UFW allows SSH on tailscale0" "ufw status | grep -q tailscale0"
    check "Fail2ban not installed" "! dpkg -l fail2ban 2>/dev/null | grep -q '^ii'"
    if tailscale ip -4 >/dev/null 2>&1; then
      check "sshd bound to Tailscale IP" "ss -tlnp | grep -q \"$(tailscale ip -4 | head -1):22\""
    fi
  else
    check "Fail2ban running" "systemctl is-active fail2ban"
    check "Fail2ban sshd jail" "fail2ban-client status sshd"
    if [[ "$SSH_PORT" != "22" ]]; then
      check "SSH on custom port ${SSH_PORT}" "grep -q 'Port ${SSH_PORT}' /etc/ssh/sshd_config.d/99-hardening.conf"
    fi
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
  setup_fail2ban
  setup_tailscale

  run_healthcheck

  echo -e "${BOLD}=== Done ===${NC}\n"
  info "Admin user: ${ADMIN_USER}"
  info "SSH port:   ${SSH_PORT}"
  if [[ "$USE_TAILSCALE" == "yes" && -z "${TS_AUTHKEY:-}" ]]; then
    warn "Next step: sudo tailscale up --ssh"
  fi
  echo -e "\n  Test: ${BOLD}ssh ${ADMIN_USER}@<server-ip>${SSH_PORT:+ -p $SSH_PORT}${NC}\n"
}

[[ "${BASH_SOURCE[0]}" == "$0" ]] && main "$@"
