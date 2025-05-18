#!/bin/bash

# Logging setup
LOG_FILE="/var/log/santoi-installer.log"
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
    if ! grep -q "^$1" /usr/share/zoneinfo/iso3166.tab; then
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

# Step 0: Update package list
echo "Updating package list..."
run_command sudo apt update || { echo "Failed to update package list. Exiting."; exit 1; }

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
    python3-gunicorn
    python3-gevent
    nginx
)

# Install packages
echo "Updating package repositories..."
run_command sudo apt update || { echo "Failed to update repositories."; exit 1; }
run_command sudo apt -y -o Dpkg::Options::="--force-confnew" full-upgrade || { echo "Failed to complete full upgrade."; exit 1; }
echo "Installing packages..."
run_command sudo apt install -y "${packages[@]}" || { echo "Failed to install packages. Exiting."; exit 1; }
echo "All packages installed successfully."

# Default settings
DEFAULT_LOCALE="en_US.UTF-8 UTF-8"
DEFAULT_TIMEZONE="UTC"
DEFAULT_WLAN_COUNTRY="US"

# Step 1: Prompt for WLAN Country
echo "Setting WLAN Country..."
echo "-------------------------------------"
echo "Available WLAN Countries:"
cat /usr/share/zoneinfo/iso3166.tab | awk '{print $1}' | grep -E '^[A-Z]{2}$' | less --quit-if-one-screen --no-init --chop-long-lines
echo "-------------------------------------"

# Prompt user for WLAN country selection
wlan_country_choice=$(prompt_and_validate "Enter your WLAN Country choice from the above list: " validate_wlan_country "Invalid WLAN country code.") || wlan_country_choice="$DEFAULT_WLAN_COUNTRY"
run_command sudo raspi-config nonint do_wifi_country "$wlan_country_choice"
echo "WLAN Country set to $wlan_country_choice."

# Step 2: Prompt for WLAN Country again for locale selection
echo "Setting system locale..."
echo "-------------------------------------"
echo "Available WLAN Countries:"
cat /usr/share/zoneinfo/iso3166.tab | awk '{print $1}' | grep -E '^[A-Z]{2}$' | less --quit-if-one-screen --no-init --chop-long-lines
echo "-------------------------------------"

# Prompt user for WLAN country selection again
locale_country_choice=$(prompt_and_validate "Enter your Locale choice from the above list: " validate_wlan_country "Invalid WLAN country code.") || locale_country_choice="$wlan_country_choice"

# Display locales for the selected WLAN country
if ! display_locales_for_wlan_country "$locale_country_choice"; then
    locale_choice="$DEFAULT_LOCALE"
else
    # Step 3: Prompt user for locale selection
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
# Extract the first part of the locale (before the space)
locale_value=$(echo "$locale_choice" | awk '{print $1}')

# Generate and set the locale
echo "Generating and setting locale: $locale_value..."
run_command sudo locale-gen "$locale_value"
run_command sudo update-locale LANG="$locale_value" LC_MESSAGES="$locale_value"
echo "Locale set to $locale_value."

# Step 4: Prompt for Timezone
echo "Setting TimeZone..."
echo "-------------------------------------"
echo "Available TimeZones:"
timedatectl list-timezones | less --quit-if-one-screen --no-init --chop-long-lines
echo "-------------------------------------"

# Prompt user for timezone selection
timezone_choice=$(prompt_and_validate "Enter your choice from the above list: " validate_timezone "Invalid timezone.") || timezone_choice="$DEFAULT_TIMEZONE"
run_command sudo timedatectl set-timezone "$timezone_choice"
echo "TimeZone set to $timezone_choice."

# Enable IPv4 and IPv6 forwarding
echo "Enabling IP forwarding temporarily..."
run_command sudo sysctl -w net.ipv4.ip_forward=1
run_command sudo sysctl -w net.ipv6.conf.all.forwarding=1
echo "IPv4 and IPv6 forwarding enabled temporarily."

# Persist IP forwarding in /etc/sysctl.conf
echo "Updating /etc/sysctl.conf for persistent IP forwarding..."
run_command sudo sed -i 's/#\(net.ipv4.ip_forward=1\)/\1/' /etc/sysctl.conf
run_command sudo sed -i 's/#\(net.ipv6.conf.all.forwarding=1\)/\1/' /etc/sysctl.conf

# Verify changes
echo "Verifying changes in /etc/sysctl.conf..."
grep -E "net.ipv4.ip_forward|net.ipv6.conf.all.forwarding" /etc/sysctl.conf

# Update /boot/firmware/config.txt
echo "Updating /boot/firmware/config.txt to enable USB max current..."
run_command sudo sed -i '/^\[all\]/a usb_max_current_enable=1' /boot/firmware/config.txt

# Verify the addition
echo "Verifying /boot/firmware/config.txt changes..."
grep -A 1 "^\[all\]" /boot/firmware/config.txt
echo "Basic system configuration complete!"

# Manage NetworkManager and systemd-networkd
echo "Configuring network services..."
if dpkg -l | grep -q "network-manager"; then
    echo "Network Manager is installed. Removing it..."
    run_command sudo systemctl disable NetworkManager || { echo "Failed to disable NetworkManager. Exiting."; exit 1; }
    run_command sudo systemctl stop NetworkManager || { echo "Failed to stop NetworkManager. Exiting."; exit 1; }
    run_command sudo apt-get purge -y network-manager
    run_command sudo apt-get autoremove -y
    echo "Network Manager has been removed."
else
    echo "Network Manager is not installed. Skipping removal."
