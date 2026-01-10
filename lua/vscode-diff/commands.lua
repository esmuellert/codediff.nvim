-- Backward compatibility shim
-- Redirects old 'vscode-diff.commands' to new 'codediff.commands'
require("vscode-diff._deprecation").warn("vscode-diff.commands", "codediff.commands")
return require("codediff.commands")
