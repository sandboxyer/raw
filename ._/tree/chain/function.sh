#!/bin/bash
# function.sh – Converts current build_output.asm into a named function
# Usage: ./function.sh [--call]
# Reads function definition from arch_output file.
# Appends the function to the parent build_output.asm

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Local build_output.asm (function body)
LOCAL_FILE="./build_output.asm"
# Parent build_output.asm (where function will be appended)
PARENT_FILE="../../build_output.asm"
INPUT_FILE="arch_output"
RUN_OUTPUT_FILE="run_output"
RAW_SCRIPT="../../../Raw.sh"
WITH_CALL=0

# Parse command line arguments
for arg in "$@"; do
    case "$arg" in
        --call) WITH_CALL=1 ;;
        *) echo "Unknown option: $arg"; exit 1 ;;
    esac
done

# Check input files
if [ ! -f "$INPUT_FILE" ]; then
    echo "Error: $INPUT_FILE not found"
    exit 1
fi

if [ ! -f "$PARENT_FILE" ]; then
    echo "Error: $PARENT_FILE not found"
    exit 1
fi

if [ ! -f "$RAW_SCRIPT" ]; then
    echo "Error: $RAW_SCRIPT not found"
    exit 1
fi

# ----------------------------------------------------------------------
# STEP 1: Create run_output by removing main chain tags and function definition
# ----------------------------------------------------------------------
echo "Step 1: Creating run_output from arch_output..."

# Remove the outermost <chain-start> and <chain-end> tags
# Also remove the function definition line
# Keep inner content intact (including nested chains)
awk '
BEGIN { chain_depth = 0; skip_line = 0 }
{
    line = $0
    
    # Check for chain-start
    if (line ~ /<chain-start>/) {
        if (chain_depth == 0) {
            # Remove outer chain-start
            line = ""
            skip_line = 1
        }
        chain_depth++
    }
    
    # Check for chain-end
    if (line ~ /<chain-end>/) {
        chain_depth--
        if (chain_depth == 0) {
            # Remove outer chain-end
            line = ""
            skip_line = 1
        }
    }
    
    # Remove function definition line
    if (line ~ /^[[:space:]]*function[[:space:]]*[^(]*\([^)]*\)/) {
        line = ""
        skip_line = 1
    }
    
    # Print line if not skipped
    if (!skip_line) {
        print line
    }
    
    # Reset skip flag
    skip_line = 0
}
' "$INPUT_FILE" > "$RUN_OUTPUT_FILE"

# Verify run_output was created and is not empty
if [ ! -s "$RUN_OUTPUT_FILE" ]; then
    echo "Error: Failed to create run_output"
    exit 1
fi

echo "✓ run_output created successfully"
echo "Content of run_output:"
cat "$RUN_OUTPUT_FILE"
echo ""

# ----------------------------------------------------------------------
# STEP 2: Run Raw.sh to generate function body
# ----------------------------------------------------------------------
echo "Step 2: Running Raw.sh to generate function body..."

# Resolve the absolute path to Raw.sh
RAW_SCRIPT_ABS="$(cd "$(dirname "$RAW_SCRIPT")" && pwd)/$(basename "$RAW_SCRIPT")"

# Check if we're in a private copy (look for .rawjs_private marker)
if [ -f "$RAW_SCRIPT_ABS/.rawjs_private" ] || [ -n "$RAWJS_PRIVATE_MODE" ]; then
    # We're in a private copy - need to find the original Raw.sh
    # The original is at the root of the rawjs-runtime directory
    ORIGINAL_RAW=""
    
    # Walk up the directory tree looking for the original Raw.sh
    CURRENT_DIR="$RAW_SCRIPT_ABS"
    while [ "$CURRENT_DIR" != "/" ]; do
        CURRENT_DIR=$(dirname "$CURRENT_DIR")
        if [ -f "$CURRENT_DIR/Raw.sh" ] && [ ! -f "$CURRENT_DIR/.rawjs_private" ]; then
            ORIGINAL_RAW="$CURRENT_DIR/Raw.sh"
            break
        fi
    done
    
    if [ -n "$ORIGINAL_RAW" ]; then
        RAW_SCRIPT_ABS="$ORIGINAL_RAW"
    fi
