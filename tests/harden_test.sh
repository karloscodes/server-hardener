#!/usr/bin/env bash
# Unit tests for harden.sh's pure/testable functions (no root, no system
# mutation). Run: bash tests/harden_test.sh
#
# This does NOT test the setup_* modules — those mutate a real Ubuntu box
# (packages, UFW, sshd, sysctl) and can only be meaningfully verified
# against one. What's covered here is the class of bug that has actually
# bitten this script: silent set -e/pipefail deaths, and detection logic
# returning the wrong thing for edge-case input.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HARDEN_SH="$SCRIPT_DIR/harden.sh"

pass=0
fail=0
skip=0

# harden.sh's detect_* functions use `grep -oP` (GNU grep only — fine,
# since harden.sh only ever runs on Ubuntu). BSD grep (default on macOS)
# doesn't support -P at all, so tests exercising those functions can't
# run locally there. Skip them explicitly rather than reporting a false
# failure that has nothing to do with harden.sh's actual behavior on its
# real target platform.
if echo x | grep -oP 'x' >/dev/null 2>&1; then
  GREP_P_SUPPORTED=1
else
  GREP_P_SUPPORTED=0
fi

skip_test() {
  echo "  skip - $1 (requires GNU grep -P; not available on this platform)"
  skip=$((skip + 1))
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "  ok   - $desc"
    pass=$((pass + 1))
  else
    echo "  FAIL - $desc"
    echo "         expected: '$expected'"
    echo "         actual:   '$actual'"
    fail=$((fail + 1))
  fi
}

assert_match() {
  local desc="$1" pattern="$2" value="$3"
  if [[ "$value" =~ $pattern ]]; then
    echo "  ok   - $desc"
    pass=$((pass + 1))
  else
    echo "  FAIL - $desc ('$value' did not match pattern)"
    fail=$((fail + 1))
  fi
}

assert_no_match() {
  local desc="$1" pattern="$2" value="$3"
  if [[ ! "$value" =~ $pattern ]]; then
    echo "  ok   - $desc"
    pass=$((pass + 1))
  else
    echo "  FAIL - $desc ('$value' matched pattern but shouldn't)"
    fail=$((fail + 1))
  fi
}

# Source harden.sh for its function definitions. The
# [[ "${BASH_SOURCE[0]}" == "$0" ]] guard at the bottom means main/run
# never fires just from sourcing.
# shellcheck source=/dev/null
#
# The `|| true` matters: harden.sh's last line is a guard that only runs
# main() when executed directly, not sourced — but when sourced, that
# guard's own false condition becomes the `source` command's exit status,
# which (combined with harden.sh's own set -e taking effect mid-source)
# kills this test script immediately. Not a hypothetical: this is the
# exact same class of bug documented below, just hit while writing the
# tests for it.
source "$HARDEN_SH" || true
# harden.sh sets -e; that would make this test script die on the first
# assertion failure instead of reporting all of them. Sourcing only
# imports its function definitions — its own error-handling behavior
# isn't something we want to inherit here.
set +e

# --- detect_admin_user ----------------------------------------------------
echo "detect_admin_user"
if [[ "$GREP_P_SUPPORTED" -eq 0 ]]; then
  skip_test "detect_admin_user (extracts configured username)"
  skip_test "detect_admin_user (empty when no AllowUsers line)"
  skip_test "detect_admin_user (empty when file doesn't exist)"
else
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' EXIT

  detect_admin_user_with_fixture() {
    local fixture="$1"
    # detect_admin_user hardcodes the real sshd path; override via a
    # wrapper that greps the fixture the same way instead of re-deriving
    # the regex.
    grep -oP '^AllowUsers \K.*' "$fixture" 2>/dev/null || true
  }

  printf '# Managed by server-hardener\nAllowUsers deploy\n' > "$tmpdir/sshd_with_user"
  assert_eq "extracts configured username" "deploy" "$(detect_admin_user_with_fixture "$tmpdir/sshd_with_user")"

  printf '# Managed by server-hardener\nPermitRootLogin no\n' > "$tmpdir/sshd_no_allowusers"
  assert_eq "empty when no AllowUsers line" "" "$(detect_admin_user_with_fixture "$tmpdir/sshd_no_allowusers")"

  assert_eq "empty when file doesn't exist" "" "$(detect_admin_user_with_fixture "$tmpdir/does_not_exist")"
fi

# --- detect_open_ports ------------------------------------------------------
echo "detect_open_ports"
if [[ "$GREP_P_SUPPORTED" -eq 0 ]]; then
  skip_test "detect_open_ports (detects restricted public ports, excludes tailscale0)"
  skip_test "detect_open_ports (excludes port 22 even when it has no tailscale0 marker)"
  skip_test "detect_open_ports (empty when ufw has no public port rules)"
