#!/bin/bash

# santoi-installer-trixie.sh
# Revised installer for Raspberry Pi OS Trixie with enhanced checks and splash screen

#set -e

# Function to generate a random ANSI color
random_color() {
    echo -e "\033[1;$(($RANDOM % 7 + 31))m"
}

reset_color="\033[0m"

# Colored Santoi Logo Splash
print_santoi_logo() {
    show_splash
    echo -e "\033[0m" # Reset color
    echo "Santoi Network Installer for Raspberry Pi OS Trixie"
    echo "==================================================="
    echo
}

# Function to show splash screen
show_splash() {
    echo -e "$(random_color)  _____                          ______          _   "
    echo -e "$(random_color) / ____|                        |  ____|        | |  "
    echo -e "$(random_color)| (___   ___ _ __ _ __ ___  _ __| |__ __ _ _ __ | |_ "
    echo -e "$(random_color) \___ \ / __| '__| '__/ _ \| '__|  __/ _\` | '_ \| __|"
    echo -e "$(random_color) ____) | (__| |  | | | (_) | |  | | | (_| | | | | |_ "
    echo -e "$(random_color)|_____/ \___|_|  |_|  \___/|_|  |_|  \__,_|_| |_|\__|"
    echo -e "$(random_color)                  Build Script                       "
    echo -e "$reset_color"
}

# Display splash screen
print_santoi_logo

# santoi-installer-trixie.sh
# Revised installer for Raspberry Pi OS Trixie

# Logging setup
LOG_FILE="/var/log/santoi-installer-trixie.log"
exec > >(tee -a "$LOG_FILE") 2>&1
echo "Logging started at $(date)" >> "$LOG_FILE"

# Dry run mode
DRY_RUN=false
if [[ "$1" == "--dry-run" ]]; then
    DRY_RUN=true
    echo "Dry run mode enabled. No changes will be made."
fi

# Help menu
show_help() {
    echo "Usage: $0 [--dry-run] [--help]"
    echo "  --dry-run  Simulate the script's actions without making changes."
    echo "  --help     Show this help message."
    exit 0
}

if [[ "$1" == "--help" ]]; then
    show_help
fi

# Function to run commands with dry run support
run_command() {
    if $DRY_RUN; then
        echo "[DRY RUN] Command: $*"
    else
        echo "Running: $*"
        "$@"
    fi
}

# Function to display locales for a specific WLAN country
display_locales_for_wlan_country() {
    local wlan_country=$1

    echo "Fetching available locales and encodings for WLAN country: $wlan_country..."
    
    # Load country code to name mapping from iso3166.tab
    declare -A country_names
    while IFS=$'\t' read -r code name; do
        country_names["$code"]="$name"
    done < /usr/share/zoneinfo/iso3166.tab

    # Get the full country name or default to the code if not found
    country_name="${country_names[$wlan_country]:-$wlan_country}"

    # Extract locales for the specified WLAN country
    locales_for_country=$(grep -i "^[a-z]\{2\}_$wlan_country" /usr/share/i18n/SUPPORTED | sort)

    if [ -z "$locales_for_country" ]; then
        echo "No locales found for WLAN country: $country_name."
        echo "Falling back to default locale: $DEFAULT_LOCALE."
        return 1
    fi

    # Display locales for the country
    echo "========================================="
    echo "Country: $country_name"
    echo "========================================="
    echo "$locales_for_country" | sed 's/^/  /'
    echo
}

# Function to validate locale
validate_locale() {
    if ! grep -q "^$1$" /usr/share/i18n/SUPPORTED; then
        echo "Error: Invalid locale '$1'. Please choose from the list above."
        return 1
    fi
    return 0
}

# Function to validate timezone
validate_timezone() {
    if ! timedatectl list-timezones | grep -q "^$1$"; then
        echo "Error: Invalid timezone '$1'. Please choose from the list above."
        return 1
    fi
    return 0
}

# Function to validate WLAN country code
validate_wlan_country() {
    if ! grep -q "^$1[[:space:]]" /usr/share/zoneinfo/iso3166.tab; then
        echo "Error: Invalid WLAN country code '$1'. Please choose from the list above."
        return 1
    fi
    return 0
}

