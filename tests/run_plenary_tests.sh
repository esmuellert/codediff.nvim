#!/usr/bin/env bash
# Test runner for vscode-diff.nvim using plenary.nvim

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║          vscode-diff.nvim Test Suite (Plenary)               ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

cd "$PROJECT_ROOT"

# Run all spec files
FAILED=0

# Test files
SPEC_FILES=(
  "tests/ffi_integration_spec.lua"
  "tests/installer_spec.lua"
  "tests/timeout_spec.lua"
  "tests/git_integration_spec.lua"
  "tests/completion_spec.lua"
  "tests/autoscroll_spec.lua"
  "tests/explorer_spec.lua"
  "tests/explorer_staging_spec.lua"
  "tests/render/semantic_tokens_spec.lua"
  "tests/render/core_spec.lua"
  "tests/render/lifecycle_spec.lua"
  "tests/render/view_spec.lua"
  "tests/integration_diagnostics_spec.lua"
  "tests/full_integration_spec.lua"
)

for spec_file in "${SPEC_FILES[@]}"; do
  echo -e "${CYAN}Running: $spec_file${NC}"
  if nvim --headless --noplugin -u tests/init.lua \
    -c "lua require('plenary.test_harness').test_file('$spec_file', { minimal_init = '$PROJECT_ROOT/tests/init.lua' })" 2>&1; then
    echo ""
  else
    echo -e "${RED}✗ $spec_file failed${NC}"
    FAILED=$((FAILED + 1))
    echo ""
  fi
done

# Summary
echo "╔══════════════════════════════════════════════════════════════╗"
if [ $FAILED -eq 0 ]; then
  echo -e "║ ${GREEN}✓ ALL TESTS PASSED${NC}                                           ║"
  echo "╚══════════════════════════════════════════════════════════════╝"
  exit 0
else
  echo -e "║ ${RED}✗ $FAILED TEST(S) FAILED${NC}                                        ║"
  echo "╚══════════════════════════════════════════════════════════════╝"
  exit 1
fi
