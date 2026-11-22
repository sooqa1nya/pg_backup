#!/usr/bin/env bash
# pg-backup.sh — Резервное копирование и восстановление PostgreSQL (Docker) с отправкой в Telegram
# Использование: pg-backup [backup|restore|update|pause|resume|status|uninstall]

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

VERSION="1.3.0"
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
        echo -e "${GRAY}[INFO]${RESET}$msg"
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
        if [[ -f "${LOG_DIR}/${f}.log" && $(stat -c \%s "${LOG_DIR}/${f}.log" 2>/dev/null \vert{}\vert{} echo 0) -gt $LOG_MAX_BYTES ]]; then
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
        clean=$(printf '%s' "$message" \vert{} sed -e $'s/\x1b\\[[0-9;]*m//g' -e 's/bot[0-9]\{6,\}:[A-Za-z0-9_-]\{20,\}/bot***/g' | tr '\n' ' ')
        echo "$(date '+%Y-%m-%d %H:%M:%S') [${level}]${clean}" >> "${LOG_DIR}/${LOG_CATEGORY}.log"
        if [[ "$level" == "ERROR" \vert{}\vert{} "$level" == "WARN" ]]; then
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
            message="${message}${LIGHT_GRAY}· ${UI_LAST_ELAPSED}с${RESET}"
        fi
        UI_LAST_ELAPSED=""
    fi
    echo -e "${color_code}[${type}]${RESET}${message}"
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

_human_size() {
    LC_ALL=C awk -v b="${1:-0}" 'BEGIN {
        split("Б КБ МБ ГБ ТБ", u, " ")
        i = 1
        while (b >= 1024 && i < 5) { b /= 1024; i++ }
        s = (i == 1) ? sprintf("%d %s", b, u[i]) : sprintf("%.1f %s", b, u[i])
        sub(/\.0 /, " ", s)
        print s
    }'
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
            echo -e "  ${LIGHT_GRAY}${label}${RESET}$(printf '%*s' $((lw -${#label} + 3)) '')${!j}${RESET}"
        done
        return 0
    fi

    for ((i = 0; i < inner + 4; i++)); do hr+="─"; done
    echo -e "${GREEN}╭${hr}╮${RESET}"
    echo -e "${GREEN}│${RESET}${title}${RESET}$(printf '%*s' $((inner -${#title_plain} + 2)) '')${GREEN}│${RESET}"
    echo -e "${GREEN}├${hr}┤${RESET}"
    for ((i = 1; i <= $#; i += 2)); do
        j=$((i + 1)); label="${!i}"
        plain=$(_ui_strip "${!j}")
        pad=$(( inner - lw - 3 -${#plain} + 2 ))
        echo -e "${GREEN}│${RESET}  ${LIGHT_GRAY}${label}${RESET}$(printf '%*s' $((lw -${#label} + 3)) '')${!j}${RESET}$(printf '%*s' "$pad" '')${GREEN}│${RESET}"
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

    local timestamp archive_file err_log archive_size file_size_bytes send_ok=true
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
    print_message "SUCCESS" "Архив создан и проверен (${archive_size})"

    if (( file_size_bytes > 52428800 )); then
        ui_spin_start "Файл > 50 МБ (${archive_size}), разбиваю и отправляю..."
        split -d -b 49M "$archive_file" "${archive_file}.part_"
        local parts=("${archive_file}".part_*)
        local total_parts=${#parts[@]} part_num=1 part

        for part in "${parts[@]}"; do
            if ! send_telegram_file "$part" "📦 Бэкап <b>${DB_NAME}</b> (часть ${part_num}/${total_parts})\n📅 ${timestamp}\n💾 ${archive_size}"; then
                send_ok=false
                break
            fi
            part_num=$((part_num + 1))
            sleep 2
        done
        rm -f "${archive_file}".part_*
    else
        ui_spin_start "Отправляю архив в Telegram..."
        if ! send_telegram_file "$archive_file" "✅ Бэкап <b>${DB_NAME}</b>\n🐳 <code>${DOCKER_CONTAINER}</code>\n📅 ${timestamp}\n💾 ${archive_size}"; then
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
        send_telegram_message "❌ <b>Ошибка отправки файла ${DB_NAME}</b>\nАрхив оставлен на сервере." || true
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
        print_message "ERROR" "Архив повреждён или не
