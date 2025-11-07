// ============================================================================
// Diff Tool - Standalone executable for computing and displaying diffs
// ============================================================================
//
// Usage: diff_tool [-t] <original_file> <modified_file>
//
// Options:
//   -t    Show timing information for compute_diff
//
// This tool:
// 1. Reads two files from disk
// 2. Uses compute_diff() to compute their LinesDiff
// 3. Uses print_utils to print the results
//
// ============================================================================

#include "default_lines_diff_computer.h"
#include "print_utils.h"
#include "types.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <stdbool.h>

// ============================================================================
// File Reading Utilities
// ============================================================================

/**
 * Read lines from a file into a dynamically allocated array.
 * Returns the number of lines read, or -1 on error.
 * 
 * IMPORTANT: Matches JavaScript's split('\n') behavior:
 *   - "a\nb\nc".split('\n') -> ["a", "b", "c"] (3 lines)
 *   - "a\nb\nc\n".split('\n') -> ["a", "b", "c", ""] (4 lines with trailing empty)
 *   - Keeps '\r' if present (doesn't strip it like fgets does)
 */
static int read_file_lines(const char* filename, char*** lines_out) {
    FILE* file = fopen(filename, "rb");
    if (!file) {
        fprintf(stderr, "Error: Cannot open file '%s'\n", filename);
        return -1;
    }
    
    // Read entire file content
    fseek(file, 0, SEEK_END);
    long file_size = ftell(file);
    fseek(file, 0, SEEK_SET);
    
    char* content = (char*)malloc(file_size + 1);
    if (!content) {
        fclose(file);
        return -1;
    }
    
    size_t bytes_read = fread(content, 1, file_size, file);
    content[bytes_read] = '\0';
    fclose(file);
    
    // Count lines by counting '\n' characters (matching JavaScript split('\n'))
    // This matches: "a\nb\nc".split('\n') -> ["a", "b", "c"] (3 lines)
    //               "a\nb\nc\n".split('\n') -> ["a", "b", "c", ""] (4 lines)
    int line_count = 1;  // At least one line (even empty file has 1 empty line)
    for (size_t i = 0; i < bytes_read; i++) {
        if (content[i] == '\n') {
            line_count++;
        }
    }
    
    // Allocate lines array
    char** lines = (char**)malloc(line_count * sizeof(char*));
    if (!lines) {
        free(content);
        return -1;
    }
    
    // Split by '\n' only, keeping '\r' if present (matching JavaScript behavior)
    // JavaScript: "line1\r\nline2\r\n".split('\n') -> ["line1\r", "line2\r", ""]
    int line_idx = 0;
    size_t line_start = 0;
    
    for (size_t i = 0; i <= bytes_read; i++) {
        if (i == bytes_read || content[i] == '\n') {
            // Extract line: everything from line_start to current position (excluding '\n')
            size_t line_len = i - line_start;
            
            lines[line_idx] = (char*)malloc(line_len + 1);
            if (!lines[line_idx]) {
                for (int j = 0; j < line_idx; j++) {
                    free(lines[j]);
                }
                free(lines);
                free(content);
                return -1;
            }
            
            memcpy(lines[line_idx], content + line_start, line_len);
            lines[line_idx][line_len] = '\0';
            line_idx++;
            line_start = i + 1;
        }
    }
    
    free(content);
    *lines_out = lines;
    return line_count;
}

/**
 * Free lines array.
 */
static void free_lines(char** lines, int count) {
    if (!lines) return;
    for (int i = 0; i < count; i++) {
        free(lines[i]);
    }
    free(lines);
}

// ============================================================================
// Main Program
// ============================================================================

int main(int argc, char* argv[]) {
    // Parse arguments
    bool show_timing = false;
    int file_arg_start = 1;

    if (argc > 1 && strcmp(argv[1], "-t") == 0) {
        show_timing = true;
        file_arg_start = 2;
    }

    // Check arguments
    if (argc - file_arg_start != 2) {
        fprintf(stderr, "Usage: %s [-t] <original_file> <modified_file>\n", argv[0]);
        return 1;
    }

    const char* original_file = argv[file_arg_start];
    const char* modified_file = argv[file_arg_start + 1];
    
    // Read original file
    char** original_lines = NULL;
    int original_count = read_file_lines(original_file, &original_lines);
    if (original_count < 0) {
        return 1;
    }
    
    // Read modified file
    char** modified_lines = NULL;
    int modified_count = read_file_lines(modified_file, &modified_lines);
    if (modified_count < 0) {
        free_lines(original_lines, original_count);
        return 1;
    }
    
    printf("=================================================================\n");
    printf("Diff Tool - Computing differences\n");
    printf("=================================================================\n");
    printf("Original: %s (%d lines)\n", original_file, original_count);
    printf("Modified: %s (%d lines)\n", modified_file, modified_count);
    printf("=================================================================\n\n");
    
    // Set up diff options (matching Lua FFI defaults)
    DiffOptions options = {
        .ignore_trim_whitespace = false,
        .max_computation_time_ms = 5000,  // 5 second timeout (same as Lua FFI)
        .compute_moves = false,
        .extend_to_subwords = false
    };

    // Compute diff with timing
    struct timespec start_time, end_time;
    clock_gettime(CLOCK_MONOTONIC, &start_time);
    LinesDiff* diff = compute_diff(
        (const char**)original_lines,
        original_count,
        (const char**)modified_lines,
        modified_count,
        &options
    );
    clock_gettime(CLOCK_MONOTONIC, &end_time);
    double elapsed_ms = (end_time.tv_sec - start_time.tv_sec) * 1000.0 + 
                        (end_time.tv_nsec - start_time.tv_nsec) / 1000000.0;
    
    if (!diff) {
        fprintf(stderr, "Error: Failed to compute diff\n");
        free_lines(original_lines, original_count);
        free_lines(modified_lines, modified_count);
        return 1;
    }
    
    // Print the results
    printf("Diff Results:\n");
    printf("=================================================================\n");
    printf("Number of changes: %d\n", diff->changes.count);
    printf("Hit timeout: %s\n", diff->hit_timeout ? "yes" : "no");
    printf("\n");
    
    if (diff->changes.count > 0) {
        print_detailed_line_range_mapping_array("Changes", &diff->changes);
    } else {
        printf("No differences found - files are identical.\n");
    }
    
    printf("\n=================================================================\n");
    
    if (show_timing) {
        printf("Computation time: %.3f ms\n", elapsed_ms);
    }
    
    // Cleanup
    free_lines_diff(diff);
    free_lines(original_lines, original_count);
    free_lines(modified_lines, modified_count);
    
    return 0;
}
