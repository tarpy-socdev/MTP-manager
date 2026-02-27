#!/bin/bash
# ==============================================
# MTProto Proxy — Universal Manager v4.3
# Установка + Менеджер
# github.com/tarpy-socdev/MTP-manager
# ==============================================
# CHANGELOG v4.3:
# - Убран SOCKS5 полностью
# - Режим мониторинга ресурсов: живое обновление каждую секунду (q для выхода)
# - Убран set -e
# - Исправлен install_command (cp вместо symlink)
# - check_port_available: пропуск текущего порта при переустановке
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
LOGFILE="/tmp/mtproto-install.log"
MANAGER_PATH="/usr/local/bin/mtproto-manager"

# ============ УТИЛИТЫ ============

err() {
    echo -e "${RED}[✗]${NC} $1"
    exit 1
}

success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

info() {
    echo -e "${CYAN}[ℹ]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[⚠]${NC} $1"
}

clear_screen() {
    clear
    echo -e "${CYAN}${BOLD}"
    echo " ╔════════════════════════════════════════════╗"
    echo " ║     MTProto Proxy Manager v4.3             ║"
    echo " ║     github.com/tarpy-socdev/MTP-manager    ║"
    echo " ╚════════════════════════════════════════════╝"
    echo -e "${NC}"
}

spinner() {
    local pid=$1
    local msg=$2
    local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0
    while kill -0 "$pid" 2>/dev/null; do
        i=$(( (i+1) % 10 ))
        printf "\r ${CYAN}${spin:$i:1}${NC} $msg"
        sleep 0.1
    done
    wait "$pid" 2>/dev/null
    local exit_code=$?
    if [ $exit_code -eq 0 ]; then
        printf "\r ${GREEN}✓${NC} $msg\n"
    else
        printf "\r ${RED}✗${NC} $msg (ошибка $exit_code)\n"
        return $exit_code
    fi
}

generate_password() {
    cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1
}

validate_port() {
    local port=$1
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        err "❌ Некорректный порт! Используй 1-65535"
    fi
}

check_port_available() {
    local port=$1
    local skip_port=${2:-""}
    if [ -n "$skip_port" ] && [ "$port" = "$skip_port" ]; then
        return 0
    fi
    if netstat -tuln 2>/dev/null | grep -q ":$port " || ss -tuln 2>/dev/null | grep -q ":$port "; then
        err "❌ Порт $port уже занят! Выбери другой"
    fi
}

generate_qr_code() {
    local data=$1
    if ! command -v qrencode &>/dev/null; then
        info "Устанавливаем qrencode..."
        apt install -y qrencode > /dev/null 2>&1
    fi
    qrencode -t ANSI -o - "$data" 2>/dev/null || echo "[QR-код недоступен]"
}

check_installation() {
    if [ -f "$SERVICE_FILE" ] && systemctl is-active --quiet mtproto-proxy 2>/dev/null; then
        return 0
    elif [ -f "$SERVICE_FILE" ]; then
        return 1
    else
        return 2
    fi
}

get_installation_status() {
    if check_installation; then
        echo 0
    elif [ -f "$SERVICE_FILE" ]; then
        echo 1
    else
        echo 2
    fi
}

[[ $EUID -ne 0 ]] && err "Запускай от root! (sudo bash script.sh)"

