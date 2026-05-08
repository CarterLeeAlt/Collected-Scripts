#!/usr/bin/env bash
# ======================================================
# Debian / Ubuntu VPS Configuration Script
# Improved stable version - manual region selection
# Compatible with Debian 12 / Ubuntu 22.x / most systemd VPS
# ======================================================

set -u
set -o pipefail
export DEBIAN_FRONTEND=noninteractive

BASHRC="/root/.bashrc"
DIRCOLORS="/root/.dircolors"
TIMEZONE="Asia/Shanghai"
HOSTS_FILE="/etc/hosts"
RESOLV_FILE="/etc/resolv.conf"
VIRTIO_BALLOON_BLACKLIST="/etc/modprobe.d/blacklist-virtio-balloon.conf"
GITHUB_RAW_PROXY_PREFIX="https://gh-proxy.com/"

TZ_CHANGED="No"
COLOR_LS="Unknown"
TERM_COLOR="Unknown"
DIRCOLOR_FILE="Unknown"
DIRCOLOR_APPLY="Unknown"
DNS_MODE_DESC="Unknown"
DNS_TEST_RESULT="Unknown"
HOSTNAME_CHANGED="No"
REGION="International"
NEW_DNS1=""
NEW_DNS2=""
GITHUB_RAW_MODE="Direct"
ROOT_SSH_LOGIN="Unknown"
ROOT_PASSWORD_AUTH="Unknown"
ROOT_PASSWD_STATUS="Unknown"
ROOT_SSH_CONFIG_CHANGED="No"
ROOT_PASSWD_CHANGED="No"
APT_MIRROR_NAME="Unknown"
APT_MIRROR_MAIN="Unknown"
APT_MIRROR_SECURITY="Unknown"
APT_MIRROR_CHANGED="No"
APT_IPV4_CONF="/etc/apt/apt.conf.d/99force-ipv4"
APT_SOURCES_BACKUP_DIR="/root/apt-sources-backup"
APT_IPV4_FORCED="No"
APT_UPDATE_AFTER_MIRROR="Unknown"

# ------------------------------------------------------
# Logging helpers
# ------------------------------------------------------
log()  { echo -e "[INFO] $*"; }
warn() { echo -e "[WARN] $*" >&2; }
err()  { echo -e "[ERROR] $*" >&2; }

# ------------------------------------------------------
# Ensure running as root
# ------------------------------------------------------
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    echo "This script must be run as root. Re-running with sudo..."
    exec sudo -E bash "$0" "$@"
fi

# ------------------------------------------------------
# Safe wrapper for commands
# ------------------------------------------------------
S() {
    if command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    else
        "$@"
    fi
}

# ------------------------------------------------------
# Helpers
# ------------------------------------------------------
is_interactive() {
    [[ -t 0 && -t 1 ]]
}

ask_yes_no() {
    local prompt="$1"
    local default="${2:-n}"
    local input

    if ! is_interactive; then
        [[ "$default" =~ ^[Yy]$ ]] && return 0 || return 1
    fi

    if [[ "$default" =~ ^[Yy]$ ]]; then
        read -r -p "$prompt [Y/n]: " input
        input="${input:-y}"
    else
        read -r -p "$prompt [y/N]: " input
        input="${input:-n}"
    fi

    input="${input,,}"
    [[ "$input" == "y" || "$input" == "yes" ]]
}

has_systemd() {
    command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]
}

safe_chattr_remove_immutable() {
    local file="$1"
    if command -v lsattr >/dev/null 2>&1 && command -v chattr >/dev/null 2>&1 && [[ -e "$file" ]]; then
        if lsattr "$file" 2>/dev/null | grep -q 'i'; then
            chattr -i "$file" 2>/dev/null || true
        fi
    fi
}

safe_chattr_add_immutable() {
    local file="$1"
    if command -v chattr >/dev/null 2>&1 && [[ -e "$file" ]]; then
        chattr +i "$file" 2>/dev/null || true
    fi
}

is_pkg_installed() {
    local pkg="$1"
    dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed"
}

