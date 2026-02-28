#!/bin/bash
# ==============================================
# TG Core — Telegram Notification Engine v1.2
# Независимое ядро TG-уведомлений
# github.com/tarpy-socdev/MTP-manager
# ==============================================
# ИСПОЛЬЗОВАНИЕ:
#   Прямой запуск:  bash tg-core.sh [--setup|--daemon|--test|--status|--install]
#   Интеграция:     source /opt/tg-core/tg-core.sh
#
# ПЕРЕМЕННЫЕ (задаются до source):
#   TG_PROJECT_NAME  — имя проекта (по умолчанию: "Service")
#   TG_BUILD_MSG_FN  — колбек построения сообщения: fn(mode)
# ==============================================
# CHANGELOG v1.2:
# - Улучшена обработка ошибок в tg_send (проверка "message not modified")
# - Замена grep -P на sed для совместимости
# - Улучшен демон с таймаутом ожидания токена
# - Фиксированный путь установки вместо копирования через $0
# - Замена ручной очистки на clear
# ==============================================

# ── Пути ──────────────────────────────────────
TG_CORE_DIR="/opt/tg-core"
TG_CORE_CONFIG="$TG_CORE_DIR/config.conf"
TG_CORE_MSGIDS="$TG_CORE_DIR/msgids"
TG_CORE_SERVICE="/etc/systemd/system/tg-core-notify.service"
TG_CORE_SCRIPT="/opt/tg-core/tg-core.sh"

# ── Цвета ─────────────────────────────────────
if [ -t 1 ]; then
    _R=$'\033[0;31m' _G=$'\033[0;32m' _Y=$'\033[1;33m'
    _C=$'\033[0;36m' _B=$'\033[1m'    _N=$'\033[0m'
else
    _R="" _G="" _Y="" _C="" _B="" _N=""
fi

TG_PROJECT_NAME="${TG_PROJECT_NAME:-Service}"

# ============ CONFIG ============

