diff --git a/mtproto-universal.sh b/mtproto-universal.sh
index 4d322a05b13fc678c7a30ed252fcc15d0d10cb20..1b57756d9d80d4d3a5102ea24ec7f37f295fb954 100644
--- a/mtproto-universal.sh
+++ b/mtproto-universal.sh
@@ -1,40 +1,40 @@
 #!/bin/bash
 # ==============================================
 # MTProto Proxy — Universal Manager v3.0
 # Установка + Менеджер в одном скрипте
 # github.com/tarpy-socdev/MTProto-VPS
 # ==============================================
 set -e
 
 # ============ ЦВЕТА И СТИЛИ ============
-RED='\033[0;31m'
-GREEN='\033[0;32m'
-YELLOW='\033[1;33m'
-CYAN='\033[0;36m'
-BOLD='\033[1m'
-NC='\033[0m'
+RED=$'\033[0;31m'
+GREEN=$'\033[0;32m'
+YELLOW=$'\033[1;33m'
+CYAN=$'\033[0;36m'
+BOLD=$'\033[1m'
+NC=$'\033[0m'
 
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
@@ -82,58 +82,68 @@ check_port_available() {
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
 
+get_installation_status() {
+    if check_installation; then
+        echo 0
+    elif [ -f "$SERVICE_FILE" ]; then
+        echo 1
+    else
+        echo 2
+    fi
+}
+
 [[ $EUID -ne 0 ]] && err "Запускай от root! (sudo bash script.sh)"
 
 # ============ ГЛАВНОЕ МЕНЮ ============
 show_start_menu() {
     clear_screen
     
-    check_installation
-    local status=$?
+    local status
+    status=$(get_installation_status)
     
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
@@ -465,52 +475,52 @@ EOF
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
     
-    check_installation
-    local status=$?
+    local status
+    status=$(get_installation_status)
     
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
@@ -567,61 +577,61 @@ manager_show_status() {
     
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
     
-    echo " Пользователь:  ${CYAN}$RUN_USER${NC}"
-    echo " Сервер IP:     ${CYAN}$SERVER_IP${NC}"
-    echo " Внешний порт:  ${CYAN}$PROXY_PORT${NC}"
-    echo " Внутренний порт: ${CYAN}$INTERNAL_PORT${NC}"
-    echo " Секрет:        ${CYAN}${SECRET:0:16}...${NC}"
+    printf " Пользователь:  %b%s%b\n" "$CYAN" "$RUN_USER" "$NC"
+    printf " Сервер IP:     %b%s%b\n" "$CYAN" "$SERVER_IP" "$NC"
+    printf " Внешний порт:  %b%s%b\n" "$CYAN" "$PROXY_PORT" "$NC"
+    printf " Внутренний порт: %b%s%b\n" "$CYAN" "$INTERNAL_PORT" "$NC"
+    printf " Секрет:        %b%s...%b\n" "$CYAN" "${SECRET:0:16}" "$NC"
     
     if grep -q -- "-P " "$SERVICE_FILE"; then
         SPONSOR_TAG=$(grep -oP '(?<=-P )\S+' "$SERVICE_FILE" || echo "N/A")
-        echo " Тег спонсора:  ${CYAN}$SPONSOR_TAG${NC}"
+        printf " Тег спонсора:  %b%s%b\n" "$CYAN" "$SPONSOR_TAG" "$NC"
     else
-        echo " Тег спонсора:  ${YELLOW}не установлен${NC}"
+        printf " Тег спонсора:  %bне установлен%b\n" "$YELLOW" "$NC"
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
@@ -701,101 +711,130 @@ manager_remove_tag() {
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
 
+ensure_bind_permissions() {
+    local target_port=$1
+    local service_user
+
+    service_user=$(grep "^User=" "$SERVICE_FILE" | cut -d'=' -f2)
+
+    if [ "$service_user" = "mtproxy" ] && [ "$target_port" -lt 1024 ]; then
+        if ! command -v setcap &>/dev/null; then
+            apt install -y libcap2-bin >> "$LOGFILE" 2>&1
+        fi
+
+        if command -v setcap &>/dev/null; then
+            setcap "cap_net_bind_service=+ep" "$INSTALL_DIR/mtproto-proxy"
+        else
+            warning "Не удалось установить setcap (libcap2-bin). Порт <1024 может не заработать для mtproxy"
+        fi
+    fi
+}
+
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
-        err "Порт $NEW_PORT уже занят!"
+        warning "Порт $NEW_PORT уже занят!"
+        read -rp " Нажми Enter для возврата... "
+        return
     fi
-    
+
     sed -i "s|-H [0-9]*|-H $NEW_PORT|" "$SERVICE_FILE"
+
+    ensure_bind_permissions "$NEW_PORT"
+
     systemctl daemon-reload > /dev/null 2>&1
     systemctl restart mtproto-proxy > /dev/null 2>&1
     sleep 2
-    
-    success "Порт изменен на $NEW_PORT!"
+
+    if systemctl is-active --quiet mtproto-proxy; then
+        success "Порт изменен на $NEW_PORT!"
+    else
+        warning "Порт изменен, но сервис не запустился. Проверь: journalctl -u mtproto-proxy -n 50 --no-pager"
+    fi
+
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
     
@@ -803,65 +842,67 @@ manager_restart() {
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
-    if [ ! -L "$MANAGER_LINK" ] || [ "$(readlink $MANAGER_LINK)" != "$0" ]; then
-        ln -sf "$0" "$MANAGER_LINK" 2>/dev/null || true
+    local script_path
+    script_path=$(realpath "$0" 2>/dev/null || echo "$0")
+
+    if [ ! -L "$MANAGER_LINK" ] || [ "$(readlink -f "$MANAGER_LINK" 2>/dev/null || true)" != "$script_path" ]; then
+        ln -sf "$script_path" "$MANAGER_LINK" 2>/dev/null || true
         chmod +x "$MANAGER_LINK" 2>/dev/null || true
     fi
 }
 
 # ============ ОСНОВНОЙ ЦИКЛ ============
 install_command
 
 # Главный цикл программы
 while true; do
     clear_screen
     
-    check_installation
-    local status=$?
+    status=$(get_installation_status)
     
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