# Function to prompt and validate user input
prompt_and_validate() {
    local prompt=$1
    local validation_func=$2
    local error_message=$3
    local choice

    read -p "$prompt" choice
    if [ -n "$choice" ]; then
        $validation_func "$choice" || { echo "$error_message"; return 1; }
        echo "$choice"
    else
        echo "Invalid choice. Setup skipped."
        return 1
    fi
}

# Step 0: Update package list and upgrade
echo "Updating package list..."
run_command sudo apt update || { echo "Failed to update package list. Exiting."; exit 1; }
run_command sudo apt -y -o Dpkg::Options::="--force-confnew" full-upgrade || { echo "Failed to complete full upgrade."; exit 1; }

# List of packages to install
packages=(
    openvpn
    wireguard
    hostapd
    dnsmasq
    dnsutils
    dhcpcd
    iptables
    resolvconf
    python3-flask
    python3-gunicorn
    python3-gevent
    nginx
)

# Install packages
echo "Installing packages..."
run_command sudo apt install -y "${packages[@]}" || { echo "Failed to install packages. Exiting."; exit 1; }
echo "All packages installed successfully."

# Default settings
DEFAULT_LOCALE="en_US.UTF-8 UTF-8"
DEFAULT_TIMEZONE="UTC"
DEFAULT_WLAN_COUNTRY="US"

# Step 1: WLAN country
echo "Setting WLAN Country..."
cat /usr/share/zoneinfo/iso3166.tab | awk '{print $1}' | grep -E '^[A-Z]{2}$' | less --quit-if-one-screen --no-init --chop-long-lines
wlan_country_choice=$(prompt_and_validate "Enter your WLAN Country choice from the above list: " validate_wlan_country "Invalid WLAN country code.") || wlan_country_choice="$DEFAULT_WLAN_COUNTRY"
run_command sudo raspi-config nonint do_wifi_country "$wlan_country_choice"
echo "WLAN Country set to $wlan_country_choice."

# Step 2: System locale
# Step 2: Prompt for WLAN Country again for locale selection
echo "Setting system locale..."
echo "-------------------------------------"
echo "Available WLAN Countries:"
cat /usr/share/zoneinfo/iso3166.tab | awk '{print $1}' | grep -E '^[A-Z]{2}$' | less --quit-if-one-screen --no-init --chop-long-lines
echo "-------------------------------------"
    
# Prompt user for WLAN country selection again
locale_country_choice=$(prompt_and_validate "Enter your Locale choice from the above list: " validate_wlan_country "Invalid WLAN country code.") || locale_country_choice="$wlan_country_choice"

if ! display_locales_for_wlan_country "$locale_country_choice"; then
    locale_choice="$DEFAULT_LOCALE"
else
    while true; do
        read -p "Enter your choice from the above list: " locale_choice
        if validate_locale "$locale_choice"; then
            break
        else
            echo "Invalid locale. Please try again."
        fi
    done
fi

run_command sudo sed -i "/^# \($locale_choice\)$/s/^# //" /etc/locale.gen
locale_value=$(echo "$locale_choice" | awk '{print $1}')
echo "Generating and setting locale: $locale_value..."
run_command sudo locale-gen "$locale_value"
run_command sudo update-locale LANG="$locale_value" LC_MESSAGES="$locale_value"
echo "Locale set to $locale_value."

# Step 3: Timezone
timedatectl list-timezones | less --quit-if-one-screen --no-init --chop-long-lines
timezone_choice=$(prompt_and_validate "Enter your choice from the above list: " validate_timezone "Invalid timezone.") || timezone_choice="$DEFAULT_TIMEZONE"
run_command sudo timedatectl set-timezone "$timezone_choice"
echo "TimeZone set to $timezone_choice."

# Step 4: IP forwarding (runtime + persistent)
echo "Enabling IP forwarding..."
run_command sudo sysctl -w net.ipv4.ip_forward=1
echo "Persisting IP forwarding..."
cat <<EOF | sudo tee /etc/sysctl.d/99-forwarding.conf
net.ipv4.ip_forward=1
EOF
run_command sudo sysctl --system
echo "IP forwarding enabled and persisted."

# Step 5: Switch to iptables-legacy
echo "Switching iptables and ip6tables to legacy mode..."
run_command sudo update-alternatives --set iptables /usr/sbin/iptables-legacy
run_command sudo update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy
echo "iptables-legacy and ip6tables-legacy set."

