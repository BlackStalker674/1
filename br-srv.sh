#!/bin/bash
# ===== Модуль 1 — BR-SRV =====
# hostname, часовой пояс, remote_user (UID 2026) + SSH:2026 с баннером
# Предварительно: адрес 192.168.0.2/28, шлюз 192.168.0.1, nameserver 77.88.8.8
# Источник: BR-SRV.sh

hostnamectl set-hostname br-srv.au-team.irpo
apt-get update && apt-get install -y chrony tzdata
timedatectl set-timezone Asia/Krasnoyarsk
systemctl enable --now chronyd

# --- Учётные записи (задание 1.3) -------------------------------------------
# remote_user — просто локальная учётная запись
# sshuser    — UID 2026, пароль P@ssw0rd, sudo без пароля
id -u remote_user >/dev/null 2>&1 || useradd -m remote_user
echo "remote_user:P@ssw0rd" | chpasswd

id -u sshuser >/dev/null 2>&1 || useradd -u 2026 -m sshuser
echo "sshuser:P@ssw0rd" | chpasswd
gpasswd -a sshuser wheel 2>/dev/null || true
grep -q '^sshuser ' /etc/sudoers || echo "sshuser ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

# --- SSH
sed -i 's/^#*Port .*/Port 2026/' /etc/openssh/sshd_config
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' /etc/openssh/sshd_config
sed -i 's/^#*MaxAuthTries.*/MaxAuthTries 2/' /etc/openssh/sshd_config
# вход разрешён ИСКЛЮЧИТЕЛЬНО пользователю sshuser
sed -i 's/^AllowUsers.*/AllowUsers sshuser/' /etc/openssh/sshd_config
grep -q '^AllowUsers' /etc/openssh/sshd_config || echo "AllowUsers sshuser" >> /etc/openssh/sshd_config
grep -q '^Banner' /etc/openssh/sshd_config || echo "Banner /etc/openssh/banner" >> /etc/openssh/sshd_config
echo "Authorized access only" > /etc/openssh/banner
systemctl enable --now sshd
systemctl restart sshd

# --- DNS на HQ-SRV
cat > /etc/resolv.conf <<EOF
search au-team.irpo
nameserver 192.168.100.2
nameserver 77.88.8.8
EOF

# --- Мониторинг CPU / RAM / диск (задание 5)
cat > /usr/local/bin/monitor.sh <<'EOF'
#!/bin/bash
LOG=/var/log/monitor.log
CPU=$(top -bn1 | grep "Cpu(s)" | awk '{print 100 - $8}')
RAM=$(free -m | awk '/Mem:/ {printf "%.0f%%", $3/$2*100}')
DISK=$(df -h / | awk 'NR==2 {print $5}')
echo "$(date '+%F %T') CPU=${CPU} RAM=${RAM} DISK=${DISK}" >> "$LOG"
EOF
chmod +x /usr/local/bin/monitor.sh
echo "*/5 * * * * root /usr/local/bin/monitor.sh" > /etc/cron.d/monitor

echo "BR-SRV: модуль 1 завершён"
echo "  Пользователь: remote_user / P@ssw0rd, SSH порт 2026, root запрещён"
