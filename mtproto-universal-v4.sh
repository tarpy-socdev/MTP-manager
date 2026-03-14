#!/bin/bash
# ==============================================
# MTProto Proxy — Universal Manager v5.1
# Установка + Менеджер в одном скрипте
# github.com/tarpy-socdev/MTP-manager
# ==============================================

# ============ ЦВЕТА И СТИЛИ ============
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'
BOLD=$'\033[1m'
NC=$'\033[0m'

# ============ ПЕРЕМЕННЫЕ ============
INSTALL_DIR="/opt/MTProxy"
SERVICE_FILE="/etc/systemd/system/mtproto-proxy.service"
RELAY_SERVICE_FILE="/etc/systemd/system/mtproto-relay.service"
RELAY_INFO_FILE="/opt/MTProxy/.relay_info"
LOGFILE="/tmp/mtproto-install.log"
MANAGER_LINK="/usr/local/bin/mtproto-manager"
CRON_TAG="mtproto-config-update"

# ============ УТИЛИТЫ ============

err() {
    echo -e "\n${RED}[✗] ОШИБКА:${NC} $1\n" >&2
    read -rp " Нажми Enter для возврата... "
    return 1
}

fatal() {
    echo -e "\n${RED}[✗] КРИТИЧЕСКАЯ ОШИБКА:${NC} $1\n" >&2
    exit 1
}

success() { echo -e "${GREEN}[✓]${NC} $1"; }
info()    { echo -e "${CYAN}[ℹ]${NC} $1"; }
warning() { echo -e "${YELLOW}[⚠]${NC} $1"; }

header() {
    clear
    echo -e "${CYAN}${BOLD}"
    echo " ╔════════════════════════════════════════════╗"
    echo " ║  MTProto Proxy Manager v5.1                ║"
    echo " ║  github.com/tarpy-socdev/MTP-manager       ║"
    echo " ╚════════════════════════════════════════════╝"
    echo -e "${NC}"
}

spinner() {
    local pid=$1 msg=$2
    local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0
    while kill -0 "$pid" 2>/dev/null; do
        i=$(( (i+1) % 10 ))
        printf "\r ${CYAN}${spin:$i:1}${NC} %s" "$msg"
        sleep 0.1
    done
    if wait "$pid"; then
        printf "\r ${GREEN}✓${NC} %s\n" "$msg"
    else
        printf "\r ${RED}✗${NC} %s\n" "$msg"
        return 1
    fi
}

press_enter() {
    echo ""
    read -rp " Нажми Enter для возврата в меню... "
}

