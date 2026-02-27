#!/bin/bash
# ==============================================
# MTProto Proxy — Universal Manager v4.0
# Установка + Менеджер + SOCKS5 в одном скрипте
# github.com/tarpy-socdev/MTP-manager
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
SOCKS5_DIR="/opt/socks5"
SERVICE_FILE="/etc/systemd/system/mtproto-proxy.service"
SOCKS5_SERVICE="/etc/systemd/system/socks5-proxy.service"
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
    echo " ║  MTProto Proxy Manager v4.0 + SOCKS5       ║"
    echo " ║  github.com/tarpy-socdev/MTP-manager       ║"
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

check_socks5_installation() {
    if [ -f "$SOCKS5_SERVICE" ] && systemctl is-active --quiet socks5-proxy 2>/dev/null; then
        return 0
    elif [ -f "$SOCKS5_SERVICE" ]; then
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

get_socks5_status() {
    if check_socks5_installation; then
        echo 0
    elif [ -f "$SOCKS5_SERVICE" ]; then
        echo 1
    else
        echo 2
    fi
}

[[ $EUID -ne 0 ]] && err "Запускай от root! (sudo bash script.sh)"

# ============ УСТАНОВКА SOCKS5 ============
install_socks5() {
    clear_screen
    echo ""
    echo -e "${BOLD}🔐 УСТАНОВКА SOCKS5 ПРОКСИ${NC}"
    echo ""
    
    # Выбор порта для SOCKS5
    echo -e "${BOLD}🔧 Выбери порт для SOCKS5:${NC}"
    echo " 1) 1080 (стандартный SOCKS5 порт)"
    echo " 2) 1085 (альтернативный)"
    echo " 3) 9050 (Tor-стиль)"
    echo " 4) Ввести свой порт"
    echo ""
    read -rp "Твой выбор [1-4]: " SOCKS_PORT_CHOICE

    case $SOCKS_PORT_CHOICE in
        1) SOCKS5_PORT=1080 ;;
        2) SOCKS5_PORT=1085 ;;
        3) SOCKS5_PORT=9050 ;;
        4) 
            read -rp "Введи порт (1-65535): " SOCKS5_PORT
            validate_port "$SOCKS5_PORT"
            ;;
        *) 
            info "Значение по умолчанию: 1080"
            SOCKS5_PORT=1080
            ;;
    esac

    check_port_available "$SOCKS5_PORT"
    info "Используем порт: $SOCKS5_PORT"
    echo ""

    # Аутентификация
    echo -e "${BOLD}🔑 Настроить аутентификацию?${NC}"
    echo " 1) Да (логин + пароль)"
    echo " 2) Нет (открытый доступ)"
    echo ""
    read -rp "Твой выбор [1-2]: " AUTH_CHOICE

    USE_AUTH=0
    if [ "$AUTH_CHOICE" = "1" ]; then
        USE_AUTH=1
        read -rp "Введи логин: " SOCKS5_USER
        read -rsp "Введи пароль: " SOCKS5_PASS
        echo ""
        
        if [ -z "$SOCKS5_USER" ] || [ -z "$SOCKS5_PASS" ]; then
            warning "Логин или пароль пустой! Используем без аутентификации"
            USE_AUTH=0
        else
            info "Аутентификация включена"
        fi
    else
        info "Аутентификация отключена"
    fi
    echo ""

    # Установка 3proxy
    info "Устанавливаем 3proxy..."
    (
        apt update -y > "$LOGFILE" 2>&1
        apt install -y 3proxy >> "$LOGFILE" 2>&1 || {
            # Если 3proxy недоступен в репозитории, собираем из исходников
            apt install -y gcc make git >> "$LOGFILE" 2>&1
            cd /tmp
            git clone https://github.com/3proxy/3proxy.git >> "$LOGFILE" 2>&1
            cd 3proxy
            make -f Makefile.Linux >> "$LOGFILE" 2>&1
            mkdir -p /usr/local/3proxy/bin
            cp bin/3proxy /usr/local/3proxy/bin/
            chmod +x /usr/local/3proxy/bin/3proxy
        }
    ) &
    spinner $! "Устанавливаем 3proxy..."

    # Создаём директорию конфигурации
    mkdir -p "$SOCKS5_DIR"
    
    # Создаём конфиг 3proxy
    cat > "$SOCKS5_DIR/3proxy.cfg" <<EOF
