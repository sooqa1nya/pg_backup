#!/usr/bin/env bash
# pg-backup.sh — Резервное копирование и восстановление PostgreSQL (Docker) с отправкой в Telegram
# Использование: pg-backup [backup|restore|update|pause|resume|status|uninstall]

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

VERSION="1.4.3"
SCRIPT_REPO_URL="https://raw.githubusercontent.com/sooqa1nya/pg_backup/master/pg-backup.sh"

INSTALL_DIR="/opt/pg-backup-tg"
SCRIPT_NAME="pg-backup.sh"
SCRIPT_PATH="${INSTALL_DIR}/${SCRIPT_NAME}"
CONFIG_FILE="${INSTALL_DIR}/config.env"
BACKUP_DIR="${INSTALL_DIR}/backups"
LOG_DIR="${INSTALL_DIR}/logs"
LAST_BACKUP_FILE="${INSTALL_DIR}/.last_backup"
RUN_LOCK_FILE="${INSTALL_DIR}/.run.lock"
SYMLINK_PATH="/usr/local/bin/pg-backup"
SERVICE_NAME="pg-backup-telegram"
LOG_MAX_BYTES=5242880
LOG_CATEGORY="system"
SCRIPT_RUN_PATH="$(readlink -f "$0")"

# Значения по умолчанию
TELEGRAM_BOT_TOKEN=""
TELEGRAM_CHAT_ID=""
DOCKER_CONTAINER="postgres"
DB_USER="postgres"
DB_NAME="postgres"
SCHEDULE_MODE="time"      # time | interval | off
SCHEDULE_TIMES="03:00"    # время через пробел, например: 03:00 15:00
SCHEDULE_HOURS="24"       # интервал в часах
SCHEDULE_PAUSED="false"
LOCAL_RETAIN_DAYS="7"     # сколько дней хранить бэкапы на сервере (0 — удалять сразу после отправки)

# ============== ЦВЕТА И TUI ==============
if [[ -t 0 && -t 1 ]]; then
    RED=$'\e[31m'
    GREEN=$'\e[32m'
    YELLOW=$'\e[33m'
    GRAY=$'\e[37m'
    LIGHT_GRAY=$'\e[90m'
    CYAN=$'\e[36m'
    RESET=$'\e[0m'
    BOLD=$'\e[1m'
    UI_SEL_BG=$'\e[48;5;22m\e[97m'
else
    RED=""; GREEN=""; YELLOW=""; GRAY=""; LIGHT_GRAY=""; CYAN=""; RESET=""; BOLD=""; UI_SEL_BG=""
fi

_ui_interactive() {
    [[ -t 0 && -t 1 && "${TERM:-dumb}" != "dumb" ]]
}

_UI_SPIN_PID=""
_UI_SPIN_T0=0
_UI_SPIN_ON=0
UI_LAST_ELAPSED=""

ui_spin_start() {
    local msg="$1"
    ui_spin_stop
    _UI_SPIN_T0=$SECONDS
    _UI_SPIN_ON=1
    log_write "INFO" "$msg"
    if ! _ui_interactive; then
        echo -e "${GRAY}[INFO]${RESET} $msg"
        return 0
    fi
    (
        local frames=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏) i=0 t0=$SECONDS
        while true; do
            printf '\r\e[2K%s%s%s %s %s%dс%s' "$CYAN" "${frames[i]}" "$RESET" "$msg" "$LIGHT_GRAY" $((SECONDS - t0)) "$RESET"
            i=$(( (i + 1) % 10 ))
            sleep 0.1
        done
    ) &
    _UI_SPIN_PID=$!
    printf '\e[?25l'
}

ui_spin_stop() {
    if [[ -n "$_UI_SPIN_PID" ]]; then
        kill "$_UI_SPIN_PID" 2>/dev/null || true
        wait "$_UI_SPIN_PID" 2>/dev/null || true
        _UI_SPIN_PID=""
        printf '\r\e[2K\e[?25h'
    fi
    if [[ "$_UI_SPIN_ON" == "1" ]]; then
        UI_LAST_ELAPSED=$(( SECONDS - _UI_SPIN_T0 ))
        _UI_SPIN_ON=0
    fi
}

trap 'ui_spin_stop; if [[ -t 0 ]]; then stty echo 2>/dev/null; printf "\e[?25h"; fi' EXIT

# ============== ЛОГИРОВАНИЕ ==============
_LOG_ROTATED=false

_log_rotate() {
    local f
    for f in backup restore error system; do
        if [[ -f "${LOG_DIR}/${f}.log" && $(stat -c %s "${LOG_DIR}/${f}.log" 2>/dev/null || echo 0) -gt $LOG_MAX_BYTES ]]; then
            mv -f "${LOG_DIR}/${f}.log" "${LOG_DIR}/${f}.log.1" 2>/dev/null || true
        fi
    done
}

log_write() {
    local level="$1"
    local message="$2"
    (
        umask 077
        [[ -d "$INSTALL_DIR" ]] || exit 0
        mkdir -p "$LOG_DIR" 2>/dev/null || exit 0
        chmod 700 "$LOG_DIR" 2>/dev/null || true
        [[ "$_LOG_ROTATED" != "true" ]] && _log_rotate
        local clean
        clean=$(printf '%s' "$message" | sed -e $'s/\x1b\\[[0-9;]*m//g' -e 's/bot[0-9]\{6,\}:[A-Za-z0-9_-]\{20,\}/bot***/g' | tr '\n' ' ')
        echo "$(date '+%Y-%m-%d %H:%M:%S') [${level}] ${clean}" >> "${LOG_DIR}/${LOG_CATEGORY}.log"
        if [[ "$level" == "ERROR" || "$level" == "WARN" ]]; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') [${level}] [${LOG_CATEGORY}] ${clean}" >> "${LOG_DIR}/error.log"
        fi
    ) 2>/dev/null || true
    _LOG_ROTATED=true
}

print_message() {
    local type="$1"
    local message="$2"
    local color_code="$RESET"
    case "$type" in
        INFO)    color_code="$GRAY" ;;
        SUCCESS) color_code="$GREEN" ;;
        WARN)    color_code="$YELLOW" ;;
        ERROR)   color_code="$RED" ;;
        ACTION)  color_code="$CYAN" ;;
        *)       type="INFO" ;;
    esac
    [[ "$_UI_SPIN_ON" == "1" ]] && ui_spin_stop
    if [[ -n "$UI_LAST_ELAPSED" ]]; then
        if [[ "$type" == "SUCCESS" && "$UI_LAST_ELAPSED" -ge 2 ]]; then
            message="${message} ${LIGHT_GRAY}· ${UI_LAST_ELAPSED}с${RESET}"
        fi
        UI_LAST_ELAPSED=""
    fi
    echo -e "${color_code}[${type}]${RESET} ${message}"
    log_write "$type" "$message"
}

# ============== КОМПОНЕНТЫ TUI ==============
_UI_MENU_KEYS=()
_UI_MENU_LABELS=()
_UI_MENU_STYLES=()
_UI_MENU_FOOTER=()
_UI_MENU_WINDOWED=0
_UI_MENU_TYPED=""
_UI_MENU_WARN=""
_UI_MENU_KW=1
_UI_MENU_DRAWN=0

ui_menu_reset() {
    _UI_MENU_KEYS=()
    _UI_MENU_LABELS=()
    _UI_MENU_STYLES=()
    _UI_MENU_FOOTER=()
}

ui_menu_add() {
    _UI_MENU_KEYS+=("$1")
    _UI_MENU_LABELS+=("$2")
    _UI_MENU_STYLES+=("${3:-}")
}

ui_menu_gap() {
    _UI_MENU_KEYS+=("")
    _UI_MENU_LABELS+=("")
    _UI_MENU_STYLES+=("gap")
}

ui_menu_footer() {
    _UI_MENU_FOOTER+=("$1")
}

_ui_menu_style() {
    case "$1" in
        primary) printf '%s' "${GREEN}${BOLD}" ;;
        warn)    printf '%s' "$YELLOW" ;;
        danger)  printf '%s' "$RED" ;;
        *)       printf '' ;;
    esac
}

