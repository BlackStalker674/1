#!/bin/bash
# ===== Модуль 1 — HQ-RTR (пп. 1, 3, 4, 6, 7, 8, 9, 11) =====
# Имя, WAN 172.16.1.2/28, VLAN 100/200/999 на одном порту, GRE-туннель до BR-RTR,
# OSPF (только на tun0, MD5-пароль), NAT, DHCP для VLAN 200, пользователь net_admin.
# ALT Linux (etcnet + FRR + dnsmasq). Запускать от root НА КОНСОЛИ.
#
# MAC-адрес HQ-CLI (чтобы hq-cli всегда получал 192.168.200.2, как в DNS):
#   HQ_CLI_MAC=aa:bb:cc:dd:ee:ff bash 02_HQ-RTR.sh
# (MAC печатает скрипт 06_HQ-CLI.sh; без него DHCP работает, но адрес из пула случайный)
set -eu

# ---------- Переменные (проверьте: ip -br link) ----------
WAN_IF=${WAN_IF:-enp7s1}              # к ISP
LAN_IF=${LAN_IF:-enp7s2}              # один порт на все VLAN (trunk, теги VLAN 100/200/999)
TZ_NAME=${TZ_NAME:-Asia/Krasnoyarsk}
PASS=${PASS:-P@ssw0rd}                # пароль net_admin (по заданию)
OSPF_KEY=${OSPF_KEY:-P@ssw0rd}        # пароль OSPF (MD5, до 16 символов)
HQ_CLI_MAC=${HQ_CLI_MAC:-}
HOST_FQDN=hq-rtr.au-team.irpo
DNS_UP=77.88.8.8

