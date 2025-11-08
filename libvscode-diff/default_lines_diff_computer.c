// ============================================================================
// VSCode DefaultLinesDiffComputer - Main Orchestrator
// ============================================================================
// 
// C port of VSCode's DefaultLinesDiffComputer class with 100% parity.
// 
// VSCode Reference:
//   src/vs/editor/common/diff/defaultLinesDiffComputer/defaultLinesDiffComputer.ts
//
// VSCode Parity: 100% (excluding computeMoves)
//
// ============================================================================

#include "default_lines_diff_computer.h"
#include "line_level.h"
#include "char_level.h"
#include "range_mapping.h"
#include "utils.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

#ifdef USE_OPENMP
#include <omp.h>
#endif

// ============================================================================
// Forward Declarations
// ============================================================================

static LinesDiff* create_empty_lines_diff(void);
static LinesDiff* create_full_file_diff(
    const char** original_lines,
    int original_count,
    const char** modified_lines,
    int modified_count
);
static RangeMappingArray* refine_diff(
    const SequenceDiff* diff,
    const char** original_lines,
    int original_count,
    const char** modified_lines,
    int modified_count,
    Timeout* timeout,
    bool consider_whitespace_changes,
    const DiffOptions* options,
    bool* hit_timeout
);

// ============================================================================
// Helper Functions (Bottom-Up Implementation)
// ============================================================================

/**
 * Create empty LinesDiff for trivial equality case.
 * 
 * VSCode Reference: defaultLinesDiffComputer.ts computeDiff() line 32
 * VSCode Parity: 100%
 */
static LinesDiff* create_empty_lines_diff(void) {
    LinesDiff* result = (LinesDiff*)malloc(sizeof(LinesDiff));
    if (!result) return NULL;
    
    result->changes.mappings = NULL;
    result->changes.count = 0;
    result->changes.capacity = 0;
    
    result->moves.moves = NULL;
    result->moves.count = 0;
    result->moves.capacity = 0;
    
    result->hit_timeout = false;
    
    return result;
}

/**
 * Create LinesDiff for single empty line case.
 * 
 * When one side is a single empty line, return a full file diff.
 * 
 * VSCode Reference: defaultLinesDiffComputer.ts computeDiff() lines 35-48
 * VSCode Parity: 100%
 */
static LinesDiff* create_full_file_diff(
    const char** original_lines,
    int original_count,
    const char** modified_lines,
    int modified_count
) {
    LinesDiff* result = (LinesDiff*)malloc(sizeof(LinesDiff));
    if (!result) return NULL;
    
    // Allocate one DetailedLineRangeMapping
    result->changes.mappings = (DetailedLineRangeMapping*)malloc(sizeof(DetailedLineRangeMapping));
    if (!result->changes.mappings) {
        free(result);
        return NULL;
    }
    result->changes.count = 1;
    result->changes.capacity = 1;
    
    // Set line ranges: full file
    result->changes.mappings[0].original.start_line = 1;
    result->changes.mappings[0].original.end_line = original_count + 1;
    result->changes.mappings[0].modified.start_line = 1;
    result->changes.mappings[0].modified.end_line = modified_count + 1;
    
    // Create one RangeMapping for the entire content
    result->changes.mappings[0].inner_changes = (RangeMapping*)malloc(sizeof(RangeMapping));
    if (!result->changes.mappings[0].inner_changes) {
        free(result->changes.mappings);
        free(result);
        return NULL;
    }
    result->changes.mappings[0].inner_change_count = 1;
    
    // Original range
    result->changes.mappings[0].inner_changes[0].original.start_line = 1;
    result->changes.mappings[0].inner_changes[0].original.start_col = 1;
    result->changes.mappings[0].inner_changes[0].original.end_line = original_count;
    if (original_count > 0) {
        result->changes.mappings[0].inner_changes[0].original.end_col = 
            (int)strlen(original_lines[original_count - 1]) + 1;
    } else {
        result->changes.mappings[0].inner_changes[0].original.end_col = 1;
    }
    
    // Modified range
    result->changes.mappings[0].inner_changes[0].modified.start_line = 1;
    result->changes.mappings[0].inner_changes[0].modified.start_col = 1;
    result->changes.mappings[0].inner_changes[0].modified.end_line = modified_count;
    if (modified_count > 0) {
        result->changes.mappings[0].inner_changes[0].modified.end_col = 
            (int)strlen(modified_lines[modified_count - 1]) + 1;
    } else {
        result->changes.mappings[0].inner_changes[0].modified.end_col = 1;
    }
    
    // No moves
    result->moves.moves = NULL;
    result->moves.count = 0;
    result->moves.capacity = 0;
    
    result->hit_timeout = false;
    
    return result;
}

