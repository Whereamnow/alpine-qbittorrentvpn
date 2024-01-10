#!/usr/bin/with-contenv bash
# shellcheck shell=bash

# shellcheck disable=SC1091
source /helper/functions.sh

##########
# Skip - Only needed if VPN is enabled

if [[ $VPN_ENABLED == "no" ]]; then
    exit 0
fi

##########
# nft rules

# Mark outgoing packets belonging to a WebUI connection (for routing and firewall)
nft "add table inet qbt-mark"
nft "add chain inet qbt-mark prerouting { type filter hook prerouting priority -150 ; }"
nft "add chain inet qbt-mark output { type route hook output priority -150 ; }"
nft "add rule inet qbt-mark prerouting tcp dport 8080 ct state new ct mark set 9090 counter comment \"Track new WebUI connections\""
nft "add rule inet qbt-mark output ct mark 9090 meta mark set 8080 counter comment \"Add mark to outgoing packets belonging to a WebUI connection\""

# Route WebUI traffic over "$DEFAULT_IPV4_GATEWAY"
mkdir -p /etc/iproute2/
echo "8080 webui" >> /etc/iproute2/rt_tables
if [ -n "$DEFAULT_IPV4_GATEWAY" ]; then
	# Default
	ip rule add fwmark 8080 table webui 
	ip route add default via "$DEFAULT_IPV4_GATEWAY" table webui
	# Look for local networks first
	ip rule add fwmark 8080 table main suppress_prefixlength 1
fi
if [ -n "$DEFAULT_IPV6_GATEWAY" ]; then
	# Default
	ip -6 rule add fwmark 8080 table webui 
	ip -6 route add default via "$DEFAULT_IPV6_GATEWAY" table webui
	# Look for local networks first
	ip -6 rule add fwmark 8080 table main suppress_prefixlength 1
fi

# Add firewall table
nft add table inet firewall

# Create the sets for storing the IPv4 and IPv6 addresses
nft "add set inet firewall vpn_ipv4 { type ipv4_addr ; }"
nft "add set inet firewall vpn_ipv6 { type ipv6_addr ; }"

# Add each IP address to its respective set
for address in "${VPN_REMOTE_IPv4_ADDRESSES[@]}"; do
	nft "add element inet firewall vpn_ipv4 { $address }"
done

for address in "${VPN_REMOTE_IPv6_ADDRESSES[@]}"; do
	nft "add element inet firewall vpn_ipv6 { $address }"
done


# Add chains to the table
nft "add chain inet firewall input { type filter hook input priority 0 ; policy drop ; }"
nft "add chain inet firewall output { type filter hook postrouting priority 0 ; policy drop ; }"


## Input

nft "add rule inet firewall input iifname $VPN_DEVICE_TYPE accept comment \"Accept input from VPN tunnel\""
nft "add rule inet firewall input iifname $DOCKER_INTERFACE $VPN_PROTOCOL sport $VPN_PORT ip saddr @vpn_ipv4 accept comment \"Accept input from VPN server \(IPv4\)\""
nft "add rule inet firewall input iifname $DOCKER_INTERFACE $VPN_PROTOCOL sport $VPN_PORT ip6 saddr @vpn_ipv6 accept comment \"Accept input from VPN server \(IPv6\)\""
nft "add rule inet firewall input iifname lo accept comment \"Accept input from internal loopback\""

# Support deprecated LAN_NETWORK env var
if [ -z "$WEBUI_ALLOWED_NETWORKS" ]; then
	WEBUI_ALLOWED_NETWORKS=$LAN_NETWORK
fi

# Input to WebUI
if [ -z "$WEBUI_ALLOWED_NETWORKS" ]; then
	nft "add rule inet firewall input tcp dport 8080 counter accept comment \"Accept input to the qBt WebUI\""
