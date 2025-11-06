/**
 * Myers Diff Algorithms - ISequence Version
 * 
 * This implementation provides two algorithms with automatic selection:
 * 1. O(MN) DP algorithm - for small sequences (exact LCS with optional scoring)
 * 2. O(ND) Myers algorithm - for large sequences (space-efficient)
 * 
 * Algorithm selection matches VSCode exactly:
 * - Lines: DP if total < 1700, otherwise Myers O(ND)
 * - Chars: DP if total < 500, otherwise Myers O(ND)
 * 
 * INFRASTRUCTURE IMPROVEMENTS:
 * 1. ISequence interface - works with any sequence type (lines, chars)
 * 2. Hash-based comparison - fast element matching via getElement()
 * 3. Strong equality check - prevents hash collision issues
 * 4. Boundary scoring support - enables optimization in Steps 2-3
 * 5. Timeout protection - prevents hanging on massive diffs
 * 6. Size-based algorithm selection - matches VSCode behavior
 * 
 * VSCode Reference: 
 * - myersDiffAlgorithm.ts
 * - dynamicProgrammingDiffing.ts
 * - defaultLinesDiffComputer.ts
 */

#include "myers.h"
#include "sequence.h"
#include "string_hash_map.h"
#include <stdlib.h>
#include <string.h>
#include <time.h>

// Forward declarations
static int myers_get_x_after_snake(const ISequence *seq_a, const ISequence *seq_b, int x, int y);

// Helper: Min/Max functions
static int min_int(int a, int b) { return a < b ? a : b; }
static int max_int(int a, int b) { return a > b ? a : b; }

static double max_double(double a, double b) { return a > b ? a : b; }

//==============================================================================
// 2D Array Helper (for DP algorithm)
//==============================================================================

typedef struct {
  double *data;
  int rows;
  int cols;
} Array2D;

static Array2D *array2d_create(int rows, int cols) {
  Array2D *arr = (Array2D *)malloc(sizeof(Array2D));
  arr->rows = rows;
  arr->cols = cols;
  arr->data = (double *)calloc((size_t)(rows * cols), sizeof(double));
  return arr;
}

static void array2d_free(Array2D *arr) {
  free(arr->data);
  free(arr);
}

static double array2d_get(const Array2D *arr, int row, int col) {
  return arr->data[row * arr->cols + col];
}

static void array2d_set(Array2D *arr, int row, int col, double value) {
  arr->data[row * arr->cols + col] = value;
}

//==============================================================================
// O(MN) Dynamic Programming Diff Algorithm
// VSCode Reference: dynamicProgrammingDiffing.ts
//==============================================================================

/**
 * Myers O(MN) DP-based Diff Algorithm
 * 
 * A O(MN) diffing algorithm that supports a score function.
 * Uses dynamic programming to find the longest common subsequence (LCS).
 * 
 * This implementation matches VSCode's DynamicProgrammingDiffing exactly:
 * - Uses 3 matrices: lcsLengths, directions, lengths
 * - Supports optional equality scoring
 * - Prefers consecutive diagonals for better diff quality
 * - Backtracks to build SequenceDiff array
 * 
 * VSCode uses this for small sequences:
 * - Line-level: when total lines < 1700
 * - Char-level: when total chars < 500
 */
