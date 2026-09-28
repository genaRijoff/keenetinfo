#!/bin/sh
# ============================================================
#  Установка kss (kn-info) — сводка роутера Keenetic
#    curl -fsSL https://raw.githubusercontent.com/genaRijoff/keenetinfo/main/install.sh | sh
#  Потом: kss | kss -f | kss update | kss uninstall
# ============================================================

RAW_BASE="${KN_RAW_BASE:-https://raw.githubusercontent.com/genaRijoff/keenetinfo/main}"
PREFIX="${KN_PREFIX:-/opt}"            # KN_* — для тестов
BIN="$PREFIX/bin/kss"
LOCAL="$PREFIX/share/kn-info.sh"

echo "==> Установка kss"

[ -d "$PREFIX/bin" ] || { echo "[!] Нет $PREFIX/bin — нужен Entware (OPKG)."; exit 1; }

# --- Пакеты: curl обязателен, jq — по возможности ---
OPKG_UPDATED=""
need_pkg() {
    opkg list-installed 2>/dev/null | grep -q "^$1 " && return 0
    if [ -z "$OPKG_UPDATED" ]; then opkg update >/dev/null 2>&1; OPKG_UPDATED=1; fi
    echo "==> opkg install $1"
    opkg install "$1" >/dev/null 2>&1
}
command -v curl >/dev/null 2>&1 || need_pkg curl
command -v curl >/dev/null 2>&1 || { echo "[!] curl не поставился: opkg install curl"; exit 1; }
command -v jq >/dev/null 2>&1 || need_pkg jq
command -v jq >/dev/null 2>&1 || echo "[~] jq нет — не страшно, JSON разберёт awk."

# --- Скрипт: качаем и проверяем, что это рабочий sh ---
fetch() {   # <url> <файл>
    if curl -fsSL "$1" -o "$2.tmp" && head -1 "$2.tmp" | grep -q '^#!' && sh -n "$2.tmp" 2>/dev/null; then
        mv "$2.tmp" "$2" && chmod +x "$2" && return 0
    fi
    rm -f "$2.tmp"; return 1
}
mkdir -p "$PREFIX/share"
fetch "$RAW_BASE/kn-info.sh" "$LOCAL" || { echo "[!] Не скачался $RAW_BASE/kn-info.sh"; exit 1; }
echo "[ok] $LOCAL"

# --- Обёртка kss ---
cat > "$BIN" << 'KSSWRAP'
#!/bin/sh
# kss — сводка роутера Keenetic (kn-info). kss -h — справка.
RAW_URL="@RAW@/kn-info.sh"
PREFIX="@PREFIX@"
LOCAL="$PREFIX/share/kn-info.sh"

case "$1" in
    update)
        echo "Обновление kss..."
        if curl -fsSL "$RAW_URL" -o "$LOCAL.tmp" && head -1 "$LOCAL.tmp" | grep -q '^#!' \
           && sh -n "$LOCAL.tmp" 2>/dev/null; then
            mv "$LOCAL.tmp" "$LOCAL"; chmod +x "$LOCAL"
            echo "[ok] $(sh "$LOCAL" -v)"
            exit 0
        fi
        rm -f "$LOCAL.tmp"
        echo "[!] Не скачалось или файл битый — оставил прежнюю версию"
        exit 1 ;;
    uninstall|remove)
        # Сначала токен RCI на роутере (5.2+), потом файлы
        [ -f "$LOCAL" ] && sh "$LOCAL" token del >/dev/null 2>&1
        rm -f "$LOCAL" "$PREFIX/etc/kn-info.conf" "$PREFIX/etc/kn-info.token" "$PREFIX/bin/kss"
        echo "[ok] kss удалён"
        exit 0 ;;
esac

[ -f "$LOCAL" ] || { echo "[!] Нет $LOCAL — выполни: kss update"; exit 1; }
exec sh "$LOCAL" "$@"
KSSWRAP
sed -i "s#@RAW@#$RAW_BASE#; s#@PREFIX@#$PREFIX#" "$BIN"
chmod +x "$BIN"

echo ""
echo "[ok] Установлено: kss (подробно: kss -f, справка: kss -h)"
echo ""
sh "$LOCAL"
