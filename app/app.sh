#!/usr/bin/env bash
#
# app.sh - Small DevOps utility used to exercise the CI pipeline.
#
# Usage:
#   app.sh system-info                show system information
#   app.sh check-host <host>          validate and resolve a host, then ping it
#   app.sh check-port <host> <port>   validate the port and test TCP connectivity
#   app.sh help                       show usage
#
# Exit codes:
#   0  success
#   1  operational failure (host unresolvable/unreachable, port closed)
#   2  invalid command or input

set -uo pipefail

TIMEOUT_SECS=5
PROG="app.sh"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

usage() {
    cat <<USAGE
Usage: $PROG <command> [arguments]

Commands:
  system-info               Display hostname, user, OS, kernel, uptime, CPU and memory.
  check-host <host>         Validate <host>, resolve it and send ICMP echo requests.
  check-port <host> <port>  Validate <port> (1-65535), resolve <host> and try a TCP connect.
  help                      Show this message.

Exit codes:
  0  success
  1  operational failure (unresolvable or unreachable host, closed port)
  2  invalid command or input
USAGE
}

invalid() {
    printf 'Error: %s\n\n' "$1" >&2
    usage >&2
    exit 2
}

print_row() {
    printf '%-20s %s\n' "$1:" "$2"
}

with_timeout() {
    # Run a command with a time limit; falls back to a watchdog when timeout(1) is absent.
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
        return $?
    fi
    "$@" &
    local pid=$!
    ( sleep "$secs"; kill "$pid" 2>/dev/null ) >/dev/null 2>&1 &
    local watchdog=$!
    wait "$pid" 2>/dev/null
    local rc=$?
    kill "$watchdog" 2>/dev/null
    wait "$watchdog" 2>/dev/null
    return "$rc"
}

# ---------------------------------------------------------------------------
# system-info
# ---------------------------------------------------------------------------

get_os() {
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        ( . /etc/os-release && printf '%s\n' "${PRETTY_NAME:-${NAME:-Linux}}" )
    elif command -v sw_vers >/dev/null 2>&1; then
        printf '%s %s\n' "$(sw_vers -productName)" "$(sw_vers -productVersion)"
    else
        uname -s
    fi
}

get_uptime() {
    if [[ -r /proc/uptime ]]; then
        local secs
        secs=$(cut -d. -f1 /proc/uptime)
        printf '%d days, %d hours, %d minutes\n' \
            $((secs / 86400)) $((secs % 86400 / 3600)) $((secs % 3600 / 60))
    elif uptime -p >/dev/null 2>&1; then
        uptime -p
    else
        uptime | sed -E 's/^.* up +//; s/,[^,]*(user|load).*$//'
    fi
}

get_cpu_model() {
    local model=""
    [[ -r /proc/cpuinfo ]] && \
        model=$(awk -F': *' '/^(model name|Model|Hardware)[[:space:]]*:/ {print $2; exit}' /proc/cpuinfo)
    [[ -z "$model" ]] && command -v lscpu >/dev/null 2>&1 && \
        model=$(lscpu 2>/dev/null | awk -F': *' '/^Model name/ {print $2; exit}')
    [[ -z "$model" ]] && command -v sysctl >/dev/null 2>&1 && \
        model=$(sysctl -n machdep.cpu.brand_string 2>/dev/null)
    printf '%s\n' "${model:-unknown}"
}

get_cpu_count() {
    nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo unknown
}

get_memory() {
    if [[ -r /proc/meminfo ]]; then
        awk '/^MemTotal:/ {t=$2} /^MemAvailable:/ {a=$2}
             END {printf "total %.1f GiB, used %.1f GiB, available %.1f GiB\n",
                  t/1048576, (t-a)/1048576, a/1048576}' /proc/meminfo
    elif command -v free >/dev/null 2>&1; then
        free -m | awk '/^Mem:/ {printf "total %d MiB, used %d MiB, free %d MiB\n", $2, $3, $4}'
    elif command -v sysctl >/dev/null 2>&1; then
        sysctl -n hw.memsize 2>/dev/null | awk '{printf "total %.1f GiB\n", $1/1073741824}'
    else
        echo unknown
    fi
}

