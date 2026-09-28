#!/bin/sh
# ============================================================
#  kss — сводка роутера Keenetic / Netcraze
#  Источники: RCI (127.0.0.1:79), /sys, /proc. POSIX sh / busybox ash.
#  KeeneticOS 4.x, 5.0, 5.1, 5.2 (токены RCI) и новее.
#  jq — необязателен: без него JSON разбирает awk, результат тот же.
# ============================================================

KN_INFO_VERSION="3.0.0"

RCI_BASE="${KN_RCI_BASE:-http://127.0.0.1:79/rci}"   # не localhost: ndm слушает только IPv4
CONF_FILE="${KN_CONF_FILE:-/opt/etc/kn-info.conf}"
TOKEN_FILE="${KN_TOKEN_FILE:-/opt/etc/kn-info.token}"
TOKEN_DESC="kss"                       # описание нашего токена в списке роутера
NDMC="${KN_NDMC:-/bin/ndmc}"
DEBUG_DIR="/tmp/kn-info-debug"

# KN_* — только для тестов: подмена RCI, ndmc, /sys и /proc
SYS_ROOT="${KN_SYS_ROOT:-}"
PROC_ROOT="${KN_PROC_ROOT:-}"

# ------------------------------------------------------------
#  Цвета (настоящие ESC: данные печатаются через %s, без разбора «\»)
# ------------------------------------------------------------
ESC=$(printf '\033')
if [ -t 1 ] && [ -z "$NO_COLOR" ]; then
    C0="${ESC}[0m"; CG="${ESC}[1;32m"; CY="${ESC}[1;33m"; CR="${ESC}[1;31m"
    CC="${ESC}[1;36m"; CW="${ESC}[1;37m"; CD="${ESC}[0;90m"
else
    C0=''; CG=''; CY=''; CR=''; CC=''; CW=''; CD=''
fi
say() { printf '%s\n' "$1"; }
isnum() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; return 0; }

# ------------------------------------------------------------
#  JSON → строки «путь=значение» (путь через «|»)
#  jq, если есть; иначе awk. Вывод одинаковый.
# ------------------------------------------------------------
HAVE_JQ=0
command -v jq >/dev/null 2>&1 && HAVE_JQ=1

json_flat() {
    if [ "$HAVE_JQ" = "1" ] && [ -z "$KN_NO_JQ" ]; then
        # Не paths(scalars): тот отбрасывает false и null («internet»: false)
        jq -r 'paths as $p | getpath($p) as $v
               | select(($v | type) != "object" and ($v | type) != "array")
               | ($p | map(tostring) | join("|")) + "="
                 + ($v | tostring | gsub("[\n\r\t]"; " "))' 2>/dev/null
        return
    fi
    # Режем по кавычкам: чётные куски — строки, нечётные — разметка.
    # Посимвольно идёт только разметка без пробелов — это быстро и на MIPS.
    awk 'BEGIN { RS = "\001" }
    function emit(v,   p, k) {
        if (typ[d] == "a") { cur[d] = idx[d]; idx[d]++ }
        p = ""
        for (k = 1; k <= d; k++) p = p (k > 1 ? "|" : "") cur[k]
        print p "=" v
    }
    function open(t) {
        if (d > 0 && typ[d] == "a") { cur[d] = idx[d]; idx[d]++ }
        d++; typ[d] = t; idx[d] = 0; cur[d] = ""; want = (t == "o")
    }
    function markup(s,   i, m, c, j) {
        gsub(/[ \t\r\n]+/, "", s); m = length(s); i = 1
        while (i <= m) {
            c = substr(s, i, 1)
            if (c == "{")                  { open("o"); i++ }
            else if (c == "[")             { open("a"); i++ }
            else if (c == "}" || c == "]") { d--; i++ }
            else if (c == ",")             { if (typ[d] == "o") want = 1; i++ }
            else if (c == ":")             { i++ }
            else {                         # число, true, false, null
                j = i; while (j <= m && index(",}]", substr(s, j, 1)) == 0) j++
                emit(substr(s, i, j - i)); i = j
            }
        }
    }
    function unesc(s,   o, i, c) {         # \" \\ \/ — символ; \n \t \r — пробел; \uXXXX — как есть
        if (index(s, "\\") == 0) return s
        o = ""
        for (i = 1; i <= length(s); i++) {
            c = substr(s, i, 1)
            if (c != "\\") { o = o c; continue }
            c = substr(s, ++i, 1)
            o = o ((c == "n" || c == "t" || c == "r") ? " " : (c == "u") ? "\\u" : c)
        }
        return o
    }
    {
        n = split($0, P, "\""); d = 0; want = 0; k = 1
        while (k <= n) {
            markup(P[k++]); if (k > n) break
            s = P[k++]
            while (k <= n && match(s, /\\+$/) && RLENGTH % 2 == 1) s = s "\"" P[k++]   # \" внутри строки
            s = unesc(s)
            if (typ[d] == "o" && want) { cur[d] = s; want = 0 } else emit(s)
        }
    }'
}

