#!/bin/sh
# openvpn-bot — Telegram bot for OpenVPN client management on OpenWrt

CONFIG_FILE="/etc/ovpnbot.conf"
CLIENTS_DIR="/etc/openvpn/clients"
PKI_DIR="/etc/openvpn/pki"
STATE_DIR="/tmp/ovpnbot_state"
OFFSET_FILE="/tmp/ovpnbot_offset"
LOG="/var/log/ovpnbot.log"

mkdir -p "$STATE_DIR" "$CLIENTS_DIR"

# ─── Загрузка конфига ─────────────────────────────────────────────────────────

[ -f "$CONFIG_FILE" ] || { echo "Config not found: $CONFIG_FILE"; exit 1; }
. "$CONFIG_FILE"

API="https://api.telegram.org/bot$TOKEN"

# ─── Logging ──────────────────────────────────────────────────────────────────

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

# ─── Auth ─────────────────────────────────────────────────────────────────────

is_admin() {
    local id=$1
    for admin in $ADMIN_IDS; do
        [ "$admin" = "$id" ] && return 0
    done
    return 1
}

# ─── Telegram API ─────────────────────────────────────────────────────────────

tg_send() {
    local chat_id=$1
    local text=$2
    curl -s -X POST "$API/sendMessage" \
        -d "chat_id=$chat_id" \
        --data-urlencode "text=$text" \
        -d "parse_mode=Markdown" > /dev/null
}

tg_send_doc() {
    local chat_id=$1
    local file=$2
    local caption=$3
    curl -s -X POST "$API/sendDocument" \
        -F "chat_id=$chat_id" \
        -F "document=@$file" \
        -F "caption=$caption" > /dev/null
}

tg_send_keyboard() {
    local chat_id=$1
    local text=$2
    local keyboard=$3
    curl -s -X POST "$API/sendMessage" \
        -d "chat_id=$chat_id" \
        --data-urlencode "text=$text" \
        -d "parse_mode=Markdown" \
        -d "reply_markup=$keyboard" > /dev/null
}

tg_get_updates() {
    local offset=$1
    curl -s "$API/getUpdates?offset=$offset&timeout=30"
}

tg_answer_callback() {
    local id=$1
    curl -s -X POST "$API/answerCallbackQuery" -d "callback_query_id=$id" > /dev/null
}

# ─── State machine ────────────────────────────────────────────────────────────

get_state() { cat "$STATE_DIR/$1" 2>/dev/null || echo "idle"; }
set_state()  { echo "$2" > "$STATE_DIR/$1"; }
clear_state(){ rm -f "$STATE_DIR/$1"; }

# ─── OpenVPN helpers ──────────────────────────────────────────────────────────

list_clients() {
    ls "$PKI_DIR/issued/" 2>/dev/null | grep -v '^server\.crt$' | sed 's/\.crt$//'
}

client_exists() { [ -f "$PKI_DIR/issued/$1.crt" ]; }

generate_client() {
    cd /etc/openvpn || return 1
    easyrsa --batch build-client-full "$1" nopass 2>&1
}

build_ovpn() {
    local name=$1
    local out="$CLIENTS_DIR/$name.ovpn"
    cat > "$out" << OVPN
client
dev tun
proto $PROTO
remote $HOST $PORT
resolv-retry infinite
nobind
persist-key
persist-tun
cipher AES-256-GCM
auth SHA256
key-direction 1
verb 3
<ca>
$(cat "$PKI_DIR/ca.crt")
</ca>
<cert>
$(openssl x509 -in "$PKI_DIR/issued/$name.crt")
</cert>
<key>
$(cat "$PKI_DIR/private/$name.key")
</key>
<tls-auth>
$(cat "$PKI_DIR/ta.key")
</tls-auth>
OVPN
    echo "$out"
}

revoke_client() {
    cd /etc/openvpn || return 1
    easyrsa --batch revoke "$1" 2>&1
    easyrsa --batch gen-crl 2>&1
    rm -f "$CLIENTS_DIR/$1.ovpn"
}

# ─── Handlers ─────────────────────────────────────────────────────────────────

cmd_start() {
    tg_send "$1" "👋 *OpenVPN Manager*

/newclient — создать клиента
/listclients — список клиентов
/revoke — отозвать клиента"
}

cmd_new_client() {
    set_state "$1" "await_client_name"
    tg_send "$1" "Введите имя нового клиента (латиница, цифры, дефис):"
}

cmd_list_clients() {
    local clients
    clients=$(list_clients)
    if [ -z "$clients" ]; then
        tg_send "$1" "Нет активных клиентов."
    else
        local msg="*Активные клиенты:*"$'\n'
        for c in $clients; do msg="$msg• $c"$'\n'; done
        tg_send "$1" "$msg"
    fi
}

cmd_revoke_start() {
    local chat_id=$1
    local clients
    clients=$(list_clients)
    if [ -z "$clients" ]; then
        tg_send "$chat_id" "Нет клиентов для отзыва."
        return
    fi
    local buttons=""
    for c in $clients; do
        [ -n "$buttons" ] && buttons="$buttons,"
        buttons="$buttons[{\"text\":\"❌ $c\",\"callback_data\":\"revoke:$c\"}]"
    done
    tg_send_keyboard "$chat_id" "Выберите клиента для отзыва:" \
        "{\"inline_keyboard\":[$buttons]}"
}

