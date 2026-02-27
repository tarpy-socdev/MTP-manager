#!/bin/bash
# ==============================================================================
# TG-CORE v1.1 — Telegram Notification Engine (Independent)
# ==============================================================================
# Универсальное ядро для интеграции Telegram уведомлений в любой проект.
# Проект подключает это ядро через source и задаёт свои колбеки.
# ==============================================================================

# ============ ЛОКАЛЬ ДЛЯ РУССКИХ СИМВОЛОВ ============
export LANG=ru_RU.UTF-8
export LC_ALL=ru_RU.UTF-8

# ============ ЦВЕТА (переопределяются проектом если нужно) ============
_R="${_R:-$'\033[0;31m'}"
_G="${_G:-$'\033[0;32m'}"
_Y="${_Y:-$'\033[1;33m'}"
_C="${_C:-$'\033[0;36m'}"
_B="${_B:-$'\033[1m'}"
_N="${_N:-$'\033[0m'}"

# ============ КОНФИГУРАЦИЯ ЯДРА ============
TG_CORE_DIR="${TG_CORE_DIR:-/opt/tg-core}"
TG_CORE_CONFIG="${TG_CORE_CONFIG:-$TG_CORE_DIR/config.conf}"
TG_MSGID_DIR="${TG_MSGID_DIR:-$TG_CORE_DIR/msgids}"
TG_SERVICE_NAME="${TG_SERVICE_NAME:-mtproto-tgnotify}"
TG_DAEMON_PATH="${TG_DAEMON_PATH:-/usr/local/bin/mtproto-manager}"

# Имя проекта (переопределяется проектом перед source)
TG_PROJECT_NAME="${TG_PROJECT_NAME:-Service}"

# Колбек для построения сообщения (переопределяется проектом)
# Принимает: chat_id, mode (full/status)
# Возвращает: текст сообщения
TG_BUILD_MSG_FN="${TG_BUILD_MSG_FN:-_tg_default_build_msg}"

# ============ ПЕРЕМЕННЫЕ КОНФИГА ============
TG_BOT_TOKEN=""
TG_CHAT_IDS=()
TG_CHAT_MODES=()
TG_CHAT_NAMES=()
TG_UPDATE_INTERVAL=30

# ============ ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ ============
_tg_msgid_file() {
    local chat_id="$1"
    # Используем md5 от chat_id чтобы избежать коллизий
    local hash=$(echo -n "$chat_id" | md5sum | cut -d' ' -f1)
    echo "$TG_MSGID_DIR/msgid_${hash}"
}

_tg_get_msgid() {
    local chat_id="$1"
    local file=$(_tg_msgid_file "$chat_id")
    [ -f "$file" ] && cat "$file" || echo ""
}

_tg_set_msgid() {
    local chat_id="$1"
    local msgid="$2"
    mkdir -p "$TG_MSGID_DIR"
    echo "$msgid" > "$(_tg_msgid_file "$chat_id")"
}

_tg_reset_msgid() {
    local chat_id="$1"
    rm -f "$(_tg_msgid_file "$chat_id")"
}

# ============ API ФУНКЦИИ ============
tg_api_call() {
    local method="$1"
    shift
    local url="https://api.telegram.org/bot${TG_BOT_TOKEN}/${method}"
    curl -s -X POST "$url" "$@"
}

tg_send_message() {
    local chat_id="$1"
    local text="$2"
    local parse_mode="${3:-}"
    
    local args=(-d "chat_id=$chat_id" -d "text=$text")
    [ -n "$parse_mode" ] && args+=(-d "parse_mode=$parse_mode")
    
    tg_api_call "sendMessage" "${args[@]}"
}

tg_edit_message() {
    local chat_id="$1"
    local message_id="$2"
    local text="$3"
    local parse_mode="${4:-}"
    
    local args=(-d "chat_id=$chat_id" -d "message_id=$message_id" -d "text=$text")
    [ -n "$parse_mode" ] && args+=(-d "parse_mode=$parse_mode")
    
    tg_api_call "editMessageText" "${args[@]}"
}

# ============ ПОСТРОЕНИЕ СООБЩЕНИЯ (ДЕФОЛТ) ============
_tg_default_build_msg() {
    local chat_id="$1"
    local mode="$2"
    echo "🤖 ${TG_PROJECT_NAME}
Статус: работает
Режим: $mode"
}

