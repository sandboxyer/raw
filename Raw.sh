#!/bin/bash

# ============================================================================
# Raw.sh - ROUTER + ISOLATED PRIVATE WORKER
# ============================================================================
# This file acts as a router when invoked from the original location.
# It creates/uses a private complete copy of the entire project for the
# calling terminal, then hands off execution to that private copy.
# Each terminal has a permanently isolated environment, making concurrent
# invocations fully independent.
#
# Once inside a private copy (marker env var or .rawjs_private file exists),
# the router block is skipped and the original Raw.sh logic executes.
#
# NEW: Base pool system.
#   - A pool of pre-warmed private copies (bases) is maintained.
#   - When a terminal first connects, it can use a pre-warmed base instead of
#     copying from the original project, which is faster.
#   - The pool size adapts dynamically based on recent terminal activity.
#   - `bash Raw.sh --start` ensures the pool is filled synchronously.
# ============================================================================

# ----------------------------------------------------------------------------
# EARLY SCRIPT LOCATION AND CALLER DIRECTORY
# ----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CALLER_DIR="$(pwd)"

# ----------------------------------------------------------------------------
# ROUTER DISPATCH (only if not already inside a private copy)
# ----------------------------------------------------------------------------
if [ -z "${RAWJS_PRIVATE_MODE:-}" ] && [ ! -f "$SCRIPT_DIR/.rawjs_private" ]; then

    # --- Router helpers -----------------------------------------------------
    router_get_terminal_id() {
        local tty_name
        tty_name=$(tty 2>/dev/null)
        if [ -n "$tty_name" ] && [ "$tty_name" != "not a tty" ]; then
            echo "$tty_name"
            return 0
        fi

        local sid
        sid=$(ps -o sid= -p $$ 2>/dev/null | tr -d ' ')
        if [ -n "$sid" ]; then
            echo "session_$sid"
        else
            echo "pid_$$"
        fi
    }

    router_sanitize_id() {
        echo "$1" | tr '/' '_' | tr -cd '[:alnum:]_-'
    }

    # --- Determine isolated private root for this terminal -----------------
    ROUTER_TID_RAW="$(router_get_terminal_id)"
    ROUTER_TID="$(router_sanitize_id "$ROUTER_TID_RAW")"
    ROUTER_PRIVATE_ROOT="$SCRIPT_DIR/.terminals/$ROUTER_TID"
    ROUTER_LOCK_DIR="$SCRIPT_DIR/.router_locks"
    ROUTER_LOCK="$ROUTER_LOCK_DIR/${ROUTER_TID}.lock"
    ROUTER_GLOBAL_CONFIG="$SCRIPT_DIR/config.txt"
    ROUTER_BASE_POOL_DIR="$SCRIPT_DIR/.base_pool"

    mkdir -p "$ROUTER_LOCK_DIR"
    mkdir -p "$ROUTER_BASE_POOL_DIR"

    # ---------------------------------------------------------------------
    # BASE POOL FUNCTIONS (new modular block)
    # ---------------------------------------------------------------------

    # Count recent active terminal directories (last 5 minutes)
    router_get_recent_active_count() {
        find "$SCRIPT_DIR/.terminals" -mindepth 1 -maxdepth 1 -type d -mmin -5 2>/dev/null | wc -l
    }

    # Calculate target idle base count based on recent activity
    # Uses exponential moving average for smoothness
    router_calculate_target_idle() {
        local recent="$1"
        # Raw target: 3 + half of recent active terminals (rounded up)
        local raw_target=$(( 3 + (recent + 1) / 2 ))

        local stats_file="$ROUTER_BASE_POOL_DIR/.target"
        if [ -f "$stats_file" ]; then
            local prev_target
            prev_target=$(cat "$stats_file" 2>/dev/null || echo "$raw_target")
            # Ensure prev_target is numeric
            if ! [[ "$prev_target" =~ ^[0-9]+$ ]]; then
                prev_target="$raw_target"
            fi
            # Smooth: average previous and current raw
            local new_target=$(( (prev_target + raw_target) / 2 ))
            # Minimum 3
            if [ "$new_target" -lt 3 ]; then
                new_target=3
            fi
            echo "$new_target"
        else
            echo "$raw_target"
        fi
    }

    # Return number of available base directories (exclude temporary ones)
    router_count_available_bases() {
        find "$ROUTER_BASE_POOL_DIR" -mindepth 1 -maxdepth 1 -type d ! -name '.tmp*' 2>/dev/null | wc -l
    }

    # Trim excess bases (oldest first) down to target
    router_trim_bases() {
        local target="$1"
        local current
        current=$(router_count_available_bases)
        if [ "$current" -le "$target" ]; then
            return 0
        fi
        local excess=$((current - target))
        # List base dirs sorted by name (timestamped names are chronological)
        find "$ROUTER_BASE_POOL_DIR" -mindepth 1 -maxdepth 1 -type d ! -name '.tmp*' 2>/dev/null \
            | sort | head -n "$excess" | while IFS= read -r dir; do
                rm -rf "$dir" 2>/dev/null
            done
    }

    # Create a single base directory (optimized, never copies .git)
    router_create_single_base() {
        local temp_base="$1"
        rm -rf "$temp_base"
        mkdir -p "$temp_base"

        # Use rsync if available (much faster than tar for large trees)
        if command -v rsync >/dev/null 2>&1; then
            rsync -a \
                --exclude='.terminals' \
                --exclude='.router_locks' \
                --exclude='.base_pool' \
                --exclude='.runtime_locks' \
                --exclude='.git' \
                --exclude='dev' \
                --exclude='dev_*' \
                "$SCRIPT_DIR/" "$temp_base/"
        else
            # Fallback to tar with aggressive .git exclusion
            (
                cd "$SCRIPT_DIR" && \
                tar \
                    --exclude='./.terminals' \
                    --exclude='./.router_locks' \
                    --exclude='./.base_pool' \
                    --exclude='./.runtime_locks' \
                    --exclude='./.git' \
                    --exclude='./dev' \
                    --exclude='./dev_*' \
                    -cf - .
            ) | (
                cd "$temp_base" && tar -xf -
            )
        fi

        if [ $? -eq 0 ]; then
            touch "$temp_base/.rawjs_private"
            chmod +x "$temp_base/Raw.sh"
            return 0
        else
            rm -rf "$temp_base"
            return 1
        fi
    }

    # Spawn a background process to create bases until the pool reaches target
    router_spawn_base_creator() {
        local target="$1"
        local lock_file="$ROUTER_LOCK_DIR/base_pool.lock"

        # If a creator is already running, do nothing
        if [ -d "$lock_file" ]; then
            return 0
        fi

        nohup bash -c '
            target='"$target"'
            SCRIPT_DIR="'"$SCRIPT_DIR"'"
            ROUTER_BASE_POOL_DIR="'"$ROUTER_BASE_POOL_DIR"'"
            ROUTER_LOCK_DIR="'"$ROUTER_LOCK_DIR"'"
            lock_file="'"$lock_file"'"

            # Source the router functions from the parent script
            router_create_single_base() {
                local temp_base="$1"
                rm -rf "$temp_base"
                mkdir -p "$temp_base"

                if command -v rsync >/dev/null 2>&1; then
                    rsync -a \
                        --exclude=".terminals" \
                        --exclude=".router_locks" \
                        --exclude=".base_pool" \
                        --exclude=".runtime_locks" \
                        --exclude=".git" \
                        --exclude="dev" \
                        --exclude="dev_*" \
                        "$SCRIPT_DIR/" "$temp_base/"
                else
                    (
                        cd "$SCRIPT_DIR" && \
                        tar \
                            --exclude="./.terminals" \
                            --exclude="./.router_locks" \
                            --exclude="./.base_pool" \
                            --exclude="./.runtime_locks" \
                            --exclude="./.git" \
                            --exclude="./dev" \
                            --exclude="./dev_*" \
                            -cf - .
                    ) | (
                        cd "$temp_base" && tar -xf -
                    )
                fi

                if [ $? -eq 0 ]; then
                    touch "$temp_base/.rawjs_private"
                    chmod +x "$temp_base/Raw.sh"
                    return 0
                else
                    rm -rf "$temp_base"
                    return 1
                fi
            }

            mkdir -p "$ROUTER_BASE_POOL_DIR"
            if mkdir "$lock_file" 2>/dev/null; then
                trap "rmdir \"$lock_file\" 2>/dev/null" EXIT
                while true; do
                    current=$(find "$ROUTER_BASE_POOL_DIR" -mindepth 1 -maxdepth 1 -type d ! -name ".tmp*" 2>/dev/null | wc -l)
                    if [ "$current" -ge "$target" ]; then
                        break
                    fi
                    temp_base="$ROUTER_BASE_POOL_DIR/.tmp_$$"
                    router_create_single_base "$temp_base"
                    if [ $? -eq 0 ]; then
                        final_base="$ROUTER_BASE_POOL_DIR/base_$(date +%s)_$RANDOM"
                        mv "$temp_base" "$final_base" 2>/dev/null
                    fi
                done
                rmdir "$lock_file" 2>/dev/null
            fi
        ' >/dev/null 2>&1 &
    }

    # Manage base pool: trim excess and spawn creator if needed
    # Must be called while holding router lock
    router_manage_base_pool() {
        mkdir -p "$ROUTER_BASE_POOL_DIR"
        local recent_active
        recent_active=$(router_get_recent_active_count)
        local target_idle
        target_idle=$(router_calculate_target_idle "$recent_active")
        # Persist target for next call
        echo "$target_idle" > "$ROUTER_BASE_POOL_DIR/.target"

        local current_bases
        current_bases=$(router_count_available_bases)

        if [ "$current_bases" -lt "$target_idle" ]; then
            # Need more bases: spawn background creator
            router_spawn_base_creator "$target_idle"
        elif [ "$current_bases" -gt "$target_idle" ]; then
            # Too many idle bases: trim
            router_trim_bases "$target_idle"
        fi
    }

    # Synchronous base pool creation (used by --start)
    router_create_bases_sync() {
        local target="$1"
        local lock_file="$ROUTER_LOCK_DIR/base_pool.lock"
        while ! mkdir "$lock_file" 2>/dev/null; do
            sleep 0.2
        done
        trap 'rmdir "$lock_file" 2>/dev/null' EXIT

        while true; do
            local current
            current=$(router_count_available_bases)
            if [ "$current" -ge "$target" ]; then
                break
            fi
            local temp_base="$ROUTER_BASE_POOL_DIR/.tmp_$$"
            router_create_single_base "$temp_base"
            if [ $? -eq 0 ]; then
                local final_base="$ROUTER_BASE_POOL_DIR/base_$(date +%s)_$RANDOM"
                mv "$temp_base" "$final_base" 2>/dev/null
            fi
        done
        rmdir "$lock_file" 2>/dev/null
        trap - EXIT
    }

    # Acquire a base from pool: use atomic rename for instant linking
    # Returns 0 on success, 1 if no base available
    router_acquire_base() {
        local base_dir
        base_dir=$(find "$ROUTER_BASE_POOL_DIR" -mindepth 1 -maxdepth 1 -type d ! -name '.tmp*' -print -quit 2>/dev/null)
        if [ -n "$base_dir" ]; then
            # Use mv (rename) for instant linking if on same filesystem
            # Fallback to cp -al (hardlink copy) if mv fails
            if ! mv "$base_dir" "$ROUTER_PRIVATE_ROOT" 2>/dev/null; then
                # Try hardlink copy (very fast, same filesystem)
                if command -v cp >/dev/null 2>&1; then
                    cp -al "$base_dir" "$ROUTER_PRIVATE_ROOT" 2>/dev/null
                    if [ $? -eq 0 ]; then
                        rm -rf "$base_dir" 2>/dev/null
                        return 0
                    fi
                fi
                return 1
            fi
            return 0
        fi
        return 1
    }

    # ---------------------------------------------------------------------
    # Handle --start special mode
    # ---------------------------------------------------------------------
    if [ "$1" = "--start" ]; then
        mkdir -p "$ROUTER_LOCK_DIR"
        # Acquire router lock to avoid concurrent pool operations
        while ! mkdir "$ROUTER_LOCK" 2>/dev/null; do
            if [ -d "$ROUTER_LOCK" ]; then
                # If lock is stale (older than 60 seconds), remove it
                ROUTER_LOCK_AGE=$(find "$ROUTER_LOCK" -maxdepth 0 -mmin +1 2>/dev/null | wc -l)
                if [ "$ROUTER_LOCK_AGE" -gt 0 ]; then
                    rm -rf "$ROUTER_LOCK" 2>/dev/null
                    continue
                fi
            fi
            sleep 0.1
        done

        # Compute target and create bases synchronously
        local recent_active
        recent_active=$(router_get_recent_active_count)
        local target_idle
        target_idle=$(router_calculate_target_idle "$recent_active")
        echo "$target_idle" > "$ROUTER_BASE_POOL_DIR/.target"
        echo "Warming base pool to $target_idle idle bases..." >&2
        router_create_bases_sync "$target_idle"

        rmdir "$ROUTER_LOCK" 2>/dev/null
        echo "Base pool ready." >&2
        exit 0
    fi

    # ---------------------------------------------------------------------
    # Normal terminal connection flow
    # ---------------------------------------------------------------------

    # Clean stale router locks (older than 60 seconds) but never delete base_pool.lock
    find "$ROUTER_LOCK_DIR" -mindepth 1 -maxdepth 1 -type d ! -name 'base_pool.lock' -mmin +1 -exec rmdir {} \; 2>/dev/null

    # --- Acquire router lock with stale detection --------------------------
    ROUTER_ACQUIRED=0
    while [ "$ROUTER_ACQUIRED" -eq 0 ]; do
        if mkdir "$ROUTER_LOCK" 2>/dev/null; then
            ROUTER_ACQUIRED=1
        else
            if [ -d "$ROUTER_LOCK" ]; then
                # If lock is stale (older than 60 seconds), remove it
                ROUTER_LOCK_AGE=$(find "$ROUTER_LOCK" -maxdepth 0 -mmin +1 2>/dev/null | wc -l)
                if [ "$ROUTER_LOCK_AGE" -gt 0 ]; then
                    rm -rf "$ROUTER_LOCK" 2>/dev/null
                    continue
                fi
            fi
            sleep 0.1
        fi
    done

    # Manage base pool (trim/spawn) while lock held
    router_manage_base_pool

    # --- Ensure a complete private copy exists -----------------------------
    ROUTER_FIRST_RUN=0
    if [ ! -f "$ROUTER_PRIVATE_ROOT/Raw.sh" ] || [ ! -d "$ROUTER_PRIVATE_ROOT/._" ]; then
        ROUTER_FIRST_RUN=1

        # Try to use a pre-warmed base (instant linking via rename)
        if router_acquire_base "$ROUTER_TID"; then
            # Successfully linked to a pre-warmed base
            :
        else
            # Fallback: create from original project (fast, excludes .git)
            echo "Initializing isolated environment for terminal: $ROUTER_TID_RAW ..." >&2
            rm -rf "$ROUTER_PRIVATE_ROOT" 2>/dev/null
            mkdir -p "$ROUTER_PRIVATE_ROOT"
            router_create_single_base "$ROUTER_PRIVATE_ROOT"
        fi
    fi

    # --- Sync global config to private copy --------------------------------
    if [ -f "$ROUTER_GLOBAL_CONFIG" ]; then
        cp "$ROUTER_GLOBAL_CONFIG" "$ROUTER_PRIVATE_ROOT/config.txt" 2>/dev/null
    fi

    # Release router lock
    rmdir "$ROUTER_LOCK" 2>/dev/null

    # Hand off to the private Raw.sh. The environment variable tells it to
    # skip the router and execute the original logic.
    export RAWJS_PRIVATE_MODE=1
    export RAWJS_PRIVATE_ROOT="$ROUTER_PRIVATE_ROOT"
    export RAWJS_FIRST_RUN="$ROUTER_FIRST_RUN"
    exec bash "$ROUTER_PRIVATE_ROOT/Raw.sh" "$@"
    exit 127  # Should never reach here
