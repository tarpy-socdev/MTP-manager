#!/bin/bash
# ==============================================
# MTProto Proxy — Universal Manager v3.0
# Установка + Менеджер в одном скрипте
# github.com/tarpy-socdev/MTProto-VPS
# download: https://raw.githubusercontent.com/tarpy-socdev/MTP-manager/main/beta/v3.5_go.sh
# ==============================================
set -e

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
MANAGER_LINK="/usr/local/bin/mtproto-manager"

# ============ ФУНКЦИИ ============

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
    echo " ║  MTProto Proxy Manager v3.0                ║"
    echo " ║  github.com/tarpy-socdev/MTProto-VPS      ║"
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

validate_port() {
    local port=$1
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        err "❌ Некорректный порт! Используй 1-65535"
    fi
}

check_port_available() {
    local port=$1
    if netstat -tuln 2>/dev/null | grep -q ":$port " || ss -tuln 2>/dev/null | grep -q ":$port "; then
        err "❌ Порт $port уже занят! Выбери другой"
    fi
}

generate_qr_code() {
    local data=$1
    
    if ! command -v qrencode &>/dev/null; then
        info "Устанавливаем qrencode для QR-кодов..."
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

# ============ ГЛАВНОЕ МЕНЮ ============
show_start_menu() {
    clear_screen
    
    local status
    status=$(get_installation_status)
    
    echo ""
    
    if [ $status -eq 0 ]; then
        echo -e " ${GREEN}✅ СТАТУС: ПРОКСИ УСТАНОВЛЕН И РАБОТАЕТ${NC}"
        echo ""
        echo -e " ${BOLD}🎯 Выбери действие:${NC}"
        echo " ─────────────────────────────────────────────"
        echo ""
        echo " 1) 📊 Менеджер прокси"
        echo " 2) ⚙️  Переустановить прокси"
        echo " 3) 🚪 Выход"
        echo ""
        read -rp "Твой выбор [1-3]: " choice
        
        case $choice in
            1) run_manager ;;
            2) 
                read -rp "⚠️ Это удалит текущий прокси. Ты уверен? (yes/no): " confirm
                if [ "$confirm" = "yes" ]; then
                    uninstall_mtproxy_silent
                    run_installer
                else
                    info "Отменено"
                fi
                ;;
            3) echo -e "${GREEN}До свидания! 👋${NC}"; exit 0 ;;
            *) warning "Неправильный выбор"; sleep 1; show_start_menu ;;
        esac
    elif [ $status -eq 1 ]; then
        echo -e " ${RED}❌ СТАТУС: ПРОКСИ УСТАНОВЛЕН НО НЕ РАБОТАЕТ${NC}"
        echo ""
        read -rp "Восстановить? (y/n): " restore
        if [[ "$restore" =~ ^[Yy]$ ]]; then
            systemctl restart mtproto-proxy
            sleep 2
            if systemctl is-active --quiet mtproto-proxy; then
                success "Прокси восстановлен!"
            else
                warning "Не удалось восстановить"
            fi
        fi
        sleep 1
        show_start_menu
    else
        echo -e " ${YELLOW}⚠️  СТАТУС: ПРОКСИ НЕ УСТАНОВЛЕН${NC}"
        echo ""
        read -rp "Установить MTProto прокси? (y/n): " install_choice
        if [[ "$install_choice" =~ ^[Yy]$ ]]; then
            run_installer
        else
            info "Выход"
            exit 0
        fi
    fi
}

