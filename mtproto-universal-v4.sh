#!/bin/bash
# ==============================================
# MTProto Proxy — Universal Manager v4.4
# Установка + Менеджер
# github.com/tarpy-socdev/MTP-manager
# ==============================================
# CHANGELOG v4.4:
# - Фикс старт/стоп в одну кнопку (toggle)
# - Смена порта без вылета при занятом порте
# - Вывод действующей ссылки после смены порта
# - Исправлен счётчик соединений (только dport)
# - Исправлены CPU/RAM показатели
# - Оптимизация: кэш get_server_ip
# - TG колбек с реальными данными ресурсов
# - Фикс русских символов в TG именах
# ==============================================

# ============ ЦВЕТА И СТИЛИ ============
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'
BOLD=$'\033[1m'
NC=$'\033[0m'

# ============ ПУТИ И КОНФИГ ============
PROXY_DIR="/opt/mtproxy"
CONFIG_FILE="$PROXY_DIR/config.conf"
SECRET_FILE="$PROXY_DIR/secret"
TAG_FILE="$PROXY_DIR/tag"
SERVICE_NAME="mtproto-proxy"
MANAGER_PATH="/usr/local/bin/mtproto-manager"

# Кэш IP-адреса сервера (обновляется раз в 5 минут)
_SERVER_IP_CACHE=""
_SERVER_IP_CACHE_TIME=0

# TG Core — флаг загрузки
_TG_CORE_LOADED=0

# ============ ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ ============
clear_screen() { printf "\033[2J\033[H"; }

info() { echo -e "${CYAN}ℹ️  $1${NC}"; }
success() { echo -e "${GREEN}✅ $1${NC}"; }
warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }
err() { echo -e "${RED}❌ $1${NC}"; }

# ============ ПОЛУЧЕНИЕ IP (С КЭШЕМ) ============
get_server_ip() {
    local now=$(date +%s)
    local cache_age=$((now - _SERVER_IP_CACHE_TIME))
    
    # Кэш валиден 5 минут
    if [ -n "$_SERVER_IP_CACHE" ] && [ $cache_age -lt 300 ]; then
        echo "$_SERVER_IP_CACHE"
        return 0
    fi
    
    # Обновляем кэш
    local ip=$(curl -s --max-time 3 https://api.ipify.org 2>/dev/null || \
               curl -s --max-time 3 https://ifconfig.me 2>/dev/null || \
               hostname -I 2>/dev/null | awk '{print $1}')
    
    if [ -n "$ip" ]; then
        _SERVER_IP_CACHE="$ip"
        _SERVER_IP_CACHE_TIME=$now
        echo "$ip"
    else
        echo "unknown"
    fi
}

# ============ ПРОВЕРКА УСТАНОВКИ ============
check_installation() {
    [ -f /etc/systemd/system/${SERVICE_NAME}.service ] || return 2
    systemctl is-active --quiet $SERVICE_NAME && return 0 || return 1
}

get_installation_status() {
    check_installation
    echo $?
}

# ============ ПРОВЕРКА ПОРТА ============
check_port_available() {
    local port="$1"
    local skip_port="${2:-}"
    
    # Проверяем что порт не занят (кроме skip_port)
    local used_ports=$(ss -tlnH | awk '{print $4}' | grep -oE '[0-9]+$' | sort -u)
    for p in $used_ports; do
        if [ "$p" = "$port" ] && [ "$p" != "$skip_port" ]; then
            return 1
        fi
    done
    return 0
}

# ============ РЕСУРСЫ (ПРАВИЛЬНЫЕ ФОРМУЛЫ) ============
get_cpu_usage() {
    # Используем top в batch mode
    top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{print 100 - $1}'
}

get_ram_usage() {
    # RAM в процентах и MB
    free -m | awk 'NR==2{printf "%.1f %d", $3*100/$2, $3}'
}

get_proxy_connections() {
    local port=$(grep -oP '(?<=-p )\d+' /etc/systemd/system/${SERVICE_NAME}.service 2>/dev/null || echo "443")
    # Считаем только ESTABLISHED соединения на порту прокси (входящие — dport)
    local count=$(ss -tn state established "( dport = :$port )" 2>/dev/null | grep -c "^ESTAB" 2>/dev/null)
    echo "${count:-0}"
}