# Step 6: USB max current
run_command sudo sed -i '/^\[all\]/a usb_max_current_enable=1' /boot/firmware/config.txt
grep -A1 "^\[all\]" /boot/firmware/config.txt

# Step 7: NetworkManager removal & systemd-networkd enable
if dpkg -l | grep -q "network-manager"; then
    run_command sudo systemctl disable NetworkManager
    run_command sudo systemctl stop NetworkManager
    run_command sudo apt-get purge -y network-manager
    run_command sudo apt-get autoremove -y
fi
run_command sudo systemctl enable systemd-networkd
run_command sudo systemctl start systemd-networkd

# Step 8: Santoi package extraction
read -p "Enter the folder location of the Santoi package: " folder_location
read -p "Enter the name of the Santoi package file (e.g., santoi.tar.gz): " package_name

if [ -f "$folder_location/$package_name" ]; then
    run_command sudo tar xvfz "$folder_location/$package_name" -C /
    secret_key=$(python3 /etc/santoi/utils/create_secret.py)
    SERVICE_FILE="/etc/systemd/system/santoi-flask.service"
    run_command sudo sed -i "s/Environment=\"SECRET_KEY=.*\"/Environment=\"SECRET_KEY=$secret_key\"/" "$SERVICE_FILE"
fi

# Step 9: Update hostapd country code
HOSTAPD_CONF="/etc/hostapd/hostapd.conf"
if [ -f "$HOSTAPD_CONF" ]; then
    run_command sudo sed -i "s/^country_code=.*/country_code=$wlan_country_choice/" "$HOSTAPD_CONF"
fi

# Step 10: AdBlock setup
read -p "Would you like to install AdBlock? (y/n): " install_adblock
if [[ "$install_adblock" =~ ^[Yy]$ ]]; then
    run_command sudo bash -c 'echo "addn-hosts=/etc/adblock.list" > /etc/dnsmasq.d/adblock.conf'
    run_command sudo touch /etc/adblock.list
    run_command sudo /etc/santoi/utils/update-dnsmasq-blocklist.sh
    run_command sudo bash -c 'echo "0 0 * * * /etc/santoi/utils/update-dnsmasq-blocklist.sh" >> /tmp/root_cron'
    run_command sudo bash -c 'echo "55 11 * * * /etc/santoi/utils/cleanjournal.sh" >> /tmp/root_cron'
    run_command sudo bash -c 'echo "00 06 * * * apt update && apt -y -o Dpkg::Options::="--force-confold" full-upgrade && apt -y autoremove --purge && apt autoclean && apt clean" >> /tmp/root_cron'
    run_command sudo crontab -u root /tmp/root_cron
    run_command sudo rm /tmp/root_cron
    run_command sudo systemctl restart dnsmasq
fi

# Step 11: Systemd service setup
run_command sudo systemctl daemon-reload
run_command sudo systemctl unmask hostapd
run_command sudo systemctl enable dnsmasq hostapd systemd-networkd
run_command sudo systemctl enable santoi-flask santoi-go santoi-nginx

# Step 12: Disable LightDM for headless setup
echo "Disabling LightDM display manager..."
run_command sudo systemctl disable lightdm
run_command sudo systemctl stop lightdm

# Step 13: Unblock Wi-Fi
run_command sudo rfkill unblock wifi

# Step 14: Logging optimizer
if [ -f "/etc/santoi/utils/logging_optimizer.sh" ]; then
    run_command bash /etc/santoi/utils/logging_optimizer.sh
fi

# Step 15: Prompt reboot
read -p "Do you want to reboot the system now? (yes/no): " reboot_choice
if [[ "$reboot_choice" =~ ^[Yy]([Ee][Ss])?$ ]]; then
    run_command sudo reboot
fi

echo "-------------------------------------"
echo "Setup complete!"
echo "WLAN Country: $wlan_country_choice"
echo "Locale: $locale_value"
echo "Timezone: $timezone_choice"
echo "Packages installed: ${packages[*]}"
echo "SECRET_KEY updated in $SERVICE_FILE"
echo "Hostapd country_code updated"
echo "LightDM disabled for headless setup"
echo "-------------------------------------"

