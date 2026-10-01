#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# 切换到项目根目录执行
cd "$PROJECT_ROOT"

source "$SCRIPT_DIR/00_init.sh" "${1:-}"
source "$SCRIPT_DIR/01_deploy.sh"
echo "✓ Deployment completed: $network"
