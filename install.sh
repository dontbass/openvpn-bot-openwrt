#!/bin/sh
# install.sh — установщик openvpn-bot для OpenWrt

set -e

INSTALL_DIR="/usr/share/ovpnbot"
INIT_SCRIPT="/etc/init.d/ovpnbot"
CLIENTS_DIR="/etc/openvpn/clients"
LOG="/var/log/ovpnbot.log"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()    { echo "${GREEN}[+]${NC} $*"; }
warn()    { echo "${YELLOW}[!]${NC} $*"; }
error()   { echo "${RED}[x]${NC} $*"; exit 1; }
prompt()  { printf "${YELLOW}[?]${NC} %s " "$*"; }

# ─── Проверки ─────────────────────────────────────────────────────────────────

info "Проверка зависимостей..."
for cmd in curl openssl easyrsa uci; do
    command -v "$cmd" > /dev/null 2>&1 || error "Не найдена команда: $cmd. Установи openvpn-easy-rsa и curl."
done

[ -f /etc/openvpn/pki/ca.crt ]    || error "PKI не найдена. Убедись что OpenVPN PKI инициализирована (/etc/openvpn/pki)."
[ -f /etc/openvpn/pki/ta.key ]    || error "ta.key не найден в /etc/openvpn/pki/"
[ -f /etc/openvpn/server.conf ]   || error "server.conf не найден в /etc/openvpn/"

# ─── Сбор параметров ──────────────────────────────────────────────────────────

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  OpenVPN Telegram Bot — Установка"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Токен бота
prompt "Telegram Bot Token:"
read -r BOT_TOKEN
[ -z "$BOT_TOKEN" ] && error "Токен не может быть пустым."

# Проверяем токен
info "Проверяем токен..."
BOTNAME=$(curl -s "https://api.telegram.org/bot$BOT_TOKEN/getMe" | grep -o '"username":"[^"]*"' | sed 's/"username":"//;s/"//')
[ -z "$BOTNAME" ] && error "Невалидный токен или нет доступа к Telegram API."
info "Бот найден: @$BOTNAME"

echo ""

# Admin IDs
echo "Введите Telegram ID администраторов."
echo "Можно указать один или несколько через пробел."
echo "Чтобы узнать свой ID — напиши @userinfobot в Telegram."
echo ""
prompt "Admin ID(s):"
read -r ADMIN_IDS
[ -z "$ADMIN_IDS" ] && error "Нужен хотя бы один admin ID."

echo ""

# Внешний IP/хост
DETECTED_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || echo "")
if [ -n "$DETECTED_IP" ]; then
    prompt "Внешний IP/хост сервера [$DETECTED_IP]:"
    read -r SERVER_HOST
    SERVER_HOST="${SERVER_HOST:-$DETECTED_IP}"
else
    prompt "Внешний IP/хост сервера:"
    read -r SERVER_HOST
fi
[ -z "$SERVER_HOST" ] && error "Хост не может быть пустым."

# Порт и протокол из server.conf
DETECTED_PORT=$(grep '^port ' /etc/openvpn/server.conf | awk '{print $2}')
DETECTED_PROTO=$(grep '^proto ' /etc/openvpn/server.conf | awk '{print $2}')
DETECTED_PORT="${DETECTED_PORT:-1194}"
DETECTED_PROTO="${DETECTED_PROTO:-udp}"

prompt "Порт OpenVPN [$DETECTED_PORT]:"
read -r SERVER_PORT
SERVER_PORT="${SERVER_PORT:-$DETECTED_PORT}"

prompt "Протокол (tcp/udp) [$DETECTED_PROTO]:"
read -r SERVER_PROTO
SERVER_PROTO="${SERVER_PROTO:-$DETECTED_PROTO}"

echo ""

# ─── Установка ────────────────────────────────────────────────────────────────

info "Устанавливаем файлы..."
mkdir -p "$INSTALL_DIR" "$CLIENTS_DIR"

cp "$(dirname "$0")/bot.sh" "$INSTALL_DIR/bot.sh"
chmod +x "$INSTALL_DIR/bot.sh"

# ─── UCI конфиг ───────────────────────────────────────────────────────────────

info "Записываем конфиг..."
uci -q delete ovpnbot.main 2>/dev/null || true
uci set ovpnbot.main=ovpnbot
uci set ovpnbot.main.token="$BOT_TOKEN"
uci set ovpnbot.main.admin_ids="$ADMIN_IDS"
uci set ovpnbot.main.host="$SERVER_HOST"
uci set ovpnbot.main.port="$SERVER_PORT"
uci set ovpnbot.main.proto="$SERVER_PROTO"
uci commit ovpnbot

# ─── CRL в server.conf (если не добавлен) ────────────────────────────────────

if ! grep -q 'crl-verify' /etc/openvpn/server.conf; then
    info "Добавляем crl-verify в server.conf..."
    echo "crl-verify /etc/openvpn/pki/crl.pem" >> /etc/openvpn/server.conf
    # Генерируем пустой CRL
    cd /etc/openvpn && easyrsa --batch gen-crl 2>/dev/null || true
fi

# ─── Init script ──────────────────────────────────────────────────────────────

info "Создаём init script..."
cat > "$INIT_SCRIPT" << 'INIT'
#!/bin/sh /etc/rc.common
START=95
STOP=10
USE_PROCD=1

start_service() {
    procd_open_instance
    procd_set_param command /bin/sh /usr/share/ovpnbot/bot.sh
    procd_set_param respawn 10 5 0
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}
INIT

chmod +x "$INIT_SCRIPT"

# ─── Запуск ───────────────────────────────────────────────────────────────────

info "Включаем автозапуск и запускаем бота..."
"$INIT_SCRIPT" enable
"$INIT_SCRIPT" start

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
info "Установка завершена!"
echo ""
echo "  Бот: @$BOTNAME"
echo "  Логи: tail -f $LOG"
echo "  Статус: /etc/init.d/ovpnbot status"
echo "  Перезапуск: /etc/init.d/ovpnbot restart"
echo "  Удаление: /etc/init.d/ovpnbot stop && rm -rf $INSTALL_DIR $INIT_SCRIPT"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
info "Напиши /start своему боту в Telegram."
