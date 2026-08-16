#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT=$(mktemp -d)
FAKE_BIN="$TEST_ROOT/bin"
PREFIX="$TEST_ROOT/prefix"
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
    */tags\?per_page=100) printf '[{"name":"v7.0.1"}]\n' ;;
    */releases/download/*) exit 22 ;;
    */v7.0.1/net-tcp-tune.sh) cp "$FIXTURE_ROOT/net-tcp-tune.sh" "$output" ;;
    */v7.0.1/SHA256SUMS)
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
"$PREFIX/bbr" version | grep -Fq 'v7.0.1' || { echo "FAIL: installed version mismatch" >&2; exit 1; }
echo "installer tests: OK"