# ------------------------------------------------------------
#  Токен RCI (KeeneticOS 5.2+)
#  С 5.2 запрос к 127.0.0.1:79 без токена пишет в журнал «obsoleted
#  unauthenticated loopback RCI access will be removed soon», позже будет
#  отказ. Токен (заголовок X-NDMA-TKN) выпускаем сами через ndmc — локально,
#  без пароля. Он бессрочный и переживает перезагрузку, но id в списке
#  роутера после неё меняются — свои токены ищем по описанию «kss».
#  До 5.2 у ndmc такой команды нет — ходим без токена.
# ------------------------------------------------------------
ndmc_run() {
    [ -x "$NDMC" ] || return 1
    "$NDMC" -c "$1" 2>&1 | sed "s/${ESC}\\[K//g"      # ndmc печатает ^[[K
}

# Список токенов — пустой или блоки «token:»; ошибка ndmc — токенов нет (до 5.2)
token_supported() {
    out=$(ndmc_run "show authentication token") || return 1
    case "$out" in *"no such command"*|*"not found"*|*"unknown command"*|*Command::*rror*) return 1 ;; esac
    return 0
}

# id токенов с нашим описанием (кроме $1)
token_ids() {
    ndmc_run "show authentication token" | awk -v want="$TOKEN_DESC" -v keep="$1" '
        { sub(/^[ \t]+/, "") }
        /^id:/        { id = $2 }
        /^user-data:/ { v = $0; sub(/^user-data:[ \t]*/, "", v); if (v == want && id != keep) print id }'
}

token_issue() {
    out=$(ndmc_run "authentication token generate $TOKEN_DESC") || return 1
    # «value:» и токен — строкой ниже; ndmc переносит длинное значение:
    # склеиваем строки без «:» до пустой строки или следующего ключа.
    parsed=$(printf '%s\n' "$out" | awk '
        { sub(/^[ \t]+/, ""); sub(/[ \t]+$/, "") }
        in_val && ($0 == "" || /:/) { in_val = 0; done = 1 }
        in_val  { val = val $0; next }
        done    { next }
        /^id:/    { id = $2 }
        /^value:/ { in_val = 1; v = $0; sub(/^value:[ \t]*/, "", v); val = v }
        END { print id " " val }')
    new_id=${parsed%% *}; tok=${parsed#* }
    case "$tok" in *[!A-Za-z0-9]*) tok="" ;; esac
    [ "${#tok}" -ge 32 ] || tok=""
    if [ -z "$tok" ]; then
        # Выпущен, но не разобран — снимаем, иначе каждый запуск оставлял бы
        # на роутере ещё один бессрочный admin-токен
        case "$out" in *"no such command"*) ;; *) token_revoke_router ;; esac
        return 1
    fi
    # Прежние токены kss снимаем, только когда новый уже есть. Без id новый
    # от старых не отличить — тогда снимутся при следующем выпуске.
    [ -n "$new_id" ] && for old in $(token_ids "$new_id"); do ndmc_run "authentication token delete $old" >/dev/null; done
    mkdir -p "${TOKEN_FILE%/*}" 2>/dev/null
    ( umask 077; printf '%s\n' "$tok" > "$TOKEN_FILE" ) 2>/dev/null
    TOKEN="$tok"
    return 0
}

token_revoke_router() {
    for id in $(token_ids ""); do ndmc_run "authentication token delete $id" >/dev/null; done
}
token_revoke() { token_revoke_router; rm -f "$TOKEN_FILE"; TOKEN=""; }

TOKEN=""
TOKEN_STATE="нет"          # нет | есть | не нужен
token_load() {
    [ -n "$KN_NO_TOKEN" ] && { TOKEN_STATE="не нужен"; return; }
    [ -r "$TOKEN_FILE" ] && IFS= read -r TOKEN < "$TOKEN_FILE"
    case "$TOKEN" in *[!A-Za-z0-9]*) TOKEN="" ;; esac
    if [ -z "$TOKEN" ]; then
        token_supported || { TOKEN_STATE="не нужен"; return; }
        token_issue || RCI_RETRIED=1      # не вышло — второй раз в этом запуске не пробуем
    fi
    [ -n "$TOKEN" ] && TOKEN_STATE="есть"
}

# ------------------------------------------------------------
#  RCI
#  rci <endpoint> → тело в $RCI_TMP, RCI_CODE, RCI_DETAIL; 0 — если 200.
#  Перевыпуск токена — один на запуск и только на отказ по токену:
#  X-Detail 0x2312 (не опознан) или 0x1218 (токен обязателен).
#  Прочие 403 — не про токен.
# ------------------------------------------------------------
RCI_TMP="${TMPDIR:-/tmp}/kss.$$"
trap 'rm -f "$RCI_TMP" "$RCI_TMP.hdr"' EXIT
trap 'exit 130' INT TERM
CR_CHAR=$(printf '\r')
RCI_CODE=""; RCI_DETAIL=""; RCI_RETRIED=""

