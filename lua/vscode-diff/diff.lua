-- Backward compatibility shim
-- Redirects old 'vscode-diff.diff' to new 'codediff.core.diff'
require("vscode-diff._deprecation").warn("vscode-diff.diff", "codediff.core.diff")
return require("codediff.core.diff")