_ui_menu_draw() {
    local sel="$1" first="$2" last="$3" final="${4:-0}" total="${#_UI_MENU_KEYS[@]}" i st lines=0 f
    if (( first > 0 )); then
        printf '\r\e[2K   %s↑ выше%s\n' "$LIGHT_GRAY" "$RESET"; lines=$((lines + 1))
    elif (( last < total - 1 || _UI_MENU_WINDOWED )); then
        printf '\r\e[2K\n'; lines=$((lines + 1))
    fi
    for ((i = first; i <= last; i++)); do
        if [[ "${_UI_MENU_STYLES[$i]}" == "gap" ]]; then
            printf '\r\e[2K\n'; lines=$((lines + 1)); continue
        fi
        st=$(_ui_menu_style "${_UI_MENU_STYLES[$i]}")
        local num
        num=$(printf '%*s' "$_UI_MENU_KW" "${_UI_MENU_KEYS[$i]}")
        if (( i == sel )); then
            printf '\r\e[2K %s▸%s %s%s %s. %s %s\n' "${GREEN}${BOLD}" "$RESET" "$UI_SEL_BG" "$BOLD" "$num" "${_UI_MENU_LABELS[$i]}" "$RESET"
        else
            printf '\r\e[2K   %s %s. %s %s\n' "$st" "$num" "${_UI_MENU_LABELS[$i]}" "$RESET"
        fi
        lines=$((lines + 1))
    done
    if (( last < total - 1 )); then
        printf '\r\e[2K   %s↓ ниже%s\n' "$LIGHT_GRAY" "$RESET"; lines=$((lines + 1))
    elif (( _UI_MENU_WINDOWED )); then
        printf '\r\e[2K\n'; lines=$((lines + 1))
    fi
    if (( ! final )); then
        local hint="↑/↓ · Enter · 0/Esc назад" hint_color="$LIGHT_GRAY"
        if [[ -n "$_UI_MENU_WARN" ]]; then
            hint="Нет пункта: ${_UI_MENU_WARN}"; hint_color="$YELLOW"
        elif [[ -n "$_UI_MENU_TYPED" ]]; then
            hint="Ввод: ${_UI_MENU_TYPED}"; hint_color="$GREEN"
        fi
        printf '\r\e[2K\n\r\e[2K   %s%s%s\n' "$hint_color" "$hint" "$RESET"
        lines=$((lines + 2))
        for f in "${_UI_MENU_FOOTER[@]}"; do
            printf '\r\e[2K   %s%s%s\n' "$LIGHT_GRAY" "$f" "$RESET"
            lines=$((lines + 1))
        done
    fi
    _UI_MENU_DRAWN=$lines
}

_ui_menu_next() {
    local i="$1" dir="$2" n="${#_UI_MENU_KEYS[@]}" step
    for ((step = 0; step < n; step++)); do
        i=$(( (i + dir + n) % n ))
        [[ "${_UI_MENU_STYLES[$i]}" != "gap" ]] && { echo "$i"; return; }
    done
    echo "$1"
}

_ui_menu_index_of() {
    local i
    for ((i = 0; i < ${#_UI_MENU_KEYS[@]}; i++)); do
        [[ "${_UI_MENU_STYLES[$i]}" != "gap" && "${_UI_MENU_KEYS[$i],,}" == "${1,,}" ]] && { echo "$i"; return 0; }
    done
    return 1
}

_ui_menu_has_prefix() {
    local k
    for k in "${_UI_MENU_KEYS[@]}"; do
        [[ -n "$k" && "${k,,}" != "${1,,}" && "${k,,}" == "${1,,}"* ]] && return 0
    done
    return 1
}

ui_menu_choose() {
    local __var="$1" init="${2:-}" n="${#_UI_MENU_KEYS[@]}" sel=0 i key rest
    _UI_MENU_TYPED=""; _UI_MENU_WARN=""
    ui_spin_stop
    _UI_MENU_KW=1
    for i in "${_UI_MENU_KEYS[@]}"; do
        (( ${#i} > _UI_MENU_KW )) && _UI_MENU_KW=${#i}
    done

    if ! _ui_interactive; then
        for ((i = 0; i < n; i++)); do
            [[ "${_UI_MENU_STYLES[$i]}" == "gap" ]] && { echo ""; continue; }
            echo -e " $(_ui_menu_style "${_UI_MENU_STYLES[$i]}")$(printf '%*s' "$_UI_MENU_KW" "${_UI_MENU_KEYS[$i]}"). ${_UI_MENU_LABELS[$i]}${RESET}"
        done
        read -rp "Выберите пункт: " key || key=""
        printf -v "$__var" '%s' "$key"
        return 0
    fi

    if [[ -n "$init" ]] && i=$(_ui_menu_index_of "$init"); then
        sel=$i
    elif [[ "${_UI_MENU_STYLES[0]:-}" == "gap" ]]; then
        sel=$(_ui_menu_next 0 1)
    fi

    local rows max first last drawn=0
    rows=$(tput lines 2>/dev/null || echo 24)
    max=$(( rows - 10 ))
    (( max < 5 )) && max=5
    first=0; last=$(( n - 1 ))
    _UI_MENU_WINDOWED=0
    (( n > max )) && _UI_MENU_WINDOWED=1

    printf '\e[?25l'
    stty -echo 2>/dev/null || true
    while true; do
        if (( n > max && sel >= 0 )); then
            (( sel < first )) && first=$sel
            (( sel > first + max - 1 )) && first=$(( sel - max + 1 ))
            last=$(( first + max - 1 ))
            (( last > n - 1 )) && last=$(( n - 1 ))
        fi
        (( drawn > 0 )) && printf '\e[%dA' "$drawn"
        _ui_menu_draw "$sel" "$first" "$last"
        drawn=$_UI_MENU_DRAWN

        IFS= read -rsn1 key || key=""
        case "$key" in
            $'\e')
                rest=""
                IFS= read -rsn2 -t 0.05 rest || true
                case "$rest" in
                    '[A'|'OA') (( sel < 0 )) && sel=$(_ui_menu_next "$n" -1) || sel=$(_ui_menu_next "$sel" -1) ;;
                    '[B'|'OB') (( sel < 0 )) && sel=$(_ui_menu_next -1 1) || sel=$(_ui_menu_next "$sel" 1) ;;
                    '[H'|'OH') sel=$(_ui_menu_next -1 1) ;;
                    '[F'|'OF') sel=$(_ui_menu_next "$n" -1) ;;
                    '') if i=$(_ui_menu_index_of "0"); then sel=$i; break; fi ;;
                    *) IFS= read -rsn5 -t 0.02 rest || true ;;
                esac
                _UI_MENU_TYPED=""; _UI_MENU_WARN="" ;;
            k) (( sel < 0 )) && sel=$(_ui_menu_next "$n" -1) || sel=$(_ui_menu_next "$sel" -1); _UI_MENU_TYPED=""; _UI_MENU_WARN="" ;;
            j) (( sel < 0 )) && sel=$(_ui_menu_next -1 1) || sel=$(_ui_menu_next "$sel" 1); _UI_MENU_TYPED=""; _UI_MENU_WARN="" ;;
            '') (( sel >= 0 )) && break ;;
            $'\x7f'|$'\b')
                _UI_MENU_TYPED="${_UI_MENU_TYPED%?}"; _UI_MENU_WARN=""
                if [[ -n "$_UI_MENU_TYPED" ]] && i=$(_ui_menu_index_of "$_UI_MENU_TYPED"); then sel=$i; fi ;;
            *)
                _UI_MENU_WARN=""
                local cand="${_UI_MENU_TYPED}${key}"
                if i=$(_ui_menu_index_of "$cand"); then
                    _UI_MENU_TYPED="$cand"; sel=$i
                elif _ui_menu_has_prefix "$cand"; then
                    _UI_MENU_TYPED="$cand"
                else
                    _UI_MENU_WARN="$cand"; _UI_MENU_TYPED=""; sel=-1
                fi ;;
        esac
    done
    printf '\e[%dA' "$drawn"
    _ui_menu_draw "$sel" "$first" "$last" 1
    printf '\e[J'
    stty echo 2>/dev/null || true
    printf '\e[?25h'
    printf -v "$__var" '%s' "${_UI_MENU_KEYS[$sel]}"
}

