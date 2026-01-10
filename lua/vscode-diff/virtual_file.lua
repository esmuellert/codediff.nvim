-- Backward compatibility shim
-- Redirects old 'vscode-diff.virtual_file' to new 'codediff.core.virtual_file'
require("vscode-diff._deprecation").warn("vscode-diff.virtual_file", "codediff.core.virtual_file")
return require("codediff.core.virtual_file")