fi

# Run Raw.sh with the run_output file
# The --tmp flag must come FIRST before any other flags
# Use env -i to clear RAWJS_PRIVATE_MODE if it's set
if [ -n "$RAWJS_PRIVATE_MODE" ]; then
    env -u RAWJS_PRIVATE_MODE -u RAWJS_PRIVATE_ROOT bash "$RAW_SCRIPT_ABS" --tmp --asm "$RUN_OUTPUT_FILE"
else
    bash "$RAW_SCRIPT_ABS" --tmp --asm "$RUN_OUTPUT_FILE"
fi

# Wait for build_output.asm to be created
MAX_WAIT=30
WAIT_COUNT=0
while [ ! -f "$LOCAL_FILE" ]; do
    if [ $WAIT_COUNT -ge $MAX_WAIT ]; then
        echo "Error: Timeout waiting for build_output.asm to be created"
        exit 1
    fi
    echo "Waiting for build_output.asm to be created... ($WAIT_COUNT/$MAX_WAIT)"
    sleep 1
    WAIT_COUNT=$((WAIT_COUNT + 1))
done

# Verify build_output.asm is not empty
if [ ! -s "$LOCAL_FILE" ]; then
    echo "Error: build_output.asm is empty"
    exit 1
fi

echo "✓ Function body generated successfully"
echo ""

# ----------------------------------------------------------------------
# STEP 3: Parse function definition from arch_output
# ----------------------------------------------------------------------
echo "Step 3: Parsing function definition..."

# Read arch_output and extract function definition line
FUNC_LINE=$(grep -o 'function[[:space:]]*[^(]*([^)]*)' "$INPUT_FILE" | head -1)
if [ -z "$FUNC_LINE" ]; then
    echo "Error: No function definition found in $INPUT_FILE"
    exit 1
fi

# Extract function name
FUNC_NAME=$(echo "$FUNC_LINE" | sed 's/function[[:space:]]*\([^(]*\)(.*/\1/' | tr -d '[:space:]')
if [ -z "$FUNC_NAME" ]; then
    echo "Error: Could not parse function name"
    exit 1
fi

# Extract parameter list
PARAMS_STR=$(echo "$FUNC_LINE" | sed 's/.*(\(.*\)).*/\1/')
IFS=',' read -ra PARAMS <<< "$PARAMS_STR"

# Arrays for parameter info
declare -a PNAMES
declare -a PDEFAULTS
declare -a PTYPES   # "none", "string", "number", "variable", "float"

