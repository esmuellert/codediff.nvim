#!/usr/bin/env node
/**
 * VSCode Wrap Alignment Tool (Standalone Implementation)
 * 
 * Computes line wrap counts and alignment fillers for diff views.
 * This implements VSCode's wrap alignment algorithm for use with Neovim.
 * 
 * Algorithm based on VSCode's:
 * - MonospaceLineBreaksComputer (for computing wrap positions)
 * - computeRangeAlignment (for computing fillers to maintain alignment)
 * 
 * Usage: node vscode-wrap-alignment.mjs [options] <file1> <file2>
 * 
 * Options:
 *   -w, --wrap-column <n>   Wrap column width (default: 80)
 *   -t, --tab-size <n>      Tab size (default: 4)
 *   --diff-json <file>      Use pre-computed diff JSON instead of computing
 *   -h, --help              Show help
 * 
 * Output: JSON with wrap counts and filler placements
 */

import { readFileSync } from 'fs';

// ============================================================================
// ArrayQueue - Port from VSCode base/common/arrays.ts
// ============================================================================

class ArrayQueue {
    constructor(items) {
        this.items = items;
        this.firstIdx = 0;
        this.lastIdx = items.length - 1;
    }

    get length() {
        return this.lastIdx - this.firstIdx + 1;
    }

    peek() {
        if (this.length === 0) return undefined;
        return this.items[this.firstIdx];
    }

    dequeue() {
        const result = this.items[this.firstIdx];
        this.firstIdx++;
        return result;
    }

    takeWhile(predicate) {
        const result = [];
        while (this.length > 0 && predicate(this.items[this.firstIdx])) {
            result.push(this.items[this.firstIdx]);
            this.firstIdx++;
        }
        return result.length > 0 ? result : undefined;
    }
}

// ============================================================================
// Monospace Line Breaks Computation
// ============================================================================

// Character classification for word wrap
const CharacterClass = {
    NONE: 0,
    BREAK_BEFORE: 1,
    BREAK_AFTER: 2,
    BREAK_IDEOGRAPHIC: 3,
};

// Default VSCode word wrap break characters
const BREAK_BEFORE_CHARS = new Set([
    '(', '[', '{', "'", '"', '`',
    '〈', '《', '「', '『', '【', '〔', '〖', '〘', '〚', '〝'
]);

const BREAK_AFTER_CHARS = new Set([
    ' ', '\t', '}', ')', ']', '?', '|', '/', '&', '.', ',', ';',
    '¢', '°', '′', '″', '‰', '℃',
    '、', '。', '，', '：', '；', '！', '？', '¿',
    '•', '※', '‥', '…', '‧', '﹏', '﹑', '﹆',
    '》', '»', '〉', '〟', '〞', '〕', '〗', '〙', '〛', '」', '』', '】'
]);

/**
 * Check if character is CJK ideographic (typically double-width)
 */
function isIdeographic(charCode) {
    // CJK Unified Ideographs
    if (charCode >= 0x4E00 && charCode <= 0x9FFF) return true;
    // CJK Unified Ideographs Extension A
    if (charCode >= 0x3400 && charCode <= 0x4DBF) return true;
    // CJK Unified Ideographs Extension B-F
    if (charCode >= 0x20000 && charCode <= 0x2FA1F) return true;
    // Hiragana and Katakana
    if (charCode >= 0x3040 && charCode <= 0x30FF) return true;
    // Hangul Syllables
    if (charCode >= 0xAC00 && charCode <= 0xD7AF) return true;
    // Fullwidth forms
    if (charCode >= 0xFF00 && charCode <= 0xFFEF) return true;
    return false;
}

/**
 * Get display width of a character (1 for normal, 2 for CJK)
 */
function getCharWidth(char) {
    const code = char.codePointAt(0);
    return isIdeographic(code) ? 2 : 1;
}

/**
 * Classify a character for word wrap purposes
 */