# ============ УСТАНОВЩИК ============
run_installer() {
    clear_screen
    echo ""
    
    # ШАГ 1 — Выбор порта
    echo -e "${BOLD}🔧 Выбери порт для прокси:${NC}"
    echo " 1) 443 (выглядит как HTTPS, лучший вариант)"
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
            info "Значение по умолчанию: 8080"
            PROXY_PORT=8080
            ;;
    esac

    check_port_available "$PROXY_PORT"
    info "Используем порт: $PROXY_PORT"
    echo ""

    # ШАГ 2 — От какого пользователя запускать
    echo -e "${BOLD}👤 От какого пользователя запускать сервис?${NC}"
    echo " 1) root (проще, работает с любым портом)"
    echo " 2) mtproxy (безопаснее, но нужен порт > 1024)"
    echo ""
    read -rp "Твой выбор [1-2]: " USER_CHOICE

    NEED_CAP=0
    case $USER_CHOICE in
        1) RUN_USER="root" ;;
        2) 
            RUN_USER="mtproxy"
            if [ "$PROXY_PORT" -lt 1024 ]; then
                info "Для портов < 1024 будет использована возможность CAP_NET_BIND_SERVICE"
                NEED_CAP=1
            fi
            ;;
        *) 
            info "Значение по умолчанию: root"
            RUN_USER="root"
            ;;
    esac

    echo -e "${CYAN}✓ Пользователь: $RUN_USER${NC}"
    echo ""

    # ШАГ 3 — Обновление системы
    echo -e "${BOLD}🔄 Обновить систему?${NC}"
    echo " 1) Да, обновить (медленнее, но безопаснее)"
    echo " 2) Нет, пропустить (быстро, могут быть проблемы)"
    echo ""
    read -rp "Твой выбор [1-2]: " UPDATE_CHOICE

    UPDATE_SYSTEM=0
    case $UPDATE_CHOICE in
        1) 
            UPDATE_SYSTEM=1
            info "Система будет обновлена"
            ;;
        2) 
            UPDATE_SYSTEM=0
            info "Обновление системы пропущено"
            ;;
        *) 
            UPDATE_SYSTEM=1
            info "По умолчанию: обновляем систему"
            ;;
    esac
    echo ""

    INTERNAL_PORT=8888

    # Получение IP
    info "Определяем IP адрес сервера..."
    SERVER_IP=$(curl -s --max-time 3 https://api.ipify.org 2>/dev/null || \
                curl -s --max-time 3 https://ifconfig.me 2>/dev/null || \
                hostname -I | awk '{print $1}')

    if [[ -z "$SERVER_IP" ]]; then
        err "❌ Не удалось определить IP сервера. Проверь подключение к интернету"
    fi

    echo -e "${CYAN}✓ IP сервера: $SERVER_IP${NC}"
    echo ""
    info "Начинаем установку..."
    echo ""

    # Системные зависимости
    if [ "$UPDATE_SYSTEM" = "1" ]; then
        (
            apt update -y > "$LOGFILE" 2>&1
            apt upgrade -y >> "$LOGFILE" 2>&1
            apt install -y git curl build-essential libssl-dev zlib1g-dev xxd netcat-openbsd >> "$LOGFILE" 2>&1
        ) &
        spinner $! "Обновляем систему и ставим зависимости..."
    else
        (
            apt install -y git curl build-essential libssl-dev zlib1g-dev xxd netcat-openbsd >> "$LOGFILE" 2>&1
        ) &
        spinner $! "Устанавливаем зависимости (без обновления системы)..."
    fi

    # Клонируем репозиторий
    (
        rm -rf "$INSTALL_DIR"
        git clone https://github.com/GetPageSpeed/MTProxy "$INSTALL_DIR" >> "$LOGFILE" 2>&1
    ) &
    spinner $! "Клонируем репозиторий MTProxy..."

    if [ ! -f "$INSTALL_DIR/Makefile" ]; then
        err "❌ Ошибка загрузки репозитория! Проверь интернет"
    fi

    # Собираем бинарник
    (
        cd "$INSTALL_DIR" && make >> "$LOGFILE" 2>&1
    ) &
    spinner $! "Собираем бинарник..."

    if [ ! -f "$INSTALL_DIR/objs/bin/mtproto-proxy" ]; then
        err "❌ Ошибка компиляции! Смотри лог: $LOGFILE"
    fi

    cp "$INSTALL_DIR/objs/bin/mtproto-proxy" "$INSTALL_DIR/"
    chmod +x "$INSTALL_DIR/mtproto-proxy"
    success "Бинарник скопирован"

    # Скачиваем конфиги Telegram
    (
        curl -s --max-time 10 https://core.telegram.org/getProxySecret -o "$INSTALL_DIR/proxy-secret" >> "$LOGFILE" 2>&1
        curl -s --max-time 10 https://core.telegram.org/getProxyConfig -o "$INSTALL_DIR/proxy-multi.conf" >> "$LOGFILE" 2>&1
    ) &
    spinner $! "Скачиваем конфиги Telegram..."

    if [ ! -s "$INSTALL_DIR/proxy-secret" ] || [ ! -s "$INSTALL_DIR/proxy-multi.conf" ]; then
        err "❌ Ошибка загрузки конфигов Telegram! Проверь подключение"
    fi

    # Генерируем секрет
    SECRET=$(head -c 16 /dev/urandom | xxd -ps)
    echo "$SECRET" > "$INSTALL_DIR/secret.txt"
    success "Секрет сгенерирован"

    # Создаём пользователя mtproxy
    if ! id "mtproxy" &>/dev/null; then
        useradd -m -s /bin/false mtproxy > /dev/null 2>&1
        success "Пользователь mtproxy создан"
    fi

    # Настраиваем права доступа
    if [ "$RUN_USER" = "mtproxy" ]; then
        chown -R mtproxy:mtproxy "$INSTALL_DIR"
    else
        chown -R root:root "$INSTALL_DIR"
    fi

    if [ "$NEED_CAP" = "1" ]; then
        setcap 'cap_net_bind_service=+ep' "$INSTALL_DIR/mtproto-proxy"
        success "Установлены capabilities для привилегированного порта"
    fi

    # Создание systemd сервиса
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

    sed -i "s|INSTALL_DIR|$INSTALL_DIR|g" "$SERVICE_FILE"
    sed -i "s|RUN_USER|$RUN_USER|g" "$SERVICE_FILE"
    sed -i "s|INTERNAL_PORT|$INTERNAL_PORT|g" "$SERVICE_FILE"
    sed -i "s|PROXY_PORT|$PROXY_PORT|g" "$SERVICE_FILE"
    sed -i "s|SECRET|$SECRET|g" "$SERVICE_FILE"

    success "Systemd сервис создан"

    # Запускаем сервис
    (
        systemctl daemon-reload > /dev/null 2>&1
        systemctl enable mtproto-proxy > /dev/null 2>&1
        systemctl restart mtproto-proxy > /dev/null 2>&1
    ) &
    spinner $! "Запускаем сервис..."

    sleep 3

    if ! systemctl is-active --quiet mtproto-proxy; then
        err "❌ Сервис не запустился!"
    fi

    success "Сервис запущен"

    # UFW
    if command -v ufw &>/dev/null; then
        (
            ufw delete allow "$PROXY_PORT/tcp" > /dev/null 2>&1 || true
            ufw allow "$PROXY_PORT/tcp" > /dev/null 2>&1
            UFW_STATUS=$(ufw status | head -1)
            if echo "$UFW_STATUS" | grep -q "active"; then
                ufw reload > /dev/null 2>&1
            fi
        ) &
        spinner $! "Настраиваем UFW..."
    fi

    # ============ СПОНСОРСКИЙ ТАГ ============
    clear_screen
    echo ""
    echo -e "${YELLOW}${BOLD}📌 Что такое тег спонсора?${NC}"
    echo ""
    echo " Когда пользователь подключается к твоему прокси,"
    echo " Telegram показывает ему плашку с названием канала"
    echo " или именем — это и есть тег спонсора."
    echo " Это бесплатный способ продвигать свой канал."
    echo ""

    echo -e "${YELLOW}${BOLD}🔗 Как получить тег:${NC}"
    echo ""
    echo " 1. Открой @MTProxybot в Telegram"
    echo " 2. Отправь команду /newproxy"
    echo " 3. Бот попросит данные прокси — они ниже:"
    echo ""
    echo -e " ┌─────────────────────────────────────────┐"
    echo -e " │ Host:Port ${CYAN}${SERVER_IP}:${PROXY_PORT}${NC}"
    echo -e " │ Секрет    ${CYAN}${SECRET}${NC}"
    echo -e " └─────────────────────────────────────────┘"
    echo ""
    echo " 4. После создания бот выдаст тег — вставь его ниже"
    echo ""
    read -rp " Введи тег (или Enter чтобы пропустить): " SPONSOR_TAG

    if [ -n "$SPONSOR_TAG" ]; then
        sed -i "s|-M 1$|-M 1 -P $SPONSOR_TAG|" "$SERVICE_FILE"
        systemctl daemon-reload > /dev/null 2>&1
        systemctl restart mtproto-proxy > /dev/null 2>&1
        sleep 2
        success "Тег добавлен и сервис перезагружен"
    fi

    # ============ ИТОГ ============
    if [ -n "$SPONSOR_TAG" ]; then
        PROXY_LINK="tg://proxy?server=${SERVER_IP}&port=${PROXY_PORT}&secret=${SECRET}&t=${SPONSOR_TAG}"
    else
        PROXY_LINK="tg://proxy?server=${SERVER_IP}&port=${PROXY_PORT}&secret=${SECRET}"
    fi

    if systemctl is-active --quiet mtproto-proxy; then
        SVC_STATUS="${GREEN}✅ РАБОТАЕТ${NC}"
    else
        SVC_STATUS="${RED}❌ ОШИБКА${NC}"
    fi

    clear_screen
    echo ""
    echo -e " ${GREEN}${BOLD}════════════════════════════════════════════${NC}"
    echo -e " 🎉 УСТАНОВКА УСПЕШНО ЗАВЕРШЕНА! 🎉"
    echo -e " ${NC}"
    echo ""
    echo -e " ${YELLOW}Статус:${NC} $(echo -e $SVC_STATUS)"
    echo -e " ${YELLOW}Сервер:${NC} ${CYAN}$SERVER_IP${NC}"
    echo -e " ${YELLOW}Порт:${NC} ${CYAN}$PROXY_PORT${NC}"
    echo -e " ${YELLOW}Секрет:${NC} ${CYAN}$SECRET${NC}"
    [ -n "$SPONSOR_TAG" ] && echo -e " ${YELLOW}Тег:${NC} ${CYAN}$SPONSOR_TAG${NC}"
    echo ""

    echo -e "${YELLOW}${BOLD}📱 QR-код для подключения:${NC}"
    echo ""
    generate_qr_code "$PROXY_LINK"
    echo ""

    echo -e "${YELLOW}${BOLD}🔗 Ссылка для Telegram:${NC}"
    echo -e "${GREEN}${BOLD}$PROXY_LINK${NC}"
    echo ""

    echo -e "${YELLOW}${BOLD}💡 Дальше используй менеджер:${NC}"
    echo -e " ${CYAN}sudo mtproto-manager${NC}"
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
    
    if [ $status -eq 0 ]; then
        echo -e " ${GREEN}✅ СТАТУС: РАБОТАЕТ${NC}"
    elif [ $status -eq 1 ]; then
        echo -e " ${RED}❌ СТАТУС: ОСТАНОВЛЕН${NC}"
    else
        echo -e " ${YELLOW}⚠️  СТАТУС: НЕ УСТАНОВЛЕН${NC}"
    fi
    
    echo ""
    echo -e " ${CYAN}${BOLD}═════════════════════════════════════════════${NC}"
    echo ""
    
    if [ $status -ne 2 ]; then
        echo -e " ${BOLD}📊 УПРАВЛЕНИЕ:${NC}"
        echo " 1) 📈 Показать статус"
        echo " 2) 📱 QR-код и ссылка"
        echo " 3) 🏷️ Применить спонсорский тег"
        echo " 4) ❌ Удалить спонсорский тег"
        echo " 5) 🔧 Изменить порт"
        echo " 6) 🔄 Перезагрузить сервис"
        echo " 7) 📝 Просмотреть логи"
        echo " 8) 🗑️ Удалить прокси"
        echo ""
    else
        echo -e " ${BOLD}⚡ ПЕРВЫЙ ЗАПУСК:${NC}"
        echo " 0) 📦 Установить прокси"
        echo ""
    fi
    
    echo " 9) 🚪 Выход"
    echo ""
    echo -e " ${CYAN}${BOLD}═════════════════════════════════════════════${NC}"
    echo ""
    read -rp " Выбери опцию: " choice
    
    case $choice in
        1) manager_show_status ;;
        2) manager_show_qr ;;
        3) manager_apply_tag ;;
        4) manager_remove_tag ;;
        5) manager_change_port ;;
        6) manager_restart ;;
        7) manager_show_logs ;;
        8) 
            read -rp "⚠️ Это удалит прокси. Ты уверен? (yes/no): " confirm
            if [ "$confirm" = "yes" ]; then
                uninstall_mtproxy_silent
                info "Прокси удален. Выход..."
                sleep 1
                exit 0
            fi
            ;;
        0) 
            if [ $status -eq 2 ]; then
                run_installer
            else
                warning "Прокси уже установлен!"
                sleep 1
            fi
            ;;
        9) 
            echo -e "${GREEN}До свидания! 👋${NC}"
            exit 0
            ;;
        *) 
            warning "Неправильный выбор"
            sleep 1
            ;;
    esac
}

