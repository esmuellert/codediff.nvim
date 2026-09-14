#!/usr/bin/env bash
# Discovery, selection and workers are shared with Windows in framework/supervisor.lua.
# CODEDIFF_TEST_TARGET is overridden by an explicit positional target.
# CODEDIFF_TEST_JOBS and CODEDIFF_TEST_TIMEOUT control workers and per-spec budgets.
set -euo pipefail

usage() {
  printf 'Usage: %s [all|unit|integration|e2e|directory|spec]\n' "${0##*/}"
  printf 'Examples: %s e2e; %s tests/integration/core/git\n' "${0##*/}" "${0##*/}"
}

if (( $# > 1 )); then
  usage
  exit 2
fi
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

export CODEDIFF_TEST_TARGET="${1:-${CODEDIFF_TEST_TARGET:-all}}"
exec nvim --headless --noplugin -u tests/init.lua \
  -c "lua require('tests.framework').run_all_and_exit()"