die() { echo "!!! $*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "Запускайте от root"

for i in "$WAN_IF" "$LAN_IF"; do
    ip link show "$i" >/dev/null 2>&1 || die "Нет интерфейса $i (ip -br link). Задайте: WAN_IF=... LAN_IF=... bash $0"
done

echo ">>> Имя"
hostnamectl set-hostname "$HOST_FQDN"

echo ">>> WAN"
D=/etc/net/ifaces/$WAN_IF
mkdir -p "$D"
cat > "$D/options" <<EOF
TYPE=eth
BOOTPROTO=static
CONFIG_IPV4=yes
DISABLED=no
NM_CONTROLLED=no
SYSTEMD_CONTROLLED=no
EOF
echo "172.16.1.2/28"          > "$D/ipv4address"
echo "default via 172.16.1.1" > "$D/ipv4route"
printf 'nameserver %s\n' "$DNS_UP" > "$D/resolv.conf"
printf 'nameserver %s\n' "$DNS_UP" > /etc/resolv.conf

echo ">>> LAN: trunk без адреса + VLAN 100/200/999"
D=/etc/net/ifaces/$LAN_IF
mkdir -p "$D"
cat > "$D/options" <<EOF
TYPE=eth
BOOTPROTO=static
CONFIG_IPV4=no
DISABLED=no
NM_CONTROLLED=no
SYSTEMD_CONTROLLED=no
EOF
rm -f "$D/ipv4address" "$D/ipv4route"
for VID in 100 200 999; do
    V=/etc/net/ifaces/$LAN_IF.$VID
    mkdir -p "$V"
    cat > "$V/options" <<EOF
TYPE=vlan
HOST=$LAN_IF
VID=$VID
BOOTPROTO=static
CONFIG_IPV4=yes
DISABLED=no
EOF
done
echo "192.168.100.1/27" > /etc/net/ifaces/$LAN_IF.100/ipv4address   # VLAN 100: 32 адреса (HQ-SRV)
echo "192.168.200.1/28" > /etc/net/ifaces/$LAN_IF.200/ipv4address   # VLAN 200: 16 адресов (HQ-CLI)
echo "192.168.99.1/29"  > /etc/net/ifaces/$LAN_IF.999/ipv4address   # VLAN 999: 8 адресов (управление)

echo ">>> GRE-туннель tun0 до BR-RTR"
T=/etc/net/ifaces/tun0
mkdir -p "$T"
cat > "$T/options" <<EOF
TYPE=iptun
TUNTYPE=gre
TUNLOCAL=172.16.1.2
TUNREMOTE=172.16.2.2
TUNOPTIONS='ttl 64'
HOST=$WAN_IF
ONBOOT=yes
EOF
echo "10.10.10.1/30" > "$T/ipv4address"

echo ">>> Форвардинг"
SYSCTL=/etc/net/sysctl.conf
touch "$SYSCTL"
if grep -qE '^\s*net\.ipv4\.ip_forward' "$SYSCTL"; then
    sed -i -E 's/^\s*net\.ipv4\.ip_forward.*/net.ipv4.ip_forward = 1/' "$SYSCTL"
else
    echo 'net.ipv4.ip_forward = 1' >> "$SYSCTL"
fi
sysctl -w net.ipv4.ip_forward=1 >/dev/null

modprobe 8021q
modprobe ip_gre
systemctl restart network
sleep 5

echo ">>> Пакеты"
apt-get update
apt-get install -y frr dnsmasq iptables tzdata sudo
timedatectl set-timezone "$TZ_NAME"

echo ">>> NAT (PAT) в сторону ISP"
iptables -t nat -C POSTROUTING -o "$WAN_IF" -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -o "$WAN_IF" -j MASQUERADE
mkdir -p /etc/sysconfig
iptables-save > /etc/sysconfig/iptables
systemctl enable --now iptables

echo ">>> DHCP для VLAN 200 (dnsmasq, DNS-часть отключена)"
cat > /etc/dnsmasq.conf <<EOF
# DHCP для HQ-CLI. Адрес маршрутизатора 192.168.200.1 в пул не входит.
port=0
interface=$LAN_IF.200
bind-dynamic
dhcp-authoritative
dhcp-range=192.168.200.2,192.168.200.14,255.255.255.240,12h
dhcp-option=option:router,192.168.200.1
dhcp-option=option:dns-server,192.168.100.2
dhcp-option=option:domain-name,au-team.irpo
dhcp-option=option:domain-search,au-team.irpo
EOF
if [ -n "$HQ_CLI_MAC" ]; then
    echo "dhcp-host=$HQ_CLI_MAC,192.168.200.2,hq-cli" >> /etc/dnsmasq.conf
else
    echo "ВНИМАНИЕ: HQ_CLI_MAC не задан, hq-cli может получить адрес не 192.168.200.2 (см. шапку скрипта)"
fi
dnsmasq --test
systemctl enable dnsmasq
systemctl restart dnsmasq

echo ">>> OSPF (FRR): только tun0, MD5-аутентификация"
sed -i -E 's/^ospfd=.*/ospfd=yes/' /etc/frr/daemons
systemctl enable frr
systemctl restart frr
sleep 5
vtysh <<EOF
configure terminal
router ospf
 ospf router-id 10.10.10.1
 passive-interface default
 no passive-interface tun0
 network 10.10.10.0/30 area 0
 network 192.168.100.0/27 area 0
 network 192.168.200.0/28 area 0
 network 192.168.99.0/29 area 0
 area 0 authentication message-digest
exit
interface tun0
 ip ospf network point-to-point
 ip ospf authentication message-digest
 ip ospf message-digest-key 1 md5 $OSPF_KEY
exit
end
write memory
EOF

echo ">>> Пользователь net_admin (sudo без пароля)"
id -u net_admin >/dev/null 2>&1 || useradd -m net_admin
echo "net_admin:$PASS" | chpasswd
usermod -aG wheel net_admin
echo "net_admin ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/net_admin
chmod 440 /etc/sudoers.d/net_admin
visudo -cf /etc/sudoers.d/net_admin
# sudo должен читать /etc/sudoers.d
grep -qE '^[#@]includedir[[:space:]]+/etc/sudoers\.d' /etc/sudoers || echo '@includedir /etc/sudoers.d' >> /etc/sudoers
visudo -c >/dev/null

echo ""
echo "===== Проверка ====="
ip -br addr
ip route
ping -c 2 77.88.8.8 || echo "ВНИМАНИЕ: Интернет недоступен (настроен ли ISP?)"
ping -c 2 10.10.10.2 || echo "Туннель: BR-RTR ещё не настроен? Повторите проверку после 03_BR-RTR.sh"
vtysh -c "show ip ospf neighbor" || true
echo "HQ-RTR: модуль 1 готов"
