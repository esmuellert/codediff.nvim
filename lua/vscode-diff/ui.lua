-- Backward compatibility shim
-- Redirects old 'vscode-diff.ui' to new 'codediff.ui'
require("vscode-diff._deprecation").warn("vscode-diff.ui", "codediff.ui")
return require("codediff.ui")