apt_install_missing() {
    local missing=()
    local pkg

    for pkg in "$@"; do
        if is_pkg_installed "$pkg"; then
            log "Package already installed: $pkg"
        else
            missing+=("$pkg")
        fi
    done

    if (( ${#missing[@]} == 0 )); then
        log "All requested packages are already installed. Skipping apt install."
        return 0
    fi

    log "Installing missing packages: ${missing[*]}"
    S apt-get update -y || return 1
    S apt-get install -y "${missing[@]}"
}

apt_purge_installed() {
    local installed=()
    local pkg

    for pkg in "$@"; do
        if is_pkg_installed "$pkg"; then
            installed+=("$pkg")
        else
            log "Package not installed, skipping purge: $pkg"
        fi
    done

    if (( ${#installed[@]} == 0 )); then
        log "No installed packages need to be purged."
        return 0
    fi

    log "Purging installed packages: ${installed[*]}"
    S apt-get purge -y "${installed[@]}" || true
    S apt-get autoremove -y || true
}

report_execution_identity() {
    local effective_user effective_uid login_user

    effective_user="$(whoami 2>/dev/null || echo unknown)"
    effective_uid="${EUID:-$(id -u)}"
    login_user=""

    if command -v logname >/dev/null 2>&1; then
        login_user="$(logname 2>/dev/null || true)"
    fi

    if [[ -z "$login_user" && -n "${SUDO_USER:-}" ]]; then
        login_user="$SUDO_USER"
    fi

    if [[ -z "$login_user" ]]; then
        login_user="$(who am i 2>/dev/null | awk '{print $1}' || true)"
    fi

    if [[ -z "$login_user" ]]; then
        login_user="$effective_user"
    fi

    log "Current login user: $login_user"
    log "Current effective user: $effective_user"
    log "Current effective UID: $effective_uid"

    if [[ "$effective_uid" -ne 0 ]]; then
        err "Current script is not running with root privileges."
        err "Please run with sudo, for example: sudo bash $0"
        exit 1
    fi

    if [[ "$login_user" == "root" ]]; then
        log "Script is being run from a root login session."
    else
        log "Login user is not root: $login_user"
        log "Script is running with root privileges through sudo/elevation."
    fi
}

ensure_sshd_managed_block() {
    local sshd_config="/etc/ssh/sshd_config"
    local backup_file
    local tmp_file
    local managed_block
    local current_without_block
    local target_content

    log "Checking SSH root password login configuration..."

    if [[ ! -f "$sshd_config" ]]; then
        warn "SSH config file not found: $sshd_config. Skipping root SSH login configuration."
        ROOT_SSH_LOGIN="Skipped (sshd_config missing)"
        ROOT_PASSWORD_AUTH="Skipped (sshd_config missing)"
        return 0
    fi

    backup_file="${sshd_config}.bak.$(date +%Y%m%d%H%M%S)"
    cp "$sshd_config" "$backup_file"
    log "Backed up SSH config to: $backup_file"

    managed_block="# BEGIN MANAGED BY DEBIAN INIT SCRIPT - ROOT PASSWORD SSH LOGIN
PermitRootLogin yes
PasswordAuthentication yes
KbdInteractiveAuthentication no
# END MANAGED BY DEBIAN INIT SCRIPT - ROOT PASSWORD SSH LOGIN"

    tmp_file="$(mktemp /tmp/sshd_config.XXXXXX)"

    awk '
        /^# BEGIN MANAGED BY DEBIAN INIT SCRIPT - ROOT PASSWORD SSH LOGIN$/ {skip=1; next}
        /^# END MANAGED BY DEBIAN INIT SCRIPT - ROOT PASSWORD SSH LOGIN$/ {skip=0; next}
        skip != 1 {print}
    ' "$sshd_config" > "$tmp_file"

    current_without_block="$(cat "$tmp_file")"
    target_content="${managed_block}

${current_without_block}"

    if [[ "$(cat "$sshd_config")" == "$target_content" ]]; then
        log "SSH root/password login managed block is already configured."
    else
        printf '%s\n' "$target_content" > "$sshd_config"
        ROOT_SSH_CONFIG_CHANGED="Yes"
        log "Enabled SSH root password login options in $sshd_config."
    fi

    rm -f "$tmp_file"

    mkdir -p /run/sshd 2>/dev/null || true

    if command -v sshd >/dev/null 2>&1; then
        if sshd -t; then
            log "SSH configuration syntax check passed."
        else
            err "SSH configuration syntax check failed. Restoring backup."
            cp "$backup_file" "$sshd_config"
            ROOT_SSH_CONFIG_CHANGED="Rollback"
            exit 1
        fi
    else
        warn "sshd command not found. Skipping SSH syntax check."
    fi

    ROOT_SSH_LOGIN="yes"
    ROOT_PASSWORD_AUTH="yes"
}

configure_root_password() {
    local status

    log "Checking root password status..."
    status="$(passwd -S root 2>/dev/null | awk '{print $2}' || true)"

    case "$status" in
        P)
            ROOT_PASSWD_STATUS="Password set"
            log "Root account currently has a password set."
            ;;
        L)
            ROOT_PASSWD_STATUS="Locked"
            warn "Root account password is currently locked."
            ;;
        NP)
            ROOT_PASSWD_STATUS="No password"
            warn "Root account currently has no password."
            ;;
        *)
            ROOT_PASSWD_STATUS="Unknown"
            warn "Could not determine root password status."
            ;;
    esac

    if ask_yes_no "Do you want to set or reset the root password now?" "n"; then
        log "Launching passwd root. Please enter the new root password twice."
        if passwd root; then
            ROOT_PASSWD_CHANGED="Yes"
            ROOT_PASSWD_STATUS="Password set/updated"
            log "Root password has been set or updated."
        else
            ROOT_PASSWD_CHANGED="Failed"
            warn "Root password change failed. Continuing with the rest of the script."
        fi
    else
        log "Skipping root password change."
    fi
}

restart_ssh_if_needed() {
    if [[ "$ROOT_SSH_CONFIG_CHANGED" != "Yes" ]]; then
        log "SSH config was not changed by this step. Skipping SSH service restart."
        return 0
    fi

    if ! has_systemd; then
        warn "systemd not detected; please restart SSH service manually if needed."
        return 0
    fi

    log "Restarting SSH service to apply root/password login configuration..."
    if systemctl restart ssh 2>/dev/null; then
        log "SSH service restarted: ssh"
    elif systemctl restart sshd 2>/dev/null; then
        log "SSH service restarted: sshd"
    else
        warn "Failed to restart SSH service. Please check: systemctl status ssh or systemctl status sshd"
        return 1
    fi
}

configure_root_ssh_password_login() {
    log "====== Configuring SSH root password login ======"
    ensure_sshd_managed_block
    configure_root_password
    restart_ssh_if_needed || true

    log "Current effective SSH root/password login settings:"
    if [[ -f /etc/ssh/sshd_config ]]; then
        grep -Ei '^[[:space:]]*(PermitRootLogin|PasswordAuthentication)[[:space:]]+' /etc/ssh/sshd_config || true
    fi
}

blacklist_virtio_balloon() {
    local module="virtio_balloon"

    if [[ -f "$VIRTIO_BALLOON_BLACKLIST" ]] && grep -qE "^[[:space:]]*blacklist[[:space:]]+$module" "$VIRTIO_BALLOON_BLACKLIST"; then
        log "$module is already blacklisted."
    else
        log "Adding blacklist for $module..."
        cat > "$VIRTIO_BALLOON_BLACKLIST" <<EOF
# Disable virtio balloon memory driver
blacklist virtio_balloon
EOF
        log "Blacklist written to $VIRTIO_BALLOON_BLACKLIST."
    fi

    if lsmod | awk '{print $1}' | grep -qx "$module"; then
        log "$module module is currently loaded. Trying to remove it..."
        if rmmod "$module" 2>/dev/null; then
            log "$module module removed."
        else
            warn "Failed to remove $module. It may be in use. Blacklist will take effect after reboot."
        fi
    else
        log "$module module is not loaded. Skipping rmmod."
    fi
}

detect_physical_memory_mb() {
    local mem_kb mem_mb

    mem_kb="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
    if [[ ! "$mem_kb" =~ ^[0-9]+$ ]] || (( mem_kb <= 0 )); then
        err "Failed to detect physical memory from /proc/meminfo."
        exit 1
    fi

    mem_mb=$(( (mem_kb + 1023) / 1024 ))
    echo "$mem_mb"
}

swapfile_active() {
    swapon --show=NAME --noheadings 2>/dev/null | grep -qx "/swapfile"
}

swapfile_size_mb() {
    if [[ -f /swapfile ]]; then
        stat -c '%s' /swapfile 2>/dev/null | awk '{printf "%d", $1/1024/1024}'
    else
        echo 0
    fi
}

active_non_swapfile_swap() {
    swapon --show=NAME --noheadings 2>/dev/null | awk '$1 != "/swapfile" {print}' || true
}

fstab_non_swapfile_swap() {
    if [[ -f /etc/fstab ]]; then
        awk 'NF > 0 && $1 !~ /^#/ && $3 == "swap" && $1 != "/swapfile" {print}' /etc/fstab 2>/dev/null || true
    fi
}

ensure_swap_fstab_entry() {
    cp /etc/fstab "/etc/fstab.bak.$(date +%Y%m%d%H%M%S)"

    sed -i '/^[[:space:]]*\/swapfile[[:space:]].*[[:space:]]swap[[:space:]]/d' /etc/fstab
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
    log "Ensured a single standard /swapfile entry in /etc/fstab."
}

bashrc_has_ls_color() {
    grep -Eq "^[[:space:]]*alias[[:space:]]+ls=['\"]?ls[[:space:]]+--color=auto['\"]?" "$BASHRC" 2>/dev/null
}

bashrc_has_term_color() {
    grep -Eq "^[[:space:]]*export[[:space:]]+TERM=['\"]?xterm-256color['\"]?" "$BASHRC" 2>/dev/null
}

bashrc_has_dircolors_apply() {
    grep -Eq "dircolors[[:space:]]+-b[[:space:]]+.*\.dircolors" "$BASHRC" 2>/dev/null
}

dns_already_configured() {
    [[ -f "$RESOLV_FILE" ]] || return 1
    grep -qE "^[[:space:]]*nameserver[[:space:]]+${NEW_DNS1}[[:space:]]*$" "$RESOLV_FILE" &&
    grep -qE "^[[:space:]]*nameserver[[:space:]]+${NEW_DNS2}[[:space:]]*$" "$RESOLV_FILE"
}

# ------------------------------------------------------
# Manual region selection
# ------------------------------------------------------
select_region_manually() {
    local input

    echo
    echo "VPS Region Selection"
    echo "-------------------------------------------------------"
    echo "1) China / Mainland China VPS"
    echo "2) International / Non-China VPS"
    echo

    if ! is_interactive; then
        warn "Non-interactive shell detected. Defaulting to International."
        REGION="International"
        GITHUB_RAW_MODE="Direct"
        return 0
    fi

    while true; do
        read -r -p "Please select VPS region [1/2] (default: 2): " input
        input="${input:-2}"

        case "$input" in
            1|cn|CN|china|China|CHINA|国内|中国)
                REGION="China"
                GITHUB_RAW_MODE="gh-proxy.com"
                log "Selected VPS region: China"
                log "GitHub Raw Download Mode: gh-proxy.com"
                return 0
                ;;
            2|intl|INTL|international|International|INTERNATIONAL|foreign|Foreign|国外|海外)
                REGION="International"
                GITHUB_RAW_MODE="Direct"
                log "Selected VPS region: International"
                log "GitHub Raw Download Mode: Direct"
                return 0
                ;;
            *)
                warn "Invalid selection. Please enter 1 for China or 2 for International."
                ;;
        esac
    done
}