# ============ ОТПРАВКА/ОБНОВЛЕНИЕ ============
tg_delete_message() {
    local chat_id="$1"
    local message_id="$2"
    tg_api_call "deleteMessage" -d "chat_id=$chat_id" -d "message_id=$message_id" >/dev/null 2>&1
}

tg_send_or_update() {
    local chat_id="$1"
    local mode="$2"
    
    local text=$($TG_BUILD_MSG_FN "$chat_id" "$mode")
    local msgid=$(_tg_get_msgid "$chat_id")
    
    local result
    if [ -n "$msgid" ]; then
        # Пробуем редактировать
        result=$(tg_edit_message "$chat_id" "$msgid" "$text" "HTML")
        local ok=$(echo "$result" | grep -o '"ok":true')
        
        # Если ошибка (сообщение удалено/не найдено) — удаляем старое и отправляем новое
        if [ -z "$ok" ]; then
            tg_delete_message "$chat_id" "$msgid" 2>/dev/null
            _tg_reset_msgid "$chat_id"
            result=$(tg_send_message "$chat_id" "$text" "HTML")
            msgid=$(echo "$result" | grep -o '"message_id":[0-9]*' | head -1 | cut -d: -f2)
            [ -n "$msgid" ] && _tg_set_msgid "$chat_id" "$msgid"
        fi
    else
        result=$(tg_send_message "$chat_id" "$text" "HTML")
        msgid=$(echo "$result" | grep -o '"message_id":[0-9]*' | head -1 | cut -d: -f2)
        [ -n "$msgid" ] && _tg_set_msgid "$chat_id" "$msgid"
    fi
    
    # Проверка ошибки
    local ok=$(echo "$result" | grep -o '"ok":true')
    if [ -z "$ok" ]; then
        local desc=$(echo "$result" | grep -o '"description":"[^"]*"' | cut -d'"' -f4)
        echo "${_R}[TG ERROR]${_N} Chat $chat_id: ${desc:-unknown error}" >&2
        return 1
    fi
    return 0
}

# ============ ДЕМОН ============
tg_daemon_loop() {
    while true; do
        for i in "${!TG_CHAT_IDS[@]}"; do
            local chat_id="${TG_CHAT_IDS[$i]}"
            local mode="${TG_CHAT_MODES[$i]}"
            tg_send_or_update "$chat_id" "$mode" &
        done
        wait
        sleep "$TG_UPDATE_INTERVAL"
    done
}

# ============ УПРАВЛЕНИЕ СЕРВИСОМ ============
tg_service_status() {
    systemctl is-active --quiet "$TG_SERVICE_NAME" && echo "running" || echo "stopped"
}

tg_service_start() {
    systemctl start "$TG_SERVICE_NAME" 2>/dev/null
}

tg_service_stop() {
    systemctl stop "$TG_SERVICE_NAME" 2>/dev/null
}

tg_service_restart() {
    systemctl restart "$TG_SERVICE_NAME" 2>/dev/null
}

tg_install_service() {
    cat > "/etc/systemd/system/${TG_SERVICE_NAME}.service" <<EOF
[Unit]
Description=Telegram Notifications for ${TG_PROJECT_NAME}
After=network.target

[Service]
Type=simple
ExecStart=${TG_DAEMON_PATH} --tg-daemon
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$TG_SERVICE_NAME"
}