# ============ МОНИТОРИНГ РЕСУРСОВ (живое обновление) ============
show_resource_live() {
    if [ ! -f "$SERVICE_FILE" ]; then
        warning "MTProto не установлен!"
        read -rp " Enter для возврата... "
        return
    fi

    local proxy_port server_ip
    proxy_port=$(grep -oP '(?<=-H )\d+' "$SERVICE_FILE" 2>/dev/null || echo "N/A")
    server_ip=$(hostname -I | awk '{print $1}')

    tput civis 2>/dev/null
    tput smcup 2>/dev/null
    trap 'tput cnorm 2>/dev/null; tput rmcup 2>/dev/null; trap - INT TERM' INT TERM
    clear

    while true; do
        read -t 0.9 -rsn1 key 2>/dev/null
        [[ "$key" == "q" || "$key" == "Q" ]] && break

        local svc_status pid cpu mem rss_mb uptime_str connections
        local cpu_bar="" mem_bar=""

        if systemctl is-active --quiet mtproto-proxy 2>/dev/null; then
            svc_status="${GREEN}✅ РАБОТАЕТ${NC}"
        else
            svc_status="${RED}❌ ОСТАНОВЛЕН${NC}"
        fi

        pid=$(systemctl show -p MainPID mtproto-proxy 2>/dev/null | cut -d= -f2)

        if [ -n "$pid" ] && [ "$pid" != "0" ] && kill -0 "$pid" 2>/dev/null; then
            cpu=$(ps -p "$pid" -o %cpu= 2>/dev/null | xargs || echo "0.0")
            mem=$(ps -p "$pid" -o %mem= 2>/dev/null | xargs || echo "0.0")
            local rss
            rss=$(ps -p "$pid" -o rss= 2>/dev/null | xargs || echo "0")
            rss_mb=$(( rss / 1024 ))

            local active_since start_epoch now_epoch diff hh mm ss
            active_since=$(systemctl show -p ActiveEnterTimestamp mtproto-proxy 2>/dev/null | cut -d= -f2)
            if [ -n "$active_since" ]; then
                start_epoch=$(date -d "$active_since" +%s 2>/dev/null || echo 0)
                now_epoch=$(date +%s)
                diff=$(( now_epoch - start_epoch ))
                hh=$(( diff / 3600 ))
                mm=$(( (diff % 3600) / 60 ))
                ss=$(( diff % 60 ))
                uptime_str=$(printf "%02d:%02d:%02d" $hh $mm $ss)
            else
                uptime_str="N/A"
            fi

            # Считаем только входящие соединения (клиенты → прокси)
            connections=$(ss -tn state established "( dport = :$proxy_port )" 2>/dev/null | tail -n +2 | wc -l 2>/dev/null || echo "0")
            # Fallback на netstat если ss не поддерживает фильтр
            if ! ss -tn state established "( dport = :$proxy_port )" > /dev/null 2>&1; then
                connections=$(netstat -tn 2>/dev/null | grep -c ":${proxy_port}[[:space:]]" || echo "0")
            fi

            local cpu_int mem_int cpu_bars mem_bars
            cpu_int=$(printf "%.0f" "$cpu" 2>/dev/null || echo 0)
            mem_int=$(printf "%.0f" "$mem" 2>/dev/null || echo 0)
            cpu_bars=$(( cpu_int / 5 )); [ $cpu_bars -gt 20 ] && cpu_bars=20
            mem_bars=$(( mem_int / 5 )); [ $mem_bars -gt 20 ] && mem_bars=20

            for ((i=0; i<cpu_bars; i++));  do cpu_bar+="${GREEN}█${NC}"; done
            for ((i=cpu_bars; i<20; i++)); do cpu_bar+="░"; done
            for ((i=0; i<mem_bars; i++));  do mem_bar+="${YELLOW}█${NC}"; done
            for ((i=mem_bars; i<20; i++)); do mem_bar+="░"; done
        else
            cpu="—"; mem="—"; rss_mb="—"; uptime_str="—"; connections="—"
            cpu_bar="░░░░░░░░░░░░░░░░░░░░"
            mem_bar="░░░░░░░░░░░░░░░░░░░░"
        fi

        local term_width log_width logs
        term_width=$(tput cols 2>/dev/null || echo 80)
        log_width=$(( term_width - 3 ))
        logs=$(journalctl -u mtproto-proxy -n 5 --no-pager --output=short 2>/dev/null \
            | cut -c1-"$log_width" | sed 's/^/ /' || echo " Логи недоступны")

        tput cup 0 0

        printf "${CYAN}${BOLD}"
        printf " ╔════════════════════════════════════════════╗\n"
        printf " ║     MTProto Proxy — Live Monitor           ║\n"
        printf " ║     %s  [q — выход]               ║\n" "$(date '+%H:%M:%S')"
        printf " ╚════════════════════════════════════════════╝\n"
        printf "${NC}\n"
        printf " Статус:      $(echo -e "$svc_status")\n"
        printf " Сервер:      ${CYAN}%s:%s${NC}\n" "$server_ip" "$proxy_port"
        printf " Аптайм:      ${CYAN}%s${NC}\n" "$uptime_str"
        printf " Соединений:  ${CYAN}%s${NC}\n" "$connections"
        printf "\n"
        printf " CPU: $(echo -e "$cpu_bar") ${CYAN}%s%%${NC}\n" "$cpu"
        printf " RAM: $(echo -e "$mem_bar") ${CYAN}%s%%${NC} (%s MB)\n" "$mem" "$rss_mb"
        printf "\n"
        printf " ${BOLD}📝 Последние логи:${NC}\n"
        printf " ─────────────────────────────────────────────\n"
        while IFS= read -r line; do
            printf "%s$(tput el)\n" "$line"
        done <<< "$logs"
        tput ed 2>/dev/null

    done

    tput cnorm 2>/dev/null
    tput rmcup 2>/dev/null
    trap - INT TERM
}