# ------------------------------------------------------
# APT mirror selection and IPv4-only configuration
# ------------------------------------------------------
select_apt_mirror_manually() {
    local input

    echo
    echo "APT Mirror Selection"
    echo "-------------------------------------------------------"

    if [[ "$REGION" == "China" ]]; then
        echo "China region mirrors:"
        echo "1) USTC - mirrors.ustc.edu.cn"
        echo "2) TUNA - mirrors.tuna.tsinghua.edu.cn"
        echo

        if ! is_interactive; then
            warn "Non-interactive shell detected. Defaulting to USTC for China."
            APT_MIRROR_NAME="USTC"
            APT_MIRROR_MAIN="https://mirrors.ustc.edu.cn/debian"
            APT_MIRROR_SECURITY="https://mirrors.ustc.edu.cn/debian-security"
            return 0
        fi

        while true; do
            read -r -p "Please select APT mirror [1/2] (default: 1): " input
            input="${input:-1}"
            case "$input" in
                1|ustc|USTC|中科大|中国科学技术大学)
                    APT_MIRROR_NAME="USTC"
                    APT_MIRROR_MAIN="https://mirrors.ustc.edu.cn/debian"
                    APT_MIRROR_SECURITY="https://mirrors.ustc.edu.cn/debian-security"
                    return 0
                    ;;
                2|tuna|TUNA|清华|清华大学)
                    APT_MIRROR_NAME="TUNA"
                    APT_MIRROR_MAIN="https://mirrors.tuna.tsinghua.edu.cn/debian"
                    APT_MIRROR_SECURITY="https://mirrors.tuna.tsinghua.edu.cn/debian-security"
                    return 0
                    ;;
                *)
                    warn "Invalid selection. Please enter 1 for USTC or 2 for TUNA."
                    ;;
            esac
        done
    else
        echo "International region mirrors:"
        echo "1) Debian Official CDN - deb.debian.org"
        echo "2) Japan JAIST - ftp.jaist.ac.jp"
        echo

        if ! is_interactive; then
            warn "Non-interactive shell detected. Defaulting to Debian Official CDN for International."
            APT_MIRROR_NAME="Debian Official CDN"
            APT_MIRROR_MAIN="https://deb.debian.org/debian"
            APT_MIRROR_SECURITY="https://deb.debian.org/debian-security"
            return 0
        fi

        while true; do
            read -r -p "Please select APT mirror [1/2] (default: 1): " input
            input="${input:-1}"
            case "$input" in
                1|official|Official|cdn|CDN|debian|Debian|官方|官方源)
                    APT_MIRROR_NAME="Debian Official CDN"
                    APT_MIRROR_MAIN="https://deb.debian.org/debian"
                    APT_MIRROR_SECURITY="https://deb.debian.org/debian-security"
                    return 0
                    ;;
                2|jaist|JAIST|japan|Japan|jp|JP|日本|北陆先端|北陆先端科学技术大学院大学)
                    APT_MIRROR_NAME="Japan JAIST"
                    APT_MIRROR_MAIN="https://ftp.jaist.ac.jp/debian"
                    APT_MIRROR_SECURITY="https://deb.debian.org/debian-security"
                    return 0
                    ;;
                *)
                    warn "Invalid selection. Please enter 1 for Debian Official CDN or 2 for Japan JAIST."
                    ;;
            esac
        done
    fi
}

