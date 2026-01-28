#!/usr/bin/env bash
set -e

echo "Testing Unified Diff Mode"
echo "=========================="
echo

# Check we're in git repo
if ! git rev-parse --git-dir > /dev/null 2>&1; then
  echo "Error: Not in a git repository"
  exit 1
fi

# Create test files
TEST_DIR=$(mktemp -d)
trap "rm -rf $TEST_DIR" EXIT

cat > "$TEST_DIR/original.lua" << 'EOF'
local function hello()
  print("Hello World")
  return true
end

local function goodbye()
  print("Goodbye World")
  return false
end

return { hello = hello, goodbye = goodbye }
EOF

cat > "$TEST_DIR/modified.lua" << 'EOF'
local function hello()
  print("Hello Universe")
  return true
end

local function greet(name)
  print("Hello " .. name)
  return true
end

return { hello = hello, greet = greet }
EOF

echo "Test 1: File comparison"
echo "Running: :CodeDiff --unified file $TEST_DIR/original.lua $TEST_DIR/modified.lua"
nvim -c "CodeDiff --unified file $TEST_DIR/original.lua $TEST_DIR/modified.lua" \
     -c "echo 'Press ]c to jump to next hunk, [c for previous, q to quit'" \
     -c "echo 'You should see red (-) and green (+) lines with character highlights'"

echo
echo "Test 2: Git diff with HEAD~1"
if git rev-parse HEAD~1 >/dev/null 2>&1; then
  echo "Running: :CodeDiff --unified file HEAD~1"
  nvim lua/codediff/config.lua \
       -c "CodeDiff --unified file HEAD~1" \
       -c "echo 'Viewing config.lua changes from HEAD~1 to working tree'" \
       -c "echo 'Press ]c/[c to navigate, q to quit'"
else
  echo "Skipped (need at least 2 commits in history)"
fi

echo
echo "Test 3: Git diff between two revisions"
if git rev-parse HEAD~2 >/dev/null 2>&1; then
  echo "Running: :CodeDiff --unified file HEAD~2 HEAD~1"
  nvim lua/codediff/config.lua \
       -c "CodeDiff --unified file HEAD~2 HEAD~1" \
       -c "echo 'Viewing config.lua changes between HEAD~2 and HEAD~1'" \
       -c "echo 'Press ]c/[c to navigate, q to quit'"
else
  echo "Skipped (need at least 3 commits in history)"
fi

echo
echo "All manual tests completed!"
echo
echo "Verification checklist:"
echo "- [ ] Hunk headers visible (@@ -line,count +line,count @@)"
echo "- [ ] Deletion lines have red background and - prefix"
echo "- [ ] Insertion lines have green background and + prefix"
echo "- [ ] Changed characters have darker overlay"
echo "- [ ] Context lines have space prefix"
echo "- [ ] ]c jumps to next hunk"
echo "- [ ] [c jumps to previous hunk"
echo "- [ ] q closes the diff"