#!/usr/local/3proxy/bin/3proxy
daemon
maxconn 200
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
log /var/log/3proxy.log D
logformat "- +_L%t.%. %N.%p %E %U %C:%c %R:%r %O %I %h %T"
archiver gz /usr/bin/gzip %F
rotate 30
EOF

    if [ "$USE_AUTH" = "1" ]; then
        # С аутентификацией
        cat >> "$SOCKS5_DIR/3proxy.cfg" <<EOF
users $SOCKS5_USER:CL:$SOCKS5_PASS
auth strong
allow $SOCKS5_USER
socks -p$SOCKS5_PORT
EOF
    else
        # Без аутентификации
        cat >> "$SOCKS5_DIR/3proxy.cfg" <<EOF
auth none
allow *
socks -p$SOCKS5_PORT
EOF
    fi

    chmod 600 "$SOCKS5_DIR/3proxy.cfg"

    # Создаём systemd сервис для SOCKS5
    cat > "$SOCKS5_SERVICE" <<EOF
[Unit]
Description=3proxy SOCKS5 Proxy Server
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/3proxy $SOCKS5_DIR/3proxy.cfg
ExecStop=/bin/kill -s TERM \$MAINPID
Restart=on-failure
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF

    # Если 3proxy установлен не в стандартный путь
    if [ -f "/usr/local/3proxy/bin/3proxy" ]; then
        sed -i "s|/usr/bin/3proxy|/usr/local/3proxy/bin/3proxy|g" "$SOCKS5_SERVICE"
    fi

    success "Конфиг создан"

    # Запускаем сервис
    (
        systemctl daemon-reload > /dev/null 2>&1
        systemctl enable socks5-proxy > /dev/null 2>&1
        systemctl restart socks5-proxy > /dev/null 2>&1
    ) &
    spinner $! "Запускаем SOCKS5 сервис..."

    sleep 2

    if ! systemctl is-active --quiet socks5-proxy; then
        err "❌ SOCKS5 сервис не запустился!"
    fi

    success "SOCKS5 прокси запущен"

    # UFW
    if command -v ufw &>/dev/null; then
        (
            ufw delete allow "$SOCKS5_PORT/tcp" > /dev/null 2>&1 || true
            ufw allow "$SOCKS5_PORT/tcp" > /dev/null 2>&1
            UFW_STATUS=$(ufw status | head -1)
            if echo "$UFW_STATUS" | grep -q "active"; then
                ufw reload > /dev/null 2>&1
            fi
        ) &
        spinner $! "Настраиваем UFW для SOCKS5..."
    fi

    # Получение IP
    SERVER_IP=$(curl -s --max-time 3 https://api.ipify.org 2>/dev/null || \
                curl -s --max-time 3 https://ifconfig.me 2>/dev/null || \
                hostname -I | awk '{print $1}')

    # Итоговая информация
    clear_screen
    echo ""
    echo -e " ${GREEN}${BOLD}════════════════════════════════════════════${NC}"
    echo -e " 🎉 SOCKS5 ПРОКСИ УСПЕШНО УСТАНОВЛЕН! 🎉"
    echo -e " ${NC}"
    echo ""
    echo -e " ${YELLOW}Сервер:${NC} ${CYAN}$SERVER_IP${NC}"
    echo -e " ${YELLOW}Порт:${NC} ${CYAN}$SOCKS5_PORT${NC}"
    
    if [ "$USE_AUTH" = "1" ]; then
        echo -e " ${YELLOW}Логин:${NC} ${CYAN}$SOCKS5_USER${NC}"
        echo -e " ${YELLOW}Пароль:${NC} ${CYAN}$SOCKS5_PASS${NC}"
        echo ""
        echo -e "${YELLOW}${BOLD}🔗 Строка подключения:${NC}"
        echo -e "${GREEN}socks5://$SOCKS5_USER:$SOCKS5_PASS@$SERVER_IP:$SOCKS5_PORT${NC}"
    else
        echo ""
        echo -e "${YELLOW}${BOLD}🔗 Строка подключения:${NC}"
        echo -e "${GREEN}socks5://$SERVER_IP:$SOCKS5_PORT${NC}"
    fi
    
    echo ""
    echo -e "${YELLOW}${BOLD}📝 Для проверки:${NC}"
    echo -e "${CYAN}curl --socks5 $SERVER_IP:$SOCKS5_PORT https://ifconfig.me${NC}"
    echo ""
    
    read -rp " Нажми Enter для продолжения... "
}