force_apt_ipv4() {
    mkdir -p /etc/apt/apt.conf.d

    if [[ -f "$APT_IPV4_CONF" ]] && grep -q 'Acquire::ForceIPv4 "true";' "$APT_IPV4_CONF"; then
        APT_IPV4_FORCED="Already enabled"
        log "APT IPv4-only mode is already configured: $APT_IPV4_CONF"
        return 0
    fi

    cat > "$APT_IPV4_CONF" <<'EOF'
Acquire::ForceIPv4 "true";
EOF
    APT_IPV4_FORCED="Enabled"
    log "APT IPv4-only mode enabled: $APT_IPV4_CONF"
}

apt_codename() {
    local codename=""

    if command -v lsb_release >/dev/null 2>&1; then
        codename="$(lsb_release -cs 2>/dev/null || true)"
    fi

    if [[ -z "$codename" && -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        codename="${VERSION_CODENAME:-}"
    fi

    echo "$codename"
}

ensure_apt_sources_backup_dir() {
    mkdir -p "$APT_SOURCES_BACKUP_DIR"
    chmod 700 "$APT_SOURCES_BACKUP_DIR" 2>/dev/null || true
}

backup_if_exists() {
    local target="$1"
    local backup
    local base

    if [[ -e "$target" || -L "$target" ]]; then
        ensure_apt_sources_backup_dir
        base="$(basename "$target")"
        backup="${APT_SOURCES_BACKUP_DIR}/${base}.bak.$(date +%Y%m%d%H%M%S)"
        cp -a "$target" "$backup" 2>/dev/null || true
        log "Backed up $target to $backup"
    fi
}

move_apt_source_backup_out_of_scanned_dir() {
    local file
    local target

    ensure_apt_sources_backup_dir
    shopt -s nullglob
    for file in /etc/apt/sources.list.d/*.bak* \
                /etc/apt/sources.list.d/*.disabled* \
                /etc/apt/sources.list.d/*.save* \
                /etc/apt/sources.list.d/*.orig*; do
        if [[ -e "$file" || -L "$file" ]]; then
            target="${APT_SOURCES_BACKUP_DIR}/$(basename "$file")"
            if [[ -e "$target" ]]; then
                target="${target}.$(date +%Y%m%d%H%M%S)"
            fi
            mv "$file" "$target" 2>/dev/null || true
            log "Moved APT backup file out of sources.list.d: $file -> $target"
        fi
    done
    shopt -u nullglob
}

disable_debian_deb822_sources() {
    local file
    local backup

    mkdir -p /etc/apt/sources.list.d
    ensure_apt_sources_backup_dir

    for file in /etc/apt/sources.list.d/debian.sources /etc/apt/sources.list.d/Debian.sources; do
        if [[ -f "$file" ]]; then
            backup="${APT_SOURCES_BACKUP_DIR}/$(basename "$file").disabled.bak.$(date +%Y%m%d%H%M%S)"
            mv "$file" "$backup"
            log "Disabled existing Debian DEB822 source file: $file -> $backup"
        fi
    done

    move_apt_source_backup_out_of_scanned_dir
}

configure_apt_mirror_and_ipv4() {
    local os_id=""
    local codename=""
    local sources_file="/etc/apt/sources.list"

    log "====== Configuring APT mirror and forcing IPv4 ======"

    force_apt_ipv4

    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        os_id="${ID:-}"
    fi

    if [[ "$os_id" != "debian" ]]; then
        warn "Current OS ID is '${os_id:-unknown}', not Debian. APT IPv4 was configured, but Debian mirror rewrite is skipped."
        APT_MIRROR_CHANGED="Skipped (not Debian)"
        return 0
    fi

    codename="$(apt_codename)"
    if [[ -z "$codename" ]]; then
        warn "Could not detect Debian codename. Defaulting to bookworm for Debian 12."
        codename="bookworm"
    fi

    if [[ "$codename" != "bookworm" ]]; then
        warn "Detected Debian codename '$codename'. This script is tuned for Debian 12 bookworm; applying the same Debian mirror template with detected codename."
    fi

    select_apt_mirror_manually

    backup_if_exists "$sources_file"
    disable_debian_deb822_sources

    cat > "$sources_file" <<EOF
# Debian APT sources managed by this VPS configuration script
# Mirror: ${APT_MIRROR_NAME}

deb ${APT_MIRROR_MAIN}/ ${codename} main contrib non-free non-free-firmware
# deb-src ${APT_MIRROR_MAIN}/ ${codename} main contrib non-free non-free-firmware

deb ${APT_MIRROR_MAIN}/ ${codename}-updates main contrib non-free non-free-firmware
# deb-src ${APT_MIRROR_MAIN}/ ${codename}-updates main contrib non-free non-free-firmware

deb ${APT_MIRROR_MAIN}/ ${codename}-backports main contrib non-free non-free-firmware
# deb-src ${APT_MIRROR_MAIN}/ ${codename}-backports main contrib non-free non-free-firmware

deb ${APT_MIRROR_SECURITY}/ ${codename}-security main contrib non-free non-free-firmware
# deb-src ${APT_MIRROR_SECURITY}/ ${codename}-security main contrib non-free non-free-firmware
EOF

    APT_MIRROR_CHANGED="Yes"
    log "APT mirror configured: $APT_MIRROR_NAME"
    log "Main mirror: $APT_MIRROR_MAIN"
    log "Security mirror: $APT_MIRROR_SECURITY"

    move_apt_source_backup_out_of_scanned_dir

    log "Updating APT package index using the selected mirror..."
    if S apt-get update -y; then
        APT_UPDATE_AFTER_MIRROR="Success"
        log "APT package index updated successfully."
    else
        APT_UPDATE_AFTER_MIRROR="Failed"
        warn "APT package index update failed. The script will continue, but package installation may fail."
    fi
}

github_raw_url() {
    local url="$1"

    if [[ "$url" == https://raw.githubusercontent.com/* ]]; then
        if [[ "$REGION" == "China" ]]; then
            echo "${GITHUB_RAW_PROXY_PREFIX}${url}"
        else
            echo "$url"
        fi
    else
        echo "$url"
    fi
}

curl_github_raw_to_stdout() {
    local url="$1"
    local final_url

    final_url="$(github_raw_url "$url")"
    log "Downloading: $final_url" >&2
    curl -fsSL "$final_url"
}

curl_github_raw_to_file() {
    local url="$1"
    local output_file="$2"
    local final_url

    final_url="$(github_raw_url "$url")"
    log "Downloading: $final_url"
    curl -fsSL "$final_url" -o "$output_file"
}

# ------------------------------------------------------
# Start
# ------------------------------------------------------
log "=== Starting Debian/Ubuntu system configuration... ==="
report_execution_identity

# ------------------------------------------------------
# [0/7] Select region manually and configure APT mirror
# Must run before apt installs and any raw.githubusercontent.com download
# ------------------------------------------------------
log "[0/7] Selecting VPS region manually..."
select_region_manually

log "Assigned Region: ${REGION}"
log "GitHub Raw Download Mode: ${GITHUB_RAW_MODE}"

log "[0/7] Configuring Debian APT mirror and forcing IPv4..."
configure_apt_mirror_and_ipv4

echo "iperf3 iperf3/start_daemon boolean false" | debconf-set-selections

apt_install_missing sudo curl wget unzip dnsutils tree net-tools cron jq nano htop ca-certificates lsb-release iperf3 2>/dev/null \
    || warn "Some base packages failed to install, continuing..."

configure_root_ssh_password_login

apt_purge_installed lrzsz

blacklist_virtio_balloon

curl_github_raw_to_stdout "https://raw.githubusercontent.com/uselibrary/memoryCheck/main/memoryCheck.sh" | bash

hash -r 2>/dev/null || true

# ------------------------------------------------------
# tcping install / check
# ------------------------------------------------------
log "Checking tcping..."

install_tcping() {
    if command -v tcping >/dev/null 2>&1; then
        log "tcping is already installed."
        return 0
    fi

    if apt-cache search '^tcping$' 2>/dev/null | grep -q '^tcping'; then
        log "Installing tcping from apt..."
        S apt-get install -y tcping && command -v tcping >/dev/null 2>&1 && return 0
    fi

    log "tcping not found. Trying remote installer..."
    local tmp_script
    tmp_script="$(mktemp /tmp/tcping_install.XXXXXX.sh)" || return 1

    if curl_github_raw_to_file "https://raw.githubusercontent.com/nodeseeker/tcping/main/install_cn.sh" "$tmp_script"; then
        chmod +x "$tmp_script"
        bash "$tmp_script" --force || true
        rm -f "$tmp_script"
        hash -r 2>/dev/null || true
        command -v tcping >/dev/null 2>&1 && return 0
    else
        rm -f "$tmp_script" 2>/dev/null || true
    fi

    return 1
}

if install_tcping; then
    log "tcping installation/check passed."
    if command -v tcping >/dev/null 2>&1; then
        tcping -4 --count 3 1.1.1.1 80 >/dev/null 2>&1 || warn "tcping test failed, but script will continue."
    fi
else
    warn "tcping installation failed. Skipping tcping test."
fi

# ------------------------------------------------------
# [1/7] Set timezone + NTP
# ------------------------------------------------------
log "[1/7] Setting timezone..."

CURRENT_TZ=""
if command -v timedatectl >/dev/null 2>&1; then
    CURRENT_TZ="$(timedatectl show --property=Timezone --value 2>/dev/null || true)"
fi

if [[ -n "$CURRENT_TZ" && "$CURRENT_TZ" != "$TIMEZONE" ]]; then
    if command -v timedatectl >/dev/null 2>&1; then
        if timedatectl set-timezone "$TIMEZONE" 2>/dev/null; then
            TZ_CHANGED="Yes"
            log "Timezone set to $TIMEZONE."
        else
            warn "Failed to set timezone via timedatectl."
        fi
    fi
elif [[ "$CURRENT_TZ" == "$TIMEZONE" ]]; then
    log "Timezone already set to $TIMEZONE."
else
    warn "Could not detect current timezone. Skipping timezone change."
fi

if has_systemd; then
    if systemctl list-unit-files 2>/dev/null | grep -q '^systemd-timesyncd\.service'; then
        systemctl enable --now systemd-timesyncd >/dev/null 2>&1 || true
        log "Enabled systemd-timesyncd."
    else
        if ! dpkg -s chrony >/dev/null 2>&1; then
            mkdir -p /var/log/chrony
            S apt-get install -y chrony || warn "chrony installation failed."
        fi

        systemctl enable --now chrony >/dev/null 2>&1 || true
        log "Enabled chrony."

        if command -v systemctl >/dev/null 2>&1; then
            systemctl status chrony --no-pager || true
        fi

        if command -v chronyc >/dev/null 2>&1; then
            chronyc tracking || true
        else
            warn "chronyc command not found. Skipping chrony tracking check."
        fi
    fi
else
    warn "systemd not detected; skipping NTP service management."
fi

if command -v timedatectl >/dev/null 2>&1; then
    timedatectl 2>/dev/null || true
fi

# ===========================================================
# SWAP section
# ===========================================================
log "====== Checking current swap status ======"
free -h || true
swapon --show || true
echo

CREATE_SWAP="n"
if ask_yes_no "Do you want to create a swapfile?" "n"; then
    CREATE_SWAP="y"
fi

if [[ "$CREATE_SWAP" != "y" ]]; then
    log "Skipping swapfile creation."
    swapon --show || true
    echo
else
    REAL_MEM_MB="$(detect_physical_memory_mb)"
    if (( REAL_MEM_MB < 1024 )); then
        REQUIRED_MB=$(( REAL_MEM_MB * 2 ))
        SWAP_SIZE_RULE="2x RAM because physical memory is below 1024 MB"
    else
        REQUIRED_MB="$REAL_MEM_MB"
        SWAP_SIZE_RULE="1x RAM because physical memory is 1024 MB or above"
    fi
    SWAP_SIZE="${REQUIRED_MB}M"
    log "User selected: create swapfile. Detected RAM: ${REAL_MEM_MB} MB. Swap rule: ${SWAP_SIZE_RULE}. Target swapfile size: ${SWAP_SIZE}."

    ACTIVE_OTHER_SWAP="$(active_non_swapfile_swap)"
    if [[ -n "$ACTIVE_OTHER_SWAP" ]]; then
        warn "Detected active swap that is not /swapfile:"
        echo "$ACTIVE_OTHER_SWAP"
        warn "Skipping /swapfile creation to avoid duplicate swap configuration."
        swapon --show || true
        echo
    else
        FSTAB_OTHER_SWAP="$(fstab_non_swapfile_swap)"
        if [[ -n "$FSTAB_OTHER_SWAP" ]]; then
            warn "Detected non-/swapfile swap entry in /etc/fstab:"
            echo "$FSTAB_OTHER_SWAP"
            warn "Skipping /swapfile creation to avoid conflicting persistent swap configuration."
            swapon --show || true
            echo
        else
            CURRENT_SWAP_MB="$(swapfile_size_mb)"

            if [[ -f /swapfile ]] && swapfile_active && (( CURRENT_SWAP_MB >= REQUIRED_MB )); then
                log "Existing /swapfile is active and size is sufficient (${CURRENT_SWAP_MB} MB >= ${REQUIRED_MB} MB). Keeping it."
                log "Repairing /etc/fstab entry for /swapfile if needed..."
                ensure_swap_fstab_entry
                swapon --show || true
                free -h || true
                echo
            else
                if [[ -f /swapfile ]]; then
                    log "Existing /swapfile detected but not active or size is insufficient (${CURRENT_SWAP_MB} MB < ${REQUIRED_MB} MB). Recreating..."
                    swapoff /swapfile 2>/dev/null || true
                    rm -f /swapfile || true
                fi

                log "Checking disk free space..."
                AVAILABLE_KB="$(df --output=avail / | tail -1 | tr -d ' ' 2>/dev/null || echo 0)"
                AVAILABLE_MB=$((AVAILABLE_KB / 1024))

                RESERVED_MB=512

                log "Available space: ${AVAILABLE_MB} MB"
                log "Required swap size: ${REQUIRED_MB} MB"
                log "Reserved free space: ${RESERVED_MB} MB"

                if (( AVAILABLE_MB < REQUIRED_MB + RESERVED_MB )); then
                    err "Not enough disk space for swapfile. Need at least $((REQUIRED_MB + RESERVED_MB)) MB free."
                    exit 1
                fi

                log "Creating swapfile with size ${SWAP_SIZE}..."
                if ! fallocate -l "$SWAP_SIZE" /swapfile 2>/dev/null; then
                    warn "fallocate failed, falling back to dd..."
                    if ! dd if=/dev/zero of=/swapfile bs=1M count="$REQUIRED_MB" status=none; then
                        err "Failed to create swapfile."
                        exit 1
                    fi
                fi

                chmod 600 /swapfile
                mkswap /swapfile >/dev/null
                swapon /swapfile

                log "Swap enabled:"
                swapon --show || true
                free -h || true
                echo

                log "Configuring persistent swap..."
                ensure_swap_fstab_entry

                log "Swap setup complete."
                echo
            fi
        fi
    fi
fi

log "Swap configuration finished."

# ------------------------------------------------------
# [2/7] Colored ls output
# ------------------------------------------------------
log "[2/7] Configuring colored ls output..."
touch "$BASHRC"
if ! bashrc_has_ls_color; then
    echo "alias ls='ls --color=auto'" >> "$BASHRC"
    COLOR_LS="Enabled"
else
    COLOR_LS="Already enabled"
fi

# ------------------------------------------------------
# [3/7] 256-color terminal
# ------------------------------------------------------
log "[3/7] Configuring terminal colors..."
if ! bashrc_has_term_color; then
    echo "export TERM=xterm-256color" >> "$BASHRC"
    TERM_COLOR="Enabled"
else
    TERM_COLOR="Already enabled"
fi

# ------------------------------------------------------
# [4/7] dircolors
# ------------------------------------------------------
log "[4/7] Setting up dircolors..."
if [[ ! -f "$DIRCOLORS" ]]; then
    if command -v dircolors >/dev/null 2>&1; then
        dircolors -p > "$DIRCOLORS"
        DIRCOLOR_FILE="Created"
    else
        DIRCOLOR_FILE="Skipped (dircolors missing)"
    fi
else
    DIRCOLOR_FILE="Exists"
fi

if ! bashrc_has_dircolors_apply; then
    echo 'eval "$(dircolors -b ~/.dircolors)"' >> "$BASHRC"
    DIRCOLOR_APPLY="Enabled"
else
    DIRCOLOR_APPLY="Already enabled"
fi

# ------------------------------------------------------
# [5/7] DNS configuration (Static resolv.conf only)
# ------------------------------------------------------
log "[5/7] Updating DNS configuration based on region..."

if [[ "$REGION" == "China" ]]; then
    NEW_DNS1="223.5.5.5"
    NEW_DNS2="223.6.6.6"
    TEST_DOMAIN="www.baidu.com"
else
    NEW_DNS1="1.1.1.1"
    NEW_DNS2="1.0.0.1"
    TEST_DOMAIN="www.google.com"
fi

DNS_MODE_DESC="Static resolv.conf"
log "Using static resolv.conf mode only."

if dns_already_configured; then
    log "DNS already configured as expected. Skipping resolv.conf rewrite."
else
    safe_chattr_remove_immutable "$RESOLV_FILE"

    if has_systemd; then
        systemctl stop systemd-resolved >/dev/null 2>&1 || true
        systemctl disable systemd-resolved >/dev/null 2>&1 || true
    fi

    if [[ -L "$RESOLV_FILE" ]]; then
        rm -f "$RESOLV_FILE"
    fi

    if [[ -f "$RESOLV_FILE" ]]; then
        cp "$RESOLV_FILE" "${RESOLV_FILE}.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
    fi

    cat > "$RESOLV_FILE" <<EOF
nameserver $NEW_DNS1
nameserver $NEW_DNS2
EOF
fi

sleep 1

log "Testing DNS resolution for $TEST_DOMAIN..."
if command -v nslookup >/dev/null 2>&1; then
    if nslookup "$TEST_DOMAIN" >/dev/null 2>&1; then
        DNS_TEST_RESULT="Success"
    else
        DNS_TEST_RESULT="Failed"
    fi
elif command -v getent >/dev/null 2>&1; then
    if getent hosts "$TEST_DOMAIN" >/dev/null 2>&1; then
        DNS_TEST_RESULT="Success"
    else
        DNS_TEST_RESULT="Failed"
    fi
else
    if ping -c 1 -W 5 "$TEST_DOMAIN" >/dev/null 2>&1; then
        DNS_TEST_RESULT="Success"
    else
        DNS_TEST_RESULT="Failed"
    fi
fi

safe_chattr_add_immutable "$RESOLV_FILE"
log "DNS Test Result: $DNS_TEST_RESULT"

# ------------------------------------------------------
# [6/7] Hostname handling
# ------------------------------------------------------
log "[6/7] Detecting OS version..."

if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS_NAME="$(echo "${ID:-vps}" | tr '[:upper:]' '[:lower:]')"
    OS_VERSION="$(echo "${VERSION_ID:-0}" | cut -d'.' -f1)"
    AUTO_HOSTNAME="${OS_NAME}${OS_VERSION}"
else
    AUTO_HOSTNAME="vps$(date +%Y%m%d)"
fi

CURRENT_HOSTNAME="$(hostname 2>/dev/null || echo unknown)"

echo
echo "Hostname Configuration"
echo "-------------------------------------------------------"
echo "Current hostname : $CURRENT_HOSTNAME"
echo "Suggested hostname: $AUTO_HOSTNAME"
echo

if ask_yes_no "Change hostname to '$AUTO_HOSTNAME'?" "n"; then
    if command -v hostnamectl >/dev/null 2>&1; then
        hostnamectl set-hostname "$AUTO_HOSTNAME" 2>/dev/null || hostname "$AUTO_HOSTNAME"
    else
        hostname "$AUTO_HOSTNAME"
        echo "$AUTO_HOSTNAME" > /etc/hostname
    fi

    HOSTNAME_CHANGED="Yes ($CURRENT_HOSTNAME -> $AUTO_HOSTNAME)"

    safe_chattr_remove_immutable "$HOSTS_FILE"

    if grep -qE '^127\.0\.1\.1\s+' "$HOSTS_FILE" 2>/dev/null; then
        sed -i -E "s/^127\.0\.1\.1\s+.*/127.0.1.1        $AUTO_HOSTNAME/" "$HOSTS_FILE"
    else
        echo "127.0.1.1        $AUTO_HOSTNAME" >> "$HOSTS_FILE"
    fi

    safe_chattr_add_immutable "$HOSTS_FILE"
else
    HOSTNAME_CHANGED="No (kept: $CURRENT_HOSTNAME)"
    log "Hostname unchanged."
fi

# ------------------------------------------------------
# Enable BBR
# ------------------------------------------------------
log "Checking BBR status..."

current_cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "")"
current_qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "")"

if [[ "$current_cc" == "bbr" && "$current_qdisc" == "fq" ]]; then
    log "BBR and FQ are already enabled."
else
    log "Enabling BBR and FQ..."
    sed -i '/^net\.core\.default_qdisc=/d' /etc/sysctl.conf
    sed -i '/^net\.ipv4\.tcp_congestion_control=/d' /etc/sysctl.conf

    {
        echo "net.core.default_qdisc=fq"
        echo "net.ipv4.tcp_congestion_control=bbr"
    } >> /etc/sysctl.conf

    sysctl -p /etc/sysctl.conf >/dev/null 2>&1 || true

    new_cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "")"
    new_qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "")"

    if [[ "$new_cc" == "bbr" && "$new_qdisc" == "fq" ]]; then
        log "BBR and FQ have been successfully enabled."
    else
        warn "Failed to fully enable BBR. Kernel may not support it."
    fi
