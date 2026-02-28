#!/bin/bash
# ==============================================
# MTProto Diagnostic Tool v1.0
# Проверка всех компонентов и создание отчёта
# ==============================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

REPORT_FILE="/tmp/mtproto-diagnostic-$(date +%Y%m%d-%H%M%S).log"

echo -e "${BOLD}🔍 MTProto Diagnostic Tool${NC}"
echo -e "Отчёт будет сохранён в: ${CYAN}$REPORT_FILE${NC}"
echo ""

# Функция записи в отчёт
log() {
    echo "$1" >> "$REPORT_FILE"
    echo -e "$1"
}

# Функция проверки статуса
check_status() {
    if [ $1 -eq 0 ]; then
        echo -e "${GREEN}✅ $2${NC}"
        log "[OK] $2"
    else
        echo -e "${RED}❌ $2${NC}"
        log "[FAIL] $2"
        FAILED=1
    fi
}

# Начинаем отчёт
log "════════════════════════════════════════════"
log "MTProto Diagnostic Report"
log "Дата: $(date)"
log "════════════════════════════════════════════"
log ""

# 1. Проверка прав root
log "🔐 ПРОВЕРКА ПРАВ"
if [ "$EUID" -eq 0 ]; then
    check_status 0 "Запуск от root"
else
    check_status 1 "Запуск от root (нужны права!)"
fi
log ""

# 2. Проверка наличия компонентов
log "📁 ПРОВЕРКА ФАЙЛОВ"

# Менеджер
if [ -f "/usr/local/bin/mtproto-manager" ]; then
    check_status 0 "Менеджер установлен (/usr/local/bin/mtproto-manager)"
    ls -la /usr/local/bin/mtproto-manager >> "$REPORT_FILE" 2>&1
else
    check_status 1 "Менеджер НЕ установлен"
fi

# Ядро TG
if [ -f "/opt/tg-core/tg-core.sh" ]; then
    check_status 0 "Ядро TG установлено (/opt/tg-core/tg-core.sh)"
    ls -la /opt/tg-core/tg-core.sh >> "$REPORT_FILE" 2>&1
    
    # Проверяем права на выполнение
    if [ -x "/opt/tg-core/tg-core.sh" ]; then
        check_status 0 "Ядро TG: есть права на выполнение"
    else
        check_status 1 "Ядро TG: НЕТ прав на выполнение"
        chmod +x /opt/tg-core/tg-core.sh 2>/dev/null
        log "   → Права восстановлены"
    fi
else
    check_status 1 "Ядро TG НЕ установлено"
fi

# Конфиг TG
if [ -f "/opt/tg-core/config.conf" ]; then
    check_status 0 "Конфиг TG существует"
    ls -la /opt/tg-core/config.conf >> "$REPORT_FILE" 2>&1
    log "   → Размер: $(wc -l < /opt/tg-core/config.conf) строк"
else
    check_status 1 "Конфиг TG НЕ найден"
fi

# Сервис файл MTProto
if [ -f "/etc/systemd/system/mtproto-proxy.service" ]; then
    check_status 0 "Сервис MTProto существует"
else
    check_status 1 "Сервис MTProto НЕ найден"
fi

# Сервис файл TG
if [ -f "/etc/systemd/system/tg-core-notify.service" ]; then
    check_status 0 "Сервис TG Core существует"
else
    check_status 1 "Сервис TG Core НЕ найден"
fi
log ""

# 3. Проверка статуса сервисов
log "🔄 ПРОВЕРКА СЕРВИСОВ"

# MTProto сервис
if systemctl is-active --quiet mtproto-proxy 2>/dev/null; then
    check_status 0 "Сервис MTProto: активен"
    MTProto_PID=$(systemctl show -p MainPID mtproto-proxy | cut -d= -f2)
    log "   → PID: $MTProto_PID"
else
    check_status 1 "Сервис MTProto: НЕ активен"
fi

# TG Core сервис
if systemctl is-active --quiet tg-core-notify 2>/dev/null; then
    check_status 0 "Сервис TG Core: активен"
    TG_PID=$(systemctl show -p MainPID tg-core-notify | cut -d= -f2)
    log "   → PID: $TG_PID"
else
    check_status 1 "Сервис TG Core: НЕ активен"
fi
log ""

# 4. Проверка загрузки ядра в менеджере
log "🔧 ПРОВЕРКА ЗАГРУЗКИ ЯДРА"

# Создаём временный тестовый скрипт
cat > /tmp/test-tg-load.sh << 'EOF'
#!/bin/bash
TG_CORE_LOADED=0
_tg_core_load() {
    [ "$TG_CORE_LOADED" = "1" ] && return 0
    if [ ! -f "/opt/tg-core/tg-core.sh" ]; then
        return 1
    fi
    source /opt/tg-core/tg-core.sh 2>/dev/null
    local rc=$?
    if [ $rc -eq 0 ] && type tg_daemon_loop &>/dev/null; then
        TG_CORE_LOADED=1
        return 0
    else
        return 1
    fi
}

