-- Backward compatibility shim
-- Redirects old 'vscode-diff.git' to new 'codediff.core.git'
require("vscode-diff._deprecation").warn("vscode-diff.git", "codediff.core.git")
return require("codediff.core.git")
