#!/bin/bash
# ==============================================
# MTProto Proxy — Universal Manager v4.6
# Установка + Менеджер
# github.com/tarpy-socdev/MTP-manager
# ==============================================
# CHANGELOG v4.6:
# - ИСПРАВЛЕНО: загрузка ядра Telegram (tg_send больше не "command not found")
# - ИСПРАВЛЕНО: аптайм теперь точный (через /proc)
# - ИСПРАВЛЕНО: скачки времени в мониторинге (убраны лишние sleep)
# - УЛУЧШЕНО: соединения разделены на входящие/исходящие
# - УЛУЧШЕНО: CPU и RAM показываются как целые числа (быстрее)
# ==============================================

# ============ ЦВЕТА И СТИЛИ ============
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'
BLUE=$'\033[0;34m'
BOLD=$'\033[1m'
NC=$'\033[0m'

# ============ ПЕРЕМЕННЫЕ ============
INSTALL_DIR="/opt/MTProxy"
SERVICE_FILE="/etc/systemd/system/mtproto-proxy.service"
LOGFILE="/tmp/mtproto-install.log"
MANAGER_PATH="/usr/local/bin/mtproto-manager"
TG_CUSTOM_MSG_FILE="/opt/tg-core/custom_message.txt"

# ============ УТИЛИТЫ ============

err() {
    echo -e "${RED}[✗]${NC} $1" >&2
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
    echo " ╔═══════════════════════════════════════════════╗"
    echo " ║      MTProto Proxy Manager v4.6               ║"
    echo " ║      github.com/tarpy-socdev/MTP-manager      ║"
    echo " ╚═══════════════════════════════════════════════╝"
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
        echo "❌ Некорректный порт! Используй 1-65535"
        return 1
    fi
    return 0
}

check_port_available() {
    local port=$1
    local skip_port=${2:-""}
    if [ -n "$skip_port" ] && [ "$port" = "$skip_port" ]; then
        return 0
    fi
    if netstat -tuln 2>/dev/null | grep -q ":$port " || ss -tuln 2>/dev/null | grep -q ":$port "; then
        return 1
    fi
    return 0
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

# ============ ЧАСОВОЙ ПОЯС ============
TIMEZONE_DIR="/usr/share/zoneinfo"
TIMEZONE_FILE="/etc/timezone"
SYSTEM_TIMEZONE=$(cat "$TIMEZONE_FILE" 2>/dev/null || echo "Etc/UTC")

show_current_time() {
    echo -e " ${CYAN}Текущее время:${NC} $(date '+%Y-%m-%d %H:%M:%S')"
    echo -e " ${CYAN}Часовой пояс:${NC} $SYSTEM_TIMEZONE"
}

change_timezone() {
    clear_screen
    echo ""
    echo -e " ${BOLD}🌍 СМЕНА ЧАСОВОГО ПОЯСА${NC}"
    echo " ─────────────────────────────────────────────"
    show_current_time
    echo ""
    echo -e " ${YELLOW}Выбери регион:${NC}"
    echo " 1) Europe"
    echo " 2) Asia"
    echo " 3) America"
    echo " 4) Africa"
    echo " 5) Australia"
    echo " 6) Pacific"
    echo " 7) Atlantic"
    echo " 8) Indian"
    echo " 9) UTC (универсальное время)"
    echo " 0) Назад"
    echo ""
    read -rp " Выбор: " region_choice

    case $region_choice in
        1) region="Europe" ;;
        2) region="Asia" ;;
        3) region="America" ;;
        4) region="Africa" ;;
        5) region="Australia" ;;
        6) region="Pacific" ;;
        7) region="Atlantic" ;;
        8) region="Indian" ;;
        9) 
            timedatectl set-timezone UTC 2>/dev/null
            SYSTEM_TIMEZONE="UTC"
            success "Часовой пояс изменён на UTC"
            read -rp " Enter для продолжения... "
            return
            ;;
        0) return ;;
        *) warning "Неверный выбор"; sleep 1; return ;;
    esac

    clear_screen
    echo ""
    echo -e " ${BOLD}🌍 Доступные города в ${region}:${NC}"
    echo " ─────────────────────────────────────────────"
    
    local cities=()
    local i=1
    while IFS= read -r city; do
        city_name=$(basename "$city")
        cities+=("$city_name")
        printf " %2d) %s\n" $i "$city_name"
        i=$((i+1))
    done < <(find "$TIMEZONE_DIR/$region" -type f 2>/dev/null | sort)
    
    echo ""
    read -rp " Выбери город (1-$((i-1))): " city_choice
    
    if [[ "$city_choice" =~ ^[0-9]+$ ]] && [ "$city_choice" -ge 1 ] && [ "$city_choice" -lt $i ]; then
        local selected_city="${cities[$((city_choice-1))]}"
        local new_tz="$region/$selected_city"
        
        if timedatectl set-timezone "$new_tz" 2>/dev/null; then
            SYSTEM_TIMEZONE="$new_tz"
            success "Часовой пояс изменён на $new_tz"
        else
            warning "Не удалось изменить часовой пояс"
        fi
    else
        warning "Неверный выбор"
    fi
    read -rp " Enter для продолжения... "
}