# ============ КОНФИГ (ЗАГРУЗКА/СОХРАНЕНИЕ) ============
tg_load_config() {
    TG_BOT_TOKEN=""
    TG_CHAT_IDS=()
    TG_CHAT_MODES=()
    TG_CHAT_NAMES=()
    local TG_CHAT_NAMES_B64=()
    TG_UPDATE_INTERVAL=30
    
    [ -f "$TG_CORE_CONFIG" ] || return 0
    
    local line
    while IFS= read -r line; do
        case "$line" in
            TG_BOT_TOKEN=*) TG_BOT_TOKEN="${line#*=}" ;;
            TG_UPDATE_INTERVAL=*) TG_UPDATE_INTERVAL="${line#*=}" ;;
            TG_CHAT_IDS+=*) eval "$line" ;;
            TG_CHAT_MODES+=*) eval "$line" ;;
            TG_CHAT_NAMES_B64+=*) eval "$line" ;;
            TG_CHAT_NAMES+=*) eval "$line" ;;  # Legacy support
        esac
    done < "$TG_CORE_CONFIG"
    
    # Декодируем base64 имена если есть
    if [ ${#TG_CHAT_NAMES_B64[@]} -gt 0 ]; then
        TG_CHAT_NAMES=()
        for name_b64 in "${TG_CHAT_NAMES_B64[@]}"; do
            local name=$(echo -n "$name_b64" | base64 -d 2>/dev/null || echo "Chat")
            TG_CHAT_NAMES+=("$name")
        done
    fi
}

tg_save_config() {
    mkdir -p "$TG_CORE_DIR"
    {
        echo "TG_BOT_TOKEN=$TG_BOT_TOKEN"
        echo "TG_UPDATE_INTERVAL=$TG_UPDATE_INTERVAL"
        for id in "${TG_CHAT_IDS[@]}"; do
            printf "TG_CHAT_IDS+=(%q)\n" "$id"
        done
        for mode in "${TG_CHAT_MODES[@]}"; do
            printf "TG_CHAT_MODES+=(%q)\n" "$mode"
        done
        # Имена в base64 чтобы не ломались русские символы
        for name in "${TG_CHAT_NAMES[@]}"; do
            local name_b64=$(echo -n "$name" | base64 -w0 2>/dev/null)
            echo "TG_CHAT_NAMES_B64+=($name_b64)"
        done
    } > "$TG_CORE_CONFIG"
}

# ============ ИНТЕРАКТИВНАЯ НАСТРОЙКА ============
tg_setup_interactive() {
    while true; do
        tg_load_config
        printf "\033[2J\033[H"  # clear без fork
        echo ""
        echo -e " ${_B}🤖 TELEGRAM ИНТЕГРАЦИЯ — ${TG_PROJECT_NAME}${_N}"
        echo " ════════════════════════════════════════════"
        echo ""
        
        if [ -z "$TG_BOT_TOKEN" ]; then
            echo -e " ${_Y}⚠️  Бот не настроен${_N}"
        else
            echo -e " ${_G}✅ Бот:${_N} ${TG_BOT_TOKEN:0:10}...${TG_BOT_TOKEN: -5}"
        fi
        
        echo -e " ${_C}Интервал:${_N} ${TG_UPDATE_INTERVAL}с"
        echo ""
        
        if [ ${#TG_CHAT_IDS[@]} -eq 0 ]; then
            echo -e " ${_Y}Нет активных чатов${_N}"
        else
            echo -e " ${_B}Активные чаты:${_N}"
            for i in "${!TG_CHAT_IDS[@]}"; do
                local chat_id="${TG_CHAT_IDS[$i]}"
                local mode="${TG_CHAT_MODES[$i]}"
                local name="${TG_CHAT_NAMES[$i]:-Chat $((i+1))}"
                local mode_label="только статус"
                [ "$mode" = "full" ] && mode_label="полный (статус+ресурсы)"
                echo "   $((i+1)). $name (ID: $chat_id) — $mode_label"
            done
        fi
        
        echo ""
        echo " ════════════════════════════════════════════"
        echo " 1) Настроить бот-токен"
        echo " 2) Добавить чат/канал/группу"
        echo " 3) Удалить чат"
        echo " 4) Переименовать чат"
        echo " 5) Изменить режим чата"
        echo " 6) Изменить интервал обновления"
        echo " 7) Отправить тест"
        echo " 8) Статус сервиса"
        echo " 0) Назад"
        echo ""
        read -rp " Выбор: " choice
        
        case $choice in
            1) _tg_setup_token ;;
            2) _tg_setup_add_chat ;;
            3) _tg_setup_remove_chat ;;
            4) _tg_setup_rename_chat ;;
            5) _tg_setup_change_mode ;;
            6) _tg_setup_interval ;;
            7) _tg_test ;;
            8) _tg_status ;;
            0) return 0 ;;
            *) echo " Неверный выбор"; sleep 1 ;;
        esac
    done
}

_tg_setup_token() {
    echo ""
    read -rp " Введи токен бота: " token
    [ -z "$token" ] && return
    
    local result=$(curl -s "https://api.telegram.org/bot${token}/getMe")
    local ok=$(echo "$result" | grep -o '"ok":true')
    
    if [ -n "$ok" ]; then
        TG_BOT_TOKEN="$token"
        tg_save_config
        echo -e " ${_G}✅ Токен сохранён${_N}"
    else
        echo -e " ${_R}❌ Неверный токен${_N}"
    fi
    sleep 2
}