ui_input() {
    local __var="$1" label="$2" hint="${3:-}" note="${4:-}" first="" value=""
    ui_spin_stop
    label="${label%: }"; label="${label%:}"
    if ! _ui_interactive; then
        read -rp "${label}: " value || value=""
        printf -v "$__var" '%s' "$value"
        return 0
    fi
    echo -e "   ${BOLD}${label}${RESET}"
    [[ -n "$note" ]] && echo -e "   ${LIGHT_GRAY}${note}${RESET}"
    local p=$'\001'"${GREEN}"$'\002''›'$'\001'"${RESET}"$'\002'' '
    printf '   %s›%s %s%s%s\r' "$GREEN" "$RESET" "$LIGHT_GRAY" "$hint" "$RESET"
    printf '   %s›%s ' "$GREEN" "$RESET"
    stty -echo 2>/dev/null || true
    while true; do
        IFS= read -rsn1 first || first=""
        if [[ "$first" == $'\e' ]]; then
            IFS= read -rsn5 -t 0.02 first || true
            continue
        fi
        break
    done
    if [[ -z "$first" ]]; then
        stty echo 2>/dev/null || true
        printf '\e[K\n'
        printf -v "$__var" '%s' ""
        return 0
    fi
    printf '\r\e[K'
    stty echo 2>/dev/null || true
    IFS= read -re -i "$first" -p "   $p" value || value=""
    printf -v "$__var" '%s' "$value"
}

ui_secret() {
    local __var="$1" label="$2" note="${3:-}" value=""
    ui_spin_stop
    label="${label%: }"; label="${label%:}"
    if ! _ui_interactive; then
        read -rsp "${label}: " value || value=""
        echo ""
        printf -v "$__var" '%s' "$value"
        return 0
    fi
    echo -e "   ${BOLD}${label}${RESET}"
    [[ -n "$note" ]] && echo -e "   ${LIGHT_GRAY}${note}${RESET}"
    printf '   %s›%s ' "$GREEN" "$RESET"
    IFS= read -rs value || value=""
    if [[ -n "$value" ]]; then
        printf '%s••••••••%s\n' "$LIGHT_GRAY" "$RESET"
    else
        printf '\n'
    fi
    printf -v "$__var" '%s' "$value"
}

ui_confirm() {
    local __var="$1" q="${2:-}" ans
    ui_spin_stop
    while true; do
        if ! read -rp "$(echo -e "${GREEN}[?]${RESET} ${q:+$q }(${GREEN}${BOLD}Y${RESET}/${RED}${BOLD}N${RESET}): ")" ans; then
            echo ""
            printf -v "$__var" '%s' "n"
            return 0
        fi
        case "${ans,,}" in
            y) printf -v "$__var" '%s' "y"; return 0 ;;
            n) printf -v "$__var" '%s' "n"; return 0 ;;
        esac
        if [[ -n "$(LC_ALL=C tr -d '\000-\177' <<< "$ans")" ]]; then
            echo -e "    ${YELLOW}Переключите раскладку на английскую (Y/N)${RESET}"
        else
            echo -e "    ${YELLOW}Введите Y или N${RESET}"
        fi
    done
}

_ui_strip() {
    sed $'s/\x1b\\[[0-9;]*m//g' <<< "$1"
}

_ui_human_size() {
    local bytes="${1:-0}"
    awk -v b="$bytes" 'BEGIN {
        split("Б КБ МБ ГБ ТБ", u, " ")
        i = 1
        while (b >= 1024 && i < 5) { b /= 1024; i++ }
        s = (i == 1) ? sprintf("%d %s", b, u[i]) : sprintf("%.1f %s", b, u[i])
        sub(/\.0 /, " ", s)
        print s
    }'
}

_disk_usage() {
    local dir="$BACKUP_DIR"
    [[ -d "$dir" ]] || dir="/"
    df -B1 --output=used,avail,size "$dir" 2>/dev/null | awk 'NR==2 {print $1, $2, $3}'
}

_disk_usage_tg_line() {
    local du_out d_used d_avail d_total d_pct icon="💿"
    du_out=$(_disk_usage)
    [[ -z "$du_out" ]] && return 0
    read -r d_used d_avail d_total <<< "$du_out"
    [[ -n "$d_total" && "$d_total" -gt 0 ]] || return 0
    d_pct=$(( d_used * 100 / d_total ))
    (( d_pct >= 90 )) && icon="⚠️"
    printf '\\n%s %s / %s (%d%%) · свободно %s' \
        "$icon" "$(_ui_human_size "$d_used")" "$(_ui_human_size "$d_total")" "$d_pct" "$(_ui_human_size "$d_avail")"
}

_backup_dir_size() {
    [[ -d "$BACKUP_DIR" ]] || { echo 0; return 0; }
    find "$BACKUP_DIR" -type f -printf '%s\n' 2>/dev/null | awk '{s+=$1} END {print s+0}'
}

_backup_dir_count() {
    [[ -d "$BACKUP_DIR" ]] || { echo 0; return 0; }
    find "$BACKUP_DIR" -maxdepth 1 -type f \( -name "*.sql.gz" -o -name "*.sql" \) 2>/dev/null | wc -l
}

_backup_dir_tg_line() {
    local b_size b_count
    b_size=$(_ui_human_size "$(_backup_dir_size)")
    b_count=$(_backup_dir_count)
    printf '\\n📁 %s (файлов: %d)' "$b_size" "$b_count"
}

