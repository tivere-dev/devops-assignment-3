#!/usr/bin/env bash
#
# build.sh - Build the Docker image and run smoke tests against it.
#
# Usage: ./scripts/build.sh [--clean]
#   --clean   remove the image after the smoke tests
#
# Environment:
#   IMAGE   image tag to build (default: devops-tool)
#
# Exit codes: 0 image built and all smoke tests passed, 1 otherwise.

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

IMAGE="${IMAGE:-devops-tool}"
CLEAN=0
[[ "${1:-}" == "--clean" ]] && CLEAN=1

failures=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }

smoke() {
    # smoke <description> <expected-exit-code> [app args...]
    local desc="$1" expected="$2"; shift 2
    local output rc
    output=$(docker run --rm "$IMAGE" "$@" 2>&1)
    rc=$?
    if [[ "$rc" -eq "$expected" ]]; then
        pass "$desc (exit $rc)"
    else
        fail "$desc (expected exit $expected, got $rc)"
        printf '%s\n' "$output" | sed 's/^/    | /'
    fi
}

if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: docker is not installed or not on PATH" >&2
    exit 1
fi
if ! docker info >/dev/null 2>&1; then
    echo "ERROR: the Docker daemon is not reachable" >&2
    exit 1
fi

echo "== Building $IMAGE =="
if ! docker build -t "$IMAGE" .; then
    echo "ERROR: docker build failed" >&2
    exit 1
fi

echo
echo "== Smoke tests =="
smoke "help succeeds" 0 help
smoke "default command prints help" 0
smoke "system-info succeeds" 0 system-info
smoke "invalid command fails with exit 2" 2 invalid-command
smoke "missing command fails with exit 2" 2 ""
smoke "check-port rejects a bad port" 2 check-port localhost abc

# Capture first, then match: piping into grep -q would trip pipefail when grep
# exits early and the producer receives SIGPIPE.
info_output=$(docker run --rm "$IMAGE" system-info 2>&1)
if [[ "$info_output" =~ [Kk]ernel ]]; then
    pass "system-info output contains kernel information"
else
    fail "system-info output lacks kernel information"
fi

if (( CLEAN == 1 )); then
    docker image rm "$IMAGE" >/dev/null 2>&1 || true
    echo "Removed image $IMAGE"
fi

echo
if (( failures > 0 )); then
    echo "BUILD FAILED: $failures smoke test(s) failed"
    exit 1
fi
echo "BUILD OK: image $IMAGE built and smoke tests passed"
exit 0
