#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT=$(mktemp -d)
FAKE_BIN="$TEST_ROOT/bin"
PREFIX="$TEST_ROOT/prefix"
RUN_PREFIX="$TEST_ROOT/run-prefix"
mkdir -p "$FAKE_BIN"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

cat > "$FAKE_BIN/curl" <<'EOF'
#!/usr/bin/env bash
set -u
output="" url=""
while (($#)); do
    case "$1" in
        -o) output="$2"; shift 2 ;;
        --connect-timeout|--max-time) shift 2 ;;
        -*) shift ;;
        *) url="$1"; shift ;;
    esac
done
case "$url" in
    */releases/latest) exit 22 ;;
    */tags\?per_page=100) printf '[{"name":"v7.2.0"}]\n' ;;
    */releases/download/*) exit 22 ;;
    */v7.2.0/net-tcp-tune.sh) cp "$FIXTURE_ROOT/net-tcp-tune.sh" "$output" ;;
    */v7.2.0/SHA256SUMS)
        hash=$(sha256sum "$FIXTURE_ROOT/net-tcp-tune.sh" | awk '{print $1}')
        printf '%s  net-tcp-tune.sh\n' "$hash" > "$output"
        ;;
    *) printf 'unexpected URL: %s\n' "$url" >&2; exit 2 ;;
esac
EOF
chmod 0755 "$FAKE_BIN/curl"

output=$(PATH="$FAKE_BIN:$PATH" FIXTURE_ROOT="$ROOT_DIR" bash "$ROOT_DIR/install-alias.sh" --prefix "$PREFIX" 2>&1)
[[ -x "$PREFIX/bbr" ]] || { echo "FAIL: installer did not create bbr" >&2; exit 1; }
grep -Fq 'falling back to immutable tag' <<< "$output" || { echo "FAIL: tag fallback was not reported" >&2; exit 1; }
"$PREFIX/bbr" version | grep -Fq 'v7.2.0' || { echo "FAIL: installed version mismatch" >&2; exit 1; }
run_output=$(PATH="$FAKE_BIN:$PATH" FIXTURE_ROOT="$ROOT_DIR" bash "$ROOT_DIR/install-alias.sh" --prefix "$RUN_PREFIX" --run 2>&1)
grep -Fq 'bbrv3-lite v7.2.0' <<< "$run_output" || { echo "FAIL: --run did not execute installed command" >&2; exit 1; }
mkdir -p "$TEST_ROOT/home"
cat > "$TEST_ROOT/home/.bashrc" <<'EOF'
keep
# ================ net-tcp-tune 快捷别名 ================
bbr() { echo legacy; }
# ================ net-tcp-tune 快捷别名结束 ================
EOF
HOME="$TEST_ROOT/home" bash "$ROOT_DIR/install-alias.sh" uninstall --prefix "$PREFIX" >/dev/null
[[ ! -e "$PREFIX/bbr" ]] || { echo "FAIL: installer uninstall left bbr command" >&2; exit 1; }
grep -Fq keep "$TEST_ROOT/home/.bashrc" || { echo "FAIL: installer uninstall damaged shell rc" >&2; exit 1; }
if grep -Fq 'net-tcp-tune 快捷别名' "$TEST_ROOT/home/.bashrc"; then echo "FAIL: installer uninstall left legacy shell function" >&2; exit 1; fi

FOREIGN_PREFIX="$TEST_ROOT/foreign-prefix"
mkdir -p "$FOREIGN_PREFIX"
printf '#!/usr/bin/env bash\necho foreign\n' > "$FOREIGN_PREFIX/bbr"
chmod 0755 "$FOREIGN_PREFIX/bbr"
if PATH="$FAKE_BIN:$PATH" FIXTURE_ROOT="$ROOT_DIR" bash "$ROOT_DIR/install-alias.sh" --prefix "$FOREIGN_PREFIX" >/dev/null 2>&1; then
    echo "FAIL: installer overwrote an unmanaged bbr file" >&2; exit 1
fi
grep -Fq 'echo foreign' "$FOREIGN_PREFIX/bbr" || { echo "FAIL: foreign bbr content changed" >&2; exit 1; }
if HOME="$TEST_ROOT/home" bash "$ROOT_DIR/install-alias.sh" uninstall --prefix "$FOREIGN_PREFIX" >/dev/null 2>&1; then
    echo "FAIL: installer removed an unmanaged bbr file" >&2; exit 1
fi
[[ -e "$FOREIGN_PREFIX/bbr" ]] || { echo "FAIL: foreign bbr file disappeared" >&2; exit 1; }

if bash "$ROOT_DIR/install-alias.sh" --prefix >/dev/null 2>&1; then echo "FAIL: missing installer option value accepted" >&2; exit 1; fi
if bash "$ROOT_DIR/install-alias.sh" uninstall --run --prefix "$PREFIX" >/dev/null 2>&1; then echo "FAIL: uninstall accepted --run" >&2; exit 1; fi
if bash "$ROOT_DIR/install-alias.sh" --prefix relative/path >/dev/null 2>&1; then echo "FAIL: relative prefix accepted" >&2; exit 1; fi
if bash "$ROOT_DIR/install-alias.sh" --prefix "$PREFIX" --prefix "$PREFIX" >/dev/null 2>&1; then echo "FAIL: duplicate prefix accepted" >&2; exit 1; fi
echo "installer tests: OK"