# Parse each parameter
for p in "${PARAMS[@]}"; do
    # Trim whitespace
    p=$(echo "$p" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    if [ -z "$p" ]; then continue; fi
    
    # Split on '='
    if [[ "$p" == *=* ]]; then
        name="${p%%=*}"
        default="${p#*=}"
        # Trim name
        name=$(echo "$name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        default=$(echo "$default" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        # Determine type of default
        if [[ "$default" =~ ^\".*\"$ ]]; then
            dtype="string"
            # Remove surrounding quotes
            default="${default:1:${#default}-2}"
        elif [[ "$default" =~ ^-?[0-9]+$ ]]; then
            dtype="number"
        elif [[ "$default" =~ ^-?[0-9]*\.[0-9]+$ ]]; then
            dtype="float"
        else
            # Assume it's a variable reference
            dtype="variable"
        fi
    else
        name="$p"
        default=""
        dtype="none"
    fi
    
    PNAMES+=("$name")
    PDEFAULTS+=("$default")
    PTYPES+=("$dtype")
done

echo "✓ Function name: $FUNC_NAME"
echo "✓ Parameters: ${#PNAMES[@]}"
echo ""

# ----------------------------------------------------------------------
# STEP 4: Generate parameter data and call code
# ----------------------------------------------------------------------
echo "Step 4: Generating parameter data..."

# Generate parameter data declarations for .data section
PARAM_DATA=""
for i in "${!PNAMES[@]}"; do
    name="${PNAMES[$i]}"
    dtype="${PTYPES[$i]}"
    PARAM_DATA+="    ; Parameter: $name"$'\n'
    PARAM_DATA+="    ${name} dq 0"$'\n'
    PARAM_DATA+="    ${name}_type dq TYPE_UNDEFINED"$'\n'
    if [ "$dtype" == "string" ] && [ -n "${PDEFAULTS[$i]}" ]; then
        # Add a default string constant
        strval="${PDEFAULTS[$i]}"
        # Escape single quotes if any
        strval_esc=$(echo "$strval" | sed "s/'/''/g")
        PARAM_DATA+="    ${FUNC_NAME}_${name}_default db '${strval_esc}', 0"$'\n'
    elif [ "$dtype" == "float" ] && [ -n "${PDEFAULTS[$i]}" ]; then
        # Add a default float string constant
        fval="${PDEFAULTS[$i]}"
        PARAM_DATA+="    ${FUNC_NAME}_${name}_default db '${fval}', 0"$'\n'
    fi
done

# Generate call setup code (if --call)
CALL_CODE=""
if [ $WITH_CALL -eq 1 ]; then
    for i in "${!PNAMES[@]}"; do
        name="${PNAMES[$i]}"
        dtype="${PTYPES[$i]}"
        default="${PDEFAULTS[$i]}"
        case "$dtype" in
            none)
                CALL_CODE+="    mov qword [${name}], 0"$'\n'
                CALL_CODE+="    mov qword [${name}_type], TYPE_UNDEFINED"$'\n'
                ;;
            string|float)
                CALL_CODE+="    mov rax, ${FUNC_NAME}_${name}_default"$'\n'
                CALL_CODE+="    mov [${name}], rax"$'\n'
                if [ "$dtype" == "string" ]; then
                    CALL_CODE+="    mov qword [${name}_type], TYPE_STRING"$'\n'
                else
                    CALL_CODE+="    mov qword [${name}_type], TYPE_FLOAT"$'\n'
                fi
                ;;
            number)
                CALL_CODE+="    mov qword [${name}], ${default}"$'\n'
                CALL_CODE+="    mov qword [${name}_type], TYPE_NUMBER"$'\n'
                ;;
            variable)
                # Copy from referenced variable
                CALL_CODE+="    mov rax, [${default}]"$'\n'
                CALL_CODE+="    mov [${name}], rax"$'\n'
                CALL_CODE+="    mov rax, [${default}_type]"$'\n'
                CALL_CODE+="    mov [${name}_type], rax"$'\n'
                ;;
        esac
    done
    CALL_CODE+="    call ${FUNC_NAME}"$'\n'
fi

# ----------------------------------------------------------------------
# STEP 5: Extract data and function body from generated build_output.asm
# ----------------------------------------------------------------------
echo "Step 5: Extracting function body..."

# Extract data section from local build_output.asm (variables specific to this function)
# But ONLY extract NEW data that was added, not the template data
LOCAL_DATA=""
IN_DATA=0

while IFS= read -r line; do
    if [[ "$line" == "section .data" ]]; then
        IN_DATA=1
        continue
    elif [[ "$line" == "section .bss" ]]; then
        IN_DATA=0
        break
    fi
    
    if [ $IN_DATA -eq 1 ]; then
        # Skip template lines using grep
        if echo "$line" | grep -qE '^[[:space:]]*(;|COLOR_|TYPE_|true_str|false_str|null_str|undefined_str|hex_prefix|float_scale|float_ten|space|newline|$)'; then
            continue
        fi
        
        # Keep only actual data (like log_* strings, variables, etc.)
        LOCAL_DATA+="$line"$'\n'
    fi
done < "$LOCAL_FILE"

# Extract the function body - only the actual code, not the template
FUNCTION_BODY=""
IN_FUNCTION=0
CAPTURE=0