# ============ УСТАНОВЩИК MTPROTO ============
run_installer() {
    clear_screen
    echo ""
    
    # ШАГ 0 — SOCKS5
    echo -e "${BOLD}🔐 Установить SOCKS5 прокси?${NC}"
    echo " SOCKS5 — это универсальный прокси для любых приложений"
    echo " (браузеры, мессенджеры, торренты и т.д.)"
    echo ""
    echo " 1) Да, установить SOCKS5 (рекомендуется)"
    echo " 2) Нет, только MTProto"
    echo ""
    
    socks5_status=$(get_socks5_status)
    if [ $socks5_status -eq 0 ]; then
        echo -e " ${GREEN}✅ SOCKS5 уже установлен и работает${NC}"
        echo ""
        read -rp "Переустановить SOCKS5? (y/n): " reinstall_socks
        if [[ "$reinstall_socks" =~ ^[Yy]$ ]]; then
            uninstall_socks5_silent
            install_socks5
        fi
    else
        read -rp "Твой выбор [1-2]: " SOCKS5_CHOICE
        
        if [ "$SOCKS5_CHOICE" = "1" ]; then
            install_socks5
        else
            info "SOCKS5 пропущен"
            echo ""
        fi
    fi
    
    # ШАГ 1 — Выбор порта MTProto
    clear_screen
    echo ""
    echo -e "${BOLD}🔧 Выбери порт для MTProto прокси:${NC}"
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
    info "Начинаем установку MTProto..."
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
    spinner $! "Запускаем MTProto сервис..."

    sleep 3

    if ! systemctl is-active --quiet mtproto-proxy; then
        err "❌ MTProto сервис не запустился!"
    fi

    success "MTProto сервис запущен"

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
        spinner $! "Настраиваем UFW для MTProto..."
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
    
    # Показываем оба прокси если SOCKS5 установлен
    socks5_status=$(get_socks5_status)
    if [ $socks5_status -eq 0 ]; then
        echo -e " ${YELLOW}${BOLD}🔐 SOCKS5 ПРОКСИ:${NC}"
        SOCKS5_PORT=$(grep -oP '(?<=socks -p)\d+' "$SOCKS5_DIR/3proxy.cfg" 2>/dev/null || echo "1080")
        if grep -q "^users" "$SOCKS5_DIR/3proxy.cfg" 2>/dev/null; then
            SOCKS5_USER=$(grep "^users" "$SOCKS5_DIR/3proxy.cfg" | cut -d: -f1 | awk '{print $2}')
            echo -e " ${CYAN}socks5://$SOCKS5_USER:*****@$SERVER_IP:$SOCKS5_PORT${NC}"
        else
            echo -e " ${CYAN}socks5://$SERVER_IP:$SOCKS5_PORT${NC}"
        fi
        echo ""
    fi
    
    echo -e " ${YELLOW}${BOLD}📱 MTPROTO ПРОКСИ:${NC}"
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
    
    local socks5_status
    socks5_status=$(get_socks5_status)
    
    echo ""
    echo -e " ${BOLD}📊 СТАТУС СЕРВИСОВ:${NC}"
    echo " ─────────────────────────────────────────────"
    
    # Статус SOCKS5
    if [ $socks5_status -eq 0 ]; then
        echo -e " SOCKS5:  ${GREEN}✅ РАБОТАЕТ${NC}"
    elif [ $socks5_status -eq 1 ]; then
        echo -e " SOCKS5:  ${RED}❌ ОСТАНОВЛЕН${NC}"
    else
        echo -e " SOCKS5:  ${YELLOW}⚠️  НЕ УСТАНОВЛЕН${NC}"
    fi
    
    # Статус MTProto
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
    
    echo -e " ${BOLD}🔐 SOCKS5 УПРАВЛЕНИЕ:${NC}"
    echo " S1) 📈 Статус SOCKS5"
    echo " S2) 🔗 Показать подключение SOCKS5"
    echo " S3) 🔄 Перезагрузить SOCKS5"
    echo " S4) 📦 Установить SOCKS5 (если не установлен)"
    echo " S5) 🗑️  Удалить SOCKS5"
    echo ""
    
    echo -e " ${BOLD}📱 MTPROTO УПРАВЛЕНИЕ:${NC}"
    echo " M1) 📈 Показать статус MTProto"
    echo " M2) 📱 QR-код и ссылка MTProto"
    echo " M3) 🏷️  Применить спонсорский тег"
    echo " M4) ❌ Удалить спонсорский тег"
    echo " M5) 🔧 Изменить порт MTProto"
    echo " M6) 🔄 Перезагрузить MTProto"
    echo " M7) 📝 Просмотреть логи MTProto"
    echo " M8) 🗑️  Удалить MTProto"
    echo ""
    
    echo " 0) 🚪 Выход"
    echo ""
    echo -e " ${CYAN}${BOLD}═════════════════════════════════════════════${NC}"
    echo ""
    read -rp " Выбери опцию: " choice
    
    case $choice in
        # SOCKS5
        S1|s1) manager_socks5_status ;;
        S2|s2) manager_socks5_show_connection ;;
        S3|s3) manager_socks5_restart ;;
        S4|s4) 
            if [ $socks5_status -eq 2 ]; then
                install_socks5
            else
                warning "SOCKS5 уже установлен!"
                sleep 1
            fi
            ;;
        S5|s5) 
            read -rp "⚠️ Это удалит SOCKS5. Ты уверен? (yes/no): " confirm
            if [ "$confirm" = "yes" ]; then
                uninstall_socks5_silent
                success "SOCKS5 удален"
                sleep 1
            fi
            ;;
        
        # MTProto
        M1|m1) manager_show_status ;;
        M2|m2) manager_show_qr ;;
        M3|m3) manager_apply_tag ;;
        M4|m4) manager_remove_tag ;;
        M5|m5) manager_change_port ;;
        M6|m6) manager_restart ;;
        M7|m7) manager_show_logs ;;
        M8|m8) 
            read -rp "⚠️ Это удалит MTProto. Ты уверен? (yes/no): " confirm
            if [ "$confirm" = "yes" ]; then
                uninstall_mtproxy_silent
                success "MTProto удален"
                sleep 1
            fi
            ;;
        
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