# ============ СБОР СТАТИСТИКИ ПРОКСИ (УЛУЧШЕННЫЙ v4.6) ============
get_proxy_stats() {
    local -A stats
    local proxy_port server_ip pid
    
    proxy_port=$(grep -oP '(?<=-H )\d+' "$SERVICE_FILE" 2>/dev/null || echo "N/A")
    server_ip=$(hostname -I | awk '{print $1}')
    stats[port]="$proxy_port"
    stats[ip]="$server_ip"
    stats[update_time]=$(date '+%Y-%m-%d %H:%M:%S')

    if systemctl is-active --quiet mtproto-proxy 2>/dev/null; then
        stats[status]="active"
        stats[status_text]="✅ РАБОТАЕТ"
        stats[status_emoji]="✅"
    else
        stats[status]="inactive"
        stats[status_text]="❌ ОСТАНОВЛЕН"
        stats[status_emoji]="❌"
    fi

    pid=$(systemctl show -p MainPID mtproto-proxy 2>/dev/null | cut -d= -f2)

    if [ -n "$pid" ] && [ "$pid" != "0" ] && kill -0 "$pid" 2>/dev/null; then
        stats[pid]="$pid"
        
        # Быстрый сбор CPU (одно измерение, без sleep)
        stats[cpu]=$(ps -p "$pid" -o %cpu= 2>/dev/null | xargs | cut -d. -f1 || echo "0")
        
        # RAM в MB и процентах
        local mem_total_kb mem_used_kb
        mem_total_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
        mem_used_kb=$(ps -p "$pid" -o rss= 2>/dev/null | xargs || echo "0")
        
        if [ -n "$mem_total_kb" ] && [ "$mem_total_kb" -gt 0 ]; then
            stats[rss_mb]=$(( mem_used_kb / 1024 ))
            stats[mem]=$(( (mem_used_kb * 100) / mem_total_kb ))
        else
            stats[rss_mb]="0"
            stats[mem]="0"
        fi

        # Аптайм через /proc/[pid]/stat (надежнее)
        if [ -f "/proc/$pid/stat" ]; then
            local start_ticks uptime_seconds
            start_ticks=$(cut -d' ' -f22 /proc/$pid/stat 2>/dev/null || echo "0")
            local system_uptime=$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo "0")
            if [ "$start_ticks" -gt 0 ] && [ "$system_uptime" -gt 0 ]; then
                # Конвертируем тики в секунды (обычно 100 тиков = 1 секунда)
                uptime_seconds=$(( system_uptime - (start_ticks / 100) ))
                if [ $uptime_seconds -lt 0 ]; then
                    uptime_seconds=0
                fi
                local days=$(( uptime_seconds / 86400 ))
                local hours=$(( (uptime_seconds % 86400) / 3600 ))
                local mins=$(( (uptime_seconds % 3600) / 60 ))
                local secs=$(( uptime_seconds % 60 ))
                
                if [ $days -gt 0 ]; then
                    stats[uptime]="${days}д ${hours}ч ${mins}м"
                elif [ $hours -gt 0 ]; then
                    stats[uptime]="${hours}ч ${mins}м ${secs}с"
                else
                    stats[uptime]="${mins}м ${secs}с"
                fi
            else
                stats[uptime]="только что"
            fi
        else
            stats[uptime]="N/A"
        fi

        # Счетчики соединений (разделяем входящие/исходящие)
        if command -v ss &>/dev/null; then
            local established_in established_out
            established_in=$(ss -tn state established "( sport = :$proxy_port )" 2>/dev/null | tail -n +2 | wc -l || echo "0")
            established_out=$(ss -tn state established "( dport = :$proxy_port )" 2>/dev/null | tail -n +2 | wc -l || echo "0")
            stats[conn_in]="$established_in"
            stats[conn_out]="$established_out"
            stats[conn_total]=$(( established_in + established_out ))
        else
            local total
            total=$(netstat -tn 2>/dev/null | grep -c ":${proxy_port}[[:space:]]" || echo "0")
            stats[conn_in]="?"
            stats[conn_out]="?"
            stats[conn_total]="$total"
        fi
    else
        stats[pid]=""
        stats[cpu]="0"
        stats[mem]="0"
        stats[rss_mb]="0"
        stats[uptime]="—"
        stats[conn_in]="0"
        stats[conn_out]="0"
        stats[conn_total]="0"
    fi

    for key in "${!stats[@]}"; do
        echo "$key=${stats[$key]}"
    done
}
# ============ МОНИТОРИНГ РЕСУРСОВ (ИСПРАВЛЕННЫЙ v4.6) ============
show_resource_live() {
    if [ ! -f "$SERVICE_FILE" ]; then
        warning "MTProto не установлен!"
        read -rp " Enter для возврата... "
        return
    fi

    tput civis 2>/dev/null
    tput smcup 2>/dev/null
    trap 'tput cnorm 2>/dev/null; tput rmcup 2>/dev/null; trap - INT TERM' INT TERM
    clear

    while true; do
        read -t 1 -rsn1 key 2>/dev/null
        [[ "$key" == "q" || "$key" == "Q" ]] && break

        # Получаем свежую статистику
        local -A stats
        while IFS='=' read -r key value; do
            stats["$key"]="$value"
        done < <(get_proxy_stats)

        # Создаем графики
        local cpu_bar="" mem_bar=""
        local cpu_int mem_int
        
        cpu_int=${stats[cpu]:-0}
        mem_int=${stats[mem]:-0}
        
        local cpu_bars=$(( cpu_int / 5 ))
        [ $cpu_bars -gt 20 ] && cpu_bars=20
        local mem_bars=$(( mem_int / 5 ))
        [ $mem_bars -gt 20 ] && mem_bars=20

        for ((i=0; i<cpu_bars; i++)); do cpu_bar+="${GREEN}█${NC}"; done
        for ((i=cpu_bars; i<20; i++)); do cpu_bar+="░"; done
        for ((i=0; i<mem_bars; i++)); do mem_bar+="${YELLOW}█${NC}"; done
        for ((i=mem_bars; i<20; i++)); do mem_bar+="░"; done

        # Логи
        local term_width log_width logs
        term_width=$(tput cols 2>/dev/null || echo 80)
        log_width=$(( term_width - 4 ))
        logs=$(journalctl -u mtproto-proxy -n 5 --no-pager --output=short 2>/dev/null \
            | cut -c1-"$log_width" | sed 's/^/  /' || echo "  Логи недоступны")

        tput cup 0 0

        # Верхняя рамка
        echo -e "${CYAN}${BOLD}"
        echo " ╔══════════════════════════════════════════════════════════╗"
        printf " ║      MTProto Proxy — Live Monitor                        ║\n"
        printf " ║      %s  [q — выход]                         ║\n" "$(date '+%H:%M:%S')"
        echo " ╚══════════════════════════════════════════════════════════╝"
        echo -e "${NC}"
        
        # Статус
        echo -e " Статус:      ${stats[status_text]}"
        echo -e " Сервер:      ${CYAN}${stats[ip]}:${stats[port]}${NC}"
        echo -e " Обновлено:   ${CYAN}${stats[update_time]}${NC}"
        echo -e " Аптайм:      ${CYAN}${stats[uptime]}${NC}"
        
        # Соединения (красиво)
        if [ "${stats[conn_in]}" != "?" ]; then
            echo -e " Соединения:  ${CYAN}📥 ${stats[conn_in]} входящих | 📤 ${stats[conn_out]} исходящих | всего ${stats[conn_total]}${NC}"
        else
            echo -e " Соединения:  ${CYAN}${stats[conn_total]} активных${NC}"
        fi
        echo ""
        
        # Графики
        printf " CPU: %s ${CYAN}%s%%${NC}\n" "$(echo -e "$cpu_bar")" "${stats[cpu]}"
        printf " RAM: %s ${CYAN}%s%%${NC} (%s MB)\n" "$(echo -e "$mem_bar")" "${stats[mem]}" "${stats[rss_mb]}"
        echo ""
        
        # Логи
        echo -e " ${BOLD}📝 Последние логи:${NC}"
        echo " ───────────────────────────────────────────────────"
        echo "$logs"
        
        tput ed 2>/dev/null
    done

    tput cnorm 2>/dev/null
    tput rmcup 2>/dev/null
    trap - INT TERM
}

