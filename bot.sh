#!/bin/sh
# openvpn-bot — Telegram bot for OpenVPN client management on OpenWrt

CONFIG_FILE="/etc/ovpnbot.conf"
CLIENTS_DIR="/etc/openvpn/clients"
PKI_DIR="/etc/openvpn/pki"
STATE_DIR="/tmp/ovpnbot_state"
OFFSET_FILE="/tmp/ovpnbot_offset"
LOG="/var/log/ovpnbot.log"
TMP_UPD="/tmp/ovpnbot_update.json"

mkdir -p "$STATE_DIR" "$CLIENTS_DIR"

[ -f "$CONFIG_FILE" ] || { echo "Config not found: $CONFIG_FILE"; exit 1; }
. "$CONFIG_FILE"

API="https://api.telegram.org/bot$TOKEN"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

is_admin() {
    for admin in $ADMIN_IDS; do [ "$admin" = "$1" ] && return 0; done
    return 1
}

tg_send() {
    curl -s -X POST "$API/sendMessage" \
        -d "chat_id=$1" \
        --data-urlencode "text=$2" \
        -d "parse_mode=Markdown" > /dev/null
}

tg_send_doc() {
    curl -s -X POST "$API/sendDocument" \
        -F "chat_id=$1" \
        -F "document=@$2" \
        -F "caption=$3" > /dev/null
}

tg_send_keyboard() {
    curl -s -X POST "$API/sendMessage" \
        -d "chat_id=$1" \
        --data-urlencode "text=$2" \
        -d "parse_mode=Markdown" \
        -d "reply_markup=$3" > /dev/null
}

tg_answer_cb() {
    curl -s -X POST "$API/answerCallbackQuery" -d "callback_query_id=$1" > /dev/null
}

get_state()  { cat "$STATE_DIR/$1" 2>/dev/null || echo "idle"; }
set_state()  { echo "$2" > "$STATE_DIR/$1"; }
clear_state(){ rm -f "$STATE_DIR/$1"; }

list_clients() {
    ls "$PKI_DIR/issued/" 2>/dev/null | grep -v '^server\.crt$' | sed 's/\.crt$//'
}

client_exists() { [ -f "$PKI_DIR/issued/$1.crt" ]; }

generate_client() {
    cd /etc/openvpn || return 1
    easyrsa --batch build-client-full "$1" nopass 2>&1
    return $?
}