# ============ SOCKS5 МЕНЕДЖЕР ============
manager_socks5_status() {
    clear_screen
    echo ""
    
    if [ ! -f "$SOCKS5_SERVICE" ]; then
        warning "SOCKS5 не установлен!"
        read -rp " Нажми Enter для возврата... "
        return
    fi
    
    echo -e " ${YELLOW}${BOLD}✅ СТАТУС SOCKS5: ${NC}"
    
    if systemctl is-active --quiet socks5-proxy; then
        echo -e " ${GREEN}РАБОТАЕТ${NC}"
    else
        echo -e " ${RED}ОСТАНОВЛЕН${NC}"
    fi
    
    echo ""
    echo -e " ${BOLD}📊 ИНФОРМАЦИЯ SOCKS5:${NC}"
    echo " ─────────────────────────────────────────────"
    
    SOCKS5_PORT=$(grep -oP '(?<=socks -p)\d+' "$SOCKS5_DIR/3proxy.cfg" 2>/dev/null || echo "1080")
    SERVER_IP=$(hostname -I | awk '{print $1}')
    
    echo " Сервер IP:  ${CYAN}$SERVER_IP${NC}"
    echo " Порт:       ${CYAN}$SOCKS5_PORT${NC}"
    
    if grep -q "^users" "$SOCKS5_DIR/3proxy.cfg" 2>/dev/null; then
        SOCKS5_USER=$(grep "^users" "$SOCKS5_DIR/3proxy.cfg" | cut -d: -f1 | awk '{print $2}')
        echo " Логин:      ${CYAN}$SOCKS5_USER${NC}"
        echo " Пароль:     ${CYAN}*****${NC}"
        echo " Аутент.:    ${GREEN}ВКЛЮЧЕНА${NC}"
    else
        echo " Аутент.:    ${YELLOW}ОТКЛЮЧЕНА${NC}"
    fi
    
    echo ""
    echo -e " ${BOLD}📈 РЕСУРСЫ:${NC}"
    echo " ─────────────────────────────────────────────"
    ps aux | grep 3proxy | grep -v grep | awk '{printf " PID: %s | CPU: %s%% | MEM: %s%%\n", $2, $3, $4}' || echo " Процесс не найден"
    
    echo ""
    echo -e " ${BOLD}📝 ПОСЛЕДНИЕ ЛОГИ (5 строк):${NC}"
    echo " ─────────────────────────────────────────────"
    journalctl -u socks5-proxy -n 5 --no-pager 2>/dev/null || echo " Логи недоступны"
    
    echo ""
    read -rp " Нажми Enter для возврата в меню... "
}

