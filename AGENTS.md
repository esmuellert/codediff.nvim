# Agent Instructions

## General CLI Agent Behavior Instructions

### Communication and File Operation Guidelines

1. **Output Messages**: When responding to users, utilize the native chat output interface. Do not use command-line utilities such as `cat`, `echo`, or `write-host` to display messages in the console.

2. **File Creation and Editing**: Always use native file operation tools (create, edit, patch/diff APIs) for all file operations. Do not use shell redirection operators (`>`, `>>`, `<<`) or command-line utilities (`cat`, `sed`, `awk`, `grep`) to create or modify files. This applies to ALL files, regardless of location (project files, `/tmp`, `%TEMP%`, etc.).

   **Prohibited patterns**:
   - `cat > /tmp/file.md << 'EOF'`
   - `echo "content" > file.txt`
   - `sed -i 's/pattern/replacement/' file.js`
   
   **Required approach**: Use native `create` or `str_replace` tools instead.

3. **Experimental and Demonstration Scripts**: When running experiments, demonstrations, or temporary operations that require script files, create the script files explicitly in temporary directories (`/tmp` on Linux/macOS, `%TEMP%` on Windows) using native file creation tools first, then execute them. Do not use inline heredocs or shell redirection. Do not place code that should have commited and checked-in in `/tmp` folder

   **Example workflow**:
   - Step 1: Use `create` tool to make `/tmp/experiment.sh`
   - Step 2: Execute `bash /tmp/experiment.sh`
   - Step 3: Clean up the file after use

4. **Trailing Spaces**: NEVER add trailing spaces to any line in any file. Always ensure lines end cleanly without whitespace.

5. **Pull Requests**: When asked to create a PR, push the branch as is (do not create a new branch), create PR with comprehensive description (summary, changes, benefits, testing), and enable auto-merge.

6. **Commits**: NEVER commit code unless explicitly requested by the user. Each request authorizes only a single commit operation. Use proper conventional commit messages.

## Path-Specific Instructions

Path-specific instructions are defined in `.github/copilot-instructions.md` files within respective directories.