_rci_once() {
    # Заголовок — только с токеном: пустой X-NDMA-TKN роутер счёл бы неверным
    set -- "$RCI_BASE/$1"
    [ -n "$TOKEN" ] && set -- -H "X-NDMA-TKN: $TOKEN" "$@"
    : > "$RCI_TMP"; : > "$RCI_TMP.hdr"
    RCI_CODE=$(curl -s -4 --noproxy '*' --connect-timeout 3 --max-time 8 \
                    -D "$RCI_TMP.hdr" -o "$RCI_TMP" -w '%{http_code}' "$@" 2>/dev/null)
    RCI_DETAIL=""
    while IFS= read -r l; do
        case "$l" in [Xx]-[Dd][Ee][Tt][Aa][Ii][Ll]:*)
            l=${l#*:}; l=${l%"$CR_CHAR"}; RCI_DETAIL=${l# } ;;
        esac
    done < "$RCI_TMP.hdr"
}
rci() {
    _rci_once "$1"
    case "$RCI_CODE" in
        401|403)
            case "$RCI_DETAIL" in
                *0x2312*|*0x1218*|'')
                    if [ -z "$RCI_RETRIED" ]; then
                        RCI_RETRIED=1
                        if token_supported && token_issue; then
                            TOKEN_STATE="есть"; _rci_once "$1"
                        fi
                    fi ;;
            esac ;;
    esac
    [ "$RCI_CODE" = "200" ]
}
# rflat <endpoint> → плоский JSON в RFLAT
rflat() { RFLAT=""; rci "$1" && RFLAT=$(json_flat < "$RCI_TMP"); }

# ------------------------------------------------------------
#  Режим: флаг > переменная окружения > конфиг > компактный
# ------------------------------------------------------------
STYLE="compact"
[ -r "$CONF_FILE" ] && while IFS='=' read -r k v; do
    case "$k" in
        \#*) ;;
        *KN_INFO_STYLE*) case "$v" in *full*) STYLE="full" ;; *compact*) STYLE="compact" ;; esac ;;
    esac
done < "$CONF_FILE"
case "$KN_INFO_STYLE" in full|compact) STYLE="$KN_INFO_STYLE" ;; esac
case "$1" in
    -c|--compact|compact) STYLE="compact"; shift ;;
    -f|--full|full)       STYLE="full";    shift ;;
esac

case "$1" in
    -v|--version) echo "kss $KN_INFO_VERSION"; exit 0 ;;
    -h|--help)
        cat <<EOF
kss $KN_INFO_VERSION — сводка роутера Keenetic

  kss            компактно (по умолчанию)
  kss -f         подробно
  kss token      статус токена RCI (KeeneticOS 5.2+)
  kss token new  выпустить токен заново
  kss token del  отозвать токен kss на роутере
  kss debug      сырые ответы RCI и /sys в $DEBUG_DIR
  kss update     обновить скрипт
  kss uninstall  удалить kss и отозвать токен

  NO_COLOR=1     без цвета
  Вид по умолчанию: echo 'KN_INFO_STYLE=full' > $CONF_FILE
EOF
        exit 0 ;;
    token)
        case "$2" in
            new) token_supported || { echo "Прошивка без токенов RCI (до 5.2) — не нужен"; exit 0; }
                 if token_issue; then echo "Токен выпущен: $TOKEN_FILE"; exit 0; fi
                 echo "Не удалось выпустить токен"; exit 1 ;;
            del) token_revoke; echo "Токены «$TOKEN_DESC» отозваны, $TOKEN_FILE удалён"; exit 0 ;;
        esac
        if ! token_supported; then echo "Токены RCI: не нужны (прошивка до 5.2)"; exit 0; fi
        token_load
        if rci "show/version"; then echo "Токен RCI: работает ($TOKEN_FILE)"
        else echo "Токен RCI: RCI ответил ${RCI_CODE}${RCI_DETAIL:+ ($RCI_DETAIL)} — kss token new"; fi
        n=0; for id in $(token_ids ""); do n=$((n + 1)); done
        echo "Токенов «$TOKEN_DESC» на роутере: $n"
        exit 0 ;;
    debug|--debug)
        command -v curl >/dev/null 2>&1 || { echo "нужен curl: opkg install curl"; exit 1; }
        token_load
        mkdir -p "$DEBUG_DIR"
        for ep in show/version show/system show/interface show/internet/status show/ip/hotspot; do
            f="$DEBUG_DIR/$(echo "$ep" | tr '/' '_').json"
            rci "$ep"; cat "$RCI_TMP" > "$f"
            printf '  %-24s %6s байт  код %s\n' "$ep" "$(wc -c < "$f" | tr -d ' ')" "$RCI_CODE"
        done
        {
            echo "== kss $KN_INFO_VERSION, токен: $TOKEN_STATE, jq: $HAVE_JQ"
            echo "== uname"; uname -a
            echo "== thermal"
            for z in "$SYS_ROOT"/sys/class/thermal/thermal_zone*; do
                [ -d "$z" ] && echo "$z $(cat "$z/type" 2>/dev/null) $(cat "$z/temp" 2>/dev/null)"
            done
            echo "== hwmon"
            for h in "$SYS_ROOT"/sys/class/hwmon/hwmon*; do
                [ -d "$h" ] && echo "$h $(cat "$h/name" 2>/dev/null) $(cat "$h"/temp*_input 2>/dev/null | tr '\n' ' ')"
            done
            echo "== device-tree"; tr '\000' ' ' < "$PROC_ROOT/proc/device-tree/compatible"; echo
            echo "== cpuinfo"; cat "$PROC_ROOT/proc/cpuinfo"
            echo "== meminfo"; cat "$PROC_ROOT/proc/meminfo"
            echo "== mounts"; cat "$PROC_ROOT/proc/mounts"
            echo "== opkg arch"; opkg print-architecture
        } > "$DEBUG_DIR/system.txt" 2>/dev/null
        echo "Готово: $DEBUG_DIR (токена в файлах нет)"
        exit 0 ;;
