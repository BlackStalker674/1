#!/bin/bash
# ===== Модуль 1 — BR-RTR (пп. 1, 3, 6, 7, 8, 11) =====
# Имя, WAN 172.16.2.2/28, LAN 192.168.0.1/28 (к BR-SRV), GRE-туннель до HQ-RTR,
# OSPF (только на tun0, MD5-пароль), NAT, пользователь net_admin.
# ALT Linux (etcnet + FRR). Запускать от root НА КОНСОЛИ.
set -eu

# ---------- Переменные (проверьте: ip -br link) ----------
WAN_IF=${WAN_IF:-enp7s1}              # к ISP
LAN_IF=${LAN_IF:-enp7s2}              # к BR-SRV
TZ_NAME=${TZ_NAME:-Asia/Krasnoyarsk}
PASS=${PASS:-P@ssw0rd}                # пароль net_admin (по заданию)
OSPF_KEY=${OSPF_KEY:-P@ssw0rd}        # пароль OSPF (должен совпасть с HQ-RTR)
HOST_FQDN=br-rtr.au-team.irpo
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
echo "172.16.2.2/28"          > "$D/ipv4address"
echo "default via 172.16.2.1" > "$D/ipv4route"
printf 'nameserver %s\n' "$DNS_UP" > "$D/resolv.conf"
printf 'nameserver %s\n' "$DNS_UP" > /etc/resolv.conf

echo ">>> LAN (BR-Net, 16 адресов)"
D=/etc/net/ifaces/$LAN_IF
mkdir -p "$D"
cat > "$D/options" <<EOF
TYPE=eth
BOOTPROTO=static
CONFIG_IPV4=yes
DISABLED=no
NM_CONTROLLED=no
SYSTEMD_CONTROLLED=no
EOF
echo "192.168.0.1/28" > "$D/ipv4address"
rm -f "$D/ipv4route"

echo ">>> GRE-туннель tun0 до HQ-RTR"
T=/etc/net/ifaces/tun0
mkdir -p "$T"
cat > "$T/options" <<EOF
TYPE=iptun
TUNTYPE=gre
TUNLOCAL=172.16.2.2
TUNREMOTE=172.16.1.2
TUNOPTIONS='ttl 64'
HOST=$WAN_IF
ONBOOT=yes
EOF
echo "10.10.10.2/30" > "$T/ipv4address"

echo ">>> Форвардинг"
SYSCTL=/etc/net/sysctl.conf
touch "$SYSCTL"
if grep -qE '^\s*net\.ipv4\.ip_forward' "$SYSCTL"; then
    sed -i -E 's/^\s*net\.ipv4\.ip_forward.*/net.ipv4.ip_forward = 1/' "$SYSCTL"
else
    echo 'net.ipv4.ip_forward = 1' >> "$SYSCTL"
fi
sysctl -w net.ipv4.ip_forward=1 >/dev/null

modprobe ip_gre
systemctl restart network
sleep 5

echo ">>> Пакеты"
apt-get update
apt-get install -y frr iptables tzdata sudo
timedatectl set-timezone "$TZ_NAME"

echo ">>> NAT (PAT) в сторону ISP"
iptables -t nat -C POSTROUTING -o "$WAN_IF" -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -o "$WAN_IF" -j MASQUERADE
mkdir -p /etc/sysconfig
iptables-save > /etc/sysconfig/iptables
systemctl enable --now iptables

echo ">>> OSPF (FRR): только tun0, MD5-аутентификация"
sed -i -E 's/^ospfd=.*/ospfd=yes/' /etc/frr/daemons
systemctl enable frr
systemctl restart frr
sleep 5
vtysh <<EOF
configure terminal
router ospf
 ospf router-id 10.10.10.2
 passive-interface default
 no passive-interface tun0
 network 10.10.10.0/30 area 0
 network 192.168.0.0/28 area 0
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
ping -c 2 10.10.10.1 || echo "Туннель: HQ-RTR ещё не настроен?"
vtysh -c "show ip ospf neighbor" || true
echo "BR-RTR: модуль 1 готов"
