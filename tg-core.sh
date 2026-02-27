#!/bin/bash
# ==============================================
# TG Core — Telegram Notification Engine v1.0
# Независимое ядро TG-уведомлений
# Интегрируется с любым проектом через source
# github.com/tarpy-socdev/MTP-manager
# ==============================================
# ИСПОЛЬЗОВАНИЕ:
#   Прямой запуск:  bash tg-core.sh [--setup|--daemon|--test|--status]
#   Интеграция:     source /opt/tg-core/tg-core.sh
#
# ПЕРЕМЕННЫЕ ОКРУЖЕНИЯ (переопределяются до source):
#   TG_PROJECT_NAME  — имя проекта для заголовков (по умолчанию: "Service")
#   TG_BUILD_MSG_FN  — имя функции-колбека для построения сообщения
#                      если не задана — используется встроенный шаблон
# ==============================================

# ── Пути ──────────────────────────────────────
TG_CORE_DIR="/opt/tg-core"
TG_CORE_CONFIG="$TG_CORE_DIR/config.conf"
TG_CORE_MSGIDS="$TG_CORE_DIR/msgids"   # dir: файл на каждый chat_id
TG_CORE_SERVICE="/etc/systemd/system/tg-core-notify.service"
TG_CORE_SCRIPT="/opt/tg-core/tg-core.sh"

# ── Цвета (только если интерактивный терминал) ──
if [ -t 1 ]; then
    _RED=$'\033[0;31m'; _GREEN=$'\033[0;32m'; _YELLOW=$'\033[1;33m'
    _CYAN=$'\033[0;36m'; _BOLD=$'\033[1m'; _NC=$'\033[0m'
else
    _RED=""; _GREEN=""; _YELLOW=""; _CYAN=""; _BOLD=""; _NC=""
fi

# ── Проект ────────────────────────────────────
TG_PROJECT_NAME="${TG_PROJECT_NAME:-Service}"

# ============ CONFIG ============

tg_load_config() {
    TG_BOT_TOKEN=""
    TG_INTERVAL=60
    TG_CHAT_IDS=()
    TG_CHAT_MODES=()
    if [ -f "$TG_CORE_CONFIG" ]; then
        source "$TG_CORE_CONFIG" 2>/dev/null || true
    fi
}

tg_save_config() {
    mkdir -p "$TG_CORE_DIR" "$TG_CORE_MSGIDS"
    {
        echo "TG_BOT_TOKEN='${TG_BOT_TOKEN}'"
        echo "TG_INTERVAL=${TG_INTERVAL}"
        # Сохраняем массивы в безопасном формате
        local ids_str="" modes_str=""
        for id in "${TG_CHAT_IDS[@]+"${TG_CHAT_IDS[@]}"}"; do
            ids_str+="'$id' "
        done
        for mode in "${TG_CHAT_MODES[@]+"${TG_CHAT_MODES[@]}"}"; do
            modes_str+="'$mode' "
        done
        echo "TG_CHAT_IDS=($ids_str)"
        echo "TG_CHAT_MODES=($modes_str)"
    } > "$TG_CORE_CONFIG"
    chmod 600 "$TG_CORE_CONFIG"
}

# ============ ОТПРАВКА ============

# Ключ файла msgid — экранируем chat_id (может быть отрицательным)
_tg_msgid_file() {
    local chat_id="$1"
    echo "${TG_CORE_MSGIDS}/${chat_id//[^0-9]/_}"
}

# Сброс сохранённого message_id для чата (принудительная новая отправка)
tg_reset_msgid() {
    local chat_id="$1"
    rm -f "$(_tg_msgid_file "$chat_id")"
}

