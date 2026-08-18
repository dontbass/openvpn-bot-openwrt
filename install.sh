#!/bin/sh
# install.sh — установщик openvpn-bot для OpenWrt

INSTALL_DIR="/usr/share/ovpnbot"
INIT_SCRIPT="/etc/init.d/ovpnbot"
CLIENTS_DIR="/etc/openvpn/clients"
LOG="/var/log/ovpnbot.log"

info()   { echo "[+] $*"; }
warn()   { echo "[!] $*"; }
error()  { echo "[x] $*"; exit 1; }
prompt() { printf "[?] %s " "$*"; }

# ─── Проверки ─────────────────────────────────────────────────────────────────

info "Проверка зависимостей..."
for cmd in curl openssl easyrsa uci; do
    command -v "$cmd" > /dev/null 2>&1 || error "Не найдена команда: $cmd"
done

[ -f /etc/openvpn/pki/ca.crt ]  || error "PKI не найдена: /etc/openvpn/pki/ca.crt"
[ -f /etc/openvpn/pki/ta.key ]  || error "ta.key не найден: /etc/openvpn/pki/ta.key"
[ -f /etc/openvpn/server.conf ] || error "server.conf не найден: /etc/openvpn/server.conf"

# ─── Сбор параметров ──────────────────────────────────────────────────────────

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  OpenVPN Telegram Bot — Установка"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Токен
prompt "Telegram Bot Token:"
read -r BOT_TOKEN
[ -z "$BOT_TOKEN" ] && error "Токен не может быть пустым."

info "Проверяем токен..."
BOTNAME=$(curl -s "https://api.telegram.org/bot$BOT_TOKEN/getMe" | grep -o '"username":"[^"]*"' | sed 's/"username":"//;s/"//')
[ -z "$BOTNAME" ] && error "Невалидный токен или нет доступа к Telegram API."
info "Бот найден: @$BOTNAME"
echo ""

# Admin IDs
echo "Введите Telegram ID администраторов (один или несколько через пробел)."
echo "Узнать свой ID: напиши @userinfobot в Telegram."
echo ""
prompt "Admin ID(s):"
read -r ADMIN_IDS
[ -z "$ADMIN_IDS" ] && error "Нужен хотя бы один admin ID."
echo ""

# Внешний IP — автоопределение
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

# Порт и протокол — читаем из server.conf автоматически
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

# ─── Установка файлов ─────────────────────────────────────────────────────────

info "Устанавливаем файлы..."
mkdir -p "$INSTALL_DIR" "$CLIENTS_DIR"
cp "$(dirname "$0")/bot.sh" "$INSTALL_DIR/bot.sh"
chmod +x "$INSTALL_DIR/bot.sh"

# ─── UCI конфиг ───────────────────────────────────────────────────────────────

info "Записываем конфиг..."

# Удаляем старый конфиг если есть — игнорируем ошибку
uci -q delete ovpnbot.main 2>/dev/null

uci set ovpnbot.main=ovpnbot
uci set ovpnbot.main.token="$BOT_TOKEN"
uci set ovpnbot.main.admin_ids="$ADMIN_IDS"
uci set ovpnbot.main.host="$SERVER_HOST"
uci set ovpnbot.main.port="$SERVER_PORT"
uci set ovpnbot.main.proto="$SERVER_PROTO"
uci commit ovpnbot || error "Не удалось записать UCI конфиг."

# ─── CRL ──────────────────────────────────────────────────────────────────────

if ! grep -q 'crl-verify' /etc/openvpn/server.conf; then
    info "Добавляем crl-verify в server.conf..."
    echo "crl-verify /etc/openvpn/pki/crl.pem" >> /etc/openvpn/server.conf
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
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
info "Напиши /start своему боту в Telegram."