# ============ TELEGRAM ИНТЕГРАЦИЯ (ИСПРАВЛЕННАЯ v4.6) ============
TG_PROJECT_NAME="MTProto Proxy"
TG_BUILD_MSG_FN="mtproto_tg_build_msg"

_TG_CORE_LOADED=0

_tg_core_load() {
    [ "$_TG_CORE_LOADED" = "1" ] && return 0
    if [ ! -f "/opt/tg-core/tg-core.sh" ]; then
        return 1
    fi
    source /opt/tg-core/tg-core.sh
    local rc=$?
    if [ $rc -eq 0 ] && type tg_daemon_loop &>/dev/null; then
        _TG_CORE_LOADED=1
        return 0
    else
        return 1
    fi
}

# Загрузка кастомного сообщения
load_custom_message() {
    if [ -f "$TG_CUSTOM_MSG_FILE" ]; then
        cat "$TG_CUSTOM_MSG_FILE"
    else
        # Сообщение по умолчанию
        cat > "$TG_CUSTOM_MSG_FILE" << 'EOF'
📡 <b>MTProto Proxy — Статус</b>

🔘 Статус: {status}
🖥 Сервер: {server}:{port}
⏱ Аптайм: {uptime}
👥 Соединения: 📥 {conn_in} входящих | 📤 {conn_out} исходящих

📊 Ресурсы:
  CPU: {cpu}%
  RAM: {ram}% ({ram_mb} MB)

🕐 Обновлено: {update_time}
EOF
        cat "$TG_CUSTOM_MSG_FILE"
    fi
}