fi
run_command sudo systemctl enable systemd-networkd || { echo "Failed to enable systemd-networkd. Exiting."; exit 1; }
run_command sudo systemctl start systemd-networkd || { echo "Failed to start systemd-networkd. Exiting."; exit 1; }
echo "Network services configured successfully."

# Prompt user for Santoi package extraction
echo "-------------------------------------"
echo "Santoi Package Extraction"
echo "-------------------------------------"
read -p "Enter the folder location of the Santoi package: " folder_location
read -p "Enter the name of the Santoi package file (e.g., santoi.tar.gz): " package_name

if [ -f "$folder_location/$package_name" ]; then
    echo "Extracting $package_name to / ..."
    run_command sudo tar xvfz "$folder_location/$package_name" -C /
    echo "Package extracted successfully."

    # Execute the Python script to generate the secret key
    echo "Generating secret key using /etc/santoi/utils/create_secret.py..."
    secret_key=$(python3 /etc/santoi/utils/create_secret.py)
    if [ -z "$secret_key" ]; then
        echo "Error: Failed to generate secret key. Exiting."
        exit 1
    fi
    echo "Generated secret key: $secret_key"

    # Update the SECRET_KEY in santoi-flask.service
    SERVICE_FILE="/etc/systemd/system/santoi-flask.service"
    if [ ! -f "$SERVICE_FILE" ]; then
        echo "Error: $SERVICE_FILE not found. Exiting."
        exit 1
    fi
    echo "Updating $SERVICE_FILE with the new secret key..."
    run_command sudo sed -i "s/Environment=\"SECRET_KEY=.*\"/Environment=\"SECRET_KEY=$secret_key\"/" "$SERVICE_FILE"
    echo "Updated SECRET_KEY in $SERVICE_FILE."
else
    echo "Error: Package file not found at $folder_location/$package_name."
    exit 1
fi

# Update /etc/hostapd.conf with the selected WLAN country code
HOSTAPD_CONF="/etc/hostapd/hostapd.conf"
if [ -f "$HOSTAPD_CONF" ]; then
    echo "Updating /etc/hostapd/hostapd.conf with WLAN country code: $wlan_country_choice..."
    run_command sudo sed -i "s/^country_code=.*/country_code=$wlan_country_choice/" "$HOSTAPD_CONF"
    echo "Updated country_code in /etc/hostapd/hostapd.conf."
else
    echo "Warning: /etc/hostapd/hostapd.conf not found. Skipping update."
fi

# Prompt user for AdBlock installation
read -p "Would you like to install AdBlock? (y/n): " install_adblock
if [[ "$install_adblock" =~ ^[Yy]$ ]]; then
    echo "Installing AdBlock..."

    # Create dnsmasq adblock configuration
    run_command sudo bash -c 'echo "addn-hosts=/etc/adblock.list" > /etc/dnsmasq.d/adblock.conf'
    echo "Created /etc/dnsmasq.d/adblock.conf."

    # Create an empty adblock list file
    run_command sudo touch /etc/adblock.list
    echo "Created empty /etc/adblock.list."

    run_command sudo /etc/santoi/utils/update-dnsmasq-blocklist.sh
    echo "Updating Ad Block list."
    
    # Add crontab entries for root
    run_command sudo bash -c 'echo "0 0 * * * /etc/santoi/utils/update-dnsmasq-blocklist.sh" >> /tmp/root_cron'
    run_command sudo bash -c 'echo "55 11 * * * /etc/santoi/utils/cleanjournal.sh" >> /tmp/root_cron'
    run_command sudo bash -c 'echo "00 06 * * * root apt update && apt -y -o Dpkg::Options::=\"--force-confold\" full-upgrade && apt -y autoremove --purge && apt autoclean && apt clean" >> /tmp/root_cron'
    run_command sudo crontab -u root /tmp/root_cron
    run_command sudo rm /tmp/root_cron
    echo "Crontab entries added for AdBlock updates and log cleaning."

    # Restart dnsmasq to apply changes
    run_command sudo systemctl restart dnsmasq
    echo "Dnsmasq restarted to apply AdBlock settings."
fi

# Reload systemd and enable services
run_command sudo systemctl daemon-reload
run_command sudo systemctl unmask hostapd
run_command sudo systemctl enable dnsmasq hostapd systemd-networkd
run_command sudo systemctl enable santoi-flask santoi-go santoi-nginx

# Unblocking Wi-Fi
echo "Unblocking Wi-Fi..."
run_command sudo rfkill unblock wifi
echo "Wi-Fi unblocked successfully."

# Prompt user for system reboot
echo "-------------------------------------"
echo "System Reboot"
echo "After reboot, please reconnect to WLAN SSID, SANTOI RP4. Default password is santoi!@#"
echo "To continue setup your router and vpn service, follow the user guide and go to http://192.168.3.1"
echo "-------------------------------------"
read -p "Do you want to reboot the system now? (yes/no): " reboot_choice

if [[ "$reboot_choice" =~ ^[Yy]([Ee][Ss])?$ ]]; then
    echo "Rebooting the system..."
    run_command sudo reboot
else
    echo "Reboot skipped. Please reboot manually later if needed."
fi

# Summary of changes
echo "-------------------------------------"
echo "Summary of Changes:"
echo "1. WLAN Country set to: $wlan_country_choice"
echo "2. Locale set to: $locale_value"
echo "3. Timezone set to: $timezone_choice"
echo "4. Packages installed: ${packages[*]}"
echo "5. SECRET_KEY updated in $SERVICE_FILE"
echo "6. Updated country_code in /etc/hostapd.conf"
echo "7. AD Block service in /etc/dnsmasq.d/adblock.conf"
echo "-------------------------------------"
