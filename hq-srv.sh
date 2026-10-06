#!/bin/bash
# HQ-SRV, модуль 1 (VLAN 100: 192.168.100.2/27, шлюз 192.168.100.1)
apt-get update && apt-get install -y tzdata
timedatectl set-timezone "$TZ"
TZ="Asia/Krasnoyarsk"   # поставьте часовой пояс места проведения экзамена
IFACE=enp7s1.100            # проверьте имя интерфейса командой ip a

hostnamectl set-hostname hq-srv.au-team.irpo

# ---------- IP ----------
mkdir -p /etc/net/ifaces/$IFACE
cat > /etc/net/ifaces/$IFACE/options <<'EOF'
TYPE=vlan
HOST=enp7s1
VID=100
BOOTPROTO=static
CONFIG_IPV4=yes
DISABLED=no
NM_CONTROLLED=no
EOF
echo '192.168.100.2/27' > /etc/net/ifaces/$IFACE/ipv4address
echo 'default via 192.168.100.1' > /etc/net/ifaces/$IFACE/ipv4route
printf 'search au-team.irpo\nnameserver 127.0.0.1\n' > /etc/net/ifaces/$IFACE/resolv.conf
systemctl restart network

# tzdata нужен для смены часового пояса (требуется интернет, сеть уже настроена)
apt-get update && apt-get install -y tzdata
timedatectl set-timezone "$TZ"

# ---------- Пользователь sshuser (UID 2026) ----------
id sshuser &>/dev/null || useradd -u 2026 -m sshuser
echo "sshuser:P@ssw0rd" | chpasswd
usermod -aG wheel sshuser
grep -q '^sshuser ' /etc/sudoers || echo "sshuser ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

# ---------- SSH: порт 2026, только sshuser, 2 попытки, баннер ----------
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

# ---------- DNS (dnsmasq) по таблице 3 ----------
# host-record создаёт A и PTR, address - только A
# Адрес hq-cli берётся из DHCP-пула (192.168.200.2-14): после выдачи адреса проверьте и поправьте запись
apt-get update && apt-get install -y dnsmasq
cat > /etc/dnsmasq.conf <<'EOF'
no-resolv
server=77.88.8.7
server=77.88.8.3
domain=au-team.irpo
host-record=hq-rtr.au-team.irpo,192.168.100.1
host-record=hq-srv.au-team.irpo,192.168.100.2
host-record=hq-cli.au-team.irpo,192.168.200.2
address=/br-rtr.au-team.irpo/192.168.0.1
address=/br-srv.au-team.irpo/192.168.0.2
address=/docker.au-team.irpo/172.16.1.1
address=/web.au-team.irpo/172.16.2.1
EOF
systemctl enable --now dnsmasq
systemctl restart dnsmasq

nslookup hq-srv.au-team.irpo 127.0.0.1