validate_port() {
    local port=$1
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

port_is_free() {
    ! ss -tuln 2>/dev/null | grep -q ":${1} "
}

get_public_ip() {
    local ip
    ip=$(curl -sf --max-time 4 https://api.ipify.org  2>/dev/null) && { echo "$ip"; return; }
    ip=$(curl -sf --max-time 4 https://ifconfig.me    2>/dev/null) && { echo "$ip"; return; }
    ip=$(curl -sf --max-time 4 https://icanhazip.com  2>/dev/null) && { echo "$ip"; return; }
    hostname -I | awk '{print $1}'
}

# ============================================================
# ЗАЩИТА ОТ ОБРЫВА SSH ВО ВРЕМЯ УСТАНОВКИ
# Если не запущен в screen/tmux — предлагаем перезапустить
# в screen. При обрыве SSH можно вернуться: screen -r mtproto
# ============================================================
ensure_screen_session() {
    # Уже внутри screen или tmux — всё ок
    [ -n "$STY" ] || [ -n "$TMUX" ] && return 0

    echo ""
    echo -e " ${YELLOW}${BOLD}⚠️  ВНИМАНИЕ: SSH без защиты от обрыва${NC}"
    echo ""
    echo " Установка занимает 3-7 минут. Если SSH-соединение"
    echo " оборвётся — придётся начинать заново."
    echo ""
    echo "  1) Запустить в screen (рекомендуется)"
    echo "  2) Продолжить без screen (на свой риск)"
    echo ""
    read -rp " Выбор [1-2, Enter=1]: " sc_choice

    if [ "${sc_choice:-1}" != "2" ]; then
        if ! command -v screen &>/dev/null; then
            info "Устанавливаем screen..."
            apt-get install -y screen >/dev/null 2>&1 \
                || { warning "Не удалось установить screen — продолжаем без него"; return 0; }
            success "screen установлен"
        fi
        local script_path
        script_path=$(readlink -f "$0" 2>/dev/null || echo "$0")
        echo ""
        echo -e " ${GREEN}Перезапускаем в screen...${NC}"
        echo -e " ${YELLOW}Если SSH пропадёт — переподключись и выполни:${NC}"
        echo -e " ${BOLD}  screen -r mtproto${NC}"
        echo ""
        sleep 2
        exec screen -S mtproto bash "$script_path"
    fi
}

# ============ СТАТУС ============
# 0 — работает, 1 — установлен но стоп, 2 — не установлен
proxy_status() {
    if [ ! -f "$SERVICE_FILE" ]; then echo 2; return; fi
    systemctl is-active --quiet mtproto-proxy 2>/dev/null && echo 0 || echo 1
}

status_label() {
    case "$(proxy_status)" in
        0) echo -e "${GREEN}✅ РАБОТАЕТ${NC}" ;;
        1) echo -e "${RED}❌ ОСТАНОВЛЕН${NC}" ;;
        2) echo -e "${YELLOW}⚠️  НЕ УСТАНОВЛЕН${NC}" ;;
    esac
}

relay_active() {
    [ -f "$RELAY_SERVICE_FILE" ] && systemctl is-active --quiet mtproto-relay 2>/dev/null
}

# ============ ЧТЕНИЕ КОНФИГА ============

read_service_param() {
    grep -oP "$1" "$SERVICE_FILE" 2>/dev/null | head -1
}

get_proxy_port()    { read_service_param '(?<=-H )\d+'; }
get_internal_port() { read_service_param '(?<=-p )\d+'; }
get_secret()        { read_service_param '(?<=-S )\S+'; }
get_run_user()      { grep "^User=" "$SERVICE_FILE" 2>/dev/null | cut -d'=' -f2; }

# ============ ГЛАВНОЕ МЕНЮ ============

show_main_menu() {
    local st
    while true; do
        st=$(proxy_status)
        header
        echo -e " Прокси: $(status_label)"
        relay_active && echo -e " Каскад: ${GREEN}✅ АКТИВЕН${NC}" || true
        echo ""
        echo -e " ${CYAN}${BOLD}═════════════════════════════════════════════${NC}"
        echo ""

        if [ "$st" -eq 2 ]; then
            echo -e " ${BOLD}⚡ ПЕРВЫЙ ЗАПУСК:${NC}"
            echo "  1) 📦 Установить прокси"
            echo ""
        else
            echo -e " ${BOLD}📊 УПРАВЛЕНИЕ:${NC}"
            echo "  1) 📈 Статус сервиса"
            echo "  2) 📡 Активные подключения"
            echo "  3) 🔗 Ссылка для подключения"
            echo "  4) 🔧 Изменить порт"
            echo "  5) 🔑 Сменить секрет (обновить ссылку)"
            echo "  6) 🔄 Перезапустить сервис"
            echo "  7) 📝 Логи"
            echo ""
            echo -e " ${BOLD}🌐 КАСКАД:${NC}"
            echo "  8) 🔀 Настроить цепочку через другой сервер"
            echo "  9) ❌ Отключить цепочку"
            echo ""
            echo -e " ${BOLD}⚙️  ПРОЧЕЕ:${NC}"
            echo " 10) 🔃 Переустановить"
            echo " 11) 🗑️  Удалить всё"
            echo ""
        fi

        echo "  0) 🚪 Выход"
        echo ""
        echo -e " ${CYAN}${BOLD}═════════════════════════════════════════════${NC}"
        echo ""
        read -rp " Выбери опцию: " choice

        case "$st:$choice" in
            "2:1") run_installer ;;
            "2:0") echo -e "${GREEN}До свидания! 👋${NC}"; exit 0 ;;
            "2:"*) warning "Сначала установи прокси (1)"; sleep 1 ;;
            *:1)   action_show_status ;;
            *:2)   action_show_stats ;;
            *:3)   action_show_link ;;
            *:4)   action_change_port ;;
            *:5)   action_rotate_secret ;;
            *:6)   action_restart ;;
            *:7)   action_show_logs ;;
            *:8)   action_cascade_setup ;;
            *:9)   action_cascade_remove ;;
            *:10)  action_reinstall ;;
            *:11)  action_uninstall ;;
            *:0)   echo -e "${GREEN}До свидания! 👋${NC}"; exit 0 ;;
            *)     warning "Неправильный выбор"; sleep 1 ;;
        esac
    done
}

# ============ ДЕЙСТВИЯ МЕНЕДЖЕРА ============

action_show_status() {
    header
    echo -e " ${BOLD}📈 СТАТУС СЕРВИСА${NC}"
    echo " ─────────────────────────────────────────────"
    echo ""

    local port secret user server_ip
    port=$(get_proxy_port)
    secret=$(get_secret)
    user=$(get_run_user)
    server_ip=$(get_public_ip)

    echo -e " Состояние:       $(status_label)"
    echo -e " Пользователь:    ${CYAN}${user:-N/A}${NC}"
    echo -e " IP сервера:      ${CYAN}${server_ip}${NC}"
    echo -e " Внешний порт:    ${CYAN}${port:-N/A}${NC}"
    echo -e " Секрет:          ${CYAN}${secret:0:8}...${secret: -8}${NC}"
    echo ""
    echo -e " ${BOLD}🕒 Запущен с:${NC}"
    systemctl show mtproto-proxy --property=ActiveEnterTimestamp 2>/dev/null \
        | sed 's/ActiveEnterTimestamp=/  /'
    echo ""

    if relay_active; then
        local relay_dest
        relay_dest=$(grep -oP 'TCP:\S+' "$RELAY_SERVICE_FILE" 2>/dev/null | head -1)
        echo -e " ${BOLD}🔀 Каскад:${NC} ${GREEN}активен${NC} → ${CYAN}${relay_dest}${NC}"
        echo ""
    fi

    echo -e " ${BOLD}📋 Последние 5 строк логов:${NC}"
    echo " ─────────────────────────────────────────────"
    journalctl -u mtproto-proxy -n 5 --no-pager 2>/dev/null || echo " Логи недоступны"

    press_enter
}

