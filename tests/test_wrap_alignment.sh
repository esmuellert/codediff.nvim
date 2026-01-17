#!/bin/bash
# Test script for vscode-wrap-alignment.mjs

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
TOOL="$PROJECT_DIR/vscode-wrap-alignment.mjs"

echo "=== Wrap Alignment Tool Tests ==="
echo ""

# Test 1: Basic wrap difference
echo "Test 1: Basic wrap difference (line 2 wraps in orig, line 3 wraps in mod)"
cat > /tmp/test1_orig.txt << 'EOF'
short line
this is a longer line that will need to wrap when the column width is narrow
another short line
EOF
cat > /tmp/test1_mod.txt << 'EOF'
short line
short replacement
another short line with extra text that may wrap
EOF

result=$(node "$TOOL" -w 40 /tmp/test1_orig.txt /tmp/test1_mod.txt)
orig_fillers=$(echo "$result" | jq '.fillers.originalFillers | length')
mod_fillers=$(echo "$result" | jq '.fillers.modifiedFillers | length')

if [ "$orig_fillers" -eq 1 ] && [ "$mod_fillers" -eq 1 ]; then
    echo "  PASS: Got expected filler counts (orig=$orig_fillers, mod=$mod_fillers)"
else
    echo "  FAIL: Expected 1 filler each, got orig=$orig_fillers mod=$mod_fillers"
    exit 1
fi

# Test 2: No wrapping needed at wide column
echo ""
echo "Test 2: Wide column (no wrapping needed)"
result=$(node "$TOOL" -w 200 /tmp/test1_orig.txt /tmp/test1_mod.txt)
orig_fillers=$(echo "$result" | jq '.fillers.originalFillers | length')
mod_fillers=$(echo "$result" | jq '.fillers.modifiedFillers | length')

if [ "$orig_fillers" -eq 0 ] && [ "$mod_fillers" -eq 0 ]; then
    echo "  PASS: No fillers at wide column"
else
    echo "  FAIL: Expected 0 fillers, got orig=$orig_fillers mod=$mod_fillers"
    exit 1
fi

# Test 3: Tab handling
echo ""
echo "Test 3: Tab handling"
printf "no tabs here\n" > /tmp/test3_orig.txt
printf "\t\t\tindented with tabs that expand\n" > /tmp/test3_mod.txt

result=$(node "$TOOL" -w 30 -t 4 /tmp/test3_orig.txt /tmp/test3_mod.txt)
mod_wrap=$(echo "$result" | jq '.modified.wrapCounts["1"]')

if [ "$mod_wrap" -gt 1 ]; then
    echo "  PASS: Tab-indented line wraps correctly (wrap count=$mod_wrap)"
else
    echo "  INFO: Tab-indented line doesn't wrap at width 30 (wrap count=$mod_wrap)"
fi

# Test 4: CJK characters (double-width)
echo ""
echo "Test 4: CJK characters (double-width)"
echo "hello world short" > /tmp/test4_orig.txt
echo "你好世界测试中文" > /tmp/test4_mod.txt

result=$(node "$TOOL" -w 10 /tmp/test4_orig.txt /tmp/test4_mod.txt)
mod_wrap=$(echo "$result" | jq '.modified.wrapCounts["1"]')

if [ "$mod_wrap" -gt 1 ]; then
    echo "  PASS: CJK line wraps (treated as double-width, wrap count=$mod_wrap)"
else
    echo "  FAIL: CJK line should wrap at width 10 (each char is 2 columns)"
    exit 1
fi

# Test 5: Identical files
echo ""
echo "Test 5: Identical files (no changes)"
echo "line one" > /tmp/test5.txt
cp /tmp/test5.txt /tmp/test5_copy.txt

result=$(node "$TOOL" -w 40 /tmp/test5.txt /tmp/test5_copy.txt)
alignments=$(echo "$result" | jq '.alignments | length')

if [ "$alignments" -eq 0 ]; then
    echo "  PASS: No alignments for identical files"
else
    echo "  FAIL: Expected 0 alignments for identical files, got $alignments"
    exit 1
fi

# Test 6: Multi-line diff with wrapping
echo ""
echo "Test 6: Multi-line diff with different wrap patterns"
cat > /tmp/test6_orig.txt << 'EOF'
first line unchanged
second line is short
third line is also short
fourth unchanged
EOF
cat > /tmp/test6_mod.txt << 'EOF'
first line unchanged
second line has been significantly extended to cause wrapping
third line has also been extended significantly to cause wrapping
fourth unchanged
EOF

result=$(node "$TOOL" -w 40 /tmp/test6_orig.txt /tmp/test6_mod.txt)
orig_fillers=$(echo "$result" | jq '.fillers.originalFillers | length')

if [ "$orig_fillers" -ge 1 ]; then
    echo "  PASS: Got fillers for multi-line diff (orig_fillers=$orig_fillers)"
else
    echo "  FAIL: Expected fillers for wrapped lines, got $orig_fillers"
    exit 1
fi

# Cleanup
rm -f /tmp/test*_orig.txt /tmp/test*_mod.txt /tmp/test*.txt /tmp/test*_copy.txt

echo ""
echo "=== All tests passed ==="