_tg_setup_add_chat() {
    echo ""
    read -rp " Введи chat_id (число или @username): " chat_id
    [ -z "$chat_id" ] && return
    
    read -rp " Название чата: " chat_name
    [ -z "$chat_name" ] && chat_name="Chat $((${#TG_CHAT_IDS[@]}+1))"
    
    echo ""
    echo " Режим сообщения:"
    echo "   1) Только статус (работает/не работает)"
    echo "   2) Полный (статус + ресурсы + соединения)"
    read -rp " Выбор [1-2]: " mode_choice
    
    local mode="status"
    [ "$mode_choice" = "2" ] && mode="full"
    
    TG_CHAT_IDS+=("$chat_id")
    TG_CHAT_MODES+=("$mode")
    TG_CHAT_NAMES+=("$chat_name")
    tg_save_config
    
    # Автоотправка первого сообщения
    _tg_reset_msgid "$chat_id"
    tg_send_or_update "$chat_id" "$mode"
    
    # Если это первый чат — запускаем демон
    if [ ${#TG_CHAT_IDS[@]} -eq 1 ]; then
        if [ ! -f "/etc/systemd/system/${TG_SERVICE_NAME}.service" ]; then
            echo -e " ${_C}ℹ️  Устанавливаем systemd сервис...${_N}"
            tg_install_service
        fi
        if ! systemctl is-active --quiet "$TG_SERVICE_NAME" 2>/dev/null; then
            echo -e " ${_C}ℹ️  Запускаем демон обновлений...${_N}"
            tg_service_start
            sleep 1
            if systemctl is-active --quiet "$TG_SERVICE_NAME"; then
                echo -e " ${_G}✅ Демон запущен${_N}"
            fi
        fi
    fi
    
    echo -e " ${_G}✅ Чат добавлен${_N}"
    sleep 2
}

_tg_setup_remove_chat() {
    [ ${#TG_CHAT_IDS[@]} -eq 0 ] && { echo " Нет чатов"; sleep 1; return; }
    
    echo ""
    read -rp " Номер чата для удаления: " num
    num=$((num - 1))
    
    if [ $num -ge 0 ] && [ $num -lt ${#TG_CHAT_IDS[@]} ]; then
        _tg_reset_msgid "${TG_CHAT_IDS[$num]}"
        unset 'TG_CHAT_IDS[$num]'
        unset 'TG_CHAT_MODES[$num]'
        unset 'TG_CHAT_NAMES[$num]'
        TG_CHAT_IDS=("${TG_CHAT_IDS[@]}")
        TG_CHAT_MODES=("${TG_CHAT_MODES[@]}")
        TG_CHAT_NAMES=("${TG_CHAT_NAMES[@]}")
        tg_save_config
        echo -e " ${_G}✅ Удалено${_N}"
    else
        echo -e " ${_R}Неверный номер${_N}"
    fi
    sleep 1
}

_tg_setup_rename_chat() {
    [ ${#TG_CHAT_IDS[@]} -eq 0 ] && { echo " Нет чатов"; sleep 1; return; }
    
    echo ""
    read -rp " Номер чата: " num
    num=$((num - 1))
    
    if [ $num -ge 0 ] && [ $num -lt ${#TG_CHAT_IDS[@]} ]; then
        read -rp " Новое название: " new_name
        [ -n "$new_name" ] && TG_CHAT_NAMES[$num]="$new_name"
        tg_save_config
        echo -e " ${_G}✅ Переименовано${_N}"
    else
        echo -e " ${_R}Неверный номер${_N}"
    fi
    sleep 1
}

_tg_setup_change_mode() {
    [ ${#TG_CHAT_IDS[@]} -eq 0 ] && { echo " Нет чатов"; sleep 1; return; }
    
    echo ""
    read -rp " Номер чата: " num
    num=$((num - 1))
    
    if [ $num -ge 0 ] && [ $num -lt ${#TG_CHAT_IDS[@]} ]; then
        echo " 1) Только статус"
        echo " 2) Полный"
        read -rp " Выбор [1-2]: " mode_choice
        
        local new_mode="status"
        [ "$mode_choice" = "2" ] && new_mode="full"
        
        TG_CHAT_MODES[$num]="$new_mode"
        tg_save_config
        
        # Сбрасываем msgid чтобы отправить новое сообщение с новым режимом
        _tg_reset_msgid "${TG_CHAT_IDS[$num]}"
        tg_send_or_update "${TG_CHAT_IDS[$num]}" "$new_mode"
        
        echo -e " ${_G}✅ Режим изменён${_N}"
    else
        echo -e " ${_R}Неверный номер${_N}"
    fi
    sleep 1
}

_tg_setup_interval() {
    echo ""
    read -rp " Интервал обновления (сек, мин 10): " interval
    interval=${interval:-30}
    [ $interval -lt 10 ] && interval=10
    TG_UPDATE_INTERVAL=$interval
    tg_save_config
    echo -e " ${_G}✅ Интервал: ${interval}с${_N}"
    sleep 1
}

_tg_test() {
    [ ${#TG_CHAT_IDS[@]} -eq 0 ] && { echo " Нет чатов"; sleep 1; return; }
    
    echo ""
    # Временно останавливаем демон чтобы не было дублей
    local daemon_was_running=0
    if systemctl is-active --quiet "$TG_SERVICE_NAME" 2>/dev/null; then
        daemon_was_running=1
        echo " Останавливаем демон..."
        tg_service_stop
        sleep 1
    fi
    
    echo " Тест отправки во все чаты..."
    for i in "${!TG_CHAT_IDS[@]}"; do
        local chat_id="${TG_CHAT_IDS[$i]}"
        local mode="${TG_CHAT_MODES[$i]}"
        local name="${TG_CHAT_NAMES[$i]:-Chat $((i+1))}"
        
        echo " → $name..."
        _tg_reset_msgid "$chat_id"  # Сброс msgid перед тестом
        if tg_send_or_update "$chat_id" "$mode"; then
            echo -e "   ${_G}✅ OK${_N}"
        else
            echo -e "   ${_R}❌ Ошибка${_N}"
        fi
    done
    
    # Перезапускаем демон если был запущен
    if [ $daemon_was_running -eq 1 ]; then
        echo " Запускаем демон обратно..."
        tg_service_start
    fi
    
    echo ""
    read -rp " Enter... "
}

_tg_status() {
    local status=$(tg_service_status)
    echo ""
    if [ "$status" = "running" ]; then
        echo -e " ${_G}✅ Сервис работает${_N}"
        echo ""
        echo " 1) Остановить"
        echo " 2) Перезапустить"
        echo " 0) Назад"
        read -rp " Выбор: " schoice
        case $schoice in
            1) tg_service_stop; echo " Остановлен"; sleep 1 ;;
            2) tg_service_restart; echo " Перезапущен"; sleep 1 ;;
        esac
    else
        echo -e " ${_R}❌ Сервис остановлен${_N}"
        echo ""
        read -rp " Запустить? (y/n): " start
        if [[ "$start" =~ ^[Yy]$ ]]; then
            [ ! -f "/etc/systemd/system/${TG_SERVICE_NAME}.service" ] && tg_install_service
            tg_service_start
            sleep 1
            [ "$(tg_service_status)" = "running" ] && echo -e " ${_G}✅ Запущен${_N}" || echo -e " ${_R}❌ Ошибка запуска${_N}"
            sleep 2
        fi
    fi
}

# ============ CLI РЕЖИМЫ (если запускается напрямую) ============
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    case "${1:-}" in
        --setup)
            tg_load_config
            tg_setup_interactive
            ;;
        --daemon)
            tg_load_config
            tg_daemon_loop
            ;;
        --test)
            tg_load_config
            _tg_test
            ;;
        --status)
            _tg_status
            ;;
        --install)
            tg_install_service
            echo "Service installed: $TG_SERVICE_NAME"
            ;;
        *)
            echo "TG-CORE v1.1 — Telegram Notification Engine"
            echo ""
            echo "Usage:"
            echo "  $0 --setup     Interactive setup"
            echo "  $0 --daemon    Run notification daemon"
            echo "  $0 --test      Send test messages"
            echo "  $0 --status    Check service status"
            echo "  $0 --install   Install systemd service"
            echo ""
            echo "Integration:"
            echo "  source $0"
            echo "  TG_PROJECT_NAME='My Project'"
            echo "  TG_BUILD_MSG_FN=my_build_msg_function"
            echo "  tg_setup_interactive"
            ;;
    esac
fi
