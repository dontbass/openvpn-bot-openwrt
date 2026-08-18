#!/bin/sh
# openvpn-bot — Telegram bot for OpenVPN client management on OpenWrt
# https://github.com/your-username/openvpn-bot-openwrt

CONFIG="/etc/config/ovpnbot"
CLIENTS_DIR="/etc/openvpn/clients"
PKI_DIR="/etc/openvpn/pki"
STATE_DIR="/tmp/ovpnbot_state"
OFFSET_FILE="/tmp/ovpnbot_offset"
LOG="/var/log/ovpnbot.log"

mkdir -p "$STATE_DIR" "$CLIENTS_DIR"

# ─── Config helpers ───────────────────────────────────────────────────────────

get_cfg() {
    uci get ovpnbot.main.$1 2>/dev/null
}

TOKEN=$(get_cfg token)
ADMIN_IDS=$(get_cfg admin_ids)  # пробел-разделённый список
OPENVPN_HOST=$(get_cfg host)
OPENVPN_PORT=$(get_cfg port)
OPENVPN_PROTO=$(get_cfg proto)

API="https://api.telegram.org/bot$TOKEN"

# ─── Logging ──────────────────────────────────────────────────────────────────

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"
}

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
    curl -s "$API/getUpdates?offset=$offset&timeout=30&allowed_updates=message"
}

# ─── State machine ────────────────────────────────────────────────────────────

get_state() {
    local chat_id=$1
    cat "$STATE_DIR/$chat_id" 2>/dev/null || echo "idle"
}

set_state() {
    local chat_id=$1
    local state=$2
    echo "$state" > "$STATE_DIR/$chat_id"
}

clear_state() {
    local chat_id=$1
    rm -f "$STATE_DIR/$chat_id"
}

# ─── OpenVPN helpers ──────────────────────────────────────────────────────────

list_clients() {
    ls "$PKI_DIR/issued/" 2>/dev/null | grep -v '^server\.crt$' | sed 's/\.crt$//'
}

client_exists() {
    [ -f "$PKI_DIR/issued/$1.crt" ]
}

generate_client() {
    local name=$1
    cd /etc/openvpn || return 1
    easyrsa --batch build-client-full "$name" nopass 2>&1
}

build_ovpn() {
    local name=$1
    local out="$CLIENTS_DIR/$name.ovpn"

    cat > "$out" << OVPN
client
dev tun
proto $OPENVPN_PROTO
remote $OPENVPN_HOST $OPENVPN_PORT
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
    local name=$1
    cd /etc/openvpn || return 1
    easyrsa --batch revoke "$name" 2>&1
    easyrsa --batch gen-crl 2>&1
    cp "$PKI_DIR/crl.pem" "$PKI_DIR/crl.pem"
    rm -f "$CLIENTS_DIR/$name.ovpn"
}

# ─── Command handlers ─────────────────────────────────────────────────────────

cmd_start() {
    local chat_id=$1
    tg_send "$chat_id" "👋 *OpenVPN Manager*

Доступные команды:
/newclient — создать нового клиента
/listclients — список клиентов
/revoke — отозвать клиента
/help — помощь"
}

cmd_new_client() {
    local chat_id=$1
    set_state "$chat_id" "await_client_name"
    tg_send "$chat_id" "Введите имя нового клиента (латиница, цифры, дефис):"
}

cmd_list_clients() {
    local chat_id=$1
    local clients
    clients=$(list_clients)
    if [ -z "$clients" ]; then
        tg_send "$chat_id" "Нет активных клиентов."
    else
        local msg="*Активные клиенты:*"$'\n'
        for c in $clients; do
            msg="$msg• $c"$'\n'
        done
        tg_send "$chat_id" "$msg"
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

    # Строим inline keyboard
    local buttons=""
    for c in $clients; do
        if [ -n "$buttons" ]; then
            buttons="$buttons,"
        fi
        buttons="$buttons[{\"text\":\"$c\",\"callback_data\":\"revoke:$c\"}]"
    done
    local keyboard="{\"inline_keyboard\":[$buttons]}"

    tg_send_keyboard "$chat_id" "Выберите клиента для отзыва:" "$keyboard"
}

handle_await_name() {
    local chat_id=$1
    local name=$2

    # Валидация имени
    if ! echo "$name" | grep -qE '^[a-zA-Z0-9_-]{1,32}$'; then
        tg_send "$chat_id" "❌ Недопустимое имя. Только латиница, цифры, _ и -. Попробуйте ещё раз:"
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
        log "ERROR generate_client $name: $result"
        tg_send "$chat_id" "❌ Ошибка генерации сертификата. Смотри лог: $LOG"
        return
    fi

    local ovpn
    ovpn=$(build_ovpn "$name")
    tg_send_doc "$chat_id" "$ovpn" "✅ Конфиг клиента *$name*"
    log "INFO created client $name"
}

