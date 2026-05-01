#!/usr/bin/env bash
# Phase 2A 端到端 smoke 测试
# 用法:
#   bash scripts/smoke_phase2a.sh <user> <host> <port> <remote_path>
# 例:
#   bash scripts/smoke_phase2a.sh home 47.117.104.181 22022 /home/home/Code/2025-code-craft-preliminary/code/disk.cpp
set -e

if [ "$#" -ne 4 ]; then
    echo "usage: $0 <user> <host> <port> <remote_path>"
    exit 2
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec nvim --headless -u NONE -l "$ROOT/scripts/smoke_phase2a.lua" "$@"
