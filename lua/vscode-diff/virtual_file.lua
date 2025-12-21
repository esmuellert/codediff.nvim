-- Backward compatibility shim
-- Redirects old 'vscode-diff.virtual_file' to new 'vscode-diff.core.virtual_file'
return require('vscode-diff.core.virtual_file')