/**
 * Check if arrays are equal (element-by-element comparison).
 * 
 * VSCode Reference: equals() from arrays.js
 * VSCode Parity: 100%
 */
static bool arrays_equal(const char** a, int a_len, const char** b, int b_len) {
    if (a_len != b_len) return false;
    
    for (int i = 0; i < a_len; i++) {
        if (strcmp(a[i], b[i]) != 0) {
            return false;
        }
    }
    return true;
}

/**
 * Refine a SequenceDiff to character-level RangeMappings.
 * 
 * This is the C port of VSCode's refineDiff() method.
 * 
 * @param diff Line-level diff to refine
 * @param original_lines Original file lines
 * @param original_count Number of original lines
 * @param modified_lines Modified file lines
 * @param modified_count Number of modified lines
 * @param timeout Timeout for computation
 * @param consider_whitespace_changes If true, include whitespace changes
 * @param options Diff options
 * @param hit_timeout Output: set to true if timeout was hit
 * @return Array of RangeMappings (character-level changes)
 * 
 * VSCode Reference: defaultLinesDiffComputer.ts refineDiff() lines 220-259
 * VSCode Parity: 100%
 */
static RangeMappingArray* refine_diff(
    const SequenceDiff* diff,
    const char** original_lines,
    int original_count,
    const char** modified_lines,
    int modified_count,
    Timeout* timeout,
    bool consider_whitespace_changes,
    const DiffOptions* options,
    bool* hit_timeout
) {
    // Call our existing refine_diff_char_level function
    CharLevelOptions char_opts;
    char_opts.consider_whitespace_changes = consider_whitespace_changes;
    char_opts.extend_to_subwords = options->extend_to_subwords;
    char_opts.timeout_ms = timeout->timeout_ms;
    
    bool local_timeout = false;
    RangeMappingArray* result = refine_diff_char_level(
        diff,
        original_lines, original_count,
        modified_lines, modified_count,
        &char_opts,
        &local_timeout
    );
    
    if (local_timeout && hit_timeout) {
        *hit_timeout = true;
    }
    
    return result;
}

/**
 * Scan equal-length line regions for whitespace-only changes.
 * 
 * When two lines have the same hash (trimmed content) but different actual
 * content, they differ only in whitespace. This function detects and refines
 * such differences.
 * 
 * @param equal_lines_count Number of equal lines to scan
 * @param seq1_last_start Current position in original lines
 * @param seq2_last_start Current position in modified lines
 * @param original_lines Original file lines
 * @param original_count Number of original lines
 * @param modified_lines Modified file lines
 * @param modified_count Number of modified lines
 * @param consider_whitespace_changes If false, skip scanning
 * @param timeout Timeout for computation
 * @param options Diff options
 * @param alignments Output: accumulate RangeMappings here
 * @param hit_timeout Output: set to true if any refinement times out
 * 
 * VSCode Reference: defaultLinesDiffComputer.ts scanForWhitespaceChanges() lines 100-118
 * VSCode Parity: 100%
 */