# ============ УСТАНОВЩИК MTPROTO ============
run_installer() {
    clear_screen
    echo ""

    echo -e "${BOLD}🔧 Выбери порт для MTProto прокси:${NC}"
    echo " 1) 443  (выглядит как HTTPS, лучший вариант)"
    echo " 2) 8080 (популярный альтернативный)"
    echo " 3) 8443 (ещё один безопасный)"
    echo " 4) Ввести свой порт"
    echo ""
    read -rp "Твой выбор [1-4]: " PORT_CHOICE

    case $PORT_CHOICE in
        1) PROXY_PORT=443 ;;
        2) PROXY_PORT=8080 ;;
        3) PROXY_PORT=8443 ;;
        4)
            read -rp "Введи порт (1-65535): " PROXY_PORT
            validate_port "$PROXY_PORT"
            ;;
        *)
            info "По умолчанию: 8080"
            PROXY_PORT=8080
            ;;
    esac

    CURRENT_PROXY_PORT=$(grep -oP '(?<=-H )\d+' "$SERVICE_FILE" 2>/dev/null || echo "")
    check_port_available "$PROXY_PORT" "$CURRENT_PROXY_PORT"
    info "Порт: $PROXY_PORT"
    echo ""

    echo -e "${BOLD}👤 От какого пользователя запускать?${NC}"
    echo " 1) root    (проще, работает с любым портом)"
    echo " 2) mtproxy (безопаснее, нужен порт > 1024)"
    echo ""
    read -rp "Твой выбор [1-2]: " USER_CHOICE

    NEED_CAP=0
    case $USER_CHOICE in
        1) RUN_USER="root" ;;
        2)
            RUN_USER="mtproxy"
            if [ "$PROXY_PORT" -lt 1024 ]; then
                info "Будет использована CAP_NET_BIND_SERVICE"
                NEED_CAP=1
            fi
            ;;
        *)
            info "По умолчанию: root"
            RUN_USER="root"
            ;;
    esac

    echo -e "${CYAN}✓ Пользователь: $RUN_USER${NC}"
    echo ""

    INTERNAL_PORT=8888

    info "Определяем IP сервера..."
    SERVER_IP=$(curl -s --max-time 3 https://api.ipify.org 2>/dev/null || \
                curl -s --max-time 3 https://ifconfig.me 2>/dev/null || \
                hostname -I | awk '{print $1}')
    [[ -z "$SERVER_IP" ]] && err "❌ Не удалось определить IP"
    echo -e "${CYAN}✓ IP: $SERVER_IP${NC}"
    echo ""

    (
        apt update -y > "$LOGFILE" 2>&1
        apt install -y git curl build-essential libssl-dev zlib1g-dev xxd netcat-openbsd >> "$LOGFILE" 2>&1
    ) &
    spinner $! "Устанавливаем зависимости..."

    (
        rm -rf "$INSTALL_DIR"
        git clone https://github.com/GetPageSpeed/MTProxy "$INSTALL_DIR" >> "$LOGFILE" 2>&1
    ) &
    spinner $! "Клонируем репозиторий..."

    [ ! -f "$INSTALL_DIR/Makefile" ] && err "❌ Ошибка загрузки репозитория!"

    (
        cd "$INSTALL_DIR" && make >> "$LOGFILE" 2>&1
    ) &
    spinner $! "Собираем бинарник..."

    [ ! -f "$INSTALL_DIR/objs/bin/mtproto-proxy" ] && err "❌ Ошибка компиляции! Лог: $LOGFILE"

    cp "$INSTALL_DIR/objs/bin/mtproto-proxy" "$INSTALL_DIR/"
    chmod +x "$INSTALL_DIR/mtproto-proxy"
    success "Бинарник собран"

    (
        curl -s --max-time 10 https://core.telegram.org/getProxySecret -o "$INSTALL_DIR/proxy-secret" >> "$LOGFILE" 2>&1
        curl -s --max-time 10 https://core.telegram.org/getProxyConfig -o "$INSTALL_DIR/proxy-multi.conf" >> "$LOGFILE" 2>&1
    ) &
    spinner $! "Скачиваем конфиги Telegram..."

    { [ ! -s "$INSTALL_DIR/proxy-secret" ] || [ ! -s "$INSTALL_DIR/proxy-multi.conf" ]; } && \
        err "❌ Ошибка загрузки конфигов Telegram!"

    SECRET=$(head -c 16 /dev/urandom | xxd -ps)
    echo "$SECRET" > "$INSTALL_DIR/secret.txt"
    success "Секрет сгенерирован"

    if ! id "mtproxy" &>/dev/null; then
        useradd -m -s /bin/false mtproxy > /dev/null 2>&1
        success "Пользователь mtproxy создан"
    fi

    if [ "$RUN_USER" = "mtproxy" ]; then
        chown -R mtproxy:mtproxy "$INSTALL_DIR"
    else
        chown -R root:root "$INSTALL_DIR"
    fi

    if [ "$NEED_CAP" = "1" ]; then
        setcap 'cap_net_bind_service=+ep' "$INSTALL_DIR/mtproto-proxy"
        success "Capabilities установлены"
    fi

    cat > "$SERVICE_FILE" <<'EOF'
