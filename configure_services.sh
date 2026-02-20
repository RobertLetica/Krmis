#!/bin/bash

# Configuration and Helper Functions

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

pause() {
    read -p "Press [Enter] to continue..."
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        error "Please run as root (sudo)."
        exit 1
    fi
}

validate_ip() {
    local ip=$1
    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        return 0
    else
        return 1
    fi
}

get_input() {
    local prompt="$1"
    local var_name="$2"
    local default="$3"

    local input
    if [ -n "$default" ]; then
        read -p "$prompt [$default]: " input
        input="${input:-$default}"
    else
        read -p "$prompt: " input
    fi
    printf -v "$var_name" "%s" "$input"
}

get_yes_no() {
    local prompt="$1"
    local default="$2" # "y" or "n"
    local choice

    while true; do
        if [ "$default" == "y" ]; then
             read -p "$prompt [Y/n]: " choice
             choice=${choice:-Y}
        else
             read -p "$prompt [y/N]: " choice
             choice=${choice:-N}
        fi

        case "$choice" in
            [Yy]* ) return 0 ;;
            [Nn]* ) return 1 ;;
            * ) echo "Please answer yes or no." ;;
        esac
    done
}

# Service Functions

install_dhcp() {
    echo "--- DHCP Configuration (Kea) ---"

    get_input "Interface name (e.g., ens33)" INTERFACE

    while true; do
        get_input "Server IP (e.g., 172.16.2.10)" SERVER_IP
        if validate_ip "$SERVER_IP"; then break; else error "Invalid IP format."; fi
    done

    get_input "Network address (e.g., 172.16.2.0)" NETWORK
    get_input "Subnet mask (CIDR, e.g., 24)" MASK
    get_input "Pool Start (e.g., 172.16.2.30)" P_START
    get_input "Pool End (e.g., 172.16.2.50)" P_END
    get_input "Gateway IP" GW
    get_input "DNS Server IP" DNS_IP "$SERVER_IP"
    get_input "Lease Time (seconds)" LEASE_TIME "3600"

    warn "This will flush the IP configuration for $INTERFACE and set it to $SERVER_IP/$MASK."
    if get_yes_no "Do you want to proceed?" "y"; then
        log "Configuring interface $INTERFACE..."
        ip addr flush dev "$INTERFACE"
        ip addr add "$SERVER_IP/$MASK" dev "$INTERFACE"
        ip link set "$INTERFACE" up
    else
        log "Skipping interface configuration."
    fi

    log "Installing Kea DHCP Server..."
    apt update && apt install kea-dhcp4-server -y

    log "Generating configuration..."
    cat <<EOF | tee /etc/kea/kea-dhcp4.conf
{
"Dhcp4": {
    "interfaces-config": {
        "interfaces": ["$INTERFACE"]
    },
    "control-socket": {
        "socket-type": "unix",
        "socket-name": "/tmp/kea4-ctrl-socket"
    },
    "lease-database": {
        "type": "memfile",
        "lfc-interval": 3600
    },
    "subnet4": [
        {
            "subnet": "$NETWORK/$MASK",
            "pools": [ { "pool": "$P_START - $P_END" } ],
            "option-data": [
                { "name": "domain-name-servers", "data": "$DNS_IP" },
                { "name": "routers", "data": "$GW" }
            ],
            "valid-lifetime": $LEASE_TIME
        }
    ]
}
}
EOF

    log "Verifying configuration..."
    kea-dhcp4 -t /etc/kea/kea-dhcp4.conf

    log "Restarting service..."
    systemctl restart kea-dhcp4-server
    systemctl enable kea-dhcp4-server

    systemctl is-active kea-dhcp4-server
    pause
}

install_dns() {
    echo "--- DNS Configuration (Bind9) ---"

    get_input "Interface name (e.g., ens33)" INTERFACE
    get_input "Server IP" SERVER_IP
    get_input "Domain Name (e.g., example.com)" DOMAIN

    if get_yes_no "Configure IP address on interface?" "n"; then
        ip addr add "$SERVER_IP/24" dev "$INTERFACE" 2>/dev/null
    fi

    # Calculate reverse zone defaults
    REV_ZONE_DEFAULT=$(echo "$SERVER_IP" | awk -F. '{print $3"."$2"."$1}')
    LAST_OCTET=$(echo "$SERVER_IP" | awk -F. '{print $4}')

    get_input "Reverse Zone Prefix (e.g., 2.16.172)" REV_ZONE "$REV_ZONE_DEFAULT"

    log "Installing Bind9..."
    apt update && apt install bind9 -y

    # Forwarders
    FORWARDERS_BLOCK=""
    if get_yes_no "Do you want to configure forwarders (e.g., 8.8.8.8)?" "n"; then
        get_input "Forwarder IP 1" FWD1 "8.8.8.8"
        get_input "Forwarder IP 2" FWD2 "8.8.4.4"
        FORWARDERS_BLOCK="forwarders { $FWD1; $FWD2; };"
    fi

    log "Configuring named.conf.local..."
    cat <<EOF | tee /etc/bind/named.conf.local
zone "$DOMAIN" IN {
    type master;
    file "/etc/bind/db.$DOMAIN";
};
zone "$REV_ZONE.in-addr.arpa" {
    type master;
    file "/etc/bind/db.$REV_ZONE";
};
EOF

    log "Configuring Forward Zone..."
    cat <<EOF | tee /etc/bind/db.$DOMAIN
\$TTL 604800
@ IN SOA ns.$DOMAIN. admin.$DOMAIN. (
    $(date +%Y%m%d)01 604800 86400 2419200 604800 )
@ IN NS ns.$DOMAIN.
ns IN A $SERVER_IP
@ IN A $SERVER_IP
www IN CNAME @
EOF

    log "Configuring Reverse Zone..."
    cat <<EOF | tee /etc/bind/db.$REV_ZONE
\$TTL 604800
@ IN SOA ns.$DOMAIN. root.ns.$DOMAIN. (
    $(date +%Y%m%d)01 604800 86400 2419200 604800 )
@ IN NS ns.$DOMAIN.
$LAST_OCTET IN PTR ns.$DOMAIN.
EOF

    if [ -n "$FORWARDERS_BLOCK" ]; then
        log "Adding forwarders to named.conf.options..."
        cat <<EOF | tee /etc/bind/named.conf.options
options {
    directory "/var/cache/bind";
    $FORWARDERS_BLOCK
    dnssec-validation auto;
    listen-on-v6 { any; };
};
EOF
    fi

    log "Restarting Bind9..."
    systemctl restart bind9

    if systemctl is-active --quiet bind9; then
        log "DNS Server configured and active."
    else
        error "DNS Server failed to start. Check logs."
    fi
    pause
}