manager_show_status() {
    clear_screen
    echo ""
    
    if [ ! -f "$SERVICE_FILE" ]; then
        warning "Прокси не установлен!"
        read -rp " Нажми Enter для возврата... "
        return
    fi
    
    echo -e " ${YELLOW}${BOLD}✅ СТАТУС: ${NC}"
    
    if systemctl is-active --quiet mtproto-proxy; then
        echo -e " ${GREEN}РАБОТАЕТ${NC}"
    else
        echo -e " ${RED}ОСТАНОВЛЕН${NC}"
    fi
    
    echo ""
    echo -e " ${BOLD}📊 ИНФОРМАЦИЯ СЕРВИСА:${NC}"
    echo " ─────────────────────────────────────────────"
    
    PROXY_PORT=$(grep -oP '(?<=-H )\d+' "$SERVICE_FILE" || echo "N/A")
    INTERNAL_PORT=$(grep -oP '(?<=-p )\d+' "$SERVICE_FILE" || echo "8888")
    RUN_USER=$(grep "^User=" "$SERVICE_FILE" | cut -d'=' -f2)
    SECRET=$(grep -oP '(?<=-S )\S+' "$SERVICE_FILE" || echo "N/A")
    SERVER_IP=$(hostname -I | awk '{print $1}')
    
    echo " Пользователь:  ${CYAN}$RUN_USER${NC}"
    echo " Сервер IP:     ${CYAN}$SERVER_IP${NC}"
    echo " Внешний порт:  ${CYAN}$PROXY_PORT${NC}"
    echo " Внутренний порт: ${CYAN}$INTERNAL_PORT${NC}"
    echo " Секрет:        ${CYAN}${SECRET:0:16}...${NC}"
    
    if grep -q -- "-P " "$SERVICE_FILE"; then
        SPONSOR_TAG=$(grep -oP '(?<=-P )\S+' "$SERVICE_FILE" || echo "N/A")
        echo " Тег спонсора:  ${CYAN}$SPONSOR_TAG${NC}"
    else
        echo " Тег спонсора:  ${YELLOW}не установлен${NC}"
    fi
    
    echo ""
    echo -e " ${BOLD}📈 РЕСУРСЫ:${NC}"
    echo " ─────────────────────────────────────────────"
    ps aux | grep mtproto-proxy | grep -v grep | awk '{printf " PID: %s | CPU: %s%% | MEM: %s%%\n", $2, $3, $4}' || echo " Процесс не найден"
    
    echo ""
    echo -e " ${BOLD}📝 ПОСЛЕДНИЕ ЛОГИ (5 строк):${NC}"
    echo " ─────────────────────────────────────────────"
    journalctl -u mtproto-proxy -n 5 --no-pager 2>/dev/null || echo " Логи недоступны"
    
    echo ""
    read -rp " Нажми Enter для возврата в меню... "
}

