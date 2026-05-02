#!/usr/bin/env bash
# Phase 3A 本地 headless smoke（不连远端，只验证 fork neogit 的 backends 抽象 +
# zero-nvim 端 backend 注册路径）
#
# 用法: bash scripts/smoke_phase3a.sh
#
# 环境前提：
#   * fork neogit 在 ~/Code/Neovim/neogit
#   * plenary.nvim 在 ~/.local/share/nvim/lazy/plenary.nvim
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NEOGIT_FORK="$HOME/Code/Neovim/neogit"
PLENARY="$HOME/.local/share/nvim/lazy/plenary.nvim"

if [ ! -d "$NEOGIT_FORK" ]; then
    echo "[FAIL] neogit fork not found at $NEOGIT_FORK"
    exit 1
fi
if [ ! -d "$PLENARY" ]; then
    echo "[FAIL] plenary.nvim not found at $PLENARY"
    exit 1
fi

exec nvim --headless --clean -u NONE \
    --cmd "set rtp+=$ROOT" \
    --cmd "set rtp+=$NEOGIT_FORK" \
    --cmd "set rtp+=$PLENARY" \
    -l "$ROOT/scripts/smoke_phase3a.lua"