[Unit]
Description=Telegram MTProto Proxy Server
After=network.target
Documentation=https://github.com/GetPageSpeed/MTProxy

[Service]
Type=simple
WorkingDirectory=INSTALL_DIR
User=RUN_USER
ExecStart=INSTALL_DIR/mtproto-proxy -u mtproxy -p INTERNAL_PORT -H PROXY_PORT -S SECRET --aes-pwd proxy-secret proxy-multi.conf -M 1
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    sed -i "s|INSTALL_DIR|$INSTALL_DIR|g"     "$SERVICE_FILE"
    sed -i "s|RUN_USER|$RUN_USER|g"           "$SERVICE_FILE"
    sed -i "s|INTERNAL_PORT|$INTERNAL_PORT|g" "$SERVICE_FILE"
    sed -i "s|PROXY_PORT|$PROXY_PORT|g"       "$SERVICE_FILE"
    sed -i "s|SECRET|$SECRET|g"               "$SERVICE_FILE"
    success "Systemd сервис создан"

    (
        systemctl daemon-reload > /dev/null 2>&1
        systemctl enable mtproto-proxy > /dev/null 2>&1
        systemctl restart mtproto-proxy > /dev/null 2>&1
    ) &
    spinner $! "Запускаем сервис..."

    sleep 3

    if ! systemctl is-active --quiet mtproto-proxy; then
        err "❌ Сервис не запустился! journalctl -u mtproto-proxy -n 30"
    fi
    success "Сервис запущен"

    if command -v ufw &>/dev/null; then
        (
            ufw delete allow "$PROXY_PORT/tcp" > /dev/null 2>&1 || true
            ufw allow "$PROXY_PORT/tcp" > /dev/null 2>&1
            ufw status | grep -q "active" && ufw reload > /dev/null 2>&1
        ) &
        spinner $! "Настраиваем UFW..."
    fi

    clear_screen
    echo ""
    echo -e "${YELLOW}${BOLD}📌 Спонсорский тег:${NC}"
    echo " Получи через @MTProxybot (/newproxy)"
    echo ""
    echo -e " ┌─────────────────────────────────────────┐"
    echo -e " │ Host:Port  ${CYAN}${SERVER_IP}:${PROXY_PORT}${NC}"
    echo -e " │ Секрет     ${CYAN}${SECRET}${NC}"
    echo -e " └─────────────────────────────────────────┘"
    echo ""
    read -rp " Введи тег (или Enter пропустить): " SPONSOR_TAG

    if [ -n "$SPONSOR_TAG" ]; then
        sed -i "s|-M 1$|-M 1 -P $SPONSOR_TAG|" "$SERVICE_FILE"
        systemctl daemon-reload > /dev/null 2>&1
        systemctl restart mtproto-proxy > /dev/null 2>&1
        sleep 2
        success "Тег добавлен"
    fi

    if [ -n "$SPONSOR_TAG" ]; then
        PROXY_LINK="tg://proxy?server=${SERVER_IP}&port=${PROXY_PORT}&secret=${SECRET}&t=${SPONSOR_TAG}"
    else
        PROXY_LINK="tg://proxy?server=${SERVER_IP}&port=${PROXY_PORT}&secret=${SECRET}"
    fi

    clear_screen
    echo ""
    echo -e " ${GREEN}${BOLD}════════════════════════════════════════════${NC}"
    echo -e "  🎉 УСТАНОВКА ЗАВЕРШЕНА!"
    echo -e " ${GREEN}${BOLD}════════════════════════════════════════════${NC}"
    echo ""
    echo -e " ${YELLOW}Сервер:${NC}  ${CYAN}$SERVER_IP${NC}"
    echo -e " ${YELLOW}Порт:${NC}    ${CYAN}$PROXY_PORT${NC}"
    echo -e " ${YELLOW}Секрет:${NC}  ${CYAN}$SECRET${NC}"
    [ -n "$SPONSOR_TAG" ] && echo -e " ${YELLOW}Тег:${NC}     ${CYAN}$SPONSOR_TAG${NC}"
    echo ""
    echo -e "${YELLOW}${BOLD}📱 QR-код:${NC}"
    generate_qr_code "$PROXY_LINK"
    echo ""
    echo -e "${YELLOW}${BOLD}🔗 Ссылка:${NC}"
    echo -e "${GREEN}${BOLD}$PROXY_LINK${NC}"
    echo ""
    read -rp " Нажми Enter для открытия менеджера... "
    run_manager
}