# ──────────────────────────────────────────────
# СТАТИСТИКА через ss — считаем ESTABLISHED
# соединения на порту прокси.
# Работает без зависимостей, без management port.
# ──────────────────────────────────────────────
action_show_stats() {
    header
    echo -e " ${BOLD}📡 АКТИВНЫЕ ПОДКЛЮЧЕНИЯ${NC}"
    echo " ─────────────────────────────────────────────"
    echo ""

    if ! systemctl is-active --quiet mtproto-proxy 2>/dev/null; then
        warning "Прокси не запущен"
        press_enter
        return
    fi

    local proxy_port
    proxy_port=$(get_proxy_port)

    # ss -tn state established: колонки без State-столбца:
    # $1=Recv-Q $2=Send-Q $3=Local:Port $4=Peer:Port
    # Считаем уникальные IP клиентов (1 устройство = ~4 соединения)
    local client_conns
    client_conns=$(ss -tn state established 2>/dev/null \
        | awk -v p=":${proxy_port}" \
            '$3 ~ p && $4 !~ /^127\./ && $4 !~ /^\[::1\]/ {
                ip = $4; sub(/:[0-9]+$/, "", ip); ips[ip]=1
            } END {print length(ips)}')

    # Всего TCP-соединений (для справки — ~4x от числа клиентов)
    local all_conns
    all_conns=$(ss -tn state established 2>/dev/null \
        | awk -v p=":${proxy_port}" \
            '$3 ~ p && $4 !~ /^127\./ {count++} END {print count+0}')

    # Трафик интерфейса из /proc/net/dev
    local iface bytes_in bytes_out
    iface=$(ip route get 8.8.8.8 2>/dev/null | grep -oP 'dev \K\S+' | head -1)
    if [ -n "$iface" ]; then
        bytes_in=$(awk  -v dev="${iface}:" '$1==dev {print $2}'  /proc/net/dev 2>/dev/null)
        bytes_out=$(awk -v dev="${iface}:" '$1==dev {print $10}' /proc/net/dev 2>/dev/null)
    fi

    fmt_bytes() {
        local b=${1:-0}
        if   [ "$b" -ge 1073741824 ] 2>/dev/null; then printf "%.1f GB" "$(echo "scale=1; $b/1073741824" | bc)"
        elif [ "$b" -ge 1048576 ]    2>/dev/null; then printf "%.1f MB" "$(echo "scale=1; $b/1048576"    | bc)"
        elif [ "$b" -ge 1024 ]       2>/dev/null; then printf "%.1f KB" "$(echo "scale=1; $b/1024"       | bc)"
        else echo "${b:-0} B"
        fi
    }

    echo -e " ${BOLD}🔌 Прямые подключения (порт ${proxy_port}):${NC}"
    echo -e "   ${YELLOW}${BOLD}Клиентов:${NC}        ${GREEN}${BOLD}${client_conns}${NC}"
    echo -e "   ${YELLOW}TCP-соединений:${NC}  ${CYAN}${all_conns}${NC}  (~4 на клиента)"

    # Если каскад активен — считаем клиентов и на relay порту
    if relay_active && [ -f "$RELAY_INFO_FILE" ]; then
        local relay_port
        relay_port=$(grep "^RELAY_PORT=" "$RELAY_INFO_FILE" | cut -d= -f2)
        local relay_remote relay_rport
        relay_remote=$(grep "^REMOTE_IP="   "$RELAY_INFO_FILE" | cut -d= -f2)
        relay_rport=$(grep  "^REMOTE_PORT=" "$RELAY_INFO_FILE" | cut -d= -f2)
        if [ -n "$relay_port" ]; then
            local relay_clients relay_tcp
            relay_clients=$(ss -tn state established 2>/dev/null \
                | awk -v p=":${relay_port}" \
                    '$3 ~ p && $4 !~ /^127\./ && $4 !~ /^\[::1\]/ {
                        ip = $4; sub(/:[0-9]+$/, "", ip); ips[ip]=1
                    } END {print length(ips)}')
            relay_tcp=$(ss -tn state established 2>/dev/null \
                | awk -v p=":${relay_port}" \
                    '$3 ~ p && $4 !~ /^127\./ {count++} END {print count+0}')
            echo ""
            echo -e " ${BOLD}🔀 Каскад (порт ${relay_port} → ${relay_remote}:${relay_rport}):${NC}"
            echo -e "   ${YELLOW}${BOLD}Клиентов:${NC}        ${GREEN}${BOLD}${relay_clients}${NC}"
            echo -e "   ${YELLOW}TCP-соединений:${NC}  ${CYAN}${relay_tcp}${NC}  (~4 на клиента)"
        fi
    fi
    echo ""

    if [ -n "$iface" ]; then
        echo -e " ${BOLD}📶 Трафик интерфейса ${iface} (с перезагрузки):${NC}"
        echo -e "   ${YELLOW}↓ Принято:${NC}    ${CYAN}$(fmt_bytes "${bytes_in:-0}")${NC}"
        echo -e "   ${YELLOW}↑ Отправлено:${NC} ${CYAN}$(fmt_bytes "${bytes_out:-0}")${NC}"
        echo ""
    fi

    echo -e " ${BOLD}📋 Список клиентов на порту ${proxy_port}:${NC}"
    echo " ─────────────────────────────────────────────"
    local conn_list
    conn_list=$(ss -tn state established 2>/dev/null \
        | awk -v p=":${proxy_port}" '$3 ~ p && $4 !~ /^127\./ {printf "  %-26s → %s\n", $4, $3}' \
        | head -25)
    if [ -n "$conn_list" ]; then
        echo "$conn_list"
    else
        echo "  (нет активных соединений)"
    fi

    press_enter
}

