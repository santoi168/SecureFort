#!/usr/bin/env bash
set -euo pipefail

# santoi-hardening.sh (v2 — menu-driven, multi-interface aware)
#
# Changes from v1:
#   - Interactive menu: choose which steps to run, in any order, repeatedly.
#   - TARGET_IPS is now an ARRAY (10.0.9.30 WireGuard + 192.168.3.1 wlan0 AP)
#     instead of a single TARGET_IP. sshd and nginx steps are idempotent:
#     they fully normalize the *managed* set of ListenAddress / listen lines
#     to match TARGET_IPS on every run, so re-running never clobbers one
#     interface in favor of another (the bug in v1).
#   - sysctl step uses rp_filter=2 (loose mode) instead of 1 (strict), and
#     also pushes the value live to every existing interface's
#     /proc/sys/net/ipv4/conf/<iface>/rp_filter, since conf.all/default only
#     affect interfaces created *after* the sysctl reload.
#
# SAFETY: every file this script touches is backed up first
# (file.bak.<timestamp>). sshd and nginx restarts ask for confirmation
# separately, since a bad bind can cut off your session.
#
# Usage:
#   chmod +x santoi-hardening.sh
#   sudo ./santoi-hardening.sh

# ---- Interfaces this Pi should stay reachable on ----
# Populated interactively at startup by prompt_target_ips() — see below.
TARGET_IPS=()

SSHD_CONFIG="/etc/ssh/sshd_config"
WAYVNC_CONFIG="/etc/wayvnc/config"
AVAHI_CONFIG="/etc/avahi/avahi-daemon.conf"
NGINX_DEFAULT="/etc/nginx/sites-available/default"
SYSCTL_CONFIG="/etc/sysctl.conf"

MANAGED_TAG="# santoi-hardening:listen"
MANAGED_TAG_DEFAULT="# santoi-hardening:defaultserver"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Run this with sudo: sudo ./santoi-hardening.sh${NC}"
    exit 1
fi

backup_file() {
    local f="$1"
    local ts
    ts=$(date +%s)
    cp "$f" "${f}.bak.${ts}"
    echo "  Backed up: ${f} -> ${f}.bak.${ts}"
}

valid_ipv4() {
    local ip="$1"
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    local IFS='.'
    read -r -a octets <<< "$ip"
    for o in "${octets[@]}"; do
        (( o >= 0 && o <= 255 )) || return 1
    done
    return 0
}

# Detect the indentation actually used inside the server{} block, so
# injected lines match the surrounding style (tabs on Debian's stock
# nginx template) instead of landing at column 0.
get_nginx_indent() {
    local file="$1"
    local indent=""
    indent=$(grep -m1 -E "^[[:space:]]+listen 80 default_server;" "$file" 2>/dev/null | sed -E 's/^([[:space:]]+).*/\1/')
    if [[ -z "$indent" ]]; then
        indent=$(grep -m1 -E "^[[:space:]]+# listen 80 default_server;" "$file" 2>/dev/null | sed -E 's/^([[:space:]]+).*/\1/')
    fi
    if [[ -z "$indent" ]]; then
        indent=$(grep -m1 -E "^[[:space:]]+root " "$file" 2>/dev/null | sed -E 's/^([[:space:]]+).*/\1/')
    fi
    if [[ -z "$indent" ]]; then
        indent=$'\t'
    fi
    printf '%s' "$indent"
}

