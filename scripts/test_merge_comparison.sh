#!/usr/bin/env bash
# Merge Alignment Comparison Test Script
# Compares merge alignment results between VSCode and our Lua implementation
#
# Usage: ./test_merge_comparison.sh <conflict_file>           # Extract from git merge conflict
#        ./test_merge_comparison.sh <base> <input1> <input2>  # Use three explicit files
#        ./test_merge_comparison.sh                           # Auto-detect from ~/vscode-merge-test

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Create secure temporary directory
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║        Merge Alignment Comparison Test                       ║"
echo "║        VSCode vs Lua Implementation                          ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# Parse arguments
BASE_FILE=""
INPUT1_FILE=""
INPUT2_FILE=""

extract_conflict() {
    local file_path="$1"
    local repo_dir
    
    # Get absolute path and find git root
    file_path="$(cd "$(dirname "$file_path")" && pwd)/$(basename "$file_path")"
    repo_dir="$(cd "$(dirname "$file_path")" && git rev-parse --show-toplevel 2>/dev/null)" || {
        echo -e "${RED}Error: $file_path is not in a git repository${NC}"
        exit 1
    }
    
    # Get relative path from repo root
    local rel_path="${file_path#$repo_dir/}"
    
    cd "$repo_dir"
    
    # Check if merge in progress
    if ! git rev-parse MERGE_HEAD >/dev/null 2>&1; then
        echo -e "${RED}Error: No merge in progress in $repo_dir${NC}"
        exit 1
    fi
    
    # Extract three versions to secure temp directory
    BASE_FILE="$TEMP_DIR/base.txt"
    INPUT1_FILE="$TEMP_DIR/current.txt"
    INPUT2_FILE="$TEMP_DIR/incoming.txt"
    
    git show ":1:$rel_path" > "$BASE_FILE" 2>/dev/null || { echo -e "${RED}Failed to extract base version${NC}"; exit 1; }
    git show ":2:$rel_path" > "$INPUT1_FILE" 2>/dev/null || { echo -e "${RED}Failed to extract current version${NC}"; exit 1; }
    git show ":3:$rel_path" > "$INPUT2_FILE" 2>/dev/null || { echo -e "${RED}Failed to extract incoming version${NC}"; exit 1; }
    
    echo -e "${GREEN}Extracted: $rel_path${NC}"
}