tg_load_config() {
    TG_BOT_TOKEN=""
    TG_INTERVAL=60
    TG_CHAT_IDS=()
    TG_CHAT_MODES=()
    TG_CHAT_NAMES=()
    if [ -f "$TG_CORE_CONFIG" ]; then
        source "$TG_CORE_CONFIG" 2>/dev/null || true
    fi
    # Гарантируем что массивы одинаковой длины
    local n=${#TG_CHAT_IDS[@]}
    while [ ${#TG_CHAT_MODES[@]} -lt $n ]; do TG_CHAT_MODES+=("status"); done
    while [ ${#TG_CHAT_NAMES[@]} -lt $n ]; do TG_CHAT_NAMES+=(""); done
}

tg_save_config() {
    mkdir -p "$TG_CORE_DIR" "$TG_CORE_MSGIDS"
    {
        printf "TG_BOT_TOKEN=%q\n" "$TG_BOT_TOKEN"
        printf "TG_INTERVAL=%d\n" "$TG_INTERVAL"
        # Массивы — каждый элемент на отдельной строке через printf %q
        printf "TG_CHAT_IDS=(\n"
        for v in "${TG_CHAT_IDS[@]+"${TG_CHAT_IDS[@]}"}"; do printf "  %q\n" "$v"; done
        printf ")\n"
        printf "TG_CHAT_MODES=(\n"
        for v in "${TG_CHAT_MODES[@]+"${TG_CHAT_MODES[@]}"}"; do printf "  %q\n" "$v"; done
        printf ")\n"
        printf "TG_CHAT_NAMES=(\n"
        for v in "${TG_CHAT_NAMES[@]+"${TG_CHAT_NAMES[@]}"}"; do printf "  %q\n" "$v"; done
        printf ")\n"
    } > "$TG_CORE_CONFIG"
    chmod 600 "$TG_CORE_CONFIG"
}

# ============ ОТПРАВКА (УЛУЧШЕННАЯ) ============

_tg_msgid_file() {
    local chat_id="$1"
    local hash
    hash=$(echo -n "$chat_id" | md5sum | cut -c1-16)
    echo "${TG_CORE_MSGIDS}/msgid_${hash}"
}

tg_reset_msgid() {
    rm -f "$(_tg_msgid_file "$1")"
}

tg_send() {
    local chat_id="$1" text="$2"
    local token="$TG_BOT_TOKEN"
    [ -z "$token" ] || [ -z "$chat_id" ] || [ -z "$text" ] && return 1

    mkdir -p "$TG_CORE_MSGIDS"
    local msgid_file
    msgid_file=$(_tg_msgid_file "$chat_id")

    # Пробуем редактировать существующее сообщение
    if [ -f "$msgid_file" ]; then
        local msg_id
        msg_id=$(cat "$msgid_file" 2>/dev/null)
        if [ -n "$msg_id" ]; then
            local resp
            resp=$(curl -s --max-time 10 \
                "https://api.telegram.org/bot${token}/editMessageText" \
                -d "chat_id=${chat_id}" \
                -d "message_id=${msg_id}" \
                -d "parse_mode=HTML" \
                --data-urlencode "text=${text}" 2>/dev/null)
            
            # Проверяем успех
            if echo "$resp" | grep -q '"ok":true'; then
                return 0
            fi
            
            # Проверяем специфичную ошибку "message is not modified"
            if echo "$resp" | grep -q '"description":"Bad Request: message is not modified"'; then
                return 0  # Считаем успехом, ничего не меняем
            fi
            
            # Другая ошибка - удаляем файл и отправим новое
            rm -f "$msgid_file"
        fi
    fi

    # Новое сообщение
    local resp
    resp=$(curl -s --max-time 10 \
        "https://api.telegram.org/bot${token}/sendMessage" \
        -d "chat_id=${chat_id}" \
        -d "parse_mode=HTML" \
        --data-urlencode "text=${text}" 2>/dev/null)

    if echo "$resp" | grep -q '"ok":true'; then
        # Более надежное извлечение message_id без grep -P
        local mid
        mid=$(echo "$resp" | sed -n 's/.*"message_id":\([0-9]*\).*/\1/p' | head -1)
        [ -n "$mid" ] && echo "$mid" > "$msgid_file"
        return 0
    fi

    local err
    err=$(echo "$resp" | sed -n 's/.*"description":"\([^"]*\).*/\1/p' | head -1)
    printf "[tg-core] ✗ %s: %s\n" "$chat_id" "${err:-нет ответа}" >&2
    return 1
}

# ============ ПОСТРОЕНИЕ СООБЩЕНИЙ ============

_tg_default_build_msg() {
    local mode="$1"
    if [ "$mode" = "status" ]; then
        local status_line
        declare -f tg_project_status > /dev/null 2>&1 \
            && status_line=$(tg_project_status) \
            || status_line="Статус неизвестен"
        printf "📡 <b>%s</b>\n%s\n🕐 <i>%s</i>" \
            "$TG_PROJECT_NAME" "$status_line" "$(date '+%d.%m.%Y %H:%M:%S')"
    else
        declare -f tg_project_full_report > /dev/null 2>&1 \
            && tg_project_full_report \
            || printf "📡 <b>%s</b>\n🕐 <i>%s</i>" "$TG_PROJECT_NAME" "$(date '+%d.%m.%Y %H:%M:%S')"
    fi
}

tg_build_message() {
    local mode="$1"
    if [ -n "${TG_BUILD_MSG_FN:-}" ] && declare -f "$TG_BUILD_MSG_FN" > /dev/null 2>&1; then
        "$TG_BUILD_MSG_FN" "$mode"
    else
        _tg_default_build_msg "$mode"
    fi
}

# ============ ДЕМОН (УЛУЧШЕННЫЙ) ============

tg_daemon_loop() {
    # Ждём конфига с токеном
    local waited=0
    while true; do
        tg_load_config
        if [ -n "$TG_BOT_TOKEN" ]; then
            break
        fi
        waited=$((waited + 10))
        if [ $waited -ge 300 ]; then  # 5 минут ожидания
            echo "[tg-core] Токен не появился после 5 минут ожидания, завершаю работу" >&2
            exit 1
        fi
        sleep 10
    done

    while true; do
        tg_load_config

        if [ -n "$TG_BOT_TOKEN" ] && [ ${#TG_CHAT_IDS[@]} -gt 0 ]; then
            for i in "${!TG_CHAT_IDS[@]}"; do
                local cid="${TG_CHAT_IDS[$i]}"
                local mode="${TG_CHAT_MODES[$i]:-status}"
                local msg
                msg=$(tg_build_message "$mode")
                tg_send "$cid" "$msg"
            done
        fi

        sleep "${TG_INTERVAL:-60}"
    done
}

# ============ SYSTEMD СЕРВИС (УЛУЧШЕННЫЙ) ============

tg_install_service() {
    local daemon_script="/opt/tg-core/tg-core.sh"  # Фиксированный путь

    # Убеждаемся что ядро скопировано в постоянное место
    if [ ! -f "$daemon_script" ]; then
        mkdir -p "$TG_CORE_DIR"
        # Копируем текущий скрипт, но не через $0
        if [ -n "${BASH_SOURCE[0]}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
            cp "${BASH_SOURCE[0]}" "$daemon_script" 2>/dev/null
        else
            # Fallback: пытаемся найти скрипт в PATH
            local script_path
            script_path=$(which tg-core.sh 2>/dev/null)
            if [ -n "$script_path" ] && [ -f "$script_path" ]; then
                cp "$script_path" "$daemon_script" 2>/dev/null
            fi
        fi
        chmod +x "$daemon_script" 2>/dev/null || true
    fi

    cat > "$TG_CORE_SERVICE" << EOF
[Unit]
Description=TG Core Notification Daemon
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/bin/bash ${daemon_script} --daemon
Restart=on-failure
RestartSec=10
Environment=TG_PROJECT_NAME=${TG_PROJECT_NAME}
Environment=TG_BUILD_MSG_FN=${TG_BUILD_MSG_FN:-}

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
# ============ ИНТЕРАКТИВНАЯ НАСТРОЙКА (УЛУЧШЕННАЯ) ============

tg_setup_interactive() {
    # tg_load_config вызывается вызывающей стороной или здесь
    [ ${#TG_CHAT_IDS[@]} -eq 0 ] && [ -z "$TG_BOT_TOKEN" ] && tg_load_config

    while true; do
        # Перечитываем конфиг при каждом показе меню — подхватываем внешние изменения
        tg_load_config
        clear
        printf "${_C}${_B}"
        printf " ╔════════════════════════════════════════════╗\n"
        printf " ║     TG Core — Настройка уведомлений v1.2  ║\n"
        printf " ╚════════════════════════════════════════════╝\n"
        printf "${_N}\n"

        if tg_service_status; then
            printf " Сервис:   ${_G}✅ РАБОТАЕТ${_N}\n"
        else
            printf " Сервис:   ${_Y}⏹  ОСТАНОВЛЕН${_N}\n"
        fi

        if [ -n "$TG_BOT_TOKEN" ]; then
            printf " Токен:    ${_G}✓ задан${_N} (%s...)\n" "${TG_BOT_TOKEN:0:12}"
        else
            printf " Токен:    ${_R}✗ не задан${_N}\n"
        fi

        printf " Интервал: ${_C}%sс${_N}\n\n" "$TG_INTERVAL"

        if [ ${#TG_CHAT_IDS[@]} -gt 0 ]; then
            printf " ${_B}Чаты:${_N}\n"
            for i in "${!TG_CHAT_IDS[@]}"; do
                local ml name
                [ "${TG_CHAT_MODES[$i]}" = "full" ] && ml="полный" || ml="только статус"
                name="${TG_CHAT_NAMES[$i]:-}"
                [ -n "$name" ] && name=" (${_B}${name}${_N})" || name=""
                printf "  %d) ${_C}%s${_N}%s — %s\n" "$((i+1))" "${TG_CHAT_IDS[$i]}" "$name" "$ml"
            done
        else
            printf " ${_Y}Чаты не добавлены${_N}\n"
        fi

        printf "\n ─────────────────────────────────────────────\n"
        printf " 1) 🔑 Задать токен\n"
        printf " 2) ➕ Добавить чат/канал/группу\n"
        printf " 3) ✏️  Изменить режим чата\n"
        printf " 4) 🏷  Переименовать чат\n"
        printf " 5) ➖ Удалить чат\n"
        printf " 6) ⏱  Интервал обновления\n"
        printf " 7) 📤 Тест — отправить сейчас\n"
        printf " 8) ▶️  Запустить сервис\n"
        printf " 9) ⏹  Остановить сервис\n"
        printf " 10) 🗑 Удалить всё\n"
        printf " 0) ← Назад\n\n"
        read -rp " Выбери: " ch

        case $ch in
            1)  _tg_setup_token ;;
            2)  _tg_setup_add_chat ;;
            3)  _tg_setup_change_mode ;;
            4)  _tg_setup_rename_chat ;;
            5)  _tg_setup_del_chat ;;
            6)  _tg_setup_interval ;;
            7)  _tg_setup_test ;;
            8)
                tg_install_service
                sleep 2
                if tg_service_status; then
                    printf " ${_G}✓ Сервис запущен${_N}\n"
                else
                    printf " ${_R}✗ Не удалось запустить. Лог:\n${_N}"
                    journalctl -u tg-core-notify -n 10 --no-pager 2>/dev/null
                fi
                read -rp " Enter... "
                ;;
            9)
                tg_remove_service
                printf " ${_G}✓ Остановлен${_N}\n"
                read -rp " Enter... "
                ;;
            10)
                read -rp "⚠️  Удалить всё? (yes/no): " c
                if [ "$c" = "yes" ]; then
                    tg_remove_service
                    rm -rf "$TG_CORE_MSGIDS"
                    TG_BOT_TOKEN=""; TG_CHAT_IDS=(); TG_CHAT_MODES=()
                    TG_CHAT_NAMES=(); TG_INTERVAL=60
                    tg_save_config
                    printf " ${_G}✓ Удалено${_N}\n"
                fi
                read -rp " Enter... "
                ;;
            0) return 0 ;;
            *) sleep 1 ;;
        esac
    done
}

_tg_setup_token() {
    printf "\n Создай бота: @BotFather → /newbot\n Токен: 1234567890:ABCdef...\n\n"
    read -rp " Токен: " new_token
    [ -z "$new_token" ] && return
    printf " Проверяем...\n"
    local resp
    resp=$(curl -s --max-time 8 "https://api.telegram.org/bot${new_token}/getMe" 2>/dev/null)
    if echo "$resp" | grep -q '"ok":true'; then
        local bot
        bot=$(echo "$resp" | sed -n 's/.*"username":"\([^"]*\).*/\1/p')
        TG_BOT_TOKEN="$new_token"
        tg_save_config
        printf " ${_G}✓ Принят! @%s${_N}\n" "$bot"
    else
        local err
        err=$(echo "$resp" | sed -n 's/.*"description":"\([^"]*\).*/\1/p')
        printf " ${_R}✗ %s${_N}\n" "${err:-нет соединения}"
    fi
    read -rp " Enter... "
}

_tg_setup_add_chat() {
    printf "\n ${_B}Как получить chat_id:${_N}\n"
    printf "  Личка:  напиши боту /start → перешли @userinfobot\n"
    printf "  Канал:  добавь бота как админа → @userinfobot\n"
    printf "  Группа: добавь бота → /start → @userinfobot\n"
    printf "  Формат: -1001234567890 (канал/группа)  123456789 (личка)\n\n"
    read -rp " Chat ID: " new_id
    [ -z "$new_id" ] && return

    # Проверка дубликата
    for ex in "${TG_CHAT_IDS[@]+"${TG_CHAT_IDS[@]}"}"; do
        if [ "$ex" = "$new_id" ]; then
            printf " ${_Y}Уже добавлен${_N}\n"; read -rp " Enter... "; return
        fi
    done

    read -rp " Название (необязательно, Enter пропустить): " new_name

    printf "\n Режим:\n 1) Только статус\n 2) Полный (статус + ресурсы)\n\n"
    read -rp " Выбор [1-2]: " mc
    local new_mode; [ "$mc" = "2" ] && new_mode="full" || new_mode="status"

    TG_CHAT_IDS+=("$new_id")
    TG_CHAT_MODES+=("$new_mode")
    TG_CHAT_NAMES+=("$new_name")
    tg_save_config

    # Сразу отправляем первое сообщение
    if [ -n "$TG_BOT_TOKEN" ]; then
        printf " Отправляем...\n"
        local msg; msg=$(tg_build_message "$new_mode")
        if tg_send "$new_id" "$msg"; then
            printf " ${_G}✓ Добавлен, сообщение отправлено${_N}\n"
        else
            printf " ${_Y}⚠ Добавлен, но отправка не удалась\n  Проверь: chat_id верный, бот добавлен в чат, бот — админ в канале${_N}\n"
        fi
    else
        printf " ${_G}✓ Добавлен${_N} (токен не задан)\n"
    fi
    read -rp " Enter... "
}

_tg_setup_change_mode() {
    [ ${#TG_CHAT_IDS[@]} -eq 0 ] && { printf " Нет чатов\n"; read -rp " Enter... "; return; }
    printf "\n"
    for i in "${!TG_CHAT_IDS[@]}"; do
        local ml name
        [ "${TG_CHAT_MODES[$i]}" = "full" ] && ml="полный" || ml="только статус"
        name="${TG_CHAT_NAMES[$i]:-${TG_CHAT_IDS[$i]}}"
        printf " %d) %s — %s\n" "$((i+1))" "$name" "$ml"
    done
    printf "\n"; read -rp " Номер: " idx; idx=$(( idx - 1 ))
    if [ "$idx" -ge 0 ] && [ "$idx" -lt ${#TG_CHAT_IDS[@]} ]; then
        printf " 1) Только статус\n 2) Полный\n\n"
        read -rp " Выбор: " mc
        local new_mode; [ "$mc" = "2" ] && new_mode="full" || new_mode="status"
        TG_CHAT_MODES[$idx]="$new_mode"
        tg_save_config
        # Сбрасываем msgid и сразу отправляем новый формат
        local cid="${TG_CHAT_IDS[$idx]}"
        tg_reset_msgid "$cid"
        if [ -n "$TG_BOT_TOKEN" ]; then
            local msg; msg=$(tg_build_message "$new_mode")
            tg_send "$cid" "$msg"
        fi
        printf " ${_G}✓ Изменён и отправлен${_N}\n"
    else
        printf " ${_Y}Неверный номер${_N}\n"
    fi
    read -rp " Enter... "
}

_tg_setup_rename_chat() {
    [ ${#TG_CHAT_IDS[@]} -eq 0 ] && { printf " Нет чатов\n"; read -rp " Enter... "; return; }
    printf "\n"
    for i in "${!TG_CHAT_IDS[@]}"; do
        printf " %d) %s — «%s»\n" "$((i+1))" "${TG_CHAT_IDS[$i]}" "${TG_CHAT_NAMES[$i]:-без названия}"
    done
    printf "\n"; read -rp " Номер: " idx; idx=$(( idx - 1 ))
    if [ "$idx" -ge 0 ] && [ "$idx" -lt ${#TG_CHAT_IDS[@]} ]; then
        read -rp " Новое название (Enter — убрать): " new_name
        TG_CHAT_NAMES[$idx]="$new_name"
        tg_save_config
        printf " ${_G}✓ Сохранено${_N}\n"
    fi
    read -rp " Enter... "
}

_tg_setup_del_chat() {
    [ ${#TG_CHAT_IDS[@]} -eq 0 ] && { printf " Нет чатов\n"; read -rp " Enter... "; return; }
    printf "\n"
    for i in "${!TG_CHAT_IDS[@]}"; do
        local name="${TG_CHAT_NAMES[$i]:-${TG_CHAT_IDS[$i]}}"
        printf " %d) %s\n" "$((i+1))" "$name"
    done
    printf "\n"; read -rp " Номер: " idx; idx=$(( idx - 1 ))
    if [ "$idx" -ge 0 ] && [ "$idx" -lt ${#TG_CHAT_IDS[@]} ]; then
        local removed="${TG_CHAT_IDS[$idx]}"
        TG_CHAT_IDS=("${TG_CHAT_IDS[@]:0:$idx}"   "${TG_CHAT_IDS[@]:$((idx+1))}")
        TG_CHAT_MODES=("${TG_CHAT_MODES[@]:0:$idx}" "${TG_CHAT_MODES[@]:$((idx+1))}")
        TG_CHAT_NAMES=("${TG_CHAT_NAMES[@]:0:$idx}" "${TG_CHAT_NAMES[@]:$((idx+1))}")
        tg_save_config
        tg_reset_msgid "$removed"
        printf " ${_G}✓ Удалён${_N}\n"
    else
        printf " ${_Y}Неверный номер${_N}\n"
    fi
    read -rp " Enter... "
}

_tg_setup_interval() {
    printf "\n"
    read -rp " Интервал сек (мин. 10, сейчас: ${TG_INTERVAL}): " val
    if [[ "$val" =~ ^[0-9]+$ ]] && [ "$val" -ge 10 ]; then
        TG_INTERVAL=$val
        tg_save_config
        tg_service_status && systemctl restart tg-core-notify > /dev/null 2>&1
        printf " ${_G}✓ %sс${_N}\n" "$TG_INTERVAL"
    else
        printf " ${_Y}Минимум 10${_N}\n"
    fi
    read -rp " Enter... "
}

_tg_setup_test() {
    [ -z "$TG_BOT_TOKEN" ] && { printf " ${_R}Сначала задай токен (п.1)${_N}\n"; read -rp " Enter... "; return; }
    [ ${#TG_CHAT_IDS[@]} -eq 0 ] && { printf " ${_R}Добавь чат (п.2)${_N}\n"; read -rp " Enter... "; return; }
    printf "\n"
    local ok=0 fail=0
    for i in "${!TG_CHAT_IDS[@]}"; do
        local cid="${TG_CHAT_IDS[$i]}"
        local mode="${TG_CHAT_MODES[$i]:-status}"
        local name="${TG_CHAT_NAMES[$i]:-$cid}"
        tg_reset_msgid "$cid"  # принудительно новое сообщение
        local msg; msg=$(tg_build_message "$mode")
        if tg_send "$cid" "$msg"; then
            printf " ${_G}✓${_N} %s\n" "$name"; ok=$(( ok+1 ))
        else
            printf " ${_R}✗${_N} %s\n" "$name"; fail=$(( fail+1 ))
        fi
    done
    printf "\n OK: %d  Ошибок: %d\n" "$ok" "$fail"
    read -rp " Enter... "
}

# ============ ТОЧКА ВХОДА ============

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    case "${1:-}" in
        --daemon)
            tg_daemon_loop
            ;;
        --setup)
            [[ $EUID -ne 0 ]] && echo "Нужен root" && exit 1
            tg_load_config
            tg_setup_interactive
            ;;
        --test)
            tg_load_config
            _tg_setup_test
            ;;
        --status)
            tg_load_config
            printf "Токен:    %s\n" "${TG_BOT_TOKEN:+задан (${TG_BOT_TOKEN:0:12}...)}"
            printf "Чатов:    %d\n" "${#TG_CHAT_IDS[@]}"
            for i in "${!TG_CHAT_IDS[@]}"; do
                printf "  [%d] %s «%s» режим=%s\n" \
                    "$((i+1))" "${TG_CHAT_IDS[$i]}" \
                    "${TG_CHAT_NAMES[$i]:-}" "${TG_CHAT_MODES[$i]}"
            done
            printf "Интервал: %sс\n" "$TG_INTERVAL"
            tg_service_status && printf "Сервис:   ✅ работает\n" || printf "Сервис:   ⏹ остановлен\n"
            ;;
        --install)
            [[ $EUID -ne 0 ]] && echo "Нужен root" && exit 1
            mkdir -p "$TG_CORE_DIR"
            # Копируем текущий скрипт
            if [ -n "${BASH_SOURCE[0]}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
                cp "${BASH_SOURCE[0]}" "$TG_CORE_SCRIPT"
            else
                cp "$0" "$TG_CORE_SCRIPT"
            fi
            chmod +x "$TG_CORE_SCRIPT"
            echo "✓ Установлен: $TG_CORE_SCRIPT"
            ;;
        *)
            printf "tg-core.sh v1.2 — TG Notification Engine\n"
            printf "Использование: %s [опция]\n\n" "$0"
            printf "  --setup    Интерактивная настройка\n"
            printf "  --daemon   Запуск демона (systemd)\n"
            printf "  --test     Тест отправки\n"
            printf "  --status   Статус конфига\n"
            printf "  --install  Установить в %s\n" "$TG_CORE_SCRIPT"
            ;;
    esac
fi