else
	nft "add set inet firewall webui_allowed_networks_ipv4 { type ipv4_addr; flags interval ; }"
	nft "add set inet firewall webui_allowed_networks_ipv6 { type ipv6_addr; flags interval ; }"

	# Split comma separated string into list from WEBUI_ALLOWED_NETWORKS env variable
	IFS=',' read -ra allowed_networks_array <<< "$WEBUI_ALLOWED_NETWORKS"

	for address in "${allowed_networks_array[@]}"; do
		# Remove whitepaces (for ipcalc)
		address="$(sed -e 's/\s//g' <<< "$address")"

		if ipcalc -c -4 "$address"; then
			nft "add element inet firewall webui_allowed_networks_ipv4 { $address }"
		elif ipcalc -c -6 "$address"; then
			nft "add element inet firewall webui_allowed_networks_ipv6 { $address }"
		fi
	done

	nft "add rule inet firewall input tcp dport 8080 ip saddr @webui_allowed_networks_ipv4 counter accept comment \"Accept input to the qBt WebUI \(IPv4\)\""
	nft "add rule inet firewall input tcp dport 8080 ip6 saddr @webui_allowed_networks_ipv6 counter accept comment \"Accept input to the qBt WebUI \(IPv6\)\""
fi

# Additional port list for scripts or container linking
if [[ -n "$ADDITIONAL_PORTS" ]]; then
	IFS=',' read -ra additional_port_list <<< "$ADDITIONAL_PORTS"

	for additional_port_item in "${additional_port_list[@]}"; do
		additional_port_item=$(echo "$additional_port_item" | sed -e 's~^[ \t]*~~;s~[ \t]*$~~')
		echo "$(date +'%Y-%m-%d %H:%M:%S') [INFO] Adding additional incoming port $additional_port_item for $DOCKER_INTERFACE"
		nft "add rule inet firewall input tcp dport $additional_port_item accept comment \"Accept input to additional port\""
	done
fi

## Output

nft "add rule inet firewall output oifname $VPN_DEVICE_TYPE accept comment \"Accept output to VPN tunnel\""
nft "add rule inet firewall output oifname $DOCKER_INTERFACE $VPN_PROTOCOL dport $VPN_PORT ip daddr @vpn_ipv4 accept comment \"Accept output to VPN server \(IPv4\)\""
nft "add rule inet firewall output oifname $DOCKER_INTERFACE $VPN_PROTOCOL dport $VPN_PORT ip6 daddr @vpn_ipv6 accept comment \"Accept output to VPN server \(IPv6\)\""
nft "add rule inet firewall output tcp sport 8080 meta mark 8080 counter accept comment \"Accept outgoing packets belonging to a WebUI connection\""
nft "add rule inet firewall output iifname lo accept comment \"Accept output to internal loopback\""

# Additional port list for scripts or container linking
if [[ -n "$ADDITIONAL_PORTS" ]]; then
	IFS=',' read -ra additional_port_list <<< "$ADDITIONAL_PORTS"

	for additional_port_item in "${additional_port_list[@]}"; do
		additional_port_item=$(echo "$additional_port_item" | sed -e 's~^[ \t]*~~;s~[ \t]*$~~')
		echo "$(date +'%Y-%m-%d %H:%M:%S') [INFO] Adding additional outgoing port $additional_port_item for $DOCKER_INTERFACE"
		nft "add rule inet firewall output oifname $DOCKER_INTERFACE tcp sport $additional_port_item accept comment \"Accept output from additional port\""
	done
fi

if [[ "$DEBUG" == "yes" ]]; then
	echo "$(date +'%Y-%m-%d %H:%M:%S') [DEBUG] 'main' routing table defined as follows..."
	echo "--------------------"
	ip route show table main
	echo "--------------------"
	echo "$(date +'%Y-%m-%d %H:%M:%S') [DEBUG] ip rules defined as follows..."
	echo "--------------------"
	ip rule
	echo "--------------------"
	echo "$(date +'%Y-%m-%d %H:%M:%S') [DEBUG] nft ruleset defined as follows..."
	echo "--------------------"
	nft list ruleset
	echo "--------------------"

    test_connection
fi

##########
# Save envirnonment variables

CONT_INIT_ENV="/var/run/s6/container_environment"
mkdir -p $CONT_INIT_ENV
export_vars=("DOCKER_INTERFACE")

for name in "${export_vars[@]}"; do
	echo -n "${!name}" > "$CONT_INIT_ENV/$name"
done