SequenceDiffArray *myers_dp_diff_algorithm(const ISequence *seq1, const ISequence *seq2,
                                           int timeout_ms, bool *hit_timeout,
                                           EqualityScoreFn score_fn, void *user_data) {
  if (hit_timeout)
    *hit_timeout = false;

  int len1 = seq1->getLength(seq1);
  int len2 = seq2->getLength(seq2);

  // Handle trivial cases
  if (len1 == 0 || len2 == 0) {
    SequenceDiffArray *result = (SequenceDiffArray *)malloc(sizeof(SequenceDiffArray));
    if (len1 == 0 && len2 == 0) {
      result->diffs = NULL;
      result->count = 0;
      result->capacity = 0;
    } else {
      result->diffs = (SequenceDiff *)malloc(sizeof(SequenceDiff));
      result->diffs[0].seq1_start = 0;
      result->diffs[0].seq1_end = len1;
      result->diffs[0].seq2_start = 0;
      result->diffs[0].seq2_end = len2;
      result->count = 1;
      result->capacity = 1;
    }
    return result;
  }

  // Create 3 matrices as in VSCode's implementation
  Array2D *lcs_lengths = array2d_create(len1, len2); // LCS length at each position
  Array2D *directions =
      array2d_create(len1, len2); // Direction taken (1=horizontal, 2=vertical, 3=diagonal)
  Array2D *lengths = array2d_create(len1, len2); // Length of consecutive diagonals

  // Timeout tracking
  clock_t start_time = clock();
  double timeout_seconds = timeout_ms / 1000.0;
  int timeout_check_counter = 0;
  const int TIMEOUT_CHECK_INTERVAL = 1024;

  // Fill matrices (VSCode's algorithm)
  for (int s1 = 0; s1 < len1; s1++) {
    for (int s2 = 0; s2 < len2; s2++) {
      // Check timeout periodically (not on every iteration to avoid overhead)
      if (timeout_ms > 0 && ++timeout_check_counter >= TIMEOUT_CHECK_INTERVAL) {
        timeout_check_counter = 0;
        clock_t current_time = clock();
        double elapsed = (double)(current_time - start_time) / CLOCKS_PER_SEC;
        if (elapsed > timeout_seconds) {
          if (hit_timeout)
            *hit_timeout = true;

          // Return trivial diff
          array2d_free(lcs_lengths);
          array2d_free(directions);
          array2d_free(lengths);

          SequenceDiffArray *result = (SequenceDiffArray *)malloc(sizeof(SequenceDiffArray));
          result->diffs = (SequenceDiff *)malloc(sizeof(SequenceDiff));
          result->diffs[0].seq1_start = 0;
          result->diffs[0].seq1_end = len1;
          result->diffs[0].seq2_start = 0;
          result->diffs[0].seq2_end = len2;
          result->count = 1;
          result->capacity = 1;
          return result;
        }
      }

      // Get values from previous cells
      double horizontal_len = (s1 == 0) ? 0 : array2d_get(lcs_lengths, s1 - 1, s2);
      double vertical_len = (s2 == 0) ? 0 : array2d_get(lcs_lengths, s1, s2 - 1);

      // Calculate diagonal score
      double extended_seq_score;
      if (seq1->getElement(seq1, s1) == seq2->getElement(seq2, s2)) {
        if (s1 == 0 || s2 == 0) {
          extended_seq_score = 0;
        } else {
          extended_seq_score = array2d_get(lcs_lengths, s1 - 1, s2 - 1);
        }

        // Prefer consecutive diagonals (VSCode optimization)
        if (s1 > 0 && s2 > 0 && array2d_get(directions, s1 - 1, s2 - 1) == 3) {
          extended_seq_score += array2d_get(lengths, s1 - 1, s2 - 1);
        }

        // Add equality score
        if (score_fn) {
          extended_seq_score += score_fn(seq1, seq2, s1, s2, user_data);
        } else {
          extended_seq_score += 1.0;
        }
      } else {
        extended_seq_score = -1;
      }

      // Choose best direction
      double new_value = max_double(max_double(horizontal_len, vertical_len), extended_seq_score);

      if (new_value == extended_seq_score) {
        // Prefer diagonals (matching elements)
        double prev_len = (s1 > 0 && s2 > 0) ? array2d_get(lengths, s1 - 1, s2 - 1) : 0;
        array2d_set(lengths, s1, s2, prev_len + 1);
        array2d_set(directions, s1, s2, 3); // Diagonal
      } else if (new_value == horizontal_len) {
        array2d_set(lengths, s1, s2, 0);
        array2d_set(directions, s1, s2, 1); // Horizontal (delete from seq1)
      } else if (new_value == vertical_len) {
        array2d_set(lengths, s1, s2, 0);
        array2d_set(directions, s1, s2, 2); // Vertical (insert into seq1)
      }

      array2d_set(lcs_lengths, s1, s2, new_value);
    }
  }

  // Backtrack to build diffs (VSCode's algorithm)
  // First pass: count diffs
  int diff_count = 0;
  int s1 = len1 - 1;
  int s2 = len2 - 1;
  int last_align_s1 = len1;
  int last_align_s2 = len2;

  while (s1 >= 0 && s2 >= 0) {
    int dir = (int)array2d_get(directions, s1, s2);
    if (dir == 3) {
      // Diagonal - this is a match, emit diff if needed
      if (s1 + 1 != last_align_s1 || s2 + 1 != last_align_s2) {
        diff_count++;
      }
      last_align_s1 = s1;
      last_align_s2 = s2;
      s1--;
      s2--;
    } else if (dir == 1) {
      // Horizontal
      s1--;
    } else {
      // Vertical
      s2--;
    }
  }

  // Final diff if needed
  if (0 != last_align_s1 || 0 != last_align_s2) {
    diff_count++;
  }

  // Second pass: build result
  SequenceDiffArray *result = (SequenceDiffArray *)malloc(sizeof(SequenceDiffArray));
  result->count = diff_count;
  result->capacity = diff_count;
  result->diffs = diff_count > 0 ? (SequenceDiff *)malloc((size_t)diff_count * sizeof(SequenceDiff)) : NULL;

  s1 = len1 - 1;
  s2 = len2 - 1;
  last_align_s1 = len1;
  last_align_s2 = len2;
  int idx = diff_count - 1;

  while (s1 >= 0 && s2 >= 0) {
    int dir = (int)array2d_get(directions, s1, s2);
    if (dir == 3) {
      // Diagonal - emit diff if there was a gap
      if (s1 + 1 != last_align_s1 || s2 + 1 != last_align_s2) {
        result->diffs[idx].seq1_start = s1 + 1;
        result->diffs[idx].seq1_end = last_align_s1;
        result->diffs[idx].seq2_start = s2 + 1;
        result->diffs[idx].seq2_end = last_align_s2;
        idx--;
      }
      last_align_s1 = s1;
      last_align_s2 = s2;
      s1--;
      s2--;
    } else if (dir == 1) {
      s1--;
    } else {
      s2--;
    }
  }

  // Final diff
  if (0 != last_align_s1 || 0 != last_align_s2) {
    result->diffs[idx].seq1_start = 0;
    result->diffs[idx].seq1_end = last_align_s1;
    result->diffs[idx].seq2_start = 0;
    result->diffs[idx].seq2_end = last_align_s2;
  }

  // Cleanup
  array2d_free(lcs_lengths);
  array2d_free(directions);
  array2d_free(lengths);

  return result;
}