action_show_link() {
    header
    echo -e " ${BOLD}🔗 ССЫЛКА ДЛЯ ПОДКЛЮЧЕНИЯ${NC}"
    echo ""

    local port secret server_ip direct_link
    port=$(get_proxy_port)
    secret=$(get_secret)
    server_ip=$(get_public_ip)
    direct_link="tg://proxy?server=${server_ip}&port=${port}&secret=${secret}"

    # Каскад активен — он главная ссылка
    if relay_active && [ -f "$RELAY_INFO_FILE" ]; then
        local relay_port relay_secret relay_remote relay_rport relay_link
        relay_port=$(grep   "^RELAY_PORT="    "$RELAY_INFO_FILE" | cut -d= -f2)
        relay_secret=$(grep "^REMOTE_SECRET=" "$RELAY_INFO_FILE" | cut -d= -f2)
        relay_remote=$(grep "^REMOTE_IP="     "$RELAY_INFO_FILE" | cut -d= -f2)
        relay_rport=$(grep  "^REMOTE_PORT="   "$RELAY_INFO_FILE" | cut -d= -f2)
        relay_link="tg://proxy?server=${server_ip}&port=${relay_port}&secret=${relay_secret}"

        echo -e " ${BOLD}🔀 Каскад активен:${NC} ${server_ip}:${relay_port} → ${relay_remote}:${relay_rport}"
        echo ""
        echo -e " ${BOLD}Данные для подключения:${NC}"
        echo " ┌─────────────────────────────────────────┐"
        echo -e " │ Сервер: ${CYAN}${server_ip}${NC}"
        echo -e " │ Порт:   ${CYAN}${relay_port}${NC}"
        echo -e " │ Секрет: ${CYAN}${relay_secret}${NC}"
        echo " └─────────────────────────────────────────┘"
        echo ""
        echo -e " ${YELLOW}${BOLD}✅ Активная ссылка (через каскад):${NC}"
        echo -e " ${GREEN}${BOLD}${relay_link}${NC}"
        echo ""
        echo " ─────────────────────────────────────────────"
        echo -e " ${BOLD}Прямое подключение (без каскада):${NC}"
        echo -e " ${CYAN}${direct_link}${NC}"
    else
        # Каскада нет — обычная ссылка
        echo -e " ${BOLD}Данные прокси:${NC}"
        echo " ┌─────────────────────────────────────────┐"
        echo -e " │ Сервер: ${CYAN}${server_ip}${NC}"
        echo -e " │ Порт:   ${CYAN}${port}${NC}"
        echo -e " │ Секрет: ${CYAN}${secret}${NC}"
        echo " └─────────────────────────────────────────┘"
        echo ""
        echo -e " ${YELLOW}${BOLD}✅ Активная ссылка:${NC}"
        echo -e " ${GREEN}${BOLD}${direct_link}${NC}"
    fi
    echo ""

    press_enter
}

action_change_port() {
    header
    echo -e " ${BOLD}🔧 ИЗМЕНИТЬ ПОРТ${NC}"
    echo ""

    local cur_port new_port
    cur_port=$(get_proxy_port)
    echo -e " Текущий порт: ${CYAN}${cur_port}${NC}"
    echo ""
    echo "  1) 443   (HTTPS)"
    echo "  2) 8080  (популярный)"
    echo "  3) 8443  (безопасный)"
    echo "  4) Ввести свой"
    echo ""
    read -rp " Выбор [1-4]: " ch

    case "$ch" in
        1) new_port=443  ;;
        2) new_port=8080 ;;
        3) new_port=8443 ;;
        4)
            read -rp " Введи порт (1-65535): " new_port
            validate_port "$new_port" || { err "Некорректный порт"; return; }
            ;;
        *) info "Отмена"; sleep 1; return ;;
    esac

    port_is_free "$new_port" || { err "Порт $new_port уже занят!"; return; }

    sed -i "s|-H [0-9]*|-H $new_port|" "$SERVICE_FILE"
    systemctl daemon-reload >/dev/null 2>&1
    systemctl restart mtproto-proxy >/dev/null 2>&1
    sleep 2

    systemctl is-active --quiet mtproto-proxy \
        && success "Порт изменён на $new_port!" \
        || warning "Порт изменён, но сервис не запустился — проверь логи (7)"

    press_enter
}

action_rotate_secret() {
    header
    echo -e " ${BOLD}🔑 СМЕНА СЕКРЕТА${NC}"
    echo ""

    local old_secret
    old_secret=$(get_secret)
    echo -e " Текущий секрет: ${CYAN}${old_secret}${NC}"
    echo ""
    echo " После смены нужно раздать новую ссылку пользователям."
    echo ""
    read -rp " Сгенерировать новый секрет? (yes/no): " confirm
    [ "$confirm" != "yes" ] && { info "Отмена"; sleep 1; return; }

    local new_secret
    new_secret=$(head -c 16 /dev/urandom | xxd -ps)

    sed -i "s|-S ${old_secret}|-S ${new_secret}|" "$SERVICE_FILE"
    echo "$new_secret" > "$INSTALL_DIR/secret.txt"

    systemctl daemon-reload >/dev/null 2>&1
    systemctl restart mtproto-proxy >/dev/null 2>&1
    sleep 2

    if systemctl is-active --quiet mtproto-proxy; then
        local port server_ip
        port=$(get_proxy_port)
        server_ip=$(get_public_ip)
        success "Секрет обновлён!"
        echo ""
        echo -e " ${YELLOW}Новый секрет:${NC} ${CYAN}${new_secret}${NC}"
        echo ""
        echo -e " ${YELLOW}Новая ссылка:${NC}"
        echo -e " ${GREEN}tg://proxy?server=${server_ip}&port=${port}&secret=${new_secret}${NC}"
    else
        # Откат при ошибке
        sed -i "s|-S ${new_secret}|-S ${old_secret}|" "$SERVICE_FILE"
        echo "$old_secret" > "$INSTALL_DIR/secret.txt"
        systemctl daemon-reload >/dev/null 2>&1
        systemctl restart mtproto-proxy >/dev/null 2>&1
        err "Сервис не запустился — откат к старому секрету"
    fi

    press_enter
}

