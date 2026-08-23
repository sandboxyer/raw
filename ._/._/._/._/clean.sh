#!/bin/bash

# Function to check if a file/directory is ignored by git
is_git_ignored() {
    local path="$1"
    git check-ignore -q "$path" 2>/dev/null
    return $?
}

# Function to clean gitignored files in a single directory (non-recursive)
clean_single() {
    local dir="$1"
    local file_count=0
    
    echo "  Cleaning $dir"
    
    # Process all files in the current directory
    while IFS= read -r -d '' file; do
        # Skip if it's the .git directory
        if [[ "$file" == *"/.git/"* ]] || [[ "$file" == *"/.git" ]]; then
            continue
        fi
        
        # Check if file is gitignored (only remove if it IS ignored)
        if is_git_ignored "$file"; then
            rm "$file"
            file_count=$((file_count + 1))
            echo "    Removed gitignored file: $(basename "$file")"
        fi
    done < <(find "$dir" -maxdepth 1 -type f -print0)
    
    return $file_count
}

# Function to clean gitignored files recursively
clean_recursive() {
    local dir="$1"
    local total_count=0
    local current_count=0
    
    # Clean current directory
    clean_single "$dir"
    current_count=$?
    total_count=$((total_count + current_count))
    
    # Recursively process subdirectories
    while IFS= read -r -d '' subdir; do
        # Skip .git directory but include ._ directory
        if [[ "$subdir" == *"/.git"* ]]; then
            continue
        fi
        
        # Process only if directory is NOT gitignored (otherwise skip entire directory)
        if is_git_ignored "$subdir"; then
            echo "  Skipping gitignored directory: $subdir"
            continue
        fi
        
        clean_recursive "$subdir"
        current_count=$?
        total_count=$((total_count + current_count))
    done < <(find "$dir" -mindepth 1 -maxdepth 1 -type d -not -name ".git" -print0)
    
    return $total_count
}

# Function to clean pool system directories
clean_pool_system() {
    local dir="$1"
    local pool_dirs_removed=0
    
    echo ""
    echo "Cleaning pool system directories from $dir"
    echo "---------------------------------------------"
    
    # Clean terminal directories
    if [ -d "$dir/.terminals" ]; then
        rm -rf "$dir/.terminals"
        echo "  Removed .terminals directory"
        pool_dirs_removed=$((pool_dirs_removed + 1))
    fi
    
    # Clean base pool directories
    if [ -d "$dir/.base_pool" ]; then
        rm -rf "$dir/.base_pool"
        echo "  Removed .base_pool directory"
        pool_dirs_removed=$((pool_dirs_removed + 1))
    fi
    
    # Clean router locks
    if [ -d "$dir/.router_locks" ]; then
        rm -rf "$dir/.router_locks"
        echo "  Removed .router_locks directory"
        pool_dirs_removed=$((pool_dirs_removed + 1))
    fi
    
    # Clean runtime locks
    if [ -d "$dir/.runtime_locks" ]; then
        rm -rf "$dir/.runtime_locks"
        echo "  Removed .runtime_locks directory"
        pool_dirs_removed=$((pool_dirs_removed + 1))
    fi
    
    if [ $pool_dirs_removed -eq 0 ]; then
        echo "  No pool system directories found"
    else
        echo "  Removed $pool_dirs_removed pool system director(y/ies)"
    fi
    
    return $pool_dirs_removed
}

# Get the directory where the script is being called from
TARGET_DIR="$(pwd)"
TOTAL_FILES=0
POOL_DIRS_REMOVED=0

# Check if we're in a git repository
if ! git rev-parse --git-dir > /dev/null 2>&1; then
    echo "Error: Not in a git repository"
    exit 1
fi

# Check for --full argument
if [[ "$1" == "--full" ]]; then
    echo "Cleaning gitignored files recursively from $TARGET_DIR"
    echo "-----------------------------------------------------"
    clean_recursive "$TARGET_DIR"
    TOTAL_FILES=$?
    
    # Clean pool system directories
    clean_pool_system "$TARGET_DIR"
    POOL_DIRS_REMOVED=$?
    
    echo "-----------------------------------------------------"
    echo "Successfully removed $TOTAL_FILES gitignored file(s) recursively from $TARGET_DIR"
    echo "Removed $POOL_DIRS_REMOVED pool system director(y/ies)"
else
    echo "Cleaning gitignored files from $TARGET_DIR (non-recursive)"
    echo "----------------------------------------------------------"
    clean_single "$TARGET_DIR"
    TOTAL_FILES=$?
    
    # Clean pool system directories
    clean_pool_system "$TARGET_DIR"
    POOL_DIRS_REMOVED=$?
    
    echo "----------------------------------------------------------"
    if [ $TOTAL_FILES -eq 0 ] && [ $POOL_DIRS_REMOVED -eq 0 ]; then
        echo "No gitignored files or pool system directories found in $TARGET_DIR"
    else
        echo "Successfully removed $TOTAL_FILES gitignored file(s) and $POOL_DIRS_REMOVED pool system director(y/ies) from $TARGET_DIR"
    fi
fi