//==============================================================================
// O(ND) Myers Forward Algorithm
// VSCode Reference: myersDiffAlgorithm.ts
//==============================================================================

// Simple dynamic array for storing integers (supports negative indices)
typedef struct {
  int *positive;
  int *negative;
  int pos_capacity;
  int neg_capacity;
} IntArray;

static IntArray *intarray_create(void) {
  IntArray *arr = (IntArray *)malloc(sizeof(IntArray));
  arr->pos_capacity = 10;
  arr->neg_capacity = 10;
  arr->positive = (int *)calloc((size_t)arr->pos_capacity, sizeof(int));
  arr->negative = (int *)calloc((size_t)arr->neg_capacity, sizeof(int));
  return arr;
}

static void intarray_free(IntArray *arr) {
  free(arr->positive);
  free(arr->negative);
  free(arr);
}

static int intarray_get(IntArray *arr, int idx) {
  if (idx < 0) {
    int neg_idx = -idx - 1;
    return (neg_idx < arr->neg_capacity) ? arr->negative[neg_idx] : 0;
  } else {
    return (idx < arr->pos_capacity) ? arr->positive[idx] : 0;
  }
}

static void intarray_set(IntArray *arr, int idx, int value) {
  if (idx < 0) {
    int neg_idx = -idx - 1;
    if (neg_idx >= arr->neg_capacity) {
      int new_cap = arr->neg_capacity * 2;
      while (neg_idx >= new_cap)
        new_cap *= 2;
      arr->negative = (int *)realloc(arr->negative, (size_t)new_cap * sizeof(int));
      memset(arr->negative + arr->neg_capacity, 0, (size_t)(new_cap - arr->neg_capacity) * sizeof(int));
      arr->neg_capacity = new_cap;
    }
    arr->negative[neg_idx] = value;
  } else {
    if (idx >= arr->pos_capacity) {
      int new_cap = arr->pos_capacity * 2;
      while (idx >= new_cap)
        new_cap *= 2;
      arr->positive = (int *)realloc(arr->positive, (size_t)new_cap * sizeof(int));
      memset(arr->positive + arr->pos_capacity, 0, (size_t)(new_cap - arr->pos_capacity) * sizeof(int));
      arr->pos_capacity = new_cap;
    }
    arr->positive[idx] = value;
  }
}

