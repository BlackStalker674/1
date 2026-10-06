#!/bin/bash
# HQ-RTR (Linux), модуль 1
# enp7s1 - к ISP (172.16.1.2/28), enp7s2 - в сторону HQ (один порт, VLAN 100/200/999)
apt-get update && apt-get install -y tzdata
timedatectl set-timezone "$TZ"
TZ="Asia/Krasnoyarsk"   # поставьте часовой пояс места проведения экзамена

hostnamectl set-hostname hq-rtr.au-team.irpo

# ---------- Интерфейсы ----------
mkdir -p /etc/net/ifaces/{enp7s1,enp7s2}

cat > /etc/net/ifaces/enp7s1/options <<'EOF'
TYPE=eth
BOOTPROTO=static
CONFIG_IPV4=yes
DISABLED=no
NM_CONTROLLED=no
EOF
echo '172.16.1.2/28' > /etc/net/ifaces/enp7s1/ipv4address
echo 'default via 172.16.1.1' > /etc/net/ifaces/enp7s1/ipv4route

cat > /etc/net/ifaces/enp7s2/options <<'EOF'
TYPE=eth
BOOTPROTO=static
CONFIG_IPV4=yes
DISABLED=no
NM_CONTROLLED=no
EOF

# VLAN 100 (HQ-SRV, /27 = 32 адреса), VLAN 200 (HQ-CLI, /28 = 16 адресов), VLAN 999 (управление, /29 = 8 адресов)
declare -A NET=( [100]="192.168.100.1/27" [200]="192.168.200.1/28" [999]="192.168.99.1/29" )
for vid in 100 200 999; do
  mkdir -p /etc/net/ifaces/enp7s2.$vid
  cat > /etc/net/ifaces/enp7s2.$vid/options <<EOF
TYPE=vlan
HOST=enp7s2
VID=$vid
BOOTPROTO=static
DISABLED=no
EOF
  echo "${NET[$vid]}" > /etc/net/ifaces/enp7s2.$vid/ipv4address
done

# Маршрутизация
sed -i 's/^net.ipv4.ip_forward.*/net.ipv4.ip_forward = 1/' /etc/net/sysctl.conf

# ---------- GRE-туннель до BR-RTR ----------
modprobe ip_gre
echo ip_gre >> /etc/modules
mkdir -p /etc/net/ifaces/tun0
cat > /etc/net/ifaces/tun0/options <<'EOF'
TYPE=iptun
TUNTYPE=gre
TUNLOCAL=172.16.1.2
TUNREMOTE=172.16.2.2
TUNTTL=64
TUNOPTIONS='ttl 64'
HOST=enp7s1
EOF
echo '10.10.10.1/30' > /etc/net/ifaces/tun0/ipv4address

systemctl restart network

# tzdata нужен для смены часового пояса (требуется интернет, сеть уже настроена)
apt-get update && apt-get install -y tzdata
timedatectl set-timezone "$TZ"

# ---------- NAT в сторону ISP ----------
apt-get update && apt-get install -y iptables
iptables -t nat -F POSTROUTING
iptables -t nat -A POSTROUTING -o enp7s1 -j MASQUERADE
iptables-save > /etc/sysconfig/iptables
systemctl enable --now iptables

# ---------- DHCP для HQ-CLI (VLAN 200) ----------
# Адрес роутера (192.168.200.1) в выдачу не входит; DNS - HQ-SRV; суффикс au-team.irpo
apt-get install -y dnsmasq
cat > /etc/dnsmasq.conf <<'EOF'
port=0
interface=enp7s2.200
bind-interfaces
dhcp-authoritative
dhcp-range=192.168.200.2,192.168.200.14,255.255.255.240,12h
dhcp-option=3,192.168.200.1
dhcp-option=6,192.168.100.2
dhcp-option=15,au-team.irpo
EOF
systemctl enable --now dnsmasq
systemctl restart dnsmasq

# ---------- OSPF (FRR) только на туннеле, с паролем ----------
apt-get install -y frr
sed -i 's/^ospfd=no/ospfd=yes/' /etc/frr/daemons
systemctl enable --now frr
systemctl restart frr

vtysh <<'VTY'
conf t
router ospf
 passive-interface default
 network 10.10.10.0/30 area 0
 network 192.168.100.0/27 area 0
 network 192.168.200.0/28 area 0
 network 192.168.99.0/29 area 0
exit
interface tun0
 no ip ospf passive
 ip ospf authentication message-digest
 ip ospf message-digest-key 1 md5 P@ssw0rd
exit
end
write memory
VTY

# ---------- Пользователь net_admin ----------
id net_admin &>/dev/null || useradd -m net_admin
echo "net_admin:P@ssw0rd" | chpasswd
usermod -aG wheel net_admin
grep -q '^net_admin ' /etc/sudoers || echo "net_admin ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

systemctl enable --now sshd