get_uptime() {
    systemctl show ${SERVICE_NAME} --property=ActiveEnterTimestamp --value 2>/dev/null | \
    xargs -I{} date -d "{}" +%s 2>/dev/null | \
    xargs -I{} bash -c 'echo $(($(date +%s) - {}))' | \
    awk '{h=int($1/3600); m=int(($1%3600)/60); s=$1%60; printf "%02d:%02d:%02d", h, m, s}'
}

# ============ ЖИВОЙ МОНИТОР РЕСУРСОВ ============
show_resource_live() {
    local port=$(grep -oP '(?<=-p )\d+' /etc/systemd/system/${SERVICE_NAME}.service 2>/dev/null || echo "443")
    local server_ip=$(get_server_ip)
    
    # Альтернативный экран
    tput smcup
    trap 'tput rmcup' EXIT
    
    while true; do
        tput cup 0 0
        tput ed  # Очистка от курсора до конца экрана
        
        local now=$(date +"%H:%M:%S")
        local uptime=$(get_uptime)
        local conns=$(get_proxy_connections)
        local cpu=$(get_cpu_usage)
        local ram_data=$(get_ram_usage)
        local ram_pct=$(echo "$ram_data" | awk '{print $1}')
        local ram_mb=$(echo "$ram_data" | awk '{print $2}')
        
        echo ""
        echo " ╔════════════════════════════════════════════╗"
        echo " ║     MTProto Proxy — Live Monitor           ║"
        echo " ║     $now  [q — выход в меню] ║"
        echo " ╚════════════════════════════════════════════╝"
        
        echo -e " Статус:       ${GREEN}✅ РАБОТАЕТ${NC}"
        echo " Сервер:       $server_ip:$port"
        echo " Аптайм:       $uptime"
        echo " Соединений:   $conns"
        echo ""
        
        # CPU progress bar
        local cpu_int=${cpu%.*}
        local cpu_bars=$((cpu_int / 5))
        printf " CPU: "
        printf '█%.0s' $(seq 1 $cpu_bars)
        printf '░%.0s' $(seq 1 $((20 - cpu_bars)))
        printf " %.1f%%\n" "$cpu"
        
        # RAM progress bar
        local ram_int=${ram_pct%.*}
        local ram_bars=$((ram_int / 5))
        printf " RAM: "
        printf '█%.0s' $(seq 1 $ram_bars)
        printf '░%.0s' $(seq 1 $((20 - ram_bars)))
        printf " %.1f%% (%d MB)\n" "$ram_pct" "$ram_mb"
        
        echo ""
        echo " 📝 Последние логи:"
        echo " ─────────────────────────────────────────────"
        journalctl -u ${SERVICE_NAME} -n 5 --no-pager -o cat | tail -5
        echo ""
        echo " [q] — выход в меню"
        
        # Проверка нажатия q с timeout (2 сек для уменьшения мигания)
        read -t 2 -n 1 key 2>/dev/null
        if [ "$key" = "q" ] || [ "$key" = "Q" ]; then
            break
        fi
    done
    
    tput rmcup
}

# ============ QR КОД ============
manager_show_qr() {
    clear_screen
    local port=$(grep -oP '(?<=-p )\d+' /etc/systemd/system/${SERVICE_NAME}.service 2>/dev/null || echo "443")
    # Читаем секрет из service файла
    local secret=$(grep -oP '(?<=-S )[0-9a-fA-F]+' /etc/systemd/system/${SERVICE_NAME}.service 2>/dev/null)
    [ -z "$secret" ] && secret="unknown"
    
    local server_ip=$(get_server_ip)
    local tag=""
    [ -f "$TAG_FILE" ] && tag=$(cat "$TAG_FILE")
    
    local tg_link="tg://proxy?server=${server_ip}&port=${port}&secret=${secret}"
    [ -n "$tag" ] && tg_link+="&tag=${tag}"
    
    echo ""
    echo -e " ${BOLD}📱 QR КОД ДЛЯ ПОДКЛЮЧЕНИЯ${NC}"
    echo " ─────────────────────────────────────────────"
    echo ""
    
    # Простой ASCII QR через API (без imagemagick)
    if command -v curl >/dev/null 2>&1; then
        echo " Генерируем QR код..."
        local qr_url="https://api.qrserver.com/v1/create-qr-code/?size=300x300&format=png&data=$(echo -n "$tg_link" | jq -sRr @uri 2>/dev/null || python3 -c "import urllib.parse; print(urllib.parse.quote(input()))" <<< "$tg_link" 2>/dev/null || echo "$tg_link")"
        echo " Открой в браузере: $qr_url"
    else
        echo " (Для QR кода установи curl)"
    fi
    
    echo ""
    echo " Ссылка:"
    echo " $tg_link"
    echo ""
    read -rp " Enter для возврата... "
}

