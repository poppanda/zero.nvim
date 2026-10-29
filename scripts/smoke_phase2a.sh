#!/usr/bin/env bash
# Phase 2A 端到端 smoke 测试
# 用法:
#   bash scripts/smoke_phase2a.sh <user> <host> <port> <remote_path>
#   或通过环境变量:
#   ZERO_TEST_USER=me ZERO_TEST_HOST=dev.example.com [ZERO_TEST_PORT=22] \
#   ZERO_TEST_PATH=/home/me/repo/file.c bash scripts/smoke_phase2a.sh
# 可选: ZERO_GITSIGNS_ROOT=/path/to/gitsigns-fork（默认 ../gitsigns.nvim）
set -e

if [ "$#" -ne 0 ] && [ "$#" -ne 4 ]; then
    echo "usage: $0 <user> <host> <port> <remote_path>" >&2
    echo "   or: ZERO_TEST_USER=... ZERO_TEST_HOST=... [ZERO_TEST_PORT=22] ZERO_TEST_PATH=... $0" >&2
    exit 2
fi
if [ "$#" -eq 0 ] && { [ -z "${ZERO_TEST_USER:-}" ] || [ -z "${ZERO_TEST_HOST:-}" ] || [ -z "${ZERO_TEST_PATH:-}" ]; }; then
    echo "usage: $0 <user> <host> <port> <remote_path>" >&2
    echo "   or: ZERO_TEST_USER=... ZERO_TEST_HOST=... [ZERO_TEST_PORT=22] ZERO_TEST_PATH=... $0" >&2
    echo "missing ZERO_TEST_USER / ZERO_TEST_HOST / ZERO_TEST_PATH" >&2
    exit 2
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec nvim --headless -u NONE -l "$ROOT/scripts/smoke_phase2a.lua" "$@"