# ============ МЕНЕДЖЕР ============
run_manager() {
    while true; do
        show_manager_menu
    done
}

show_manager_menu() {
    clear_screen

    local status
    status=$(get_installation_status)

    echo ""
    echo -e " ${BOLD}📊 СТАТУС:${NC}"
    echo " ─────────────────────────────────────────────"

    if [ $status -eq 0 ]; then
        echo -e " MTProto: ${GREEN}✅ РАБОТАЕТ${NC}"
    elif [ $status -eq 1 ]; then
        echo -e " MTProto: ${RED}❌ ОСТАНОВЛЕН${NC}"
    else
        echo -e " MTProto: ${YELLOW}⚠️  НЕ УСТАНОВЛЕН${NC}"
    fi

    echo ""
    echo -e " ${CYAN}${BOLD}═════════════════════════════════════════════${NC}"
    echo ""
    echo -e " ${BOLD}📱 УПРАВЛЕНИЕ:${NC}"
    echo ""
    echo " 1)  📈 Мониторинг ресурсов (live)"
    echo " 2)  📱 QR-код и ссылка"
    echo " 3)  ▶️  Запустить"
    echo " 4)  ⏸️  Остановить"
    echo " 5)  🔄 Перезагрузить"
    echo " 6)  🏷️  Применить спонсорский тег"
    echo " 7)  ❌ Удалить спонсорский тег"
    echo " 8)  🔧 Изменить порт"
    echo " 9)  📝 Логи (50 строк)"
    echo " 10) 🗑️  Удалить MTProto"
    echo " 11) 🤖 Telegram уведомления"
    echo ""
    echo " 0)  🚪 Выход"
    echo ""
    echo -e " ${CYAN}${BOLD}═════════════════════════════════════════════${NC}"
    echo ""
    read -rp " Выбери опцию: " choice

    case $choice in
        1)  show_resource_live ;;
        2)  manager_show_qr ;;
        3)  manager_start ;;
        4)  manager_stop ;;
        5)  manager_restart ;;
        6)  manager_apply_tag ;;
        7)  manager_remove_tag ;;
        8)  manager_change_port ;;
        9)  manager_show_logs ;;
        10)
            read -rp "⚠️  Удалить MTProto? (yes/no): " confirm
            if [ "$confirm" = "yes" ]; then
                uninstall_mtproxy_silent
                success "MTProto удалён"
                sleep 1
            fi
            ;;
        11) manager_tg_settings ;;
        0)
            echo -e "${GREEN}До свидания! 👋${NC}"
            exit 0
            ;;
        *)
            warning "Неправильный выбор"
            sleep 1
            ;;
    esac
}

# ============ ФУНКЦИИ МЕНЕДЖЕРА ============

manager_show_qr() {
    clear_screen
    echo ""
    if [ ! -f "$SERVICE_FILE" ]; then
        warning "MTProto не установлен!"
        read -rp " Enter... "; return
    fi

    local server_ip proxy_port secret proxy_link
    server_ip=$(hostname -I | awk '{print $1}')
    proxy_port=$(grep -oP '(?<=-H )\d+' "$SERVICE_FILE" || echo "8080")
    secret=$(grep -oP '(?<=-S )\S+' "$SERVICE_FILE" || echo "")

    if grep -q -- "-P " "$SERVICE_FILE"; then
        local tag
        tag=$(grep -oP '(?<=-P )\S+' "$SERVICE_FILE" || echo "")
        proxy_link="tg://proxy?server=${server_ip}&port=${proxy_port}&secret=${secret}&t=${tag}"
    else
        proxy_link="tg://proxy?server=${server_ip}&port=${proxy_port}&secret=${secret}"
    fi

    echo -e " ${YELLOW}${BOLD}📱 QR-КОД:${NC}"
    generate_qr_code "$proxy_link"
    echo ""
    echo -e " ${YELLOW}${BOLD}🔗 ССЫЛКА:${NC}"
    echo -e " ${GREEN}${BOLD}$proxy_link${NC}"
    echo ""
    echo -e " ${YELLOW}${BOLD}📋 Данные для @MTProxybot:${NC}"
    echo -e " ┌─────────────────────────────────────────┐"
    echo -e " │ Host:Port  ${CYAN}${server_ip}:${proxy_port}${NC}"
    echo -e " │ Секрет     ${CYAN}${secret}${NC}"
    echo -e " └─────────────────────────────────────────┘"
    echo ""
    read -rp " Enter для возврата... "
}

manager_start() {
    clear_screen; echo ""
    [ ! -f "$SERVICE_FILE" ] && { warning "MTProto не установлен!"; read -rp " Enter... "; return; }
    systemctl start mtproto-proxy > /dev/null 2>&1; sleep 2
    systemctl is-active --quiet mtproto-proxy && success "Запущен!" || err "Ошибка запуска!"
    read -rp " Enter для возврата... "
}