esac

# ------------------------------------------------------------
#  Сбор
# ------------------------------------------------------------
command -v curl >/dev/null 2>&1 || { say "${CR}[!] нужен curl: opkg install curl${C0}"; exit 1; }
token_load

rflat show/version; VER="$RFLAT"
if [ -z "$VER" ]; then
    [ "$RCI_CODE" = "000" ] && RCI_CODE=""
    say "${CR}[!] RCI не отвечает: $RCI_BASE, код ${RCI_CODE:-нет ответа}${RCI_DETAIL:+ ($RCI_DETAIL)}${C0}"
    case "$RCI_CODE:$RCI_DETAIL" in
        401:*|403:|403:*0x2312*|403:*0x1218*)
                 echo "    Нужен токен RCI (KeeneticOS 5.2+): kss token new" ;;
        403:*)   ;;    # отказ не по токену — причина в скобках выше
        *)       echo "    Проверь: id -u (0?) · env | grep -i proxy · curl -s $RCI_BASE/show/version" ;;
    esac
    exit 1
fi
rflat show/system;          SYS="$RFLAT"
rflat show/interface;       IF="$RFLAT"
rflat show/internet/status; NET="$RFLAT"
rflat show/ip/hotspot;      HOT="$RFLAT"

# ── Версия, система, интернет: нужные поля одним проходом, без форков ──
V_DEVICE=""; V_MODEL=""; V_DESC=""; HWID=""; REGION=""; TITLE=""; RELEASE=""; SANDBOX=""
V_ARCH=""; BUILD=""; COMP=""; FEAT=""; COMP0=""; FEAT0=""
while IFS='=' read -r k v; do
    case "$k" in
        device) V_DEVICE=$v ;;  model) V_MODEL=$v ;;      description) V_DESC=$v ;;
        hw_id) HWID=$v ;;       region) REGION=$v ;;      title) TITLE=$v ;;
        release) RELEASE=$v ;;  sandbox) SANDBOX=$v ;;    arch) V_ARCH=$v ;;
        'ndm|cdate') BUILD=$v ;;
        'ndw|components') COMP=$v ;;  components) COMP0=$v ;;   # старые прошивки —
        'ndw|features')   FEAT=$v ;;  features)   FEAT0=$v ;;   # на верхнем уровне
    esac
done <<EOF
$VER
EOF
[ -z "$COMP" ] && COMP=$COMP0
[ -z "$FEAT" ] && FEAT=$FEAT0

S_LOAD=""; S_MEM=""; S_SWAP=""; S_MT=""; S_MF=""; S_MB=""; S_MC=""; S_UP=""; S_CT=""; S_CF=""
while IFS='=' read -r k v; do
    case "$k" in
        cpuload) S_LOAD=$v ;;   memory) S_MEM=$v ;;       swap) S_SWAP=$v ;;       uptime) S_UP=$v ;;
        memtotal) S_MT=$v ;;    memfree) S_MF=$v ;;       membuffers) S_MB=$v ;;   memcache) S_MC=$v ;;
        conntotal) S_CT=$v ;;   connfree) S_CF=$v ;;
    esac
done <<EOF
$SYS
EOF

N_INET=""; GW_IF=""
while IFS='=' read -r k v; do
    case "$k" in internet) N_INET=$v ;; 'gateway|interface') GW_IF=$v ;; esac
done <<EOF
$NET
EOF

# ── Устройство и прошивка ──
MODEL=${V_DEVICE:-${V_MODEL:-${V_DESC:-неизвестно}}}
case "$MODEL" in *"$HWID"*) ;; *) MODEL="$MODEL ($HWID)" ;; esac

PORT_FLAG=""
case "$MODEL" in
    *Cudy*|*WBR3000*|*TR3000*|*WR3000*|*CMCC*|*RAX3000M*|*Netis*|*NX31*|*NX32*|*Redmi*|*Xiaomi*|\
    *AX3000T*|*Mercusys*|*SmartBox*|*TP-Link*|*EC330*|*Archer*|*Linksys*|*WiFire*|*Vertell*|*MTS*|\
    *WG430*|*HLK*) PORT_FLAG=" [Port]" ;;
esac

BOOT_SLOT=""
[ -r "$PROC_ROOT/proc/dual_image/boot_current" ] && read -r BOOT_SLOT < "$PROC_ROOT/proc/dual_image/boot_current"
isnum "$BOOT_SLOT" || BOOT_SLOT=""

# ── CPU ──
ARCH=""                         # opkg.conf различает mips и mipsel, RCI — нет
[ -r /opt/etc/opkg.conf ] && while read -r k a _; do
    [ "$k" = "arch" ] || continue
    case "$a" in aarch64*) ARCH="aarch64" ;; mipsel*) ARCH="mipsel" ;; mips*) ARCH="mips" ;; esac
