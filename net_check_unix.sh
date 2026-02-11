#!/usr/bin/env bash
set -u

SCRIPT_VERSION="2.2"
TARGET_ICMP="8.8.8.8"
TARGET_TCP_HOST="1.1.1.1"
TARGET_TCP_PORT="443"
MAX_HOPS="4"
AUTO_INSTALL="${NETCHECK_AUTO_INSTALL:-0}"
PAUSE_AT_END="${NETCHECK_PAUSE_AT_END:-1}"
CAMPUS_GATEWAY_REGEX="${NETCHECK_CAMPUS_GATEWAY_REGEX:-}"
DNS_TEST_DOMAIN="${NETCHECK_DNS_TEST_DOMAIN:-google.com}"
TRACK_MODE=0
TRACK_TARGET="${NETCHECK_TRACK_TARGET:-}"
TRACK_INTERVAL="${NETCHECK_TRACK_INTERVAL:-2}"
TRACK_WINDOW="${NETCHECK_TRACK_WINDOW:-5}"
TRACK_MIN_STEP="${NETCHECK_TRACK_MIN_STEP:-3}"
OS_NAME="$(uname -s)"
TRACE_MODE=""
ROUTER_SUSPECT=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-pause) PAUSE_AT_END="0" ;;
        --pause) PAUSE_AT_END="1" ;;
        --auto-install) AUTO_INSTALL="1" ;;
        --no-auto-install) AUTO_INSTALL="0" ;;
        --track)
            TRACK_MODE=1
            if [[ $# -gt 1 && "$2" != --* ]]; then
                TRACK_TARGET="$2"
                shift
            fi
            ;;
        --track-target)
            TRACK_MODE=1
            if [[ $# -lt 2 ]]; then
                printf "Missing value for --track-target\n"
                exit 2
            fi
            TRACK_TARGET="$2"
            shift
            ;;
        --track-interval)
            TRACK_MODE=1
            if [[ $# -lt 2 ]]; then
                printf "Missing value for --track-interval\n"
                exit 2
            fi
            TRACK_INTERVAL="$2"
            shift
            ;;
        -h|--help)
            cat <<'EOF'
Usage: net_check_unix.sh [--pause|--no-pause] [--auto-install|--no-auto-install]
       net_check_unix.sh --track [BSSID]
       net_check_unix.sh --track-target BSSID [--track-interval 2]
Environment:
  NETCHECK_AUTO_INSTALL=1    Enable trace-tool auto install (default: 0)
  NETCHECK_PAUSE_AT_END=0    Disable pause before window close
  NETCHECK_DNS_TEST_DOMAIN   DNS test domain (default: google.com)
  NETCHECK_CAMPUS_GATEWAY_REGEX
                            Regex for known campus gateway range
  NETCHECK_TRACK_TARGET      BSSID to track (AA:BB:CC:DD:EE:FF)
  NETCHECK_TRACK_INTERVAL    Tracker sampling interval (default: 2 sec)
  NETCHECK_TRACK_WINDOW      Moving average window size (default: 5)
  NETCHECK_TRACK_MIN_STEP    Minimum avg delta for trend (default: 3)
EOF
            exit 0
            ;;
        *)
            printf "Unknown option: %s\nUse --help for usage.\n" "$1"
            exit 2
            ;;
    esac
    shift
done

pause_before_exit() {
    local rc=$?
    if [[ "$PAUSE_AT_END" == "1" && -t 0 ]]; then
        printf "\nPress Enter to close this window..."
        read -r _
    fi
    trap - EXIT
    exit "$rc"
}
trap pause_before_exit EXIT

if [[ -t 1 ]]; then
    C_RESET=$'\033[0m'
    C_INFO=$'\033[36m'
    C_OK=$'\033[32m'
    C_WARN=$'\033[33m'
    C_FAIL=$'\033[31m'
else
    C_RESET=""
    C_INFO=""
    C_OK=""
    C_WARN=""
    C_FAIL=""
fi

status() {
    local level="$1"
    shift
    local color="$C_INFO"
    case "$level" in
        INFO) color="$C_INFO" ;;
        OK) color="$C_OK" ;;
        WARN) color="$C_WARN" ;;
        FAIL) color="$C_FAIL" ;;
    esac
    printf "%b[%s]%b %s\n" "$color" "$level" "$C_RESET" "$*"
}

