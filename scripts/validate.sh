#!/bin/bash
# 本地/CI 验证入口：语法检查 + 可选 shellcheck
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "==> Bash syntax check"
bash -n net-tcp-tune.sh
bash -n install-alias.sh
bash -n scripts/validate.sh

echo "==> Version marker"
grep -n 'SCRIPT_VERSION=' net-tcp-tune.sh | head -1

echo "==> ShellCheck (optional)"
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -S error net-tcp-tune.sh install-alias.sh scripts/validate.sh
else
    echo "shellcheck not available; skipped"
fi

echo "==> All checks passed"
