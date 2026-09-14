# Virtual File Implementation

## Purpose

CodeDiff uses a `codediff://` URI for read-only content loaded from a Git revision.
The URI gives each historical buffer a stable identity while keeping it separate
from the real working-tree file.

## Buffer Types

```lua
BufferType = {
  VIRTUAL_FILE = "VIRTUAL_FILE", -- read-only content from a Git revision
  REAL_FILE = "REAL_FILE",       -- a file on disk
  SCRATCH = "SCRATCH",           -- an in-memory comparison buffer
}
```

The normal Git diff view combines a virtual original buffer with a real modified
buffer. File-to-file comparisons use scratch buffers.

## Loading a Virtual Buffer

The virtual-file loader:

1. Parses the `codediff://` URI.
2. Reads the requested revision asynchronously through Git.
3. Places the content in the buffer.
4. Marks the buffer read-only and disables diagnostics.
5. Starts Tree-sitter directly when a parser is available.
6. Fires `CodeDiffVirtualFileLoaded` so the view can render the diff.

Tree-sitter is started directly instead of assigning `filetype`. This prevents
`FileType` autocmds from causing LSP clients to attach to a URI scheme they may
not support.

## Highlighting and LSP Boundary

Virtual revision buffers use Tree-sitter syntax highlighting. They are not LSP
client buffers and do not send document notifications to language servers.

The real working-tree buffer remains a normal Neovim buffer, so users retain
normal LSP behavior when they leave the diff view or open the file separately.

## Lifecycle

Virtual buffers are reused when possible, refreshed for mutable revisions such
as `:0`, and deleted when they are no longer needed. The view waits for
`CodeDiffVirtualFileLoaded` before reading content that was loaded asynchronously.

## URI Format

```text
codediff:///path/to/repository///revision/path/to/file
```

The URI is an internal buffer identity. It is not a filesystem path and should
not be passed to tools or language servers that only accept `file://` URIs.

## Related Code

- `lua/codediff/core/virtual_file.lua` — URI parsing, loading, and Tree-sitter setup
- `lua/codediff/ui/view/render.lua` — side-by-side rendering after load
- `lua/codediff/ui/inline_view/render.lua` — inline rendering after load
- `tests/integration/core/virtual_file_spec.lua` — regression coverage ensuring virtual
  buffers do not trigger LSP attachment