manager_stop() {
    clear_screen; echo ""
    [ ! -f "$SERVICE_FILE" ] && { warning "MTProto не установлен!"; read -rp " Enter... "; return; }
    systemctl stop mtproto-proxy > /dev/null 2>&1; sleep 2
    ! systemctl is-active --quiet mtproto-proxy && success "Остановлен!" || warning "Не удалось остановить"
    read -rp " Enter для возврата... "
}

manager_restart() {
    clear_screen; echo ""
    [ ! -f "$SERVICE_FILE" ] && { warning "MTProto не установлен!"; read -rp " Enter... "; return; }
    systemctl restart mtproto-proxy > /dev/null 2>&1; sleep 2
    systemctl is-active --quiet mtproto-proxy && success "Перезагружен!" || err "Ошибка перезагрузки!"
    read -rp " Enter для возврата... "
}

manager_apply_tag() {
    clear_screen; echo ""
    [ ! -f "$SERVICE_FILE" ] && { warning "MTProto не установлен!"; read -rp " Enter... "; return; }
    read -rp " Введи спонсорский тег: " SPONSOR_TAG
    [ -z "$SPONSOR_TAG" ] && { warning "Тег не введён"; read -rp " Enter... "; return; }

    if grep -q -- "-P " "$SERVICE_FILE"; then
        sed -i "s|-P [^ ]*|-P $SPONSOR_TAG|" "$SERVICE_FILE"
    else
        sed -i "s|-M 1$|-M 1 -P $SPONSOR_TAG|" "$SERVICE_FILE"
    fi
    systemctl daemon-reload > /dev/null 2>&1
    systemctl restart mtproto-proxy > /dev/null 2>&1; sleep 2
    success "Тег применён!"
    read -rp " Enter для возврата... "
}

manager_remove_tag() {
    clear_screen; echo ""
    [ ! -f "$SERVICE_FILE" ] && { warning "MTProto не установлен!"; read -rp " Enter... "; return; }
    grep -q -- "-P " "$SERVICE_FILE" || { warning "Тег не установлен"; read -rp " Enter... "; return; }

    read -rp " Удалить тег? (yes/no): " confirm
    if [ "$confirm" = "yes" ]; then
        sed -i "s| -P [^ ]*||" "$SERVICE_FILE"
        systemctl daemon-reload > /dev/null 2>&1
        systemctl restart mtproto-proxy > /dev/null 2>&1; sleep 2
        success "Тег удалён!"
    else
        info "Отменено"
    fi
    read -rp " Enter для возврата... "
}

manager_change_port() {
    clear_screen; echo ""
    [ ! -f "$SERVICE_FILE" ] && { warning "MTProto не установлен!"; read -rp " Enter... "; return; }

    local current_port
    current_port=$(grep -oP '(?<=-H )\d+' "$SERVICE_FILE")
    echo -e " Текущий порт: ${CYAN}$current_port${NC}"
    echo ""
    echo " 1) 443"
    echo " 2) 8080"
    echo " 3) 8443"
    echo " 4) Свой"
    echo ""
    read -rp "Выбор [1-4]: " PORT_CHOICE

    case $PORT_CHOICE in
        1) NEW_PORT=443 ;;
        2) NEW_PORT=8080 ;;
        3) NEW_PORT=8443 ;;
        4) read -rp "Порт: " NEW_PORT; validate_port "$NEW_PORT" ;;
        *) warning "Неверный выбор"; read -rp " Enter... "; return ;;
    esac

    check_port_available "$NEW_PORT" "$current_port"
    sed -i "s|-H [0-9]*|-H $NEW_PORT|" "$SERVICE_FILE"
    systemctl daemon-reload > /dev/null 2>&1
    systemctl restart mtproto-proxy > /dev/null 2>&1; sleep 2
    success "Порт изменён на $NEW_PORT!"
    read -rp " Enter для возврата... "
}

manager_show_logs() {
    clear_screen; echo ""
    echo -e " ${BOLD}📝 ЛОГИ (последние 50 строк)${NC}"
    echo " ─────────────────────────────────────────────"
    journalctl -u mtproto-proxy -n 50 --no-pager 2>/dev/null || echo " Логи недоступны"
    echo ""
    read -rp " Enter для возврата... "
}

uninstall_mtproxy_silent() {
    systemctl stop mtproto-proxy 2>/dev/null || true
    systemctl disable mtproto-proxy 2>/dev/null || true
    rm -rf "$INSTALL_DIR"
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload > /dev/null 2>&1
}


# ============ TELEGRAM ИНТЕГРАЦИЯ ============
# Подключаем ядро и задаём колбеки для MTProto