function classifyChar(char) {
    if (BREAK_BEFORE_CHARS.has(char)) return CharacterClass.BREAK_BEFORE;
    if (BREAK_AFTER_CHARS.has(char)) return CharacterClass.BREAK_AFTER;
    const code = char.codePointAt(0);
    if (isIdeographic(code)) return CharacterClass.BREAK_IDEOGRAPHIC;
    return CharacterClass.NONE;
}

/**
 * Compute line break positions for a single line
 * Returns array of column positions where line breaks occur
 * 
 * @param line The text of the line
 * @param wrapColumn Column width to wrap at
 * @param tabSize Size of tabs
 * @returns Array of break column positions (empty if no breaks needed)
 */
function computeLineBreaks(line, wrapColumn, tabSize) {
    if (line.length === 0) return [];
    
    const breakOffsets = [];
    let currentColumn = 0;
    let lastBreakableOffset = -1;
    let lastBreakableColumn = 0;
    
    for (let i = 0; i < line.length; i++) {
        const char = line[i];
        const charClass = classifyChar(char);
        
        // Calculate column after this character
        let charWidth;
        if (char === '\t') {
            charWidth = tabSize - (currentColumn % tabSize);
        } else {
            charWidth = getCharWidth(char);
        }
        
        const nextColumn = currentColumn + charWidth;
        
        // Check if we need to wrap
        if (nextColumn > wrapColumn && i > 0) {
            // We've exceeded the wrap column
            if (lastBreakableOffset >= 0) {
                // Break at last breakable position
                breakOffsets.push(lastBreakableOffset + 1);
                // Reset column tracking from the break point
                currentColumn = 0;
                for (let j = lastBreakableOffset + 1; j <= i; j++) {
                    const c = line[j];
                    if (c === '\t') {
                        currentColumn += tabSize - (currentColumn % tabSize);
                    } else {
                        currentColumn += getCharWidth(c);
                    }
                }
                lastBreakableOffset = -1;
                // Continue without re-checking wrap condition since we just reset
                continue;
            } else {
                // No breakable position, force break before current character
                breakOffsets.push(i);
                currentColumn = charWidth;
                continue;
            }
        }
        
        // Update breakable position based on character class
        if (charClass === CharacterClass.BREAK_AFTER) {
            lastBreakableOffset = i;
            lastBreakableColumn = nextColumn;
        } else if (charClass === CharacterClass.BREAK_BEFORE && i > 0) {
            lastBreakableOffset = i - 1;
            lastBreakableColumn = currentColumn;
        } else if (charClass === CharacterClass.BREAK_IDEOGRAPHIC) {
            lastBreakableOffset = i;
            lastBreakableColumn = nextColumn;
        }
        
        currentColumn = nextColumn;
    }
    
    return breakOffsets;
}

/**
 * Get the number of visual lines a text line occupies when wrapped
 * 
 * @param line The text line
 * @param wrapColumn Column width
 * @param tabSize Tab size
 * @returns Number of visual lines (1 = no wrap, >1 = wrapped)
 */
function getWrapCount(line, wrapColumn, tabSize) {
    const breaks = computeLineBreaks(line, wrapColumn, tabSize);
    return breaks.length + 1;
}

// ============================================================================
// Simple Diff Computation (LCS-based)
// ============================================================================

/**
 * Compute Longest Common Subsequence indices
 * Returns arrays of matching indices in original and modified
 */
function computeLCS(original, modified) {
    const m = original.length;
    const n = modified.length;
    
    // Build LCS table
    const dp = Array(m + 1).fill(null).map(() => Array(n + 1).fill(0));
    
    for (let i = 1; i <= m; i++) {
        for (let j = 1; j <= n; j++) {
            if (original[i - 1] === modified[j - 1]) {
                dp[i][j] = dp[i - 1][j - 1] + 1;
            } else {
                dp[i][j] = Math.max(dp[i - 1][j], dp[i][j - 1]);
            }
        }
    }
    
    // Backtrack to find matching pairs
    const origIndices = [];
    const modIndices = [];
    let i = m, j = n;
    
    while (i > 0 && j > 0) {
        if (original[i - 1] === modified[j - 1]) {
            origIndices.unshift(i - 1);
            modIndices.unshift(j - 1);
            i--;
            j--;
        } else if (dp[i - 1][j] > dp[i][j - 1]) {
            i--;
        } else {
            j--;
        }
    }
    
    return { origIndices, modIndices };
}