handle_revoke_confirm() {
    local chat_id=$1
    local name=$2

    tg_send "$chat_id" "⏳ Отзываю сертификат *$name*..."
    local result
    result=$(revoke_client "$name")
    if [ $? -ne 0 ]; then
        log "ERROR revoke $name: $result"
        tg_send "$chat_id" "❌ Ошибка отзыва. Смотри лог: $LOG"
        return
    fi
    tg_send "$chat_id" "✅ Клиент *$name* отозван."
    log "INFO revoked client $name"
}

# ─── Update processing ────────────────────────────────────────────────────────

process_message() {
    local chat_id=$1
    local from_id=$2
    local text=$3

    if ! is_admin "$from_id"; then
        tg_send "$chat_id" "⛔ Нет доступа."
        log "WARN unauthorized access from $from_id"
        return
    fi

    local state
    state=$(get_state "$chat_id")

    # Состояние — ожидаем имя клиента
    if [ "$state" = "await_client_name" ]; then
        # Отмена по команде
        if [ "$text" = "/cancel" ]; then
            clear_state "$chat_id"
            tg_send "$chat_id" "Отменено."
            return
        fi
        handle_await_name "$chat_id" "$text"
        return
    fi

    # Команды
    case "$text" in
        /start)       cmd_start "$chat_id" ;;
        /help)        cmd_start "$chat_id" ;;
        /newclient)   cmd_new_client "$chat_id" ;;
        /listclients) cmd_list_clients "$chat_id" ;;
        /revoke)      cmd_revoke_start "$chat_id" ;;
        /cancel)      tg_send "$chat_id" "Нечего отменять." ;;
        *)            tg_send "$chat_id" "Неизвестная команда. /help" ;;
    esac
}

process_callback() {
    local chat_id=$1
    local from_id=$2
    local data=$3
    local callback_id=$4

    # Подтверждаем callback
    curl -s -X POST "$API/answerCallbackQuery" -d "callback_query_id=$callback_id" > /dev/null

    if ! is_admin "$from_id"; then
        return
    fi

    case "$data" in
        revoke:*)
            local name="${data#revoke:}"
            handle_revoke_confirm "$chat_id" "$name"
            ;;
    esac
}

# ─── Main loop ────────────────────────────────────────────────────────────────

log "INFO bot started"

OFFSET=0
[ -f "$OFFSET_FILE" ] && OFFSET=$(cat "$OFFSET_FILE")

while true; do
    RESPONSE=$(tg_get_updates "$OFFSET")

    # Парсим update_id, тип, данные через grep/sed (без jq)
    echo "$RESPONSE" | grep -o '"update_id":[0-9]*' | while read -r upd; do
        UPDATE_ID=$(echo "$upd" | grep -o '[0-9]*')
        NEXT_OFFSET=$((UPDATE_ID + 1))
        echo "$NEXT_OFFSET" > "$OFFSET_FILE"
        OFFSET=$NEXT_OFFSET

        # Определяем тип апдейта
        BLOCK=$(echo "$RESPONSE" | grep -o "\"update_id\":$UPDATE_ID[^}]*}")

        # Callback query
        if echo "$RESPONSE" | grep -q '"callback_query"'; then
            CALLBACK_ID=$(echo "$RESPONSE" | grep -o '"id":"[^"]*"' | head -1 | grep -o '"[^"]*"$' | tr -d '"')
            FROM_ID=$(echo "$RESPONSE" | grep -o '"from":{[^}]*}' | head -2 | tail -1 | grep -o '"id":[0-9]*' | grep -o '[0-9]*')
            CHAT_ID=$(echo "$RESPONSE" | grep -o '"chat":{[^}]*}' | head -1 | grep -o '"id":[0-9]*' | grep -o '[0-9]*')
            DATA=$(echo "$RESPONSE" | grep -o '"data":"[^"]*"' | head -1 | sed 's/"data":"//;s/"//')
            process_callback "$CHAT_ID" "$FROM_ID" "$DATA" "$CALLBACK_ID"
        else
            # Обычное сообщение
            FROM_ID=$(echo "$RESPONSE" | grep -o '"from":{[^}]*}' | head -1 | grep -o '"id":[0-9]*' | grep -o '[0-9]*')
            CHAT_ID=$(echo "$RESPONSE" | grep -o '"chat":{[^}]*}' | head -1 | grep -o '"id":[0-9]*' | grep -o '[0-9]*')
            TEXT=$(echo "$RESPONSE" | grep -o '"text":"[^"]*"' | head -1 | sed 's/"text":"//;s/"$//')
            [ -n "$TEXT" ] && process_message "$CHAT_ID" "$FROM_ID" "$TEXT"
        fi
    done

    sleep 1
done
