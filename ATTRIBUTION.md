# Attribution

This project includes code from or is derived from the following open source projects. We are grateful to the authors and contributors of these projects.

---

## Bundled Dependencies

### utf8proc

**License**: MIT License  
**Copyright**: Copyright (c) 2014-2021 Steven G. Johnson, Jiahao Chen, Tony Kelman, Jonas Fonseca, and other contributors  
**Source**: https://github.com/JuliaStrings/utf8proc  
**Location**: `libvscode-diff/vendor/`  
**Purpose**: UTF-8 Unicode string processing  

Full license text: [libvscode-diff/vendor/utf8proc_LICENSE.md](libvscode-diff/vendor/utf8proc_LICENSE.md)

---

## Derivative Works

### Microsoft Visual Studio Code

**License**: MIT License  
**Copyright**: Copyright (c) Microsoft Corporation  
**Source**: https://github.com/microsoft/vscode  
**Description**: The diff computation algorithm in this project is a C port of VSCode's `defaultLinesDiffComputer` implementation. The algorithm, data structures, and optimization heuristics are derived from VSCode's TypeScript source code.

**Key Components Ported**:
- Myers diff algorithm (`src/vs/editor/common/diff/defaultLinesDiffComputer/algorithms/myersDiffAlgorithm.ts`)
- Dynamic Programming algorithm (`src/vs/editor/common/diff/defaultLinesDiffComputer/algorithms/dynamicProgrammingDiffing.ts`)
- Line-level optimization heuristics (`src/vs/editor/common/diff/defaultLinesDiffComputer/heuristicSequenceOptimizations.ts`)
- Character-level refinement (`src/vs/editor/common/diff/defaultLinesDiffComputer/defaultLinesDiffComputer.ts`)
- Range mapping data structures (`src/vs/editor/common/diff/rangeMapping.ts`)

**VSCode License**: MIT License (see [official license](https://github.com/microsoft/vscode/blob/main/LICENSE.txt))

```
MIT License

Copyright (c) Microsoft Corporation

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

## Vendored Code

### Neovim LSP Semantic Tokens

**License**: Apache License 2.0  
**Copyright**: Copyright Neovim contributors  
**Source**: https://github.com/neovim/neovim  
**Location**: `lua/vscode-diff/render/semantic_tokens.lua` (lines 38-117)  
**Description**: Two helper functions from Neovim's LSP semantic tokens implementation are vendored because there is no public API to process semantic token responses for arbitrary buffers.

**Functions Vendored**:
- `modifiers_from_number()` - Decodes token modifiers from bit field
- `tokens_to_ranges()` - Converts LSP token array to highlight ranges

**Reason for Vendoring**: Neovim's LSP semantic token API is designed for regular buffers only. Virtual/scratch buffers need direct access to the parsing functions, which are not publicly exported.

**Neovim License**: Apache License 2.0 (see [official license](https://github.com/neovim/neovim/blob/master/LICENSE.txt))

```
                                 Apache License
                           Version 2.0, January 2004
                        http://www.apache.org/licenses/

Copyright Neovim contributors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
```

---

## External Dependencies

The following dependencies are not bundled but are required for full functionality:

### nui.nvim

**License**: MIT License  
**Author**: Munif Tanjim  
**Source**: https://github.com/MunifTanjim/nui.nvim  
**Purpose**: UI components for file explorer  

### plenary.nvim

**License**: MIT License  
**Maintainers**: nvim-lua community  
**Source**: https://github.com/nvim-lua/plenary.nvim  
**Purpose**: Test framework (development only)  

---

---

## Architectural Inspiration

The following projects inspired architectural decisions but no code was copied:

### vim-fugitive

**Author**: Tim Pope  
**Source**: https://github.com/tpope/vim-fugitive  
**Inspiration**: The virtual file URL scheme (`vscodediff://`) is inspired by vim-fugitive's `fugitive://` pattern for creating virtual buffers that represent git objects.

### gitsigns.nvim & diffview.nvim

**Sources**: 
- https://github.com/lewis6991/gitsigns.nvim
- https://github.com/sindrets/diffview.nvim

**Inspiration**: Async git integration patterns and best practices for Neovim git plugins.

---

## Acknowledgments

We would like to thank:

- **Microsoft Corporation** and the VSCode team for creating and open-sourcing an excellent diff algorithm implementation
- **The Neovim contributors** for LSP infrastructure and semantic token support
- **The JuliaStrings project** and utf8proc contributors for providing a robust Unicode processing library
- **Tim Pope** (vim-fugitive) for pioneering the virtual file URL pattern
- **The Neovim community** for creating the plugin ecosystem and supporting libraries
- All contributors to the dependencies and inspirations listed above

---

*This project is distributed under the MIT License. See LICENSE file for details.*
