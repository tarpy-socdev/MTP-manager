# 🚀 MTP-manager — Менеджер MTProto прокси

![Shell Script](https://img.shields.io/badge/Shell_Script-121011?logo=gnu-bash&logoColor=white)
![License](https://img.shields.io/badge/License-MIT-blue)
![Platform](https://img.shields.io/badge/Platform-Debian%20%7C%20Ubuntu-orange)
![Version](https://img.shields.io/badge/Stable-version-brightgreen)

Установка и управление MTProto прокси для Telegram в одну команду.  
Компиляция, systemd, каскад, статистика — всё автоматически.

---

## ✨ Возможности

- 🛠 **Простая установка** — компиляция из исходников, настройка systemd, UFW
- 🛡 **Защита от обрыва SSH** — автозапуск установки в `screen`, переподключение через `screen -r mtproto`
- 📡 **Статистика подключений** — уникальные клиенты по IP, TCP-соединения, трафик интерфейса
- 🔀 **Каскад (relay)** — пустить трафик через второй сервер с помощью `socat`
- 🔑 **Смена секрета** — генерация нового секрета и обновление ссылки одной кнопкой

---

## 📦 Установка

```bash
curl -fsSL https://raw.githubusercontent.com/tarpy-socdev/MTP-manager/refs/heads/main/mtproto-universal.sh -o mtproto-universal.sh
chmod +x mtproto-universal.sh
sudo ./mtproto-universal.sh
```

После установки скрипт доступен как системная команда:

```bash
sudo mtproto-manager
```

---

## 🖥 Меню

```
 📊 УПРАВЛЕНИЕ:
  1) 📈 Статус сервиса
  2) 📡 Активные подключения
  3) 🔗 Ссылка для подключения
  4) 🔧 Изменить порт
  5) 🔑 Сменить секрет
  6) 🔄 Перезапустить сервис
  7) 📝 Логи

 🌐 КАСКАД:
  8) 🔀 Настроить цепочку через другой сервер
  9) ❌ Отключить цепочку

 ⚙️  ПРОЧЕЕ:
 10) 🔃 Переустановить
 11) 🗑️  Удалить всё
```

---

## 🔀 Каскад

Трафик клиентов идёт через этот сервер на второй, где работает MTProxy.  
Клиент видит только первый сервер, Telegram — IP второго.

```
Клиент → [Сервер 1 : relay] → [Сервер 2 : MTProxy] → Telegram
```

**Как настроить:**

1. Установи MTProxy на второй сервер этим же скриптом
2. На первом сервере: меню → пункт `8`
3. Введи IP, порт и секрет **второго** сервера

Скрипт выдаст готовую ссылку. Когда каскад активен — пункт `3` автоматически показывает ссылку каскада.

> Секрет в ссылке берётся от второго сервера — это правильно.  
> Клиент делает MTProto-хэндшейк с удалённым сервером через TCP-туннель.

---

## ⚙️ Требования

- Debian / Ubuntu
- Bash ≥ 4.0
- Root-права

---

## 🔧 Полезные команды

```bash
# Статус
systemctl status mtproto-proxy

# Логи в реальном времени
journalctl -u mtproto-proxy -f

# Логи каскада
journalctl -u mtproto-relay -f

# Переподключиться к установке после обрыва SSH
screen -r mtproto
```

---

## 📄 Лицензия

MIT License © 2026
