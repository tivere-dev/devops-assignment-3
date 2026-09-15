#!/usr/bin/env bash
#
# test.sh - Test suite for app/app.sh, run by the CI "test" job.
#
# Each test asserts an exit code and, where useful, the output. A non-zero exit
# from this script means at least one test failed. Tests that need a helper
# (python3 for a local TCP listener) are skipped, not failed, when it is missing.

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
APP="./app/app.sh"

passed=0
failed=0
skipped=0
last_output=""
last_rc=0

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

pass() { echo "PASS: $1"; passed=$((passed + 1)); }
fail() { echo "FAIL: $1"; failed=$((failed + 1)); }
skip() { echo "SKIP: $1"; skipped=$((skipped + 1)); }

run_app() {
    last_output=$("$APP" "$@" 2>&1)
    last_rc=$?
}

expect_exit() {
    # expect_exit <description> <expected-code> [app args...]
    local desc="$1" expected="$2"; shift 2
    run_app "$@"
    if [[ "$last_rc" -eq "$expected" ]]; then
        pass "$desc (exit $last_rc)"
    else
        fail "$desc (expected exit $expected, got $last_rc)"
        printf '%s\n' "$last_output" | sed 's/^/    | /'
    fi
}

expect_output() {
    # expect_output <description> <regex>  -- inspects the output of the last run_app
    local desc="$1" pattern="$2"
    if grep -Eqi -- "$pattern" <<< "$last_output"; then
        pass "$desc"
    else
        fail "$desc (pattern '$pattern' not found)"
        printf '%s\n' "$last_output" | sed 's/^/    | /'
    fi
}

free_port() {
    # Ask the OS for an unused TCP port.
    python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])' 2>/dev/null
}

listener_pid=""
listener_port=""

start_listener() {
    # Start a TCP listener on 127.0.0.1 in the background and record its port.
    local port_file
    port_file=$(mktemp) || return 1
    python3 -c 'import socket, time
s = socket.socket()
s.bind(("127.0.0.1", 0))
s.listen(5)
print(s.getsockname()[1], flush=True)
time.sleep(60)' > "$port_file" 2>/dev/null &
    listener_pid=$!
    local _attempt  # loop counter only
    for _attempt in $(seq 1 50); do
        listener_port=$(cat "$port_file")
        [[ -n "$listener_port" ]] && break
        sleep 0.1
    done
    rm -f "$port_file"
    [[ "$listener_port" =~ ^[0-9]+$ ]]
}

stop_listener() {
    [[ -n "$listener_pid" ]] && kill "$listener_pid" 2>/dev/null
    wait "$listener_pid" 2>/dev/null
    listener_pid=""
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

echo "Running app.sh tests"
echo "----------------------------------------"

# 1. help
expect_exit "help exits 0" 0 help
expect_output "help prints usage" '^Usage:'
expect_output "help lists all commands" 'check-port'
expect_output "help documents exit codes" 'Exit codes'

# 2. system-info
expect_exit "system-info exits 0" 0 system-info
expect_output "system-info shows hostname" 'Hostname:'
expect_output "system-info shows kernel" 'Kernel version:'
expect_output "system-info shows uptime" 'Uptime:'
expect_output "system-info shows memory" 'Memory:'
expect_exit "system-info rejects extra arguments" 2 system-info extra

# 3. invalid commands
expect_exit "no command exits 2" 2
expect_exit "unknown command exits 2" 2 invalid-command
expect_output "unknown command reports the problem" 'unknown command'
expect_exit "empty command exits 2" 2 ""

# 4. missing host
expect_exit "check-host without host exits 2" 2 check-host
expect_exit "check-host rejects malformed host" 2 check-host "bad host!"
expect_exit "check-host rejects too many arguments" 2 check-host localhost extra

# 5. valid host
expect_exit "check-host localhost exits 0" 0 check-host localhost
expect_output "check-host shows resolved address" 'Resolved address:'
expect_exit "check-host 127.0.0.1 exits 0" 0 check-host 127.0.0.1
expect_exit "check-host unresolvable host is an operational failure (1)" 1 check-host nonexistent.invalid

# 6. missing port
expect_exit "check-port without arguments exits 2" 2 check-port
expect_exit "check-port without port exits 2" 2 check-port localhost
expect_exit "check-port rejects too many arguments" 2 check-port localhost 80 extra

# 7. non-numeric port
expect_exit "check-port rejects non-numeric port" 2 check-port localhost abc
expect_exit "check-port rejects decimal port" 2 check-port localhost 1.5
expect_exit "check-port rejects negative port" 2 check-port localhost -1
expect_exit "check-port rejects malformed host" 2 check-port "bad host!" 80

# 8. out-of-range ports
expect_exit "check-port rejects port 0" 2 check-port localhost 0
expect_exit "check-port rejects port 65536" 2 check-port localhost 65536
expect_exit "check-port rejects port 99999" 2 check-port localhost 99999

# 9. real TCP behaviour (needs python3 for a local listener)
if command -v python3 >/dev/null 2>&1; then
    if start_listener; then
        expect_exit "check-port reports an open local port as OK" 0 check-port 127.0.0.1 "$listener_port"
        expect_output "check-port says the port is open" 'OPEN'
    else
        skip "open-port test (could not start local listener)"
    fi
    stop_listener

    closed_port=$(free_port)
    if [[ "$closed_port" =~ ^[0-9]+$ ]]; then
        expect_exit "check-port reports a closed port as operational failure (1)" 1 check-port 127.0.0.1 "$closed_port"
        expect_output "check-port says the port is closed" 'CLOSED'
    else
        skip "closed-port test (could not find a free port)"
    fi
else
    skip "open/closed port tests (python3 not available)"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo "----------------------------------------"
echo "Passed: $passed  Failed: $failed  Skipped: $skipped"
if (( failed > 0 )); then
    echo "TESTS FAILED"
    exit 1
fi
echo "ALL TESTS PASSED"
exit 0