# Основная функция отправки: редактирует существующее или отправляет новое
tg_send() {
    local chat_id="$1"
    local text="$2"
    local token="${TG_BOT_TOKEN}"

    [ -z "$token" ] || [ -z "$chat_id" ] || [ -z "$text" ] && return 1

    mkdir -p "$TG_CORE_MSGIDS"
    local msgid_file
    msgid_file=$(_tg_msgid_file "$chat_id")

    # Пробуем edit если есть сохранённый message_id
    if [ -f "$msgid_file" ]; then
        local msg_id
        msg_id=$(cat "$msgid_file" 2>/dev/null)
        if [ -n "$msg_id" ]; then
            local resp
            resp=$(curl -s --max-time 8 \
                "https://api.telegram.org/bot${token}/editMessageText" \
                -d "chat_id=${chat_id}" \
                -d "message_id=${msg_id}" \
                -d "parse_mode=HTML" \
                --data-urlencode "text=${text}" 2>/dev/null)

            if echo "$resp" | grep -q '"ok":true'; then
                return 0  # Успешно отредактировано
            fi

            # Edit не удался — удаляем старый msgid и отправляем новое
            rm -f "$msgid_file"
        fi
    fi

    # Отправляем новое сообщение
    local resp
    resp=$(curl -s --max-time 8 \
        "https://api.telegram.org/bot${token}/sendMessage" \
        -d "chat_id=${chat_id}" \
        -d "parse_mode=HTML" \
        --data-urlencode "text=${text}" 2>/dev/null)

    if echo "$resp" | grep -q '"ok":true'; then
        local new_msg_id
        new_msg_id=$(echo "$resp" | grep -oP '"message_id":\K\d+' | head -1)
        [ -n "$new_msg_id" ] && echo "$new_msg_id" > "$msgid_file"
        return 0
    fi

    # Логируем ошибку
    local err_desc
    err_desc=$(echo "$resp" | grep -oP '"description":"\K[^"]+' | head -1)
    echo "[tg-core] Ошибка отправки в $chat_id: $err_desc" >&2
    return 1
}

# ============ ПОСТРОЕНИЕ СООБЩЕНИЙ ============

# Встроенный шаблон — проект может переопределить через TG_BUILD_MSG_FN
_tg_default_build_msg() {
    local mode="$1"   # status | full
    local proj="${TG_PROJECT_NAME}"

    if [ "$mode" = "status" ]; then
        # Вызываем колбек проекта для получения статуса если есть
        local status_line
        if declare -f tg_project_status > /dev/null 2>&1; then
            status_line=$(tg_project_status)
        else
            status_line="Статус неизвестен"
        fi
        printf "📡 <b>%s</b>\n%s\n🕐 <i>%s</i>" \
            "$proj" "$status_line" "$(date '+%d.%m.%Y %H:%M:%S')"
    else
        # full — вызываем колбек проекта для полного отчёта
        if declare -f tg_project_full_report > /dev/null 2>&1; then
            tg_project_full_report
        else
            printf "📡 <b>%s — Статус</b>\n🕐 <i>%s</i>" \
                "$proj" "$(date '+%d.%m.%Y %H:%M:%S')"
        fi
    fi
}

tg_build_message() {
    local mode="$1"
    # Если проект задал свою функцию построения — используем её
    if [ -n "${TG_BUILD_MSG_FN:-}" ] && declare -f "$TG_BUILD_MSG_FN" > /dev/null 2>&1; then
        "$TG_BUILD_MSG_FN" "$mode"
    else
        _tg_default_build_msg "$mode"
    fi
}

# ============ ЦИКЛ УВЕДОМЛЕНИЙ (демон) ============

