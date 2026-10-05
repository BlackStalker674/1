#!/bin/bash
# ISP, модуль 1
# enp7s1 - к провайдеру (DHCP), enp7s2 - к HQ-RTR (172.16.1.0/28), enp7s3 - к BR-RTR (172.16.2.0/28)
TZ="Asia/Krasnoyarsk"   # поставьте часовой пояс места проведения экзамена

hostnamectl set-hostname isp.au-team.irpo
apt-get update && apt-get install -y tzdata
timedatectl set-timezone "$TZ"

mkdir -p /etc/net/ifaces/{enp7s1,enp7s2,enp7s3}

cat > /etc/net/ifaces/enp7s1/options <<'EOF'
TYPE=eth
BOOTPROTO=dhcp
CONFIG_IPV4=yes
DISABLED=no
NM_CONTROLLED=no
EOF

for i in enp7s2 enp7s3; do
cat > /etc/net/ifaces/$i/options <<'EOF'
TYPE=eth
BOOTPROTO=static
CONFIG_IPV4=yes
DISABLED=no
NM_CONTROLLED=no
EOF
done

echo '172.16.1.1/28' > /etc/net/ifaces/enp7s2/ipv4address
echo '172.16.2.1/28' > /etc/net/ifaces/enp7s3/ipv4address

# Маршрутизация
sed -i 's/^net.ipv4.ip_forward.*/net.ipv4.ip_forward = 1/' /etc/net/sysctl.conf

# Динамическая трансляция (NAT) в сторону провайдера
apt-get update && apt-get install -y iptables
iptables -t nat -F POSTROUTING
iptables -t nat -A POSTROUTING -o enp7s1 -j MASQUERADE
iptables-save > /etc/sysconfig/iptables
systemctl enable --now iptables

# root по SSH нужен для scp сертификатов в модуле 3
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/openssh/sshd_config
systemctl enable --now sshd
systemctl restart sshd

systemctl restart network
