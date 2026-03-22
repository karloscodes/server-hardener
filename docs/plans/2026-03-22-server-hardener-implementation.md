# Server Hardener Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Rewrite `harden-server.sh` into a wizard-driven, modular, testable server hardening script with optional Tailscale support and a built-in health check.

**Architecture:** Single bash script organized as sourced functions. An interactive wizard collects config, shows a dry-run summary, then calls module functions based on user choices. A health check function verifies everything at the end. A separate `test.sh` validates individual functions.

**Tech Stack:** Bash, Ubuntu 24.04, UFW, Fail2ban, Tailscale, systemd

---

### Task 1: Initialize Git Repo + Project Structure

**Files:**
- Create: `.gitignore`
- Create: `LICENSE` (MIT)
- Existing: `harden-server.sh` (will be replaced in later tasks)

**Step 1: Initialize git and create .gitignore**

```bash
cd /Users/karloscodes/Code/server-hardener
git init
```

Create `.gitignore`:
```
*.bak
*.tmp
.DS_Store
```

**Step 2: Create MIT LICENSE**

Standard MIT license with `Carlos` as author, year `2026`.

**Step 3: Commit initial state**

```bash
git add .gitignore LICENSE harden-server.sh docs/
git commit -m "initial commit: original hardening script and design docs"
```

---

### Task 2: Create GitHub Repo

**Step 1: Create public repo on GitHub**

```bash
gh repo create karloscodes/server-hardener --public --source=. --push --description "Interactive server hardening wizard for Ubuntu VPS boxes. Tailscale-first."
```

---

### Task 3: Scaffold the New Script — Helpers + Preconditions

**Files:**
- Create: `harden.sh`

**Step 1: Write the helpers and preconditions section**

Create `harden.sh` with:
- Shebang, `set -euo pipefail`
- Color output helpers: `info()`, `warn()`, `error()`, `success()`, `ask()`
- `write_if_changed()` — same as original
- `enable_service_now()` — same as original
- `apt_update_retry()` — same as original
- Preconditions check function: `check_preconditions()` — must be root, must be Ubuntu
- A `main()` function stub that calls `check_preconditions` then exits
- Script entry: `[[ "${BASH_SOURCE[0]}" == "$0" ]] && main "$@"` — this guard makes the script sourceable for testing

```bash
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
  answer="$(ask "$prompt (y/n)" "$default")"
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

main() {
  check_preconditions
  # wizard, modules, health check will be added in subsequent tasks
}

[[ "${BASH_SOURCE[0]}" == "$0" ]] && main "$@"
```

**Step 2: Verify syntax**

```bash
bash -n harden.sh
```

Expected: no output (valid syntax).

**Step 3: Commit**

```bash
git add harden.sh
git commit -m "scaffold harden.sh with helpers, preconditions, and sourceable guard"
```

---

### Task 4: Wizard + Summary + Confirmation

**Files:**
- Modify: `harden.sh`

**Step 1: Add wizard function**

Add `run_wizard()` after preconditions. Sets global config vars:

```bash
# --- Wizard -------------------------------------------------------------------
run_wizard() {
  echo -e "\n${BOLD}=== Server Hardener ===${NC}\n"

  ADMIN_USER="$(ask "Admin username" "ubuntu")"
  USE_TAILSCALE="$(ask_yn "Enable Tailscale" "y" && echo "yes" || echo "no")"

  if [[ "$USE_TAILSCALE" == "no" ]]; then
    SSH_PORT="$(ask "SSH port" "2222")"
  else
    SSH_PORT=22
  fi

  OPEN_PORTS="$(ask "TCP ports to open publicly" "80 443")"
}
```

**Step 2: Add summary + confirmation function**

```bash
# --- Summary ------------------------------------------------------------------
show_summary() {
  echo -e "\n${BOLD}=== What will happen ===${NC}\n"
  info "Admin user:          ${ADMIN_USER} (sudo, passwordless, key-only)"
  info "SSH port:            ${SSH_PORT}"
  info "SSH access:          $(
    [[ "$USE_TAILSCALE" == "yes" ]] && echo "Tailscale only" || echo "Public (with fail2ban)"
  )"
  info "Tailscale:           ${USE_TAILSCALE}"
  info "Public TCP ports:    ${OPEN_PORTS}"
  info "Firewall:            UFW (deny incoming, allow outgoing)"
  info "Unattended upgrades: enabled (auto-reboot 03:30)"
  info "Sysctl hardening:    enabled"
  echo ""

  if ! ask_yn "Proceed?"; then
    warn "Aborted."
    exit 0
  fi
}
```

**Step 3: Wire into main**

```bash
main() {
  check_preconditions
  run_wizard
  show_summary
  # module calls + health check in subsequent tasks
}
```

**Step 4: Verify syntax**

```bash
bash -n harden.sh
```

**Step 5: Commit**

```bash
git add harden.sh
git commit -m "add interactive wizard and dry-run summary"
```

---

### Task 5: Module — Admin User Setup

