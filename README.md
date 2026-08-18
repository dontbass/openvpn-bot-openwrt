# openvpn-bot-openwrt

Telegram бот для управления клиентами OpenVPN на роутере под OpenWrt / FriendlyWrt.

Написан на чистом `sh` + `curl` — без Python, Node.js, дополнительных пакетов.

## Возможности

- `/newclient` — интерактивное создание клиента, получение `.ovpn` файлом прямо в чат
- `/listclients` — список активных клиентов
- `/revoke` — отзыв клиента через inline-кнопки
- Авторизация по Telegram ID (один или несколько администраторов)

## Требования

- OpenWrt 23.x / FriendlyWrt 24
- Установленные пакеты: `openvpn-openssl`, `openvpn-easy-rsa`, `curl`
- Инициализированная PKI (`/etc/openvpn/pki/ca.crt`, `ta.key`)

## Быстрый старт

```sh
cd /tmp
curl -L https://github.com/dontbass/openvpn-bot-openwrt/archive/refs/heads/main.tar.gz | tar xz
cd openvpn-bot-openwrt-main
sh install.sh
```

Установщик спросит:
- **Bot Token** — токен от @BotFather
- **Admin ID(s)** — Telegram ID администраторов (через пробел, если несколько). Узнать свой ID: @userinfobot
- **Внешний IP/хост** — определяется автоматически, можно изменить
- **Порт и протокол** — считываются из `server.conf` автоматически

## Команды бота

| Команда | Описание |
|---|---|
| `/start` | Главное меню |
| `/newclient` | Создать нового клиента (интерактивно) |
| `/listclients` | Список активных клиентов |
| `/revoke` | Отозвать клиента (inline-кнопки) |
| `/cancel` | Отменить текущее действие |

## Управление сервисом

```sh
/etc/init.d/ovpnbot status
/etc/init.d/ovpnbot restart
/etc/init.d/ovpnbot stop

# Логи
tail -f /var/log/ovpnbot.log
```

## Конфиг

Хранится в UCI `/etc/config/ovpnbot`. Изменить вручную:

```sh
uci set ovpnbot.main.admin_ids="123456789 987654321"
uci commit ovpnbot
/etc/init.d/ovpnbot restart
```

## Удаление

```sh
/etc/init.d/ovpnbot stop
/etc/init.d/ovpnbot disable
rm -rf /usr/share/ovpnbot /etc/init.d/ovpnbot
uci delete ovpnbot
uci commit ovpnbot
```