manager_socks5_show_connection() {
    clear_screen
    echo ""
    
    if [ ! -f "$SOCKS5_SERVICE" ]; then
        warning "SOCKS5 не установлен!"
        read -rp " Нажми Enter для возврата... "
        return
    fi
    
    SERVER_IP=$(hostname -I | awk '{print $1}')
    SOCKS5_PORT=$(grep -oP '(?<=socks -p)\d+' "$SOCKS5_DIR/3proxy.cfg" 2>/dev/null || echo "1080")
    
    echo -e " ${YELLOW}${BOLD}🔗 ПОДКЛЮЧЕНИЕ К SOCKS5:${NC}"
    echo ""
    
    if grep -q "^users" "$SOCKS5_DIR/3proxy.cfg" 2>/dev/null; then
        SOCKS5_USER=$(grep "^users" "$SOCKS5_DIR/3proxy.cfg" | cut -d: -f1 | awk '{print $2}')
        SOCKS5_PASS=$(grep "^users" "$SOCKS5_DIR/3proxy.cfg" | cut -d: -f3)
        
        echo -e " ${CYAN}Сервер:${NC} $SERVER_IP"
        echo -e " ${CYAN}Порт:${NC} $SOCKS5_PORT"
        echo -e " ${CYAN}Логин:${NC} $SOCKS5_USER"
        echo -e " ${CYAN}Пароль:${NC} $SOCKS5_PASS"
        echo ""
        echo -e " ${YELLOW}Строка подключения:${NC}"
        echo -e " ${GREEN}socks5://$SOCKS5_USER:$SOCKS5_PASS@$SERVER_IP:$SOCKS5_PORT${NC}"
    else
        echo -e " ${CYAN}Сервер:${NC} $SERVER_IP"
        echo -e " ${CYAN}Порт:${NC} $SOCKS5_PORT"
        echo ""
        echo -e " ${YELLOW}Строка подключения:${NC}"
        echo -e " ${GREEN}socks5://$SERVER_IP:$SOCKS5_PORT${NC}"
    fi
    
    echo ""
    echo -e " ${YELLOW}${BOLD}💡 Проверка работы:${NC}"
    echo -e " ${CYAN}curl --socks5 $SERVER_IP:$SOCKS5_PORT https://ifconfig.me${NC}"
    echo ""
    
    read -rp " Нажми Enter для возврата в меню... "
}