static void scan_for_whitespace_changes(
    int equal_lines_count,
    int seq1_last_start,
    int seq2_last_start,
    const char** original_lines,
    int original_count,
    const char** modified_lines,
    int modified_count,
    bool consider_whitespace_changes,
    Timeout* timeout,
    const DiffOptions* options,
    RangeMappingArray* alignments,
    bool* hit_timeout
) {
    if (!consider_whitespace_changes) {
        return;
    }
    
    for (int i = 0; i < equal_lines_count; i++) {
        int seq1_offset = seq1_last_start + i;
        int seq2_offset = seq2_last_start + i;
        
        if (strcmp(original_lines[seq1_offset], modified_lines[seq2_offset]) != 0) {
            // This is because of whitespace changes, diff these lines
            SequenceDiff line_diff = {
                .seq1_start = seq1_offset,
                .seq1_end = seq1_offset + 1,
                .seq2_start = seq2_offset,
                .seq2_end = seq2_offset + 1
            };
            
            bool local_timeout = false;
            RangeMappingArray* character_diffs = refine_diff(
                &line_diff,
                original_lines, original_count,
                modified_lines, modified_count,
                timeout,
                consider_whitespace_changes,
                options,
                &local_timeout
            );
            
            if (character_diffs) {
                // Add all mappings to alignments array
                for (int j = 0; j < character_diffs->count; j++) {
                    // Grow alignments array if needed
                    if (alignments->count >= alignments->capacity) {
                        size_t new_capacity = (size_t)(alignments->capacity == 0 ? 8 : alignments->capacity * 2);
                        RangeMapping* new_mappings = (RangeMapping*)realloc(
                            alignments->mappings,
                            new_capacity * sizeof(RangeMapping)
                        );
                        if (new_mappings) {
                            alignments->mappings = new_mappings;
                            alignments->capacity = (int)new_capacity;
                        }
                    }
                    
                    if (alignments->count < alignments->capacity) {
                        alignments->mappings[alignments->count++] = character_diffs->mappings[j];
                    }
                }
                
                range_mapping_array_free(character_diffs);
            }
            
            if (local_timeout) {
                *hit_timeout = true;
            }
        }
    }
}

// ============================================================================
// Main Function: compute_diff
// ============================================================================

/**
 * Compute diff between two files.
 * 
 * This is the main entry point, implementing VSCode's computeDiff() method
 * with 100% algorithmic parity.
 * 
 * @param original_lines Original file lines
 * @param original_count Number of lines in original
 * @param modified_lines Modified file lines
 * @param modified_count Number of lines in modified
 * @param options Diff computation options
 * @return LinesDiff structure containing changes and metadata
 * 
 * VSCode Reference: defaultLinesDiffComputer.ts computeDiff() lines 31-174
 * VSCode Parity: 100% (excluding computeMoves)
 * 
 * Notable differences from VSCode:
 * - No computeMoves implementation (Neovim UI limitation)
 * - No assertion validation (can be added later if needed)
 */
