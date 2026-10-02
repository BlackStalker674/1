#!/bin/bash
# ===== Модуль 1 — ISP =====
# hostname, часовой пояс, адреса на интерфейсах, форвардинг, NAT, root по SSH
# Источник: isp.sh, prof.sh

WAN_IF=enp7s1   # интерфейс в интернет (на VirtualBox обычно enp0s3)
HQ_IF=enp7s2    # в сторону HQ-RTR
BR_IF=enp7s3    # в сторону BR-RTR

hostnamectl set-hostname isp.au-team.irpo
apt-get update && apt-get install -y chrony tzdata iptables
timedatectl set-timezone Asia/Krasnoyarsk

# --- Интерфейсы в сторону роутеров
for IF in "$HQ_IF" "$BR_IF"; do
  mkdir -p /etc/net/ifaces/"$IF"
  cat > /etc/net/ifaces/"$IF"/options <<EOF
BOOTPROTO=static
TYPE=eth
CONFIG_WIRELESS=no
SYSTEMD_BOOTPROTO=dhcp4
CONFIG_IPV4=yes
DISABLED=no
NM_CONTROLLED=no
SYSTEMD_CONTROLLED=no
EOF
done
echo '172.16.1.1/28' > /etc/net/ifaces/"$HQ_IF"/ipv4address
echo '172.16.2.1/28' > /etc/net/ifaces/"$BR_IF"/ipv4address

# --- WAN: адрес от провайдера (DHCP) или статика
mkdir -p /etc/net/ifaces/"$WAN_IF"
cat > /etc/net/ifaces/"$WAN_IF"/options <<EOF
BOOTPROTO=dhcp
TYPE=eth
CONFIG_WIRELESS=no
SYSTEMD_BOOTPROTO=dhcp4
CONFIG_IPV4=yes
DISABLED=no
NM_CONTROLLED=no
SYSTEMD_CONTROLLED=no
EOF
# Для статики раскомментируйте (и поменяйте BOOTPROTO=dhcp на static):
# echo '192.168.0.10/24' > /etc/net/ifaces/"$WAN_IF"/ipv4address
# echo '192.168.0.1'     > /etc/net/ifaces/"$WAN_IF"/ipv4route

# --- Маршрут по умолчанию (при DHCP приходит от провайдера)
# Для статики раскомментируйте:
# echo 'default via 192.168.0.1' > /etc/net/ifaces/"$WAN_IF"/ipv4route

# --- Форвардинг (добавляем, только если отсутствует)
grep -qE '^\s*net\.ipv4\.ip_forward\s*=\s*1' /etc/net/sysctl.conf 2>/dev/null \
  || echo 'net.ipv4.ip_forward = 1' >> /etc/net/sysctl.conf
sysctl -w net.ipv4.ip_forward=1

# --- NAT
iptables -t nat -C POSTROUTING -o "$WAN_IF" -j MASQUERADE 2>/dev/null || \
  iptables -t nat -A POSTROUTING -o "$WAN_IF" -j MASQUERADE
mkdir -p /etc/sysconfig
iptables-save > /etc/sysconfig/iptables
systemctl enable --now iptables 2>/dev/null || true

systemctl restart network

# --- Root по SSH (для удобства настройки)
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/openssh/sshd_config
systemctl enable --now sshd
systemctl restart sshd

echo "ISP: модуль 1 завершён"