while IFS= read -r line; do
    # Detect the start of _start
    if [[ "$line" == "_start:" ]]; then
        IN_FUNCTION=1
        CAPTURE=1
        continue
    fi
    
    # If we're in the function and hit the exit syscall, stop capturing
    if [ $IN_FUNCTION -eq 1 ] && echo "$line" | grep -qE '^[[:space:]]*mov[[:space:]]+rax,[[:space:]]*60$'; then
        CAPTURE=0
        IN_FUNCTION=0
        continue
    fi
    
    # Skip the exit syscall lines
    if [ $IN_FUNCTION -eq 0 ] && echo "$line" | grep -qE '^[[:space:]]*(xor|syscall)'; then
        continue
    fi
    
    # Capture the function body
    if [ $CAPTURE -eq 1 ]; then
        # Skip template comments using grep
        if echo "$line" | grep -qE '^[[:space:]]*;.*(Your code here|Example usage|mov rax, 42|mov rdx, TYPE_NUMBER|call print|mov rax, newline|mov rdx, TYPE_STRING)'; then
            continue
        fi
        
        FUNCTION_BODY+="$line"$'\n'
    fi
done < "$LOCAL_FILE"

# Clean up the function body - remove leading/trailing empty lines
FUNCTION_BODY=$(echo "$FUNCTION_BODY" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^$/N;/^\n$/D')

# Prepare the function code to append to parent
FUNCTION_CODE="${FUNC_NAME}:"$'\n'
FUNCTION_CODE+="${FUNCTION_BODY}"$'\n'
FUNCTION_CODE+="    ret"$'\n'  # Ensure there's always a ret at the end

# Combine parameter data and local data for insertion
ALL_DATA="${PARAM_DATA}${LOCAL_DATA}"

echo "✓ Function body extracted"
echo ""

# ----------------------------------------------------------------------
# STEP 6: Append function to parent build_output.asm
# ----------------------------------------------------------------------
echo "Step 6: Appending function to parent build_output.asm..."

# Create temporary file for parent build_output.asm
TEMP_FILE=$(mktemp)

# Process parent build_output.asm
awk -v funcname="$FUNC_NAME" -v all_data="$ALL_DATA" -v function_code="$FUNCTION_CODE" -v call_code="$CALL_CODE" -v with_call="$WITH_CALL" '
BEGIN {
    inserted_data = 0
    inserted_function = 0
    skip_old_start = 0
}
# Insert all data before section .bss
/^section \.bss/ && !inserted_data {
    if (all_data != "") {
        print all_data
    }
    inserted_data = 1
}
# Insert function code just before _start
/^_start:/ && !inserted_function {
    print function_code
    inserted_function = 1
    # If we have a call, skip the old _start body
    if (with_call) {
        skip_old_start = 1
        # Print new _start with call code
        print ""
        print "_start:"
        print call_code
        print "    mov rax, 60"
        print "    xor rdi, rdi"
        print "    syscall"
        next
    }
}
# Skip old _start body if we are replacing it
skip_old_start && /^[[:space:]]*mov[[:space:]]+rax,[[:space:]]*60$/ {
    # Skip until we find the next label or section
    skip_old_start = 2
    next
}
skip_old_start == 2 && /^[[:space:]]*syscall/ {
    skip_old_start = 0
    next
}
skip_old_start {
    next
}
{ print }
END {
    # If we never found _start, append everything at the end
    if (!inserted_function) {
        print function_code
        if (with_call) {
            print ""
            print "_start:"
            print call_code
            print "    mov rax, 60"
            print "    xor rdi, rdi"
            print "    syscall"
        }
    }
}
' "$PARENT_FILE" > "$TEMP_FILE"

mv "$TEMP_FILE" "$PARENT_FILE"

echo "✓ Function '$FUNC_NAME' successfully created"
if [ $WITH_CALL -eq 1 ]; then
    echo "✓ Added test call in _start"
fi
echo ""
echo "All steps completed successfully!"
exit 0
