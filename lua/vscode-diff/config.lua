-- Backward compatibility shim
-- Redirects old 'vscode-diff.config' to new 'codediff.config'
require("vscode-diff._deprecation").warn("vscode-diff.config", "codediff.config")
return require("codediff.config")