# ============ УПРАВЛЕНИЕ СЕРВИСОМ ============
manager_toggle() {
    if systemctl is-active --quiet $SERVICE_NAME; then
        # Работает → останавливаем
        systemctl stop $SERVICE_NAME
        if systemctl is-active --quiet $SERVICE_NAME; then
            err "Не удалось остановить"
        else
            success "Прокси остановлен"
        fi
    else
        # Остановлен → запускаем
        systemctl start $SERVICE_NAME
        sleep 1
        if systemctl is-active --quiet $SERVICE_NAME; then
            success "Прокси запущен"
        else
            err "Не удалось запустить"
        fi
    fi
    sleep 2
}

manager_restart() {
    info "Перезапуск..."
    systemctl restart $SERVICE_NAME
    sleep 2
    systemctl is-active --quiet $SERVICE_NAME && success "Перезапущен" || err "Не удалось перезапустить"
    sleep 2
}

# ============ ТЕГИ ============
manager_apply_tag() {
    clear_screen
    echo ""
    echo -e " ${BOLD}📌 ПРИМЕНИТЬ ПРОМО-ТЕГ${NC}"
    echo " ─────────────────────────────────────────────"
    echo ""
    read -rp " Введи промо-тег (32 hex символа): " tag
    
    if [ -z "$tag" ]; then
        warning "Тег не введён"
        sleep 2
        return
    fi
    
    if ! [[ "$tag" =~ ^[0-9a-fA-F]{32}$ ]]; then
        err "Неверный формат тега (должно быть 32 hex)"
        sleep 2
        return
    fi
    
    echo "$tag" > "$TAG_FILE"
    success "Тег сохранён: $tag"
    info "Перезапусти прокси чтобы применить"
    sleep 2
}

manager_remove_tag() {
    if [ -f "$TAG_FILE" ]; then
        rm -f "$TAG_FILE"
        success "Тег удалён"
        info "Перезапусти прокси чтобы применить"
    else
        warning "Тег не установлен"
    fi
    sleep 2
}

# ============ СМЕНА ПОРТА ============
manager_change_port() {
    clear_screen
    local current_port=$(grep -oP '(?<=-p )\d+' /etc/systemd/system/${SERVICE_NAME}.service 2>/dev/null || echo "443")
    
    echo ""
    echo -e " ${BOLD}🔧 СМЕНА ПОРТА${NC}"
    echo " ─────────────────────────────────────────────"
    echo ""
    echo " Текущий порт: $current_port"
    echo ""
    read -rp " Новый порт (1024-65535): " new_port
    
    # Валидация
    if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1024 ] || [ "$new_port" -gt 65535 ]; then
        err "Неверный порт"
        sleep 2
        return
    fi
    
    if [ "$new_port" = "$current_port" ]; then
        warning "Это текущий порт"
        sleep 2
        return
    fi
    
    # Проверка доступности (пропускаем текущий порт)
    if ! check_port_available "$new_port" "$current_port"; then
        err "Порт $new_port уже занят"
        echo ""
        echo " Занятые порты:"
        ss -tlnH | awk '{print $4}' | grep -oE '[0-9]+$' | sort -u | head -10 | awk '{print "   - " $1}'
        echo ""
        read -rp " Enter для возврата... "
        return
    fi
    
    # Меняем порт в конфиге
    info "Обновляю конфигурацию..."
    sed -i "s/-p $current_port/-p $new_port/" /etc/systemd/system/${SERVICE_NAME}.service
    
    # UFW правило
    if command -v ufw >/dev/null 2>&1; then
        ufw delete allow "$current_port/tcp" 2>/dev/null
        ufw allow "$new_port/tcp" >/dev/null 2>&1
    fi
    
    # Перезапуск
    systemctl daemon-reload
    systemctl restart $SERVICE_NAME
    sleep 2
    
    if systemctl is-active --quiet $SERVICE_NAME; then
        success "Порт изменён: $current_port → $new_port"
        echo ""
        
        # Выводим новую ссылку
        local server_ip=$(get_server_ip)
        # Читаем секрет из service файла
        local secret=$(grep -oP '(?<=-S )[0-9a-fA-F]+' /etc/systemd/system/${SERVICE_NAME}.service 2>/dev/null)
        [ -z "$secret" ] && secret="unknown"
        local tag=""
        [ -f "$TAG_FILE" ] && tag=$(cat "$TAG_FILE")
        
        local tg_link="tg://proxy?server=${server_ip}&port=${new_port}&secret=${secret}"
        [ -n "$tag" ] && tg_link+="&tag=${tag}"
        
        echo -e " ${GREEN}Новая ссылка для подключения:${NC}"
        echo " $tg_link"
        echo ""
    else
        err "Ошибка при перезапуске"
    fi
    
    read -rp " Enter для возврата... "
}