manager_show_qr() {
    clear_screen
    echo ""
    
    if [ ! -f "$SERVICE_FILE" ]; then
        warning "Прокси не установлен!"
        read -rp " Нажми Enter для возврата... "
        return
    fi
    
    SERVER_IP=$(hostname -I | awk '{print $1}')
    PROXY_PORT=$(grep -oP '(?<=-H )\d+' "$SERVICE_FILE" || echo "8080")
    SECRET=$(grep -oP '(?<=-S )\S+' "$SERVICE_FILE" || echo "")
    
    if grep -q -- "-P " "$SERVICE_FILE"; then
        SPONSOR_TAG=$(grep -oP '(?<=-P )\S+' "$SERVICE_FILE" || echo "")
        PROXY_LINK="tg://proxy?server=${SERVER_IP}&port=${PROXY_PORT}&secret=${SECRET}&t=${SPONSOR_TAG}"
    else
        PROXY_LINK="tg://proxy?server=${SERVER_IP}&port=${PROXY_PORT}&secret=${SECRET}"
    fi
    
    echo -e " ${YELLOW}${BOLD}📱 QR-КОД:${NC}"
    echo ""
    generate_qr_code "$PROXY_LINK"
    echo ""
    
    echo -e " ${YELLOW}${BOLD}🔗 ССЫЛКА:${NC}"
    echo -e " ${GREEN}${BOLD}$PROXY_LINK${NC}"
    echo ""
    
    echo -e " ${YELLOW}${BOLD}📋 ДАННЫЕ ДЛЯ @MTProxybot:${NC}"
    echo ""
    echo -e " ┌─────────────────────────────────────────┐"
    echo -e " │ Host:Port ${CYAN}${SERVER_IP}:${PROXY_PORT}${NC}"
    echo -e " │ Секрет    ${CYAN}${SECRET}${NC}"
    echo -e " └─────────────────────────────────────────┘"
    echo ""
    read -rp " Нажми Enter для возврата в меню... "
}