# Сохранение кастомного сообщения
save_custom_message() {
    local msg="$1"
    echo "$msg" > "$TG_CUSTOM_MSG_FILE"
}

# Функция для замены переменных в сообщении
format_custom_message() {
    local template="$1"
    local -n stats_ref="$2"
    
    local result="$template"
    result="${result//\{status\}/${stats_ref[status_emoji]} ${stats_ref[status_text]}}"
    result="${result//\{server\}/${stats_ref[ip]}}"
    result="${result//\{port\}/${stats_ref[port]}}"
    result="${result//\{uptime\}/${stats_ref[uptime]}}"
    result="${result//\{conn_in\}/${stats_ref[conn_in]}}"
    result="${result//\{conn_out\}/${stats_ref[conn_out]}}"
    result="${result//\{conn_total\}/${stats_ref[conn_total]}}"
    result="${result//\{cpu\}/${stats_ref[cpu]}}"
    result="${result//\{ram\}/${stats_ref[mem]}}"
    result="${result//\{ram_mb\}/${stats_ref[rss_mb]}}"
    result="${result//\{update_time\}/${stats_ref[update_time]}}"
    
    echo "$result"
}

tg_project_status() {
    local -A stats
    while IFS='=' read -r key value; do
        stats["$key"]="$value"
    done < <(get_proxy_stats)
    
    local template=$(load_custom_message)
    format_custom_message "$template" stats
}