manager_socks5_restart() {
    clear_screen
    echo ""
    
    if [ ! -f "$SOCKS5_SERVICE" ]; then
        warning "SOCKS5 не установлен!"
        read -rp " Нажми Enter для возврата... "
        return
    fi
    
    echo -e " ${BOLD}🔄 ПЕРЕЗАГРУЗИТЬ SOCKS5${NC}"
    echo ""
    
    systemctl restart socks5-proxy > /dev/null 2>&1
    sleep 2
    
    if systemctl is-active --quiet socks5-proxy; then
        success "SOCKS5 сервис успешно перезагружен!"
    else
        err "Ошибка при перезагрузке SOCKS5!"
    fi
    
    read -rp " Нажми Enter для возврата... "
}

uninstall_socks5_silent() {
    systemctl stop socks5-proxy 2>/dev/null || true
    systemctl disable socks5-proxy 2>/dev/null || true
    rm -rf "$SOCKS5_DIR"
    rm -f "$SOCKS5_SERVICE"
    systemctl daemon-reload > /dev/null 2>&1
}

# ============ MTPROTO МЕНЕДЖЕР (старые функции) ============
manager_show_status() {
    clear_screen
    echo ""
    
    if [ ! -f "$SERVICE_FILE" ]; then
        warning "MTProto не установлен!"
        read -rp " Нажми Enter для возврата... "
        return
    fi
    
    echo -e " ${YELLOW}${BOLD}✅ СТАТУС MTPROTO: ${NC}"
    
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
        warning "MTProto не установлен!"
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
        warning "MTProto не установлен!"
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
        warning "MTProto не установлен!"
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
        warning "MTProto не установлен!"
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
        warning "MTProto не установлен!"
        read -rp " Нажми Enter для возврата... "
        return
    fi
    
    echo -e " ${BOLD}🔄 ПЕРЕЗАГРУЗИТЬ СЕРВИС${NC}"
    echo ""
    
    systemctl restart mtproto-proxy > /dev/null 2>&1
    sleep 2
    
    if systemctl is-active --quiet mtproto-proxy; then
        success "MTProto сервис успешно перезагружен!"
    else
        err "Ошибка при перезагрузке MTProto!"
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
    socks5_status=$(get_socks5_status)
    
    echo ""
    
    if [ $status -eq 0 ]; then
        # MTProto установлен и работает
        echo -e " ${GREEN}✅ СТАТУС: MTPROTO УСТАНОВЛЕН И РАБОТАЕТ${NC}"
        if [ $socks5_status -eq 0 ]; then
            echo -e " ${GREEN}✅ СТАТУС: SOCKS5 УСТАНОВЛЕН И РАБОТАЕТ${NC}"
        fi
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
        # MTProto установлен но не работает
        echo -e " ${RED}❌ СТАТУС: MTPROTO УСТАНОВЛЕН НО НЕ РАБОТАЕТ${NC}"
        echo ""
        read -rp "Восстановить? (y/n): " restore
        if [[ "$restore" =~ ^[Yy]$ ]]; then
            systemctl restart mtproto-proxy
            sleep 2
            if systemctl is-active --quiet mtproto-proxy; then
                success "MTProto восстановлен!"
            else
                warning "Не удалось восстановить MTProto"
            fi
        fi
        sleep 2
    
    else
        # MTProto не установлен
        echo -e " ${YELLOW}⚠️  СТАТУС: MTPROTO НЕ УСТАНОВЛЕН${NC}"
        if [ $socks5_status -eq 0 ]; then
            echo -e " ${GREEN}✅ SOCKS5 уже работает${NC}"
        fi
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
