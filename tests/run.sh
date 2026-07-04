#!/usr/bin/env bash
# Test runner for git-native-agents.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Running git-native-agents test suite..."
echo ""

bash "$SCRIPT_DIR/concurrency.sh"

echo ""
echo "All tests passed."
