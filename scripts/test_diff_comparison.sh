#!/bin/bash

# Test script to compare C diff tool and Node vscode-diff.mjs outputs
# Dynamically tests top N most revised files from git history (origin/main)
#
# Usage: ./test_diff_comparison.sh [OPTIONS]
#   -q, --quiet      Quiet mode: only show summary (tests/mismatches)
#   (no options)     Normal mode: show progress and summary
#   -v, --verbose    Verbose mode: show detailed output

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
EXAMPLE_DIR="$REPO_ROOT/example"
C_DIFF="$REPO_ROOT/build/libvscode-diff/diff"
NODE_DIFF="$REPO_ROOT/vscode-diff.mjs"
TEMP_DIR="/tmp/diff_comparison_$$"

# Configuration: Number of top revised files to test
NUM_TOP_FILES=10
TESTS_PER_FILE=30
# Use origin/main as the reference point for consistent results
BASE_REF="origin/main"
# Verbosity level: 0=quiet, 1=normal, 2=verbose
VERBOSITY=1

# Parse command line arguments
for arg in "$@"; do
    case $arg in
        -q|--quiet)
            VERBOSITY=0
            shift
            ;;
        -v|--verbose)
            VERBOSITY=2
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  -q, --quiet      Quiet mode: only show summary (tests/mismatches)"
            echo "                   Perfect for comparing test runs"
            echo "  (no options)     Normal mode: show progress and summary"
            echo "  -v, --verbose    Verbose mode: show all details and performance"
            echo "  -h, --help       Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $arg"
            echo "Use -h or --help for usage information"
            exit 1
            ;;
    esac
done

mkdir -p "$TEMP_DIR"

# Always rebuild C diff binary to ensure latest changes
if [ $VERBOSITY -ge 1 ]; then
    echo "Building C diff binary with clean build..."
fi
cd "$REPO_ROOT"
# Remove old binary and object files to force rebuild
rm -f build/libvscode-diff/diff
find build/libvscode-diff/CMakeFiles/diff.dir -name "*.o" -delete 2>/dev/null || true
# Reconfigure if needed and build
cmake -B build > /dev/null 2>&1
cmake --build build --target diff > /dev/null 2>&1
if [ ! -f "$C_DIFF" ]; then
    echo "Error: Failed to build C diff binary" >&2
    exit 1
fi
if [ $VERBOSITY -ge 1 ]; then
    echo "✓ C diff binary built successfully"
    echo ""
fi

if [ ! -f "$NODE_DIFF" ]; then
    if [ $VERBOSITY -ge 1 ]; then
        echo "Node diff binary not found. Building..."
    fi
    "$SCRIPT_DIR/build-vscode-diff.sh" > /dev/null 2>&1
    if [ ! -f "$NODE_DIFF" ]; then
        echo "Error: Failed to build Node diff binary" >&2
        exit 1
    fi
fi