cmd_system_info() {
    [[ $# -eq 0 ]] || invalid "'system-info' does not take arguments"
    echo "System information"
    echo "=================="
    print_row "Hostname"         "$(hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || uname -n)"
    print_row "Current user"     "$(id -un 2>/dev/null || echo "${USER:-unknown}")"
    print_row "Date/time"        "$(date '+%Y-%m-%d %H:%M:%S %Z')"
    print_row "Operating system" "$(get_os)"
    print_row "Kernel version"   "$(uname -r)"
    print_row "Architecture"     "$(uname -m)"
    print_row "Uptime"           "$(get_uptime)"
    print_row "CPU model"        "$(get_cpu_model)"
    print_row "CPU cores"        "$(get_cpu_count)"
    print_row "Memory"           "$(get_memory)"
    print_row "Working directory" "$(pwd)"
    return 0
}

# ---------------------------------------------------------------------------
# check-host / check-port
# ---------------------------------------------------------------------------

valid_host() {
    local host="$1"
    [[ ${#host} -le 253 ]] || return 1
    [[ "$host" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] && return 0
    [[ "$host" =~ ^[0-9A-Fa-f:]+$ && "$host" == *:* ]] && return 0
    return 1
}

valid_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    port=$((10#$port))
    (( port >= 1 && port <= 65535 ))
}

resolve_host() {
    # Print one address (IPv4 preferred). The system resolver is authoritative when present.
    local host="$1" addr=""
    if command -v getent >/dev/null 2>&1; then
        addr=$(with_timeout "$TIMEOUT_SECS" getent ahosts "$host" 2>/dev/null \
               | awk '$1 ~ /^[0-9.]+$/ && !v4 {v4=$1} NR==1 {first=$1} END {print (v4 != "" ? v4 : first)}')
    elif command -v dscacheutil >/dev/null 2>&1; then
        addr=$(with_timeout "$TIMEOUT_SECS" dscacheutil -q host -a name "$host" 2>/dev/null \
               | awk '/^ip_address:/ {v4=$2} /^ipv6_address:/ {v6=$2} END {print (v4 != "" ? v4 : v6)}')
    elif command -v dig >/dev/null 2>&1; then
        addr=$(dig +short +time=3 +tries=1 "$host" A 2>/dev/null | grep -E '^[0-9.]+$' | head -n 1)
    elif command -v python3 >/dev/null 2>&1; then
        addr=$(with_timeout "$TIMEOUT_SECS" python3 -c \
               'import socket, sys; print(socket.getaddrinfo(sys.argv[1], None)[0][4][0])' "$host" 2>/dev/null)
    fi
    [[ -n "$addr" ]] && printf '%s\n' "$addr"
}

ping_host() {
    local host="$1"
    if [[ "$(uname -s)" == "Darwin" ]]; then
        ping -c 2 -t "$TIMEOUT_SECS" "$host"
    else
        ping -c 2 -W "$TIMEOUT_SECS" "$host"
    fi
}

tcp_check() {
    local addr="$1" port="$2"
    # shellcheck disable=SC2016  # $0/$1 are expanded by the inner bash, on purpose
    with_timeout "$TIMEOUT_SECS" bash -c 'exec 3<>"/dev/tcp/$0/$1"' "$addr" "$port" 2>/dev/null
}

cmd_check_host() {
    [[ $# -ge 1 ]] || invalid "'check-host' requires a host argument"
    [[ $# -le 1 ]] || invalid "'check-host' accepts exactly one argument"
    local host="$1" addr

    valid_host "$host" || invalid "'$host' is not a valid hostname or IP address"

    echo "Checking host: $host"
    if addr=$(resolve_host "$host") && [[ -n "$addr" ]]; then
        print_row "Resolved address" "$addr"
    else
        echo "Could not resolve '$host'" >&2
        echo "RESULT: FAILED (name resolution)"
        return 1
    fi

    if ! command -v ping >/dev/null 2>&1; then
        print_row "Ping" "skipped (ping not installed)"
        echo "RESULT: OK (resolved only)"
        return 0
    fi
    if ping_host "$host" >/dev/null 2>&1; then
        print_row "Ping" "reachable"
        echo "RESULT: OK"
        return 0
    print_row "Ping" "no reply (host down or ICMP filtered)"
    echo "RESULT: FAILED (unreachable)"
    return 1
}

cmd_check_port() {
    [[ $# -ge 2 ]] || invalid "'check-port' requires a host and a port"
    [[ $# -le 2 ]] || invalid "'check-port' accepts exactly two arguments"
    local host="$1" port="$2" addr

    valid_host "$host" || invalid "'$host' is not a valid hostname or IP address"
    valid_port "$port" || invalid "port '$port' must be a whole number between 1 and 65535"
    port=$((10#$port))

    echo "Checking TCP port $port on $host"
    if addr=$(resolve_host "$host") && [[ -n "$addr" ]]; then
        print_row "Resolved address" "$addr"
    else
        echo "Could not resolve '$host'" >&2
        echo "RESULT: FAILED (name resolution)"
        return 1
    fi

    if tcp_check "$addr" "$port"; then
        print_row "TCP port $port" "OPEN"
        echo "RESULT: OK"
        return 0
    fi
    print_row "TCP port $port" "CLOSED or unreachable"
    echo "RESULT: FAILED (connection)"
    return 1
}

# ---------------------------------------------------------------------------
# Dispatcher
# ---------------------------------------------------------------------------

main() {
    [[ $# -ge 1 ]] || invalid "no command given"
    local command="$1"
    shift
    case "$command" in
        system-info)    cmd_system_info "$@" ;;
        check-host)     cmd_check_host "$@" ;;
        check-port)     cmd_check_port "$@" ;;
        help|-h|--help) usage ;;
        *)              invalid "unknown command '$command'" ;;
    esac
}

main "$@"