if _tg_core_load; then
    echo "✅ Ядро загружено успешно"
    if type tg_send &>/dev/null; then
        echo "✅ Функция tg_send доступна"
    else
        echo "❌ Функция tg_send НЕ доступна"
    fi
else
    echo "❌ Не удалось загрузить ядро"
fi
EOF

chmod +x /tmp/test-tg-load.sh
TEST_RESULT=$(/tmp/test-tg-load.sh)
echo "$TEST_RESULT" >> "$REPORT_FILE"
echo -e "$TEST_RESULT"
log ""

# 5. Проверка конфигурации TG
log "⚙️ ПАРСИНГ КОНФИГА TG"

if [ -f "/opt/tg-core/config.conf" ]; then
    # Извлекаем токен (безопасно, только первые символы)
    TOKEN_LINE=$(grep TG_BOT_TOKEN /opt/tg-core/config.conf | head -1)
    if [ -n "$TOKEN_LINE" ]; then
        TOKEN_VALUE=$(echo "$TOKEN_LINE" | cut -d= -f2 | tr -d "'\"")
        if [ -n "$TOKEN_VALUE" ] && [ "$TOKEN_VALUE" != '""' ]; then
            TOKEN_PREVIEW="${TOKEN_VALUE:0:8}...${TOKEN_VALUE: -4}"
            check_status 0 "Токен найден: $TOKEN_PREVIEW"
        else
            check_status 1 "Токен пустой"
        fi
    else
        check_status 1 "Токен не найден в конфиге"
    fi
    
    # Считаем чаты
    CHAT_COUNT=$(grep -c "TG_CHAT_IDS" /opt/tg-core/config.conf || echo 0)
    if [ "$CHAT_COUNT" -gt 0 ]; then
        check_status 0 "Чаты: $CHAT_COUNT"
    else
        check_status 1 "Чаты не добавлены"
    fi
    
    # Интервал
    INTERVAL_LINE=$(grep TG_INTERVAL /opt/tg-core/config.conf | head -1)
    if [ -n "$INTERVAL_LINE" ]; then
        INTERVAL=$(echo "$INTERVAL_LINE" | cut -d= -f2)
        log "   → Интервал: $INTERVAL секунд"
    fi
else
    check_status 1 "Конфиг не найден"
fi
log ""

# 6. Тест отправки (если есть токен и чаты)
log "📤 ТЕСТОВАЯ ОТПРАВКА"

if [ -f "/opt/tg-core/config.conf" ] && [ -f "/opt/tg-core/tg-core.sh" ]; then
    # Загружаем ядро и пробуем отправить
    source /opt/tg-core/tg-core.sh 2>/dev/null
    tg_load_config 2>/dev/null
    
    if [ -n "$TG_BOT_TOKEN" ] && [ ${#TG_CHAT_IDS[@]} -gt 0 ]; then
        log "Попытка отправки тестового сообщения..."
        TEST_MSG="🧪 Тестовое сообщение от диагностического скрипта $(date)"
        
        SENT=0
        for cid in "${TG_CHAT_IDS[@]}"; do
            if tg_send "$cid" "$TEST_MSG" 2>/tmp/tg-send-error.log; then
                SENT=$((SENT + 1))
            else
                ERROR_MSG=$(cat /tmp/tg-send-error.log)
                log "   → Ошибка для $cid: $ERROR_MSG"
            fi
        done
        
        if [ $SENT -gt 0 ]; then
            check_status 0 "Отправлено $SENT сообщений"
        else
            check_status 1 "Не удалось отправить ни одного сообщения"
            log "   → Проверь ошибки выше"
        fi
    else
        if [ -z "$TG_BOT_TOKEN" ]; then
            check_status 1 "Нет токена для теста"
        fi
        if [ ${#TG_CHAT_IDS[@]} -eq 0 ]; then
            check_status 1 "Нет чатов для теста"
        fi
    fi
else
    check_status 1 "Нет компонентов для теста отправки"
fi
log ""

# 7. Итог
log "════════════════════════════════════════════"
if [ -z "$FAILED" ]; then
    log "${GREEN}✅ ВСЕ ПРОВЕРКИ ПРОЙДЕНЫ${NC}"
else
    log "${RED}❌ ОБНАРУЖЕНЫ ПРОБЛЕМЫ${NC}"
    log "Проверь отчёт выше для деталей"
fi
log "════════════════════════════════════════════"

echo ""
echo -e "${BOLD}📋 Отчёт сохранён:${NC} ${CYAN}$REPORT_FILE${NC}"
echo -e "${YELLOW}Если есть ошибки, покажи этот файл в поддержке${NC}"