tg_daemon_loop() {
    tg_load_config

    # Ждём появления конфига если запустили раньше времени
    local wait_count=0
    while [ -z "$TG_BOT_TOKEN" ] && [ $wait_count -lt 30 ]; do
        sleep 2
        tg_load_config
        wait_count=$(( wait_count + 1 ))
    done

    while true; do
        # Перечитываем конфиг при каждой итерации — подхватываем изменения без рестарта
        tg_load_config

        if [ -n "$TG_BOT_TOKEN" ] && [ ${#TG_CHAT_IDS[@]} -gt 0 ]; then
            for i in "${!TG_CHAT_IDS[@]}"; do
                local chat_id="${TG_CHAT_IDS[$i]}"
                local mode="${TG_CHAT_MODES[$i]:-status}"
                local msg
                msg=$(tg_build_message "$mode")
                tg_send "$chat_id" "$msg"
            done
        fi

        sleep "${TG_INTERVAL:-60}"
    done
}

# ============ SYSTEMD СЕРВИС ============

tg_install_service() {
    local project_script="${1:-$TG_CORE_SCRIPT}"

    # Копируем себя в постоянное место если нужно
    if [ "$0" != "$TG_CORE_SCRIPT" ] && [ -f "$0" ]; then
        mkdir -p "$TG_CORE_DIR"
        cp "$0" "$TG_CORE_SCRIPT"
        chmod +x "$TG_CORE_SCRIPT"
    fi

    cat > "$TG_CORE_SERVICE" << EOF
[Unit]
Description=TG Core Notification Daemon
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/bin/bash ${project_script} --daemon
Restart=on-failure
RestartSec=10
Environment=TG_PROJECT_NAME=${TG_PROJECT_NAME}

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload > /dev/null 2>&1
    systemctl enable tg-core-notify > /dev/null 2>&1
    systemctl restart tg-core-notify > /dev/null 2>&1
}

tg_remove_service() {
    systemctl stop tg-core-notify 2>/dev/null || true
    systemctl disable tg-core-notify 2>/dev/null || true
    rm -f "$TG_CORE_SERVICE"
    systemctl daemon-reload > /dev/null 2>&1
}

tg_service_status() {
    systemctl is-active --quiet tg-core-notify 2>/dev/null
}

# ============ ИНТЕРАКТИВНАЯ НАСТРОЙКА ============

tg_setup_interactive() {
    tg_load_config

    while true; do
        clear
        printf "${_CYAN}${_BOLD}"
        printf " ╔════════════════════════════════════════════╗\n"
        printf " ║     TG Core — Настройка уведомлений        ║\n"
        printf " ╚════════════════════════════════════════════╝\n"
        printf "${_NC}\n"

        # Статус сервиса
        if tg_service_status; then
            printf " Сервис:   ${_GREEN}✅ РАБОТАЕТ${_NC}\n"
        else
            printf " Сервис:   ${_YELLOW}⏹  ОСТАНОВЛЕН${_NC}\n"
        fi

        if [ -n "$TG_BOT_TOKEN" ]; then
            printf " Токен:    ${_GREEN}✓ задан${_NC} (%s...)\n" "${TG_BOT_TOKEN:0:12}"
        else
            printf " Токен:    ${_RED}✗ не задан${_NC}\n"
        fi

        printf " Интервал: ${_CYAN}%sс${_NC}\n" "$TG_INTERVAL"
        printf "\n"

        if [ ${#TG_CHAT_IDS[@]} -gt 0 ]; then
            printf " ${_BOLD}Чаты:${_NC}\n"
            for i in "${!TG_CHAT_IDS[@]}"; do
                local mlabel
                [ "${TG_CHAT_MODES[$i]}" = "full" ] && mlabel="полный" || mlabel="только статус"
                printf "  %d) ${_CYAN}%s${_NC} — %s\n" "$((i+1))" "${TG_CHAT_IDS[$i]}" "$mlabel"
            done
        else
            printf " ${_YELLOW}Чаты не добавлены${_NC}\n"
        fi

        printf "\n"
        printf " ─────────────────────────────────────────────\n"
        printf " 1) 🔑 Задать токен бота\n"
        printf " 2) ➕ Добавить чат/канал/группу\n"
        printf " 3) ✏️  Изменить режим чата\n"
        printf " 4) ➖ Удалить чат\n"
        printf " 5) ⏱  Интервал обновления\n"
        printf " 6) 📤 Тест — отправить сейчас\n"
        printf " 7) ▶️  Запустить сервис\n"
        printf " 8) ⏹  Остановить сервис\n"
        printf " 9) 🗑  Удалить всё\n"
        printf " 0) ← Назад\n"
        printf "\n"
        read -rp " Выбери: " choice

        case $choice in
            1) _tg_setup_token ;;
            2) _tg_setup_add_chat ;;
            3) _tg_setup_change_mode ;;
            4) _tg_setup_del_chat ;;
            5) _tg_setup_interval ;;
            6) _tg_setup_test ;;
            7)
                tg_install_service "$TG_CORE_SCRIPT"
                sleep 1
                tg_service_status && \
                    printf " ${_GREEN}✓ Сервис запущен${_NC}\n" || \
                    printf " ${_RED}✗ Не удалось запустить${_NC}\n"
                read -rp " Enter... "
                ;;
            8)
                tg_remove_service
                printf " ${_GREEN}✓ Сервис остановлен${_NC}\n"
                read -rp " Enter... "
                ;;
            9)
                read -rp "⚠️  Удалить всё? (yes/no): " confirm
                if [ "$confirm" = "yes" ]; then
                    tg_remove_service
                    rm -rf "$TG_CORE_MSGIDS"
                    TG_BOT_TOKEN=""; TG_CHAT_IDS=(); TG_CHAT_MODES=(); TG_INTERVAL=60
                    tg_save_config
                    printf " ${_GREEN}✓ Всё удалено${_NC}\n"
                fi
                read -rp " Enter... "
                ;;
            0) return 0 ;;
            *) sleep 1 ;;
        esac
    done
}