manager_apply_tag() {
    clear_screen
    echo ""
    
    if [ ! -f "$SERVICE_FILE" ]; then
        warning "Прокси не установлен!"
        read -rp " Нажми Enter для возврата... "
        return
    fi
    
    echo -e " ${BOLD}🏷️ ПРИМЕНИТЬ СПОНСОРСКИЙ ТАГ${NC}"
    echo ""
    read -rp " Введи спонсорский тег: " SPONSOR_TAG
    
    if [ -z "$SPONSOR_TAG" ]; then
        warning "Тег не введен"
        read -rp " Нажми Enter для возврата... "
        return
    fi
    
    if grep -q -- "-P " "$SERVICE_FILE"; then
        sed -i "s|-P [^ ]*|-P $SPONSOR_TAG|" "$SERVICE_FILE"
    else
        sed -i "s|-M 1$|-M 1 -P $SPONSOR_TAG|" "$SERVICE_FILE"
    fi
    
    systemctl daemon-reload > /dev/null 2>&1
    systemctl restart mtproto-proxy > /dev/null 2>&1
    sleep 2
    
    success "Спонсорский тег применен!"
    read -rp " Нажми Enter для возврата... "
}

manager_remove_tag() {
    clear_screen
    echo ""
    
    if [ ! -f "$SERVICE_FILE" ]; then
        warning "Прокси не установлен!"
        read -rp " Нажми Enter для возврата... "
        return
    fi
    
    if ! grep -q -- "-P " "$SERVICE_FILE"; then
        warning "Спонсорский тег не установлен"
        read -rp " Нажми Enter для возврата... "
        return
    fi
    
    echo -e " ${BOLD}⚠️ УДАЛИТЬ СПОНСОРСКИЙ ТАГ${NC}"
    echo ""
    read -rp " Ты уверен? (yes/no): " confirm
    
    if [ "$confirm" = "yes" ]; then
        sed -i "s| -P [^ ]*||" "$SERVICE_FILE"
        systemctl daemon-reload > /dev/null 2>&1
        systemctl restart mtproto-proxy > /dev/null 2>&1
        sleep 2
        success "Спонсорский тег удален!"
    else
        info "Отменено"
    fi
    
    read -rp " Нажми Enter для возврата... "
}