result_and_exit() {
    local code="$1"
    local level="$2"
    local summary="$3"
    local next_step="${4:-}"

    printf "%s\n" "--------------------------------------------"
    status "$level" "RESULT: $summary"
    if [[ -n "$next_step" ]]; then
        status INFO "NEXT STEP: $next_step"
    fi
    exit "$code"
}

print_banner() {
    printf "============================================\n"
    printf "     UNIX NETWORK DIAGNOSTICS v%s\n" "$SCRIPT_VERSION"
    printf "============================================\n"
}

install_traceroute_linux() {
    if ! command -v sudo >/dev/null 2>&1; then
        status WARN "Missing sudo. Cannot auto-install traceroute utilities."
        return 1
    fi

    if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get install -y traceroute >/dev/null 2>&1 || sudo apt-get install -y iputils-tracepath >/dev/null 2>&1
    elif command -v dnf >/dev/null 2>&1; then
        sudo dnf -y install traceroute >/dev/null 2>&1
    elif command -v yum >/dev/null 2>&1; then
        sudo yum -y install traceroute >/dev/null 2>&1
    elif command -v pacman >/dev/null 2>&1; then
        sudo pacman -Sy --noconfirm traceroute >/dev/null 2>&1
    elif command -v zypper >/dev/null 2>&1; then
        sudo zypper --non-interactive install traceroute >/dev/null 2>&1
    elif command -v apk >/dev/null 2>&1; then
        sudo apk add traceroute >/dev/null 2>&1
    else
        status WARN "Unsupported package manager. Install traceroute manually."
        return 1
    fi
}

install_nmcli_linux() {
    if ! command -v sudo >/dev/null 2>&1; then
        status WARN "Missing sudo. Cannot auto-install nmcli."
        return 1
    fi

    if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get install -y network-manager >/dev/null 2>&1
    elif command -v dnf >/dev/null 2>&1; then
        sudo dnf -y install NetworkManager >/dev/null 2>&1
    elif command -v yum >/dev/null 2>&1; then
        sudo yum -y install NetworkManager >/dev/null 2>&1
    elif command -v pacman >/dev/null 2>&1; then
        sudo pacman -Sy --noconfirm networkmanager >/dev/null 2>&1
    elif command -v zypper >/dev/null 2>&1; then
        sudo zypper --non-interactive install NetworkManager >/dev/null 2>&1
    elif command -v apk >/dev/null 2>&1; then
        sudo apk add networkmanager >/dev/null 2>&1
    else
        status WARN "Unsupported package manager. Install NetworkManager/nmcli manually."
        return 1
    fi
}

ensure_trace_tool() {
    if command -v traceroute >/dev/null 2>&1; then
        TRACE_MODE="traceroute"
        return 0
    fi

    if command -v tracepath >/dev/null 2>&1; then
        TRACE_MODE="tracepath"
        return 0
    fi

    if [[ "$OS_NAME" == "Linux" && "$AUTO_INSTALL" == "1" ]]; then
        status INFO "Trace tool missing. Attempting automatic install."
        install_traceroute_linux || return 1
        if command -v traceroute >/dev/null 2>&1; then
            TRACE_MODE="traceroute"
            return 0
        fi
        if command -v tracepath >/dev/null 2>&1; then
            TRACE_MODE="tracepath"
            return 0
        fi
    fi

    return 1
}

ensure_nmcli_tool() {
    if command -v nmcli >/dev/null 2>&1; then
        return 0
    fi

    if [[ "$OS_NAME" == "Linux" && "$AUTO_INSTALL" == "1" ]]; then
        status INFO "nmcli missing. Attempting automatic install."
        install_nmcli_linux || return 1
        command -v nmcli >/dev/null 2>&1
        return $?
    fi

    return 1
}

normalize_mac() {
    local input="${1^^}"
    input="${input//-/:}"
    if [[ "$input" =~ ^([0-9A-F]{2}:){5}[0-9A-F]{2}$ ]]; then
        printf "%s" "$input"
        return 0
    fi
    return 1
}

