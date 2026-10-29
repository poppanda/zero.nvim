#!/usr/bin/env bash
# Phase 3A 本地 headless smoke（不连远端，只验证 fork neogit 的 backends 抽象 +
# zero-nvim 端 backend 注册路径）
#
# 用法: bash scripts/smoke_phase3a.sh
#
# 环境变量（可选）：
#   ZERO_NEOGIT_ROOT  fork neogit 路径（默认 <repo>/../neogit）
#   ZERO_PLENARY_ROOT plenary.nvim 路径（默认 ~/.local/share/nvim/lazy/plenary.nvim）
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NEOGIT_FORK="${ZERO_NEOGIT_ROOT:-$ROOT/../neogit}"
PLENARY="${ZERO_PLENARY_ROOT:-$HOME/.local/share/nvim/lazy/plenary.nvim}"

if [ ! -d "$NEOGIT_FORK" ]; then
    echo "[FAIL] neogit fork not found at $NEOGIT_FORK (set ZERO_NEOGIT_ROOT)" >&2
    exit 2
fi
if [ ! -d "$PLENARY" ]; then
    echo "[FAIL] plenary.nvim not found at $PLENARY (set ZERO_PLENARY_ROOT)" >&2
    exit 2
fi

exec nvim --headless --clean -u NONE \
    --cmd "set rtp+=$ROOT" \
    --cmd "set rtp+=$NEOGIT_FORK" \
    --cmd "set rtp+=$PLENARY" \
    -l "$ROOT/scripts/smoke_phase3a.lua"
