-- Backward compatibility shim
-- Redirects old 'vscode-diff.installer' to new 'codediff.core.installer'
require("vscode-diff._deprecation").warn("vscode-diff.installer", "codediff.core.installer")
return require("codediff.core.installer")