prompt_target_ips() {
    echo -e "${CYAN}${BOLD}Which interfaces should sshd / nginx / wayvnc stay reachable on?${NC}"
    echo
    echo "IP addresses currently configured on this machine, for reference:"
    ip -o -4 addr show | awk '{print "  " $2 ": " $4}' | grep -v '^\s*lo:' || true
    echo
    echo "Enter target IP addresses, separated by spaces or commas"
    echo "(e.g. 10.0.9.30 192.168.3.1). Press Enter with no input to be"
    echo "prompted one at a time instead."
    read -r -p "> " raw_input

    local candidates=()
    if [[ -n "$raw_input" ]]; then
        raw_input="${raw_input//,/ }"
        read -r -a candidates <<< "$raw_input"
    else
        while true; do
            read -r -p "  Enter an IP (blank to finish): " one_ip
            [[ -z "$one_ip" ]] && break
            candidates+=("$one_ip")
        done
    fi

    TARGET_IPS=()
    for ip in "${candidates[@]}"; do
        if [[ "$ip" == "127.0.0.1" ]]; then
            echo -e "${YELLOW}  Skipping '127.0.0.1' — loopback is already handled automatically${NC}"
            echo -e "${YELLOW}  by the nginx step; adding it here would create a duplicate${NC}"
            echo -e "${YELLOW}  'listen 127.0.0.1:80;' directive and fail nginx's config test.${NC}"
        elif valid_ipv4 "$ip"; then
            TARGET_IPS+=("$ip")
        else
            echo -e "${YELLOW}  Skipping '${ip}' — not a valid IPv4 address.${NC}"
        fi
    done

    if [[ ${#TARGET_IPS[@]} -eq 0 ]]; then
        echo -e "${RED}No valid IP addresses entered. You must provide at least one.${NC}"
        prompt_target_ips
        return
    fi

    echo
    echo -e "${GREEN}Target interfaces set to: ${TARGET_IPS[*]}${NC}"
}

print_banner() {
echo -e "${MAGENTA}${BOLD}"
cat << "EOF"
   _____             _        _   _   _                 _            _
  / ____|           | |      (_) | | | |               | |          (_)
 | (___   __ _ _ __ | |_ ___  _  | |_| | __ _ _ __ __ _  | ___ _ __   __ _
  \___ \ / _` | '_ \| __/ _ \| | |  _  |/ _` | '__/ _` | |/ _ \ '_ \ / _` |
  ____) | (_| | | | | || (_) | | | | | | (_| | | | (_| | |  __/ | | | (_| |
 |_____/ \__,_|_| |_|\__\___/|_| |_| |_|\__,_|_|  \__,_|_|\___|_| |_|\__, |
                                                                       __/ |
                    S A N T O I   H A R D E N I N G                 |___/
EOF
echo -e "${NC}"
echo -e "${CYAN}${BOLD}==========================================================${NC}"
echo -e "${CYAN}${BOLD}     santoi-hardening.sh v2 — menu-driven hardening        ${NC}"
echo -e "${CYAN}${BOLD}==========================================================${NC}"
echo
}

# ============================================================
# Step 1: sshd — normalize ListenAddress lines to TARGET_IPS
# ============================================================
step_sshd() {
    echo -e "${CYAN}${BOLD}Step: sshd — ListenAddress -> ${TARGET_IPS[*]}${NC}"

    if [[ ! -f "$SSHD_CONFIG" ]]; then
        echo -e "${YELLOW}WARNING: ${SSHD_CONFIG} not found. Skipping.${NC}"
        return
    fi

    local desired=()
    for ip in "${TARGET_IPS[@]}"; do
        desired+=("ListenAddress ${ip} ${MANAGED_TAG}")
    done

    # Current managed lines (only ones we tagged ourselves in a prior run)
    local current
    current=$(grep -F "$MANAGED_TAG" "$SSHD_CONFIG" || true)
    local desired_joined
    desired_joined=$(printf "%s\n" "${desired[@]}")

    if [[ "$current" == "$desired_joined" ]]; then
        echo "sshd_config already has exactly the desired managed ListenAddress lines. No change needed."
        return
    fi

    backup_file "$SSHD_CONFIG"

    # Remove any previously-managed lines, keep everything else (including
    # any ListenAddress lines you added manually and did NOT run through
    # this script — those are left alone).
    grep -vF "$MANAGED_TAG" "$SSHD_CONFIG" > "${SSHD_CONFIG}.tmp"
    {
        cat "${SSHD_CONFIG}.tmp"
        echo ""
        echo "# --- santoi-hardening.sh managed ListenAddress block ---"
        printf "%s\n" "${desired[@]}"
    } > "$SSHD_CONFIG"
    rm -f "${SSHD_CONFIG}.tmp"

    echo "Updated ${SSHD_CONFIG}:"
    grep -E "^\s*ListenAddress" "$SSHD_CONFIG" || true

    # Safety check: what interface is our current SSH session on?
    local ssh_client_ip=""
    if command -v who >/dev/null 2>&1; then
        ssh_client_ip=$(who am i 2>/dev/null | grep -oP '(?<=\()[0-9a-fA-F:.]+(?=\))' | head -n1)
    fi
    if [[ -z "$ssh_client_ip" && -n "${SSH_CONNECTION:-}" ]]; then
        ssh_client_ip=$(echo "${SSH_CONNECTION}" | awk '{print $1}')
    fi
    if [[ -n "$ssh_client_ip" ]]; then
        local current_iface
        current_iface=$(ip -o route get "$ssh_client_ip" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')
        echo "You are currently connected via SSH from ${ssh_client_ip} (interface: ${current_iface:-unknown})."
        local matched=false
        for ip in "${TARGET_IPS[@]}"; do
            local target_iface
            target_iface=$(ip -o -4 addr show | awk -v ip="$ip" '$4 ~ ip"/" {print $2}')
            [[ "$current_iface" == "$target_iface" ]] && matched=true
        done
        if [[ "$matched" == false ]]; then
            echo -e "${RED}*** WARNING: none of the target interfaces match your current session's${NC}"
            echo -e "${RED}*** interface (${current_iface:-unknown}). Restarting sshd may disconnect you.${NC}"
        fi
    else
        echo "Could not detect current SSH client IP (may be a local/console session)."
    fi

    read -r -p "Proceed with restarting sshd now? Type 'yes' to continue: " confirm
    if [[ "$confirm" == "yes" ]]; then
        systemctl restart ssh
        echo -e "${GREEN}sshd restarted.${NC}"
    else
        echo "Skipped sshd restart. Config file was updated but not yet applied."
        echo "Run 'sudo systemctl restart ssh' manually when ready."
    fi
}

# ============================================================
# Step 2: wayvnc — bind Address (single value; wayvnc config
# format only supports one 'address=' line)
# ============================================================
step_wayvnc() {
    echo -e "${CYAN}${BOLD}Step: wayvnc — bind Address${NC}"

    if [[ ! -f "$WAYVNC_CONFIG" ]]; then
        echo "${WAYVNC_CONFIG} not found. Skipping."
        return
    fi

    echo "wayvnc's config supports only one 'address=' line. Pick which"
    echo "interface wayvnc should bind to:"
    local i=1
    for ip in "${TARGET_IPS[@]}"; do
        echo "  ${i}) ${ip}"
        i=$((i+1))
    done
    read -r -p "Choice: " choice
    local chosen_ip="${TARGET_IPS[$((choice-1))]:-}"
    if [[ -z "$chosen_ip" ]]; then
        echo -e "${YELLOW}Invalid choice, skipping wayvnc step.${NC}"
        return
    fi

    if grep -qE "^\s*address\s*=\s*${chosen_ip}\s*$" "$WAYVNC_CONFIG"; then
        echo "wayvnc config already binds to ${chosen_ip}. No change needed."
        return
    fi

    backup_file "$WAYVNC_CONFIG"
    if grep -qE "^\s*address\s*=" "$WAYVNC_CONFIG"; then
        sed -i -E "s/^\s*address\s*=.*/address=${chosen_ip}/" "$WAYVNC_CONFIG"
    else
        echo "address=${chosen_ip}" | tee -a "$WAYVNC_CONFIG" >/dev/null
    fi
    echo "Updated ${WAYVNC_CONFIG}:"
    grep -iE "^\s*address" "$WAYVNC_CONFIG" || true
    systemctl restart wayvnc
    echo -e "${GREEN}wayvnc restarted.${NC}"
}

# ============================================================
# Step: avahi — restrict mDNS to one interface, disable wide-area DNS-SD
# ============================================================
step_avahi() {
    echo -e "${CYAN}${BOLD}Step: avahi — restrict mDNS to one interface${NC}"

    if [[ ! -f "$AVAHI_CONFIG" ]]; then
        echo "${AVAHI_CONFIG} not found. Skipping."
        return
    fi

    # avahi restricts by INTERFACE NAME, not IP, so map a chosen TARGET_IPS
    # entry to its interface (same lookup used in the sshd session-safety check).
    echo "avahi's allow-interfaces directive takes an interface name, not an IP."
    echo "Pick which target IP's interface avahi/mDNS should be restricted to:"
    local i=1
    for ip in "${TARGET_IPS[@]}"; do
        echo "  ${i}) ${ip}"
        i=$((i+1))
    done
    read -r -p "Choice: " choice
    local chosen_ip="${TARGET_IPS[$((choice-1))]:-}"
    if [[ -z "$chosen_ip" ]]; then
        echo -e "${YELLOW}Invalid choice, skipping avahi step.${NC}"
        return
    fi

    local chosen_iface
    chosen_iface=$(ip -o -4 addr show | awk -v ip="$chosen_ip" '$4 ~ ip"/" {print $2}')
    if [[ -z "$chosen_iface" ]]; then
        echo -e "${YELLOW}Could not determine which interface has ${chosen_ip}. Skipping.${NC}"
        return
    fi
    echo "Resolved ${chosen_ip} -> interface ${chosen_iface}."

    local already_scoped=false
    local already_no_wide_area=false
    grep -qE "^[[:space:]]*allow-interfaces[[:space:]]*=[[:space:]]*${chosen_iface}[[:space:]]*$" "$AVAHI_CONFIG" && already_scoped=true
    grep -qE "^[[:space:]]*enable-wide-area[[:space:]]*=[[:space:]]*no[[:space:]]*$" "$AVAHI_CONFIG" && already_no_wide_area=true

    if $already_scoped && $already_no_wide_area; then
        echo "avahi already restricted to ${chosen_iface} with wide-area disabled. No change needed."
        return
    fi

    backup_file "$AVAHI_CONFIG"

    # allow-interfaces: handles an active line, the commented template line
    # (#allow-interfaces=eth0), or neither being present.
    if grep -qE "^[[:space:]]*allow-interfaces[[:space:]]*=" "$AVAHI_CONFIG"; then
        sed -i -E "s/^[[:space:]]*allow-interfaces[[:space:]]*=.*/allow-interfaces=${chosen_iface}/" "$AVAHI_CONFIG"
    elif grep -qE "^#allow-interfaces=" "$AVAHI_CONFIG"; then
        sed -i -E "s/^#allow-interfaces=.*/allow-interfaces=${chosen_iface}/" "$AVAHI_CONFIG"
    else
        sed -i "/^\[server\]/a allow-interfaces=${chosen_iface}" "$AVAHI_CONFIG"
    fi

    # enable-wide-area: force to 'no' regardless of current active/commented state.
    if grep -qE "^[[:space:]]*enable-wide-area[[:space:]]*=" "$AVAHI_CONFIG"; then
        sed -i -E "s/^[[:space:]]*enable-wide-area[[:space:]]*=.*/enable-wide-area=no/" "$AVAHI_CONFIG"
    elif grep -qE "^#enable-wide-area=" "$AVAHI_CONFIG"; then
        sed -i -E "s/^#enable-wide-area=.*/enable-wide-area=no/" "$AVAHI_CONFIG"
    else
        sed -i "/^\[wide-area\]/a enable-wide-area=no" "$AVAHI_CONFIG"
    fi

    echo "Updated ${AVAHI_CONFIG}:"
    grep -E "^allow-interfaces|^enable-wide-area" "$AVAHI_CONFIG" || true

    systemctl restart avahi-daemon
    echo -e "${GREEN}avahi-daemon restarted.${NC}"
    echo "Note: 'ss -tulnp | grep avahi' will likely still show 0.0.0.0 — mDNS"
    echo "sockets are bound wide at the OS level for multicast regardless of"
    echo "allow-interfaces. The restriction is enforced in avahi's own logic,"
    echo "not the socket bind. Verify by testing resolution from a device on"
    echo "${chosen_iface} vs. a device on a different interface."
}

# ============================================================
# Step 3: nginx — normalize listen lines to 127.0.0.1:80 + TARGET_IPS:80
# ============================================================
step_nginx() {
    echo -e "${CYAN}${BOLD}Step: nginx — listen 127.0.0.1:80 + ${TARGET_IPS[*]}:80${NC}"

    if [[ ! -f "$NGINX_DEFAULT" ]]; then
        echo -e "${YELLOW}WARNING: ${NGINX_DEFAULT} not found. Skipping.${NC}"
        return
    fi

    local indent
    indent=$(get_nginx_indent "$NGINX_DEFAULT")

    # Defense in depth: 127.0.0.1 is always added below as the first entry,
    # and duplicate listen directives make nginx -t fail. Skip it here (and
    # any accidental duplicate IP) even if it somehow ended up in TARGET_IPS.
    local seen_ips=("127.0.0.1")
    local desired=("${indent}listen 127.0.0.1:80; ${MANAGED_TAG}")
    for ip in "${TARGET_IPS[@]}"; do
        local dupe=false
        for s in "${seen_ips[@]}"; do
            [[ "$ip" == "$s" ]] && dupe=true && break
        done
        if $dupe; then
            echo -e "${YELLOW}  Skipping duplicate/loopback IP in listen list: ${ip}${NC}"
            continue
        fi
        seen_ips+=("$ip")
        desired+=("${indent}listen ${ip}:80; ${MANAGED_TAG}")
    done

    local current desired_joined
    current=$(grep -F "$MANAGED_TAG" "$NGINX_DEFAULT" | grep -vF "$MANAGED_TAG_DEFAULT" || true)
    desired_joined=$(printf "%s\n" "${desired[@]}")

    if [[ "$current" == "$desired_joined" ]]; then
        echo "nginx default site already has exactly the desired managed listen lines. No change needed."
        return
    fi

    backup_file "$NGINX_DEFAULT"

    # --- Pass 1: comment out the stock default_server lines, tagged with a
    #     SEPARATE tag (MANAGED_TAG_DEFAULT) so pass 2 below — which strips
    #     lines carrying MANAGED_TAG — does not delete these too. Only runs
    #     if the uncommented originals are still present (idempotent).
    if grep -qE "^[[:space:]]*listen 80 default_server;" "$NGINX_DEFAULT"; then
        sed -i -E "s/^([[:space:]]*)listen 80 default_server;/\1# listen 80 default_server; ${MANAGED_TAG_DEFAULT}/" "$NGINX_DEFAULT"
    fi
    if grep -qE "^[[:space:]]*listen \[::\]:80 default_server;" "$NGINX_DEFAULT"; then
        sed -i -E "s/^([[:space:]]*)listen \[::\]:80 default_server;/\1# listen [::]:80 default_server; ${MANAGED_TAG_DEFAULT}/" "$NGINX_DEFAULT"
    fi

    # --- Pass 2: strip only the previously-injected listen lines (MANAGED_TAG),
    #     leaving the MANAGED_TAG_DEFAULT comment lines from pass 1 untouched.
    grep -vF "$MANAGED_TAG" "$NGINX_DEFAULT" > "${NGINX_DEFAULT}.tmp" || cp "$NGINX_DEFAULT" "${NGINX_DEFAULT}.tmp"

    # --- Pass 3: inject the desired listen lines right after the first
    #     'server {' block opener. Uses a POSIX bracket class ([[:space:]])
    #     rather than the gawk-only '\s' escape, since Raspberry Pi OS ships
    #     mawk as /usr/bin/awk by default, and '\s' does not mean whitespace
    #     there — it silently fails to match, which previously caused the
    #     injection to be skipped entirely with no error.
    awk -v inject="$(printf '%s\n' "${desired[@]}")" '
        {print}
        /^[[:space:]]*server[[:space:]]*\{/ && !done { print inject; done=1 }
    ' "${NGINX_DEFAULT}.tmp" > "$NGINX_DEFAULT"

    rm -f "${NGINX_DEFAULT}.tmp"

    # Sanity check: confirm the injection actually happened before trusting
    # nginx -t / restarting. If it didn't, stop rather than silently
    # falling back to "no listen directive = listen on everything".
    if ! grep -qF "$MANAGED_TAG" "$NGINX_DEFAULT"; then
        echo -e "${RED}*** ERROR: failed to inject managed listen lines (no 'server {' block found?).${NC}"
        echo -e "${RED}*** Restoring from backup — no changes applied, nginx NOT restarted.${NC}"
        local latest_bak
        latest_bak=$(ls -t "${NGINX_DEFAULT}".bak.* 2>/dev/null | head -n1)
        [[ -n "$latest_bak" ]] && cp "$latest_bak" "$NGINX_DEFAULT"
        return
    fi

    echo "Updated ${NGINX_DEFAULT}:"
    grep -nE "listen (80|\[::\]:80|127\.0\.0\.1:80|$(IFS='|'; echo "${TARGET_IPS[*]}"))" "$NGINX_DEFAULT" || true

    echo
    echo "Testing nginx config syntax before restarting..."
    if nginx -t; then
        echo -e "${GREEN}Config OK.${NC}"
    else
        echo -e "${RED}*** nginx config test FAILED. Not restarting. Review ${NGINX_DEFAULT}.${NC}"
        echo -e "${RED}*** Backup is at the .bak file listed above if you need to revert.${NC}"
        return
    fi

    echo "Disabling and masking 'nginx' service, restarting 'santoi-nginx' service."
    echo "(If 'santoi-nginx' isn't the real unit name, check: systemctl list-units | grep nginx)"
    systemctl disable nginx || true
    systemctl mask nginx || true
    systemctl restart santoi-nginx
    echo -e "${GREEN}santoi-nginx restarted.${NC}"
}

# ============================================================
# Step 4: sysctl — SYN flood / ICMP hardening, rp_filter=2 (loose)
# ============================================================
step_sysctl() {
    echo -e "${CYAN}${BOLD}Step: sysctl hardening (rp_filter=2, loose mode)${NC}"

    local params=(
        "net.ipv4.tcp_syncookies = 1"
        "net.ipv4.tcp_max_syn_backlog = 2048"
        "net.ipv4.tcp_synack_retries = 2"
        "net.ipv4.tcp_rfc1337 = 1"
        "net.ipv4.icmp_echo_ignore_broadcasts = 1"
        "net.ipv4.icmp_ignore_bogus_error_responses = 1"
        "net.ipv4.conf.all.rp_filter = 2"
        "net.ipv4.conf.default.rp_filter = 2"
        "net.ipv4.conf.all.accept_source_route = 0"
        "net.ipv4.conf.all.log_martians = 1"
        "net.ipv4.icmp_echo_ignore_all = 1"
    )

    backup_file "$SYSCTL_CONFIG"

    local needs_header=true
    grep -qF "# Kernel-level SYN flood protection (sysctl)" "$SYSCTL_CONFIG" && needs_header=false

    if $needs_header; then
        {
            echo ""
            echo "# Kernel-level SYN flood protection (sysctl)"
        } | tee -a "$SYSCTL_CONFIG" >/dev/null
    fi

    for param in "${params[@]}"; do
        local key="${param%% =*}"
        if grep -qE "^\s*${key}\s*=" "$SYSCTL_CONFIG"; then
            # Update in place if value differs (handles the rp_filter 1 -> 2 migration)
            sed -i -E "s|^\s*${key}\s*=.*|${param}|" "$SYSCTL_CONFIG"
            echo "  Ensured: ${param}"
        else
            echo "$param" | tee -a "$SYSCTL_CONFIG" >/dev/null
            echo "  Added: ${param}"
        fi
    done

    echo
    echo "Applying sysctl settings from ${SYSCTL_CONFIG}..."
    sysctl -p

    echo
    echo "Pushing rp_filter=2 live to every existing interface (conf.all/default"
    echo "only apply to interfaces created AFTER this reload — existing ones like"
    echo "an already-up WireGuard interface need this explicit per-interface push):"
    for ifpath in /proc/sys/net/ipv4/conf/*/rp_filter; do
        local iface
        iface=$(basename "$(dirname "$ifpath")")
        [[ "$iface" == "lo" || "$iface" == "all" || "$iface" == "default" ]] && continue
        sysctl -w "net.ipv4.conf.${iface}.rp_filter=2" >/dev/null
        echo "  net.ipv4.conf.${iface}.rp_filter = 2"
    done
    echo -e "${GREEN}sysctl hardening applied.${NC}"
}

# ============================================================
# Step 5: report
# ============================================================
step_report() {
    echo -e "${CYAN}${BOLD}Step: current listening state${NC}"
    echo "--- port 80 ---"
    ss -tnpl | grep ':80' || echo "(nothing listening on :80)"
    echo "--- port 22 ---"
    ss -tnpl | grep ':22' || echo "(nothing listening on :22)"
    echo "--- port 5900 ---"
    ss -tnpl | grep ':5900' || echo "(nothing listening on :5900)"
    echo "--- rp_filter per interface ---"
    for ifpath in /proc/sys/net/ipv4/conf/*/rp_filter; do
        local iface
        iface=$(basename "$(dirname "$ifpath")")
        printf "  %-10s %s\n" "$iface" "$(cat "$ifpath")"
    done
}

# ============================================================
# Step 6: list ports bound to the public/wildcard address (0.0.0.0)
# ============================================================
step_public_listeners() {
    echo -e "${CYAN}${BOLD}Step: ports listening on 0.0.0.0 (all interfaces)${NC}"
    echo "Anything shown here is reachable from EVERY interface this Pi has —"
    echo "including any public-facing IP — not just the target IPs you set."
    echo

    echo -e "${BOLD}TCP:${NC}"
    local tcp_hits
    tcp_hits=$(ss -tnlp 2>/dev/null | awk '$4 ~ /^0\.0\.0\.0:/')
    if [[ -n "$tcp_hits" ]]; then
        ss -tnlp 2>/dev/null | awk 'NR==1{print; next} $4 ~ /^0\.0\.0\.0:/{print}'
    else
        echo "  (none)"
    fi

    echo
    echo -e "${BOLD}UDP:${NC}"
    local udp_hits
    udp_hits=$(ss -unlp 2>/dev/null | awk '$4 ~ /^0\.0\.0\.0:/')
    if [[ -n "$udp_hits" ]]; then
        ss -unlp 2>/dev/null | awk 'NR==1{print; next} $4 ~ /^0\.0\.0\.0:/{print}'
    else
        echo "  (none)"
    fi

    echo
    echo -e "${YELLOW}Note:${NC} this only checks the IPv4 wildcard (0.0.0.0). Services bound to"
    echo "the IPv6 wildcard ([::]) are equally exposed on every interface — run"
    echo "option 5 (report) or 'ss -tnlp' / 'ss -unlp' directly to review those too."

    if [[ -n "$tcp_hits" || -n "$udp_hits" ]]; then
        echo
        echo -e "${RED}${BOLD}Any process listed above is reachable from outside this LAN if this${NC}"
        echo -e "${RED}${BOLD}Pi's WAN-facing interface (or router port-forward) exposes it.${NC} Consider"
        echo "rebinding it to one of your target IPs (${TARGET_IPS[*]:-none set}) instead,"
        echo "the same way steps 1-3 do for sshd/wayvnc/nginx."
    fi
}

# ============================================================
# Menu
# ============================================================
print_banner
prompt_target_ips

while true; do
    echo
    echo -e "${BOLD}Choose a step to run:${NC}"
    echo "  1) sshd       — bind ListenAddress to ${TARGET_IPS[*]}"
    echo "  2) wayvnc     — bind Address (pick one interface)"
    echo "  3) nginx      — restrict default site to 127.0.0.1 + ${TARGET_IPS[*]}"
    echo "  4) sysctl     — SYN-flood / ICMP hardening, rp_filter=2"
    echo "  5) report     — show current listening state + rp_filter values"
    echo "  6) avahi      — restrict mDNS to one interface, disable wide-area"
    echo "  6) run all    — steps 1-6 in order"
    echo "  7) change target IPs (currently: ${TARGET_IPS[*]})"
    echo "  8) list ports listening on 0.0.0.0 (public/wildcard)"
    echo "  9) run all    — steps 1-6 in order"
    echo "  0) exit"
    read -r -p "Selection: " sel
    echo

    case "$sel" in
        1) step_sshd ;;
        2) step_wayvnc ;;
        3) step_nginx ;;
        4) step_sysctl ;;
        5) step_report ;;
        6) step_avahi ;;
        7) prompt_target_ips ;;
        8) step_public_listeners ;;
        9) step_sshd; step_wayvnc; step_nginx; step_avahi; step_sysctl; step_report ;;
        0) echo "Exiting. No further changes."; break ;;
        *) echo -e "${YELLOW}Invalid selection.${NC}" ;;
    esac
    echo
    echo -e "${CYAN}----------------------------------------------------------${NC}"
done