manager_change_port() {
    clear_screen
    echo ""
    
    if [ ! -f "$SERVICE_FILE" ]; then
        warning "Прокси не установлен!"
        read -rp " Нажми Enter для возврата... "
        return
    fi
    
    echo -e " ${BOLD}🔧 ИЗМЕНИТЬ ПОРТ${NC}"
    echo ""
    
    CURRENT_PORT=$(grep -oP '(?<=-H )\d+' "$SERVICE_FILE")
    echo -e " Текущий порт: ${CYAN}$CURRENT_PORT${NC}"
    echo ""
    
    echo " Выбери новый порт:"
    echo " 1) 443 (HTTPS, рекомендуется)"
    echo " 2) 8080 (альтернативный)"
    echo " 3) 8443 (безопасный)"
    echo " 4) Ввести свой"
    echo ""
    
    read -rp "Твой выбор [1-4]: " PORT_CHOICE
    
    case $PORT_CHOICE in
        1) NEW_PORT=443 ;;
        2) NEW_PORT=8080 ;;
        3) NEW_PORT=8443 ;;
        4) 
            read -rp "Введи порт (1-65535): " NEW_PORT
            validate_port "$NEW_PORT"
            ;;
        *) 
            warning "Неправильный выбор"
            read -rp " Нажми Enter для возврата... "
            return
            ;;
    esac
    
    if netstat -tuln 2>/dev/null | grep -q ":$NEW_PORT " || ss -tuln 2>/dev/null | grep -q ":$NEW_PORT "; then
        err "Порт $NEW_PORT уже занят!"
    fi
    
    sed -i "s|-H [0-9]*|-H $NEW_PORT|" "$SERVICE_FILE"
    systemctl daemon-reload > /dev/null 2>&1
    systemctl restart mtproto-proxy > /dev/null 2>&1
    sleep 2
    
    success "Порт изменен на $NEW_PORT!"
    read -rp " Нажми Enter для возврата... "
}