/**
 * Compute diff mappings from two arrays of lines
 * Returns array of changed regions
 */
function computeSimpleDiff(originalLines, modifiedLines) {
    const { origIndices, modIndices } = computeLCS(originalLines, modifiedLines);
    
    const mappings = [];
    let lastOrigIdx = -1;
    let lastModIdx = -1;
    
    for (let i = 0; i < origIndices.length; i++) {
        const origIdx = origIndices[i];
        const modIdx = modIndices[i];
        
        // Check if there's a gap (changed region)
        if (origIdx > lastOrigIdx + 1 || modIdx > lastModIdx + 1) {
            mappings.push({
                originalRange: {
                    startLineNumber: lastOrigIdx + 2, // +1 for 0-based, +1 for 1-based
                    endLineNumberExclusive: origIdx + 1 // +1 for 1-based
                },
                modifiedRange: {
                    startLineNumber: lastModIdx + 2,
                    endLineNumberExclusive: modIdx + 1
                }
            });
        }
        
        lastOrigIdx = origIdx;
        lastModIdx = modIdx;
    }
    
    // Check for trailing changes
    if (lastOrigIdx < originalLines.length - 1 || lastModIdx < modifiedLines.length - 1) {
        mappings.push({
            originalRange: {
                startLineNumber: lastOrigIdx + 2,
                endLineNumberExclusive: originalLines.length + 1
            },
            modifiedRange: {
                startLineNumber: lastModIdx + 2,
                endLineNumberExclusive: modifiedLines.length + 1
            }
        });
    }
    
    return mappings;
}

/**
 * Compute diff mappings between two files
 */
function computeDiffMappings(file1, file2, scriptDir) {
    const lines1 = readFileSync(file1, 'utf8').split('\n');
    const lines2 = readFileSync(file2, 'utf8').split('\n');
    
    return computeSimpleDiff(lines1, lines2);
}

// ============================================================================
// Range Alignment Computation (ported from VSCode diffEditorViewZones.ts)
// ============================================================================

/**
 * Compute alignment regions with height information
 * This is the core algorithm from VSCode's computeRangeAlignment()
 * 
 * @param originalLines Lines from original file
 * @param modifiedLines Lines from modified file
 * @param diffMappings Array of diff mappings (from vscode-diff)
 * @param originalExtraLines Map of line number -> extra visual lines due to wrapping
 * @param modifiedExtraLines Map of line number -> extra visual lines due to wrapping
 * @returns Array of alignment regions with original/modified heights
 */
