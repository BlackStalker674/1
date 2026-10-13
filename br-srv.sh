#!/bin/bash
# ===== Модуль 1 — BR-SRV (пп. 1, 3, 5, 11) =====
# Имя, 192.168.0.2/28, пользователи remote_user и sshuser,
# SSH (порт 2026, только sshuser, 2 попытки, баннер), DNS = HQ-SRV.
# ALT Linux Server (etcnet). Запускать от root НА КОНСОЛИ.
# Порядок: после ISP, HQ-RTR, BR-RTR и HQ-SRV.
set -eu

# ---------- Переменные (проверьте: ip -br link) ----------
IF=${IF:-enp7s1}
TZ_NAME=${TZ_NAME:-Asia/Krasnoyarsk}
PASS=${PASS:-P@ssw0rd}
HOST_FQDN=br-srv.au-team.irpo
DNS_UP=77.88.8.8
DNS_HQ=192.168.100.2

die() { echo "!!! $*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "Запускайте от root"
ip link show "$IF" >/dev/null 2>&1 || die "Нет интерфейса $IF (ip -br link). Задайте: IF=... bash $0"

setopt() { # файл ключ значение
    local f=$1 k=$2 v=$3
    if grep -qE "^[#[:space:]]*${k}[[:space:]]" "$f"; then
        sed -i -E "0,/^[#[:space:]]*${k}[[:space:]]/{s|^[#[:space:]]*${k}[[:space:]].*|${k} ${v}|}" "$f"
    else
        echo "${k} ${v}" >> "$f"
    fi
}

set_dns() { # nameserver...
    local f=/etc/net/ifaces/$IF/resolv.conf
    { echo "search au-team.irpo"; for n in "$@"; do echo "nameserver $n"; done; } > "$f"
    cp -f "$f" /etc/resolv.conf
}

echo ">>> Имя"
hostnamectl set-hostname "$HOST_FQDN"

echo ">>> Сеть"
D=/etc/net/ifaces/$IF
mkdir -p "$D"
cat > "$D/options" <<EOF
TYPE=eth
BOOTPROTO=static
CONFIG_IPV4=yes
DISABLED=no
NM_CONTROLLED=no
SYSTEMD_CONTROLLED=no
EOF
echo "192.168.0.2/28"            > "$D/ipv4address"
echo "default via 192.168.0.1"   > "$D/ipv4route"
set_dns "$DNS_UP"             # временно, на время установки пакетов
systemctl restart network
sleep 5
set_dns "$DNS_UP"

echo ">>> Пакеты"
apt-get update
apt-get install -y sudo tzdata openssh-server
timedatectl set-timezone "$TZ_NAME"

echo ">>> Пользователи"
id -u remote_user >/dev/null 2>&1 || useradd -m remote_user
echo "remote_user:$PASS" | chpasswd
id -u sshuser >/dev/null 2>&1 || useradd -m -u 2026 sshuser
echo "sshuser:$PASS" | chpasswd
usermod -aG wheel sshuser
echo "sshuser ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/sshuser
chmod 440 /etc/sudoers.d/sshuser
visudo -cf /etc/sudoers.d/sshuser
# sudo должен читать /etc/sudoers.d
grep -qE '^[#@]includedir[[:space:]]+/etc/sudoers\.d' /etc/sudoers || echo '@includedir /etc/sudoers.d' >> /etc/sudoers
visudo -c >/dev/null

echo ">>> SSH: порт 2026, только sshuser, 2 попытки, баннер"
CFG=/etc/openssh/sshd_config
echo "Authorized access only" > /etc/openssh/banner
setopt "$CFG" Port 2026
setopt "$CFG" AllowUsers sshuser
setopt "$CFG" MaxAuthTries 2
setopt "$CFG" Banner /etc/openssh/banner
sshd -t
systemctl enable sshd
systemctl restart sshd

echo ">>> DNS = HQ-SRV"
set_dns "$DNS_HQ"

echo ""
echo "===== Проверка ====="
ip -br addr
ip route
getent hosts hq-srv.au-team.irpo || echo "ВНИМАНИЕ: DNS HQ-SRV недоступен (туннель/OSPF/dnsmasq?)"
getent hosts ya.ru || echo "ВНИМАНИЕ: пересылка DNS не работает"
ping -c 2 192.168.100.2 || echo "ВНИМАНИЕ: HQ-SRV недоступен (OSPF не сошёлся?)"
sshd -T | grep -Ei '^(port|allowusers|maxauthtries|banner) '
echo "BR-SRV: модуль 1 готов"