fi

# ------------------------------------------------------
# Summary
# ------------------------------------------------------
echo
echo "=== Configuration Summary ==="
echo "Region: $REGION"
echo "GitHub Raw Mode: $GITHUB_RAW_MODE"
echo "APT Mirror: $APT_MIRROR_NAME"
echo "  Main: $APT_MIRROR_MAIN"
echo "  Security: $APT_MIRROR_SECURITY"
echo "  Mirror Changed: $APT_MIRROR_CHANGED"
echo "  Force IPv4: $APT_IPV4_FORCED ($APT_IPV4_CONF)"
echo "  APT backup dir: $APT_SOURCES_BACKUP_DIR"
echo "  apt-get update after mirror: $APT_UPDATE_AFTER_MIRROR"
echo "Root SSH login: $ROOT_SSH_LOGIN"
echo "SSH password authentication: $ROOT_PASSWORD_AUTH"
echo "Root password status: $ROOT_PASSWD_STATUS"
echo "Root SSH config changed: $ROOT_SSH_CONFIG_CHANGED"
echo "Root password changed: $ROOT_PASSWD_CHANGED"
echo "Timezone: $TIMEZONE (Changed: $TZ_CHANGED)"
echo "Hostname: $(hostname 2>/dev/null || echo unknown) (Changed: $HOSTNAME_CHANGED)"
echo "DNS Mode: $DNS_MODE_DESC"
echo "  Primary DNS: $NEW_DNS1"
echo "  Secondary DNS: $NEW_DNS2"
echo "  DNS Test: $DNS_TEST_RESULT"
echo "Colored ls: $COLOR_LS"
echo "256-color terminal: $TERM_COLOR"
echo "dircolors: $DIRCOLOR_FILE, Applied: $DIRCOLOR_APPLY"
echo

if ask_yes_no "Reboot now?" "n"; then
    reboot
else
    log "Reboot cancelled."
fi