function computeRangeAlignment(
    originalLines,
    modifiedLines,
    diffMappings,
    originalExtraLines,
    modifiedExtraLines
) {
    const result = [];
    const lineHeightInPx = 1; // Normalized to 1 line = 1 unit
    
    let lastOriginalLine = 0;
    let lastModifiedLine = 0;
    
    // Helper: Add alignment if heights differ
    function addLineAlignment(oLine, mLine) {
        const origHeight = 1 + (originalExtraLines.get(oLine) || 0);
        const modHeight = 1 + (modifiedExtraLines.get(mLine) || 0);
        
        if (origHeight !== modHeight) {
            result.push({
                originalRange: { startLineNumber: oLine, endLineNumberExclusive: oLine + 1 },
                modifiedRange: { startLineNumber: mLine, endLineNumberExclusive: mLine + 1 },
                originalHeightInPx: origHeight * lineHeightInPx,
                modifiedHeightInPx: modHeight * lineHeightInPx
            });
        }
    }
    
    // Process each diff mapping
    for (const mapping of diffMappings) {
        const origStart = mapping.originalRange?.startLineNumber ?? mapping.original?.startLineNumber ?? 1;
        const origEnd = mapping.originalRange?.endLineNumberExclusive ?? mapping.original?.endLineNumberExclusive ?? origStart;
        const modStart = mapping.modifiedRange?.startLineNumber ?? mapping.modified?.startLineNumber ?? 1;
        const modEnd = mapping.modifiedRange?.endLineNumberExclusive ?? mapping.modified?.endLineNumberExclusive ?? modStart;
        
        // Add alignment for unchanged region before this mapping (1:1 line correspondence)
        const unchangedOrigStart = lastOriginalLine + 1;
        const unchangedOrigEnd = origStart;
        const unchangedModStart = lastModifiedLine + 1;
        
        for (let oLine = unchangedOrigStart; oLine < unchangedOrigEnd; oLine++) {
            const mLine = unchangedModStart + (oLine - unchangedOrigStart);
            addLineAlignment(oLine, mLine);
        }
        
        // For the changed region, we need to decide how to align
        // VSCode aligns changed regions as a block, but we also need per-line fillers
        // for proper wrap alignment
        
        const origLineCount = origEnd - origStart;
        const modLineCount = modEnd - modStart;
        
        // Compute total visual heights for the region
        let origTotalHeight = 0;
        let modTotalHeight = 0;
        
        for (let line = origStart; line < origEnd; line++) {
            origTotalHeight += 1 + (originalExtraLines.get(line) || 0);
        }
        for (let line = modStart; line < modEnd; line++) {
            modTotalHeight += 1 + (modifiedExtraLines.get(line) || 0);
        }
        
        // For same-size regions, align line-by-line and add per-line fillers
        if (origLineCount === modLineCount) {
            for (let i = 0; i < origLineCount; i++) {
                const oLine = origStart + i;
                const mLine = modStart + i;
                addLineAlignment(oLine, mLine);
            }
        } else {
            // Different size regions - add as single block alignment if heights differ
            if (origTotalHeight !== modTotalHeight) {
                result.push({
                    originalRange: { startLineNumber: origStart, endLineNumberExclusive: origEnd },
                    modifiedRange: { startLineNumber: modStart, endLineNumberExclusive: modEnd },
                    originalHeightInPx: origTotalHeight * lineHeightInPx,
                    modifiedHeightInPx: modTotalHeight * lineHeightInPx
                });
            }
        }
        
        lastOriginalLine = origEnd - 1;
        lastModifiedLine = modEnd - 1;
    }
    
    // Handle trailing unchanged region
    const trailingOrigStart = lastOriginalLine + 1;
    const trailingModStart = lastModifiedLine + 1;
    const trailingCount = Math.min(
        originalLines.length - lastOriginalLine,
        modifiedLines.length - lastModifiedLine
    );
    
    for (let i = 0; i < trailingCount; i++) {
        const oLine = trailingOrigStart + i;
        const mLine = trailingModStart + i;
        if (oLine <= originalLines.length && mLine <= modifiedLines.length) {
            addLineAlignment(oLine, mLine);
        }
    }
    
    return result;
}

/**
 * Convert alignment regions to filler placements
 * 
 * @param alignments Array of alignment regions
 * @returns Object with originalFillers and modifiedFillers arrays
 */
function computeFillerPlacements(alignments) {
    const originalFillers = [];
    const modifiedFillers = [];
    
    for (const alignment of alignments) {
        const delta = alignment.originalHeightInPx - alignment.modifiedHeightInPx;
        
        if (delta > 0) {
            // Original is taller, need filler on modified side
            modifiedFillers.push({
                afterLineNumber: alignment.modifiedRange.endLineNumberExclusive - 1,
                heightInLines: delta
            });
        } else if (delta < 0) {
            // Modified is taller, need filler on original side
            originalFillers.push({
                afterLineNumber: alignment.originalRange.endLineNumberExclusive - 1,
                heightInLines: -delta
            });
        }
    }
    
    return { originalFillers, modifiedFillers };
}

// ============================================================================
// Main
// ============================================================================

