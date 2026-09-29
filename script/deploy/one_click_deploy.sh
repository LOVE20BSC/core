#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/00_init.sh" "${1:-}" || exit 1
source "$SCRIPT_DIR/01_deploy.sh" || exit 1
source "$SCRIPT_DIR/99_check.sh" || exit 1
echo "✓ Deployment completed: $network"