**Files:**
- Modify: `harden.sh`

**Step 1: Add setup_admin_user function**

```bash
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
```

**Step 2: Wire into main**

Add `setup_admin_user` call in `main()` after `show_summary`.

**Step 3: Verify syntax, commit**

```bash
bash -n harden.sh
git add harden.sh
git commit -m "add admin user setup module"
```

---

### Task 6: Module — Packages + Unattended Upgrades

**Files:**
- Modify: `harden.sh`

**Step 1: Add setup_packages and setup_unattended_upgrades functions**

```bash
# --- Module: Packages ---------------------------------------------------------
setup_packages() {
  info "Updating system and installing packages..."
  apt_update_retry || true

  # Ensure universe repo (fail2ban lives here)
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
```

**Step 2: Wire into main, verify syntax, commit**

```bash
bash -n harden.sh
git add harden.sh
git commit -m "add packages and unattended upgrades modules"
```

---

### Task 7: Module — Sysctl Hardening

**Files:**
- Modify: `harden.sh`

**Step 1: Add setup_sysctl function**

```bash
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
```

Note: `ip_forward=1` when Tailscale is enabled (Tailscale needs it).

**Step 2: Wire into main, verify syntax, commit**

```bash
bash -n harden.sh
git add harden.sh
git commit -m "add sysctl hardening module (ip_forward=1 for tailscale)"
```

---

### Task 8: Module — SSH Hardening

**Files:**
- Modify: `harden.sh`

**Step 1: Add setup_ssh function**

```bash
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
MaxAuthTries 3
LoginGraceTime 30
MaxStartups 10:30:100
X11Forwarding no
PermitEmptyPasswords no
ClientAliveInterval 300
ClientAliveCountMax 2
EOF

  if ! sshd -t; then
    error "sshd config test failed — restoring backup."
    [[ -f "$backup" ]] && cp -a "$backup" "$dropin" || rm -f "$dropin"
    exit 1
  fi
  systemctl reload ssh || systemctl reload sshd
  success "SSH hardened (port ${SSH_PORT})."
}
```

**Step 2: Wire into main, verify syntax, commit**

```bash
bash -n harden.sh
git add harden.sh
git commit -m "add SSH hardening module with conditional port change"
```

---

### Task 9: Module — UFW Firewall

**Files:**
- Modify: `harden.sh`

**Step 1: Add setup_ufw function**

```bash
# --- Module: UFW --------------------------------------------------------------
setup_ufw() {
  info "Configuring UFW..."
  ufw --force reset
  ufw default deny incoming
  ufw default allow outgoing

  for port in $OPEN_PORTS; do
    ufw allow "${port}/tcp"
  done

  if [[ "$USE_TAILSCALE" == "yes" ]]; then
    # SSH only via Tailscale interface
    ufw allow in on tailscale0 to any port 22 proto tcp
  else
    ufw limit "${SSH_PORT}/tcp"
  fi

  ufw --force enable
  success "UFW configured."
}
```

**Step 2: Wire into main, verify syntax, commit**

```bash
bash -n harden.sh
git add harden.sh
git commit -m "add UFW module with tailscale-aware SSH rules"
```

---

### Task 10: Module — Fail2ban (No-Tailscale Only)

**Files:**
- Modify: `harden.sh`

**Step 1: Add setup_fail2ban function**

```bash
# --- Module: Fail2ban (no-Tailscale only) -------------------------------------
setup_fail2ban() {
  [[ "$USE_TAILSCALE" == "yes" ]] && return 0

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
```

**Step 2: Wire into main, verify syntax, commit**

```bash
bash -n harden.sh
git add harden.sh
git commit -m "add fail2ban module (skipped when tailscale enabled)"
```

---

### Task 11: Module — Tailscale

**Files:**
- Modify: `harden.sh`

**Step 1: Add setup_tailscale function**

```bash
# --- Module: Tailscale --------------------------------------------------------
setup_tailscale() {
  [[ "$USE_TAILSCALE" != "yes" ]] && return 0

  info "Installing Tailscale..."

  if ! command -v tailscale >/dev/null 2>&1; then
    curl -fsSL https://tailscale.com/install.sh | sh
  fi

  success "Tailscale installed."
  warn "Run 'sudo tailscale up' after this script to authenticate."
}
```

**Step 2: Wire into main, verify syntax, commit**

```bash
bash -n harden.sh
git add harden.sh
git commit -m "add tailscale installation module"
```

---

### Task 12: Health Check

**Files:**
- Modify: `harden.sh`

**Step 1: Add run_healthcheck function**