install_ftp() {
    echo "--- FTP Configuration (vsftpd) ---"

    get_input "FTP User" FTP_USER
    read -s -p "FTP Password: " FTP_PASS
    echo ""

    log "Installing vsftpd..."
    apt update && apt install vsftpd -y

    ANON_ENABLE="NO"
    if get_yes_no "Enable Anonymous Access?" "n"; then
        ANON_ENABLE="YES"
    fi

    LOCAL_ROOT="/home/\$USER/ftp"
    if get_yes_no "Use default local root ($LOCAL_ROOT)?" "y"; then
        :
    else
        get_input "Enter custom local root path" CUSTOM_ROOT
        LOCAL_ROOT=$CUSTOM_ROOT
    fi

    log "Configuring vsftpd.conf..."
    cat <<EOF | tee /etc/vsftpd.conf
listen=YES
listen_ipv6=NO
anonymous_enable=$ANON_ENABLE
local_enable=YES
write_enable=YES
chroot_local_user=YES
allow_writeable_chroot=YES
user_sub_token=\$USER
local_root=$LOCAL_ROOT
userlist_enable=YES
userlist_file=/etc/vsftpd.userlist
userlist_deny=NO
EOF

    log "Creating user and directories..."
    if id "$FTP_USER" &>/dev/null; then
        log "User $FTP_USER already exists."
    else
        useradd -m -s /bin/bash "$FTP_USER"
        echo "$FTP_USER:$FTP_PASS" | chpasswd
    fi

    echo "$FTP_USER" | tee -a /etc/vsftpd.userlist

    # Eval the path to handle $USER variable expansion if it's literal in string
    ACTUAL_ROOT_DIR=$(echo "$LOCAL_ROOT" | sed "s/\\\$USER/$FTP_USER/g")

    mkdir -p "$ACTUAL_ROOT_DIR/dupload"
    chown -R "$FTP_USER:$FTP_USER" "$ACTUAL_ROOT_DIR"
    chmod 555 "$ACTUAL_ROOT_DIR"
    chmod 777 "$ACTUAL_ROOT_DIR/dupload"

    log "Restarting vsftpd..."
    systemctl restart vsftpd
    log "FTP service ready."
    pause
}

install_ssh() {
    echo "--- SSH Configuration ---"

    log "Installing OpenSSH Server..."
    apt update && apt install openssh-server -y

    get_input "SSH Port" SSH_PORT "22"

    PERMIT_ROOT="no"
    if get_yes_no "Permit Root Login?" "n"; then
        PERMIT_ROOT="yes"
    fi

    log "Configuring sshd_config..."
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak

    sed -i "s/^#Port 22/Port $SSH_PORT/" /etc/ssh/sshd_config
    sed -i "s/^Port .*/Port $SSH_PORT/" /etc/ssh/sshd_config

    sed -i "s/^#PermitRootLogin .*/PermitRootLogin $PERMIT_ROOT/" /etc/ssh/sshd_config
    sed -i "s/^PermitRootLogin .*/PermitRootLogin $PERMIT_ROOT/" /etc/ssh/sshd_config

    log "Restarting SSH..."
    systemctl restart ssh
    log "SSH active on port $SSH_PORT."
    pause
}

# Main Loop

check_root

while true; do
    clear
    echo "=========================================================="
    echo "    DYNAMIC SERVICE AUTOMATION - LINUX MINT        "
    echo "=========================================================="
    echo "1) DHCP (Kea)"
    echo "2) DNS (Bind9)"
    echo "3) FTP (vsftpd)"
    echo "4) SSH (OpenSSH)"
    echo "5) Exit"
    echo "=========================================================="
    read -p "Select option [1-5]: " option

    case $option in
        1) install_dhcp ;;
        2) install_dns ;;
        3) install_ftp ;;
        4) install_ssh ;;
        5) exit 0 ;;
        *) echo "Invalid option." ;;
    esac
done