fi

# ============================================================================
# ORIGINAL Raw.sh LOGIC - runs only inside the private environment
# ============================================================================

# ============================================
# CONFIGURATION FILE MANAGEMENT
# ============================================
CONFIG_FILE="$SCRIPT_DIR/config.txt"  # Will be set after SCRIPT_DIR is defined
GLOBAL_CONFIG_FILE=""  # Will be set to the original/global config location

# Function: Load configuration from config.txt
# Format: Each line is "key=value"
load_config() {
    CONFIG_DEV_MODE="false"  # Default value
    POOL_SIZE=3              # Default runtime pool size

    # FIX: Load from global config if available, otherwise local
    local config_to_load="$CONFIG_FILE"
    if [ -n "$GLOBAL_CONFIG_FILE" ] && [ -f "$GLOBAL_CONFIG_FILE" ]; then
        config_to_load="$GLOBAL_CONFIG_FILE"
    fi

    if [ -f "$config_to_load" ]; then
        while IFS='=' read -r key value; do
            case "$key" in
                "dev_mode") CONFIG_DEV_MODE="$value" ;;
                "pool_size") POOL_SIZE="$value" ;;
            esac
        done < "$config_to_load"
    fi
}

# Function: Save configuration to config.txt
save_config() {
    # FIX: Save to both global and local config files
    local config_to_save="$CONFIG_FILE"
    if [ -n "$GLOBAL_CONFIG_FILE" ]; then
        config_to_save="$GLOBAL_CONFIG_FILE"
    fi

    # Preserve existing config and update only the changed values
    local temp_file="${config_to_save}.tmp"
    local dev_mode_written=false
    local pool_size_written=false

    # Copy existing config if it exists
    if [ -f "$config_to_save" ]; then
        while IFS='=' read -r key value; do
            if [ "$key" = "dev_mode" ]; then
                echo "dev_mode=$CONFIG_DEV_MODE" >> "$temp_file"
                dev_mode_written=true
            elif [ "$key" = "pool_size" ]; then
                echo "pool_size=$POOL_SIZE" >> "$temp_file"
                pool_size_written=true
            else
                echo "$key=$value" >> "$temp_file"
            fi
        done < "$config_to_save"
    fi

    # Add dev_mode if not already written
    if [ "$dev_mode_written" = false ]; then
        echo "dev_mode=$CONFIG_DEV_MODE" >> "$temp_file"
    fi
    # Add pool_size if not already written
    if [ "$pool_size_written" = false ]; then
        echo "pool_size=$POOL_SIZE" >> "$temp_file"
    fi

    mv "$temp_file" "$config_to_save"
    
    # FIX: Also sync to local config if global was used
    if [ -n "$GLOBAL_CONFIG_FILE" ] && [ "$config_to_save" != "$CONFIG_FILE" ]; then
        cp "$config_to_save" "$CONFIG_FILE" 2>/dev/null
    fi
    
    # FIX: Sync to all active terminal directories
    sync_config_to_all_terminals
}

