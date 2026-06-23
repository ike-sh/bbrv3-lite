#!/bin/bash
# 本地/CI 验证入口：语法检查 + 可选 shellcheck
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "==> Bash syntax check"
bash -n net-tcp-tune.sh
bash -n install-alias.sh
bash -n bbrv3arm.sh
bash -n scripts/validate.sh

echo "==> Version marker"
grep -m1 -n 'SCRIPT_VERSION=' net-tcp-tune.sh

echo "==> Kernel install safety guards"
grep -q 'check_secure_boot_before_kernel_install()' net-tcp-tune.sh
grep -q 'guard_apt_install_keeps_network_stack()' net-tcp-tune.sh
grep -q 'verify_network_stack_after_kernel_install()' net-tcp-tune.sh

echo "==> ShellCheck (optional)"
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -S error net-tcp-tune.sh install-alias.sh bbrv3arm.sh scripts/validate.sh
else
    echo "shellcheck not available; skipped"
fi

echo "==> All checks passed"
