# 🔐 OpenVPN Bot for OpenWrt

> Telegram-бот для управления клиентами OpenVPN прямо с телефона — без терминала и SSH.

[![OpenWrt](https://img.shields.io/badge/OpenWrt-23.x%20%2F%20FriendlyWrt%2024-00b5e2?style=flat-square&logo=openwrt)](https://openwrt.org)
[![Shell](https://img.shields.io/badge/Shell-ash%20%2F%20sh-89e051?style=flat-square&logo=gnu-bash)](https://wiki.openwrt.org/doc/techref/ash)
[![License](https://img.shields.io/badge/License-MIT-green?style=flat-square)](LICENSE)
[![Telegram Bot API](https://img.shields.io/badge/Telegram%20Bot%20API-v7-2CA5E0?style=flat-square&logo=telegram)](https://core.telegram.org/bots/api)

---

## ✨ Возможности

| Функция | Описание |
|---|---|
| `/newclient` | Интерактивное создание клиента + отправка `.ovpn` файлом в чат |
| `/listclients` | Список всех активных клиентов |
| `/revoke` | Отзыв сертификата через inline-кнопки |
| 📎 Инструкция | После конфига автоматически отправляются ссылки на клиенты для всех платформ |
| 🔒 Авторизация | Доступ только по Telegram ID (один или несколько администраторов) |

## 📋 Требования

- **OpenWrt 23.x** или **FriendlyWrt 24** (тестировалось на NanoPi R5S)
- Пакеты: `openvpn-openssl`, `openvpn-easy-rsa`, `curl`
- Инициализированная PKI (`/etc/openvpn/pki/`)
- Поднятый OpenVPN сервер

## ⚡ Быстрый старт

```sh
cd /tmp
curl -L https://github.com/dontbass/openvpn-bot-openwrt/archive/refs/heads/main.tar.gz | tar xz
cd openvpn-bot-openwrt-main
sh install.sh
```

Установщик сам определит внешний IP, порт и протокол из `server.conf` и спросит только необходимое:

```
========================================
  OpenVPN Telegram Bot — Установка
========================================

[?] Telegram Bot Token: <токен от @BotFather>
[+] Бот найден: @your_bot_name

[?] Admin ID(s): 123456789
    (узнать свой ID: @userinfobot)

[?] Внешний IP/хост сервера [1.2.3.4]:
[?] Порт OpenVPN [1194]:
[?] Протокол (tcp/udp) [tcp]:

[+] Установка завершена!
```

## 💬 Команды бота

```
/start        — главное меню
/newclient    — создать нового клиента (интерактивно)
/listclients  — список активных клиентов
/revoke       — отозвать клиента (inline-кнопки)
/cancel       — отменить текущее действие
```

### Как выглядит создание клиента

```
Вы: /newclient
Бот: Введите имя нового клиента (латиница, цифры, дефис):
Вы: myphoneq
Бот: ⏳ Генерирую сертификат для myphoneq...
Бот: 📎 myphoneq.ovpn  [файл]
Бот: 📱 Как подключиться:
     • Android — OpenVPN for Android
     • iOS — OpenVPN Connect
     • Windows — OpenVPN Connect
     • macOS — Tunnelblick
     • Linux — sudo apt install openvpn
```

## 🛠 Управление

```sh
# Статус
/etc/init.d/ovpnbot status

# Перезапуск
/etc/init.d/ovpnbot restart

# Логи
tail -f /var/log/ovpnbot.log

# Обновление бота
curl -L https://raw.githubusercontent.com/dontbass/openvpn-bot-openwrt/main/bot.sh \
  -o /usr/share/ovpnbot/bot.sh && /etc/init.d/ovpnbot restart
```

## ⚙️ Конфигурация

Конфиг хранится в `/etc/ovpnbot.conf`:

```sh
TOKEN="your_bot_token"
ADMIN_IDS="123456789 987654321"  # несколько ID через пробел
HOST="1.2.3.4"
PORT="1194"
PROTO="tcp"
```

Изменить и применить:

```sh
vi /etc/ovpnbot.conf
/etc/init.d/ovpnbot restart
```

## 🗑 Удаление

```sh
/etc/init.d/ovpnbot stop
/etc/init.d/ovpnbot disable
rm -rf /usr/share/ovpnbot /etc/init.d/ovpnbot /etc/ovpnbot.conf
```

## 🏗 Как это работает

```
Telegram → Bot API (polling) → bot.sh → easyrsa → .ovpn файл → Bot API → вам в чат
```

Бот написан на чистом **POSIX sh + curl** — никаких зависимостей, работает на минимальной прошивке OpenWrt. Использует `procd` для автозапуска и автоматического перезапуска при падении.

## 📜 Лицензия

MIT — используйте свободно.