# FIX: New function to sync config to all active terminal directories
sync_config_to_all_terminals() {
    local source_config="$CONFIG_FILE"
    if [ -n "$GLOBAL_CONFIG_FILE" ] && [ -f "$GLOBAL_CONFIG_FILE" ]; then
        source_config="$GLOBAL_CONFIG_FILE"
    fi
    
    # Find all terminal directories and sync the config
    if [ -d "$SCRIPT_DIR/.terminals" ]; then
        for terminal_dir in "$SCRIPT_DIR/.terminals"/*/; do
            if [ -f "$terminal_dir/config.txt" ] || [ -d "$terminal_dir" ]; then
                cp "$source_config" "$terminal_dir/config.txt" 2>/dev/null
            fi
        done
    fi
}

# Function: Toggle dev mode
toggle_dev_mode() {
    load_config
    if [ "$CONFIG_DEV_MODE" = "true" ]; then
        CONFIG_DEV_MODE="false"
        echo -e "${YELLOW}Dev mode disabled. Raw.sh without arguments will show usage.${NC}"
    else
        CONFIG_DEV_MODE="true"
        echo -e "${GREEN}Dev mode enabled. Raw.sh without arguments will launch CLI.${NC}"
    fi
    save_config
}

# ============================================
# ANSI STRIPPING FUNCTION
# ============================================
strip_ansi_codes() {
    local input="$1"

    # Use sed with simpler patterns that work on both GNU and BusyBox sed
    echo "$input" | sed -E 's/\x1b\[[0-9;]*[mK]//g; s/\x1b\][^\x07\x1b]*(\x07|\x1b\\)//g; s/\x1b[()][AB012]//g; s/\x1b\[[0-9;]*[a-zA-Z]//g; s/\x1b[^a-zA-Z]*[a-zA-Z]//g'
}

# ============================================
# SAVE CALLER'S DIRECTORY AND RESOLVE JS FILE FIRST
# ============================================
CALLER_DIR="$(pwd)"  # Save where the script was called from

# Check for special flags FIRST before processing JS file
SPECIAL_MODE=""
FORCE_LOG_MODE="false"  # New flag for --log (only for normal JS execution)
VERBOSE_MODE="false"    # New flag for --verbose (enables log mode and passes --verbose to tree/build.sh)
TOOL_MODE="false"       # New flag for --tool
TOOL_COMMAND=""         # Store the tool command
TOOL_ARGS=""            # Store tool arguments
ASM_MODE="false"        # New flag for --asm
ASM_ONLY_MODE="false"   # Flag for --asm without JS file
BIN_OUTPUT_MODE="false" # Flag for --bin output generation with JS processing
BIN_OUTPUT_NAME=""      # Store the output name for --bin mode
CLI_MODE="false"        # New flag for --cli

if [ $# -gt 0 ]; then
    if [ "$1" = "--test" ] || [ "$1" = "--reset" ]; then
        SPECIAL_MODE="$1"
        shift  # Remove the flag from arguments
    elif [ "$1" = "--dev" ]; then
        # NEW: Toggle dev mode
        SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        CONFIG_FILE="$SCRIPT_DIR/config.txt"
        # FIX: Set global config path
        if [ -n "$RAWJS_PRIVATE_ROOT" ]; then
            GLOBAL_CONFIG_FILE="$(dirname "$RAWJS_PRIVATE_ROOT")/../config.txt"
        fi
        load_config
        toggle_dev_mode
        exit 0
    elif [ "$1" = "--cli" ]; then
        CLI_MODE="true"
        shift  # Remove --cli flag
    elif [ "$1" = "--tool" ]; then
        TOOL_MODE="true"
        shift  # Remove --tool flag

        # Check if a command was provided
        if [ $# -gt 0 ]; then
            TOOL_COMMAND="$1"
            shift  # Remove command name

            # Store remaining arguments as tool args
            TOOL_ARGS="$@"
        fi
    elif [ "$1" = "--tools" ] || [ "$1" = "--stools" ] || [ "$1" = "--stool" ]; then
        # Support both --tools (full) and --stools/--stool (compact)
        if [ "$1" = "--stools" ] || [ "$1" = "--stool" ]; then
            SPECIAL_MODE="--stools"
        else
            SPECIAL_MODE="--tools"
        fi
        shift
    elif [ "$1" = "--asm" ]; then
        ASM_MODE="true"
        shift  # Remove --asm flag

        # Check if there's a JS file after --asm
        if [ $# -gt 0 ] && [[ "$1" != -* ]]; then
            # There's a JS file - will process normally and then copy asm
            ASM_ONLY_MODE="false"
        else
            # No JS file - just copy the asm file
            ASM_ONLY_MODE="true"
        fi
    elif [ "$1" = "--version" ] || [ "$1" = "--v" ] || [ "$1" = "-v" ] || [ "$1" = "-version" ]; then
        # Get script's own directory to read package.json
        SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

        # Read version from package.json
        if [ -f "$SCRIPT_DIR/package.json" ]; then
            VERSION=$(grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' "$SCRIPT_DIR/package.json" | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+')
            if [ -n "$VERSION" ]; then
                echo "RawJS - $VERSION"
            else
                echo "RawJS - version unknown"
            fi
        else
            echo "RawJS - version unknown"
        fi
        exit 0
    elif [ "$1" = "--verbose" ]; then
        # Enable verbose mode (enables log mode and passes --verbose to tree/build.sh)
        VERBOSE_MODE="true"
        FORCE_LOG_MODE="true"
        shift  # Remove --verbose flag
    elif [ "$1" = "--bin" ]; then
        # Check if --bin is being used as a tool command (no JS file follows)
        shift  # Remove --bin flag

        # Check if there are more arguments
        if [ $# -gt 0 ] && [[ "$1" != -* ]]; then
            # Check if next argument looks like a JS file
            if [[ "$1" == *.js ]] || [[ "$1" == *.JS ]]; then
                # It's a JS file - use --bin mode for JS processing
                BIN_OUTPUT_MODE="true"
                # JS file will be processed in the JS file section below
            elif [ -f "$CALLER_DIR/$1" ] && [[ "$1" == *.asm || "$1" == *.ASM ]]; then
                # It's an existing .asm file - use as tool command
                TOOL_MODE="true"
                TOOL_COMMAND="bin"
                TOOL_ARGS="$@"
                # Reset the arguments to prevent further processing
                set -- "$@"
            else
                # Could be an output name for --bin mode with JS processing
                # Check if the next argument after this might be a JS file
                if [ $# -gt 1 ] && ([[ "$2" == *.js ]] || [[ "$2" == *.JS ]]); then
                    BIN_OUTPUT_MODE="true"
                    BIN_OUTPUT_NAME="$1"
                    shift  # Remove output name
                    # JS file will be processed in the JS file section below
                else
                    # Treat as tool command with arguments
                    TOOL_MODE="true"
                    TOOL_COMMAND="bin"
                    TOOL_ARGS="$1 $@"
                    shift
                    set -- "$@"
                fi
            fi
        else
            # No arguments after --bin, or next is a flag - treat as tool command
            TOOL_MODE="true"
            TOOL_COMMAND="bin"
            TOOL_ARGS="$@"
            # Reset the arguments to prevent further processing
            set -- "$@"
        fi
    else
        # NEW: Check if first argument is a tool name (starts with -- and not a known flag)
        if [[ "$1" == --* ]] && [ "$1" != "--log" ] && [ "$1" != "--verbose" ] && [ "$1" != "--asm" ] && [ "$1" != "--bin" ] && [ "$1" != "--test" ] && [ "$1" != "--reset" ] && [ "$1" != "--version" ] && [ "$1" != "--v" ] && [ "$1" != "-v" ] && [ "$1" != "-version" ] && [ "$1" != "--tools" ] && [ "$1" != "--stools" ] && [ "$1" != "--stool" ] && [ "$1" != "--cli" ] && [ "$1" != "--dev" ]; then
            # Extract tool name by removing leading --
            TOOL_COMMAND="${1#--}"
            TOOL_MODE="true"
            shift  # Remove the tool flag

            # Store remaining arguments as tool args
            TOOL_ARGS="$@"
        fi
    fi
fi

# Only check for --log and --verbose if we're NOT in a special mode or tool mode
if [ -z "$SPECIAL_MODE" ] && [ "$TOOL_MODE" = "false" ] && [ "$CLI_MODE" = "false" ] && [ $# -gt 0 ]; then
    if [ "$1" = "--verbose" ]; then
        # Enable verbose mode (enables log mode and passes --verbose to tree/build.sh)
        VERBOSE_MODE="true"
        FORCE_LOG_MODE="true"
        shift  # Remove the flag from arguments
    fi
    if [ "$1" = "--log" ]; then
        FORCE_LOG_MODE="true"
        shift  # Remove the flag from arguments
    fi
fi

# Process JS file argument BEFORE changing directories (only if not in tool mode and not asm-only mode and not cli mode)
JS_FILE=""
JS_ARGS=""
if [ "$TOOL_MODE" = "false" ] && [ "$CLI_MODE" = "false" ] && [ $# -gt 0 ] && [ -z "$SPECIAL_MODE" ] && [ "$ASM_ONLY_MODE" = "false" ]; then
    # Check if BIN_OUTPUT_MODE is already set (from --bin parsing above)
    if [ "$BIN_OUTPUT_MODE" = "false" ]; then
        # Check for --bin flag before JS file (in case it wasn't caught above)
        if [ "$1" = "--bin" ]; then
            BIN_OUTPUT_MODE="true"
            shift  # Remove --bin flag

            # Check if next argument is an output name
            if [ $# -gt 0 ] && [[ "$1" != -* ]]; then
                # Check if it looks like an output name (not a JS file)
                if [[ "$1" != *.js ]] && [[ "$1" != *.JS ]]; then
                    BIN_OUTPUT_NAME="$1"
                    shift
                fi
            fi
        fi
    fi

    # Now process JS file if arguments remain
    if [ $# -gt 0 ]; then
        # Resolve JS file path relative to caller's directory
        if [[ "$1" = /* ]]; then
            # Absolute path
            JS_FILE="$1"
        else
            # Relative path - resolve from caller's directory
            JS_FILE="$CALLER_DIR/$1"
        fi
        shift
        JS_ARGS="$@"
    fi
fi

# ============================================
# GET SCRIPT'S OWN DIRECTORY (not caller's directory)
# ============================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"  # Change to script's directory to ensure consistent paths

# FIX: Set global config path for private instances
if [ -n "$RAWJS_PRIVATE_ROOT" ]; then
    GLOBAL_CONFIG_FILE="$(dirname "$RAWJS_PRIVATE_ROOT")/../config.txt"
fi

# NOW load configuration
CONFIG_FILE="$SCRIPT_DIR/config.txt"
load_config

# Now JS_FILE contains the absolute path to the JS file from caller's perspective
# The rest of the script continues exactly as before...

# ============================================
# VERBOSITY CONTROL FOR DEV COMPILATION STEP
# ============================================
# Set to "true" to enable compilation error/output (for debugging)
# Set to "false" for complete silent operation (default for production)
#
# When false: NO output at all from compilation step (not even errors)
# When true: Shows all compilation details including errors
# ============================================
VERBOSE_DEV="${VERBOSE_DEV:-false}"  # Default: completely silent

# ============================================
# GLOBAL EXECUTION PATH CONFIGURATION
# ============================================
# Controls where to look for files to execute
# "dev" - uses per-terminal runtime directory (default)
# "source" - uses ./._ directory (contains source files, will be compiled on-demand)
# ============================================
EXECUTION_SOURCE="${EXECUTION_SOURCE:-dev}"  # Default: use compiled binaries from runtime pool

# ============================================
# RUNTIME POOL CONFIGURATION
# ============================================
# Pool directories are created at the same level as the original /dev.
# Each directory is named "dev_N" (dev_1, dev_2, dev_3, ...).
# Every terminal/process obtains its own directory, with a persistent lock.
# Locks are removed after 10 minutes or when the owning process exits.
# A global lock protects pool creation and reset operations.
LOCK_DIRECTORY="$SCRIPT_DIR/.runtime_locks"
LOCK_TIMEOUT_SECONDS=600
POOL_SIZE=3
POOL_PREFIX="dev_"
WORKING_DIRECTORY=""
GLOBAL_LOCK_FILE="$LOCK_DIRECTORY/global.lock"
ACTIVE_LOCK_FILE=""
INHERITED_RUNTIME=0

# ============================================
# TOOL GROUPS CONFIGURATION
# ============================================
# Define tool groups, their colors, and tool order
# Groups are displayed in the order defined here
# Tools not assigned to any group go to "General" group
#
# COLOR OPTIONS (use ANSI color codes without \033[ or \e[):
#   Black: 0;30, Dark Gray: 1;30
#   Red: 0;31, Light Red: 1;31
#   Green: 0;32, Light Green: 1;32
#   Brown/Orange: 0;33, Yellow: 1;33
#   Blue: 0;34, Light Blue: 1;34
#   Purple: 0;35, Light Purple: 1;35
#   Cyan: 0;36, Light Cyan: 1;36
#   Light Gray: 0;37, White: 1;37
#
# TO ADD A NEW GROUP:
#   1. Add a new array TOOL_GROUP_<groupname>_TOOLS with tools in desired order
#   2. Add the group name to TOOL_GROUPS_ORDER array
#   3. Define TOOL_GROUP_<groupname>_COLOR with the color code
#
# TO ADD A TOOL TO EXISTING GROUP:
#   1. Add tool name to the group's TOOL_GROUP_<groupname>_TOOLS array
#   2. Add tool function (tool_<toolname>) in TOOL COMMAND HANDLERS section
#   3. Add working directory config in get_tool_working_dir() function
#
# TO CHANGE ORDER OF GROUPS:
#   - Modify TOOL_GROUPS_ORDER array
#
# TO CHANGE ORDER OF TOOLS IN A GROUP:
#   - Modify the group's TOOL_GROUP_<groupname>_TOOLS array
# ============================================

# Define the order of groups (first group appears first)
TOOL_GROUPS_ORDER=(
    "Main"
)

# Define tools for "Main" group (in desired order)
TOOL_GROUP_Main_TOOLS=(
    "min"
    "polish"
    "arch"
    "build"
    "bin"
)

# Define color for "Main" group
TOOL_GROUP_Main_COLOR="1;36"  # Light Cyan

# Define color for default "General" group
TOOL_GROUP_General_COLOR="1;33"  # Yellow

# ============================================
# TOOL WORKING DIRECTORY CONFIGURATION
# ============================================
# WORKING DIRECTORY TYPES:
#   "global"  - Execute from script's own directory ($SCRIPT_DIR)
#   "caller"  - Execute from user's current working directory (where command was called)
#   "file"    - Execute from the directory containing the executed file itself
#
# Add your tool commands here to configure their working directory
# ============================================
get_tool_working_dir() {
    local tool_name="$1"
    case "$tool_name" in
        # =====================================================================
        # TOOL COMMANDS - Configure working directory for each tool
        # =====================================================================
        "dual")     echo "file" ;;
        "info")     echo "caller" ;;
        "min")      echo "caller" ;;
        "polish")   echo "caller" ;;
        "arch")     echo "caller" ;;
        "chain")    echo "caller" ;;
        "build")    echo "caller" ;;
        "bin")      echo "caller" ;;
        "emb")      echo "caller" ;;
        "testcheck") echo "caller" ;;
        "clean")    echo "caller" ;;
        "jsclean")  echo "caller" ;;

        # =====================================================================
        # ADD YOUR TOOLS HERE with their working directory
        # =====================================================================
        # "compile")  echo "global" ;;
        # "process")  echo "caller" ;;
        # "analyze")  echo "file" ;;

        # =====================================================================
        # DEFAULT - uses "global" if not specified
        # =====================================================================
        *) echo "global" ;;
    esac
}

# Colors for output (only used when VERBOSE_DEV=true)
if [ "$VERBOSE_DEV" = "true" ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m' # No Color
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; NC=''
fi

# Silent logging function for dev step
dev_log() {
    if [ "$VERBOSE_DEV" = "true" ]; then
        echo -e "$@"
    fi
}

# Error logging for dev step (only shows if VERBOSE_DEV=true)
dev_error() {
    if [ "$VERBOSE_DEV" = "true" ]; then
        echo -e "$@" >&2
    fi
}

# ============================================
# RUNTIME POOL AND LOCK MANAGEMENT
# ============================================

# Get a unique identifier for the current terminal/process
get_terminal_identifier() {
    # If parent Raw.sh already set an identifier, reuse it.
    if [ -n "$RAWJS_TERMINAL_ID" ]; then
        echo "$RAWJS_TERMINAL_ID"
        return 0
    fi

    local tty_name=""
    tty_name=$(tty 2>/dev/null)
    if [ -z "$tty_name" ] || [ "$tty_name" = "not a tty" ]; then
        # Fallback to session ID or process ID
        local session_id=""
        session_id=$(ps -o sid= -p $$ 2>/dev/null | tr -d ' ')
        if [ -n "$session_id" ]; then
            echo "session_$session_id"
        else
            echo "pid_$$"
        fi
    else
        echo "$tty_name"
    fi
}

# Create pool directories (no global lock)
ensure_pool_dirs_locked() {
    local index=1
    while [ $index -le "$POOL_SIZE" ]; do
        local pool_dir="$SCRIPT_DIR/${POOL_PREFIX}${index}"
        if [ ! -d "$pool_dir" ]; then
            compile_and_copy "$pool_dir"
            if [ $? -ne 0 ]; then
                return 1
            fi
        fi
        index=$((index + 1))
    done
    return 0
}

# Initialize runtime pool with global lock protection
initialize_runtime_pool() {
    mkdir -p "$LOCK_DIRECTORY"

    if ! mkdir "$GLOBAL_LOCK_FILE" 2>/dev/null; then
        # Another process is initializing or resetting; wait for it to finish.
        local wait_count=0
        while [ -d "$GLOBAL_LOCK_FILE" ] && [ $wait_count -lt 60 ]; do
            sleep 1
            wait_count=$((wait_count + 1))
        done
        # Check if pool is ready now.
        local index=1
        local all_ready=true
        while [ $index -le "$POOL_SIZE" ]; do
            if [ ! -d "$SCRIPT_DIR/${POOL_PREFIX}${index}" ]; then
                all_ready=false
                break
            fi
            index=$((index + 1))
        done
        if [ "$all_ready" = true ]; then
            return 0
        fi
        # If still not ready, fall through and try to acquire the lock again.
        if ! mkdir "$GLOBAL_LOCK_FILE" 2>/dev/null; then
            return 1
        fi
    fi

    ensure_pool_dirs_locked
    local result=$?

    # Clean stale locks older than timeout
    find "$LOCK_DIRECTORY" -type f -name "owner_*" -mmin +$((LOCK_TIMEOUT_SECONDS / 60)) -delete 2>/dev/null
    find "$LOCK_DIRECTORY" -type d -name "active_*" -mmin +$((LOCK_TIMEOUT_SECONDS / 60)) -exec rmdir {} \; 2>/dev/null

    rmdir "$GLOBAL_LOCK_FILE" 2>/dev/null
    return $result
}

# Acquire a working directory for this invocation.
# If the environment already contains RAWJS_ACTIVE_DIR, we reuse it directly.
acquire_working_directory() {
    # If a parent Raw.sh already exported an active directory, use it.
    if [ -n "$RAWJS_ACTIVE_DIR" ] && [ -d "$RAWJS_ACTIVE_DIR" ]; then
        WORKING_DIRECTORY="$RAWJS_ACTIVE_DIR"
        INHERITED_RUNTIME=1
        export WORKING_DIRECTORY
        return 0
    fi

    local terminal_id=""
    terminal_id=$(get_terminal_identifier)
    export RAWJS_TERMINAL_ID="$terminal_id"

    mkdir -p "$LOCK_DIRECTORY"
    local current_time
    current_time=$(date +%s)

    # Ensure at least POOL_SIZE directories exist.
    local index=1
    local pool_ready=true
    while [ $index -le "$POOL_SIZE" ]; do
        if [ ! -d "$SCRIPT_DIR/${POOL_PREFIX}${index}" ]; then
            pool_ready=false
            break
        fi
        index=$((index + 1))
    done

    if [ "$pool_ready" = false ]; then
        initialize_runtime_pool
        if [ $? -ne 0 ]; then
            return 1
        fi
    fi

    # Search for an existing directory owned by this terminal.
    index=1
    while [ -d "$SCRIPT_DIR/${POOL_PREFIX}${index}" ]; do
        local pool_dir="$SCRIPT_DIR/${POOL_PREFIX}${index}"
        local owner_file="$LOCK_DIRECTORY/owner_$index"
        local active_lock="$LOCK_DIRECTORY/active_$index"
        local owner_id=""
        local owner_time=0

        if [ -f "$owner_file" ]; then
            read -r owner_id owner_time < "$owner_file" 2>/dev/null
        fi

        if [ "$owner_id" = "$terminal_id" ]; then
            if [ -d "$active_lock" ]; then
                local age=$((current_time - owner_time))
                if [ "$age" -le "$LOCK_TIMEOUT_SECONDS" ]; then
                    # Active lock is still valid and belongs to this terminal.
                    WORKING_DIRECTORY="$pool_dir"
                    INHERITED_RUNTIME=1
                    export WORKING_DIRECTORY
                    return 0
                else
                    # Stale active lock -- clean it up and fall through.
                    rmdir "$active_lock" 2>/dev/null
                    rm -f "$owner_file"
                fi
            else
                # Owner matches but no active lock: remove stale owner and reuse.
                rm -f "$owner_file"
            fi
        fi

        # Determine whether this directory is free.
        local is_free=0
        if [ ! -d "$active_lock" ]; then
            if [ ! -f "$owner_file" ]; then
                is_free=1
            else
                # Owner file exists but may be stale.
                local stale_owner_id=""
                local stale_owner_time=0
                read -r stale_owner_id stale_owner_time < "$owner_file" 2>/dev/null
                if [ -z "$stale_owner_id" ] || [ $((current_time - stale_owner_time)) -gt "$LOCK_TIMEOUT_SECONDS" ]; then
                    is_free=1
                    rm -f "$owner_file"
                fi
            fi
        fi

        if [ "$is_free" = "1" ]; then
            # Try to acquire active lock atomically.
            if mkdir "$active_lock" 2>/dev/null; then
                echo "$terminal_id $current_time" > "${owner_file}.tmp"
                mv "${owner_file}.tmp" "$owner_file" 2>/dev/null
                WORKING_DIRECTORY="$pool_dir"
                ACTIVE_LOCK_FILE="$active_lock"
                INHERITED_RUNTIME=0
                export WORKING_DIRECTORY
                return 0
            fi
        fi

        index=$((index + 1))
    done

    # All existing directories are locked by other terminals; create a new one.
    local new_index=$index
    local new_dir="$SCRIPT_DIR/${POOL_PREFIX}${new_index}"
    local new_owner_file="$LOCK_DIRECTORY/owner_$new_index"
    local new_active_lock="$LOCK_DIRECTORY/active_$new_index"

    if mkdir "$new_active_lock" 2>/dev/null; then
        if compile_and_copy "$new_dir"; then
            echo "$terminal_id $current_time" > "$new_owner_file"
            WORKING_DIRECTORY="$new_dir"
            ACTIVE_LOCK_FILE="$new_active_lock"
            INHERITED_RUNTIME=0
            export WORKING_DIRECTORY
            return 0
        else
            rmdir "$new_active_lock" 2>/dev/null
            return 1
        fi
    else
        # Race: another process created it, retry once by scanning again.
        index=1
        while [ -d "$SCRIPT_DIR/${POOL_PREFIX}${index}" ]; do
            local pool_dir="$SCRIPT_DIR/${POOL_PREFIX}${index}"
            local active_lock="$LOCK_DIRECTORY/active_$index"
            if [ ! -d "$active_lock" ]; then
                if mkdir "$active_lock" 2>/dev/null; then
                    echo "$terminal_id $current_time" > "${LOCK_DIRECTORY}/owner_${index}"
                    WORKING_DIRECTORY="$pool_dir"
                    ACTIVE_LOCK_FILE="$active_lock"
                    INHERITED_RUNTIME=0
                    export WORKING_DIRECTORY
                    return 0
                fi
            fi
            index=$((index + 1))
        done
        return 1
    fi
}

# Cleanup function: remove only the active lock if this process created it.
cleanup_runtime_lock() {
    if [ "$INHERITED_RUNTIME" = "0" ] && [ -n "$ACTIVE_LOCK_FILE" ]; then
        rmdir "$ACTIVE_LOCK_FILE" 2>/dev/null
    fi
}
trap cleanup_runtime_lock EXIT

# ============================================
# FILE MANIPULATION FUNCTIONS
# ============================================

# Minimalistic move file
# Usage: mv_file "source" "destination"
mv_file() {
    mv "$1" "$2" 2>/dev/null
}

# Minimalistic delete file
# Usage: rm_file "file_path"
rm_file() {
    rm -f "$1" 2>/dev/null
}

# Minimalistic delete directory
# Usage: rm_dir "directory_path"
rm_dir() {
    rm -rf "$1" 2>/dev/null
}

# Minimalistic copy file (preserves original)
# Usage: cp_file "source" "destination"
cp_file() {
    cp "$1" "$2" 2>/dev/null
}

# ============================================
# EXECUTION TIME TRACKING (for --log mode)
# ============================================
EXECUTION_START_TIME=""
EXECUTION_END_TIME=""

# Function: Format execution time beautifully
format_execution_time() {
    local duration_ms="$1"
    local hours=$((duration_ms / 3600000))
    local minutes=$(((duration_ms % 3600000) / 60000))
    local seconds=$(((duration_ms % 60000) / 1000))
    local milliseconds=$((duration_ms % 1000))

    # Build the formatted string
    local formatted=""

    if [ $hours -gt 0 ]; then
        formatted="${hours}h ${minutes}m ${seconds}s ${milliseconds}ms"
    elif [ $minutes -gt 0 ]; then
        formatted="${minutes}m ${seconds}s ${milliseconds}ms"
    elif [ $seconds -gt 0 ]; then
        if [ $milliseconds -gt 0 ]; then
            formatted="${seconds}.$(printf "%03d" $milliseconds)s"
        else
            formatted="${seconds}s"
        fi
    else
        formatted="${milliseconds}ms"
    fi

    echo "$formatted"
}

# Function: Start execution timer
start_timer() {
    EXECUTION_START_TIME=$(date +%s%3N 2>/dev/null || python3 -c "import time; print(int(time.time() * 1000))" 2>/dev/null || echo "0")
}

# Function: Stop timer and display execution time
stop_timer() {
    EXECUTION_END_TIME=$(date +%s%3N 2>/dev/null || python3 -c "import time; print(int(time.time() * 1000))" 2>/dev/null || echo "0")

    if [ "$EXECUTION_START_TIME" != "0" ] && [ "$EXECUTION_END_TIME" != "0" ]; then
        local duration=$((EXECUTION_END_TIME - EXECUTION_START_TIME))
        local formatted_time=$(format_execution_time $duration)

        echo ""
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${GREEN}  ⏱  Execution Time: ${YELLOW}${formatted_time}${NC}"
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
    fi
}

# Function: Resolve file path based on EXECUTION_SOURCE
# This is for execution files (scripts, asm, binaries) NOT for the JS file
resolve_file_path() {
    local file_path="$1"
    file_path="${file_path#./}"
    case "$EXECUTION_SOURCE" in
        "source") echo "$SCRIPT_DIR/._/$file_path" ;;
        "dev"|*)  if [ -n "$WORKING_DIRECTORY" ]; then
                       echo "$WORKING_DIRECTORY/$file_path"
                   else
                       echo "$SCRIPT_DIR/dev/$file_path"
                   fi ;;
    esac
}

# Function: Execute a file using the unified basm.sh
# Usage: execute_file <mode> <file_path> [working_dir_type] [additional_args...]
#   mode: normal, silent, log
#   file_path: path relative to dev or ._ directory
#   working_dir_type: "caller", "file", or "global" (optional, defaults to "global")
execute_file() {
    local mode="$1"
    local file_path="$2"
    shift 2

    # Check if next argument is a working directory type
    local working_dir_type="global"
    if [ "$1" = "caller" ] || [ "$1" = "file" ] || [ "$1" = "global" ]; then
        working_dir_type="$1"
        shift
    fi

    local additional_args="$@"

    # Override mode if FORCE_LOG_MODE is true (only affects normal JS execution)
    if [ "$FORCE_LOG_MODE" = "true" ]; then
        mode="log"
    fi

    # Path to the single unified basm.sh (now relative to WORKING_DIRECTORY)
    local basm_script="$WORKING_DIRECTORY/basm/basm.sh"

    # Check if basm script exists
    if [ ! -f "$basm_script" ]; then
        echo -e "${RED}Error: basm script not found at $basm_script${NC}" >&2
        return 1
    fi

    # Make sure basm script is executable
    chmod +x "$basm_script" 2>/dev/null

    # Resolve the full path to the file
    local full_path=$(resolve_file_path "$file_path")

    # Check if file exists
    if [ ! -f "$full_path" ]; then
        echo -e "${RED}Error: File not found at $full_path${NC}" >&2
        return 1
    fi

    # Determine the working directory based on type
    local working_dir="$SCRIPT_DIR"  # Default: global (script's directory)
    case "$working_dir_type" in
        "caller")
            working_dir="$CALLER_DIR"  # Use caller's directory
            ;;
        "file")
            working_dir="$(dirname "$full_path")"  # Use file's directory
            ;;
        "global"|*)
            working_dir="$SCRIPT_DIR"  # Use script's directory
            ;;
    esac

    # Execute with appropriate mode and working directory
    case "$mode" in
        "silent")
            if [[ "$full_path" == *.sh ]]; then
                (cd "$working_dir" && bash "$full_path" $additional_args >/dev/null 2>&1)
            else
                (cd "$working_dir" && "$basm_script" --silent "$full_path" $additional_args)
            fi
            ;;
        "log")
            if [[ "$full_path" == *.sh ]]; then
                (cd "$working_dir" && bash "$full_path" $additional_args)
            else
                (cd "$working_dir" && "$basm_script" --log "$full_path" $additional_args)
            fi
            ;;
        "normal"|*)
            if [[ "$full_path" == *.sh ]]; then
                (cd "$working_dir" && bash "$full_path" $additional_args)
            else
                (cd "$working_dir" && "$basm_script" "$full_path" $additional_args)
            fi
            ;;
    esac

    return $?
}

# Function: Execute a sequence of files
# Usage: execute_sequence <mode> <file1> [file2] [file3...]
execute_sequence() {
    local mode="$1"
    shift
    local files=("$@")
    local success_count=0
    local fail_count=0

    # Override mode if FORCE_LOG_MODE is true (only affects normal JS execution)
    if [ "$FORCE_LOG_MODE" = "true" ]; then
        mode="log"
    fi

    echo -e "${BLUE}Executing sequence in ${mode} mode...${NC}"

    for file in "${files[@]}"; do
        echo -e "${YELLOW}Executing: $file${NC}"

        if execute_file "$mode" "$file"; then
            echo -e "${GREEN}✓ Successfully executed: $file${NC}"
            ((success_count++))
        else
            echo -e "${RED}✗ Failed to execute: $file${NC}"
            ((fail_count++))
        fi
        echo ""
    done

    echo -e "${BLUE}=== Sequence Summary ===${NC}"
    echo -e "${GREEN}Successful: $success_count${NC}"
    echo -e "${RED}Failed: $fail_count${NC}"

    return $fail_count
}

# ============================================
# COMPILE AND COPY FUNCTION (modified to accept destination directory)
# ============================================
# This now accepts an optional destination directory argument.
# Usage: compile_and_copy [destination_directory]
# If no argument, defaults to $SCRIPT_DIR/dev (backward compatibility)
compile_and_copy() {
    local destination_directory="${1:-$SCRIPT_DIR/dev}"

    dev_log "${BLUE}Starting compilation and linking of .asm files...${NC}"
    dev_log "${BLUE}Also copying .sh files and binaries to destination directory...${NC}"

    # Determine current architecture
    ARCH=""
    case "$(uname -m)" in
        "x86_64"|"amd64")
            ARCH="x86_64"
            FORMAT="elf64"
            ;;
        "i386"|"i486"|"i586"|"i686")
            ARCH="i386"
            FORMAT="elf32"
            ;;
        "arm"|"armv7l"|"armv8l"|"aarch64"|"arm64")
            ARCH="arm"
            FORMAT="elf32"
            ;;
        *)
            dev_error "${RED}Unsupported architecture: $(uname -m)${NC}"
            return 1
            ;;
    esac

    dev_log "${GREEN}Detected architecture: ${ARCH} (using ${FORMAT} format)${NC}"

    # Set up NASM binary path (based on script's directory)
    NASM_BINARY="$SCRIPT_DIR/._/basm/${ARCH}-linux/nasm-${ARCH}-linux"

    # Check if NASM binary exists
    if [ ! -f "$NASM_BINARY" ]; then
        dev_error "${RED}NASM binary not found at: $NASM_BINARY${NC}"
        return 1
    fi

    dev_log "${GREEN}Using NASM binary: $NASM_BINARY${NC}"

    # Make NASM binary executable
    chmod +x "$NASM_BINARY" 2>/dev/null

    # Clean up old destination directory and create brand new
    dev_log "${BLUE}Cleaning up and creating new directory: $destination_directory ...${NC}"
    rm -rf "$destination_directory" 2>/dev/null
    mkdir -p "$destination_directory" 2>/dev/null

    # Create directory structure for all directories EXCEPT nasm (we'll handle basm separately)
    dev_log "${BLUE}Creating directory structure...${NC}"
    find "$SCRIPT_DIR/._" -type d 2>/dev/null | while IFS= read -r dir; do
        # Skip the entire nasm directory - we'll handle basm files manually
        if [[ "$dir" == "$SCRIPT_DIR/._/basm"* ]]; then
            continue
        fi

        # Create corresponding directory in destination
        new_dir="${dir/$SCRIPT_DIR\/\.\_/$destination_directory}"
        mkdir -p "$new_dir" 2>/dev/null
    done

    # Special handling for basm directory - create full structure
    dev_log "${BLUE}Creating basm directory structure...${NC}"
    mkdir -p "$destination_directory/basm" 2>/dev/null
    mkdir -p "$destination_directory/basm/arm-linux" 2>/dev/null
    mkdir -p "$destination_directory/basm/i386-linux" 2>/dev/null
    mkdir -p "$destination_directory/basm/x86_64-linux" 2>/dev/null

    # Find all .asm files (excluding basm directory)
    dev_log "${BLUE}Finding .asm files...${NC}"
    ASM_FILES=$(find "$SCRIPT_DIR/._" -name "*.asm" ! -path "$SCRIPT_DIR/._/basm/*" 2>/dev/null)
    ASM_COUNT=$(echo "$ASM_FILES" | wc -l)

    # Find all .sh files (excluding basm directory - we'll handle basm scripts separately)
    dev_log "${BLUE}Finding .sh files...${NC}"
    SH_FILES=$(find "$SCRIPT_DIR/._" -name "*.sh" ! -path "$SCRIPT_DIR/._/basm/*" 2>/dev/null)
    SH_COUNT=$(echo "$SH_FILES" | wc -l)

    # Find all binary files (excluding basm directory - we'll handle basm binaries separately)
    dev_log "${BLUE}Finding binary files...${NC}"
    BINARY_FILES=$(find "$SCRIPT_DIR/._" -type f ! -name "*.asm" ! -name "*.sh" ! -path "$SCRIPT_DIR/._/basm/*" 2>/dev/null)
    BINARY_COUNT=$(echo "$BINARY_FILES" | wc -l)

    # Find all files in basm directory (scripts, binaries, everything)
    dev_log "${BLUE}Finding basm files...${NC}"
    BASM_FILES=$(find "$SCRIPT_DIR/._/basm" -type f 2>/dev/null)
    BASM_COUNT=$(echo "$BASM_FILES" | wc -l)

    TOTAL_FILES=$((ASM_COUNT + SH_COUNT + BINARY_COUNT + BASM_COUNT))

    if [ "$TOTAL_FILES" -eq 0 ]; then
        dev_error "${RED}No .asm, .sh, binary, or basm files found!${NC}"
        return 1
    fi

    dev_log "${YELLOW}Found $ASM_COUNT .asm files, $SH_COUNT .sh files, $BINARY_COUNT binary files, and $BASM_COUNT basm files to process${NC}"

    # Initialize counters
    total_asm_files=0
    compiled_files=0
    failed_asm_files=0

    total_sh_files=0
    copied_sh_files=0
    failed_sh_files=0

    total_binary_files=0
    copied_binary_files=0
    failed_binary_files=0

    total_basm_files=0
    copied_basm_files=0
    failed_basm_files=0

    # ============================================
    # PROCESS 1: Compile and link all .asm files
    # ============================================
    if [ "$ASM_COUNT" -gt 0 ]; then
        dev_log "${BLUE}\n[1/4] Compiling and linking .asm files...${NC}"

        while IFS= read -r asm_file; do
            ((total_asm_files++))

            dev_log "\n${YELLOW}[${total_asm_files}] Processing ASM: ${asm_file}${NC}"

            # Generate output paths
            output_file="${asm_file/$SCRIPT_DIR\/\.\_/$destination_directory}"
            output_file="${output_file%.asm}"  # Remove .asm extension
            object_file="${output_file}.o"

            # Ensure output directory exists
            mkdir -p "$(dirname "$output_file")" 2>/dev/null

            # Step 1: Compile with NASM (completely silent)
            dev_log "  Compiling: $NASM_BINARY -f ${FORMAT} \"${asm_file}\" -o \"${object_file}\""
            "$NASM_BINARY" -f "$FORMAT" "$asm_file" -o "$object_file" 2>/dev/null
            NASM_EXIT=$?

            if [ $NASM_EXIT -eq 0 ]; then
                dev_log "  ${GREEN}✓ Compilation successful${NC}"
            else
                dev_error "${RED}  ✗ Compilation failed for: ${asm_file}${NC}"
                rm -f "$object_file" 2>/dev/null
                ((failed_asm_files++))
                continue
            fi

            # Step 2: Link with LD (completely silent)
            dev_log "  Linking: ld \"${object_file}\" -o \"${output_file}\""
            ld "$object_file" -o "$output_file" 2>/dev/null
            LD_EXIT=$?

            if [ $LD_EXIT -eq 0 ]; then
                dev_log "  ${GREEN}✓ Linking successful${NC}"
                chmod +x "$output_file" 2>/dev/null
                ((compiled_files++))
            else
                dev_error "${RED}  ✗ Linking failed for: ${asm_file}${NC}"
                ((failed_asm_files++))
            fi

            # Step 3: Clean up object file
            rm -f "$object_file" 2>/dev/null
            dev_log "  ${BLUE}✓ Cleaned up object file${NC}"

        done < <(echo "$ASM_FILES")
    fi

    # ============================================
    # PROCESS 2: Copy all .sh files (non-basm)
    # ============================================
    if [ "$SH_COUNT" -gt 0 ]; then
        dev_log "\n${BLUE}[2/4] Copying .sh files to destination directory...${NC}"

        while IFS= read -r sh_file; do
            ((total_sh_files++))

            dev_log "${YELLOW}[${total_sh_files}] Copying SH: ${sh_file}${NC}"

            # Generate output path
            output_file="${sh_file/$SCRIPT_DIR\/\.\_/$destination_directory}"

            # Ensure output directory exists
            mkdir -p "$(dirname "$output_file")" 2>/dev/null

            # Copy the .sh file (completely silent)
            dev_log "  Copying: cp \"${sh_file}\" \"${output_file}\""
            cp_file "$sh_file" "$output_file"
            COPY_EXIT=$?

            if [ $COPY_EXIT -eq 0 ]; then
                # Make it executable
                chmod +x "$output_file" 2>/dev/null
                dev_log "  ${GREEN}✓ Copy successful${NC}"
                ((copied_sh_files++))
            else
                dev_error "${RED}  ✗ Copy failed for: ${sh_file}${NC}"
                ((failed_sh_files++))
            fi

        done < <(echo "$SH_FILES")
    fi

    # ============================================
    # PROCESS 3: Copy all binary files (non-basm)
    # ============================================
    if [ "$BINARY_COUNT" -gt 0 ] && [ -n "$BINARY_FILES" ]; then
        dev_log "\n${BLUE}[3/4] Copying binary files to destination directory...${NC}"

        while IFS= read -r binary_file; do
            # Skip empty lines
            [ -z "$binary_file" ] && continue

            ((total_binary_files++))

            dev_log "${YELLOW}[${total_binary_files}] Copying binary: ${binary_file}${NC}"

            # Generate output path
            output_file="${binary_file/$SCRIPT_DIR\/\.\_/$destination_directory}"

            # Ensure output directory exists
            mkdir -p "$(dirname "$output_file")" 2>/dev/null

            # Copy the binary file (completely silent)
            dev_log "  Copying: cp \"${binary_file}\" \"${output_file}\""
            cp_file "$binary_file" "$output_file"
            COPY_EXIT=$?

            if [ $COPY_EXIT -eq 0 ]; then
                # Make it executable
                chmod +x "$output_file" 2>/dev/null
                dev_log "  ${GREEN}✓ Binary copy successful${NC}"
                ((copied_binary_files++))
            else
                dev_error "${RED}  ✗ Binary copy failed for: ${binary_file}${NC}"
                ((failed_binary_files++))
            fi

        done < <(echo "$BINARY_FILES")
    fi

    # ============================================
    # PROCESS 4: Copy all basm files (scripts and binaries)
    # ============================================
    if [ "$BASM_COUNT" -gt 0 ] && [ -n "$BASM_FILES" ]; then
        dev_log "\n${BLUE}[4/4] Copying basm files to destination directory...${NC}"

        while IFS= read -r basm_file; do
            # Skip empty lines
            [ -z "$basm_file" ] && continue

            ((total_basm_files++))

            dev_log "${YELLOW}[${total_basm_files}] Processing basm file: ${basm_file}${NC}"

            # Generate output path (preserve subdirectory structure)
            output_file="${basm_file/$SCRIPT_DIR\/\.\_/$destination_directory}"

            # Ensure output directory exists
            mkdir -p "$(dirname "$output_file")" 2>/dev/null

            # Copy the file (completely silent)
            dev_log "  Copying: cp \"${basm_file}\" \"${output_file}\""
            cp_file "$basm_file" "$output_file"
            COPY_EXIT=$?

            if [ $COPY_EXIT -eq 0 ]; then
                # Make it executable if it's a binary or script
                chmod +x "$output_file" 2>/dev/null
                dev_log "  ${GREEN}✓ Copy successful${NC}"
                ((copied_basm_files++))
            else
                dev_error "${RED}  ✗ Copy failed for: ${basm_file}${NC}"
                ((failed_basm_files++))
            fi

        done < <(echo "$BASM_FILES")
    fi

    # ============================================
    # SUMMARY (only shown in verbose mode)
    # ============================================
    if [ "$VERBOSE_DEV" = "true" ]; then
        echo -e "\n${BLUE}=== Compilation Summary ===${NC}"
        if [ "$ASM_COUNT" -gt 0 ]; then
            echo -e "${GREEN}Successfully compiled and linked: ${compiled_files} .asm files${NC}"
            if [ $failed_asm_files -gt 0 ]; then
                echo -e "${RED}Failed: ${failed_asm_files} .asm files${NC}"
            fi
            echo -e "Total .asm files processed: ${total_asm_files}"
        fi

        if [ "$SH_COUNT" -gt 0 ]; then
            echo -e "\n${BLUE}=== Shell Script Copy Summary ===${NC}"
            echo -e "${GREEN}Successfully copied: ${copied_sh_files} .sh files${NC}"
            if [ $failed_sh_files -gt 0 ]; then
                echo -e "${RED}Failed: ${failed_sh_files} .sh files${NC}"
            fi
            echo -e "Total .sh files processed: ${total_sh_files}"
        fi

        if [ "$BINARY_COUNT" -gt 0 ]; then
            echo -e "\n${BLUE}=== Binary Copy Summary ===${NC}"
            echo -e "${GREEN}Successfully copied: ${copied_binary_files} binary files${NC}"
            if [ $failed_binary_files -gt 0 ]; then
                echo -e "${RED}Failed: ${failed_binary_files} binary files${NC}"
            fi
            echo -e "Total binary files processed: ${total_binary_files}"
        fi

        if [ "$BASM_COUNT" -gt 0 ]; then
            echo -e "\n${BLUE}=== BASM Files Copy Summary ===${NC}"
            echo -e "${GREEN}Successfully copied: ${copied_basm_files} basm files${NC}"
            if [ $failed_basm_files -gt 0 ]; then
                echo -e "${RED}Failed: ${failed_basm_files} basm files${NC}"
            fi
            echo -e "Total basm files processed: ${total_basm_files}"

            # List the basm directory contents specifically
            echo -e "\n${BLUE}=== $destination_directory/basm Directory Contents ===${NC}"
            if [ -d "$destination_directory/basm" ]; then
                ls -la "$destination_directory/basm" 2>/dev/null | tail -n +2
            fi
        fi

        echo -e "\n${GREEN}Output directory: $destination_directory${NC}"

        # Display what's in $destination_directory with tree-like structure
        echo -e "\n${BLUE}=== $destination_directory Directory Structure ===${NC}"
        echo -e "${GREEN}Executable files created:${NC}"

        # Use a simple tree display
        list_files() {
            local indent="$1"
            local dir="$2"

            for item in "$dir"/*; do
                if [ -d "$item" ]; then
                    echo -e "${indent}└── $(basename "$item")/"
                    list_files "    $indent" "$item"
                elif [ -f "$item" ]; then
                    if [ -x "$item" ]; then
                        echo -e "${indent}└── ${GREEN}$(basename "$item") ✓${NC}"
                    else
                        echo -e "${indent}└── $(basename "$item")"
                    fi
                fi
            done
        }

        # Start listing from $destination_directory
        for item in "$destination_directory"/*; do
            if [ -d "$item" ]; then
                echo "└── $(basename "$item")/"
                list_files "    " "$item"
            elif [ -f "$item" ]; then
                if [ -x "$item" ]; then
                    echo -e "└── ${GREEN}$(basename "$item") ✓${NC}"
                else
                    echo "└── $(basename "$item")"
                fi
            fi
        done

        # Verify all files were created
        echo -e "\n${BLUE}=== Verification ===${NC}"
        if [ "$ASM_COUNT" -gt 0 ]; then
            echo -e "Expected .asm files: $ASM_COUNT"
        fi
        if [ "$SH_COUNT" -gt 0 ]; then
            echo -e "Expected .sh files: $SH_COUNT"
        fi
        if [ "$BINARY_COUNT" -gt 0 ]; then
            echo -e "Expected binary files: $BINARY_COUNT"
        fi
        if [ "$BASM_COUNT" -gt 0 ]; then
            echo -e "Expected basm files: $BASM_COUNT"
        fi

        expected_total=$((ASM_COUNT + SH_COUNT + BINARY_COUNT + BASM_COUNT))
        actual_total=$(find "$destination_directory" -type f 2>/dev/null | wc -l)

        echo -e "Total files created: $actual_total"

        if [ "$expected_total" -eq "$actual_total" ]; then
            echo -e "${GREEN}✓ All files were successfully created!${NC}"
        else
            echo -e "${YELLOW}⚠ Some files might be missing (expected: $expected_total, got: $actual_total)${NC}"
        fi

        echo -e "\n${GREEN}Build completed successfully!${NC}"
        echo -e "All binaries, shell scripts, and executables are available in the $destination_directory directory"
    fi

    return 0
}

# ============================================
# EXECUTION STEP FUNCTIONS
# ============================================

# Display usage information (minimalistic)
show_usage() {
    echo -e "${YELLOW}Usage: bash Raw.sh [--log] [--verbose] <path/to/file.js> [args...]${NC}"
    echo -e "${YELLOW}       bash Raw.sh --reset${NC}"
    echo -e "${YELLOW}       bash Raw.sh --test${NC}"
    echo -e "${YELLOW}       bash Raw.sh --cli${NC}"
    echo -e "${YELLOW}       bash Raw.sh --dev${NC}"
    echo -e "${YELLOW}       bash Raw.sh --tool [command] [args...]${NC}"
    echo -e "${YELLOW}       bash Raw.sh --<tool> [args...]${NC}"
    echo -e "${YELLOW}       bash Raw.sh --tools${NC}"
    echo -e "${YELLOW}       bash Raw.sh --stools${NC}"
    echo -e "${YELLOW}       bash Raw.sh --version${NC}"
    echo -e "${YELLOW}       bash Raw.sh --asm [path/to/file.js] [args...]${NC}"
    echo -e "${YELLOW}       bash Raw.sh --bin [output_name] <path/to/file.js> [args...]${NC}"
    echo -e "${YELLOW}       bash Raw.sh --bin [options] <build_output.asm>${NC}"
    echo -e "${YELLOW}       bash Raw.sh --start${NC}"
}

# Process the JavaScript file - just store path and args for later use
# Usage: process_js_file <js_file_path> [js_args...]
process_js_file() {
    local js_file="$1"
    shift
    local js_args="$@"

    # Check if JS file exists
    if [ ! -f "$js_file" ]; then
        echo -e "${RED}Error: JS file not found: $js_file${NC}" >&2
        return 1
    fi

    # Get absolute path for the JS file
    local abs_js_path=$(realpath "$js_file" 2>/dev/null || echo "$(cd "$(dirname "$js_file")" && pwd)/$(basename "$js_file")")

    # Store in global variables for use in execution patterns
    JS_FILE_PATH="$abs_js_path"
    JS_ARGS="$js_args"

    return 0
}

# Function: Copy build_output.asm to caller's directory
copy_asm_to_caller() {
    local source_asm="$WORKING_DIRECTORY/build_output.asm"

    # Check if build_output.asm exists
    if [ ! -f "$source_asm" ]; then
        echo -e "${RED}Error: build_output.asm not found in working directory${NC}" >&2
        return 1
    fi

    # Copy to caller's directory (replacing if exists)
    cp_file "$source_asm" "$CALLER_DIR/build_output.asm"

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ build_output.asm copied to: $CALLER_DIR/build_output.asm${NC}"
        return 0
    else
        echo -e "${RED}✗ Failed to copy build_output.asm to caller directory${NC}" >&2
        return 1
    fi
}

# Function: Execute binary generation using basm.sh with --bin flag
# Usage: generate_binary <asm_file_path> <output_name>
generate_binary() {
    local asm_file="$1"
    local output_name="$2"

    # Path to the basm script (now relative to WORKING_DIRECTORY)
    local basm_script="$WORKING_DIRECTORY/basm/basm.sh"

    # Check if basm script exists
    if [ ! -f "$basm_script" ]; then
        echo -e "${RED}Error: basm script not found at $basm_script${NC}" >&2
        return 1
    fi

    # Make sure basm script is executable
    chmod +x "$basm_script" 2>/dev/null

    echo -e "${BLUE}Binary generation started...${NC}"
    echo -e "${YELLOW}Input ASM: $asm_file${NC}"

    if [ -n "$output_name" ]; then
        echo -e "${YELLOW}Output name: $output_name${NC}"
        # Execute basm with --bin and output name
        (cd "$CALLER_DIR" && "$basm_script" --log --bin "$output_name" "$asm_file")
    else
        # Execute basm with --bin without output name
        (cd "$CALLER_DIR" && "$basm_script" --log --bin "$asm_file")
    fi

    local result=$?

    if [ $result -eq 0 ]; then
        echo ""
        echo -e "${GREEN}Binary generation completed successfully!${NC}"
        if [ -n "$output_name" ]; then
            echo -e "${GREEN}Output: $CALLER_DIR/$output_name${NC}"
        else
            echo -e "${GREEN}Output: $CALLER_DIR/a.out${NC}"
        fi
    else
        echo -e "${RED}Binary generation failed with exit code: $result${NC}" >&2
    fi

    return $result
}

# Creates an interactive CLI where each line is treated as JS code
handle_cli() {
    clear
    echo -e "${GREEN}RawJS${NC} ${YELLOW}· exit | clear | errorgen${NC}"
    echo ""

    local cli_js_file="$CALLER_DIR/.rawjs_cli.js"
    local cli_backup_file="$CALLER_DIR/.rawjs_cli.backup.js"

    # Initialize empty JS file
    : > "$cli_js_file"

    # working script = only successful lines (used for incremental execution)
    local working_script=""
    # full transcript = all typed lines (including failed ones, used for errorgen)
    local full_transcript=""
    local previous_output=""

    while true; do
        echo -ne "${GREEN} > ${NC}"
        if ! IFS= read -r user_input; then
            echo ""
            break
        fi

        if [ "$user_input" = "exit" ] || [ "$user_input" = "quit" ]; then
            clear
            break
        fi

        if [ "$user_input" = "clear" ]; then
            : > "$cli_js_file"
            working_script=""
            full_transcript=""
            previous_output=""
            clear
            echo -e "${GREEN}RawJS${NC} ${YELLOW}· exit | clear | errorgen${NC}"
            echo ""
            continue
        fi

        if [ -z "$user_input" ]; then
            continue
        fi

        # errorgen command: process the FULL transcript (including failed lines)
        if [[ "$user_input" == *"errorgen"* ]]; then
            echo -e "${YELLOW}errorgen detected. Writing full transcript to .rawjs_cli.js and generating logs...${NC}"

            # Write the complete transcript (all lines typed) to the file
            printf "%s\n" "$full_transcript" > "$cli_js_file"

            local log_file="$CALLER_DIR/.rawjs_cli.log.txt"
            local verbose_file="$CALLER_DIR/.rawjs_cli.verbose.txt"
            local full_file="$CALLER_DIR/.rawjs_cli.full.txt"

            echo -e "${BLUE}Running with --log...${NC}"
            (cd "$CALLER_DIR" && bash "$SCRIPT_DIR/Raw.sh" --log .rawjs_cli.js > "$log_file" 2>&1)
            local log_status=$?

            echo -e "${BLUE}Running with --verbose...${NC}"
            (cd "$CALLER_DIR" && bash "$SCRIPT_DIR/Raw.sh" --verbose .rawjs_cli.js > "$verbose_file" 2>&1)
            local verbose_status=$?

            echo -e "${BLUE}Running with --asm...${NC}"
            (cd "$CALLER_DIR" && bash "$SCRIPT_DIR/Raw.sh" --asm .rawjs_cli.js > /dev/null 2>&1)
            local asm_status=$?

            # Strip ANSI codes from log and verbose files
            echo -e "${BLUE}Stripping ANSI codes from log and verbose files...${NC}"

            # Create temporary files for stripped content
            local log_file_stripped="${log_file}.stripped"
            local verbose_file_stripped="${verbose_file}.stripped"

            # Strip ANSI codes from log file
            if [ -f "$log_file" ]; then
                strip_ansi_codes "$(cat "$log_file")" > "$log_file_stripped"
                mv_file "$log_file_stripped" "$log_file"
                echo -e "${GREEN}✓ ANSI codes stripped from log file${NC}"
            fi

            # Strip ANSI codes from verbose file
            if [ -f "$verbose_file" ]; then
                strip_ansi_codes "$(cat "$verbose_file")" > "$verbose_file_stripped"
                mv_file "$verbose_file_stripped" "$verbose_file"
                echo -e "${GREEN}✓ ANSI codes stripped from verbose file${NC}"
            fi

            echo -e "${BLUE}Generating full output file...${NC}"
            {
                echo "Full Error Log - Generated by Raw.sh CLI errorgen"
                echo "Generated at: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
                echo "Caller Directory: ${CALLER_DIR}"
                echo "========================================="
                echo ""
                echo "--- Verbose Mode Output ---"
                echo ""
                strip_ansi_codes "$(cat "$verbose_file")"
                echo ""
                echo "--- Complete JS Source Code (full transcript) ---"
                echo "File: ${cli_js_file}"
                echo ""
                cat "$cli_js_file"
                echo ""
                echo "--- ASM Output ---"
                echo "Command: bash $SCRIPT_DIR/Raw.sh --asm .rawjs_cli.js"
                echo "Exit Code: ${asm_status}"
                echo ""
            } > "$full_file"

            local asm_file="$WORKING_DIRECTORY/build_output.asm"
            if [ -f "$asm_file" ]; then
                {
                    echo "--- Generated .asm File Content (from: ${asm_file}) ---"
                    echo ""
                    cat "$asm_file"
                    echo ""
                    echo "========================================="
                } >> "$full_file"
                rm_file "$asm_file"
                echo -e "${GREEN}✓ ASM file content captured and removed${NC}"
            else
                local found_asm=""
                if [ -f "$CALLER_DIR/build_output.asm" ]; then
                    found_asm="$CALLER_DIR/build_output.asm"
                fi

                if [ -n "$found_asm" ] && [ -f "$found_asm" ]; then
                    {
                        echo "--- Generated .asm File Content (from: ${found_asm}) ---"
                        echo ""
                        cat "$found_asm"
                        echo ""
                        echo "========================================="
                    } >> "$full_file"
                    rm_file "$found_asm"
                    echo -e "${GREEN}✓ ASM file content captured from $found_asm and removed${NC}"
                else
                    {
                        echo "--- Warning: No build_output.asm file found ---"
                        echo "ASM generation may have failed"
                        echo "========================================="
                    } >> "$full_file"
                    echo -e "${YELLOW}⚠ No build_output.asm file found${NC}"
                fi
            fi

            echo -e "${GREEN}✓ .rawjs_cli.js written with full transcript${NC}"
            echo -e "${GREEN}✓ Log file (--log): $log_file${NC}"
            echo -e "${GREEN}✓ Verbose file (--verbose): $verbose_file${NC}"
            echo -e "${GREEN}✓ Full file (verbose + JS + ASM): $full_file${NC}"

            return 0
        fi

        # ===== NUCLEAR ROLLBACK PREPARATION =====
        # Append to full transcript unconditionally (never rolled back)
        if [ -n "$full_transcript" ]; then
            full_transcript="$full_transcript"$'\n'"$user_input"
        else
            full_transcript="$user_input"
        fi

        # Save current working script state before modification
        local prev_working_script="$working_script"
        cp "$cli_js_file" "$cli_backup_file" 2>/dev/null

        # Append to working script for this attempt
        if [ -n "$working_script" ]; then
            working_script="$working_script"$'\n'"$user_input"
        else
            working_script="$user_input"
        fi

        # Append to the working JS file
        echo "$user_input" >> "$cli_js_file"

        local compile_success=true
        local compile_error=""
        local output_js="$SCRIPT_DIR/output.js"

        # Pipeline steps (same as before, but using WORKING_DIRECTORY for moves)
        if ! execute_file "silent" "./._/min/min" "$cli_js_file" >/dev/null 2>&1; then
            compile_success=false
            compile_error="minification"
        fi

        if [ "$compile_success" = true ]; then
            if ! execute_file "silent" "./._/min/polish.sh" "$output_js" >/dev/null 2>&1; then
                compile_success=false
                compile_error="polishing"
            fi
        fi

        if [ "$compile_success" = true ]; then
            if ! execute_file "silent" "./build" >/dev/null 2>&1; then
                compile_success=false
                compile_error="build"
            fi
        fi

        if [ "$compile_success" = true ]; then
            mv_file "build_output.asm" "$WORKING_DIRECTORY/build_output.asm" 2>/dev/null

            if ! execute_file "silent" "./arch" "$output_js" >/dev/null 2>&1; then
                compile_success=false
                compile_error="arch"
            fi
        fi

        if [ "$compile_success" = true ]; then
            mv_file "arch_output" "$WORKING_DIRECTORY/arch_output" 2>/dev/null
            rm_file "$SCRIPT_DIR/output.js" 2>/dev/null

            if ! execute_file "silent" "./tree/build.sh" >/dev/null 2>&1; then
                compile_success=false
                compile_error="tree/build"
            fi
        fi

        # Run the final binary
        local current_output=""
        local execution_success=0
        if [ "$compile_success" = true ]; then
            current_output=$(execute_file "log" "./build_output.asm" 2>&1)
            execution_success=$?
        else
            execution_success=1
        fi

        # ===== ROLLBACK ON ANY FAILURE =====
        if [ "$compile_success" = false ] || [ $execution_success -ne 0 ]; then
            # Restore working script to previous state (remove the offending line)
            working_script="$prev_working_script"

            # Restore the working JS file from backup
            cp "$cli_backup_file" "$cli_js_file" 2>/dev/null

            # Clean up any leftover files
            rm_file "$SCRIPT_DIR/output.js" 2>/dev/null
            rm_file "$SCRIPT_DIR/arch_output" 2>/dev/null
            rm_file "$WORKING_DIRECTORY/arch_output" 2>/dev/null
            rm_file "$WORKING_DIRECTORY/build_output.asm" 2>/dev/null

            if [ "$compile_success" = false ]; then
                echo -e "${RED}✗ Compilation failed!${NC}"
                echo -e "${RED}  Error in: $compile_error step${NC}"
                echo -e "${YELLOW}  Removed line: $user_input${NC}"
            else
                echo -e "${RED}✗ Execution failed!${NC}"
                echo -e "${YELLOW}  Removed line: $user_input${NC}"
            fi
            echo ""
            continue
        fi

        # ===== SUCCESS: keep the new state =====
        # Extract only new output
        if [ -n "$previous_output" ]; then
            local new_output=$(diff <(echo "$previous_output") <(echo "$current_output") | grep '^>' | sed 's/^> //')
            if [ -n "$new_output" ]; then
                echo "$new_output"
            fi
        else
            echo "$current_output"
        fi

        previous_output="$current_output"
        echo ""
    done

    # Cleanup temp files
    rm_file "$cli_js_file"
    rm_file "$cli_backup_file" 2>/dev/null

    return 0
}

# ============================================
# SPECIAL MODE HANDLERS
# ============================================

# Handle --reset mode
handle_reset() {
    echo -e "${YELLOW}Resetting runtime pool...${NC}"

    mkdir -p "$LOCK_DIRECTORY"

    # Acquire global lock to prevent concurrent resets and initialization
    if ! mkdir "$GLOBAL_LOCK_FILE" 2>/dev/null; then
        echo -e "${YELLOW}Another reset is in progress. Waiting...${NC}"
        local wait_count=0
        while [ -d "$GLOBAL_LOCK_FILE" ] && [ $wait_count -lt 30 ]; do
            sleep 1
            wait_count=$((wait_count + 1))
        done
        if [ -d "$GLOBAL_LOCK_FILE" ]; then
            echo -e "${RED}Reset lock timeout. Another reset may be stuck.${NC}" >&2
            return 1
        fi
        if ! mkdir "$GLOBAL_LOCK_FILE" 2>/dev/null; then
            echo -e "${RED}Failed to acquire reset lock.${NC}" >&2
            return 1
        fi
    fi

    # Clean up only inactive directories.
    # Active directories (with a valid active lock) are preserved.
    local index=1
    while [ -d "$SCRIPT_DIR/${POOL_PREFIX}${index}" ]; do
        local dir="$SCRIPT_DIR/${POOL_PREFIX}${index}"
        local owner_file="$LOCK_DIRECTORY/owner_$index"
        local active_lock="$LOCK_DIRECTORY/active_$index"

        local should_delete=1
        if [ -d "$active_lock" ]; then
            local owner_id=""
            local owner_time=0
            if [ -f "$owner_file" ]; then
                read -r owner_id owner_time < "$owner_file" 2>/dev/null
            fi
            local current_ts
            current_ts=$(date +%s)
            if [ -n "$owner_id" ] && [ $((current_ts - owner_time)) -le "$LOCK_TIMEOUT_SECONDS" ]; then
                should_delete=0
            else
                rmdir "$active_lock" 2>/dev/null
                rm -f "$owner_file"
            fi
        fi

        if [ "$should_delete" = "1" ]; then
            rm -rf "$dir"
            rm -f "$owner_file"
            rm -rf "$active_lock"
        fi

        index=$((index + 1))
    done

    # Rebuild pool to the configured size.
    ensure_pool_dirs_locked
    local result=$?

    # Release global lock
    rmdir "$GLOBAL_LOCK_FILE" 2>/dev/null

    if [ $result -eq 0 ]; then
        echo -e "${GREEN}Reset completed successfully! Runtime pool has been rebuilt.${NC}"

        # If asm mode is active, copy the asm file after reset
        if [ "$ASM_MODE" = "true" ]; then
            # Acquire a working directory for the copy
            acquire_working_directory
            if [ $? -eq 0 ]; then
                copy_asm_to_caller
            fi
        fi

        return 0
    else
        echo -e "${RED}Reset failed during pool initialization!${NC}"
        return 1
    fi
}

# Handle --test mode
handle_test() {
    local test_args="$@"

    echo -e "${YELLOW}Running test mode...${NC}"

    # First reset the runtime pool safely.
    echo -e "${BLUE}Step 1: Resetting runtime pool...${NC}"
    handle_reset
    if [ $? -ne 0 ]; then
        echo -e "${RED}Test failed: Could not rebuild runtime pool!${NC}"
        return 1
    fi

    # Acquire a working directory for the test process.
    acquire_working_directory
    if [ $? -ne 0 ]; then
        echo -e "${RED}Test failed: Could not acquire working directory.${NC}" >&2
        return 1
    fi

    # Then execute the test script.
    echo -e "${BLUE}Step 2: Executing test script...${NC}"
    local test_script="$WORKING_DIRECTORY/._/._/._/runtest.sh"

    if [ ! -f "$test_script" ]; then
        echo -e "${RED}Error: Test script not found at $test_script${NC}"
        return 1
    fi

    # Make it executable
    chmod +x "$test_script" 2>/dev/null

    # Execute with bash, passing any additional arguments
    if [ -n "$test_args" ]; then
        echo -e "${GREEN}Running test script with arguments: $test_args${NC}"
        bash "$test_script" $test_args
    else
        echo -e "${GREEN}Running test script...${NC}"
        bash "$test_script"
    fi

    local test_result=$?

    if [ $test_result -eq 0 ]; then
        echo -e "${GREEN}Tests completed successfully!${NC}"

        # If asm mode is active, copy the asm file after test
        if [ "$ASM_MODE" = "true" ]; then
            copy_asm_to_caller
        fi
    else
        echo -e "${RED}Tests failed with exit code: $test_result${NC}"
    fi

    return $test_result
}

# ============================================
# TOOL GROUPS SYSTEM
# ============================================

# Function: Check if a tool belongs to a specific group
is_tool_in_group() {
    local tool_name="$1"
    local group_name="$2"

    # Get the array of tools for this group
    local group_array_name="TOOL_GROUP_${group_name}_TOOLS[@]"

    # Check if the tool is in this group's array
    for group_tool in "${!group_array_name}"; do
        if [ "$group_tool" = "$tool_name" ]; then
            return 0  # Found
        fi
    done

    return 1  # Not found
}

# Function: Get the group name for a specific tool
get_tool_group() {
    local tool_name="$1"

    # Check all defined groups first
    for group_name in "${TOOL_GROUPS_ORDER[@]}"; do
        if is_tool_in_group "$tool_name" "$group_name"; then
            echo "$group_name"
            return 0
        fi
    done

    # If not in any defined group, return "General"
    echo "General"
    return 0
}

# Function: Get color code for a group
get_group_color() {
    local group_name="$1"
    local color_variable="TOOL_GROUP_${group_name}_COLOR"
    local color="${!color_variable}"

    if [ -z "$color" ]; then
        # Default to white if no color defined
        echo "0;37"
    else
        echo "$color"
    fi
}

# Function: Get tool description by running the tool function
get_tool_description() {
    local tool_name="$1"

    # Check if tool function exists
    if ! declare -f "tool_${tool_name}" > /dev/null 2>&1; then
        echo "<no description>"
        return 0
    fi

    # Execute the tool function without arguments and capture first line of output
    local description=""
    description=$( (CALLER_DIR="$SCRIPT_DIR" tool_${tool_name} 2>&1 || true) | sed 's/\x1b\[[0-9;]*m//g' | head -n 1 | tr '\n' ' ' | sed 's/  */ /g' | xargs)

    # If no description, use a placeholder
    if [ -z "$description" ]; then
        description="<no description>"
    fi

    echo "$description"
}