_ui_status_card() {
    local LC_ALL=C.UTF-8
    local title="$1"; shift
    local title_plain lw=0 vw=0 i j label plain inner cols hr="" pad
    title_plain=$(_ui_strip "$title")
    for ((i = 1; i <= $#; i += 2)); do
        j=$((i + 1))
        label="${!i}"
        plain=$(_ui_strip "${!j}")
        (( ${#label} > lw )) && lw=${#label}
        (( ${#plain} > vw )) && vw=${#plain}
    done
    inner=$(( lw + 3 + vw ))
    (( ${#title_plain} > inner )) && inner=${#title_plain}
    cols=$(tput cols 2>/dev/null || echo 80)

    if (( inner + 6 > cols )); then
        echo -e "  ${title}${RESET}"
        echo ""
        for ((i = 1; i <= $#; i += 2)); do
            j=$((i + 1)); label="${!i}"
            echo -e "  ${LIGHT_GRAY}${label}${RESET}$(printf '%*s' $((lw - ${#label} + 3)) '')${!j}${RESET}"
        done
        return 0
    fi

    for ((i = 0; i < inner + 4; i++)); do hr+="─"; done
    echo -e "${GREEN}╭${hr}╮${RESET}"
    echo -e "${GREEN}│${RESET}  ${title}${RESET}$(printf '%*s' $((inner - ${#title_plain} + 2)) '')${GREEN}│${RESET}"
    echo -e "${GREEN}├${hr}┤${RESET}"
    for ((i = 1; i <= $#; i += 2)); do
        j=$((i + 1)); label="${!i}"
        plain=$(_ui_strip "${!j}")
        pad=$(( inner - lw - 3 - ${#plain} + 2 ))
        echo -e "${GREEN}│${RESET}  ${LIGHT_GRAY}${label}${RESET}$(printf '%*s' $((lw - ${#label} + 3)) '')${!j}${RESET}$(printf '%*s' "$pad" '')${GREEN}│${RESET}"
    done
    echo -e "${GREEN}╰${hr}╯${RESET}"
}

# ============== БЛОКИРОВКА FLOCK ==============
_RUN_LOCK_FD=""

_take_run_lock() {
    command -v flock >/dev/null 2>&1 || return 0
    [[ -n "$_RUN_LOCK_FD" ]] && return 0
    mkdir -p "$INSTALL_DIR"
    exec {_RUN_LOCK_FD}>"$RUN_LOCK_FILE" || { _RUN_LOCK_FD=""; return 0; }
    if ! flock -n "$_RUN_LOCK_FD"; then
        exec {_RUN_LOCK_FD}>&-
        _RUN_LOCK_FD=""
        return 1
    fi
    return 0
}

_release_run_lock() {
    [[ -n "$_RUN_LOCK_FD" ]] || return 0
    flock -u "$_RUN_LOCK_FD" 2>/dev/null || true
    exec {_RUN_LOCK_FD}>&-
    _RUN_LOCK_FD=""
}

# ============== КОНФИГ И САМОУСТАНОВКА ==============
save_config() {
    mkdir -p "$INSTALL_DIR" "$BACKUP_DIR" "$LOG_DIR"
    cat > "$CONFIG_FILE" <<EOF
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID}"
DOCKER_CONTAINER="${DOCKER_CONTAINER}"
DB_USER="${DB_USER}"
DB_NAME="${DB_NAME}"
SCHEDULE_MODE="${SCHEDULE_MODE}"
SCHEDULE_TIMES="${SCHEDULE_TIMES}"
SCHEDULE_HOURS="${SCHEDULE_HOURS}"
SCHEDULE_PAUSED="${SCHEDULE_PAUSED}"
LOCAL_RETAIN_DAYS="${LOCAL_RETAIN_DAYS}"
EOF
    chmod 600 "$CONFIG_FILE"
}

setup_symlink() {
    [[ "$EUID" -ne 0 ]] && return 0
    if [[ -L "$SYMLINK_PATH" && "$(readlink -f "$SYMLINK_PATH")" == "$SCRIPT_PATH" ]]; then
        return 0
    fi
    ln -sf "$SCRIPT_PATH" "$SYMLINK_PATH"
}

first_run_wizard() {
    clear
    echo -e "${GREEN}${BOLD}Первичная настройка PostgreSQL Backup v${VERSION}${RESET}"
    echo ""

    ui_secret TELEGRAM_BOT_TOKEN "Токен Telegram-бота" "Получить у @BotFather"
    echo ""
    ui_input TELEGRAM_CHAT_ID "Chat ID для отправки бэкапов" "-1001234567890" "ID личного чата или группы"
    echo ""
    local input_container input_user input_db input_retain
    ui_input input_container "Имя Docker-контейнера PostgreSQL" "postgres" "Enter — оставить postgres"
    DOCKER_CONTAINER="${input_container:-postgres}"
    echo ""
    ui_input input_user "Пользователь БД (DB_USER)" "postgres" "Enter — оставить postgres"
    DB_USER="${input_user:-postgres}"
    echo ""
    ui_input input_db "Имя базы данных (DB_NAME)" "postgres" "Enter — оставить postgres"
    DB_NAME="${input_db:-postgres}"
    echo ""
    ui_input input_retain "Хранить локальные копии на сервере (дней)" "7" "Enter — 7 дней; 0 — удалять сразу после отправки"
    if [[ "$input_retain" =~ ^[0-9]+$ ]]; then
        LOCAL_RETAIN_DAYS="$input_retain"
    else
        LOCAL_RETAIN_DAYS="7"
    fi
    echo ""

    print_message "ACTION" "Выберите режим расписания:"
    ui_menu_reset
    ui_menu_add 1 "По времени (например, 03:00)"
    ui_menu_add 2 "Интервал в часах (например, каждые 12 ч)"
    ui_menu_add 3 "Не включать расписание (только вручную)"
    local sched_choice
    ui_menu_choose sched_choice
    echo ""

    case "$sched_choice" in
        1)
            local input_times
            SCHEDULE_MODE="time"
            ui_input input_times "Время запуска (ЧЧ:ММ через пробел)" "03:00" "Например: 03:00 или 03:00 15:00"
            SCHEDULE_TIMES="${input_times:-03:00}"
            SCHEDULE_PAUSED="false"
            ;;
        2)
            local input_hours
            SCHEDULE_MODE="interval"
            ui_input input_hours "Интервал в часах" "24" "Целое число больше 0"
            SCHEDULE_HOURS="${input_hours:-24}"
            SCHEDULE_PAUSED="false"
            ;;
        *)
            SCHEDULE_MODE="off"
            SCHEDULE_PAUSED="true"
            ;;
    esac

    save_config
    apply_systemd_schedule
    print_message "SUCCESS" "Настройка завершена! Запускайте меню командой: ${BOLD}pg-backup${RESET}"
    echo ""
    read -rp "Нажмите Enter для перехода в меню..."
}

load_or_init() {
    if [[ ! -f "$CONFIG_FILE" && "$SCRIPT_RUN_PATH" != "$SCRIPT_PATH" ]]; then
        mkdir -p "$INSTALL_DIR" "$BACKUP_DIR" "$LOG_DIR"
        cp "$SCRIPT_RUN_PATH" "$SCRIPT_PATH"
        chmod +x "$SCRIPT_PATH"
        setup_symlink
        exec "$SCRIPT_PATH" "$@"
    fi

    mkdir -p "$INSTALL_DIR" "$BACKUP_DIR" "$LOG_DIR"
    setup_symlink

    if [[ -f "$CONFIG_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$CONFIG_FILE"
        LOCAL_RETAIN_DAYS="${LOCAL_RETAIN_DAYS:-7}"
    else
        first_run_wizard
    fi
}

# ============== SYSTEMD TIMER ==============
is_timer_active() {
    systemctl is-active --quiet "${SERVICE_NAME}.timer" 2>/dev/null
}

apply_systemd_schedule() {
    if [[ "$EUID" -ne 0 ]]; then
        print_message "WARN" "Для настройки systemd требуются права root."
        return 1
    fi

    cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=PostgreSQL Backup to Telegram
After=docker.service network-online.target
Requires=docker.service

[Service]
Type=oneshot
ExecStart=${SCRIPT_PATH} backup
User=root
EOF

    if [[ "$SCHEDULE_MODE" == "off" ]]; then
        systemctl disable --now "${SERVICE_NAME}.timer" 2>/dev/null || true
        rm -f "/etc/systemd/system/${SERVICE_NAME}.timer"
        systemctl daemon-reload
        return 0
    fi

    local timer_rules=""
    if [[ "$SCHEDULE_MODE" == "interval" ]]; then
        timer_rules="OnActiveSec=${SCHEDULE_HOURS}h
OnUnitActiveSec=${SCHEDULE_HOURS}h"
    else
        local t
        for t in $SCHEDULE_TIMES; do
            timer_rules+="OnCalendar=*-*-* ${t}:00"$'\n'
        done
        timer_rules+="Persistent=true"
    fi

    cat > "/etc/systemd/system/${SERVICE_NAME}.timer" <<EOF
[Unit]
Description=Scheduled PostgreSQL Backup to Telegram

[Timer]
${timer_rules}

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    if [[ "$SCHEDULE_PAUSED" == "true" ]]; then
        systemctl disable --now "${SERVICE_NAME}.timer" 2>/dev/null || true
    else
        systemctl enable --now "${SERVICE_NAME}.timer" 2>/dev/null
    fi
}

pause_schedule() {
    if [[ "$SCHEDULE_MODE" == "off" ]]; then
        print_message "WARN" "Расписание не настроено."
        return 1
    fi
    SCHEDULE_PAUSED="true"
    save_config
    systemctl disable --now "${SERVICE_NAME}.timer" 2>/dev/null || true
    print_message "SUCCESS" "Автоматические бэкапы приостановлены."
}

resume_schedule() {
    if [[ "$SCHEDULE_MODE" == "off" ]]; then
        print_message "WARN" "Сначала задайте расписание в пункте «Расписание и хранение»."
        return 1
    fi
    SCHEDULE_PAUSED="false"
    save_config
    apply_systemd_schedule
    print_message "SUCCESS" "Автоматические бэкапы возобновлены."
}

# ============== TELEGRAM API ==============
send_telegram_message() {
    local message="$1"
    [[ -z "$TELEGRAM_BOT_TOKEN" || -z "$TELEGRAM_CHAT_ID" ]] && return 1
    local formatted="${message//\\n/$'\n'}"
    local attempt=1 response rc

    while (( attempt <= 3 )); do
        response=$(curl -fsS --connect-timeout 10 --max-time 30 -X POST \
            "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
            --data-urlencode "text=${formatted}" \
            --data-urlencode "parse_mode=HTML" 2>&1)
        rc=$?
        [[ $rc -eq 0 ]] && return 0
        (( attempt < 3 )) && sleep 5
        attempt=$((attempt + 1))
    done

    log_write "ERROR" "Telegram sendMessage failed: ${response}"
    return 1
}

send_telegram_file() {
    local file_path="$1"
    local caption="$2"
    [[ -z "$TELEGRAM_BOT_TOKEN" || -z "$TELEGRAM_CHAT_ID" ]] && return 1
    local formatted="${caption//\\n/$'\n'}"
    local attempt=1 response rc

    while (( attempt <= 3 )); do
        response=$(curl -fsS --connect-timeout 10 --max-time 180 -X POST \
            "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendDocument" \
            -F "chat_id=${TELEGRAM_CHAT_ID}" \
            -F "document=@${file_path}" \
            -F "caption=${formatted}" \
            -F "parse_mode=HTML" 2>&1)
        rc=$?
        [[ $rc -eq 0 ]] && return 0
        (( attempt < 3 )) && sleep 5
        attempt=$((attempt + 1))
    done

    log_write "ERROR" "Telegram sendDocument failed: ${response}"
    return 1
}

# ============== РОТАЦИЯ ЛОКАЛЬНЫХ КОПИЙ ==============
cleanup_old_backups() {
    local retain="${LOCAL_RETAIN_DAYS:-7}"
    [[ "$retain" =~ ^[0-9]+$ ]] || return 0
    (( retain <= 0 )) && return 0

    local deleted
    deleted=$(find "$BACKUP_DIR" -maxdepth 1 -type f -name "*.sql.gz" -mmin +"$((retain * 1440))" -print -delete 2>/dev/null | wc -l)
    if (( deleted > 0 )); then
        print_message "INFO" "Удалено старых локальных копий: ${deleted} (старше ${retain} дн.)"
    fi
}

# ============== ЛОГИКА БЭКАПА ==============
do_backup() {
    LOG_CATEGORY="backup"
    if ! _take_run_lock; then
        print_message "WARN" "Другой процесс бэкапа или восстановления уже выполняется."
        return 1
    fi

    local timestamp archive_file err_log archive_size file_size_bytes backups_line disk_line send_ok=true
    timestamp=$(date '+%Y-%m-%d_%H-%M-%S')
    archive_file="${BACKUP_DIR}/${DB_NAME}_${timestamp}.sql.gz"
    err_log=$(mktemp)

    if ! docker container inspect -f '{{.State.Running}}' "$DOCKER_CONTAINER" 2>/dev/null | grep -q "true"; then
        print_message "ERROR" "Контейнер ${BOLD}${DOCKER_CONTAINER}${RESET} не запущен!"
        send_telegram_message "❌ <b>Ошибка бэкапа ${DB_NAME}</b>\nКонтейнер <code>${DOCKER_CONTAINER}</code> не запущен.\nВремя: ${timestamp}" || true
        echo "$(date '+%d.%m.%Y %H:%M')|—|error" > "$LAST_BACKUP_FILE"
        rm -f "$err_log"
        _release_run_lock
        return 1
    fi

    ui_spin_start "Создаю и сжимаю дамп ${DB_NAME}..."
    if ! ( set -o pipefail; docker exec "$DOCKER_CONTAINER" pg_dump --clean --if-exists -U "$DB_USER" "$DB_NAME" 2>"$err_log" | gzip -6 > "$archive_file" ) \
       || [[ ! -s "$archive_file" ]] \
       || ! gzip -t "$archive_file" 2>/dev/null; then
        local err_text
        err_text=$(head -n 5 "$err_log" | tr '\n' ' ')
        print_message "ERROR" "Ошибка создания дампа! ${err_text}"
        send_telegram_message "❌ <b>Ошибка бэкапа ${DB_NAME}</b>\nНе удалось создать дамп.\n${err_text}\nВремя: ${timestamp}" || true
        echo "$(date '+%d.%m.%Y %H:%M')|—|error" > "$LAST_BACKUP_FILE"
        rm -f "$archive_file" "$err_log"
        _release_run_lock
        return 1
    fi
    rm -f "$err_log"

    archive_size=$(du -h "$archive_file" | cut -f1)
    file_size_bytes=$(stat -c%s "$archive_file")
    backups_line=$(_backup_dir_tg_line)
    disk_line=$(_disk_usage_tg_line)
    print_message "SUCCESS" "Архив создан и проверен (${archive_size})"

    if (( file_size_bytes > 52428800 )); then
        ui_spin_start "Файл > 50 МБ (${archive_size}), разбиваю и отправляю..."
        split -d -b 49M "$archive_file" "${archive_file}.part_"
        local parts=("${archive_file}".part_*)
        local total_parts=${#parts[@]} part_num=1 part

        for part in "${parts[@]}"; do
            if ! send_telegram_file "$part" "📦 Бэкап <b>${DB_NAME}</b> (часть ${part_num}/${total_parts})\n📅 ${timestamp}\n💾 ${archive_size}${backups_line}${disk_line}"; then
                send_ok=false
                break
            fi
            part_num=$((part_num + 1))
            sleep 2
        done
        rm -f "${archive_file}".part_*
    else
        ui_spin_start "Отправляю архив в Telegram..."
        if ! send_telegram_file "$archive_file" "✅ Бэкап <b>${DB_NAME}</b>\n🐳 <code>${DOCKER_CONTAINER}</code>\n📅 ${timestamp}\n💾 ${archive_size}${backups_line}${disk_line}"; then
            send_ok=false
        fi
    fi

    local retain="${LOCAL_RETAIN_DAYS:-7}"
    [[ "$retain" =~ ^[0-9]+$ ]] || retain=7

    if [[ "$send_ok" == "true" ]]; then
        echo "$(date '+%d.%m.%Y %H:%M')|${archive_size}|ok" > "$LAST_BACKUP_FILE"
        if (( retain == 0 )); then
            rm -f "$archive_file"
            print_message "SUCCESS" "Бэкап отправлен в Telegram, локальный файл удалён."
        else
            print_message "SUCCESS" "Бэкап отправлен в Telegram и сохранён локально (${retain} дн.)."
            cleanup_old_backups
        fi
        _release_run_lock
        return 0
    else
        echo "$(date '+%d.%m.%Y %H:%M')|${archive_size}|tg_err" > "$LAST_BACKUP_FILE"
        print_message "ERROR" "Не удалось отправить в Telegram. Архив сохранён локально: ${archive_file}"
        send_telegram_message "❌ <b>Ошибка отправки файла ${DB_NAME}</b>\nАрхив оставлен на сервере.${backups_line}${disk_line}" || true
        _release_run_lock
        return 1
    fi
}

# ============== ВОССТАНОВЛЕНИЕ ИЗ БЭКАПА ==============
restore_backup() {
    LOG_CATEGORY="restore"
    if ! _take_run_lock; then
        print_message "WARN" "Сейчас выполняется другая операция (бэкап или восстановление)."
        return 1
    fi

    clear
    echo -e "${GREEN}${BOLD}Восстановление PostgreSQL из бэкапа${RESET}"
    echo ""
    print_message "INFO" "Целевой контейнер: ${BOLD}${DOCKER_CONTAINER}${RESET} (${DB_USER}/${DB_NAME})"
    print_message "INFO" "Папка локальных копий: ${BOLD}${BACKUP_DIR}${RESET}"
    echo ""

    if ! docker container inspect -f '{{.State.Running}}' "$DOCKER_CONTAINER" 2>/dev/null | grep -q "true"; then
        print_message "ERROR" "Контейнер ${BOLD}${DOCKER_CONTAINER}${RESET} не запущен!"
        _release_run_lock
        return 1
    fi

    local -a files=()
    while IFS= read -r f; do
        [[ -n "$f" ]] && files+=("$f")
    done < <(find "$BACKUP_DIR" -maxdepth 1 -type f \( -name "*.sql.gz" -o -name "*.sql" \) -printf "%T@ %p\n" 2>/dev/null | sort -nr | cut -d' ' -f2-)

    ui_menu_reset
    local i=1 f size
    for f in "${files[@]}"; do
        size=$(du -h "$f" | cut -f1)
        ui_menu_add "$i" "${f##*/} ${LIGHT_GRAY}(${size})${RESET}"
        i=$((i + 1))
    done
    [[ ${#files[@]} -gt 0 ]] && ui_menu_gap
    ui_menu_add "P" "Указать путь к файлу вручную (.sql или .sql.gz)" primary
    ui_menu_gap
    ui_menu_add "0" "Назад"

    local choice selected_file=""
    ui_menu_choose choice
    echo ""

    case "$choice" in
        0)
            _release_run_lock
            return 0
            ;;
        [Pp])
            ui_input selected_file "Полный путь к файлу дампа" "/tmp/backup.sql.gz" "Поддерживаются .sql.gz и .sql"
            if [[ -z "$selected_file" || ! -f "$selected_file" ]]; then
                print_message "ERROR" "Файл не найден: ${selected_file:-пусто}"
                _release_run_lock
                return 1
            fi
            ;;
        *)
            if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#files[@]} )); then
                selected_file="${files[$((choice - 1))]}"
            else
                print_message "ERROR" "Неверный выбор."
                _release_run_lock
                return 1
            fi
            ;;
    esac

    if [[ "$selected_file" == *.gz ]] && ! gzip -t "$selected_file" 2>/dev/null; then
        print_message "ERROR" "Архив повреждён или не является корректным gzip-файлом."
        _release_run_lock
        return 1
    fi

    echo ""
    print_message "WARN" "Файл: ${BOLD}${selected_file}${RESET}"
    print_message "WARN" "Текущие данные в базе ${BOLD}${DB_NAME}${RESET} будут перезаписаны!"
    local confirm
    ui_confirm confirm "Выполнить восстановление?"
    echo ""

    if [[ "$confirm" != "y" ]]; then
        print_message "INFO" "Восстановление отменено."
        _release_run_lock
        return 0
    fi

    local err_log rc=0
    err_log=$(mktemp)
    ui_spin_start "Восстанавливаю базу ${DB_NAME}..."

    if [[ "$selected_file" == *.gz ]]; then
        ( set -o pipefail; gunzip -c "$selected_file" | docker exec -i "$DOCKER_CONTAINER" psql -q -U "$DB_USER" -d "$DB_NAME" >/dev/null 2>"$err_log" ) || rc=$?
    else
        docker exec -i "$DOCKER_CONTAINER" psql -q -U "$DB_USER" -d "$DB_NAME" >/dev/null 2>"$err_log" < "$selected_file" || rc=$?
    fi

    if [[ $rc -eq 0 ]]; then
        print_message "SUCCESS" "База ${BOLD}${DB_NAME}${RESET} успешно восстановлена!"
        if [[ -s "$err_log" ]]; then
            print_message "WARN" "Предупреждения psql (первые 5 строк):"
            head -n 5 "$err_log"
        fi
        send_telegram_message "✅ <b>Восстановление БД ${DB_NAME} завершено</b>\nФайл: <code>${selected_file##*/}</code>" || true
    else
        print_message "ERROR" "Ошибка при восстановлении (код ${rc}):"
        head -n 10 "$err_log"
        log_write "ERROR" "Restore failed (rc=${rc}): $(head -n 5 "$err_log" | tr '\n' ' ')"
    fi

    rm -f "$err_log"
    _release_run_lock
    return $rc
}

# ============== ОБНОВЛЕНИЕ СКРИПТА ==============
_version_lt() {
    [[ "$1" != "$2" ]] && [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" == "$1" ]]
}

update_script() {
    LOG_CATEGORY="system"
    clear
    echo -e "${GREEN}${BOLD}Обновление скрипта${RESET}"
    echo ""

    if [[ "$EUID" -ne 0 ]]; then
        print_message "ERROR" "Для обновления требуются права root."
        return 1
    fi

    ui_spin_start "Проверяю последнюю версию на GitHub..."
    local remote_ver
    remote_ver=$(curl -fsSL --max-time 15 "$SCRIPT_REPO_URL" 2>/dev/null | grep -m 1 '^VERSION=' | cut -d'"' -f2)

    if [[ -z "$remote_ver" ]]; then
        print_message "ERROR" "Не удалось получить информацию о версии с GitHub."
        return 1
    fi

    print_message "INFO" "Текущая версия:   ${BOLD}${VERSION}${RESET}"
    print_message "INFO" "Версия на GitHub: ${BOLD}${GREEN}${remote_ver}${RESET}"
    echo ""

    local confirm="n"
    if _version_lt "$VERSION" "$remote_ver"; then
        ui_confirm confirm "Доступно обновление до v${remote_ver}. Установить?"
    else
        print_message "SUCCESS" "У вас установлена актуальная версия."
        ui_confirm confirm "Принудительно переустановить с GitHub?"
    fi

    [[ "$confirm" != "y" ]] && { print_message "INFO" "Обновление отменено."; return 0; }

    local tmp_script="${SCRIPT_PATH}.tmp"
    ui_spin_start "Загружаю новую версию..."
    if ! curl -fsSL --max-time 30 "$SCRIPT_REPO_URL" -o "$tmp_script"; then
        rm -f "$tmp_script"
        print_message "ERROR" "Ошибка загрузки файла с GitHub."
        return 1
    fi

    if [[ ! -s "$tmp_script" ]] || ! head -n 1 "$tmp_script" | grep -qE '^#!.*bash'; then
        rm -f "$tmp_script"
        print_message "ERROR" "Загруженный файл повреждён или не является bash-скриптом."
        return 1
    fi

    cp -f "$SCRIPT_PATH" "${SCRIPT_PATH}.bak" 2>/dev/null || true
    mv -f "$tmp_script" "$SCRIPT_PATH"
    chmod +x "$SCRIPT_PATH"
    setup_symlink

    print_message "SUCCESS" "Скрипт обновлён до v${remote_ver}! Конфигурация сохранена."
    echo ""
    if _ui_interactive; then
        read -rp "Нажмите Enter для перезапуска..."
        exec "$SCRIPT_PATH"
    fi
}

# ============== КАРТОЧКА СТАТУСА ==============
show_status_card() {
    local title="${GREEN}${BOLD}PostgreSQL Backup${RESET}  ${LIGHT_GRAY}v${VERSION}${RESET}"
    local db_val="${BOLD}${DOCKER_CONTAINER}${RESET} · ${DB_USER}/${DB_NAME}"
    local tg_val sched_val next_val retain_val disk_val last_val local_count local_size

    if [[ -n "$TELEGRAM_BOT_TOKEN" && -n "$TELEGRAM_CHAT_ID" ]]; then
        local tail="${TELEGRAM_BOT_TOKEN#*:}"
        tg_val="${GREEN}Настроен${RESET} ${LIGHT_GRAY}(${TELEGRAM_CHAT_ID}, ***${tail: -4})${RESET}"
    else
        tg_val="${RED}Не настроен${RESET}"
    fi

    if [[ "$SCHEDULE_MODE" == "off" ]]; then
        sched_val="${LIGHT_GRAY}Отключено${RESET}"
    elif is_timer_active; then
        if [[ "$SCHEDULE_MODE" == "interval" ]]; then
            sched_val="${GREEN}Активно${RESET} · каждые ${BOLD}${SCHEDULE_HOURS} ч.${RESET}"
        else
            sched_val="${GREEN}Активно${RESET} · в ${BOLD}${SCHEDULE_TIMES}${RESET}"
        fi
    else
        if [[ "$SCHEDULE_MODE" == "interval" ]]; then
            sched_val="${YELLOW}На паузе${RESET} ${LIGHT_GRAY}(каждые ${SCHEDULE_HOURS} ч.)${RESET}"
        else
            sched_val="${YELLOW}На паузе${RESET} ${LIGHT_GRAY}(${SCHEDULE_TIMES})${RESET}"
        fi
    fi

    if is_timer_active; then
        next_val=$(systemctl show -p NextElapseUSecRealtime --value "${SERVICE_NAME}.timer" 2>/dev/null)
        if [[ -z "$next_val" || "$next_val" == "n/a" ]]; then
            next_val=$(systemctl list-timers --no-pager --no-legend "${SERVICE_NAME}.timer" 2>/dev/null | awk '$1 != "n/a" && $1 != "-" {print $1, $2, $3, $4}')
        fi
        next_val="${BOLD}${next_val:-вычисляется...}${RESET}"
    else
        next_val="${LIGHT_GRAY}—${RESET}"
    fi

    local_count=$(_backup_dir_count)
    local_size=$(_ui_human_size "$(_backup_dir_size)")
    if [[ "${LOCAL_RETAIN_DAYS:-7}" == "0" ]]; then
        retain_val="${LIGHT_GRAY}Удалять сразу${RESET} ${LIGHT_GRAY}(файлов: ${local_count} · ${local_size})${RESET}"
    else
        retain_val="${BOLD}${LOCAL_RETAIN_DAYS} дн.${RESET} ${LIGHT_GRAY}(файлов: ${local_count} · ${local_size})${RESET}"
    fi

    disk_val="${LIGHT_GRAY}—${RESET}"
    local du_out d_used d_avail d_total d_pct d_color
    du_out=$(_disk_usage)
    if [[ -n "$du_out" ]]; then
        read -r d_used d_avail d_total <<< "$du_out"
        if [[ -n "$d_total" && "$d_total" -gt 0 ]]; then
            d_pct=$(( d_used * 100 / d_total ))
            if (( d_pct >= 90 )); then
                d_color="${RED}${BOLD}"
            elif (( d_pct >= 80 )); then
                d_color="${YELLOW}${BOLD}"
            else
                d_color="${BOLD}"
            fi
            disk_val="${d_color}$(_ui_human_size "$d_used") / $(_ui_human_size "$d_total") (${d_pct}%)${RESET} ${LIGHT_GRAY}· свободно $(_ui_human_size "$d_avail")${RESET}"
        fi
    fi

    if [[ -f "$LAST_BACKUP_FILE" ]]; then
        local lb_date lb_size lb_st
        IFS='|' read -r lb_date lb_size lb_st < "$LAST_BACKUP_FILE"
        case "$lb_st" in
            ok)     last_val="${GREEN}✓${RESET} ${lb_date} · ${BOLD}${lb_size}${RESET}" ;;
            tg_err) last_val="${YELLOW}⚠ Ошибка TG${RESET} (${lb_date}, локально)" ;;
            *)      last_val="${RED}✗ Ошибка${RESET} (${lb_date})" ;;
        esac
    else
        last_val="${LIGHT_GRAY}Ещё не выполнялся${RESET}"
    fi

    _ui_status_card "$title" \
        "База данных"  "$db_val" \
        "Telegram"     "$tg_val" \
        "Расписание"   "$sched_val" \
        "След. запуск" "$next_val" \
        "Хранение"     "$retain_val" \
        "Диск"         "$disk_val" \
        "Последний"    "$last_val"
}

# ============== ПОДМЕНЮ НАСТРОЕК ==============
menu_schedule() {
    local choice
    while true; do
        clear
        echo -e "${GREEN}${BOLD}Расписание и хранение копий${RESET}"
        echo ""
        if [[ "$SCHEDULE_MODE" == "interval" ]]; then
            print_message "INFO" "Расписание: ${BOLD}интервал каждые ${SCHEDULE_HOURS} ч.${RESET}"
        elif [[ "$SCHEDULE_MODE" == "time" ]]; then
            print_message "INFO" "Расписание: ${BOLD}по времени (${SCHEDULE_TIMES})${RESET}"
        else
            print_message "INFO" "Расписание: ${YELLOW}отключено${RESET}"
        fi
        local local_size
        local_size=$(_ui_human_size "$(_backup_dir_size)")
        if [[ "${LOCAL_RETAIN_DAYS:-7}" == "0" ]]; then
            print_message "INFO" "Хранение на сервере: ${YELLOW}удалять сразу после отправки в Telegram${RESET} (${local_size})"
        else
            print_message "INFO" "Хранение на сервере: ${BOLD}${LOCAL_RETAIN_DAYS} дн.${RESET} (${BACKUP_DIR}, ${local_size})"
        fi
        echo ""

        ui_menu_reset
        ui_menu_add 1 "Задать интервал в часах (ручной ввод)"
        ui_menu_add 2 "Задать точное время запуска (ЧЧ:ММ)"
        if is_timer_active; then
            ui_menu_add 3 "Приостановить расписание" warn
        elif [[ "$SCHEDULE_MODE" != "off" ]]; then
            ui_menu_add 3 "Возобновить расписание" primary
        fi
        ui_menu_add 4 "Полностью отключить расписание" danger
        ui_menu_gap
        ui_menu_add 5 "Изменить срок хранения на сервере (дней)"
        ui_menu_gap
        ui_menu_add 0 "Назад"
        ui_menu_choose choice
        echo ""

        case "$choice" in
            1)
                local hours
                ui_input hours "Интервал в часах" "$SCHEDULE_HOURS" "Целое число, например: 6, 12, 24"
                if [[ "$hours" =~ ^[0-9]+$ && "$hours" -gt 0 ]]; then
                    SCHEDULE_MODE="interval"
                    SCHEDULE_HOURS="$hours"
                    SCHEDULE_PAUSED="false"
                    save_config
                    apply_systemd_schedule
                    print_message "SUCCESS" "Установлен интервал: каждые ${BOLD}${hours} ч.${RESET}"
                else
                    print_message "ERROR" "Введите целое положительное число."
                fi
                ;;
            2)
                local times t valid=true
                ui_input times "Время запуска (ЧЧ:ММ через пробел)" "$SCHEDULE_TIMES" "По времени сервера ($(date +%Z)). Пример: 03:00 или 03:00 15:00"
                [[ -z "$times" ]] && continue
                for t in $times; do
                    if ! [[ "$t" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
                        print_message "ERROR" "Неверный формат времени: ${t} (нужно ЧЧ:ММ, например 03:00)"
                        valid=false; break
                    fi
                done
                if [[ "$valid" == "true" ]]; then
                    SCHEDULE_MODE="time"
                    SCHEDULE_TIMES="$times"
                    SCHEDULE_PAUSED="false"
                    save_config
                    apply_systemd_schedule
                    print_message "SUCCESS" "Установлено расписание на: ${BOLD}${times}${RESET}"
                fi
                ;;
            3)
                if is_timer_active; then pause_schedule; else resume_schedule; fi
                ;;
            4)
                SCHEDULE_MODE="off"
                SCHEDULE_PAUSED="true"
                save_config
                apply_systemd_schedule
                print_message "SUCCESS" "Расписание отключено."
                ;;
            5)
                local days
                ui_input days "Сколько дней хранить локальные копии" "$LOCAL_RETAIN_DAYS" "0 — удалять сразу после отправки в Telegram"
                if [[ "$days" =~ ^[0-9]+$ ]]; then
                    LOCAL_RETAIN_DAYS="$((10#$days))"
                    save_config
                    if (( LOCAL_RETAIN_DAYS == 0 )); then
                        print_message "SUCCESS" "Локальное хранение отключено (архивы будут удаляться после отправки)."
                    else
                        print_message "SUCCESS" "Срок хранения на сервере: ${BOLD}${LOCAL_RETAIN_DAYS} дн.${RESET}"
                    fi
                else
                    print_message "ERROR" "Введите целое число (0 или больше)."
                fi
                ;;
            0) return ;;
        esac
        echo ""
        read -rp "Нажмите Enter..."
    done
}

menu_database() {
    local choice
    while true; do
        clear
        echo -e "${GREEN}${BOLD}Настройка Docker и PostgreSQL${RESET}"
        echo ""
        print_message "INFO" "Контейнер:    ${BOLD}${DOCKER_CONTAINER}${RESET}"
        print_message "INFO" "Пользователь: ${BOLD}${DB_USER}${RESET}"
        print_message "INFO" "База данных:  ${BOLD}${DB_NAME}${RESET}"
        echo ""

        ui_menu_reset
        ui_menu_add 1 "Изменить Docker-контейнер"
        ui_menu_add 2 "Изменить DB_USER"
        ui_menu_add 3 "Изменить DB_NAME"
        ui_menu_add 4 "Проверить подключение к БД"
        ui_menu_gap
        ui_menu_add 0 "Назад"
        ui_menu_choose choice
        echo ""

        case "$choice" in
            1)
                local val
                ui_input val "Имя Docker-контейнера" "$DOCKER_CONTAINER"
                if [[ -n "$val" ]]; then
                    DOCKER_CONTAINER="$val"; save_config
                    print_message "SUCCESS" "Контейнер обновлён: ${BOLD}${DOCKER_CONTAINER}${RESET}"
                fi
                ;;
            2)
                local val
                ui_input val "Пользователь БД (DB_USER)" "$DB_USER"
                if [[ -n "$val" ]]; then
                    DB_USER="$val"; save_config
                    print_message "SUCCESS" "DB_USER обновлён: ${BOLD}${DB_USER}${RESET}"
                fi
                ;;
            3)
                local val
                ui_input val "Имя базы данных (DB_NAME)" "$DB_NAME"
                if [[ -n "$val" ]]; then
                    DB_NAME="$val"; save_config
                    print_message "SUCCESS" "DB_NAME обновлён: ${BOLD}${DB_NAME}${RESET}"
                fi
                ;;
            4)
                ui_spin_start "Проверяю доступность ${DOCKER_CONTAINER}..."
                if docker exec "$DOCKER_CONTAINER" pg_isready -U "$DB_USER" -d "$DB_NAME" >/dev/null 2>&1; then
                    print_message "SUCCESS" "Подключение к ${DB_NAME} успешно!"
                else
                    print_message "ERROR" "Не удалось подключиться к контейнеру/БД."
                fi
                ;;
            0) return ;;
        esac
        echo ""
        read -rp "Нажмите Enter..."
    done
}

menu_telegram() {
    local choice
    while true; do
        clear
        echo -e "${GREEN}${BOLD}Настройка Telegram${RESET}"
        echo ""
        local masked="не задан"
        if [[ -n "$TELEGRAM_BOT_TOKEN" ]]; then
            local tail="${TELEGRAM_BOT_TOKEN#*:}"
            masked="${TELEGRAM_BOT_TOKEN%%:*}:****${tail: -4}"
        fi
        print_message "INFO" "Токен бота: ${BOLD}${masked}${RESET}"
        print_message "INFO" "Chat ID:    ${BOLD}${TELEGRAM_CHAT_ID:-не задан}${RESET}"
        echo ""

        ui_menu_reset
        ui_menu_add 1 "Изменить токен бота"
        ui_menu_add 2 "Изменить Chat ID"
        ui_menu_add 3 "Отправить тестовое сообщение"
        ui_menu_gap
        ui_menu_add 0 "Назад"
        ui_menu_choose choice
        echo ""

        case "$choice" in
            1)
                local tok
                ui_secret tok "Новый токен Telegram-бота" "Ввод скрыт"
                if [[ -n "$tok" ]]; then
                    TELEGRAM_BOT_TOKEN="$tok"; save_config
                    print_message "SUCCESS" "Токен сохранён."
                fi
                ;;
            2)
                local cid
                ui_input cid "Новый Chat ID" "$TELEGRAM_CHAT_ID"
                if [[ -n "$cid" ]]; then
                    TELEGRAM_CHAT_ID="$cid"; save_config
                    print_message "SUCCESS" "Chat ID сохранён: ${BOLD}${TELEGRAM_CHAT_ID}${RESET}"
                fi
                ;;
            3)
                ui_spin_start "Отправляю тест в Telegram..."
                if send_telegram_message "✅ <b>Тестовое сообщение</b>\nБот настроен корректно (<code>${DOCKER_CONTAINER}/${DB_NAME}</code>)."; then
                    print_message "SUCCESS" "Сообщение доставлено!"
                else
                    print_message "ERROR" "Ошибка отправки. Проверьте токен, Chat ID и логи."
                fi
                ;;
            0) return ;;
        esac
        echo ""
        read -rp "Нажмите Enter..."
    done
}

menu_logs() {
    local choice
    while true; do
        clear
        echo -e "${GREEN}${BOLD}Просмотр логов${RESET}"
        echo ""
        ui_menu_reset
        ui_menu_add 1 "Лог бэкапов (backup.log)"
        ui_menu_add 2 "Лог восстановлений (restore.log)"
        ui_menu_add 3 "Лог ошибок (error.log)"
        ui_menu_add 4 "Журнал systemd (journalctl)"
        ui_menu_gap
        ui_menu_add 0 "Назад"
        ui_menu_choose choice
        echo ""

        clear
        case "$choice" in
            1)
                echo -e "${GREEN}${BOLD}${LOG_DIR}/backup.log${RESET}\n"
                if [[ -s "${LOG_DIR}/backup.log" ]]; then tail -n 50 "${LOG_DIR}/backup.log"; else print_message "INFO" "Лог пока пуст."; fi
                ;;
            2)
                echo -e "${GREEN}${BOLD}${LOG_DIR}/restore.log${RESET}\n"
                if [[ -s "${LOG_DIR}/restore.log" ]]; then tail -n 50 "${LOG_DIR}/restore.log"; else print_message "INFO" "Лог пока пуст."; fi
                ;;
            3)
                echo -e "${GREEN}${BOLD}${LOG_DIR}/error.log${RESET}\n"
                if [[ -s "${LOG_DIR}/error.log" ]]; then tail -n 50 "${LOG_DIR}/error.log"; else print_message "INFO" "Ошибок не зафиксировано."; fi
                ;;
            4)
                echo -e "${GREEN}${BOLD}journalctl -u ${SERVICE_NAME}.service${RESET}\n"
                journalctl -u "${SERVICE_NAME}.service" -n 40 --no-pager 2>/dev/null || print_message "INFO" "Записей нет."
                ;;
            0) return ;;
        esac
        echo ""
        read -rp "Нажмите Enter..."
    done
}