// Simple path structure to track snake paths
typedef struct SnakePath {
  struct SnakePath *prev;
  int x;
  int y;
  int length;
} SnakePath;

static SnakePath *snakepath_create(SnakePath *prev, int x, int y, int length) {
  SnakePath *path = (SnakePath *)malloc(sizeof(SnakePath));
  path->prev = prev;
  path->x = x;
  path->y = y;
  path->length = length;
  return path;
}

static void snakepath_free_chain(SnakePath *path) {
  while (path) {
    SnakePath *prev = path->prev;
    free(path);
    path = prev;
  }
}

// Dynamic array for storing SnakePath pointers (supports negative indices)
typedef struct {
  SnakePath **positive;
  SnakePath **negative;
  int pos_capacity;
  int neg_capacity;
} PathArray;

static PathArray *patharray_create(void) {
  PathArray *arr = (PathArray *)malloc(sizeof(PathArray));
  arr->pos_capacity = 10;
  arr->neg_capacity = 10;
  arr->positive = (SnakePath **)calloc((size_t)arr->pos_capacity, sizeof(SnakePath *));
  arr->negative = (SnakePath **)calloc((size_t)arr->neg_capacity, sizeof(SnakePath *));
  return arr;
}

static void patharray_free(PathArray *arr) {
  // Note: We don't free individual paths here as they're freed later
  free(arr->positive);
  free(arr->negative);
  free(arr);
}

static SnakePath *patharray_get(PathArray *arr, int idx) {
  if (idx < 0) {
    int neg_idx = -idx - 1;
    return (neg_idx < arr->neg_capacity) ? arr->negative[neg_idx] : NULL;
  } else {
    return (idx < arr->pos_capacity) ? arr->positive[idx] : NULL;
  }
}

static void patharray_set(PathArray *arr, int idx, SnakePath *value) {
  if (idx < 0) {
    int neg_idx = -idx - 1;
    if (neg_idx >= arr->neg_capacity) {
      int new_cap = arr->neg_capacity * 2;
      while (neg_idx >= new_cap)
        new_cap *= 2;
      arr->negative = (SnakePath **)realloc(arr->negative, (size_t)new_cap * sizeof(SnakePath *));
      memset(arr->negative + arr->neg_capacity, 0,
             (size_t)(new_cap - arr->neg_capacity) * sizeof(SnakePath *));
      arr->neg_capacity = new_cap;
    }
    arr->negative[neg_idx] = value;
  } else {
    if (idx >= arr->pos_capacity) {
      int new_cap = arr->pos_capacity * 2;
      while (idx >= new_cap)
        new_cap *= 2;
      arr->positive = (SnakePath **)realloc(arr->positive, (size_t)new_cap * sizeof(SnakePath *));
      memset(arr->positive + arr->pos_capacity, 0,
             (size_t)(new_cap - arr->pos_capacity) * sizeof(SnakePath *));
      arr->pos_capacity = new_cap;
    }
    arr->positive[idx] = value;
  }
}