done < /opt/etc/opkg.conf
[ -z "$ARCH" ] && ARCH=$V_ARCH
[ -z "$ARCH" ] && ARCH=$(uname -m 2>/dev/null)

SOC_RE='MT7[0-9]{3}[0-9A-Za-z]*|MT[0-9]{4}[0-9A-Za-z]*|EN75[0-9A-Za-z]*|IPQ[0-9]{4}|RTL[0-9]{4}'
SOC=""
for lib in /lib/libndmMwsController.so /lib/libndmMws.so /lib/libndmCore.so; do
    [ -r "$lib" ] || continue
    SOC=$(grep -m1 -aoE "$SOC_RE" "$lib" 2>/dev/null | head -n1); [ -n "$SOC" ] && break
done
# /proc/cpuinfo: ядра, SoC (MIPS — «system type», ARMv7 — «Hardware»), ядро ARM
CPUI=$(awk -F: '
    /^processor/                             { n++ }
    /^(system type|Hardware)/ && soc == ""   { soc = substr($0, index($0, ":") + 1); sub(/^[ \t]+/, "", soc); sub(/ ver:.*/, "", soc) }
    /^CPU part/ && part == ""                { part = $2; gsub(/[ \t]/, "", part) }
    END { print n + 0 "|" part "|" soc }' "$PROC_ROOT/proc/cpuinfo" 2>/dev/null)
CORES=${CPUI%%|*}; CPUI=${CPUI#*|}; CPU_PART=${CPUI%%|*}
[ -z "$SOC" ] && SOC=${CPUI#*|}
if [ -z "$SOC" ] && [ -r "$PROC_ROOT/proc/device-tree/compatible" ]; then
    # последняя запись — SoC: «mediatek,mt7622» → MT7622
    SOC=$(tr '\000' '\n' < "$PROC_ROOT/proc/device-tree/compatible" | awk 'NF { s = $0 } END { sub(/^[^,]*,/, "", s); sub(/-soc$/, "", s); print toupper(s) }')
fi
if [ -z "$SOC" ]; then
    case "$CPU_PART" in
        0xd03) SOC="Cortex-A53" ;; 0xd04) SOC="Cortex-A35" ;; 0xd05) SOC="Cortex-A55" ;;
        0xd07) SOC="Cortex-A57" ;; 0xd08) SOC="Cortex-A72" ;; 0xd09) SOC="Cortex-A73" ;;
        0xd0b) SOC="Cortex-A76" ;; 0xc07) SOC="Cortex-A7" ;;  0xc09) SOC="Cortex-A9" ;;
    esac
fi
[ "$CORES" = "0" ] && CORES=""
FREQ=""
f="$SYS_ROOT/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq"
if [ -r "$f" ] && read -r f < "$f" && isnum "$f" && [ "$f" -gt 0 ]; then FREQ="$((f / 1000)) MHz"; fi
LOADAVG=""
[ -r "$PROC_ROOT/proc/loadavg" ] && read -r l1 l2 l3 _ < "$PROC_ROOT/proc/loadavg" && LOADAVG="$l1 $l2 $l3"

# ── Память, аптайм, соединения ──
MEM_U=""; MEM_T=""
case "$S_MEM" in */*) MEM_U=${S_MEM%%/*}; MEM_T=${S_MEM#*/} ;; esac     # «занято/всего» в КБ
if ! isnum "$MEM_U" || ! isnum "$MEM_T"; then
    MEM_U=""; MEM_T=""
    if isnum "$S_MT" && isnum "$S_MF"; then       # те же цифры из отдельных полей
        isnum "$S_MB" || S_MB=0; isnum "$S_MC" || S_MC=0
        MEM_T=$S_MT; MEM_U=$((S_MT - S_MF - S_MB - S_MC))
    elif [ -r "$PROC_ROOT/proc/meminfo" ]; then
        ma=""
        while read -r k v _; do
            case "$k" in MemTotal:) MEM_T=$v ;; MemAvailable:) ma=$v ;; esac
        done < "$PROC_ROOT/proc/meminfo"
        isnum "$MEM_T" && isnum "$ma" && MEM_U=$((MEM_T - ma))
    fi
fi
MEM_STR=""
if isnum "$MEM_U" && isnum "$MEM_T" && [ "$MEM_T" -gt 0 ]; then
    MEM_STR="$((MEM_U / 1024)) / $((MEM_T / 1024)) MB ($((MEM_U * 100 / MEM_T))%)"
fi
SWAP_STR=""
case "$S_SWAP" in */*)
    sw_u=${S_SWAP%%/*}; sw_t=${S_SWAP#*/}
    isnum "$sw_u" && isnum "$sw_t" && [ "$sw_t" -gt 0 ] && SWAP_STR="swap $((sw_u / 1024)) / $((sw_t / 1024)) MB" ;;
esac

UP=${S_UP%%.*}
if ! isnum "$UP"; then
    UP=""; [ -r "$PROC_ROOT/proc/uptime" ] && read -r UP _ < "$PROC_ROOT/proc/uptime"; UP=${UP%%.*}