# Function to generate example files for top N most revised files
generate_example_files() {
    local num_files=$1
    if [ $VERBOSITY -ge 2 ]; then
        echo "Generating example files for top $num_files most revised files from $BASE_REF..."
    fi
    
    # Create example directory
    mkdir -p "$EXAMPLE_DIR"
    
    # Get all files that exist in BASE_REF
    if [ $VERBOSITY -ge 2 ]; then
        echo "Counting revisions for files in $BASE_REF (this may take a moment)..."
    fi
    
    # Create temporary file to store file:revision pairs
    local temp_file=$(mktemp)
    
    git -C "$REPO_ROOT" ls-tree -r --name-only "$BASE_REF" | while read file; do
        local revisions=$(git -C "$REPO_ROOT" log "$BASE_REF" --follow --oneline -- "$file" 2>/dev/null | wc -l)
        if [ $revisions -gt 0 ]; then
            echo "$revisions $file" >> "$temp_file"
        fi
    done
    
    # Sort by revision count and take top N
    local files=($(sort -rn "$temp_file" | head -$num_files | awk '{print $2}'))
    rm -f "$temp_file"
    
    if [ $VERBOSITY -ge 2 ]; then
        echo ""
        echo "Top $num_files most revised files (as of $BASE_REF, with rename tracking):"
        for i in "${!files[@]}"; do
            local file="${files[$i]}"
            local revisions=$(git -C "$REPO_ROOT" log "$BASE_REF" --follow --oneline -- "$file" 2>/dev/null | wc -l)
            echo "  $((i+1)). $file ($revisions revisions)"
        done
        echo ""
    fi
    
    # For each top file, save all its git history versions up to BASE_REF
    for file in "${files[@]}"; do
        if [ $VERBOSITY -ge 2 ]; then
            echo "Processing $file..."
        fi
        
        # Check if file exists at BASE_REF
        if ! git -C "$REPO_ROOT" cat-file -e "$BASE_REF:$file" 2>/dev/null; then
            if [ $VERBOSITY -ge 2 ]; then
                echo "  Warning: $file not found at $BASE_REF, skipping"
            fi
            continue
        fi
        
        local basename=$(basename "$file")
        
        # Get all commits that modified this file up to BASE_REF
        # Note: --reverse doesn't work with --follow, so we get them in reverse-chronological order
        # and then reverse the array
        local commits_reverse=($(git -C "$REPO_ROOT" log "$BASE_REF" --follow --format=%H -- "$file"))
        
        # Reverse the array to get chronological order
        local commits=()
        for ((i=${#commits_reverse[@]}-1; i>=0; i--)); do
            commits+=("${commits_reverse[i]}")
        done
        
        if [ $VERBOSITY -ge 2 ]; then
            echo "  Found ${#commits[@]} commits (saving in chronological order)"
        fi
        
        # Build a map of commit -> filepath by walking through rename history
        # Start with the current filename and walk backwards through renames
        declare -A commit_paths
        local current_path="$file"
        
        # Get all renames in chronological order
        local rename_info=$(git -C "$REPO_ROOT" log "$BASE_REF" --follow --format='%H' --name-status --diff-filter=R -- "$file")
        
        # Parse rename information to build a timeline
        local last_commit=""
        while IFS= read -r line; do
            if [[ $line =~ ^[0-9a-f]{40}$ ]]; then
                last_commit="$line"
            elif [[ $line =~ ^R[0-9]*[[:space:]]+(.*)[[:space:]]+(.*)\$ ]]; then
                # Format: R100 old_path new_path
                local old_path=$(echo "$line" | awk '{print $2}')
                local new_path=$(echo "$line" | awk '{print $3}')
                # At this commit, file was renamed from old_path to new_path
                # So commits before this used old_path, commits after use new_path
                if [ -n "$last_commit" ]; then
                    echo "DEBUG: Rename at $last_commit: $old_path -> $new_path" >&2
                fi
            fi
        done <<< "$rename_info"
        
        # Save each version with sequence number and commit hash for ordering
        local count=0
        for idx in "${!commits[@]}"; do
            local commit="${commits[$idx]}"
            # Use zero-padded index for proper sorting (e.g., 001, 002, ...)
            local seq=$(printf "%03d" $idx)
            local output_file="$EXAMPLE_DIR/${basename}_${seq}_${commit}"
            
            # Try to extract with current filename first
            if git -C "$REPO_ROOT" show "$commit:$file" > "$output_file" 2>/dev/null; then
                count=$((count + 1))
            else
                # If that fails, try to find the file by basename in the commit
                local found=false
                while IFS= read -r potential_path; do
                    if [[ "$(basename "$potential_path")" == "$basename" ]]; then
                        if git -C "$REPO_ROOT" show "$commit:$potential_path" > "$output_file" 2>/dev/null; then
                            count=$((count + 1))
                            found=true
                            break
                        fi
                    fi
                done < <(git -C "$REPO_ROOT" ls-tree -r --name-only "$commit")
                
                if [ "$found" = false ]; then
                    rm -f "$output_file"
                fi
            fi
        done
        
        if [ $VERBOSITY -ge 2 ]; then
            echo "  Saved $count versions in chronological order"
        fi
    done
    
    if [ $VERBOSITY -ge 2 ]; then
        echo ""
        echo "Done! Example files generated in $EXAMPLE_DIR"
        echo "Total files: $(ls -1 "$EXAMPLE_DIR" | wc -l)"
    fi
}

# Get top N most revised files from git history up to BASE_REF
if [ $VERBOSITY -ge 1 ]; then
    echo "Finding top $NUM_TOP_FILES most revised files from git history (up to $BASE_REF)..."
fi
# Note: Can't use --follow here as it requires a single pathspec
# We'll use --follow when counting individual file revisions
TOP_FILES=($(git -C "$REPO_ROOT" log "$BASE_REF" --pretty=format: --name-only | \
    grep -v '^$' | sort | uniq -c | sort -rn | head -$NUM_TOP_FILES | awk '{print $2}'))

# Check if we need to regenerate example files
NEED_REGENERATE=false
for TOP_FILE in "${TOP_FILES[@]}"; do
    BASENAME=$(basename "$TOP_FILE")
    FILES_COUNT=$(ls -1 "$EXAMPLE_DIR"/${BASENAME}_* 2>/dev/null | wc -l)
    if [ $FILES_COUNT -eq 0 ]; then
        NEED_REGENERATE=true
        break
    fi
done

if [ "$NEED_REGENERATE" = true ]; then
    if [ $VERBOSITY -ge 1 ]; then
        echo "Example files missing or incomplete. Regenerating..."
    fi
    generate_example_files $NUM_TOP_FILES
    if [ $VERBOSITY -ge 1 ]; then
        echo ""
    fi
fi

if [ $VERBOSITY -ge 2 ]; then
    echo "Top revised files (as of $BASE_REF, with rename tracking):"
    for i in "${!TOP_FILES[@]}"; do
        # Use --follow to track renames for each individual file
        REVISIONS=$(git -C "$REPO_ROOT" log "$BASE_REF" --follow --oneline -- "${TOP_FILES[$i]}" | wc -l)
        echo "  $((i+1)). ${TOP_FILES[$i]} ($REVISIONS revisions)"
    done
    echo ""
fi

# Collect version files for each top file (skip files with 0 versions)
declare -a FILE_GROUPS
declare -a VALID_TOP_FILES
declare -A FILE_METRICS  # Store file metrics (lines, size)
for TOP_FILE in "${TOP_FILES[@]}"; do
    BASENAME=$(basename "$TOP_FILE")
    # Files are now named: basename_SEQ_HASH, sort by SEQ for chronological order
    FILES=($(ls -1 "$EXAMPLE_DIR"/${BASENAME}_* 2>/dev/null | sort))
    if [ ${#FILES[@]} -gt 0 ]; then
        FILE_GROUPS+=("${#FILES[@]}")
        eval "FILES_${BASENAME//[^a-zA-Z0-9]/_}=(${FILES[@]})"
        VALID_TOP_FILES+=("$TOP_FILE")
        
        # Get metrics from the latest version (last file in chronological order)
        LATEST_FILE="${FILES[-1]}"
        LINES=$(wc -l < "$LATEST_FILE" 2>/dev/null || echo "0")
        SIZE_BYTES=$(stat -f%z "$LATEST_FILE" 2>/dev/null || stat -c%s "$LATEST_FILE" 2>/dev/null || echo "0")
        SIZE_KB=$(awk "BEGIN {printf \"%.1f\", $SIZE_BYTES/1024}")
        FILE_METRICS["$BASENAME"]="${LINES}L ${SIZE_KB}KB"
        
        if [ $VERBOSITY -ge 2 ]; then
            echo "Found ${#FILES[@]} versions of $BASENAME (chronologically ordered)"
        fi
    fi
done
if [ $VERBOSITY -ge 2 ]; then
    echo ""
fi

# Update TOP_FILES to only include files with versions
TOP_FILES=("${VALID_TOP_FILES[@]}")

TOTAL_TESTS=0
MISMATCHES=0
MISMATCH_DETAILS=""

# Timing arrays per file
declare -A C_TIMES
declare -A NODE_TIMES
declare -A TEST_COUNTS

# Function to test a pair of files
test_pair() {
    local FILE1="$1"
    local FILE2="$2"
    local TEST_ID="$3"
    local FILE_GROUP="$4"
    
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    
    # Get base filenames for display
    BASE1=$(basename "$FILE1")
    BASE2=$(basename "$FILE2")
    
    # Run C diff tool with timing
    C_OUTPUT="$TEMP_DIR/c_output_${TEST_ID}.txt"
    C_START=$(($(date +%s%N)/1000000))
    "$C_DIFF" "$FILE1" "$FILE2" > "$C_OUTPUT" 2>&1
    C_EXIT=$?
    C_END=$(($(date +%s%N)/1000000))
    C_TIME=$((C_END - C_START))
    # Sanity check: ensure non-negative timing
    [ $C_TIME -lt 0 ] && C_TIME=0
    
    # Run Node diff tool with timing
    NODE_OUTPUT="$TEMP_DIR/node_output_${TEST_ID}.txt"
    NODE_START=$(($(date +%s%N)/1000000))
    node "$NODE_DIFF" "$FILE1" "$FILE2" > "$NODE_OUTPUT" 2>&1
    NODE_EXIT=$?
    NODE_END=$(($(date +%s%N)/1000000))
    NODE_TIME=$((NODE_END - NODE_START))
    # Sanity check: ensure non-negative timing
    [ $NODE_TIME -lt 0 ] && NODE_TIME=0
    
    # Accumulate timing stats
    C_TIMES[$FILE_GROUP]=$((${C_TIMES[$FILE_GROUP]:-0} + C_TIME))
    NODE_TIMES[$FILE_GROUP]=$((${NODE_TIMES[$FILE_GROUP]:-0} + NODE_TIME))
    TEST_COUNTS[$FILE_GROUP]=$((${TEST_COUNTS[$FILE_GROUP]:-0} + 1))
    
    # Compare outputs
    if ! diff -q "$C_OUTPUT" "$NODE_OUTPUT" > /dev/null 2>&1; then
        MISMATCHES=$((MISMATCHES + 1))
        MISMATCH_DETAILS="${MISMATCH_DETAILS}Mismatch #${MISMATCHES} (Test #${TOTAL_TESTS}):\n"
        MISMATCH_DETAILS="${MISMATCH_DETAILS}  Files: $BASE1 vs $BASE2\n"
        MISMATCH_DETAILS="${MISMATCH_DETAILS}  C exit: $C_EXIT, Node exit: $NODE_EXIT\n"
        MISMATCH_DETAILS="${MISMATCH_DETAILS}  C output: $C_OUTPUT\n"
        MISMATCH_DETAILS="${MISMATCH_DETAILS}  Node output: $NODE_OUTPUT\n\n"
    fi
    
    # Progress indicator every 10 tests (normal and verbose only)
    if [ $VERBOSITY -ge 1 ] && [ $((TOTAL_TESTS % 10)) -eq 0 ]; then
        echo "Progress: $TOTAL_TESTS tests completed, $MISMATCHES mismatches found"
    fi
}

# Test each file group with real-world commit distances
for FILE_IDX in "${!TOP_FILES[@]}"; do
    TOP_FILE="${TOP_FILES[$FILE_IDX]}"
    BASENAME=$(basename "$TOP_FILE")
    VAR_NAME="FILES_${BASENAME//[^a-zA-Z0-9]/_}[@]"
    eval "FILE_ARRAY=(\${$VAR_NAME})"
    NUM_FILES=${#FILE_ARRAY[@]}
    
    if [ $VERBOSITY -ge 1 ]; then
        echo "Testing $BASENAME versions (target: $TESTS_PER_FILE tests)..."
        if [ $VERBOSITY -ge 2 ]; then
            echo "  Strategy: consecutive commits first, then increasing distances"
        fi
    fi
    TESTS_BEFORE=$TOTAL_TESTS
    
    # Test with increasing commit distances: 1, 2, 3, 4, 5, ...
    # This simulates real-world usage where users typically diff nearby commits
    for ((distance=1; distance<$NUM_FILES && (TOTAL_TESTS - TESTS_BEFORE)<$TESTS_PER_FILE; distance++)); do
        # For each distance, test all consecutive pairs with that distance
        for ((i=0; i+distance<$NUM_FILES && (TOTAL_TESTS - TESTS_BEFORE)<$TESTS_PER_FILE; i++)); do
            j=$((i + distance))
            test_pair "${FILE_ARRAY[$i]}" "${FILE_ARRAY[$j]}" "${BASENAME//[^a-zA-Z0-9]/_}_d${distance}_${i}_${j}" "$BASENAME"
        done
    done
    if [ $VERBOSITY -ge 1 ]; then
        echo ""
    fi
done

# Output based on verbosity level
if [ $VERBOSITY -eq 0 ]; then
    # Quiet mode: single line for easy comparison
    echo "$TOTAL_TESTS $MISMATCHES"
else
    # Normal and verbose modes
    echo ""
    echo "========================================"
    echo "SUMMARY"
    echo "========================================"
    echo "Total tests run: $TOTAL_TESTS"
    echo "Mismatches found: $MISMATCHES"
    echo ""
    
    if [ $MISMATCHES -gt 0 ]; then
        if [ $VERBOSITY -ge 2 ]; then
            echo "MISMATCH DETAILS:"
            echo "========================================"
            echo -e "$MISMATCH_DETAILS"
            echo ""
            echo "Showing first mismatch in detail:"
            echo "========================================"
            
            # Show first mismatch
            FIRST_C=$(ls -1 "$TEMP_DIR"/c_output_*.txt 2>/dev/null | head -1)
            FIRST_NODE="${FIRST_C/c_output/node_output}"
            
            if [ -f "$FIRST_C" ] && [ -f "$FIRST_NODE" ]; then
                echo "C diff output:"
                echo "---"
                head -50 "$FIRST_C"
                echo ""
                echo "Node diff output:"
                echo "---"
                head -50 "$FIRST_NODE"
                echo ""
                echo "Diff between outputs:"
                echo "---"
                diff -u "$FIRST_C" "$FIRST_NODE" | head -100
            fi
        else
            echo "⚠ Mismatches detected. Run with -v or --verbose to see details."
        fi
    else
        echo "✓ All tests passed! No mismatches found."
    fi
    
    # Performance comparison (normal and verbose modes)
    echo ""
    echo "========================================"
    echo "PERFORMANCE COMPARISON"
    echo "========================================"
    
    if [ $VERBOSITY -eq 1 ]; then
        # Normal mode: condensed summary
        for FILE_IDX in "${!TOP_FILES[@]}"; do
            TOP_FILE="${TOP_FILES[$FILE_IDX]}"
            BASENAME=$(basename "$TOP_FILE")
            
            if [ ${TEST_COUNTS[$BASENAME]:-0} -gt 0 ]; then
                C_AVG=$(( ${C_TIMES[$BASENAME]} / ${TEST_COUNTS[$BASENAME]} ))
                NODE_AVG=$(( ${NODE_TIMES[$BASENAME]} / ${TEST_COUNTS[$BASENAME]} ))
                
                # Only show if both timings are valid (positive)
                if [ $C_AVG -gt 0 ] && [ $NODE_AVG -gt 0 ]; then
                    RATIO=$(( (NODE_AVG * 100) / C_AVG ))
                    echo "$BASENAME: C=${C_AVG}ms, Node=${NODE_AVG}ms (${RATIO}%)"
                elif [ $C_AVG -gt 0 ] || [ $NODE_AVG -gt 0 ]; then
                    # At least one timing available
                    echo "$BASENAME: C=${C_AVG}ms, Node=${NODE_AVG}ms (timing error)"
                fi
            fi
        done
    else
        # Verbose mode: detailed output
        for FILE_IDX in "${!TOP_FILES[@]}"; do
            TOP_FILE="${TOP_FILES[$FILE_IDX]}"
            BASENAME=$(basename "$TOP_FILE")
            
            if [ ${TEST_COUNTS[$BASENAME]:-0} -gt 0 ]; then
                C_AVG=$(( ${C_TIMES[$BASENAME]} / ${TEST_COUNTS[$BASENAME]} ))
                NODE_AVG=$(( ${NODE_TIMES[$BASENAME]} / ${TEST_COUNTS[$BASENAME]} ))
                
                # Include file metrics in the output
                METRICS="${FILE_METRICS[$BASENAME]}"
                echo "$BASENAME [$METRICS] (${TEST_COUNTS[$BASENAME]} tests):"
                echo "  C diff:    ${C_AVG} ms average"
                echo "  Node diff: ${NODE_AVG} ms average"
                
                # Only show ratio if both timings are valid
                if [ $C_AVG -gt 0 ] && [ $NODE_AVG -gt 0 ]; then
                    RATIO=$(( (NODE_AVG * 100) / C_AVG ))
                    echo "  Node/C ratio: ${RATIO}%"
                elif [ $C_AVG -le 0 ] || [ $NODE_AVG -le 0 ]; then
                    echo "  ⚠ Timing error detected (negative or zero values)"
                fi
                echo ""
            fi
        done
    fi
fi

# Cleanup
rm -rf "$TEMP_DIR"

exit $MISMATCHES
