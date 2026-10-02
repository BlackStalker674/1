#!/bin/bash
# ===== Модуль 1 — HQ-CLI =====
# hostname, часовой пояс, интерфейс по DHCP от HQ-RTR (VLAN 200), sshuser + SSH:2027
# Источник: HQ-CLI.sh, prof.sh

IF=enp7s1

hostnamectl set-hostname hq-cli.au-team.irpo
apt-get update && apt-get install -y chrony tzdata
timedatectl set-timezone Asia/Krasnoyarsk
systemctl enable --now chronyd

# --- Интерфейс по DHCP
mkdir -p /etc/net/ifaces/"$IF"
cat > /etc/net/ifaces/"$IF"/options <<EOF
BOOTPROTO=dhcp
TYPE=eth
CONFIG_WIRELESS=no
SYSTEMD_BOOTPROTO=dhcp4
CONFIG_IPV4=yes
DISABLED=no
NM_CONTROLLED=no
SYSTEMD_CONTROLLED=no
EOF
rm -f /etc/net/ifaces/"$IF"/ipv4address /etc/net/ifaces/"$IF"/ipv4route
systemctl restart network

# --- Учётные записи (задание 1 п.3) -------------------------------------------
# remote_user — просто локальная учётная запись
# sshuser    — UID 2026, пароль P@ssw0rd, sudo без пароля
id -u remote_user >/dev/null 2>&1 || useradd -m remote_user
echo "remote_user:P@ssw0rd" | chpasswd

id -u sshuser >/dev/null 2>&1 || useradd -u 2026 -m sshuser
echo "sshuser:P@ssw0rd" | chpasswd
gpasswd -a sshuser wheel
grep -q '^sshuser ' /etc/sudoers || echo "sshuser ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

# --- SSH: порт 2027, 2 попытки, баннер
sed -i 's/^#*Port .*/Port 2027/' /etc/openssh/sshd_config
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' /etc/openssh/sshd_config
sed -i 's/^#*MaxAuthTries.*/MaxAuthTries 2/' /etc/openssh/sshd_config
grep -q '^AllowUsers' /etc/openssh/sshd_config && \
  sed -i 's/^AllowUsers.*/AllowUsers sshuser/' /etc/openssh/sshd_config || \
  echo "AllowUsers sshuser" >> /etc/openssh/sshd_config
grep -q '^Banner' /etc/openssh/sshd_config || echo "Banner /etc/openssh/banner" >> /etc/openssh/sshd_config
echo "Authorized access only" > /etc/openssh/banner
systemctl enable --now sshd
systemctl restart sshd

# --- DNS на HQ-SRV
chattr -i /etc/resolv.conf 2>/dev/null
cat > /etc/resolv.conf <<EOF
search au-team.irpo
nameserver 192.168.100.2
EOF
chattr +i /etc/resolv.conf

# --- Проверка
ip -4 a show "$IF"
ping -c 2 hq-srv.au-team.irpo

echo "HQ-CLI: модуль 1 завершён"