uninstall_all() {
    local ans
    print_message "WARN" "Будут удалены: systemd сервис/таймер, симлинк ${SYMLINK_PATH} и папка ${INSTALL_DIR}."
    ui_confirm ans "Точно удалить?"
    [[ "$ans" != "y" ]] && return

    systemctl disable --now "${SERVICE_NAME}.timer" 2>/dev/null || true
    systemctl stop "${SERVICE_NAME}.service" 2>/dev/null || true
    rm -f "/etc/systemd/system/${SERVICE_NAME}.service" "/etc/systemd/system/${SERVICE_NAME}.timer"
    systemctl daemon-reload
    rm -f "$SYMLINK_PATH"
    rm -rf "$INSTALL_DIR"
    print_message "SUCCESS" "Скрипт и systemd-таймер полностью удалены."
    exit 0
}

# ============== ГЛАВНОЕ МЕНЮ ==============
main_menu() {
    local choice=""
    while true; do
        LOG_CATEGORY="system"
        clear
        show_status_card
        echo ""

        ui_menu_reset
        ui_menu_add 1 "Сделать моментальный бэкап" primary
        ui_menu_add 2 "Восстановить БД из бэкапа" primary
        if is_timer_active; then
            ui_menu_add 3 "Приостановить авто-бэкапы" warn
        else
            ui_menu_add 3 "Возобновить авто-бэкапы" primary
        fi
        ui_menu_gap
        ui_menu_add 4 "Расписание и хранение (время / интервал / дни)"
        ui_menu_add 5 "База данных и Docker-контейнер"
        ui_menu_add 6 "Настройки Telegram (токен и чат)"
        ui_menu_add 7 "Логи"
        ui_menu_gap
        ui_menu_add 8 "Обновить скрипт" warn
        ui_menu_add 9 "Удалить скрипт и таймер" danger
        ui_menu_gap
        ui_menu_add 0 "Выход"
        ui_menu_footer "Команды: pg-backup [backup|restore|update|pause|resume|status]"
        ui_menu_choose choice "$choice"
        echo ""

        case "$choice" in
            1) ( do_backup ) || true; echo ""; read -rp "Нажмите Enter..." ;;
            2) ( restore_backup ) || true; echo ""; read -rp "Нажмите Enter..." ;;
            3)
                if is_timer_active; then pause_schedule; else resume_schedule; fi
                echo ""; read -rp "Нажмите Enter..."
                ;;
            4) menu_schedule ;;
            5) menu_database ;;
            6) menu_telegram ;;
            7) menu_logs ;;
            8) update_script; echo ""; read -rp "Нажмите Enter..." ;;
            9) uninstall_all ;;
            0) exit 0 ;;
        esac
    done
}

# ============== ТОЧКА ВХОДА ==============
load_or_init "$@"

case "${1:-}" in
    "")
        main_menu
        ;;
    backup)
        do_backup
        ;;
    restore)
        restore_backup
        ;;
    update)
        update_script
        ;;
    pause)
        pause_schedule
        ;;
    resume)
        resume_schedule
        ;;
    status)
        show_status_card
        ;;
    uninstall)
        uninstall_all
        ;;
    *)
        echo "Использование: pg-backup [backup|restore|update|pause|resume|status|uninstall]"
        exit 1
        ;;
esac