fi
UP_STR=""
if isnum "$UP"; then
    d=$((UP / 86400)); h=$(((UP % 86400) / 3600)); m=$(((UP % 3600) / 60)); s=$((UP % 60))
    if [ "$d" -gt 0 ]; then UP_STR=$(printf '%d дн. %02d:%02d:%02d' "$d" "$h" "$m" "$s")
    else UP_STR=$(printf '%02d:%02d:%02d' "$h" "$m" "$s"); fi
fi
CONN=""
isnum "$S_CT" && isnum "$S_CF" && CONN="$((S_CT - S_CF)) / $S_CT"

# ── Интерфейсы: один проход awk ──
# R band канал ширина состояние — радио     T/TW метка °C — температура из RCI
# U метка скорость / D метка — порты        G адрес описание — шлюз по умолчанию
# N адрес описание — интерфейс из internet/status   M сигнал rsrp sinr — модем
IFROWS=$(printf '%s\n' "$IF" | awk -v gwif="$GW_IF" '
    {
        p = index($0, "="); if (p == 0) next
        path = substr($0, 1, p - 1); val = substr($0, p + 1)
        n = split(path, a, "|"); nm = a[1]
        if (!(nm in seen)) { seen[nm] = 1; ord[++cnt] = nm }
        if (n == 2) f[nm, a[2]] = val
        else if (n == 3 && a[2] == "traits") trt[nm] = trt[nm] " " val " "
        else if (n == 3 && a[2] == "mobile") fm[nm, a[3]] = val      # вложенный вид у части прошивок
    }
    function g(nm, k) { return ((nm, k) in f) ? f[nm, k] : "" }
    function gm(nm, k) { return ((nm, k) in f) ? f[nm, k] : ((nm, k) in fm) ? fm[nm, k] : "" }
    function isn(v) { return v ~ /^-?[0-9]+(\.[0-9]+)?$/ }
    function nz(v) { return (v == "") ? "-" : v }
    function band(nm,   ch, ix) {
        ch = g(nm, "channel") + 0; ix = g(nm, "index") + 0
        if (ch > 0 && ch <= 14 && ix == 0) return "2.4G"
        if (ix >= 2) return (trt[nm] ~ /6[Gg]/) ? "6G" : "5G-2"   # третье радио
        if (ch > 14) return "5G"
        return (ix == 0) ? "2.4G" : "5G"
    }
    END {
        for (i = 1; i <= cnt; i++) {
            nm = ord[i]; ty = g(nm, "type"); t = gm(nm, "temperature")
            mob = (ty ~ /Lte|Qmi|UsbModem|Mobile/ || trt[nm] ~ / (UsbLte|Mobile) /)
            if (ty == "WifiMaster") {
                b = band(nm)
                print "R", b, nz(g(nm, "channel")), nz(g(nm, "bandwidth")), nz(g(nm, "hwstate"))
                if (isn(t)) print "TW", b, int(t)
            } else if (isn(t)) print "T", (mob ? "LTE" : nm), int(t)
            if (mob) {
                sn = gm(nm, "sinr"); if (sn == "") sn = gm(nm, "snr"); if (sn == "") sn = gm(nm, "cinr")
                sl = gm(nm, "signal-level"); rp = gm(nm, "rsrp")
                if (sl != "" || rp != "" || sn != "") print "M", nz(sl), nz(rp), nz(sn)
            }
            if (ty == "Port") {
                lb = g(nm, "label"); if (lb == "") lb = nm
                if (g(nm, "link") == "up") print "U", lb, nz(g(nm, "speed")); else print "D", lb
            }
            ad = g(nm, "address"); ds = g(nm, "description"); if (ds == "") ds = nm
            if (ad != "" && g(nm, "defaultgw") == "true" && !gw) { gw = 1; print "G", ad, ds }
            if (ad != "" && nm == gwif) print "N", ad, ds
        }
    }')

WIFI_LINE=""; P_UP=""; P_DN=""; RCI_TEMPS=""; WIFI_RCI=0; LTE_LINE=""
WAN_IP=""; WAN_IF=""; GWN_IP=""; GWN_IF=""
while read -r tag a b c d; do
    case "$tag" in
        R)  if [ "$d" = "off" ] || [ "$b" = "-" ]; then part="$a ${CD}выкл${C0}"
            else
                part="$a к$b"
                if isnum "$c"; then part="$part/${c}МГц"; elif [ "$c" != "-" ]; then part="$part/$c"; fi
            fi
            WIFI_LINE="${WIFI_LINE:+$WIFI_LINE  }$part" ;;
        TW) RCI_TEMPS="$RCI_TEMPS $a=$b"; WIFI_RCI=1 ;;
        T)  RCI_TEMPS="$RCI_TEMPS $a=$b" ;;
        M)  [ -n "$LTE_LINE" ] && continue
            [ "$a" != "-" ] && LTE_LINE="сигнал $a/5"
            [ "$b" != "-" ] && LTE_LINE="${LTE_LINE:+$LTE_LINE  }RSRP $b"
            [ "$c" != "-" ] && LTE_LINE="${LTE_LINE:+$LTE_LINE  }SINR $c" ;;
        U)  case "$b" in 10000) b="10G" ;; 5000) b="5G" ;; 2500) b="2.5G" ;; 1000) b="1G" ;;
                         -) b="" ;; *[!0-9]*) ;; *) b="${b}M" ;; esac
            P_UP="${P_UP:+$P_UP }$a${b:+:$b}" ;;
        D)  P_DN="${P_DN:+$P_DN,}$a" ;;
        G)  WAN_IP=$a; WAN_IF="$b${c:+ $c}${d:+ $d}" ;;
        N)  GWN_IP=$a; GWN_IF="$b${c:+ $c}${d:+ $d}" ;;
    esac