# ============ ЛОГИ ============
manager_show_logs() {
    clear_screen
    echo ""
    echo -e " ${BOLD}📋 ПОСЛЕДНИЕ 50 СТРОК ЛОГОВ${NC}"
    echo " ─────────────────────────────────────────────"
    echo ""
    journalctl -u ${SERVICE_NAME} -n 50 --no-pager
    echo ""
    read -rp " Enter для возврата... "
}

# ============ TELEGRAM ИНТЕГРАЦИЯ ============
# Колбек для построения сообщения TG
mtproxy_build_tg_msg() {
    local chat_id="$1"
    local mode="$2"
    
    local status="❌ Не работает"
    local status_icon="🔴"
    
    if systemctl is-active --quiet $SERVICE_NAME; then
        status="✅ Работает"
        status_icon="🟢"
    fi
    
    local port=$(grep -oP '(?<=-p )\d+' /etc/systemd/system/${SERVICE_NAME}.service 2>/dev/null || echo "443")
    local server_ip=$(get_server_ip)
    
    if [ "$mode" = "status" ]; then
        # Только статус
        echo "${status_icon} <b>MTProto Proxy</b>
Статус: ${status}
Сервер: <code>${server_ip}:${port}</code>"
    else
        # Полный режим
        local uptime=$(get_uptime)
        local conns=$(get_proxy_connections)
        local cpu=$(get_cpu_usage)
        local ram_data=$(get_ram_usage)
        local ram_pct=$(echo "$ram_data" | awk '{print $1}')
        local ram_mb=$(echo "$ram_data" | awk '{print $2}')
        
        echo "${status_icon} <b>MTProto Proxy</b>
Статус: ${status}
Сервер: <code>${server_ip}:${port}</code>
Аптайм: ${uptime}

📊 <b>Ресурсы:</b>
CPU: ${cpu}%
RAM: ${ram_pct}% (${ram_mb} MB)
Соединений: ${conns}"
    fi
}