else
  # detect_open_ports calls `ufw` directly; stub it for each case.
  ufw() {
    case "$__TEST_UFW_FIXTURE" in
      cloudflare_restricted)
        cat <<'EOF'
Status: active

To                         Action      From
--                         ------      ----
80/tcp                     ALLOW       173.245.48.0/20
443/tcp                    ALLOW       173.245.48.0/20
22/tcp on tailscale0       ALLOW       Anywhere
EOF
        ;;
      ssh_wrongly_open)
        # The exact real-world case that leaked port 22 into the
        # Cloudflare allowlist: a pre-existing "22/tcp ... Anywhere" rule
        # with no tailscale0 marker at all.
        cat <<'EOF'
Status: active

To                         Action      From
--                         ------      ----
22/tcp                     LIMIT IN    Anywhere
80/tcp                     ALLOW IN    Anywhere
443/tcp                    ALLOW IN    Anywhere
EOF
        ;;
      inactive)
        echo "Status: inactive"
        ;;
      *)
        echo "unknown fixture: $__TEST_UFW_FIXTURE" >&2
        return 1
        ;;
    esac
  }

  __TEST_UFW_FIXTURE=cloudflare_restricted
  assert_eq "detects restricted public ports, excludes tailscale0" "80 443" "$(detect_open_ports)"

  __TEST_UFW_FIXTURE=ssh_wrongly_open
  assert_eq "excludes port 22 even when it has no tailscale0 marker" "80 443" "$(detect_open_ports)"

  __TEST_UFW_FIXTURE=inactive
  assert_eq "empty when ufw has no public port rules" "" "$(detect_open_ports)"

  unset -f ufw
fi

# --- Cloudflare CIDR validation (fetch_cloudflare_ranges's regex) ---------
echo "Cloudflare CIDR regex"
cidr_re='^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$|^[0-9a-fA-F:]+/[0-9]{1,3}$'

assert_match "valid v4 CIDR" "$cidr_re" "173.245.48.0/20"
assert_match "valid v6 CIDR" "$cidr_re" "2400:cb00::/32"
assert_no_match "rejects HTML (fetch endpoint returning an error page)" "$cidr_re" "<html>error</html>"
assert_no_match "rejects empty-ish garbage" "$cidr_re" "not-a-cidr"
assert_no_match "rejects a bare IP with no prefix" "$cidr_re" "173.245.48.0"

# --- Tailscale IP validation (bind_ssh_to_tailscale's CGNAT regex) --------
echo "Tailscale CGNAT IP regex"
ts_re='^100\.([6-9][4-9]|[7-9][0-9]|1[0-1][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}$'

assert_match "accepts a real tailnet IP" "$ts_re" "100.103.171.107"
assert_match "accepts low end of CGNAT range (100.64.x.x)" "$ts_re" "100.64.0.1"
assert_match "accepts high end of CGNAT range (100.127.x.x)" "$ts_re" "100.127.255.255"
assert_no_match "rejects a public IP" "$ts_re" "8.8.8.8"
assert_no_match "rejects a private RFC1918 IP" "$ts_re" "192.168.1.1"
assert_no_match "rejects garbage/warning-line output" "$ts_re" "Warning: something went wrong"
assert_no_match "rejects just outside the CGNAT range (100.63.x.x)" "$ts_re" "100.63.0.1"
assert_no_match "rejects just outside the CGNAT range (100.128.x.x)" "$ts_re" "100.128.0.1"

# --- Static guard: the exact set -e footgun that bit this script twice ---
# ((counter++)) evaluates to the PRE-increment value; when counter is 0,
# that's arithmetic result 0 -> exit status 1 -> set -e kills the whole
# script right after the first pass/fail. Regression-guard against ever
# reintroducing this pattern instead of `counter=$((counter + 1))`.
echo "set -e footgun guard"
footguns="$(grep -nF '++))' "$HARDEN_SH" || true)"
footguns+="$(grep -nF -- '--))' "$HARDEN_SH" || true)"
assert_eq "no bare ((var++))/((var--)) arithmetic commands" "" "$footguns"

# --- Syntax ------------------------------------------------------------
echo "syntax"
if bash -n "$HARDEN_SH" 2>/dev/null; then
  echo "  ok   - bash -n passes"
  pass=$((pass + 1))
else
  echo "  FAIL - bash -n reported a syntax error"
  fail=$((fail + 1))
fi

echo ""
echo "Results: $pass passed, $fail failed, $skip skipped"
[[ $fail -eq 0 ]]
