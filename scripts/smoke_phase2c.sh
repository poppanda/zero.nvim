#!/usr/bin/env bash
# Phase 2C 本地 headless smoke（不需要远端，只验 refresh 模块行为）
# 用法: bash scripts/smoke_phase2c.sh
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec nvim --headless -u NONE -l "$ROOT/scripts/smoke_phase2c.lua"