# Загрузка TG ядра (один раз)
_tg_core_load() {
    [ "$_TG_CORE_LOADED" = "1" ] && return 0  # уже загружено
    
    if [ ! -f "/opt/tg-core/tg-core.sh" ]; then
        return 1
    fi
    
    # Задаём колбеки перед загрузкой ядра
    export TG_PROJECT_NAME="MTProto Proxy"
    export TG_BUILD_MSG_FN="mtproxy_build_tg_msg"
    export TG_SERVICE_NAME="mtproto-tgnotify"
    export TG_DAEMON_PATH="$MANAGER_PATH"
    
    # Загружаем ядро
    local rc=0
    source /opt/tg-core/tg-core.sh 2>/dev/null || rc=$?
    [ $rc -eq 0 ] && _TG_CORE_LOADED=1
    return $rc
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
            if curl -fsSL --max-time 15 \
                "https://raw.githubusercontent.com/tarpy-socdev/MTP-manager/refs/heads/main/tg-core.sh" \
                -o /opt/tg-core/tg-core.sh 2>/dev/null && [ -s /opt/tg-core/tg-core.sh ]; then
                dl_ok=1
            fi
            if [ $dl_ok -eq 0 ]; then
                warning "Не удалось скачать. Помести tg-core.sh вручную в /opt/tg-core/"
                read -rp " Enter... "; return
            fi
            chmod +x /opt/tg-core/tg-core.sh
            success "tg-core.sh установлен"
            sleep 1
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

# ============ УДАЛЕНИЕ ============
uninstall_mtproxy_silent() {
    systemctl stop ${SERVICE_NAME} 2>/dev/null
    systemctl disable ${SERVICE_NAME} 2>/dev/null
    rm -f /etc/systemd/system/${SERVICE_NAME}.service
    systemctl daemon-reload
    rm -rf "$PROXY_DIR"
    
    # Удаляем TG сервис если был
    systemctl stop mtproto-tgnotify 2>/dev/null
    systemctl disable mtproto-tgnotify 2>/dev/null
    rm -f /etc/systemd/system/mtproto-tgnotify.service
    systemctl daemon-reload
}

# ============ УСТАНОВКА ============
run_installer() {
    clear_screen
    echo ""
    echo -e " ${BOLD}🚀 УСТАНОВКА MTPROTO PROXY${NC}"
    echo " ─────────────────────────────────────────────"
    echo ""
    
    # Порт
    read -rp " Порт (по умолчанию 443): " port
    port=${port:-443}
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        err "Неверный порт"
        sleep 2
        return
    fi
    
    if ! check_port_available "$port"; then
        err "Порт $port занят"
        sleep 2
        return
    fi
    
    # Секрет
    info "Генерируем секрет..."
    local secret="ee$(head -c 16 /dev/urandom | xxd -ps -c 16)"
    
    # Создаём директорию
    mkdir -p "$PROXY_DIR"
    echo "$secret" > "$SECRET_FILE"
    
    # Устанавливаем зависимости
    info "Устанавливаем зависимости..."
    apt-get update -qq 2>/dev/null
    apt-get install -y curl wget build-essential libssl-dev zlib1g-dev -qq 2>/dev/null || \
        yum install -y curl wget gcc openssl-devel zlib-devel -q 2>/dev/null
    
    # Компилируем MTProxy
    info "Компилируем MTProto Proxy..."
    cd /tmp
    rm -rf MTProxy
    git clone https://github.com/TelegramMessenger/MTProxy.git >/dev/null 2>&1 || {
        err "Не удалось скачать исходники"
        sleep 2
        return
    }
    
    cd MTProxy
    make >/dev/null 2>&1 || {
        err "Ошибка компиляции"
        sleep 2
        return
    }
    
    cp objs/bin/mtproto-proxy /usr/local/bin/ || {
        err "Не удалось установить бинарник"
        sleep 2
        return
    }
    
    chmod +x /usr/local/bin/mtproto-proxy
    
    # Создаём systemd service
    cat > /etc/systemd/system/${SERVICE_NAME}.service <<EOF
[Unit]
Description=MTProto Proxy
After=network.target

[Service]
Type=simple
WorkingDirectory=$PROXY_DIR
ExecStart=/usr/local/bin/mtproto-proxy -u nobody -p $port -H 443 -S $secret --aes-pwd $PROXY_DIR/proxy-secret $PROXY_DIR/proxy-multi.conf
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    
    # Создаём конфиг
    curl -s https://core.telegram.org/getProxySecret -o $PROXY_DIR/proxy-secret 2>/dev/null
    curl -s https://core.telegram.org/getProxyConfig -o $PROXY_DIR/proxy-multi.conf 2>/dev/null
    
    # UFW
    if command -v ufw >/dev/null 2>&1; then
        ufw allow "$port/tcp" >/dev/null 2>&1
    fi
    
    # Запускаем
    systemctl daemon-reload
    systemctl enable ${SERVICE_NAME} >/dev/null 2>&1
    systemctl start ${SERVICE_NAME}
    
    sleep 2
    
    if systemctl is-active --quiet ${SERVICE_NAME}; then
        success "Установка завершена!"
        echo ""
        local server_ip=$(get_server_ip)
        echo -e " ${GREEN}Ссылка для подключения:${NC}"
        echo " tg://proxy?server=${server_ip}&port=${port}&secret=${secret}"
        echo ""
        read -rp " Enter для перехода в менеджер... "
        run_manager
    else
        err "Не удалось запустить сервис"
        journalctl -u ${SERVICE_NAME} -n 10 --no-pager
        sleep 5
    fi
}

