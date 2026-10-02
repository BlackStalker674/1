#!/bin/bash
# ===== Модуль 1 — HQ-RTR =====
# hostname, VLAN 100/200/999, форвардинг, GRE-туннель, OSPF, DHCP, NAT, net_admin + SSH:2027
# Предварительно: адрес 172.16.1.2/28 на enp7s1, шлюз 172.16.1.1, nameserver 77.88.8.8
# Источник: HQ-RTR.sh, 1.sh, sshrout.sh

WAN_IF=enp7s1   # в сторону ISP
LAN_IF=enp7s2   # trunk в сторону HQ-SW

hostnamectl set-hostname hq-rtr.au-team.irpo
apt-get update && apt-get install -y chrony tzdata dnsmasq frr iptables shadow-groups
timedatectl set-timezone Asia/Krasnoyarsk

# --- Физический LAN-интерфейс (без адреса, работает в trunk)
mkdir -p /etc/net/ifaces/"$LAN_IF"
cat > /etc/net/ifaces/"$LAN_IF"/options <<EOF
BOOTPROTO=static
TYPE=eth
CONFIG_WIRELESS=no
SYSTEMD_BOOTPROTO=dhcp4
CONFIG_IPV4=no
DISABLED=no
NM_CONTROLLED=no
SYSTEMD_CONTROLLED=no
EOF

# --- VLAN
for VID in 100 200 999; do
  mkdir -p /etc/net/ifaces/"$LAN_IF"."$VID"
  cat > /etc/net/ifaces/"$LAN_IF"."$VID"/options <<EOF
TYPE=vlan
HOST=$LAN_IF
VID=$VID
BOOTPROTO=static
EOF
done
echo "192.168.100.1/27" > /etc/net/ifaces/"$LAN_IF".100/ipv4address
echo "192.168.200.1/28" > /etc/net/ifaces/"$LAN_IF".200/ipv4address
echo "192.168.99.1/29"  > /etc/net/ifaces/"$LAN_IF".999/ipv4address

# --- Форвардинг
grep -qE '^\s*net\.ipv4\.ip_forward\s*=\s*1' /etc/net/sysctl.conf 2>/dev/null \
  || echo 'net.ipv4.ip_forward = 1' >> /etc/net/sysctl.conf
sysctl -w net.ipv4.ip_forward=1

# --- GRE-туннель
mkdir -p /etc/net/ifaces/tun0
cat > /etc/net/ifaces/tun0/options <<EOF
TYPE=iptun
TUNTYPE=gre
TUNLOCAL=172.16.1.2
TUNREMOTE=172.16.2.2
TUNTTL=64
TUNOPTIONS='ttl 64'
HOST=$WAN_IF
EOF
echo "10.10.10.1/30" > /etc/net/ifaces/tun0/ipv4address
modprobe gre
modprobe 8021q
systemctl restart network

# --- DHCP для VLAN 200 (dnsmasq) — исключаем шлюз .1
cat > /etc/dnsmasq.conf <<EOF
no-resolv
domain=au-team.irpo
dhcp-range=192.168.200.2,192.168.200.14,999h
dhcp-option=3,192.168.200.1
dhcp-option=6,192.168.100.2
dhcp-option=15,au-team.irpo
interface=$LAN_IF.200
EOF
systemctl enable --now dnsmasq
systemctl restart dnsmasq

# --- OSPF (FRR) — соседство ТОЛЬКО на tun0; LAN-сети объявляются пассивными
sed -i 's/ospfd=no/ospfd=yes/' /etc/frr/daemons
systemctl daemon-reload
systemctl enable --now frr
vtysh <<'EOF'
conf t
router ospf
 passive-interface default
 no passive-interface tun0
 network 10.10.10.0/30 area 0
 network 192.168.100.0/27 area 0
 network 192.168.200.0/28 area 0
 network 192.168.99.0/29 area 0
 area 0 authentication message-digest
exit
interface tun0
 ip ospf authentication message-digest
 ip ospf message-digest-key 1 md5 P@ssw0rd
exit
do wr
exit
EOF

# --- NAT и проброс портов (задание 8, модуль 2 п.8)
# 8080 -> веб на HQ-SRV, 2026 -> SSH HQ-SRV (доступ из внешних сетей)
# Свой SSH роутера — 2027, чтобы не конфликтовать с DNAT на 2026
iptables -t nat -C POSTROUTING -o "$WAN_IF" -j MASQUERADE 2>/dev/null || \
  iptables -t nat -A POSTROUTING -o "$WAN_IF" -j MASQUERADE
iptables -t nat -C PREROUTING -i "$WAN_IF" -p tcp --dport 8080 -j DNAT --to-destination 192.168.100.2:80 2>/dev/null || \
  iptables -t nat -A PREROUTING -i "$WAN_IF" -p tcp --dport 8080 -j DNAT --to-destination 192.168.100.2:80
iptables -t nat -C PREROUTING -i "$WAN_IF" -p tcp --dport 2026 -j DNAT --to-destination 192.168.100.2:2026 2>/dev/null || \
  iptables -t nat -A PREROUTING -i "$WAN_IF" -p tcp --dport 2026 -j DNAT --to-destination 192.168.100.2:2026
mkdir -p /etc/sysconfig
iptables-save > /etc/sysconfig/iptables
systemctl enable --now iptables

# --- Пользователь net_admin и SSH:2027 (задание 3)
useradd -m net_admin 2>/dev/null || true
echo "net_admin:P@ssw0rd" | chpasswd
gpasswd -a net_admin wheel
grep -q '^net_admin ' /etc/sudoers || echo "net_admin ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers
sed -i 's/^#*Port .*/Port 2027/' /etc/openssh/sshd_config
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' /etc/openssh/sshd_config
systemctl enable --now sshd
systemctl restart sshd

# --- Проверка
echo "Туннель:"; ping -c 3 10.10.10.2
vtysh -c "show ip ospf neighbor"

echo "HQ-RTR: модуль 1 завершён (net_admin, SSH 2027)"