manager_restart() {
    clear_screen
    echo ""
    
    if [ ! -f "$SERVICE_FILE" ]; then
        warning "Прокси не установлен!"
        read -rp " Нажми Enter для возврата... "
        return
    fi
    
    echo -e " ${BOLD}🔄 ПЕРЕЗАГРУЗИТЬ СЕРВИС${NC}"
    echo ""
    
    systemctl restart mtproto-proxy > /dev/null 2>&1
    sleep 2
    
    if systemctl is-active --quiet mtproto-proxy; then
        success "Сервис успешно перезагружен!"
    else
        err "Ошибка при перезагрузке сервиса!"
    fi
    
    read -rp " Нажми Enter для возврата... "
}

manager_show_logs() {
    clear_screen
    echo ""
    echo -e " ${BOLD}📝 ЛОГИ MTPROTO-PROXY (последние 50 строк)${NC}"
    echo " ─────────────────────────────────────────────"
    echo ""
    
    journalctl -u mtproto-proxy -n 50 --no-pager 2>/dev/null || echo " Логи недоступны"
    
    echo ""
    read -rp " Нажми Enter для возврата в меню... "
}

uninstall_mtproxy_silent() {
    systemctl stop mtproto-proxy 2>/dev/null || true
    systemctl disable mtproto-proxy 2>/dev/null || true
    rm -rf "$INSTALL_DIR"
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload > /dev/null 2>&1
}

# ============ УСТАНОВКА КОМАНДЫ ============
install_command() {
    if [ ! -L "$MANAGER_LINK" ] || [ "$(readlink $MANAGER_LINK)" != "$0" ]; then
        ln -sf "$0" "$MANAGER_LINK" 2>/dev/null || true
        chmod +x "$MANAGER_LINK" 2>/dev/null || true
    fi
}

# ============ ОСНОВНОЙ ЦИКЛ ============
install_command

# Главный цикл программы
while true; do
    clear_screen
    
    status=$(get_installation_status)
    
    echo ""
    
    if [ $status -eq 0 ]; then
        # Прокси установлен и работает
        echo -e " ${GREEN}✅ СТАТУС: ПРОКСИ УСТАНОВЛЕН И РАБОТАЕТ${NC}"
        echo ""
        echo -e " ${BOLD}🎯 Выбери действие:${NC}"
        echo " ─────────────────────────────────────────────"
        echo ""
        echo " 1) 📊 Менеджер прокси"
        echo " 2) ⚙️  Переустановить прокси"
        echo " 3) 🚪 Выход"
        echo ""
        read -rp "Твой выбор [1-3]: " choice
        
        case $choice in
            1) run_manager ;;
            2) 
                read -rp "⚠️ Это удалит текущий прокси. Ты уверен? (yes/no): " confirm
                if [ "$confirm" = "yes" ]; then
                    uninstall_mtproxy_silent
                    run_installer
                fi
                ;;
            3) echo -e "${GREEN}До свидания! 👋${NC}"; exit 0 ;;
            *) warning "Неправильный выбор"; sleep 2 ;;
        esac
    
    elif [ $status -eq 1 ]; then
        # Прокси установлен но не работает
        echo -e " ${RED}❌ СТАТУС: ПРОКСИ УСТАНОВЛЕН НО НЕ РАБОТАЕТ${NC}"
        echo ""
        read -rp "Восстановить? (y/n): " restore
        if [[ "$restore" =~ ^[Yy]$ ]]; then
            systemctl restart mtproto-proxy
            sleep 2
            if systemctl is-active --quiet mtproto-proxy; then
                success "Прокси восстановлен!"
            else
                warning "Не удалось восстановить"
            fi
        fi
        sleep 2
    
    else
        # Прокси не установлен
        echo -e " ${YELLOW}⚠️  СТАТУС: ПРОКСИ НЕ УСТАНОВЛЕН${NC}"
        echo ""
        read -rp "Установить MTProto прокси? (y/n): " install_choice
        if [[ "$install_choice" =~ ^[Yy]$ ]]; then
            run_installer
        else
            echo -e "${GREEN}До свидания! 👋${NC}"
            exit 0
        fi
    fi
done