action_restart() {
    header
    echo -e " ${BOLD}🔄 ПЕРЕЗАПУСК${NC}"
    echo ""
    systemctl restart mtproto-proxy >/dev/null 2>&1
    sleep 2
    systemctl is-active --quiet mtproto-proxy \
        && success "Сервис перезапущен!" \
        || warning "Сервис не запустился. Проверь логи (7)"
    press_enter
}

action_show_logs() {
    header
    echo -e " ${BOLD}📝 ЛОГИ (последние 60 строк)${NC}"
    echo " ─────────────────────────────────────────────"
    echo ""
    journalctl -u mtproto-proxy -n 60 --no-pager 2>/dev/null || echo " Логи недоступны"
    press_enter
}

# ============================================================
# КАСКАД (RELAY) — исправленная логика
#
# socat пробрасывает сырой TCP. MTProto-хэндшейк клиент
# делает с УДАЛЁННЫМ сервером напрямую. Поэтому ссылка:
#   server = IP ЭТОГО сервера
#   port   = порт relay на ЭТОМ сервере
#   secret = СЕКРЕТ УДАЛЁННОГО сервера
# ============================================================
action_cascade_setup() {
    header
    echo -e " ${BOLD}🔀 НАСТРОЙКА ЦЕПОЧКИ (КАСКАД)${NC}"
    echo ""
    echo -e " ${BOLD}Как это работает:${NC}"
    echo "  Клиент → [Этот сервер : relay] → [Удалённый сервер : MTProxy]"
    echo ""
    echo " Трафик идёт через этот сервер на второй, где стоит"
    echo " настоящий MTProxy. Клиент видит только этот сервер."
    echo ""
    echo " Ссылка будет с адресом ЭТОГО сервера и секретом"
    echo " УДАЛЁННОГО сервера — это правильно, так и должно быть."
    echo ""
    echo -e " ${YELLOW}На удалённом сервере должен быть запущен MTProxy.${NC}"
    echo ""

    if ! command -v socat &>/dev/null; then
        info "Устанавливаем socat..."
        apt-get install -y socat >/dev/null 2>&1 \
            || { err "Не удалось установить socat"; return; }
        success "socat установлен"
        echo ""
    fi

    # ── Данные удалённого сервера ─────────────────
    read -rp " IP удалённого сервера (где стоит MTProxy): " REMOTE_IP
    [ -z "$REMOTE_IP" ] && { info "Отмена"; sleep 1; return; }

    read -rp " Порт MTProxy на удалённом сервере: " REMOTE_PORT
    validate_port "$REMOTE_PORT" || { err "Некорректный порт"; return; }

    echo ""
    echo -e " ${BOLD}Секрет удалённого сервера:${NC}"
    echo " (Найти на удалённом сервере командой: sudo mtproto-manager → пункт 3)"
    read -rp " Секрет: " REMOTE_SECRET
    [ -z "$REMOTE_SECRET" ] && { err "Секрет обязателен"; return; }

    # ── Локальный порт relay ──────────────────────
    local relay_local_port=8444
    echo ""
    read -rp " Порт relay на ЭТОМ сервере [${relay_local_port}]: " inp
    [ -n "$inp" ] && relay_local_port=$inp
    validate_port "$relay_local_port" || { err "Некорректный порт"; return; }
    port_is_free "$relay_local_port" || { err "Порт $relay_local_port уже занят!"; return; }

    # ── Чистим старый relay ───────────────────────
    if [ -f "$RELAY_SERVICE_FILE" ]; then
        systemctl stop    mtproto-relay 2>/dev/null || true
        systemctl disable mtproto-relay 2>/dev/null || true
    fi

    # ── Создаём systemd relay ─────────────────────
    cat > "$RELAY_SERVICE_FILE" <<RELAYEOF
[Unit]
Description=MTProto TCP Relay -> ${REMOTE_IP}:${REMOTE_PORT}
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/socat TCP-LISTEN:${relay_local_port},fork,reuseaddr TCP:${REMOTE_IP}:${REMOTE_PORT}
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
RELAYEOF

    # ── Сохраняем инфо для отображения ───────────
    mkdir -p "$INSTALL_DIR"
    cat > "$RELAY_INFO_FILE" <<INFOEOF
RELAY_PORT=${relay_local_port}
REMOTE_IP=${REMOTE_IP}
REMOTE_PORT=${REMOTE_PORT}
REMOTE_SECRET=${REMOTE_SECRET}
INFOEOF

    (
        systemctl daemon-reload >/dev/null 2>&1
        systemctl enable mtproto-relay >/dev/null 2>&1
        systemctl restart mtproto-relay >/dev/null 2>&1
    ) &
    spinner $! "Запускаем relay сервис..."
    sleep 2

    if ! systemctl is-active --quiet mtproto-relay; then
        err "Relay не запустился! Проверь: journalctl -u mtproto-relay"
        return
    fi

    # UFW
    if command -v ufw &>/dev/null; then
        ufw allow "$relay_local_port/tcp" >/dev/null 2>&1 || true
    fi

    local this_ip relay_link
    this_ip=$(get_public_ip)
    # Секрет берём от УДАЛЁННОГО сервера — это ключевой момент
    relay_link="tg://proxy?server=${this_ip}&port=${relay_local_port}&secret=${REMOTE_SECRET}"

    success "Каскад настроен!"
    echo ""
    echo -e " ${BOLD}Схема:${NC}"
    echo -e "  Клиент → ${CYAN}${this_ip}:${relay_local_port}${NC} → ${CYAN}${REMOTE_IP}:${REMOTE_PORT}${NC}"
    echo ""
    echo -e " ${YELLOW}${BOLD}🔗 Ссылка для клиентов:${NC}"
    echo -e " ${GREEN}${BOLD}${relay_link}${NC}"
    echo ""
    echo -e " ${CYAN}Адрес этого сервера + секрет удалённого — так и должно быть.${NC}"

    press_enter
}