# Function: Build a map of all tools and their groups
build_tool_group_map() {
    # Declare associative array for tool to group mapping
    declare -gA TOOL_GROUP_MAP

    # Get all available tool functions
    local all_tools=$(declare -F | grep -o 'tool_[a-zA-Z0-9_]*' | grep -v 'tool_mode\|tool_command\|tool_args\|tool_commands\|tool_group' | sed 's/^tool_//' | sort)

    # Assign each tool to its group
    while IFS= read -r tool_name; do
        if [ -n "$tool_name" ]; then
            local group=$(get_tool_group "$tool_name")
            TOOL_GROUP_MAP["$tool_name"]="$group"
        fi
    done <<< "$all_tools"
}

# Function: Get all tools for a specific group (sorted by group's defined order)
get_tools_for_group() {
    local group_name="$1"
    local group_array_name="TOOL_GROUP_${group_name}_TOOLS[@]"
    local group_tools=()

    # If this is a defined group with specific order
    if [ "$group_name" != "General" ] && [ ${#TOOL_GROUPS_ORDER[@]} -gt 0 ]; then
        # Use the defined order from the group array
        for tool_name in "${!group_array_name}"; do
            # Check if tool function actually exists
            if declare -f "tool_${tool_name}" > /dev/null 2>&1; then
                group_tools+=("$tool_name")
            fi
        done
    else
        # For General group, collect all tools not in any other group
        local all_tools=$(declare -F | grep -o 'tool_[a-zA-Z0-9_]*' | grep -v 'tool_mode\|tool_command\|tool_args\|tool_commands\|tool_group' | sed 's/^tool_//' | sort)

        while IFS= read -r tool_name; do
            if [ -n "$tool_name" ]; then
                local assigned_group=$(get_tool_group "$tool_name")
                if [ "$assigned_group" = "General" ]; then
                    # Only include if tool function exists
                    if declare -f "tool_${tool_name}" > /dev/null 2>&1; then
                        group_tools+=("$tool_name")
                    fi
                fi
            fi
        done <<< "$all_tools"
    fi

    # Return the array as newline-separated string
    printf '%s\n' "${group_tools[@]}"
}

# Function: Display formatted tool list with groups and colors (full version)
display_tool_list_with_groups() {
    # Build the tool-group map
    build_tool_group_map

    # Find the longest tool name for alignment
    local max_tool_length=0
    local all_tools=$(declare -F | grep -o 'tool_[a-zA-Z0-9_]*' | grep -v 'tool_mode\|tool_command\|tool_args\|tool_commands\|tool_group' | sed 's/^tool_//' | sort)

    while IFS= read -r tool_name; do
        if [ -n "$tool_name" ] && [ ${#tool_name} -gt $max_tool_length ]; then
            max_tool_length=${#tool_name}
        fi
    done <<< "$all_tools"

    # Create temp directory for parallel description fetching
    local temp_directory=$(mktemp -d)
    local process_ids=()

    # Fetch all tool descriptions in parallel
    while IFS= read -r tool_name; do
        if [ -n "$tool_name" ]; then
            (
                local description=$(get_tool_description "$tool_name")
                echo "$description" > "$temp_directory/${tool_name}.description"
            ) &
            process_ids+=($!)
        fi
    done <<< "$all_tools"

    # Wait for all background processes to complete
    for process_id in "${process_ids[@]}"; do
        wait $process_id 2>/dev/null
    done

    # Display header
    echo -e "\033[0;34mAvailable tools:\033[0m"
    echo ""

    # Calculate max description width based on terminal
    local terminal_width=${COLUMNS:-80}
    local separator=" | "
    local description_maximum=$((terminal_width - max_tool_length - ${#separator}))

    # Display tools group by group
    local has_general_tools=false

    # Process defined groups first (in order)
    for group_name in "${TOOL_GROUPS_ORDER[@]}"; do
        local group_tools_list=$(get_tools_for_group "$group_name")

        if [ -n "$group_tools_list" ]; then
            local group_color=$(get_group_color "$group_name")

            # Display group header with its color
            echo -e "\033[${group_color}m▸ ${group_name}:\033[0m"

            # Display tools in this group
            while IFS= read -r tool_name; do
                if [ -n "$tool_name" ]; then
                    local description="<no description>"
                    if [ -f "$temp_directory/${tool_name}.description" ]; then
                        description=$(cat "$temp_directory/${tool_name}.description")
                    fi

                    # Truncate description if too long
                    if [ ${#description} -gt $description_maximum ]; then
                        description="${description:0:$((description_maximum - 3))}..."
                    fi

                    # Get working directory for this tool
                    local working_directory=$(get_tool_working_dir "$tool_name")

                    # Display tool with group color
                    printf "  \033[${group_color}m--%-${max_tool_length}s\033[0m ${separator}%s \033[0;90m[dir: %s]\033[0m\n" \
                        "$tool_name" "$description" "$working_directory"
                fi
            done <<< "$group_tools_list"

            echo ""
        fi
    done

    # Check if there are any tools in General group
    local general_tools_list=$(get_tools_for_group "General")
    if [ -n "$general_tools_list" ]; then
        has_general_tools=true
        local general_color=$(get_group_color "General")

        # Display General group header
        echo -e "\033[${general_color}m▸ General:\033[0m"

        # Display tools in General group
        while IFS= read -r tool_name; do
            if [ -n "$tool_name" ]; then
                local description="<no description>"
                if [ -f "$temp_directory/${tool_name}.description" ]; then
                    description=$(cat "$temp_directory/${tool_name}.description")
                fi

                # Truncate description if too long
                if [ ${#description} -gt $description_maximum ]; then
                    description="${description:0:$((description_maximum - 3))}..."
                fi

                # Get working directory for this tool
                local working_directory=$(get_tool_working_dir "$tool_name")

                # Display tool with general color
                printf "  \033[${general_color}m--%-${max_tool_length}s\033[0m ${separator}%s \033[0;90m[dir: %s]\033[0m\n" \
                    "$tool_name" "$description" "$working_directory"
            fi
        done <<< "$general_tools_list"

        echo ""
    fi

    # Cleanup temp directory
    rm -rf "$temp_directory"

    # Display usage information
    echo -e "\033[1;33mUsage: bash Raw.sh --<tool> [args...]\033[0m"
    echo -e "\033[1;33m   or: bash Raw.sh --tool <tool> [args...]\033[0m"
    echo ""
    echo -e "\033[0;34mWorking directory types:\033[0m"
    echo -e "  \033[0;37mglobal\033[0m  - Execute from Raw.sh directory ($SCRIPT_DIR)"
    echo -e "  \033[0;37mcaller\033[0m  - Execute from where you called the command ($CALLER_DIR)"
    echo -e "  \033[0;37mfile\033[0m    - Execute from the tool file's own directory"
}

# Function: Display compact tool list (for --stools/--stool)
# Designed to fit in extremely small terminals with color toggling for clarity
display_compact_tool_list() {
    # Build the tool-group map
    build_tool_group_map

    # Get all available tool functions
    local all_tools=$(declare -F | grep -o 'tool_[a-zA-Z0-9_]*' | grep -v 'tool_mode\|tool_command\|tool_args\|tool_commands\|tool_group' | sed 's/^tool_//' | sort)

    # Collect all tools by group
    local group_tools_map=""

    # Process defined groups first (in order)
    for group_name in "${TOOL_GROUPS_ORDER[@]}"; do
        local group_tools_list=$(get_tools_for_group "$group_name")
        if [ -n "$group_tools_list" ]; then
            local group_color=$(get_group_color "$group_name")
            local tools_in_group=""

            while IFS= read -r tool_name; do
                if [ -n "$tool_name" ]; then
                    if [ -n "$tools_in_group" ]; then
                        tools_in_group="$tools_in_group,"
                    fi
                    tools_in_group="$tools_in_group$tool_name"
                fi
            done <<< "$group_tools_list"

            if [ -n "$tools_in_group" ]; then
                group_tools_map="$group_tools_map"$'\n'"$group_color|$group_name|$tools_in_group"
            fi
        fi
    done

    # Process General group
    local general_tools_list=$(get_tools_for_group "General")
    if [ -n "$general_tools_list" ]; then
        local general_color=$(get_group_color "General")
        local tools_in_general=""

        while IFS= read -r tool_name; do
            if [ -n "$tool_name" ]; then
                if [ -n "$tools_in_general" ]; then
                    tools_in_general="$tools_in_general,"
                fi
                tools_in_general="$tools_in_general$tool_name"
            fi
        done <<< "$general_tools_list"

        if [ -n "$tools_in_general" ]; then
            group_tools_map="$group_tools_map"$'\n'"$general_color|General|$tools_in_general"
        fi
    fi

    # Display compact header
    echo -e "\033[0;34mTools:\033[0m"

    # Display groups in compact format with alternating colors for each tool
    while IFS='|' read -r group_color group_name tools_list; do
        if [ -n "$group_name" ]; then
            # Display group name with color
            printf "\033[%sm%s:\033[0m " "$group_color" "$group_name"

            # Display tools with alternating background colors for clarity
            local tool_index=0
            IFS=',' read -ra TOOLS_ARRAY <<< "$tools_list"
            for tool_name in "${TOOLS_ARRAY[@]}"; do
                if [ $((tool_index % 2)) -eq 0 ]; then
                    # Even index - slightly darker background
                    printf "\033[48;5;235m\033[%sm%s\033[0m " "$group_color" "$tool_name"
                else
                    # Odd index - slightly lighter background
                    printf "\033[48;5;238m\033[%sm%s\033[0m " "$group_color" "$tool_name"
                fi
                ((tool_index++))
            done
            echo ""
        fi
    done <<< "$group_tools_map"

    echo ""
    echo -e "\033[0;90mUse --tools for detailed view\033[0m"
    echo -e "\033[1;33mUsage: --<tool> [args]\033[0m"
}

# ============================================
# TOOL COMMAND HANDLERS
# ============================================
# Add your tool command handlers here following this pattern:
#
# Function: Handle <command> tool command
# Usage: tool_<command>() {
#     # All arguments are passed as $@
#     # You can access individual args: $1, $2, $3, etc.
#     # Or pass all args: "$@"
#
#     # Get working directory type from configuration
#     local working_dir=$(get_tool_working_dir "command_name")
#
#     # Execute with automatic working directory handling
#     execute_file "normal" "path/to/your/script.sh" "$working_dir" "$@"
# }
# ============================================

# Function: Handle dual tool command
# Usage: bash Raw.sh --dual <arg1> <arg2> [arg3] [arg4...]
# This command can accept any number of arguments and passes them all
tool_dual() {
    # Get working directory from configuration
    local working_dir=$(get_tool_working_dir "dual")

    # Execute with automatic working directory handling
    execute_file "log" "../._/._/._/._/dual.sh" "$working_dir" "$@"

    return 0
}

tool_testcheck() {
    # Get working directory from configuration
    local working_dir=$(get_tool_working_dir "testcheck")

    # Execute with automatic working directory handling
    execute_file "log" "../._/._/._/._/testcheck.sh" "$working_dir" "$@"

    return 0
}

tool_info() {
    # Get working directory from configuration
    local working_dir=$(get_tool_working_dir "info")

    # Execute with automatic working directory handling
    execute_file "log" "../._/._/._/._/jsinfo.sh" "$working_dir" "$@"

    return 0
}

tool_min() {
    # Get working directory from configuration
    local working_dir=$(get_tool_working_dir "min")

    # Execute with automatic working directory handling
    execute_file "log" "./._/min/min" "$working_dir" "$@"

    return 0
}

tool_polish() {
    # Get working directory from configuration
    local working_dir=$(get_tool_working_dir "polish")

    # Execute with automatic working directory handling
    execute_file "log" "./._/min/polish.sh" "$working_dir" "$@"

    return 0
}

tool_arch() {
    # Get working directory from configuration
    local working_dir=$(get_tool_working_dir "arch")

    # Execute with automatic working directory handling
    execute_file "log" "./arch" "$working_dir" "$@"

    return 0
}

tool_chain() {
    # Get working directory from configuration
    local working_dir=$(get_tool_working_dir "chain")

    # Execute with automatic working directory handling
    execute_file "log" "./._/._/._/chaincheck.sh" "$working_dir" "$@"

    return 0
}

tool_clean() {
    # Get working directory from configuration
    local working_dir=$(get_tool_working_dir "clean")

    # Execute with automatic working directory handling
    execute_file "log" "../._/._/._/._/clean.sh" "$working_dir" "$@"

    return 0
}

tool_jsclean() {
    # Get working directory from configuration
    local working_dir=$(get_tool_working_dir "jsclean")

    # Execute with automatic working directory handling
    execute_file "log" "../._/._/._/._/jsclean.sh" "$working_dir" "$@"

    return 0
}

tool_emb() {
    # Get working directory from configuration
    local working_dir=$(get_tool_working_dir "emb")

    # Execute with automatic working directory handling
    execute_file "log" "../._/._/._/._/emb.sh" "$working_dir" "$@"

    return 0
}

# Function: Handle build tool command
# Usage: bash Raw.sh --build <path/to/arch_output>
# This command receives an arch_output file and runs the build pipeline:
# 1. Execute ./build (generates build_output.asm in caller dir)
# 2. Move build_output.asm to dev directory for tree/build.sh
# 3. Copy the input arch_output to the same dev directory level
# 4. Execute ./tree/build.sh
# 5. Move the final build_output.asm back to the caller directory (where arch_output is located)
tool_build() {
    # Get working directory from configuration
    local working_dir=$(get_tool_working_dir "build")

    # Check if arch_output argument was provided
    if [ $# -eq 0 ]; then
        echo -e "\033[0;31mError: arch_output file path required\033[0m" >&2
        echo -e "\033[1;33mUsage: bash Raw.sh --build <path/to/arch_output>\033[0m" >&2
        return 1
    fi

    local arch_output_argument="$1"

    # Resolve arch_output path relative to caller's directory
    local arch_output_path=""
    if [[ "$arch_output_argument" = /* ]]; then
        # Absolute path
        arch_output_path="$arch_output_argument"
    else
        # Relative path - resolve from caller's directory
        arch_output_path="$CALLER_DIR/$arch_output_argument"
    fi

    # Check if arch_output file exists
    if [ ! -f "$arch_output_path" ]; then
        echo -e "\033[0;31mError: arch_output file not found: $arch_output_path\033[0m" >&2
        return 1
    fi

    # Get the directory containing the arch_output file
    local arch_output_directory=$(dirname "$arch_output_path")

    echo -e "\033[0;34mBuild process started...\033[0m"
    echo -e "\033[0;37mInput arch_output: $arch_output_path\033[0m"
    echo -e "\033[0;37mOutput directory: $arch_output_directory\033[0m"
    echo ""

    # Step 1: Execute ./build (generates build_output.asm in caller directory)
    echo -e "\033[1;33mStep 1/4: Generating build_output.asm...\033[0m"
    execute_file "silent" "./build" "$working_dir"
    if [ $? -ne 0 ]; then
        echo -e "\033[0;31mError: ./build execution failed\033[0m" >&2
        return 1
    fi
    echo -e "\033[0;32m✓ build_output.asm generated in caller directory\033[0m"

    # build_output.asm should now be in CALLER_DIR since ./build ran with "caller" working dir
    local generated_build_asm="$CALLER_DIR/build_output.asm"

    # Check if the file was actually generated
    if [ ! -f "$generated_build_asm" ]; then
        echo -e "\033[0;31mError: build_output.asm was not generated in $CALLER_DIR\033[0m" >&2
        return 1
    fi

    # Step 2: Move build_output.asm to the correct dev directory (same level as tree/build.sh expects)
    echo -e "\033[1;33mStep 2/4: Moving build_output.asm to build directory...\033[0m"
    local dev_build_asm="$WORKING_DIRECTORY/build_output.asm"
    mv_file "$generated_build_asm" "$dev_build_asm"
    if [ $? -ne 0 ]; then
        echo -e "\033[0;31mError: Failed to move build_output.asm to $dev_build_asm\033[0m" >&2
        return 1
    fi
    echo -e "\033[0;32m✓ build_output.asm moved to $dev_build_asm\033[0m"

    # Step 3: Copy the received arch_output to the same directory level as build_output.asm
    echo -e "\033[1;33mStep 3/4: Copying arch_output to build directory...\033[0m"
    local dev_arch_output="$WORKING_DIRECTORY/arch_output"
    cp_file "$arch_output_path" "$dev_arch_output"
    if [ $? -ne 0 ]; then
        echo -e "\033[0;31mError: Failed to copy arch_output to $dev_arch_output\033[0m" >&2
        return 1
    fi
    echo -e "\033[0;32m✓ arch_output copied to $dev_arch_output\033[0m"

    # Step 4: Execute ./tree/build.sh (uses both build_output.asm and arch_output from the dev directory)
    echo -e "\033[1;33mStep 4/4: Running tree/build.sh...\033[0m"
    execute_file "log" "./tree/build.sh" "$working_dir"
    if [ $? -ne 0 ]; then
        echo -e "\033[0;31mError: tree/build.sh execution failed\033[0m" >&2
        return 1
    fi
    echo -e "\033[0;32m✓ tree/build.sh completed\033[0m"

    # Step 5: Move the final build_output.asm back to the caller's arch_output directory
    echo -e "\033[1;33mMoving final build_output.asm to: $arch_output_directory/\033[0m"
    local final_asm="$arch_output_directory/build_output.asm"
    mv_file "$dev_build_asm" "$final_asm"
    if [ $? -ne 0 ]; then
        echo -e "\033[0;31mError: Failed to move final build_output.asm to $final_asm\033[0m" >&2
        return 1
    fi
    echo -e "\033[0;32m✓ Final build_output.asm saved to: $final_asm\033[0m"

    # Clean up: remove the copied arch_output from dev directory
    rm_file "$dev_arch_output"

    echo ""
    echo -e "\033[0;32mBuild process completed successfully!\033[0m"

    return 0
}

# Function: Handle bin tool command
# Usage: bash Raw.sh --bin [options] <build_output.asm>
# Options:
#   -o <output_name>    Specify the output binary name (optional)
# Examples:
#   bash Raw.sh --bin build_output.asm
#   bash Raw.sh --bin -o test build_output.asm
#   bash Raw.sh --bin -o myprogram build_output.asm
tool_bin() {
    # Get working directory from configuration
    local working_dir=$(get_tool_working_dir "bin")

    # Check if arguments were provided
    if [ $# -eq 0 ]; then
        echo -e "\033[0;31mError: build_output.asm file path required\033[0m" >&2
        echo -e "\033[1;33mUsage: bash Raw.sh --bin [-o <output_name>] <build_output.asm>\033[0m" >&2
        echo -e "\033[1;33mExamples:\033[0m" >&2
        echo -e "\033[1;33m  bash Raw.sh --bin build_output.asm\033[0m" >&2
        echo -e "\033[1;33m  bash Raw.sh --bin -o test build_output.asm\033[0m" >&2
        return 1
    fi

    # Parse arguments: look for -o flag
    local output_name=""
    local asm_file=""

    while [ $# -gt 0 ]; do
        if [ "$1" = "-o" ]; then
            # Next argument is the output name
            if [ $# -lt 2 ]; then
                echo -e "\033[0;31mError: -o requires an output name\033[0m" >&2
                return 1
            fi
            output_name="$2"
            shift 2
        elif [[ "$1" != -* ]]; then
            # This is the asm file
            asm_file="$1"
            shift
        else
            echo -e "\033[0;31mError: Unknown option: $1\033[0m" >&2
            return 1
        fi
    done

    # Check if asm file was provided
    if [ -z "$asm_file" ]; then
        echo -e "\033[0;31mError: build_output.asm file path required\033[0m" >&2
        return 1
    fi

    # Resolve asm file path relative to caller's directory
    local asm_file_path=""
    if [[ "$asm_file" = /* ]]; then
        # Absolute path
        asm_file_path="$asm_file"
    else
        # Relative path - resolve from caller's directory
        asm_file_path="$CALLER_DIR/$asm_file"
    fi

    # Check if asm file exists
    if [ ! -f "$asm_file_path" ]; then
        echo -e "\033[0;31mError: build_output.asm file not found: $asm_file_path\033[0m" >&2
        return 1
    fi

    echo -e "\033[0;34mBinary generation started...\033[0m"
    echo -e "\033[0;37mInput ASM: $asm_file_path\033[0m"

    # Use the generate_binary function
    generate_binary "$asm_file_path" "$output_name"

    return $?
}

# ============================================
# ADD MORE TOOL COMMANDS BELOW
# ============================================
# Example of adding a new command:
#
# Function: Handle compile tool command
# Usage: bash Raw.sh --compile <source_file> <output_file>
# tool_compile() {
#     local working_dir=$(get_tool_working_dir "compile")
#     execute_file "silent" "compiler/compile.sh" "$working_dir" "$@"
# }
#
# Example of adding a command with variable arguments:
#
# Function: Handle process tool command
# Usage: bash Raw.sh --process <file> [options...]
# tool_process() {
#     local working_dir=$(get_tool_working_dir "process")
#     execute_file "log" "processor/main.sh" "$working_dir" "$@"
# }
#
# IMPORTANT: When adding new tools:
#   1. Add their working directory config in get_tool_working_dir() function above
#   2. Add tool function handler (tool_<name>) here
#   3. Optionally add to a group in TOOL GROUPS CONFIGURATION section
# ============================================

# Function: Route tool commands to appropriate handler
handle_tool_command() {
    local command="$1"
    shift
    local args="$@"

    # If no command provided, show all available commands
    if [ -z "$command" ]; then
        display_tool_list_with_groups
        return 0
    fi

    # Check if the tool exists
    if ! declare -f "tool_${command}" > /dev/null 2>&1; then
        echo -e "${RED}Error: Unknown tool command '$command'${NC}" >&2
        echo ""
        display_tool_list_with_groups
        return 1
    fi

    # Execute the tool with arguments
    "tool_${command}" $args
    return $?
}

# ============================================
# SEQUENCE PATTERNS (Commented Examples)
# ============================================

# Pattern 1: Execute a single file in normal mode
# execute_file "normal" "path/to/your/file.sh"

# Pattern 2: Execute a single file in silent mode
# execute_file "silent" "path/to/your/file.asm"

# Pattern 3: Execute a single file in log mode
# execute_file "log" "path/to/your/binary"

# Pattern 4: Execute multiple files in sequence with same mode
# execute_sequence "normal" "file1.sh" "file2.asm" "file3"

# Pattern 5: Mixed mode execution (using different modes for different files)
# execute_file "silent" "setup.sh"
# execute_file "normal" "main.asm"
# execute_file "log" "processor"

# Pattern 6: Execute with additional arguments
# execute_file "normal" "script.sh" "--verbose" "--output=result.txt"

# Pattern 7: Change execution source temporarily
# EXECUTION_SOURCE="source" execute_file "normal" "script.sh"
# EXECUTION_SOURCE="dev" execute_file "normal" "script.sh"

# Pattern 8: Use JS file path as argument to an executable
# execute_file "normal" "processor" "$JS_FILE_PATH" "$JS_ARGS"

# Pattern 9: Execute with specific working directory type
# execute_file "normal" "processor.sh" "caller" "$@"
# execute_file "normal" "processor.sh" "file" "$@"
# execute_file "normal" "processor.sh" "global" "$@"

# Pattern 10: Conditional execution based on JS file processing
# if process_js_file "config.js" "some-arg"; then
#     execute_sequence "normal" "success.sh"
# else
#     execute_sequence "normal" "failure.sh"
# fi

# ============================================
# MAIN FLOW
# ============================================

main_flow() {
    # Step 1: Check for tool mode FIRST (before special modes)
    if [ "$TOOL_MODE" = "true" ]; then
        acquire_working_directory
        if [ $? -ne 0 ]; then
            echo -e "${RED}Failed to acquire working directory${NC}" >&2
            exit 1
        fi
        handle_tool_command "$TOOL_COMMAND" $TOOL_ARGS
        exit $?
    fi

    # Step 2: Check for --tools or --stools/--stool special mode
    if [ "$SPECIAL_MODE" = "--tools" ]; then
        display_tool_list_with_groups
        exit 0
    elif [ "$SPECIAL_MODE" = "--stools" ]; then
        display_compact_tool_list
        exit 0
    fi

    # Step 3: Check for CLI mode
    if [ "$CLI_MODE" = "true" ]; then
        acquire_working_directory
        if [ $? -ne 0 ]; then
            echo -e "${RED}Failed to acquire working directory${NC}" >&2
            exit 1
        fi
        handle_cli
        exit $?
    fi

    # Step 4: Check for asm-only mode (--asm without JS file)
    if [ "$ASM_MODE" = "true" ] && [ "$ASM_ONLY_MODE" = "true" ]; then
        acquire_working_directory
        if [ $? -ne 0 ]; then
            echo -e "${RED}Failed to acquire working directory${NC}" >&2
            exit 1
        fi
        copy_asm_to_caller
        exit $?
    fi

    # Step 5: Check for special modes
    if [ "$SPECIAL_MODE" = "--reset" ]; then
        handle_reset
        exit $?
    elif [ "$SPECIAL_MODE" = "--test" ]; then
        handle_test "$@"
        exit $?
    fi

    # Step 6: Normal execution flow
    acquire_working_directory
    if [ $? -ne 0 ]; then
        echo -e "${RED}Failed to acquire working directory${NC}" >&2
        exit 1
    fi

    # FIX: Warmup on first run
    if [ "$RAWJS_FIRST_RUN" = "1" ]; then
        # Create a temporary warmup JS file
        local warmup_file="$CALLER_DIR/.rawjs_warmup.js"
        echo "run" > "$warmup_file"
        
        # Run the warmup silently
        process_js_file "$warmup_file" >/dev/null 2>&1
        if [ $? -eq 0 ]; then
            OUTPUT_JS="$SCRIPT_DIR/output.js"
            execute_file "silent" "./._/min/min" "$JS_FILE_PATH" >/dev/null 2>&1
            execute_file "silent" "./._/min/polish.sh" "$OUTPUT_JS" >/dev/null 2>&1
            execute_file "silent" "./build" >/dev/null 2>&1
            mv_file "build_output.asm" "$WORKING_DIRECTORY/build_output.asm" 2>/dev/null
            execute_file "silent" "./arch" "$OUTPUT_JS" >/dev/null 2>&1
            mv_file "arch_output" "$WORKING_DIRECTORY/arch_output" 2>/dev/null
            rm_file "$SCRIPT_DIR/output.js" 2>/dev/null
            execute_file "silent" "./tree/build.sh" >/dev/null 2>&1
            execute_file "silent" "./build_output.asm" >/dev/null 2>&1
        fi
        
        # Clean up warmup file
        rm_file "$warmup_file"
        
        # Reset first run flag
        export RAWJS_FIRST_RUN=0
    fi

    # Step 7: Process the JS file if provided
    if [ -n "$JS_FILE" ]; then
        process_js_file "$JS_FILE" $JS_ARGS
        if [ $? -ne 0 ]; then
            exit 1
        fi

        # ============================================
        # NOW EXECUTE YOUR FILES USING THE JS PATH
        # ============================================

        # Start execution timer if in log mode
        if [ "$FORCE_LOG_MODE" = "true" ]; then
            start_timer
        fi

        OUTPUT_JS="$SCRIPT_DIR/output.js"
        ARCH_OUTPUT="$SCRIPT_DIR/arch_output"

        # Execute the processing pipeline (silent steps)
        execute_file "silent" "./._/min/min" "$JS_FILE_PATH"
        execute_file "silent" "./._/min/polish.sh" "$OUTPUT_JS"
        execute_file "silent" "./build"
        mv_file "build_output.asm" "$WORKING_DIRECTORY/build_output.asm"
        execute_file "silent" "./arch" "$OUTPUT_JS"
        mv_file "arch_output" "$WORKING_DIRECTORY/arch_output"
        rm_file "$SCRIPT_DIR/output.js"

        # Execute tree/build.sh with --verbose flag if verbose mode is active
        if [ "$VERBOSE_MODE" = "true" ]; then
            execute_file "silent" "./tree/build.sh" "--verbose"
        else
            execute_file "silent" "./tree/build.sh"
        fi

        # Check if binary output mode is active (--bin flag was used)
        if [ "$BIN_OUTPUT_MODE" = "true" ]; then
            local asm_file="$WORKING_DIRECTORY/build_output.asm"
            generate_binary "$asm_file" "$BIN_OUTPUT_NAME"
        elif [ "$ASM_MODE" = "true" ]; then
            copy_asm_to_caller
        else
            execute_file "log" "./build_output.asm"
        fi

        # Display execution time if in log mode
        if [ "$FORCE_LOG_MODE" = "true" ]; then
            stop_timer
        fi

    else
        # NEW: Check if dev mode is enabled and no JS file provided
        if [ "$CONFIG_DEV_MODE" = "true" ]; then
            # Dev mode enabled - launch CLI instead of showing usage
            handle_cli
            exit $?
        else
            show_usage
            exit 1
        fi
    fi
}

# Execute main flow with all arguments
main_flow "$@"