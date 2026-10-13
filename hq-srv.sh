#!/bin/bash
# ===== Модуль 1 — HQ-SRV (пп. 1, 3, 5, 10, 11) =====
# Имя, 192.168.100.2/27 (VLAN 100), пользователи remote_user и sshuser,
# SSH (порт 2026, только sshuser, 2 попытки, баннер), DNS-сервер dnsmasq по таблице 3.
# ALT Linux Server (etcnet). Запускать от root НА КОНСОЛИ.
# Порядок: после ISP, HQ-RTR и BR-RTR (нужны Интернет и маршрутизация).
set -eu

# ---------- Переменные (проверьте: ip -br link) ----------
IF=${IF:-enp7s1}
TZ_NAME=${TZ_NAME:-Asia/Krasnoyarsk}
PASS=${PASS:-P@ssw0rd}                # пароли remote_user и sshuser (по заданию)
HOST_FQDN=hq-srv.au-team.irpo
SELF=192.168.100.2
DNS_UP1=77.88.8.8                     # сервер пересылки

die() { echo "!!! $*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "Запускайте от root"
ip link show "$IF" >/dev/null 2>&1 || die "Нет интерфейса $IF (ip -br link). Задайте: IF=... bash $0"

setopt() { # файл ключ значение: заменить (или добавить) параметр в sshd_config
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
echo "$SELF/27"               > "$D/ipv4address"
echo "default via 192.168.100.1" > "$D/ipv4route"
set_dns "$DNS_UP1"            # временно, пока не поднят свой DNS
systemctl restart network
sleep 5
set_dns "$DNS_UP1"

echo ">>> Пакеты"
apt-get update
apt-get install -y dnsmasq sudo tzdata openssh-server
timedatectl set-timezone "$TZ_NAME"

echo ">>> Пользователи"
# По тексту задания создаётся remote_user, а пароль/UID 2026/sudo относятся к sshuser.
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

echo ">>> DNS-сервер (dnsmasq) по таблице 3"
cat > /etc/dnsmasq.conf <<EOF
# Основной DNS-сервер офисов HQ и BR
domain-needed
no-resolv
bind-dynamic
listen-address=127.0.0.1,$SELF
domain=au-team.irpo
expand-hosts

# Серверы пересылки
server=$DNS_UP1

# A + PTR: hq-rtr, hq-srv, hq-cli
host-record=hq-rtr.au-team.irpo,192.168.100.1
host-record=hq-srv.au-team.irpo,$SELF
host-record=hq-cli.au-team.irpo,192.168.200.2

# Только A: br-rtr, br-srv
address=/br-rtr.au-team.irpo/192.168.0.1
address=/br-srv.au-team.irpo/192.168.0.2

# ISP: docker.* - интерфейс в сторону HQ-RTR, web.* - в сторону BR-RTR
address=/docker.au-team.irpo/172.16.1.1
address=/web.au-team.irpo/172.16.2.1
EOF
dnsmasq --test
systemctl enable dnsmasq
systemctl restart dnsmasq
sleep 2
set_dns "$SELF"

echo ""
echo "===== Проверка ====="
ip -br addr
ip route
for n in hq-rtr hq-srv hq-cli br-rtr br-srv docker web; do getent hosts "$n.au-team.irpo" || echo "НЕТ записи: $n"; done
for a in 192.168.100.1 192.168.100.2 192.168.200.2; do getent hosts "$a" || echo "НЕТ PTR: $a"; done
getent hosts ya.ru || echo "ВНИМАНИЕ: пересылка DNS не работает"
sshd -T | grep -Ei '^(port|allowusers|maxauthtries|banner) '
echo "HQ-SRV: модуль 1 готов"