_tg_setup_token() {
    printf "\n"
    printf " Создай бота через @BotFather → /newbot\n"
    printf " Токен формата: 1234567890:ABCdef...\n\n"
    read -rp " Токен: " new_token
    [ -z "$new_token" ] && { read -rp " Enter... "; return; }

    printf " Проверяем токен...\n"
    local resp
    resp=$(curl -s --max-time 8 "https://api.telegram.org/bot${new_token}/getMe" 2>/dev/null)
    if echo "$resp" | grep -q '"ok":true'; then
        local bot_name
        bot_name=$(echo "$resp" | grep -oP '"username":"\K[^"]+')
        TG_BOT_TOKEN="$new_token"
        tg_save_config
        printf " ${_GREEN}✓ Принят! Бот: @%s${_NC}\n" "$bot_name"
    else
        local err
        err=$(echo "$resp" | grep -oP '"description":"\K[^"]+')
        printf " ${_RED}✗ Ошибка: %s${_NC}\n" "${err:-нет соединения}"
    fi
    read -rp " Enter... "
}

_tg_setup_add_chat() {
    printf "\n"
    printf " ${_BOLD}Как получить chat_id:${_NC}\n"
    printf "  • Личка: напиши боту /start → перешли сообщение @userinfobot\n"
    printf "  • Канал: добавь бота как админа → @userinfobot\n"
    printf "  • Группа: добавь бота → напиши /start → @userinfobot\n"
    printf "  Формат: -1001234567890 (канал/группа)  или  123456789 (личка)\n\n"
    read -rp " Chat ID: " new_id
    [ -z "$new_id" ] && { read -rp " Enter... "; return; }

    # Проверяем дубликат
    for existing in "${TG_CHAT_IDS[@]+"${TG_CHAT_IDS[@]}"}"; do
        if [ "$existing" = "$new_id" ]; then
            printf " ${_YELLOW}Этот чат уже добавлен${_NC}\n"
            read -rp " Enter... "; return
        fi
    done

    printf "\n Режим:\n"
    printf " 1) Только статус (работает/нет)\n"
    printf " 2) Полный (статус + CPU/RAM + соединения)\n\n"
    read -rp " Выбор [1-2]: " mode_choice
    local new_mode
    [ "$mode_choice" = "2" ] && new_mode="full" || new_mode="status"

    TG_CHAT_IDS+=("$new_id")
    TG_CHAT_MODES+=("$new_mode")
    tg_save_config

    # FIX: сразу отправляем первое сообщение при добавлении
    if [ -n "$TG_BOT_TOKEN" ]; then
        printf " Отправляем первое сообщение...\n"
        local msg
        msg=$(tg_build_message "$new_mode")
        if tg_send "$new_id" "$msg"; then
            printf " ${_GREEN}✓ Добавлен и сообщение отправлено${_NC}\n"
        else
            printf " ${_YELLOW}⚠ Добавлен, но отправка не удалась (проверь chat_id и права бота)${_NC}\n"
        fi
    else
        printf " ${_GREEN}✓ Добавлен${_NC} (токен не задан — отправка пропущена)\n"
    fi
    read -rp " Enter... "
}

