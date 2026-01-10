-- Backward compatibility shim
-- Redirects old 'vscode-diff.version' to new 'codediff.version'
require("vscode-diff._deprecation").warn("vscode-diff.version", "codediff.version")
return require("codediff.version")