tg_project_full_report() {
    tg_project_status
}

mtproto_tg_build_msg() {
    local mode="$1"
    tg_project_status
}

# Меню настройки кастомного сообщения
edit_custom_message() {
    clear_screen
    echo ""
    echo -e " ${BOLD}✏️  РЕДАКТИРОВАНИЕ СООБЩЕНИЯ${NC}"
    echo " ─────────────────────────────────────────────"
    echo ""
    echo -e " ${YELLOW}Доступные переменные:${NC}"
    echo " {status}     - статус прокси (✅ РАБОТАЕТ / ❌ ОСТАНОВЛЕН)"
    echo " {server}     - IP сервера"
    echo " {port}       - порт прокси"
    echo " {uptime}     - время работы"
    echo " {conn_in}    - входящие соединения"
    echo " {conn_out}   - исходящие соединения"
    echo " {conn_total} - всего соединений"
    echo " {cpu}        - загрузка CPU (%)"
    echo " {ram}        - загрузка RAM (%)"
    echo " {ram_mb}     - использование RAM (MB)"
    echo " {update_time} - время обновления"
    echo ""
    echo -e " ${YELLOW}Текущее сообщение:${NC}"
    echo " ─────────────────────────────────────────────"
    cat "$TG_CUSTOM_MSG_FILE"
    echo ""
    echo " ─────────────────────────────────────────────"
    echo ""
    echo " Введи новое сообщение (пустая строка - завершить):"
    echo ""
    
    local new_message=""
    while IFS= read -r line; do
        [ -z "$line" ] && break
        new_message+="$line"$'\n'
    done
    
    if [ -n "$new_message" ]; then
        save_custom_message "$new_message"
        success "Сообщение сохранено!"
        
        # Отправляем тест, если ядро загружено
        if [ "$_TG_CORE_LOADED" = "1" ] && [ -n "$TG_BOT_TOKEN" ] && [ ${#TG_CHAT_IDS[@]} -gt 0 ]; then
            echo ""
            info "Отправляю тестовое сообщение..."
            local msg=$(tg_project_status)
            for cid in "${TG_CHAT_IDS[@]}"; do
                tg_send "$cid" "$msg"
            done
        fi
    fi
    
    read -rp " Enter для продолжения... "
}

manager_tg_settings() {
    # Сначала проверяем наличие файла ядра
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
            if curl -fsSL --max-time 15 \
                "https://raw.githubusercontent.com/tarpy-socdev/MTP-manager/refs/heads/main/tg-core.sh" \
                -o /opt/tg-core/tg-core.sh 2>/dev/null && [ -s /opt/tg-core/tg-core.sh ]; then
                chmod +x /opt/tg-core/tg-core.sh
                success "tg-core.sh установлен"
            else
                warning "Не удалось скачать. Помести tg-core.sh вручную в /opt/tg-core/"
                read -rp " Enter... "
                return
            fi
        else
            return
        fi
    fi

    # Пытаемся загрузить ядро
    if ! _tg_core_load; then
        warning "Не удалось загрузить tg-core.sh. Проверь файл в /opt/tg-core/"
        read -rp " Enter... "
        return
    fi

    # Загружаем конфиг ядра
    tg_load_config
    
    # Расширенное меню Telegram
    while true; do
        clear_screen
        echo ""
        echo -e " ${BOLD}🤖 TELEGRAM УВЕДОМЛЕНИЯ${NC}"
        echo " ─────────────────────────────────────────────"
        
        if tg_service_status; then
            echo -e " Сервис:   ${GREEN}✅ РАБОТАЕТ${NC}"
        else
            echo -e " Сервис:   ${YELLOW}⏹  ОСТАНОВЛЕН${NC}"
        fi
        
        if [ -n "$TG_BOT_TOKEN" ]; then
            echo -e " Токен:    ${GREEN}✓ задан${NC} (${TG_BOT_TOKEN:0:12}...)"
        else
            echo -e " Токен:    ${RED}✗ не задан${NC}"
        fi
        
        echo -e " Интервал: ${CYAN}${TG_INTERVAL}с${NC}"
        echo ""
        echo " 1) 🔑 Задать токен"
        echo " 2) ➕ Добавить чат"
        echo " 3) ✏️  Редактировать сообщение"
        echo " 4) 📤 Тест отправки"
        echo " 5) ⏱  Интервал обновления"
        echo " 6) ▶️  Запустить сервис"
        echo " 7) ⏹  Остановить сервис"
        echo " 8) 🗑  Удалить всё"
        echo " 0) ← Назад"
        echo ""
        read -rp " Выбери: " tg_choice
        
        case $tg_choice in
            1) _tg_setup_token ;;
            2) _tg_setup_add_chat ;;
            3) edit_custom_message ;;
            4) 
                if [ -n "$TG_BOT_TOKEN" ] && [ ${#TG_CHAT_IDS[@]} -gt 0 ]; then
                    local msg=$(tg_project_status)
                    for cid in "${TG_CHAT_IDS[@]}"; do
                        tg_send "$cid" "$msg"
                    done
                    success "Тест отправлен!"
                else
                    warning "Сначала настрой токен и чаты"
                fi
                read -rp " Enter... "
                ;;
            5) _tg_setup_interval ;;
            6) tg_install_service; success "Сервис запущен"; read -rp " Enter... " ;;
            7) tg_remove_service; success "Сервис остановлен"; read -rp " Enter... " ;;
            8)
                read -rp "⚠️  Удалить всё? (yes/no): " c
                if [ "$c" = "yes" ]; then
                    tg_remove_service
                    rm -rf "$TG_CORE_MSGIDS"
                    rm -f "$TG_CUSTOM_MSG_FILE"
                    TG_BOT_TOKEN=""; TG_CHAT_IDS=(); TG_CHAT_MODES=()
                    TG_CHAT_NAMES=(); TG_INTERVAL=60
                    tg_save_config
                    success "Удалено"
                fi
                read -rp " Enter... "
                ;;
            0) return 0 ;;
        esac
    done
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
    local SPONSOR_TAG
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

    local NEW_PORT
    case $PORT_CHOICE in
        1) NEW_PORT=443 ;;
        2) NEW_PORT=8080 ;;
        3) NEW_PORT=8443 ;;
        4)
            while :; do
                read -rp "Порт: " NEW_PORT
                validate_port "$NEW_PORT" && break
            done
            ;;
        *) warning "Неверный выбор"; read -rp " Enter... "; return ;;
    esac

    if ! check_port_available "$NEW_PORT" "$current_port"; then
        warning "Порт $NEW_PORT уже занят!"
        read -rp " Enter... "
        return
    fi

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

    local PROXY_PORT
    case $PORT_CHOICE in
        1) PROXY_PORT=443 ;;
        2) PROXY_PORT=8080 ;;
        3) PROXY_PORT=8443 ;;
        4)
            while :; do
                read -rp "Введи порт (1-65535): " PROXY_PORT
                validate_port "$PROXY_PORT" && break
            done
            ;;
        *)
            info "По умолчанию: 8080"
            PROXY_PORT=8080
            ;;
    esac

    local CURRENT_PROXY_PORT
    CURRENT_PROXY_PORT=$(grep -oP '(?<=-H )\d+' "$SERVICE_FILE" 2>/dev/null || echo "")
    if ! check_port_available "$PROXY_PORT" "$CURRENT_PROXY_PORT"; then
        err "❌ Порт $PROXY_PORT уже занят! Выбери другой"
    fi
    info "Порт: $PROXY_PORT"
    echo ""

    echo -e "${BOLD}👤 От какого пользователя запускать?${NC}"
    echo " 1) root    (проще, работает с любым портом)"
    echo " 2) mtproxy (безопаснее, нужен порт > 1024)"
    echo ""
    read -rp "Твой выбор [1-2]: " USER_CHOICE

    local RUN_USER NEED_CAP=0
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

    local INTERNAL_PORT=8888

    info "Определяем IP сервера..."
    local SERVER_IP
    SERVER_IP=$(curl -s --max-time 3 https://api.ipify.org 2>/dev/null || \
                curl -s --max-time 3 https://ifconfig.me 2>/dev/null || \
                hostname -I | awk '{print $1}')
    [[ -z "$SERVER_IP" ]] && err "❌ Не удалось определить IP"
    echo -e "${CYAN}✓ IP: $SERVER_IP${NC}"
    echo ""

    (
        apt update -y > "$LOGFILE" 2>&1
        apt install -y git curl build-essential libssl-dev zlib1g-dev xxd netcat-openbsd bc >> "$LOGFILE" 2>&1
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

    local SECRET
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
    local SPONSOR_TAG
    read -rp " Введи тег (или Enter пропустить): " SPONSOR_TAG

    if [ -n "$SPONSOR_TAG" ]; then
        sed -i "s|-M 1$|-M 1 -P $SPONSOR_TAG|" "$SERVICE_FILE"
        systemctl daemon-reload > /dev/null 2>&1
        systemctl restart mtproto-proxy > /dev/null 2>&1
        sleep 2
        success "Тег добавлен"
    fi

    local PROXY_LINK
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
    echo -e " ${CYAN}${BOLD}════════════════════════════════════════════════════╗${NC}"
    echo ""
    echo -e " ${BOLD}📱 УПРАВЛЕНИЕ:${NC}"
    echo ""
    echo "  1)  📈 Мониторинг ресурсов (live)"
    echo "  2)  📱 QR-код и ссылка"
    echo "  3)  ▶️  Запустить"
    echo "  4)  ⏸️  Остановить"
    echo "  5)  🔄 Перезагрузить"
    echo "  6)  🏷️  Применить спонсорский тег"
    echo "  7)  ❌ Удалить спонсорский тег"
    echo "  8)  🔧 Изменить порт"
    echo "  9)  📝 Логи (50 строк)"
    echo " 10)  🗑️  Удалить MTProto"
    echo " 11)  🤖 Telegram уведомления"
    echo " 12)  🌍 Сменить часовой пояс"
    echo ""
    echo "  0)  🚪 Выход"
    echo ""
    echo -e " ${CYAN}${BOLD}════════════════════════════════════════════════════╝${NC}"
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
        12) change_timezone ;;
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
if [ "${1:-}" = "--tg-daemon" ]; then
    if ! _tg_core_load; then
        echo "tg-core not found or invalid" >&2
        exit 1
    fi
    tg_daemon_loop
    exit 0
fi

install_command

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
        *) warning "Неправильный выбор"; sleep 2; exec "$0" ;;
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