_tg_setup_change_mode() {
    [ ${#TG_CHAT_IDS[@]} -eq 0 ] && { printf " Нет чатов\n"; read -rp " Enter... "; return; }
    printf "\n"
    for i in "${!TG_CHAT_IDS[@]}"; do
        local ml; [ "${TG_CHAT_MODES[$i]}" = "full" ] && ml="полный" || ml="только статус"
        printf " %d) %s — %s\n" "$((i+1))" "${TG_CHAT_IDS[$i]}" "$ml"
    done
    printf "\n"
    read -rp " Номер чата: " idx
    idx=$(( idx - 1 ))
    if [ "$idx" -ge 0 ] && [ "$idx" -lt ${#TG_CHAT_IDS[@]} ]; then
        printf " 1) Только статус\n 2) Полный\n\n"
        read -rp " Выбор: " mc
        local new_mode
        [ "$mc" = "2" ] && new_mode="full" || new_mode="status"
        TG_CHAT_MODES[$idx]="$new_mode"
        tg_save_config

        # FIX: сбрасываем msgid чтобы отправить новое сообщение с новым форматом
        # и сразу шлём — не ждём следующего цикла демона
        local chat_id="${TG_CHAT_IDS[$idx]}"
        tg_reset_msgid "$chat_id"
        if [ -n "$TG_BOT_TOKEN" ]; then
            local msg
            msg=$(tg_build_message "$new_mode")
            tg_send "$chat_id" "$msg"
        fi
        printf " ${_GREEN}✓ Режим изменён и сообщение обновлено${_NC}\n"
    else
        printf " ${_YELLOW}Неверный номер${_NC}\n"
    fi
    read -rp " Enter... "
}

_tg_setup_del_chat() {
    [ ${#TG_CHAT_IDS[@]} -eq 0 ] && { printf " Нет чатов\n"; read -rp " Enter... "; return; }
    printf "\n"
    for i in "${!TG_CHAT_IDS[@]}"; do
        printf " %d) %s\n" "$((i+1))" "${TG_CHAT_IDS[$i]}"
    done
    printf "\n"
    read -rp " Номер для удаления: " idx
    idx=$(( idx - 1 ))
    if [ "$idx" -ge 0 ] && [ "$idx" -lt ${#TG_CHAT_IDS[@]} ]; then
        local removed="${TG_CHAT_IDS[$idx]}"
        TG_CHAT_IDS=("${TG_CHAT_IDS[@]:0:$idx}" "${TG_CHAT_IDS[@]:$((idx+1))}")
        TG_CHAT_MODES=("${TG_CHAT_MODES[@]:0:$idx}" "${TG_CHAT_MODES[@]:$((idx+1))}")
        tg_save_config
        tg_reset_msgid "$removed"
        printf " ${_GREEN}✓ Удалён${_NC}\n"
    else
        printf " ${_YELLOW}Неверный номер${_NC}\n"
    fi
    read -rp " Enter... "
}

_tg_setup_interval() {
    printf "\n"
    read -rp " Интервал в секундах (мин. 10, текущий: ${TG_INTERVAL}): " val
    if [[ "$val" =~ ^[0-9]+$ ]] && [ "$val" -ge 10 ]; then
        TG_INTERVAL=$val
        tg_save_config
        # Перезапускаем демон чтобы подхватил новый интервал
        tg_service_status && systemctl restart tg-core-notify > /dev/null 2>&1
        printf " ${_GREEN}✓ Интервал: %sс${_NC}\n" "$TG_INTERVAL"
    else
        printf " ${_YELLOW}Минимум 10 секунд${_NC}\n"
    fi
    read -rp " Enter... "
}

_tg_setup_test() {
    if [ -z "$TG_BOT_TOKEN" ]; then
        printf " ${_RED}Сначала задай токен (пункт 1)${_NC}\n"
        read -rp " Enter... "; return
    fi
    if [ ${#TG_CHAT_IDS[@]} -eq 0 ]; then
        printf " ${_RED}Добавь хотя бы один чат (пункт 2)${_NC}\n"
        read -rp " Enter... "; return
    fi
    printf "\n Отправляем...\n"
    local ok=0 fail=0
    for i in "${!TG_CHAT_IDS[@]}"; do
        local chat_id="${TG_CHAT_IDS[$i]}"
        local mode="${TG_CHAT_MODES[$i]:-status}"
        # FIX: сброс msgid перед тестом — гарантируем новое сообщение
        tg_reset_msgid "$chat_id"
        local msg
        msg=$(tg_build_message "$mode")
        if tg_send "$chat_id" "$msg"; then
            printf " ${_GREEN}✓${_NC} %s\n" "$chat_id"
            ok=$(( ok + 1 ))
        else
            printf " ${_RED}✗${_NC} %s — ошибка\n" "$chat_id"
            fail=$(( fail + 1 ))
        fi
    done
    printf "\n Отправлено: %d, ошибок: %d\n" "$ok" "$fail"
    read -rp " Enter... "
}

# ============ ТОЧКА ВХОДА (прямой запуск) ============

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    # Скрипт запущен напрямую, а не через source
    case "${1:-}" in
        --daemon)
            tg_daemon_loop
            ;;
        --setup)
            [[ $EUID -ne 0 ]] && echo "Нужен root" && exit 1
            tg_setup_interactive
            ;;
        --test)
            tg_load_config
            _tg_setup_test
            ;;
        --status)
            tg_load_config
            printf "Токен:    %s\n" "${TG_BOT_TOKEN:+задан}"
            printf "Чатов:    %d\n" "${#TG_CHAT_IDS[@]}"
            printf "Интервал: %sс\n" "$TG_INTERVAL"
            tg_service_status && printf "Сервис:   работает\n" || printf "Сервис:   остановлен\n"
            ;;
        --install)
            [[ $EUID -ne 0 ]] && echo "Нужен root" && exit 1
            mkdir -p "$TG_CORE_DIR"
            cp "$0" "$TG_CORE_SCRIPT"
            chmod +x "$TG_CORE_SCRIPT"
            echo "Установлен в $TG_CORE_SCRIPT"
            ;;
        *)
            echo "Использование: $0 [--setup|--daemon|--test|--status|--install]"
            echo "  --setup    Интерактивная настройка"
            echo "  --daemon   Запуск демона (для systemd)"
            echo "  --test     Отправить тест"
            echo "  --status   Показать статус конфига"
            echo "  --install  Установить в $TG_CORE_SCRIPT"
            ;;
    esac
fi