function showHelp() {
    console.log(`VSCode Wrap Alignment Tool

Computes line wrap counts and alignment fillers for diff views.

Usage: node vscode-wrap-alignment.mjs [options] <file1> <file2>

Options:
  -w, --wrap-column <n>   Wrap column width (default: 80)
  -t, --tab-size <n>      Tab size (default: 4)
  --diff-json <file>      Use pre-computed diff JSON instead of computing
  -h, --help              Show help

Output: JSON with wrap counts and filler placements

Example:
  node vscode-wrap-alignment.mjs -w 40 original.txt modified.txt
`);
}

function main() {
    const args = process.argv.slice(2);
    
    let wrapColumn = 80;
    let tabSize = 4;
    let diffJsonFile = null;
    const files = [];
    
    // Parse arguments
    for (let i = 0; i < args.length; i++) {
        const arg = args[i];
        
        if (arg === '-h' || arg === '--help') {
            showHelp();
            process.exit(0);
        } else if (arg === '-w' || arg === '--wrap-column') {
            wrapColumn = parseInt(args[++i], 10);
        } else if (arg === '-t' || arg === '--tab-size') {
            tabSize = parseInt(args[++i], 10);
        } else if (arg === '--diff-json') {
            diffJsonFile = args[++i];
        } else if (!arg.startsWith('-')) {
            files.push(arg);
        }
    }
    
    if (files.length !== 2) {
        console.error('Error: Two files are required');
        console.error('Usage: node vscode-wrap-alignment.mjs [options] <file1> <file2>');
        process.exit(1);
    }
    
    const [file1, file2] = files;
    
    // Read files
    const originalLines = readFileSync(file1, 'utf8').split('\n');
    const modifiedLines = readFileSync(file2, 'utf8').split('\n');
    
    // Compute wrap counts for each line
    const originalWrapCounts = new Map();
    const modifiedWrapCounts = new Map();
    const originalExtraLines = new Map();
    const modifiedExtraLines = new Map();
    
    for (let i = 0; i < originalLines.length; i++) {
        const lineNum = i + 1;
        const wrapCount = getWrapCount(originalLines[i], wrapColumn, tabSize);
        originalWrapCounts.set(lineNum, wrapCount);
        if (wrapCount > 1) {
            originalExtraLines.set(lineNum, wrapCount - 1);
        }
    }
    
    for (let i = 0; i < modifiedLines.length; i++) {
        const lineNum = i + 1;
        const wrapCount = getWrapCount(modifiedLines[i], wrapColumn, tabSize);
        modifiedWrapCounts.set(lineNum, wrapCount);
        if (wrapCount > 1) {
            modifiedExtraLines.set(lineNum, wrapCount - 1);
        }
    }
    
    // Get diff mappings
    let diffMappings;
    if (diffJsonFile) {
        const diffData = JSON.parse(readFileSync(diffJsonFile, 'utf8'));
        diffMappings = diffData.changes || diffData;
    } else {
        // Get script directory
        const scriptDir = new URL('.', import.meta.url).pathname.replace(/\/$/, '');
        diffMappings = computeDiffMappings(file1, file2, scriptDir);
    }
    
    // Compute alignment regions
    const alignments = computeRangeAlignment(
        originalLines,
        modifiedLines,
        diffMappings,
        originalExtraLines,
        modifiedExtraLines
    );
    
    // Compute filler placements
    const fillers = computeFillerPlacements(alignments);
    
    // Output result
    const result = {
        settings: {
            wrapColumn,
            tabSize
        },
        original: {
            lineCount: originalLines.length,
            wrapCounts: Object.fromEntries(originalWrapCounts),
            extraLines: Object.fromEntries(originalExtraLines)
        },
        modified: {
            lineCount: modifiedLines.length,
            wrapCounts: Object.fromEntries(modifiedWrapCounts),
            extraLines: Object.fromEntries(modifiedExtraLines)
        },
        alignments,
        fillers
    };
    
    console.log(JSON.stringify(result, null, 2));
}

main();
