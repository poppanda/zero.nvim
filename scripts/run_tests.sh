#!/usr/bin/env bash
# 运行 tests/test_*.lua（headless，无网络）。
# 用法:
#   bash scripts/run_tests.sh                 # 全部
#   bash scripts/run_tests.sh tests/test_x.lua  # 指定文件
# 环境变量:
#   NVIM=/path/to/nvim  指定 nvim 可执行文件（默认 PATH 里的 nvim）
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 2
NVIM="${NVIM:-nvim}"

if ! command -v "$NVIM" >/dev/null 2>&1; then
    echo "run_tests: nvim not found (set NVIM=/path/to/nvim)" >&2
    exit 2
fi

if [ "$#" -gt 0 ]; then
    files=("$@")
else
    shopt -s nullglob
    files=(tests/test_*.lua)
fi

if [ "${#files[@]}" -eq 0 ]; then
    echo "run_tests: no tests found"
    exit 0
fi

pass=0
failed=()
for f in "${files[@]}"; do
    out="$("$NVIM" --headless -u NONE -i NONE -n --cmd "set rtp^=$ROOT" -l "$f" 2>&1 </dev/null)"
    code=$?
    if [ "$code" -eq 0 ]; then
        pass=$((pass + 1))
        echo "[PASS] $f"
    else
        failed+=("$f")
        echo "[FAIL] $f (exit $code)"
        printf '%s\n' "$out" | sed 's/^/    /'
    fi
done

echo ""
echo "$pass passed, ${#failed[@]} failed"
[ "${#failed[@]}" -eq 0 ]
