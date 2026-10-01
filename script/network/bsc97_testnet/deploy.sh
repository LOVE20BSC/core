#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
echo "BSC 测试网部署统一使用 script/network/bsc97_dev 的配置和 .account。"
exec bash "$CORE_DIR/script/deploy/one_click_deploy.sh" bsc97_dev