TG_PROJECT_NAME="MTProto Proxy"
TG_BUILD_MSG_FN="mtproto_tg_build_msg"

# Флаг — ядро загружается только один раз
_TG_CORE_LOADED=0

_tg_core_load() {
    [ "$_TG_CORE_LOADED" = "1" ] && return 0  # уже загружено
    if [ ! -f "/opt/tg-core/tg-core.sh" ]; then
        return 1
    fi
    source /opt/tg-core/tg-core.sh
    local rc=$?
    [ $rc -eq 0 ] && _TG_CORE_LOADED=1
    return $rc
}

# Колбек: статус прокси (вызывается из tg-core при mode=status)
tg_project_status() {
    local server_ip proxy_port
    server_ip=$(hostname -I | awk '{print $1}')
    proxy_port=$(grep -oP '(?<=-H )\d+' "$SERVICE_FILE" 2>/dev/null || echo "N/A")

    if systemctl is-active --quiet mtproto-proxy 2>/dev/null; then
        printf "🔘 Статус: <b>✅ Работает</b>\n🖥 Сервер: <code>%s:%s</code>" \
            "$server_ip" "$proxy_port"
    else
        printf "🔘 Статус: <b>❌ Остановлен</b>\n🖥 Сервер: <code>%s:%s</code>" \
            "$server_ip" "$proxy_port"
    fi
}

# Колбек: полный отчёт (mode=full)
tg_project_full_report() {
    local server_ip proxy_port pid cpu mem rss_mb uptime_str connections svc

    server_ip=$(hostname -I | awk '{print $1}')
    proxy_port=$(grep -oP '(?<=-H )\d+' "$SERVICE_FILE" 2>/dev/null || echo "N/A")

    if systemctl is-active --quiet mtproto-proxy 2>/dev/null; then
        svc="✅ Работает"
    else
        svc="❌ Остановлен"
        printf "📡 <b>MTProto Proxy — Статистика</b>\n\n🔘 Статус: <b>%s</b>\n🖥 Сервер: <code>%s:%s</code>\n\n🕐 <i>%s</i>" \
            "$svc" "$server_ip" "$proxy_port" "$(date '+%d.%m.%Y %H:%M:%S')"
        return
    fi

    pid=$(systemctl show -p MainPID mtproto-proxy 2>/dev/null | cut -d= -f2)
    if [ -n "$pid" ] && [ "$pid" != "0" ] && kill -0 "$pid" 2>/dev/null; then
        cpu=$(ps -p "$pid" -o %cpu= 2>/dev/null | xargs || echo "—")
        mem=$(ps -p "$pid" -o %mem= 2>/dev/null | xargs || echo "—")
        local rss; rss=$(ps -p "$pid" -o rss= 2>/dev/null | xargs || echo "0")
        rss_mb=$(( rss / 1024 ))
        local active_since; active_since=$(systemctl show -p ActiveEnterTimestamp mtproto-proxy 2>/dev/null | cut -d= -f2)
        if [ -n "$active_since" ]; then
            local diff hh mm ss
            diff=$(( $(date +%s) - $(date -d "$active_since" +%s 2>/dev/null || echo 0) ))
            hh=$(( diff/3600 )); mm=$(( (diff%3600)/60 )); ss=$(( diff%60 ))
            uptime_str=$(printf "%02d:%02d:%02d" $hh $mm $ss)
        else
            uptime_str="N/A"
        fi
        connections=$(ss -tn state established "( dport = :$proxy_port )" 2>/dev/null | tail -n +2 | wc -l || echo "0")
    else
        cpu="—"; mem="—"; rss_mb="—"; uptime_str="—"; connections="—"
    fi

    printf "📡 <b>MTProto Proxy — Статистика</b>\n\n🔘 Статус:    <b>%s</b>\n🖥 Сервер:    <code>%s:%s</code>\n⏱ Аптайм:    <code>%s</code>\n👥 Соединений: <b>%s</b>\n\n📊 <b>Ресурсы:</b>\n  CPU: <code>%s%%</code>\n  RAM: <code>%s%%</code> (%s MB)\n\n🕐 <i>%s</i>" \
        "$svc" "$server_ip" "$proxy_port" "$uptime_str" "$connections" \
        "$cpu" "$mem" "$rss_mb" "$(date '+%d.%m.%Y %H:%M:%S')"
}

# Функция-обёртка для построения сообщений (передаётся в tg-core как TG_BUILD_MSG_FN)
mtproto_tg_build_msg() {
    local mode="$1"
    if [ "$mode" = "full" ]; then
        tg_project_full_report
    else
        printf "📡 <b>MTProto Proxy</b>\n%s\n🕐 <i>%s</i>" \
            "$(tg_project_status)" "$(date '+%d.%m.%Y %H:%M:%S')"
    fi
}

