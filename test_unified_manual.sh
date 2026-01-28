#!/bin/bash
set -e

TEST_DIR=$(mktemp -d)
echo "Creating test repository in: $TEST_DIR"

cd "$TEST_DIR"

git init
git config user.email "test@example.com"
git config user.name "Test User"

cat > file1.lua << 'EOF'
local M = {}

function M.greet(name)
  print("Hello, " .. name)
end

function M.farewell(name)
  print("Goodbye, " .. name)
end

return M
EOF

git add file1.lua
git commit -m "Initial commit"

cat > file1.lua << 'EOF'
local M = {}

function M.greet(name)
  print("Hi there, " .. name .. "!")
end

function M.farewell(name)
  print("See you later, " .. name)
end

function M.welcome(name)
  print("Welcome aboard, " .. name)
end

return M
EOF

git add file1.lua
git commit -m "Update greetings"

cat > file2.lua << 'EOF'
-- Configuration file
local config = {
  debug = false,
  timeout = 30,
}

return config
EOF

echo ""
echo "Test repository created!"
echo "Repository: $TEST_DIR"
echo ""
echo "To test unified diff mode, run these commands in Neovim:"
echo ""
echo "  cd $TEST_DIR"
echo "  nvim file1.lua"
echo ""
echo "Then try:"
echo "  :CodeDiff --unified file HEAD~1"
echo "  :CodeDiff --unified file HEAD~1 HEAD"
echo "  :CodeDiff --unified file file1.lua file2.lua"
echo ""
echo "Navigation:"
echo "  ]c / [c - Next/previous hunk"
echo "  q - Close tab"
echo ""

nvim -c "cd $TEST_DIR" -c "edit file1.lua" -c "CodeDiff --unified file HEAD~1"
