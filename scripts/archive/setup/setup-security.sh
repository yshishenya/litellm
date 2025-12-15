#!/bin/bash
#
# Setup Security Configuration
# Настраивает базовую безопасность: UFW firewall, Fail2ban
#

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

log_error() {
    echo -e "${RED}[✗]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

echo "======================================================================"
echo "  Security Configuration Setup"
echo "======================================================================"
echo ""

# Проверка прав root
if [ "$EUID" -ne 0 ]; then
    log_error "Этот скрипт должен выполняться с правами root (sudo)"
    exit 1
fi

#############################################################################
# 1. Установка UFW (Uncomplicated Firewall)
#############################################################################

log_info "Установка UFW..."
apt-get update -qq
apt-get install -y ufw

log_success "UFW установлен"

#############################################################################
# 2. Настройка правил UFW
#############################################################################

log_info "Настройка правил UFW..."

# Сброс всех правил
ufw --force reset

# Политики по умолчанию
ufw default deny incoming
ufw default allow outgoing

# SSH (ВАЖНО: разрешить перед активацией!)
ufw allow 22/tcp comment 'SSH'

# HTTP и HTTPS (для Nginx)
ufw allow 80/tcp comment 'HTTP'
ufw allow 443/tcp comment 'HTTPS'

# ОПЦИОНАЛЬНО: Если нужен прямой доступ к сервисам (обычно НЕ нужен)
# ufw allow from <YOUR_IP> to any port 4000 comment 'LiteLLM API (restricted)'
# ufw allow from <YOUR_IP> to any port 3098 comment 'Grafana (restricted)'

log_success "Правила UFW настроены"

# Активация UFW
log_info "Активация UFW..."
ufw --force enable

log_success "UFW активирован"

# Статус
echo ""
log_info "Статус UFW:"
ufw status numbered

#############################################################################
# 3. Установка Fail2ban
#############################################################################

log_info "Установка Fail2ban..."
apt-get install -y fail2ban

log_success "Fail2ban установлен"

#############################################################################
# 4. Настройка Fail2ban
#############################################################################

log_info "Создание конфигурации Fail2ban..."

# Локальная конфигурация
cat > /etc/fail2ban/jail.local <<'FAIL2BAN'
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5
destemail = root@localhost
sendername = Fail2Ban
action = %(action_mw)s

[sshd]
enabled = true
port = 22
logpath = /var/log/auth.log
maxretry = 3
bantime = 7200

[nginx-http-auth]
enabled = true
port = http,https
logpath = /var/log/nginx/error.log

[nginx-noscript]
enabled = true
port = http,https
logpath = /var/log/nginx/access.log

[nginx-badbots]
enabled = true
port = http,https
logpath = /var/log/nginx/access.log
maxretry = 2

[nginx-noproxy]
enabled = true
port = http,https
logpath = /var/log/nginx/access.log
FAIL2BAN

log_success "Конфигурация Fail2ban создана"

# Перезапуск Fail2ban
log_info "Перезапуск Fail2ban..."
systemctl restart fail2ban
systemctl enable fail2ban

log_success "Fail2ban запущен"

# Статус
echo ""
log_info "Статус Fail2ban:"
fail2ban-client status

#############################################################################
# 5. Настройка автоматических обновлений безопасности
#############################################################################

log_info "Настройка автоматических обновлений безопасности..."
apt-get install -y unattended-upgrades

cat > /etc/apt/apt.conf.d/50unattended-upgrades <<'UNATTENDED'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
UNATTENDED

cat > /etc/apt/apt.conf.d/20auto-upgrades <<'AUTO_UPGRADES'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
AUTO_UPGRADES

log_success "Автоматические обновления настроены"

echo ""
echo "======================================================================"
echo -e "${GREEN}✓ Безопасность настроена успешно!${NC}"
echo "======================================================================"
echo ""
echo "Настроено:"
echo "  ✓ UFW Firewall (порты: 22, 80, 443)"
echo "  ✓ Fail2ban (защита SSH, Nginx)"
echo "  ✓ Автоматические обновления безопасности"
echo ""
echo "Проверка:"
echo "  sudo ufw status"
echo "  sudo fail2ban-client status"
echo ""
echo "ВАЖНО: Убедитесь, что SSH (порт 22) разрешен в UFW!"
echo "       Иначе вы потеряете доступ к серверу."
echo ""