LinesDiff* compute_diff(
    const char** original_lines,
    int original_count,
    const char** modified_lines,
    int modified_count,
    const DiffOptions* options
) {
    // Early exit: 0-1 lines and equal
    if (original_count <= 1 && arrays_equal(original_lines, original_count, 
                                            modified_lines, modified_count)) {
        return create_empty_lines_diff();
    }
    
    // Early exit: single empty line
    if ((original_count == 1 && strlen(original_lines[0]) == 0) ||
        (modified_count == 1 && strlen(modified_lines[0]) == 0)) {
        return create_full_file_diff(original_lines, original_count,
                                     modified_lines, modified_count);
    }
    
    // Setup timeout
    Timeout timeout;
    timeout.timeout_ms = options->max_computation_time_ms;
    timeout.start_time_ms = get_current_time_ms();
    
    bool consider_whitespace_changes = !options->ignore_trim_whitespace;
    
    // Line-level diff
    // Use our compute_line_alignments which internally selects DP (<1700 lines) or Myers
    // VSCode Reference: defaultLinesDiffComputer.ts lines 66-77
    bool line_hit_timeout = false;
    SequenceDiffArray* line_alignments = compute_line_alignments(
        original_lines, original_count,
        modified_lines, modified_count,
        timeout.timeout_ms,
        &line_hit_timeout
    );
    bool hit_timeout = line_hit_timeout;
    
    if (!line_alignments) {
        return NULL;
    }
    
    // Optimize line diffs (already done inside compute_line_diff)
    // No need to call optimize_sequence_diffs or remove_very_short_matching_lines_between_diffs
    
    // Initialize character mappings array
    RangeMappingArray* alignments = (RangeMappingArray*)malloc(sizeof(RangeMappingArray));
    if (!alignments) {
        sequence_diff_array_free(line_alignments);
        return NULL;
    }
    alignments->mappings = NULL;
    alignments->count = 0;
    alignments->capacity = 0;
    
#ifdef USE_OPENMP
    // Parallel character refinement (OpenMP)
    // Set default thread count if not explicitly configured by user
    if (getenv("OMP_NUM_THREADS") == NULL) {
        int num_procs = omp_get_num_procs();
        omp_set_num_threads(num_procs > 4 ? 4 : num_procs);
    }
    
    // Only parallelize if we have enough diffs to justify thread overhead
    const int MIN_DIFFS_FOR_PARALLEL = 1;
    int use_parallel = line_alignments->count >= MIN_DIFFS_FOR_PARALLEL;
    
    if (use_parallel) {
        // Pre-allocate thread-local result arrays
        int num_diffs = line_alignments->count;
        RangeMappingArray** thread_results = (RangeMappingArray**)calloc((size_t)num_diffs, sizeof(RangeMappingArray*));
        int* thread_equal_lines = (int*)calloc((size_t)num_diffs, sizeof(int));
        int* thread_seq1_starts = (int*)calloc((size_t)num_diffs, sizeof(int));
        int* thread_seq2_starts = (int*)calloc((size_t)num_diffs, sizeof(int));
        int* thread_timeouts = (int*)calloc((size_t)num_diffs, sizeof(int));
        
        if (!thread_results || !thread_equal_lines || !thread_seq1_starts || 
            !thread_seq2_starts || !thread_timeouts) {
            free(thread_results);
            free(thread_equal_lines);
            free(thread_seq1_starts);
            free(thread_seq2_starts);
            free(thread_timeouts);
            use_parallel = 0; // Fallback to sequential
        } else {
            // Precompute position data (sequential, fast)
            int seq1_last_start = 0;
            int seq2_last_start = 0;
            for (int i = 0; i < num_diffs; i++) {
                const SequenceDiff* diff = &line_alignments->diffs[i];
                thread_equal_lines[i] = diff->seq1_start - seq1_last_start;
                thread_seq1_starts[i] = seq1_last_start;
                thread_seq2_starts[i] = seq2_last_start;
                seq1_last_start = diff->seq1_end;
                seq2_last_start = diff->seq2_end;
            }
            
            // Parallel character refinement with dynamic scheduling
            // MSVC OpenMP 2.0 workaround: declare loop variable outside
#ifdef _MSC_VER
            #pragma warning(push)
            #pragma warning(disable: 4101) // unreferenced local variable (false positive with OpenMP)
#endif
            int diff_idx;
            #pragma omp parallel for schedule(dynamic, 1) shared(thread_results, thread_timeouts) private(diff_idx)
            for (diff_idx = 0; diff_idx < num_diffs; diff_idx++) {
                const SequenceDiff* diff = &line_alignments->diffs[diff_idx];
                
                // Thread-local timeout flags
                bool ws_timeout = false;
                bool char_timeout = false;
                
                // Thread-local whitespace change scanning
                RangeMappingArray* ws_changes = (RangeMappingArray*)malloc(sizeof(RangeMappingArray));
                ws_changes->mappings = NULL;
                ws_changes->count = 0;
                ws_changes->capacity = 0;
                
                scan_for_whitespace_changes(
                    thread_equal_lines[diff_idx],
                    thread_seq1_starts[diff_idx],
                    thread_seq2_starts[diff_idx],
                    original_lines, original_count,
                    modified_lines, modified_count,
                    consider_whitespace_changes,
                    &timeout,
                    options,
                    ws_changes,
                    &ws_timeout
                );
                
                // Thread-local character diff refinement
                RangeMappingArray* character_diffs = refine_diff(
                    diff,
                    original_lines, original_count,
                    modified_lines, modified_count,
                    &timeout,
                    consider_whitespace_changes,
                    options,
                    &char_timeout
                );
                
                // Store timeout flags - no race condition since each thread writes to its own index
                if (ws_timeout || char_timeout) {
                    thread_timeouts[diff_idx] = 1;
                }
                
                // Merge ws_changes and character_diffs into thread_results[diff_idx]
                int total_count = (ws_changes ? ws_changes->count : 0) + 
                                 (character_diffs ? character_diffs->count : 0);
                
                if (total_count > 0) {
                    RangeMappingArray* combined = (RangeMappingArray*)malloc(sizeof(RangeMappingArray));
                    combined->mappings = (RangeMapping*)malloc((size_t)total_count * sizeof(RangeMapping));
                    combined->count = 0;
                    combined->capacity = total_count;
                    
                    if (ws_changes && ws_changes->count > 0) {
                        memcpy(combined->mappings, ws_changes->mappings, 
                               (size_t)ws_changes->count * sizeof(RangeMapping));
                        combined->count += ws_changes->count;
                    }
                    
                    if (character_diffs && character_diffs->count > 0) {
                        memcpy(combined->mappings + combined->count, character_diffs->mappings,
                               (size_t)character_diffs->count * sizeof(RangeMapping));
                        combined->count += character_diffs->count;
                    }
                    
                    thread_results[diff_idx] = combined;
                }
                
                if (ws_changes) range_mapping_array_free(ws_changes);
                if (character_diffs) range_mapping_array_free(character_diffs);
            }
#ifdef _MSC_VER
            #pragma warning(pop)
#endif
            
            // Check timeout flags
            for (int i = 0; i < num_diffs; i++) {
                if (thread_timeouts[i]) {
                    hit_timeout = true;
                    break;
                }
            }
            
            // Optimized merge: calculate total size and do single allocation + batch copy
            int total_size = 0;
            for (int i = 0; i < num_diffs; i++) {
                if (thread_results[i]) {
                    total_size += thread_results[i]->count;
                }
            }
            
            if (total_size > 0) {
                alignments->mappings = (RangeMapping*)malloc((size_t)total_size * sizeof(RangeMapping));
                if (alignments->mappings) {
                    alignments->capacity = total_size;
                    int offset = 0;
                    for (int i = 0; i < num_diffs; i++) {
                        if (thread_results[i] && thread_results[i]->count > 0) {
                            memcpy(alignments->mappings + offset,
                                   thread_results[i]->mappings,
                                   (size_t)thread_results[i]->count * sizeof(RangeMapping));
                            offset += thread_results[i]->count;
                        }
                    }
                    alignments->count = total_size;
                }
            }
            
            // Cleanup thread results
            for (int i = 0; i < num_diffs; i++) {
                if (thread_results[i]) {
                    range_mapping_array_free(thread_results[i]);
                }
            }
            
            free(thread_results);
            free(thread_equal_lines);
            free(thread_seq1_starts);
            free(thread_seq2_starts);
            free(thread_timeouts);
        }
    }
    
    // Fallback to sequential or handle remaining work
    if (!use_parallel)
#endif
    {
        // Sequential character refinement loop (original code)
        int seq1_last_start = 0;
        int seq2_last_start = 0;
        
        for (int diff_idx = 0; diff_idx < line_alignments->count; diff_idx++) {
            const SequenceDiff* diff = &line_alignments->diffs[diff_idx];
            
            int equal_lines_count = diff->seq1_start - seq1_last_start;
            
            // Scan equal lines for whitespace changes
            scan_for_whitespace_changes(
                equal_lines_count,
                seq1_last_start,
                seq2_last_start,
                original_lines, original_count,
                modified_lines, modified_count,
                consider_whitespace_changes,
                &timeout,
                options,
                alignments,
                &hit_timeout
            );
            
            seq1_last_start = diff->seq1_end;
            seq2_last_start = diff->seq2_end;
            
            // Refine this diff region
            bool local_timeout = false;
            RangeMappingArray* character_diffs = refine_diff(
                diff,
                original_lines, original_count,
                modified_lines, modified_count,
                &timeout,
                consider_whitespace_changes,
                options,
                &local_timeout
            );
            
            if (local_timeout) {
                hit_timeout = true;
            }
            
            if (character_diffs) {
                // Add all character mappings
                for (int j = 0; j < character_diffs->count; j++) {
                    if (alignments->count >= alignments->capacity) {
                        size_t new_capacity = (size_t)(alignments->capacity == 0 ? 16 : alignments->capacity * 2);
                        RangeMapping* new_mappings = (RangeMapping*)realloc(
                            alignments->mappings,
                            new_capacity * sizeof(RangeMapping)
                        );
                        if (new_mappings) {
                            alignments->mappings = new_mappings;
                            alignments->capacity = (int)new_capacity;
                        }
                    }
                    
                    if (alignments->count < alignments->capacity) {
                        alignments->mappings[alignments->count++] = character_diffs->mappings[j];
                    }
                }
                
                range_mapping_array_free(character_diffs);
            }
        }
    }
    
    // Scan remaining equal lines (sequential - happens after all diffs)
    int seq1_final = 0;
    int seq2_final = 0;
    if (line_alignments->count > 0) {
        seq1_final = line_alignments->diffs[line_alignments->count - 1].seq1_end;
        seq2_final = line_alignments->diffs[line_alignments->count - 1].seq2_end;
    }
    
    int remaining = original_count - seq1_final;
    scan_for_whitespace_changes(
        remaining,
        seq1_final,
        seq2_final,
        original_lines, original_count,
        modified_lines, modified_count,
        consider_whitespace_changes,
        &timeout,
        options,
        alignments,
        &hit_timeout
    );
    
    // Convert to line mappings
    DetailedLineRangeMappingArray* changes = line_range_mapping_from_range_mappings(
        alignments,
        original_lines, original_count,
        modified_lines, modified_count,
        false  // dontAssertStartLine
    );
    
    // VSCode: if (options.computeMoves) { moves = this.computeMoves(...); }
    //
    // SKIPPED: computeMoves is not implemented
    //
    // Reason: Neovim does not support moved block visualization in UI.
    // The computeMoves algorithm exists in VSCode at:
    //   src/vs/editor/common/diff/defaultLinesDiffComputer/computeMovedLines.ts
    //
    // When UI support is added, implement:
    // 1. Port computeMovedLines() function
    // 2. Port refineDiff for moved blocks
    // 3. Populate moves array instead of leaving it empty
    //
    // For now, always return empty moves array.
    
    // Create LinesDiff result
    LinesDiff* result = (LinesDiff*)malloc(sizeof(LinesDiff));
    if (!result) {
        free_detailed_line_range_mapping_array(changes);
        range_mapping_array_free(alignments);
        sequence_diff_array_free(line_alignments);
        return NULL;
    }
    
    // Transfer changes
    if (changes) {
        result->changes = *changes;
        free(changes);  // Free the container, not the contents
    } else {
        result->changes.mappings = NULL;
        result->changes.count = 0;
        result->changes.capacity = 0;
    }
    
    // No moves
    result->moves.moves = NULL;
    result->moves.count = 0;
    result->moves.capacity = 0;
    
    result->hit_timeout = hit_timeout;
    
    // Cleanup
    range_mapping_array_free(alignments);
    sequence_diff_array_free(line_alignments);
    
    return result;
}

/**
 * Free LinesDiff structure.
 * 
 * @param diff LinesDiff to free (can be NULL)
 */
void free_lines_diff(LinesDiff* diff) {
    if (!diff) return;
    
    if (diff->changes.mappings) {
        for (int i = 0; i < diff->changes.count; i++) {
            if (diff->changes.mappings[i].inner_changes) {
                free(diff->changes.mappings[i].inner_changes);
            }
        }
        free(diff->changes.mappings);
    }
    
    if (diff->moves.moves) {
        free(diff->moves.moves);
    }
    
    free(diff);
}

/**
 * Get library version.
 */
const char* get_version(void) {
    return "0.3.0-compute-diff";
}
