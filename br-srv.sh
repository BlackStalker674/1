#!/bin/bash
# BR-SRV, модуль 1 (192.168.0.2/28, шлюз 192.168.0.1)
apt-get update && apt-get install -y tzdata
timedatectl set-timezone "$TZ"
TZ="Asia/Krasnoyarsk"   # поставьте часовой пояс места проведения экзамена
IFACE=enp7s1            # проверьте имя интерфейса командой ip a

hostnamectl set-hostname br-srv.au-team.irpo

mkdir -p /etc/net/ifaces/$IFACE
cat > /etc/net/ifaces/$IFACE/options <<'EOF'
TYPE=eth
BOOTPROTO=static
CONFIG_IPV4=yes
DISABLED=no
NM_CONTROLLED=no
EOF
echo '192.168.0.2/28' > /etc/net/ifaces/$IFACE/ipv4address
echo 'default via 192.168.0.1' > /etc/net/ifaces/$IFACE/ipv4route
printf 'search au-team.irpo\nnameserver 192.168.100.2\n' > /etc/net/ifaces/$IFACE/resolv.conf
systemctl restart network

# tzdata нужен для смены часового пояса (требуется интернет, сеть уже настроена)
apt-get update && apt-get install -y tzdata
timedatectl set-timezone "$TZ"

id sshuser &>/dev/null || useradd -u 2026 -m sshuser
echo "sshuser:P@ssw0rd" | chpasswd
usermod -aG wheel sshuser
grep -q '^sshuser ' /etc/sudoers || echo "sshuser ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

echo "Authorized access only" > /etc/openssh/banner
sed -i 's/^#\?Port .*/Port 2026/' /etc/openssh/sshd_config
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/openssh/sshd_config
sed -i '/^AllowUsers/d;/^MaxAuthTries/d;/^Banner/d' /etc/openssh/sshd_config
cat >> /etc/openssh/sshd_config <<'EOF'
AllowUsers sshuser
MaxAuthTries 2
Banner /etc/openssh/banner
EOF
systemctl enable --now sshd
systemctl restart sshd
