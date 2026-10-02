#!/bin/bash
# ===== Модуль 1 — BR-RTR =====
# hostname, LAN-интерфейс, форвардинг, GRE-туннель, OSPF, NAT, net_admin + SSH:2027
# Предварительно: адрес 172.16.2.2/28 на enp7s1, шлюз 172.16.2.1, nameserver 77.88.8.8
# Источник: BR-RTR.sh, sshrout.sh

WAN_IF=enp7s1   # в сторону ISP
LAN_IF=enp7s2   # в сторону BR-SRV

hostnamectl set-hostname br-rtr.au-team.irpo
apt-get update && apt-get install -y chrony tzdata frr iptables shadow-groups
timedatectl set-timezone Asia/Krasnoyarsk

# --- LAN-интерфейс
mkdir -p /etc/net/ifaces/"$LAN_IF"
cat > /etc/net/ifaces/"$LAN_IF"/options <<EOF
BOOTPROTO=static
TYPE=eth
CONFIG_WIRELESS=no
SYSTEMD_BOOTPROTO=dhcp4
CONFIG_IPV4=yes
DISABLED=no
NM_CONTROLLED=no
SYSTEMD_CONTROLLED=no
EOF
echo "192.168.0.1/28" > /etc/net/ifaces/"$LAN_IF"/ipv4address

# --- Форвардинг
grep -qE '^\s*net\.ipv4\.ip_forward\s*=\s*1' /etc/net/sysctl.conf 2>/dev/null \
  || echo 'net.ipv4.ip_forward = 1' >> /etc/net/sysctl.conf
sysctl -w net.ipv4.ip_forward=1

# --- GRE-туннель
mkdir -p /etc/net/ifaces/tun0
cat > /etc/net/ifaces/tun0/options <<EOF
TYPE=iptun
TUNTYPE=gre
TUNLOCAL=172.16.2.2
TUNREMOTE=172.16.1.2
TUNTTL=64
TUNOPTIONS='ttl 64'
HOST=$WAN_IF
EOF
echo "10.10.10.2/30" > /etc/net/ifaces/tun0/ipv4address
modprobe gre
systemctl restart network

# --- OSPF (FRR) — соседство ТОЛЬКО на tun0; LAN-сеть не объявляется
sed -i 's/ospfd=no/ospfd=yes/' /etc/frr/daemons
systemctl daemon-reload
systemctl enable --now frr
vtysh <<'EOF'
conf t
router ospf
 passive-interface default
 no passive-interface tun0
 network 10.10.10.0/30 area 0
 redistribute connected subnets
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
# 8080 -> веб-контейнер на BR-SRV (:8080), 2026 -> SSH BR-SRV (доступ из внешних сетей)
iptables -t nat -C POSTROUTING -o "$WAN_IF" -j MASQUERADE 2>/dev/null || \
  iptables -t nat -A POSTROUTING -o "$WAN_IF" -j MASQUERADE
iptables -t nat -C PREROUTING -i "$WAN_IF" -p tcp --dport 8080 -j DNAT --to-destination 192.168.0.2:8080 2>/dev/null || \
  iptables -t nat -A PREROUTING -i "$WAN_IF" -p tcp --dport 8080 -j DNAT --to-destination 192.168.0.2:8080
iptables -t nat -C PREROUTING -i "$WAN_IF" -p tcp --dport 2026 -j DNAT --to-destination 192.168.0.2:2026 2>/dev/null || \
  iptables -t nat -A PREROUTING -i "$WAN_IF" -p tcp --dport 2026 -j DNAT --to-destination 192.168.0.2:2026
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
echo "Туннель:"; ping -c 3 10.10.10.1
vtysh -c "show ip ospf neighbor"

echo "BR-RTR: модуль 1 завершён (net_admin, SSH 2027)"