action_cascade_remove() {
    header
    echo -e " ${BOLD}❌ ОТКЛЮЧИТЬ КАСКАД${NC}"
    echo ""

    if [ ! -f "$RELAY_SERVICE_FILE" ]; then
        warning "Каскад не настроен"
        press_enter
        return
    fi

    read -rp " Отключить? (yes/no): " confirm
    [ "$confirm" != "yes" ] && { info "Отмена"; sleep 1; return; }

    systemctl stop    mtproto-relay >/dev/null 2>&1 || true
    systemctl disable mtproto-relay >/dev/null 2>&1 || true
    rm -f "$RELAY_SERVICE_FILE" "$RELAY_INFO_FILE"
    systemctl daemon-reload >/dev/null 2>&1

    success "Каскад отключён"
    press_enter
}

action_reinstall() {
    header
    echo -e " ${BOLD}🔃 ПЕРЕУСТАНОВКА${NC}"
    echo ""
    read -rp " ⚠️  Удалить текущий прокси и переустановить? (yes/no): " confirm
    if [ "$confirm" = "yes" ]; then
        uninstall_silent
        run_installer
    else
        info "Отмена"; sleep 1
    fi
}

action_uninstall() {
    header
    echo -e " ${BOLD}🗑️  УДАЛЕНИЕ${NC}"
    echo ""
    read -rp " ⚠️  Полностью удалить всё? (yes/no): " confirm
    if [ "$confirm" = "yes" ]; then
        uninstall_silent
        remove_cron_updater
        success "Всё удалено!"
        sleep 2
        exit 0
    else
        info "Отмена"; sleep 1
    fi
}

# ============ ТИХОЕ УДАЛЕНИЕ ============

uninstall_silent() {
    systemctl stop    mtproto-proxy 2>/dev/null || true
    systemctl disable mtproto-proxy 2>/dev/null || true
    systemctl stop    mtproto-relay 2>/dev/null || true
    systemctl disable mtproto-relay 2>/dev/null || true
    rm -rf "$INSTALL_DIR"
    rm -f  "$SERVICE_FILE" "$RELAY_SERVICE_FILE"
    systemctl daemon-reload >/dev/null 2>&1
}

# ============ CRON: АВТООБНОВЛЕНИЕ ============

install_cron_updater() {
    local script="/usr/local/bin/mtproto-update-configs"
    cat > "$script" <<'CREOF'
#!/bin/bash
INSTALL_DIR="/opt/MTProxy"
[ -d "$INSTALL_DIR" ] || exit 0
curl -sf --max-time 10 https://core.telegram.org/getProxySecret  \
    -o "$INSTALL_DIR/proxy-secret.new"     || exit 0
curl -sf --max-time 10 https://core.telegram.org/getProxyConfig  \
    -o "$INSTALL_DIR/proxy-multi.conf.new" || exit 0
[ -s "$INSTALL_DIR/proxy-secret.new" ]     \
    && mv "$INSTALL_DIR/proxy-secret.new"     "$INSTALL_DIR/proxy-secret"
[ -s "$INSTALL_DIR/proxy-multi.conf.new" ] \
    && mv "$INSTALL_DIR/proxy-multi.conf.new" "$INSTALL_DIR/proxy-multi.conf"
systemctl restart mtproto-proxy >/dev/null 2>&1
CREOF
    chmod +x "$script"
    if ! crontab -l 2>/dev/null | grep -q "$CRON_TAG"; then
        ( crontab -l 2>/dev/null; echo "0 3 * * * $script # $CRON_TAG" ) | crontab -
    fi
}

remove_cron_updater() {
    rm -f "/usr/local/bin/mtproto-update-configs"
    crontab -l 2>/dev/null | grep -v "$CRON_TAG" | crontab - 2>/dev/null || true
}

# ============ УСТАНОВЩИК ============