// Helper: Get X position after following snake (diagonal matches)
// Now uses ISequence.getElement() for hash-based comparison
static int myers_get_x_after_snake(const ISequence *seq_a, const ISequence *seq_b, int x, int y) {
  int len_a = seq_a->getLength(seq_a);
  int len_b = seq_b->getLength(seq_b);

  while (x < len_a && y < len_b && seq_a->getElement(seq_a, x) == seq_b->getElement(seq_b, y)) {
    x++;
    y++;
  }
  return x;
}

// Main Myers O(ND) Forward Algorithm
// (Renamed from myers_diff_algorithm to myers_nd_diff_algorithm)
SequenceDiffArray *myers_nd_diff_algorithm(const ISequence *seq1, const ISequence *seq2,
                                           int timeout_ms, bool *hit_timeout) {
  if (hit_timeout)
    *hit_timeout = false;

  int len_a = seq1->getLength(seq1);
  int len_b = seq2->getLength(seq2);

  // Handle trivial cases
  if (len_a == 0 || len_b == 0) {
    SequenceDiffArray *result = (SequenceDiffArray *)malloc(sizeof(SequenceDiffArray));
    if (len_a == 0 && len_b == 0) {
      result->diffs = NULL;
      result->count = 0;
      result->capacity = 0;
    } else {
      result->diffs = (SequenceDiff *)malloc(sizeof(SequenceDiff));
      result->diffs[0].seq1_start = 0;
      result->diffs[0].seq1_end = len_a;
      result->diffs[0].seq2_start = 0;
      result->diffs[0].seq2_end = len_b;
      result->count = 1;
      result->capacity = 1;
    }
    return result;
  }

  IntArray *V = intarray_create();
  PathArray *paths = patharray_create();

  int initial_x = myers_get_x_after_snake(seq1, seq2, 0, 0);
  intarray_set(V, 0, initial_x);
  patharray_set(paths, 0, initial_x == 0 ? NULL : snakepath_create(NULL, 0, 0, initial_x));

  int d = 0;
  int k = 0;
  int found = 0;

  // Timeout tracking
  clock_t start_time = clock();
  double timeout_seconds = timeout_ms / 1000.0;

  // Main loop: increase edit distance until we reach the end
  while (!found) {
    d++;

    // Check timeout (VSCode's timeout support)
    if (timeout_ms > 0) {
      clock_t current_time = clock();
      double elapsed = (double)(current_time - start_time) / CLOCKS_PER_SEC;
      if (elapsed > timeout_seconds) {
        if (hit_timeout)
          *hit_timeout = true;

        // Return trivial diff (entire range changed)
        intarray_free(V);
        patharray_free(paths);

        SequenceDiffArray *result = (SequenceDiffArray *)malloc(sizeof(SequenceDiffArray));
        result->diffs = (SequenceDiff *)malloc(sizeof(SequenceDiff));
        result->diffs[0].seq1_start = 0;
        result->diffs[0].seq1_end = len_a;
        result->diffs[0].seq2_start = 0;
        result->diffs[0].seq2_end = len_b;
        result->count = 1;
        result->capacity = 1;
        return result;
      }
    }

    // Bounds for diagonals we need to consider
    int lower_bound = -min_int(d, len_b + (d % 2));
    int upper_bound = min_int(d, len_a + (d % 2));

    for (k = lower_bound; k <= upper_bound; k += 2) {
      // Determine whether to go down (insert) or right (delete)
      int max_x_top = (k == upper_bound) ? -1 : intarray_get(V, k + 1);
      int max_x_left = (k == lower_bound) ? -1 : intarray_get(V, k - 1) + 1;

      int x = min_int(max_int(max_x_top, max_x_left), len_a);
      int y = x - k;

      // Skip invalid diagonals
      if (x > len_a || y > len_b) {
        continue;
      }

      // Follow snake (diagonal matches)
      int new_max_x = myers_get_x_after_snake(seq1, seq2, x, y);
      intarray_set(V, k, new_max_x);

      // Track path
      SnakePath *last_path =
          (x == max_x_top) ? patharray_get(paths, k + 1) : patharray_get(paths, k - 1);
      SnakePath *new_path =
          (new_max_x != x) ? snakepath_create(last_path, x, y, new_max_x - x) : last_path;
      patharray_set(paths, k, new_path);

      // Check if we reached the end
      if (intarray_get(V, k) == len_a && intarray_get(V, k) - k == len_b) {
        found = 1;
        break;
      }
    }
  }

  // Build result from path
  SnakePath *path = patharray_get(paths, k);

  // Count diffs first
  int diff_count = 0;
  int last_pos_a = len_a;
  int last_pos_b = len_b;
  SnakePath *temp_path = path;

  while (1) {
    int end_x = temp_path ? temp_path->x + temp_path->length : 0;
    int end_y = temp_path ? temp_path->y + temp_path->length : 0;

    if (end_x != last_pos_a || end_y != last_pos_b) {
      diff_count++;
    }
    if (!temp_path)
      break;

    last_pos_a = temp_path->x;
    last_pos_b = temp_path->y;
    temp_path = temp_path->prev;
  }

  // Allocate result
  SequenceDiffArray *result = (SequenceDiffArray *)malloc(sizeof(SequenceDiffArray));
  result->count = diff_count;
  result->capacity = diff_count;
  result->diffs = diff_count > 0 ? (SequenceDiff *)malloc((size_t)diff_count * sizeof(SequenceDiff)) : NULL;

  // Fill result (in reverse order, then we'll reverse)
  int idx = diff_count - 1;
  last_pos_a = len_a;
  last_pos_b = len_b;

  while (1) {
    int end_x = path ? path->x + path->length : 0;
    int end_y = path ? path->y + path->length : 0;

    if (end_x != last_pos_a || end_y != last_pos_b) {
      result->diffs[idx].seq1_start = end_x;
      result->diffs[idx].seq1_end = last_pos_a;
      result->diffs[idx].seq2_start = end_y;
      result->diffs[idx].seq2_end = last_pos_b;
      idx--;
    }

    if (!path)
      break;

    last_pos_a = path->x;
    last_pos_b = path->y;
    path = path->prev;
  }

  // Clean up - free the entire path chain from final path
  SnakePath *final_path = patharray_get(paths, k);
  snakepath_free_chain(final_path);

  intarray_free(V);
  patharray_free(paths);

  return result;
}