connected_bssid() {
    nmcli -t -f ACTIVE,BSSID dev wifi list 2>/dev/null |
        awk -F: '$1 == "yes" {print toupper($2 ":" $3 ":" $4 ":" $5 ":" $6 ":" $7); exit}'
}

signal_for_bssid() {
    local target="$1"
    nmcli -t -f BSSID,SIGNAL dev wifi list --rescan yes 2>/dev/null |
        awk -F: -v mac="$target" '
            {
                b=toupper($1 ":" $2 ":" $3 ":" $4 ":" $5 ":" $6)
                if (b == mac && $7 ~ /^[0-9]+$/) {
                    print $7
                    exit
                }
            }'
}

start_wifi_tracker() {
    local target="${TRACK_TARGET:-}"
    local interval="$TRACK_INTERVAL"
    local window="$TRACK_WINDOW"
    local min_step="$TRACK_MIN_STEP"

    if [[ "$OS_NAME" != "Linux" ]]; then
        result_and_exit 51 FAIL "Wi-Fi tracking mode is currently supported only on Linux in this script." "Use the Windows tracker mode in net_check_win.ps1 on Windows."
    fi

    if ! ensure_nmcli_tool; then
        result_and_exit 52 FAIL "Wi-Fi tracking needs nmcli (NetworkManager)." "Install NetworkManager or rerun with --auto-install."
    fi

    if [[ "$interval" =~ ^[0-9]+([.][0-9]+)?$ ]] && awk "BEGIN {exit !($interval > 0)}"; then
        :
    else
        interval="2"
    fi

    if [[ ! "$window" =~ ^[0-9]+$ || "$window" -lt 3 ]]; then
        window="5"
    fi

    if [[ ! "$min_step" =~ ^[0-9]+$ || "$min_step" -lt 1 ]]; then
        min_step="3"
    fi

    if [[ -z "$target" ]]; then
        target="$(connected_bssid)"
    fi

    if [[ -z "$target" ]]; then
        result_and_exit 53 FAIL "No tracker target selected." "Pass BSSID: --track AA:BB:CC:DD:EE:FF or connect to the target Wi-Fi first."
    fi

    target="$(normalize_mac "$target" 2>/dev/null || true)"
    if [[ -z "$target" ]]; then
        result_and_exit 54 FAIL "Invalid MAC/BSSID format for tracker target." "Use format AA:BB:CC:DD:EE:FF."
    fi

    status INFO "TRACKER: Monitoring BSSID $target"
    status INFO "TRACKER: Sampling every ${interval}s (moving avg window: ${window}, step threshold: ${min_step})"
    status INFO "TRACKER: Ctrl+C to stop."

    local -a samples=()
    local prev_avg=""
    local trend_state="STABLE"
    local trend_streak=0

    while true; do
        local sig
        sig="$(signal_for_bssid "$target")"

        if [[ -z "$sig" ]]; then
            printf "\r\033[K[WARN] Signal not visible for %s. Move and rescan..." "$target"
            sleep "$interval"
            continue
        fi

        samples+=("$sig")
        if (( ${#samples[@]} > window )); then
            samples=("${samples[@]:1}")
        fi

        local sum=0
        local value
        for value in "${samples[@]}"; do
            ((sum += value))
        done
        local avg=$((sum / ${#samples[@]}))
        local direction="STABLE"
        local hint="HOLD"

        if [[ -n "$prev_avg" ]]; then
            local delta=$((avg - prev_avg))
            if (( delta >= min_step )); then
                direction="CLOSER"
            elif (( delta <= -min_step )); then
                direction="AWAY"
            fi
        fi

        if [[ "$direction" == "$trend_state" && "$direction" != "STABLE" ]]; then
            ((trend_streak += 1))
        else
            trend_state="$direction"
            trend_streak=1
        fi

        if [[ "$direction" == "CLOSER" && "$trend_streak" -ge 2 ]]; then
            hint="MOVING CLOSER"
        elif [[ "$direction" == "AWAY" && "$trend_streak" -ge 2 ]]; then
            hint="MOVING AWAY"
        fi

        local bar_len=$((sig / 2))
        if (( bar_len > 50 )); then
            bar_len=50
        fi
        local bar
        bar="$(printf '%*s' "$bar_len" '' | tr ' ' '#')"
        local empty
        empty="$(printf '%*s' "$((50 - bar_len))" '')"

        printf "\r\033[KSignal: [%-50s] %3s%%  Avg:%3s%%  Trend:%-13s Target:%s" "${bar}${empty}" "$sig" "$avg" "$hint" "$target"
        prev_avg="$avg"
        sleep "$interval"
    done
}

looks_like_personal_router() {
    local gw="$1"

    if [[ -n "$CAMPUS_GATEWAY_REGEX" ]]; then
        if printf "%s\n" "$gw" | grep -Eq "$CAMPUS_GATEWAY_REGEX" 2>/dev/null; then
            return 1
        fi
    fi

    case "$gw" in
        192.168.0.1|192.168.1.1|192.168.50.1|10.0.0.1|10.0.1.1) return 0 ;;
        *) return 1 ;;
    esac
}

check_dns() {
    local domain="$1"

    if command -v nslookup >/dev/null 2>&1; then
        nslookup "$domain" >/dev/null 2>&1
        return $?
    fi

    if command -v host >/dev/null 2>&1; then
        host "$domain" >/dev/null 2>&1
        return $?
    fi

    if command -v dig >/dev/null 2>&1; then
        [[ -n "$(dig +short "$domain" 2>/dev/null | head -n 1)" ]]
        return $?
    fi

    if command -v getent >/dev/null 2>&1; then
        getent ahostsv4 "$domain" >/dev/null 2>&1 || getent hosts "$domain" >/dev/null 2>&1
        return $?
    fi

    return 2
}

detect_gateway() {
    local gw=""

    if command -v ip >/dev/null 2>&1; then
        gw="$(ip route show default 2>/dev/null | awk '/default/ {print $3; exit}')"
    fi

    if [[ -z "$gw" && "$OS_NAME" == "Darwin" ]] && command -v route >/dev/null 2>&1; then
        gw="$(route -n get default 2>/dev/null | awk '/gateway:/{print $2; exit}')"
    fi

    if [[ -z "$gw" ]] && command -v netstat >/dev/null 2>&1; then
        gw="$(netstat -nr 2>/dev/null | awk '$1 == "default" || $1 == "0.0.0.0" {print $2; exit}')"
    fi

    printf "%s" "$gw"
}

ping_once() {
    local host="$1"
    case "$OS_NAME" in
        Darwin|FreeBSD) ping -n -c 1 -W 1000 "$host" >/dev/null 2>&1 ;;
        *) ping -n -c 1 -W 1 "$host" >/dev/null 2>&1 ;;
    esac
}

tcp_probe() {
    local host="$1"
    local port="$2"

    if command -v nc >/dev/null 2>&1; then
        if [[ "$OS_NAME" == "Darwin" ]]; then
            nc -G 2 -z "$host" "$port" >/dev/null 2>&1 || nc -w 2 -z "$host" "$port" >/dev/null 2>&1
        else
            nc -w 2 -z "$host" "$port" >/dev/null 2>&1
        fi
        return $?
    fi

    if command -v timeout >/dev/null 2>&1; then
        timeout 2 bash -c "</dev/tcp/${host}/${port}" >/dev/null 2>&1
        return $?
    fi

    return 1
}

run_trace() {
    if [[ "$TRACE_MODE" == "traceroute" ]]; then
        traceroute -n -q 1 -w 1 -m "$MAX_HOPS" "$TARGET_ICMP" 2>/dev/null
    else
        tracepath -n -m "$MAX_HOPS" "$TARGET_ICMP" 2>/dev/null
    fi
}

classify_trace() {
    local trace_output="$1"
    local hop1=""
    local hop2=""

    if [[ "$TRACE_MODE" == "traceroute" ]]; then
        hop1="$(printf "%s\n" "$trace_output" | awk '$1 == "1" {print; exit}')"
        hop2="$(printf "%s\n" "$trace_output" | awk '$1 == "2" {print; exit}')"

        if [[ -z "$hop1" || "$hop1" == *"* * *"* ]]; then
            return 20
        fi

        if [[ -z "$hop2" || "$hop2" == *"* * *"* ]]; then
            return 21
        fi

        return 22
    fi

    if printf "%s\n" "$trace_output" | awk '$1 ~ /^1\??:/ {found=1} END{exit(found?0:1)}'; then
        return 21
    fi

    return 20
}

if [[ "$TRACK_MODE" == "1" ]]; then
    print_banner
    start_wifi_tracker
fi

print_banner

if ! command -v ping >/dev/null 2>&1; then
    result_and_exit 40 FAIL "This device is missing the ping utility." "Install ping tool (or ask IT support)."
fi

GW="$(detect_gateway)"
if [[ -z "$GW" ]]; then
    result_and_exit 10 FAIL "No active network connection found." "Connect to campus Wi-Fi or Ethernet, then run again."
fi
status OK "LOCAL: Connected. Gateway: $GW"

if looks_like_personal_router "$GW"; then
    ROUTER_SUSPECT=1
    status WARN "Gateway looks like a personal router ($GW). Check WAN cable to wall port."
fi

if ! ping_once "$GW"; then
    result_and_exit 11 FAIL "Connected, but cannot reach your gateway/router." "Check room cable, wall port, Wi-Fi signal, or router power."
fi
status OK "LINK: Gateway reachable."

icmp_ok=0
tcp_ok=0
if ping_once "$TARGET_ICMP"; then
    icmp_ok=1
fi
if tcp_probe "$TARGET_TCP_HOST" "$TARGET_TCP_PORT"; then
    tcp_ok=1
fi

if [[ $icmp_ok -eq 1 || $tcp_ok -eq 1 ]]; then
    status OK "INTERNET: Reachability test passed."
    if [[ $icmp_ok -eq 0 && $tcp_ok -eq 1 ]]; then
        status WARN "ICMP appears filtered, but TCP/443 is working."
    fi

    check_dns "$DNS_TEST_DOMAIN"
    dns_rc=$?
    case "$dns_rc" in
        0) result_and_exit 0 OK "Internet and website name lookup (DNS) are working." "You should be able to browse normally." ;;
        1) result_and_exit 12 WARN "Internet is up, but DNS lookup is failing." "Set DNS to Automatic, or try 1.1.1.1 / 8.8.8.8." ;;
        *) result_and_exit 0 OK "Internet is working." "DNS check tool not found on this device." ;;
    esac