run_installer() {
    # Защита от обрыва SSH — перезапускаем в screen если нужно
    ensure_screen_session

    header
    echo -e " ${BOLD}📦 УСТАНОВКА MTPROTO ПРОКСИ${NC}"
    echo ""

    # ── Шаг 1: порт ──────────────────────────────
    echo -e " ${BOLD}🔧 Шаг 1/3 — Выбери порт:${NC}"
    echo "  1) 443   (HTTPS — лучший вариант)"
    echo "  2) 8080  (популярный)"
    echo "  3) 8443  (безопасный)"
    echo "  4) Свой"
    echo ""
    read -rp " Выбор [1-4, Enter=2]: " PORT_CHOICE

    case "$PORT_CHOICE" in
        1) PROXY_PORT=443  ;;
        3) PROXY_PORT=8443 ;;
        4)
            read -rp " Порт (1-65535): " PROXY_PORT
            validate_port "$PROXY_PORT" || fatal "Некорректный порт"
            ;;
        *) PROXY_PORT=8080 ;;
    esac

    port_is_free "$PROXY_PORT" || fatal "Порт $PROXY_PORT занят! Выбери другой"
    success "Порт: $PROXY_PORT"
    echo ""

    # ── Шаг 2: пользователь ──────────────────────
    echo -e " ${BOLD}👤 Шаг 2/3 — Пользователь сервиса:${NC}"
    echo "  1) root    (проще, любой порт)"
    echo "  2) mtproxy (безопаснее)"
    echo ""
    read -rp " Выбор [1-2, Enter=1]: " USER_CHOICE

    NEED_CAP=0
    if [ "$USER_CHOICE" = "2" ]; then
        RUN_USER="mtproxy"
        [ "$PROXY_PORT" -lt 1024 ] && NEED_CAP=1
    else
        RUN_USER="root"
    fi
    success "Пользователь: $RUN_USER"
    echo ""

    # ── Шаг 3: обновление системы ────────────────
    echo -e " ${BOLD}🔄 Шаг 3/3 — Обновить систему перед установкой?${NC}"
    echo "  1) Да (надёжнее, +2-3 мин)   2) Нет (быстрее)"
    echo ""
    read -rp " Выбор [1-2, Enter=2]: " UPDATE_CHOICE
    UPDATE_SYSTEM=0
    [ "$UPDATE_CHOICE" = "1" ] && UPDATE_SYSTEM=1

    INTERNAL_PORT=8888

    echo ""
    info "Определяем IP..."
    SERVER_IP=$(get_public_ip)
    [ -z "$SERVER_IP" ] && fatal "Не удалось определить IP"
    success "IP: $SERVER_IP"
    echo ""

    # ── Зависимости ──────────────────────────────
    if [ "$UPDATE_SYSTEM" = "1" ]; then
        (
            apt-get update -y >"$LOGFILE" 2>&1
            apt-get upgrade -y >>"$LOGFILE" 2>&1
            apt-get install -y git curl build-essential libssl-dev \
                zlib1g-dev xxd socat screen >>"$LOGFILE" 2>&1
        ) &
        spinner $! "Обновляем систему и ставим зависимости..." \
            || fatal "Ошибка. Лог: $LOGFILE"
    else
        (
            apt-get install -y git curl build-essential libssl-dev \
                zlib1g-dev xxd socat screen >>"$LOGFILE" 2>&1
        ) &
        spinner $! "Устанавливаем зависимости..." \
            || fatal "Ошибка. Лог: $LOGFILE"
    fi

    # ── Клонируем ────────────────────────────────
    (
        rm -rf "$INSTALL_DIR"
        git clone --depth=1 https://github.com/GetPageSpeed/MTProxy \
            "$INSTALL_DIR" >>"$LOGFILE" 2>&1
    ) &
    spinner $! "Клонируем репозиторий..." || fatal "Ошибка. Лог: $LOGFILE"

    [ -f "$INSTALL_DIR/Makefile" ] || fatal "Репозиторий не скачался"

    # ── Сборка (все ядра) ────────────────────────
    (
        cd "$INSTALL_DIR" && make -j"$(nproc)" >>"$LOGFILE" 2>&1
    ) &
    spinner $! "Собираем бинарник ($(nproc) потоков)..." \
        || fatal "Ошибка компиляции. Лог: $LOGFILE"

    [ -f "$INSTALL_DIR/objs/bin/mtproto-proxy" ] \
        || fatal "Бинарник не собрался. Лог: $LOGFILE"
    cp "$INSTALL_DIR/objs/bin/mtproto-proxy" "$INSTALL_DIR/"
    chmod +x "$INSTALL_DIR/mtproto-proxy"
    success "Бинарник готов"

    # ── Конфиги Telegram (параллельно) ───────────
    (
        curl -sf --max-time 10 https://core.telegram.org/getProxySecret \
            -o "$INSTALL_DIR/proxy-secret"     >>"$LOGFILE" 2>&1 &
        curl -sf --max-time 10 https://core.telegram.org/getProxyConfig \
            -o "$INSTALL_DIR/proxy-multi.conf" >>"$LOGFILE" 2>&1 &
        wait
    ) &
    spinner $! "Скачиваем конфиги Telegram..." \
        || fatal "Ошибка. Лог: $LOGFILE"

    if [ ! -s "$INSTALL_DIR/proxy-secret" ] || [ ! -s "$INSTALL_DIR/proxy-multi.conf" ]; then
        fatal "Конфиги пустые — проверь интернет"
    fi

    # ── Секрет ───────────────────────────────────
    SECRET=$(head -c 16 /dev/urandom | xxd -ps)
    echo "$SECRET" > "$INSTALL_DIR/secret.txt"
    success "Секрет сгенерирован"

    # ── Пользователь mtproxy ─────────────────────
    if ! id "mtproxy" &>/dev/null; then
        useradd -r -s /bin/false mtproxy >/dev/null 2>&1
        success "Пользователь mtproxy создан"
    fi

    # ── Права доступа ────────────────────────────
    if [ "$RUN_USER" = "mtproxy" ]; then
        chown -R mtproxy:mtproxy "$INSTALL_DIR"
    else
        chown -R root:root "$INSTALL_DIR"
    fi

    if [ "$NEED_CAP" = "1" ]; then
        setcap 'cap_net_bind_service=+ep' "$INSTALL_DIR/mtproto-proxy"
        success "CAP_NET_BIND_SERVICE установлена"
    fi

    # ── Systemd-сервис ───────────────────────────
    cat > "$SERVICE_FILE" <<SVCEOF