# ============ МЕНЕДЖЕР ============
show_manager_menu() {
    clear_screen
    local status
    status=$(get_installation_status)
    
    echo ""
    echo " ╔════════════════════════════════════════════╗"
    echo " ║     MTProto Proxy Manager v4.4             ║"
    echo " ║     github.com/tarpy-socdev/MTP-manager    ║"
    echo " ╚════════════════════════════════════════════╝"
    
    echo ""
    echo -e " ${BOLD}📊 СТАТУС:${NC}"
    echo " ─────────────────────────────────────────────"
    
    if [ $status -eq 0 ]; then
        echo -e " MTProto: ${GREEN}✅ РАБОТАЕТ${NC}"
    elif [ $status -eq 1 ]; then
        echo -e " MTProto: ${YELLOW}⚠️  УСТАНОВЛЕН НО ОСТАНОВЛЕН${NC}"
    else
        echo -e " MTProto: ${RED}❌ НЕ УСТАНОВЛЕН${NC}"
    fi
    
    local port=$(grep -oP '(?<=-p )\d+' /etc/systemd/system/${SERVICE_NAME}.service 2>/dev/null || echo "?")
    local server_ip=$(get_server_ip)
    echo " Сервер: $server_ip:$port"
    
    if [ $status -eq 0 ]; then
        local conns=$(get_proxy_connections)
        local uptime=$(get_uptime)
        echo " Соединений: $conns"
        echo " Аптайм: $uptime"
    fi
    
    echo ""
    echo " ─────────────────────────────────────────────"
    echo " 1) 📊 Монитор ресурсов (живой)"
    echo " 2) 📱 Показать QR код"
    echo " 3) ⏯️  Старт/Стоп (toggle)"
    echo " 4) 🔄 Перезапуск"
    echo " 5) 📌 Применить промо-тег"
    echo " 6) 🗑️  Удалить промо-тег"
    echo " 7) 🔧 Сменить порт"
    echo " 8) 📋 Показать логи"
    echo " 9) 🤖 Telegram уведомления"
    echo " 10) 🗑️  Удалить MTProto"
    echo " 0) 🚪 Выход"
    echo ""
    read -rp " Выбор [0-10]: " choice
    
    case $choice in
        1)  show_resource_live ;;
        2)  manager_show_qr ;;
        3)  manager_toggle ;;
        4)  manager_restart ;;
        5)  manager_apply_tag ;;
        6)  manager_remove_tag ;;
        7)  manager_change_port ;;
        8)  manager_show_logs ;;
        9)  manager_tg_settings ;;
        10)
            read -rp "⚠️  Удалить MTProto? (yes/no): " confirm
            if [ "$confirm" = "yes" ]; then
                uninstall_mtproxy_silent
                success "MTProto удалён"
                sleep 1
                exit 0
            fi
            ;;
        0)
            echo -e "${GREEN}До свидания! 👋${NC}"
            exit 0
            ;;
        *) warning "Неправильный выбор"; sleep 2 ;;
    esac
}

run_manager() {
    while true; do
        show_manager_menu
    done
}

# ============ УСТАНОВКА КОМАНДЫ ============
install_command() {
    local self_path
    self_path=$(readlink -f "$0" 2>/dev/null || echo "")
    
    if [ "$self_path" != "$MANAGER_PATH" ]; then
        if cp "$0" "$MANAGER_PATH" 2>/dev/null; then
            chmod +x "$MANAGER_PATH"
        else
            curl -fsSL "https://raw.githubusercontent.com/tarpy-socdev/MTP-manager/refs/heads/main/mtproto-universal.sh" \
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

# Главное меню (без while true — run_manager имеет свой)
clear_screen
status=$(get_installation_status)

echo ""
echo " ╔════════════════════════════════════════════╗"
echo " ║     MTProto Proxy Manager v4.4             ║"
echo " ║     github.com/tarpy-socdev/MTP-manager    ║"
echo " ╚════════════════════════════════════════════╝"
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
        *) warning "Неправильный выбор"; sleep 2; exec "$0" ;;
    esac
elif [ $status -eq 1 ]; then
    echo -e " ${RED}❌ MTPROTO УСТАНОВЛЕН НО НЕ РАБОТАЕТ${NC}"
    echo ""
    read -rp "Восстановить? (y/n): " restore
    if [[ "$restore" =~ ^[Yy]$ ]]; then
        systemctl restart ${SERVICE_NAME}
        sleep 2
        systemctl is-active --quiet ${SERVICE_NAME} && success "Восстановлен!" || warning "Не удалось восстановить"
    fi
    sleep 2
    exec "$0"
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