done <<EOF
$IFROWS
EOF
[ -z "$WAN_IP" ] && { WAN_IP=$GWN_IP; WAN_IF=$GWN_IF; }
PORT_LINE=""
[ -n "$P_UP" ] && PORT_LINE="${CG}▲${C0} $P_UP"
[ -n "$P_DN" ] && PORT_LINE="${PORT_LINE:+$PORT_LINE  }${CD}▼ $P_DN${C0}"

case "$N_INET" in
    true)  INET="${CG}● онлайн${C0}" ;;
    false) INET="${CR}● нет интернета${C0}" ;;
    *)     INET="${CY}● ?${C0}" ;;
esac

# ── Клиенты: хосты верхнего уровня и активные из них ──
CL=$(printf '%s\n' "$HOT" | awk '/^(host[|])?[0-9]+[|]mac=/ { a++ } /^(host[|])?[0-9]+[|]active=true$/ { o++ } END { print a + 0, o + 0 }')
CL_ALL=${CL% *}; CL_ON=${CL#* }

# ── Температуры: зоны ядра, радио и модем из RCI, hwmon — одной строкой ──
# Цвет: <55 зелёный, 55–69 жёлтый, ≥70 красный. Строка переносится по
# ширине терминала, продолжение — под значением (отступ = ширина метки).
if [ "$STYLE" = "full" ]; then LBL_W=12; else LBL_W=9; fi
COLS=""
[ -t 1 ] && COLS=$(stty size 2>/dev/null < /dev/tty) && COLS=${COLS#* }
isnum "$COLS" || COLS=${COLUMNS:-80}
isnum "$COLS" || COLS=80
[ "$COLS" -ge 40 ] || COLS=80          # pty без размера отдаёт 0
TEMP_LINE=$(awk -v rci="$RCI_TEMPS" -v wifi="$WIFI_RCI" -v w="$((COLS - LBL_W))" -v lw="$LBL_W" \
                -v g="$CG" -v y="$CY" -v r="$CR" -v z="$C0" '
    function rd(f,   l) { l = ""; if ((getline l < f) <= 0) l = ""; close(f); return l }
    function add(lbl, v,   c, len) {
        if (v !~ /^-?[0-9]+(\.[0-9]+)?$/) return
        v = int(v); if (v > 1000) v = int(v / 1000)          # миллиградусы
        if (v <= 0 || v >= 150) return
        c = (v >= 70) ? r : (v >= 55) ? y : g
        len = length(lbl) + length(v) + 2
        if (cur > 0 && cur + 2 + len > w) { out = out "\n" sprintf("%" lw "s", ""); cur = 0 }
        else if (cur > 0) { out = out "  "; cur += 2 }
        out = out lbl " " c v "°" z; cur += len
    }
    BEGIN {
        for (i = 1; i < ARGC; i++) {                 # 1) зоны ядра: cpu-thermal → CPU, ddr-thermal → DDR
            dd = ARGV[i]; if (dd !~ /thermal_zone[0-9]+$/) continue
            t = rd(dd "/temp"); if (t == "") continue
            ty = rd(dd "/type"); k = ty; gsub(/-/, "_", k); seen[k] = 1
            if (ty ~ /cpu|soc|tsens/ || ty ~ /^thermal/ || ty == "") { cpu++; lbl = (cpu > 1) ? "CPU" cpu : "CPU" }
            else { lbl = ty; sub(/[-_]thermal$/, "", lbl); lbl = toupper(lbl) }
            add(lbl, t)
        }
        n = split(rci, a, " ")                       # 2) радио, модем и прочее из RCI
        for (i = 1; i <= n; i++) if ((p = index(a[i], "=")) > 0) add(substr(a[i], 1, p - 1), substr(a[i], p + 1))
        for (i = 1; i < ARGC; i++) {                 # 3) hwmon: по датчику на устройство
            dd = ARGV[i]; if (dd !~ /hwmon[0-9]+$/) continue
            nm = rd(dd "/name"); if (nm in seen) continue   # дубль зоны ядра
            t = ""; for (j = 1; j <= 8 && t == ""; j++) t = rd(dd "/temp" j "_input")
            if (t == "") continue
            if (nm ~ /^nvme/)           lbl = "NVMe"
            else if (nm ~ /^drivetemp/) lbl = "Диск"
            else if (nm ~ /sfp/)        lbl = "SFP"
            else if (nm ~ /^mt7|phy/) { if (wifi) continue; lbl = "Wi-Fi" }
            else if (nm ~ /cpu|soc/)  { if (cpu) continue; lbl = "CPU" }
            else lbl = nm
            add(lbl, t)
        }
        print out
        exit
    }' "$SYS_ROOT"/sys/class/thermal/thermal_zone* "$SYS_ROOT"/sys/class/hwmon/hwmon*)

# ── Накопители: разделы USB/NVMe/SD, подпись — имя точки монтирования ──
DISK_LINE=""
while IFS= read -r mnt; do
    [ -n "$mnt" ] || continue
    dl=$(df -Ph "$mnt" 2>/dev/null | awk -v n="${mnt##*/}" 'NR == 2 { print n " " $3 "/" $2 " (" $5 ")" }')
    [ -n "$dl" ] && DISK_LINE="${DISK_LINE:+$DISK_LINE  }$dl"
done <<EOF
$(awk '$1 ~ /^\/dev\/(sd|nvme|mmcblk|ub)/ && $2 ~ /\/(tmp|run|opt)\/mnt\/|\/storage/ {
          gsub(/\\040/, " ", $2); print $2 }' "$PROC_ROOT/proc/mounts" 2>/dev/null)
EOF

# ── Компоненты (подробный вид) ──
has() { case ",$1," in *",$2,"*) return 0 ;; esac; return 1; }
pick() { src="$1"; shift; out=""; while [ $# -ge 2 ]; do has "$src" "$1" && out="${out:+$out }$2"; shift 2; done; PICK=$out; }
pick "$COMP" wireguard WireGuard openvpn OpenVPN ipsec IPsec l2tp L2TP sstp SSTP pptp PPTP zerotier ZeroTier; VPN=$PICK
pick "$COMP" ntfs NTFS exfat exFAT ext EXT hfsplus HFS+ tsmb SMB ftp FTP webdav WebDAV;                    FSC=$PICK
pick "$FEAT" hwnat HW-NAT wifi6_5ghz Wi-Fi6 wifi7 Wi-Fi7 wpa3 WPA3 link_agg LAG dual_image 2×прошивка;      FTR=$PICK

# ------------------------------------------------------------
#  Вывод
# ------------------------------------------------------------
# Метки выровнены литералами: printf %-Ns считает байты, кириллица — по два.
row() { [ -n "$2" ] && say "${CC}$1${C0}$2"; }
dot=" ${CD}·${C0} "
jn() { J=""; for p in "$@"; do [ -n "$p" ] && J="${J:+$J$dot}$p"; done; }   # склейка через « · » в $J

jn "${CW}${TITLE:-н/д}${C0}${SANDBOX:+ $SANDBOX}" "$RELEASE" "$BUILD" "${BOOT_SLOT:+слот $BOOT_SLOT}"; FW=$J
jn "$SOC" "$ARCH${CORES:+ ×$CORES}" "${S_LOAD:+${S_LOAD}%}" "$FREQ";                                   CPU=$J
jn "$INET" "${WAN_IP:+$WAN_IP}${WAN_IF:+ ${CD}($WAN_IF)${C0}}";                                        NETL=$J
if [ "$STYLE" = "full" ]; then CL_STR="${CW}${CL_ON}${C0} онлайн / ${CL_ALL} всего"
else CL_STR="${CW}${CL_ON}${C0} / ${CL_ALL}"; fi
jn "$CL_STR" "${CONN:+соединений $CONN}";                                                               CLI=$J

if [ "$STYLE" = "full" ]; then
    say "${CC}kss${C0} ${CD}v$KN_INFO_VERSION${C0}"
    row "Модель      " "${CW}${MODEL}${C0}${CR}${PORT_FLAG}${C0}${REGION:+  $REGION}"
    row "Прошивка    " "$FW"
    row "Процессор   " "$CPU"
    row "Load avg    " "$LOADAVG"
    row "Температура " "${TEMP_LINE:-${CD}датчики недоступны${C0}}"
    jn "$MEM_STR" "$SWAP_STR"
    row "ОЗУ         " "$J"
    row "Накопители  " "$DISK_LINE"
    row "Wi-Fi       " "$WIFI_LINE"
    row "LTE         " "$LTE_LINE"
    row "Порты       " "$PORT_LINE"
    row "Интернет    " "$NETL"
    row "Клиенты     " "$CLI"
    row "Аптайм      " "$UP_STR"
    row "VPN         " "$VPN"
    row "ФС и сеть   " "$FSC"
    row "Возможности " "$FTR"
    case "$TOKEN_STATE" in
        есть) row "RCI         " "токен ✓" ;;
        нет)  row "RCI         " "${CY}без токена${C0} ${CD}(kss token new)${C0}" ;;
    esac
else
    row "Модель   " "${CW}${MODEL}${C0}${CR}${PORT_FLAG}${C0}"
    row "Прошивка " "$FW"
    row "CPU      " "$CPU"
    row "Темп.    " "$TEMP_LINE"
    row "ОЗУ      " "$MEM_STR"
    row "Диск     " "$DISK_LINE"
    row "Wi-Fi    " "$WIFI_LINE"
    row "LTE      " "$LTE_LINE"
    row "Порты    " "$PORT_LINE"
    row "Сеть     " "$NETL"
    row "Клиенты  " "$CLI"
    row "Аптайм   " "$UP_STR"
fi
exit 0
