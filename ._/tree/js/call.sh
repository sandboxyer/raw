#!/bin/bash

# call.sh - Handles generic function calls and appends them to build_output.asm
# This script is called when no specific handler exists for a function

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

OUTPUT_FILE="../../build_output.asm"
INPUT_FILE="call_input"

if [ ! -f "$INPUT_FILE" ]; then
    echo "Error: $INPUT_FILE not found"
    exit 1
fi

# Read and clean the call statement
CALL_STMT=$(cat "$INPUT_FILE" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

# Remove ALL trailing semicolons and any extra characters after them
CALL_STMT=$(echo "$CALL_STMT" | sed 's/;.*$//')

# Remove any trailing ')' that might be duplicated
CALL_STMT=$(echo "$CALL_STMT" | sed 's/))$/)/')

# Debug output to stderr
echo "Debug - Cleaned call statement: '$CALL_STMT'" >&2

# Extract function name and arguments
if [[ "$CALL_STMT" =~ ^([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*\((.*)\)$ ]]; then
    FUNC_NAME="${BASH_REMATCH[1]}"
    ARGS="${BASH_REMATCH[2]}"
else
    echo "Error: Invalid function call format: $CALL_STMT"
    exit 1
fi

echo "Debug - Function: $FUNC_NAME, Args: '$ARGS'" >&2

# Generate unique ID for this call
CALL_ID="call_$(date +%s%N 2>/dev/null || date +%s)_$(od -An -N4 -tu4 /dev/urandom 2>/dev/null | tr -d ' ' || echo $$)"

# Parse arguments (simple split by comma, respecting quotes)
parse_args() {
    local args=()
    local current=""
    local in_quote=false
    local quote_char=""
    local i=0
    
    # If ARGS is empty, return empty array
    if [[ -z "${ARGS// }" ]]; then
        return
    fi
    
    while [ $i -lt ${#ARGS} ]; do
        local c="${ARGS:$i:1}"
        
        if [[ "$c" =~ [\"\'] ]] && [ "$in_quote" = false ]; then
            in_quote=true
            quote_char="$c"
        elif [ "$c" = "$quote_char" ] && [ "$in_quote" = true ]; then
            in_quote=false
            quote_char=""
        fi
        
        if [ "$c" = ',' ] && [ "$in_quote" = false ]; then
            args+=("$(echo "$current" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')")
            current=""
        else
            current="${current}${c}"
        fi
        i=$((i+1))
    done
    
    [ -n "$current" ] && args+=("$(echo "$current" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')")
    
    printf '%s\n' "${args[@]}"
}

# Generate string constants for string literals
generate_strings() {
    local args=("$@")
    local strings=""
    local idx=0
    
    for arg in "${args[@]}"; do
        if [[ "$arg" =~ ^\".*\"$ ]] || [[ "$arg" =~ ^\'.*\'$ ]]; then
            local stripped="${arg:1:${#arg}-2}"
            strings="${strings}    ${CALL_ID}_str${idx} db '${stripped}', 0"$'\n'
        fi
        idx=$((idx+1))
    done
    
    echo "$strings"
}

# Generate the function call assembly
gen_call_code() {
    local args=("$@")
    local call_code=""
    
    call_code="${call_code}    ; Function call: ${FUNC_NAME}(${ARGS})"$'\n'
    
    # Push arguments in reverse order (C calling convention)
    if [ ${#args[@]} -gt 0 ]; then
        for ((i=${#args[@]}-1; i>=0; i--)); do
            local arg="${args[$i]}"
            # Handle string literals
            if [[ "$arg" =~ ^\".*\"$ ]] || [[ "$arg" =~ ^\'.*\'$ ]]; then
                call_code="${call_code}    mov rax, ${CALL_ID}_str${i}"$'\n'
                call_code="${call_code}    push rax"$'\n'
            # Handle numeric literals
            elif [[ "$arg" =~ ^-?[0-9]+$ ]]; then
                call_code="${call_code}    mov rax, $arg"$'\n'
                call_code="${call_code}    push rax"$'\n'
            # Handle variables (assume they exist)
            else
                call_code="${call_code}    mov rax, [${arg}]"$'\n'
                call_code="${call_code}    push rax"$'\n'
            fi
        done
    fi
    
    call_code="${call_code}    call ${FUNC_NAME}"$'\n'
    
    # Clean up stack if arguments were pushed
    if [ ${#args[@]} -gt 0 ]; then
        call_code="${call_code}    add rsp, $((8 * ${#args[@]}))"$'\n'
    fi
    
    echo "$call_code"
}

# Main execution
mapfile -t ARGS_ARRAY < <(parse_args)

STRING_CONSTANTS=$(generate_strings "${ARGS_ARRAY[@]}")
CALL_CODE=$(gen_call_code "${ARGS_ARRAY[@]}")

# Check if output file exists
if [ ! -f "$OUTPUT_FILE" ]; then
    echo "Error: $OUTPUT_FILE not found"
    exit 1
fi

# Insert into file - before the "mov rax, 60" in _start section
TEMP_FILE=$(mktemp)
IN_DATA=0
IN_START=0
DATA_DONE=0
CODE_DONE=0

while IFS= read -r line; do
    # Track which section we're in
    if [[ "$line" == "section .data" ]]; then
        IN_DATA=1
    elif [[ "$line" == section* ]] && [ "$IN_DATA" -eq 1 ]; then
        if [ "$DATA_DONE" -eq 0 ] && [ -n "$STRING_CONSTANTS" ]; then
            echo "$STRING_CONSTANTS" >> "$TEMP_FILE"
            DATA_DONE=1
        fi
        IN_DATA=0
    fi
    
    # Track when we enter _start
    if [[ "$line" == "_start:" ]]; then
        IN_START=1
    fi
    
    # Only insert ONCE - before the FIRST mov rax, 60 AFTER _start
    if [ "$IN_START" -eq 1 ] && [ "$CODE_DONE" -eq 0 ] && \
       [[ "$line" =~ ^[[:space:]]*mov[[:space:]]+rax,[[:space:]]*60$ ]]; then
        echo "$CALL_CODE" >> "$TEMP_FILE"
        CODE_DONE=1
    fi
    
    echo "$line" >> "$TEMP_FILE"
done < "$OUTPUT_FILE"

# Handle edge cases
if [ "$IN_DATA" -eq 1 ] && [ "$DATA_DONE" -eq 0 ] && [ -n "$STRING_CONSTANTS" ]; then
    echo "$STRING_CONSTANTS" >> "$TEMP_FILE"
fi

if [ "$CODE_DONE" -eq 0 ] && [ -n "$CALL_CODE" ]; then
    echo "$CALL_CODE" >> "$TEMP_FILE"
fi

mv "$TEMP_FILE" "$OUTPUT_FILE"

echo "Successfully appended function call: ${FUNC_NAME}(${ARGS})"
exit 0
