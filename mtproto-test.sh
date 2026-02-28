#!/bin/bash
# ==============================================
# MTProto Auto-Test & Repair Tool v1.0
# Тестирует все функции и чинит проблемы
# ==============================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'
LOG_FILE="/tmp/mtproto-test-$(date +%Y%m%d-%H%M%S).log"
FIXED_ANY=0

log() { echo "$1" | tee -a "$LOG_FILE"; }
ok() { log "${GREEN}✅ $1${NC}"; }
fail() { log "${RED}❌ $1${NC}"; FIXED_ANY=1; }
warn() { log "${YELLOW}⚠️ $1${NC}"; }

log "${BOLD}🔍 MTProto Auto-Test & Repair Tool${NC}"
log "Лог: $LOG_FILE\n"

# 1. Проверка прав
if [ "$EUID" -ne 0 ]; then
    fail "Скрипт должен быть запущен от root"
    exit 1
else
    ok "Права root"
fi

# 2. Проверка и запуск сервиса TG Core
log "\n${BOLD}📡 Проверка TG Core сервиса:${NC}"
if systemctl is-active --quiet tg-core-notify; then
    ok "Сервис tg-core-notify активен"
else
    warn "Сервис tg-core-notify остановлен. Пробую запустить..."
    systemctl start tg-core-notify
    sleep 3
    if systemctl is-active --quiet tg-core-notify; then
        ok "Сервис успешно запущен"
    else
        fail "Не удалось запустить сервис. Пробую переустановить..."
        if [ -f "/opt/tg-core/tg-core.sh" ]; then
            bash /opt/tg-core/tg-core.sh --install
            systemctl start tg-core-notify
            sleep 3
            if systemctl is-active --quiet tg-core-notify; then
                ok "Сервис переустановлен и запущен"
            else
                fail "Критическая ошибка: сервис не запускается"
            fi
        fi
    fi
fi

# 3. Проверка загрузки функций ядра
log "\n${BOLD}📚 Проверка функций ядра:${NC}"
if [ -f "/opt/tg-core/tg-core.sh" ]; then
    source /opt/tg-core/tg-core.sh
    if type tg_send &>/dev/null; then
        ok "Функция tg_send доступна"
    else
        fail "Функция tg_send НЕ доступна"
    fi
    
    if type tg_daemon_loop &>/dev/null; then
        ok "Функция tg_daemon_loop доступна"
    else
        fail "Функция tg_daemon_loop НЕ доступна"
    fi
else
    fail "Файл ядра не найден"
fi

# 4. Тест отправки
log "\n${BOLD}📤 Тест отправки сообщений:${NC}"
if type tg_send &>/dev/null; then
    tg_load_config
    SENT=0
    for cid in "${TG_CHAT_IDS[@]}"; do
        TEST_MSG="🧪 Тест $(date)"
        if tg_send "$cid" "$TEST_MSG" 2>/dev/null; then
            SENT=$((SENT+1))
        fi
    done
    if [ $SENT -gt 0 ]; then
        ok "Отправлено $SENT сообщений"
    else
        fail "Не удалось отправить сообщения"
    fi
else
    fail "Пропуск теста отправки (нет функции)"
fi

# 5. Проверка менеджера
log "\n${BOLD}📱 Проверка менеджера:${NC}"
MANAGER_PATH=$(which mtproto-manager 2>/dev/null)
if [ -n "$MANAGER_PATH" ]; then
    ok "Менеджер найден: $MANAGER_PATH"
else
    fail "Менеджер не найден в PATH"
fi

# Итог
log "\n${BOLD}════════════════════════════════════════════${NC}"
if [ $FIXED_ANY -eq 0 ]; then
    log "${GREEN}✅ Все тесты пройдены успешно!${NC}"
else
    log "${YELLOW}⚠️ Некоторые проблемы были исправлены. Запусти тест снова.${NC}"
fi
log "Подробный лог: $LOG_FILE"
