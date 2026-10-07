#!/bin/bash
# BR-RTR (Linux), модуль 1
# enp7s1 - к ISP (172.16.2.2/28), enp7s2 - в сторону BR-SRV (192.168.0.0/28 = 16 адресов)
apt-get update && apt-get install -y tzdata
timedatectl set-timezone "$TZ"
TZ="Asia/Krasnoyarsk"   # поствьте часовой пояс места проведения экзамена

hostnamectl set-hostname br-rtr.au-team.irpo

mkdir -p /etc/net/ifaces/{enp7s1,enp7s2}

cat > /etc/net/ifaces/enp7s1/options <<'EOF'
TYPE=eth
BOOTPROTO=static
CONFIG_IPV4=yes
DISABLED=no
NM_CONTROLLED=no
EOF
echo '172.16.2.2/28' > /etc/net/ifaces/enp7s1/ipv4address
echo 'default via 172.16.2.1' > /etc/net/ifaces/enp7s1/ipv4route

cp /etc/net/ifaces/enp7s1/options /etc/net/ifaces/enp7s2/options
echo '192.168.0.1/28' > /etc/net/ifaces/enp7s2/ipv4address

sed -i 's/^net.ipv4.ip_forward.*/net.ipv4.ip_forward = 1/' /etc/net/sysctl.conf

# ---------- GRE-туннель до HQ-RTR ----------
modprobe ip_gre
echo ip_gre >> /etc/modules
mkdir -p /etc/net/ifaces/tun0
cat > /etc/net/ifaces/tun0/options <<'EOF'
TYPE=iptun
TUNTYPE=gre
TUNLOCAL=172.16.2.2
TUNREMOTE=172.16.1.2
TUNTTL=64
TUNOPTIONS='ttl 64'
HOST=enp7s1
EOF
echo '10.10.10.2/30' > /etc/net/ifaces/tun0/ipv4address

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
 network 192.168.0.0/28 area 0
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