manager_tg_settings() {
    # Устанавливаем tg-core если не установлен
    if [ ! -f "/opt/tg-core/tg-core.sh" ]; then
        clear_screen
        echo ""
        echo -e " ${BOLD}🤖 TELEGRAM ИНТЕГРАЦИЯ${NC}"
        echo ""
        warning "tg-core.sh не установлен"
        echo ""
        echo " Для работы Telegram уведомлений нужно установить ядро tg-core."
        echo ""
        read -rp " Установить сейчас? (y/n): " install_tg
        if [[ "$install_tg" =~ ^[Yy]$ ]]; then
            info "Скачиваем tg-core.sh..."
            mkdir -p /opt/tg-core
            local dl_ok=0
            # Пробуем скачать с GitHub
            if curl -fsSL --max-time 15                 "https://raw.githubusercontent.com/tarpy-socdev/MTP-manager/refs/heads/main/tg-core.sh"                 -o /opt/tg-core/tg-core.sh 2>/dev/null && [ -s /opt/tg-core/tg-core.sh ]; then
                dl_ok=1
            fi
            if [ $dl_ok -eq 0 ]; then
                warning "Не удалось скачать. Помести tg-core.sh вручную в /opt/tg-core/"
                read -rp " Enter... "; return
            fi
            chmod +x /opt/tg-core/tg-core.sh
            success "tg-core.sh установлен"
        else
            return
        fi
    fi

    # Загружаем ядро (один раз — повторные вызовы пропускаются)
    if ! _tg_core_load; then
        warning "Не удалось загрузить tg-core.sh"
        read -rp " Enter... "; return
    fi

    # Загружаем конфиг и открываем настройку
    tg_load_config
    tg_setup_interactive
}


# ============ УСТАНОВКА КОМАНДЫ ============
install_command() {
    local self_path
    self_path=$(readlink -f "$0" 2>/dev/null || echo "")
    if [ "$self_path" != "$MANAGER_PATH" ]; then
        if cp "$0" "$MANAGER_PATH" 2>/dev/null; then
            chmod +x "$MANAGER_PATH"
        else
            curl -fsSL "https://raw.githubusercontent.com/tarpy-socdev/MTP-manager/refs/heads/main/mtproto-universal-v4.sh" \
                -o "$MANAGER_PATH" 2>/dev/null && chmod +x "$MANAGER_PATH" || true
        fi
    fi
}

# ============ ОСНОВНОЙ ЦИКЛ ============
# Режим демона для Telegram уведомлений (вызывается из systemd)
if [ "${1:-}" = "--tg-daemon" ]; then
    # Загружаем ядро и запускаем демон с колбеками проекта
    source /opt/tg-core/tg-core.sh 2>/dev/null || { echo "tg-core not found"; exit 1; }
    tg_daemon_loop
    exit 0
fi

install_command

while true; do
    clear_screen
    status=$(get_installation_status)
    echo ""

    if [ $status -eq 0 ]; then
        echo -e " ${GREEN}✅ MTPROTO УСТАНОВЛЕН И РАБОТАЕТ${NC}"
        echo ""
        echo " 1) 📊 Менеджер"
        echo " 2) ⚙️  Переустановить"
        echo " 3) 🚪 Выход"
        echo ""
        read -rp "Выбор [1-3]: " choice
        case $choice in
            1) run_manager ;;
            2)
                read -rp "⚠️  Переустановить? (yes/no): " confirm
                [ "$confirm" = "yes" ] && { uninstall_mtproxy_silent; run_installer; }
                ;;
            3) echo -e "${GREEN}До свидания! 👋${NC}"; exit 0 ;;
            *) warning "Неправильный выбор"; sleep 2 ;;
        esac

    elif [ $status -eq 1 ]; then
        echo -e " ${RED}❌ MTPROTO УСТАНОВЛЕН НО НЕ РАБОТАЕТ${NC}"
        echo ""
        read -rp "Восстановить? (y/n): " restore
        if [[ "$restore" =~ ^[Yy]$ ]]; then
            systemctl restart mtproto-proxy
            sleep 2
            systemctl is-active --quiet mtproto-proxy && success "Восстановлен!" || warning "Не удалось восстановить"
        fi
        sleep 2

    else
        echo -e " ${YELLOW}⚠️  MTPROTO НЕ УСТАНОВЛЕН${NC}"
        echo ""
        read -rp "Установить? (y/n): " install_choice
        if [[ "$install_choice" =~ ^[Yy]$ ]]; then
            run_installer
        else
            echo -e "${GREEN}До свидания! 👋${NC}"
            exit 0
        fi
    fi
done
