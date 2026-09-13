#!/bin/sh
# Reverse tethering for the Inferno iPhone VM (guide: Post-Setup > Reverse Tethering, iptables method).
# The uplink is whatever interface holds the default route (its name differs between machines).
S=$(ip route show default | awk '{print $5; exit}')
D=$(ip -o link | awk -F": " "/de:ad:be:ef:/ {print \$2; exit}")
[ -n "$D" ] && [ -n "$S" ] || exit 0
ip link set "$D" up
ip addr replace 192.168.178.1/24 dev "$D"
iptables -t nat -C POSTROUTING -o "$S" -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -o "$S" -j MASQUERADE
iptables -C FORWARD -i "$D" -o "$S" -j ACCEPT 2>/dev/null || iptables -A FORWARD -i "$D" -o "$S" -j ACCEPT
iptables -C FORWARD -i "$S" -o "$D" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || iptables -A FORWARD -i "$S" -o "$D" -m state --state RELATED,ESTABLISHED -j ACCEPT
systemctl restart dnsmasq