build_ovpn() {
    local name=$1 out="$CLIENTS_DIR/$name.ovpn"
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

cmd_start() {
    tg_send "$1" "👋 *OpenVPN Manager*

/newclient — создать клиента
/getclient — получить конфиг повторно
/listclients — список клиентов
/revoke — отозвать клиента"
}

cmd_new_client() {
    set_state "$1" "await_name"
    tg_send "$1" "Введите имя нового клиента (латиница, цифры, дефис, подчёркивание):"
}

cmd_list_clients() {
    local clients msg c
    clients=$(list_clients)
    if [ -z "$clients" ]; then
        tg_send "$1" "Нет активных клиентов."
    else
        msg="*Активные клиенты:*"$'\n'
        for c in $clients; do msg="${msg}• $c"$'\n'; done
        tg_send "$1" "$msg"
    fi
}

cmd_get_client() {
    local chat_id=$1
    local clients buttons c kb
    clients=$(list_clients)
    if [ -z "$clients" ]; then
        tg_send "$chat_id" "Нет активных клиентов."; return
    fi
    buttons=""
    for c in $clients; do
        [ -n "$buttons" ] && buttons="$buttons,"
        buttons="${buttons}[{\"text\":\"📄 $c\",\"callback_data\":\"getclient:$c\"}]"
    done
    kb="{\"inline_keyboard\":[$buttons]}"
    tg_send_keyboard "$chat_id" "Выберите клиента для получения конфига:" "$kb"
}

cmd_revoke_start() {
    local clients buttons c kb
    clients=$(list_clients)
    if [ -z "$clients" ]; then
        tg_send "$1" "Нет клиентов для отзыва."; return
    fi
    buttons=""
    for c in $clients; do
        [ -n "$buttons" ] && buttons="$buttons,"
        buttons="${buttons}[{\"text\":\"❌ $c\",\"callback_data\":\"revoke:$c\"}]"
    done
    kb="{\"inline_keyboard\":[$buttons]}"
    tg_send_keyboard "$1" "Выберите клиента для отзыва:" "$kb"
}

handle_name() {
    local chat_id=$1 name=$2
    if ! echo "$name" | grep -qE '^[a-zA-Z0-9_-]{1,32}$'; then
        tg_send "$chat_id" "❌ Только латиница, цифры, _ и -. Попробуйте ещё раз:"
        return
    fi
    if client_exists "$name"; then
        tg_send "$chat_id" "❌ Клиент *$name* уже существует. Другое имя:"
        return
    fi
    clear_state "$chat_id"
    tg_send "$chat_id" "⏳ Генерирую сертификат для *$name*..."
    local res ret ovpn
    res=$(generate_client "$name"); ret=$?
    if [ $ret -ne 0 ]; then
        log "ERROR generate $name: $res"
        tg_send "$chat_id" "❌ Ошибка генерации. Лог: $LOG"
        return
    fi
    ovpn=$(build_ovpn "$name")
    tg_send_doc "$chat_id" "$ovpn" "✅ $name.ovpn"
    tg_send "$chat_id" "📱 *Как подключиться:*

1️⃣ Установите OpenVPN клиент:
• *Android* — [OpenVPN for Android](https://play.google.com/store/apps/details?id=de.blinkt.openvpn)
• *iOS* — [OpenVPN Connect](https://apps.apple.com/app/openvpn-connect/id590379981)
• *Windows* — [OpenVPN Connect](https://openvpn.net/client/client-connect-vpn-for-windows/)
• *macOS* — [Tunnelblick](https://tunnelblick.net/downloads.html)
• *Linux* — \`sudo apt install openvpn\`

2️⃣ Откройте приложение → импортируйте файл \`$name.ovpn\`

3️⃣ Нажмите *Подключить*"
    log "INFO created $name"
}

handle_send_config() {
    local chat_id=$1 name=$2 ovpn
    # Если .ovpn файл уже есть — шлём сразу, иначе перестраиваем
    if [ ! -f "$CLIENTS_DIR/$name.ovpn" ]; then
        if ! client_exists "$name"; then
            tg_send "$chat_id" "❌ Клиент *$name* не найден."; return
        fi
        ovpn=$(build_ovpn "$name")
    else
        ovpn="$CLIENTS_DIR/$name.ovpn"
    fi
    tg_send_doc "$chat_id" "$ovpn" "📄 $name.ovpn"
    tg_send "$chat_id" "📱 *Как подключиться:*

1️⃣ Установите OpenVPN клиент:
• *Android* — [OpenVPN for Android](https://play.google.com/store/apps/details?id=de.blinkt.openvpn)
• *iOS* — [OpenVPN Connect](https://apps.apple.com/app/openvpn-connect/id590379981)
• *Windows* — [OpenVPN Connect](https://openvpn.net/client/client-connect-vpn-for-windows/)
• *macOS* — [Tunnelblick](https://tunnelblick.net/downloads.html)
• *Linux* — \`sudo apt install openvpn\`

2️⃣ Откройте приложение → импортируйте файл \`$name.ovpn\`

3️⃣ Нажмите *Подключить*"
    log "INFO resent config $name"
}

handle_revoke() {
    local chat_id=$1 name=$2 res ret
    tg_send "$chat_id" "⏳ Отзываю *$name*..."
    res=$(revoke_client "$name"); ret=$?
    if [ $ret -ne 0 ]; then
        log "ERROR revoke $name: $res"
        tg_send "$chat_id" "❌ Ошибка отзыва."
        return
    fi
    tg_send "$chat_id" "✅ Клиент *$name* отозван."
    log "INFO revoked $name"
}

process_message() {
    local chat_id=$1 from_id=$2 text=$3 state

    if ! is_admin "$from_id"; then
        tg_send "$chat_id" "⛔ Нет доступа."
        log "WARN unauthorized $from_id"
        return
    fi

    state=$(get_state "$chat_id")
    if [ "$state" = "await_name" ]; then
        if [ "$text" = "/cancel" ]; then
            clear_state "$chat_id"; tg_send "$chat_id" "Отменено."
        else
            handle_name "$chat_id" "$text"
        fi
        return
    fi

    case "$text" in
        /start|/help)  cmd_start "$chat_id" ;;
        /newclient)    cmd_new_client "$chat_id" ;;
        /getclient)    cmd_get_client "$chat_id" ;;
        /listclients)  cmd_list_clients "$chat_id" ;;
        /revoke)       cmd_revoke_start "$chat_id" ;;
        /cancel)       tg_send "$chat_id" "Нечего отменять." ;;
        *)             tg_send "$chat_id" "Неизвестная команда. /help" ;;
    esac
}

process_callback() {
    local chat_id=$1 from_id=$2 data=$3 cb_id=$4
    tg_answer_cb "$cb_id"
    is_admin "$from_id" || return
    case "$data" in
        revoke:*)    handle_revoke "$chat_id" "${data#revoke:}" ;;
        getclient:*) handle_send_config "$chat_id" "${data#getclient:}" ;;
    esac
}

# Парсинг одного поля из JSON (без jq)
json_get() {
    echo "$1" | grep -o "\"$2\":[^,}]*" | head -1 | sed "s/\"$2\"://;s/\"//g;s/^ //;s/ $//"
}

json_get_str() {
    echo "$1" | grep -o "\"$2\":\"[^\"]*\"" | head -1 | sed "s/\"$2\":\"//;s/\"$//"
}

# ─── Main loop (без subshell) ─────────────────────────────────────────────────

log "INFO bot started (host=$HOST port=$PORT proto=$PROTO)"

OFFSET=0
[ -f "$OFFSET_FILE" ] && OFFSET=$(cat "$OFFSET_FILE")

while true; do
    # Сохраняем ответ в файл чтобы избежать subshell
    curl -s "$API/getUpdates?offset=$OFFSET&timeout=25" > "$TMP_UPD" 2>/dev/null

    # Читаем update_id'ы построчно из файла
    grep -o '"update_id":[0-9]*' "$TMP_UPD" | grep -o '[0-9]*' > /tmp/ovpnbot_ids

    while read -r UID; do
        OFFSET=$((UID + 1))
        echo "$OFFSET" > "$OFFSET_FILE"

        # Извлекаем блок апдейта
        UPD=$(cat "$TMP_UPD")

        # Callback query?
        if echo "$UPD" | grep -q '"callback_query"'; then
            CB_ID=$(echo "$UPD" | grep -o '"callback_query":{"id":"[^"]*"' | grep -o '"id":"[^"]*"' | grep -o '[0-9]*')
            FROM_ID=$(echo "$UPD" | grep -o '"callback_query":{[^}]*"from":{"id":[0-9]*' | grep -o '"from":{"id":[0-9]*' | grep -o '[0-9]*$')
            CHAT_ID=$(echo "$UPD" | grep -o '"message":{"message_id":[^}]*"chat":{"id":[^,}]*' | grep -o '"chat":{"id":[^,]*' | grep -o '[-0-9]*$')
            DATA=$(echo "$UPD" | grep -o '"data":"[^"]*"' | head -1 | sed 's/"data":"//;s/"$//')
            log "DEBUG callback from=$FROM_ID chat=$CHAT_ID data=$DATA"
            process_callback "$CHAT_ID" "$FROM_ID" "$DATA" "$CB_ID"
        else
            FROM_ID=$(echo "$UPD" | grep -o '"from":{"id":[0-9]*' | head -1 | grep -o '[0-9]*$')
            CHAT_ID=$(echo "$UPD" | grep -o '"chat":{"id":[^,]*' | head -1 | grep -o '[-0-9]*$')
            TEXT=$(echo "$UPD" | grep -o '"text":"[^"]*"' | head -1 | sed 's/"text":"//;s/"$//')
            log "DEBUG message from=$FROM_ID chat=$CHAT_ID text=$TEXT"
            [ -n "$TEXT" ] && process_message "$CHAT_ID" "$FROM_ID" "$TEXT"
        fi
    done < /tmp/ovpnbot_ids

    sleep 1
done