if [ $# -eq 3 ]; then
    # Three files: base, input1, input2
    BASE_FILE="$1"
    INPUT1_FILE="$2"
    INPUT2_FILE="$3"
elif [ $# -eq 1 ]; then
    # Single file: extract from git merge conflict
    if [ ! -f "$1" ]; then
        echo -e "${RED}Error: File not found: $1${NC}"
        exit 1
    fi
    extract_conflict "$1"
elif [ $# -eq 0 ]; then
    # Auto-detect from ~/vscode-merge-test
    MERGE_TEST_DIR="$HOME/vscode-merge-test"
    if [ -d "$MERGE_TEST_DIR/.git" ]; then
        cd "$MERGE_TEST_DIR"
        if git rev-parse MERGE_HEAD >/dev/null 2>&1; then
            CONFLICT_FILE=$(git diff --name-only --diff-filter=U | head -1)
            if [ -n "$CONFLICT_FILE" ]; then
                extract_conflict "$MERGE_TEST_DIR/$CONFLICT_FILE"
            else
                echo -e "${RED}No conflicted files in $MERGE_TEST_DIR${NC}"
                exit 1
            fi
        else
            echo -e "${RED}No merge in progress in $MERGE_TEST_DIR${NC}"
            exit 1
        fi
    else
        echo -e "${YELLOW}Usage: $0 <conflict_file>${NC}"
        echo -e "       $0 <base> <input1> <input2>"
        echo "       Or ensure ~/vscode-merge-test has an active merge conflict"
        exit 1
    fi
else
    echo -e "${YELLOW}Usage: $0 <conflict_file>${NC}"
    echo -e "       $0 <base> <input1> <input2>"
    exit 1
fi

cd "$PROJECT_ROOT"

echo ""
echo -e "${CYAN}Test files:${NC}"
echo "  Base:     $BASE_FILE ($(wc -l < "$BASE_FILE") lines)"
echo "  Input1:   $INPUT1_FILE ($(wc -l < "$INPUT1_FILE") lines)"
echo "  Input2:   $INPUT2_FILE ($(wc -l < "$INPUT2_FILE") lines)"
echo ""

# Output files in secure temp directory
VSCODE_OUTPUT="$TEMP_DIR/vscode_output.json"
LUA_OUTPUT="$TEMP_DIR/lua_output.json"

# Run VSCode implementation
echo -e "${CYAN}Running VSCode implementation...${NC}"
if node "$PROJECT_ROOT/vscode-merge.mjs" "$BASE_FILE" "$INPUT1_FILE" "$INPUT2_FILE" > "$VSCODE_OUTPUT" 2>/dev/null; then
    echo -e "${GREEN}✓ VSCode output generated${NC}"
else
    echo -e "${RED}✗ VSCode implementation failed${NC}"
    exit 1
fi

# Run Lua implementation
echo -e "${CYAN}Running Lua implementation...${NC}"
if nvim --headless -l scripts/merge_alignment_cli.lua "$BASE_FILE" "$INPUT1_FILE" "$INPUT2_FILE" > "$LUA_OUTPUT" 2>/dev/null; then
    echo -e "${GREEN}✓ Lua output generated${NC}"
else
    echo -e "${RED}✗ Lua implementation failed${NC}"
    exit 1
fi

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "                         COMPARISON RESULTS"
echo "═══════════════════════════════════════════════════════════════"
echo ""

# Compare diffs (should be identical since we use same algorithm)
echo -e "${CYAN}1. Diff Results (base->input1):${NC}"
VSCODE_DIFF1_COUNT=$(jq '.diffs.base_to_input1 | length' "$VSCODE_OUTPUT")
LUA_DIFF1_COUNT=$(jq '.diffs.base_to_input1 | length' "$LUA_OUTPUT")
echo "   VSCode: $VSCODE_DIFF1_COUNT changes"
echo "   Lua:    $LUA_DIFF1_COUNT changes"
if [ "$VSCODE_DIFF1_COUNT" -eq "$LUA_DIFF1_COUNT" ]; then
    echo -e "   ${GREEN}✓ Match${NC}"
else
    echo -e "   ${RED}✗ Mismatch${NC}"
fi

echo ""
echo -e "${CYAN}2. Diff Results (base->input2):${NC}"
VSCODE_DIFF2_COUNT=$(jq '.diffs.base_to_input2 | length' "$VSCODE_OUTPUT")
LUA_DIFF2_COUNT=$(jq '.diffs.base_to_input2 | length' "$LUA_OUTPUT")
echo "   VSCode: $VSCODE_DIFF2_COUNT changes"
echo "   Lua:    $LUA_DIFF2_COUNT changes"
if [ "$VSCODE_DIFF2_COUNT" -eq "$LUA_DIFF2_COUNT" ]; then
    echo -e "   ${GREEN}✓ Match${NC}"
else
    echo -e "   ${RED}✗ Mismatch${NC}"
fi

echo ""
echo -e "${CYAN}3. Filler Lines (Left/Input1):${NC}"
VSCODE_LEFT_FILLERS=$(jq '.fillers.left_fillers | length' "$VSCODE_OUTPUT")
LUA_LEFT_FILLERS=$(jq '.fillers.left_fillers | length' "$LUA_OUTPUT")
echo "   VSCode: $VSCODE_LEFT_FILLERS fillers"
echo "   Lua:    $LUA_LEFT_FILLERS fillers"

echo ""
echo "   VSCode left fillers:"
jq -c '.fillers.left_fillers[]' "$VSCODE_OUTPUT" 2>/dev/null | head -10 | while read -r line; do
    echo "     $line"
done

echo ""
echo "   Lua left fillers:"
jq -c '.fillers.left_fillers[]' "$LUA_OUTPUT" 2>/dev/null | head -10 | while read -r line; do
    echo "     $line"
done

echo ""
echo -e "${CYAN}4. Filler Lines (Right/Input2):${NC}"
VSCODE_RIGHT_FILLERS=$(jq '.fillers.right_fillers | length' "$VSCODE_OUTPUT")
LUA_RIGHT_FILLERS=$(jq '.fillers.right_fillers | length' "$LUA_OUTPUT")
echo "   VSCode: $VSCODE_RIGHT_FILLERS fillers"
echo "   Lua:    $LUA_RIGHT_FILLERS fillers"

echo ""
echo "   VSCode right fillers:"
jq -c '.fillers.right_fillers[]' "$VSCODE_OUTPUT" 2>/dev/null | head -10 | while read -r line; do
    echo "     $line"
done

echo ""
echo "   Lua right fillers:"
jq -c '.fillers.right_fillers[]' "$LUA_OUTPUT" 2>/dev/null | head -10 | while read -r line; do
    echo "     $line"
done

echo ""
echo -e "${CYAN}5. Mapping Alignments:${NC}"
VSCODE_MA_COUNT=$(jq '.mapping_alignments | length' "$VSCODE_OUTPUT" 2>/dev/null || echo "N/A")
echo "   VSCode mapping alignments: $VSCODE_MA_COUNT"
echo ""
echo "   First 5 VSCode mapping alignments:"
jq -c '.mapping_alignments[:5][] | {base: .base_range, input1: .input1_range, input2: .input2_range, conflict: .is_conflicting}' "$VSCODE_OUTPUT" 2>/dev/null | while read -r line; do
    echo "     $line"
done

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "                         DETAILED DIFF"
echo "═══════════════════════════════════════════════════════════════"
echo ""

# Create normalized versions for comparison
echo -e "${CYAN}Comparing fillers (normalized):${NC}"
jq -S '.fillers' "$VSCODE_OUTPUT" > "$TEMP_DIR/vscode_fillers.json"
jq -S '.fillers' "$LUA_OUTPUT" > "$TEMP_DIR/lua_fillers.json"

if diff -q "$TEMP_DIR/vscode_fillers.json" "$TEMP_DIR/lua_fillers.json" > /dev/null 2>&1; then
    echo -e "${GREEN}✓ Fillers are IDENTICAL${NC}"
else
    echo -e "${YELLOW}✗ Fillers DIFFER:${NC}"
    diff --color=always "$TEMP_DIR/vscode_fillers.json" "$TEMP_DIR/lua_fillers.json" | head -50 || true
fi

echo ""
echo -e "${CYAN}Comparing inner_changes (character-level highlights):${NC}"
jq -S '.diffs.base_to_input1[].inner_changes' "$VSCODE_OUTPUT" > "$TEMP_DIR/vscode_inner1.json" 2>/dev/null
jq -S '.diffs.base_to_input1[].inner_changes' "$LUA_OUTPUT" > "$TEMP_DIR/lua_inner1.json" 2>/dev/null
jq -S '.diffs.base_to_input2[].inner_changes' "$VSCODE_OUTPUT" > "$TEMP_DIR/vscode_inner2.json" 2>/dev/null
jq -S '.diffs.base_to_input2[].inner_changes' "$LUA_OUTPUT" > "$TEMP_DIR/lua_inner2.json" 2>/dev/null

INNER1_MATCH=true
INNER2_MATCH=true

if ! diff -q "$TEMP_DIR/vscode_inner1.json" "$TEMP_DIR/lua_inner1.json" > /dev/null 2>&1; then
    INNER1_MATCH=false
fi
if ! diff -q "$TEMP_DIR/vscode_inner2.json" "$TEMP_DIR/lua_inner2.json" > /dev/null 2>&1; then
    INNER2_MATCH=false
fi

if $INNER1_MATCH && $INNER2_MATCH; then
    echo -e "${GREEN}✓ Inner changes (highlights) are IDENTICAL${NC}"
else
    if ! $INNER1_MATCH; then
        echo -e "${YELLOW}✗ Inner changes (base->input1) DIFFER${NC}"
    fi
    if ! $INNER2_MATCH; then
        echo -e "${YELLOW}✗ Inner changes (base->input2) DIFFER${NC}"
    fi
fi

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "                         OUTPUT FILES"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "Temp directory: $TEMP_DIR (cleaned up on exit)"
echo ""
echo "To view outputs before exit, check:"
echo "  $VSCODE_OUTPUT"
echo "  $LUA_OUTPUT"
echo ""
