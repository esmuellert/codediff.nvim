-- Backward compatibility shim
-- Redirects old 'vscode-diff' to new 'codediff'
require("vscode-diff._deprecation").warn("vscode-diff", "codediff")
return require("codediff")
