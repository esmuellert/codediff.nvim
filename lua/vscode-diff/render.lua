-- Backward compatibility shim
-- Redirects old 'vscode-diff.render' to new 'codediff.ui'
require("vscode-diff._deprecation").warn("vscode-diff.render", "codediff.ui")
return require("codediff.ui")