//==============================================================================
//==============================================================================
// Legacy API for backward compatibility
//==============================================================================

/**
 * Legacy wrapper for backward compatibility
 * 
 * Creates LineSequence wrappers and calls the appropriate algorithm.
 * This function is DEPRECATED - use compute_line_alignments() from line_level.h instead.
 * 
 * @deprecated Use compute_line_alignments() from line_level.h for line-level diffs
 */
SequenceDiffArray *myers_diff_lines(const char **lines_a, int len_a, const char **lines_b,
                                    int len_b) {
  // Create shared hash map for both sequences (ensures hash consistency)
  StringHashMap *hash_map = string_hash_map_create();

  // Create LineSequence wrappers (no whitespace trimming for backward compat)
  ISequence *seq_a = line_sequence_create(lines_a, len_a, false, hash_map);
  ISequence *seq_b = line_sequence_create(lines_b, len_b, false, hash_map);

  // Algorithm selection (simple version without equality scoring)
  int total = len_a + len_b;
  bool hit_timeout = false;
  SequenceDiffArray *result;

  if (total < 1700) {
    // Small file: use DP without scoring (backward compat)
    result = myers_dp_diff_algorithm(seq_a, seq_b, 0, &hit_timeout, NULL, NULL);
  } else {
    // Large file: use O(ND)
    result = myers_nd_diff_algorithm(seq_a, seq_b, 0, &hit_timeout);
  }

  // Cleanup sequences and hash map
  seq_a->destroy(seq_a);
  seq_b->destroy(seq_b);
  string_hash_map_destroy(hash_map);

  return result;
}
