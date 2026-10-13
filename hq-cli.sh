#!/bin/bash
# ===== Модуль 1 — HQ-CLI (пп. 1, 9, 11) =====
# Имя, часовой пояс, адрес/шлюз/DNS/суффикс по DHCP от HQ-RTR (VLAN 200).
# По заданию SSH и пользователи настраиваются только на серверах, здесь их нет.
# ALT Рабочая станция: сетью обычно управляет NetworkManager, тогда интерфейс
# переводится в DHCP через nmcli; если NetworkManager не запущен - через etcnet.
# Запускать от root НА КОНСОЛИ.
set -eu

# ---------- Переменные (проверьте: ip -br link) ----------
IF=${IF:-enp7s1}
TZ_NAME=${TZ_NAME:-Asia/Krasnoyarsk}
HOST_FQDN=hq-cli.au-team.irpo

die() { echo "!!! $*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "Запускайте от root"
ip link show "$IF" >/dev/null 2>&1 || die "Нет интерфейса $IF (ip -br link). Задайте: IF=... bash $0"

echo ">>> Имя"
hostnamectl set-hostname "$HOST_FQDN"

echo ""
echo "MAC для HQ-RTR (закрепление адреса 192.168.200.2):"
echo "  HQ_CLI_MAC=$(cat /sys/class/net/"$IF"/address) bash 02_HQ-RTR.sh"
echo ""

echo ">>> Интерфейс $IF по DHCP"
if systemctl is-active --quiet NetworkManager; then
    CON=$(nmcli -g GENERAL.CONNECTION device show "$IF" 2>/dev/null | head -1)
    if [ -z "$CON" ] || [ "$CON" = "--" ]; then
        CON="$IF"
        nmcli con add type ethernet ifname "$IF" con-name "$CON"
    fi
    echo "NetworkManager, подключение: $CON"
    nmcli con mod "$CON" ipv4.method auto ipv4.addresses "" ipv4.gateway "" \
        ipv4.dns "" ipv4.ignore-auto-dns no connection.autoconnect yes
    nmcli con up "$CON"
else
    D=/etc/net/ifaces/$IF
    mkdir -p "$D"
    cat > "$D/options" <<EOF
TYPE=eth
BOOTPROTO=dhcp
CONFIG_IPV4=yes
DISABLED=no
NM_CONTROLLED=no
SYSTEMD_CONTROLLED=no
EOF
    rm -f "$D/ipv4address" "$D/ipv4route" "$D/resolv.conf"
    systemctl enable network
    systemctl restart network
fi
sleep 8

echo ">>> Пакеты и часовой пояс"
apt-get update
apt-get install -y tzdata
timedatectl set-timezone "$TZ_NAME"

echo ""
echo "===== Проверка ====="
ip -br addr show "$IF"
ip route
cat /etc/resolv.conf
getent hosts hq-srv.au-team.irpo || echo "ВНИМАНИЕ: DNS HQ-SRV недоступен"
ping -c 2 ya.ru || echo "ВНИМАНИЕ: Интернет недоступен"
echo "HQ-CLI: модуль 1 готов"