```bash
# --- Health Check -------------------------------------------------------------
run_healthcheck() {
  echo -e "\n${BOLD}=== Health Check ===${NC}\n"
  local passed=0 failed=0

  check() {
    local label="$1"; shift
    if "$@" >/dev/null 2>&1; then
      success "$label"
      ((passed++))
    else
      error "FAIL: $label"
      ((failed++))
    fi
  }

  # SSH
  check "SSH config valid" sshd -t
  check "Root login disabled" grep -q "PermitRootLogin no" /etc/ssh/sshd_config.d/99-hardening.conf
  check "Password auth disabled" grep -q "PasswordAuthentication no" /etc/ssh/sshd_config.d/99-hardening.conf

  # UFW
  check "UFW active" ufw status | grep -q "Status: active"

  # Admin user
  check "Admin user '${ADMIN_USER}' exists" id "$ADMIN_USER"
  check "Admin user has sudo" groups "$ADMIN_USER" | grep -q sudo
  check "Sudoers file valid" visudo -cf "/etc/sudoers.d/90-${ADMIN_USER}-nopasswd"

  # Sysctl
  check "Sysctl hardening applied" test -f /etc/sysctl.d/60-net-hardening.conf

  # Unattended upgrades
  check "Unattended upgrades enabled" systemctl is-enabled unattended-upgrades

  # Mode-specific checks
  if [[ "$USE_TAILSCALE" == "yes" ]]; then
    check "Tailscale installed" command -v tailscale
    if tailscale status >/dev/null 2>&1; then
      check "Tailscale connected" tailscale status
      local ts_ip; ts_ip="$(tailscale ip -4 2>/dev/null || true)"
      if [[ -n "$ts_ip" ]]; then
        success "Tailscale IP: ${ts_ip}"
        ((passed++))
      else
        warn "Tailscale IP not yet assigned (run 'tailscale up' to authenticate)"
      fi
    else
      warn "Tailscale not yet connected (run 'sudo tailscale up' to authenticate)"
    fi
    check "UFW allows SSH on tailscale0" ufw status | grep -q "tailscale0"
  else
    check "Fail2ban running" systemctl is-active fail2ban
    check "Fail2ban sshd jail active" fail2ban-client status sshd
  fi

  echo -e "\n${BOLD}Results: ${GREEN}${passed} passed${NC}, ${RED}${failed} failed${NC}\n"

  if [[ $failed -gt 0 ]]; then
    warn "Some checks failed. Review the output above."
    return 1
  fi
  return 0
}
```

**Step 2: Wire into main, verify syntax, commit**

```bash
bash -n harden.sh
git add harden.sh
git commit -m "add health check with pass/fail verification"
```

---

### Task 13: Wire Everything in main() + Final Summary

**Files:**
- Modify: `harden.sh`

**Step 1: Complete main function**

```bash
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

  echo -e "\n${BOLD}=== Done ===${NC}\n"
  info "Admin user: ${ADMIN_USER}"
  info "SSH port: ${SSH_PORT}"
  if [[ "$USE_TAILSCALE" == "yes" ]]; then
    warn "Next step: sudo tailscale up"
  fi
  info "Test: ssh ${ADMIN_USER}@<server-ip>${SSH_PORT:+ -p $SSH_PORT}"
}
```

**Step 2: Verify syntax, commit**

```bash
bash -n harden.sh
git add harden.sh
git commit -m "wire all modules in main and add final summary"
```

---

### Task 14: Write README

**Files:**
- Create: `README.md`

**Step 1: Write concise README**

```markdown
# Server Hardener

Interactive wizard to harden Ubuntu VPS boxes. Tailscale-first.

## What it does

- Creates admin user with key-only SSH + passwordless sudo
- Hardens SSH config (no root, no passwords)
- Configures UFW firewall
- Enables unattended security upgrades
- Applies kernel/network sysctl hardening
- **Tailscale mode:** SSH restricted to Tailscale network only
- **No-Tailscale mode:** Custom SSH port + Fail2ban protection
- Runs a health check to verify everything

## Usage

```bash
curl -fsSL https://raw.githubusercontent.com/karloscodes/server-hardener/main/harden.sh -o harden.sh
sudo bash harden.sh
```

The wizard will ask you 4 questions, show a summary, and ask for confirmation before making changes.

## Configuration

All config is collected interactively. No config files needed.

| Question | Default | Notes |
|----------|---------|-------|
| Admin username | `ubuntu` | Created if missing |
| Enable Tailscale? | yes | Restricts SSH to Tailscale only |
| SSH port | 2222 | Only asked if Tailscale disabled |
| TCP ports to open | 80 443 | Public-facing ports |

## After hardening

If you enabled Tailscale:
```bash
sudo tailscale up
```

Test access:
```bash
ssh <admin-user>@<server-ip>
```

## Requirements

- Ubuntu 24.04 LTS
- Root access
- SSH key already in `/root/.ssh/authorized_keys`

## License

MIT
```

**Step 2: Commit**

```bash
git add README.md
git commit -m "add README"
```

---

### Task 15: Clean Up + Push

**Step 1: Remove old script**

```bash
git rm harden-server.sh
git commit -m "remove original script (replaced by harden.sh)"
```

**Step 2: Final syntax check**

```bash
bash -n harden.sh
```

**Step 3: Push to GitHub**

```bash
git push
```