fi

status WARN "INTERNET: Public reachability failed. Running quick path check."
if ! ensure_trace_tool; then
    if [[ $ROUTER_SUSPECT -eq 1 ]]; then
        result_and_exit 30 FAIL "Your router responds, but internet is still down." "Check the router WAN cable to wall port and router internet settings."
    fi
    result_and_exit 30 FAIL "Gateway responds, but internet is still down." "Likely room uplink or campus backend issue. Contact campus IT."
fi

TRACE_OUTPUT="$(run_trace)"
classify_trace "$TRACE_OUTPUT"
trace_rc=$?

case "$trace_rc" in
    20)
        if [[ $ROUTER_SUSPECT -eq 1 ]]; then
            result_and_exit 20 FAIL "Traffic fails near your router/room network." "Check router WAN cable, room wall port, and router reboot."
        fi
        result_and_exit 20 FAIL "Traffic fails near your room connection." "Check cable, wall port, or local Wi-Fi/Ethernet setup."
        ;;
    21)
        if [[ $ROUTER_SUSPECT -eq 1 ]]; then
            result_and_exit 21 FAIL "Your router is reachable, but its uplink likely has a problem." "Reconnect WAN cable from router to wall and test again."
        fi
        result_and_exit 21 FAIL "Local gateway works, but campus/backend uplink may be down." "Report this to campus IT with this result."
        ;;
    *)
        result_and_exit 22 WARN "Local network is okay; issue is likely upstream (ISP/remote service)." "Wait a bit or try another external site."
        ;;
esac
