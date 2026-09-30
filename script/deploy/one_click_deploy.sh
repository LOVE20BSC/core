#!/usr/bin/env bash

# 避免 VSCode 终端集成的提示符错误
unset __vsc_update_prompt 2>/dev/null || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# 切换到项目根目录执行
cd "$PROJECT_ROOT"

source "$SCRIPT_DIR/00_init.sh" "${1:-}" || exit 1
source "$SCRIPT_DIR/01_deploy.sh" || exit 1
source "$SCRIPT_DIR/99_check.sh" || exit 1
echo "✓ Deployment completed: $network"