[Unit]
Description=Telegram MTProto Proxy
After=network.target
Documentation=https://github.com/GetPageSpeed/MTProxy

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
User=${RUN_USER}
ExecStart=${INSTALL_DIR}/mtproto-proxy -u mtproxy -p ${INTERNAL_PORT} -H ${PROXY_PORT} -S ${SECRET} --aes-pwd proxy-secret proxy-multi.conf -M 1
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVCEOF
    success "Systemd-сервис создан"

    # ── Запуск ───────────────────────────────────
    (
        systemctl daemon-reload >/dev/null 2>&1
        systemctl enable mtproto-proxy >/dev/null 2>&1
        systemctl restart mtproto-proxy >/dev/null 2>&1
    ) &
    spinner $! "Запускаем сервис..."
    sleep 3

    systemctl is-active --quiet mtproto-proxy \
        || fatal "Сервис не запустился! journalctl -u mtproto-proxy"
    success "Сервис запущен"

    # ── UFW ──────────────────────────────────────
    if command -v ufw &>/dev/null; then
        (
            ufw delete allow "$PROXY_PORT/tcp" >/dev/null 2>&1 || true
            ufw allow "$PROXY_PORT/tcp" >/dev/null 2>&1
            ufw status | grep -q "^Status: active" \
                && ufw reload >/dev/null 2>&1 || true
        ) &
        spinner $! "Настраиваем UFW..."
    fi

    # ── Cron автообновление ───────────────────────
    install_cron_updater
    success "Автообновление конфигов Telegram — ежедневно 03:00"

    # ── Итог ─────────────────────────────────────
    local PROXY_LINK
    PROXY_LINK="tg://proxy?server=${SERVER_IP}&port=${PROXY_PORT}&secret=${SECRET}"

    header
    echo ""
    echo -e " ${GREEN}${BOLD}════════════════════════════════════════════${NC}"
    echo -e "  🎉 УСТАНОВКА ЗАВЕРШЕНА!"
    echo -e " ${NC}"
    echo ""
    echo -e " ${YELLOW}Сервер:${NC}  ${CYAN}${SERVER_IP}${NC}"
    echo -e " ${YELLOW}Порт:${NC}    ${CYAN}${PROXY_PORT}${NC}"
    echo -e " ${YELLOW}Секрет:${NC}  ${CYAN}${SECRET}${NC}"
    echo ""

    # Если каскад уже был настроен до переустановки — показываем его ссылку
    if relay_active && [ -f "$RELAY_INFO_FILE" ]; then
        local r_port r_secret r_ip r_rport r_link
        r_port=$(grep   "^RELAY_PORT="    "$RELAY_INFO_FILE" | cut -d= -f2)
        r_secret=$(grep "^REMOTE_SECRET=" "$RELAY_INFO_FILE" | cut -d= -f2)
        r_ip=$(grep     "^REMOTE_IP="     "$RELAY_INFO_FILE" | cut -d= -f2)
        r_rport=$(grep  "^REMOTE_PORT="   "$RELAY_INFO_FILE" | cut -d= -f2)
        r_link="tg://proxy?server=${SERVER_IP}&port=${r_port}&secret=${r_secret}"
        echo -e " ${YELLOW}${BOLD}✅ Активная ссылка (через каскад):${NC}"
        echo -e " ${GREEN}${BOLD}${r_link}${NC}"
        echo ""
        echo -e " ${CYAN}Каскад: ${SERVER_IP}:${r_port} → ${r_ip}:${r_rport}${NC}"
        echo ""
        echo -e " Прямое подключение: ${CYAN}${PROXY_LINK}${NC}"
    else
        echo -e " ${YELLOW}${BOLD}✅ Активная ссылка:${NC}"
        echo -e " ${GREEN}${BOLD}${PROXY_LINK}${NC}"
    fi
    echo ""
    echo -e " ${YELLOW}Менеджер:${NC} ${CYAN}sudo mtproto-manager${NC}"
    echo ""
    read -rp " Нажми Enter для открытия менеджера... "
}

# ============ УСТАНОВКА КОМАНДЫ В PATH ============

install_manager_link() {
    local target
    target=$(readlink -f "$0" 2>/dev/null || echo "$0")
    if [ ! -L "$MANAGER_LINK" ] || [ "$(readlink "$MANAGER_LINK")" != "$target" ]; then
        ln -sf "$target" "$MANAGER_LINK" 2>/dev/null || true
        chmod +x "$MANAGER_LINK" 2>/dev/null || true
    fi
}

# ============ ТОЧКА ВХОДА ============

[[ $EUID -ne 0 ]] && { echo -e "${RED}[✗]${NC} Запускай от root: sudo bash $0"; exit 1; }

install_manager_link
show_main_menu