handle_await_name() {
    local chat_id=$1
    local name=$2

    if ! echo "$name" | grep -qE '^[a-zA-Z0-9_-]{1,32}$'; then
        tg_send "$chat_id" "❌ Только латиница, цифры, _ и -. Попробуйте ещё раз:"
        return
    fi
    if client_exists "$name"; then
        tg_send "$chat_id" "❌ Клиент *$name* уже существует. Введите другое имя:"
        return
    fi

    clear_state "$chat_id"
    tg_send "$chat_id" "⏳ Генерирую сертификат для *$name*..."

    local result
    result=$(generate_client "$name")
    if [ $? -ne 0 ]; then
        log "ERROR generate $name: $result"
        tg_send "$chat_id" "❌ Ошибка генерации. Смотри лог: $LOG"
        return
    fi

    local ovpn
    ovpn=$(build_ovpn "$name")
    tg_send_doc "$chat_id" "$ovpn" "✅ Конфиг клиента: $name"
    log "INFO created client $name"
}

handle_revoke() {
    local chat_id=$1
    local name=$2
    tg_send "$chat_id" "⏳ Отзываю *$name*..."
    local result
    result=$(revoke_client "$name")
    if [ $? -ne 0 ]; then
        log "ERROR revoke $name: $result"
        tg_send "$chat_id" "❌ Ошибка отзыва."
        return
    fi
    tg_send "$chat_id" "✅ Клиент *$name* отозван."
    log "INFO revoked client $name"
}

# ─── Обработка сообщений ──────────────────────────────────────────────────────

process_message() {
    local chat_id=$1 from_id=$2 text=$3

    if ! is_admin "$from_id"; then
        tg_send "$chat_id" "⛔ Нет доступа."
        log "WARN unauthorized from $from_id"
        return
    fi

    local state
    state=$(get_state "$chat_id")

    if [ "$state" = "await_client_name" ]; then
        if [ "$text" = "/cancel" ]; then
            clear_state "$chat_id"
            tg_send "$chat_id" "Отменено."
        else
            handle_await_name "$chat_id" "$text"
        fi
        return
    fi

    case "$text" in
        /start|/help)   cmd_start "$chat_id" ;;
        /newclient)     cmd_new_client "$chat_id" ;;
        /listclients)   cmd_list_clients "$chat_id" ;;
        /revoke)        cmd_revoke_start "$chat_id" ;;
        /cancel)        tg_send "$chat_id" "Нечего отменять." ;;
        *)              tg_send "$chat_id" "Неизвестная команда. /help" ;;
    esac
}

process_callback() {
    local chat_id=$1 from_id=$2 data=$3 cb_id=$4
    tg_answer_callback "$cb_id"
    is_admin "$from_id" || return
    case "$data" in
        revoke:*) handle_revoke "$chat_id" "${data#revoke:}" ;;
    esac
}

# ─── Main loop ────────────────────────────────────────────────────────────────

log "INFO bot started (host=$HOST port=$PORT proto=$PROTO)"

OFFSET=0
[ -f "$OFFSET_FILE" ] && OFFSET=$(cat "$OFFSET_FILE")

while true; do
    RESP=$(tg_get_updates "$OFFSET")

    # Парсим каждый update по update_id
    echo "$RESP" | grep -o '"update_id":[0-9]*' | grep -o '[0-9]*' | while read -r UID; do
        NEXT=$((UID + 1))
        echo "$NEXT" > "$OFFSET_FILE"

        # Определяем тип: callback_query или message
        if echo "$RESP" | grep -q '"callback_query"'; then
            CB_ID=$(echo "$RESP" | grep -o '"id":"[0-9]*"' | head -1 | grep -o '[0-9]*')
            FROM_ID=$(echo "$RESP" | grep -o '"from":{"id":[0-9]*' | head -2 | tail -1 | grep -o '[0-9]*')
            CHAT_ID=$(echo "$RESP" | grep -o '"chat":{"id":[0-9]*' | head -1 | grep -o '[0-9]*' | head -1)
            DATA=$(echo "$RESP" | grep -o '"data":"[^"]*"' | head -1 | sed 's/"data":"//;s/"$//')
            process_callback "$CHAT_ID" "$FROM_ID" "$DATA" "$CB_ID"
        else
            FROM_ID=$(echo "$RESP" | grep -o '"from":{"id":[0-9]*' | head -1 | grep -o '[0-9]*')
            CHAT_ID=$(echo "$RESP" | grep -o '"chat":{"id":[0-9]*' | head -1 | grep -o '[0-9]*')
            TEXT=$(echo "$RESP" | grep -o '"text":"[^"]*"' | head -1 | sed 's/"text":"//;s/"$//')
            [ -n "$TEXT" ] && process_message "$CHAT_ID" "$FROM_ID" "$TEXT"
        fi
    done

    OFFSET=$(cat "$OFFSET_FILE" 2>/dev/null || echo "$OFFSET")
    sleep 1
done
