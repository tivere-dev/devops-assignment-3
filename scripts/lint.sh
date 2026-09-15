#!/usr/bin/env bash
#
# lint.sh - Static validation used by the CI "validate" job.
#
# 1. Checks that every required project file exists.
# 2. Runs `bash -n` (syntax check) on every Bash script.
# 3. Runs ShellCheck when it is installed (skipped with a notice otherwise).
#
# Exit codes: 0 all checks passed, 1 at least one check failed.

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

REQUIRED_FILES=(
    README.md
    app/app.sh
    scripts/lint.sh
    scripts/build.sh
    tests/test.sh
    Dockerfile
    compose.yaml
    .dockerignore
    .github/workflows/ci.yml
)
BASH_SCRIPTS=(app/*.sh scripts/*.sh tests/*.sh)

errors=0
ok()   { echo "ok   : $1"; }
fail() { echo "FAIL : $1"; errors=$((errors + 1)); }

echo "== Required files =="
for f in "${REQUIRED_FILES[@]}"; do
    if [[ -f "$f" ]]; then ok "$f"; else fail "missing $f"; fi
done

echo
echo "== Bash syntax (bash -n) =="
for f in "${BASH_SCRIPTS[@]}"; do
    [[ -f "$f" ]] || continue
    if output=$(bash -n "$f" 2>&1); then
        ok "$f"
    else
        fail "$f"
        printf '%s\n' "$output" | sed 's/^/       /'
    fi
done

echo
echo "== Executable bits =="
for f in app/app.sh scripts/lint.sh scripts/build.sh tests/test.sh; do
    if [[ -x "$f" ]]; then ok "$f"; else fail "$f is not executable (chmod +x $f)"; fi
done

echo
echo "== ShellCheck =="
if command -v shellcheck >/dev/null 2>&1; then
    if shellcheck "${BASH_SCRIPTS[@]}"; then
        ok "shellcheck found no issues"
    else
        fail "shellcheck reported issues"
    fi
else
    echo "skip : shellcheck is not installed (optional check)"
fi

echo
if (( errors > 0 )); then
    echo "LINT FAILED: $errors problem(s)"
    exit 1
fi
echo "LINT PASSED"
exit 0
