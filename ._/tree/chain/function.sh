#!/bin/bash
# function.sh – Converts current build_output.asm into a named function
# Usage: ./function.sh [--call]
# Reads function definition from arch_output file.
# Appends the function to the parent build_output.asm
# Enhanced: Proper variable scoping, string handling, and metadata generation
# FIX: Generate missing data declarations for local variables

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
declare -a PTYPES

# Parse each parameter
for p in "${PARAMS[@]}"; do
    # Trim whitespace
    p=$(echo "$p" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    if [ -z "$p" ]; then continue; fi
   
    # Split on '='
    if [[ "$p" == *=* ]]; then
        name="${p%%=*}"
        default="${p#*=}"
        name=$(echo "$name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        default=$(echo "$default" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
       
        # Determine type of default
        if [[ "$default" =~ ^\".*\"$ ]]; then
            dtype="string"
            default="${default:1:${#default}-2}"
        elif [[ "$default" =~ ^-?[0-9]+$ ]]; then
            dtype="number"
        elif [[ "$default" =~ ^-?[0-9]*\.[0-9]+$ ]]; then
            dtype="float"
        else
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
for i in "${!PNAMES[@]}"; do
    echo "  - ${PNAMES[$i]} (default: '${PDEFAULTS[$i]}', type: ${PTYPES[$i]})"
done
echo ""

# ----------------------------------------------------------------------
# STEP 3.5: Write function metadata for call generation
# ----------------------------------------------------------------------
echo "Step 3.5: Writing function metadata..."

META_DIR="../function_meta"
mkdir -p "$META_DIR"

META_FILE="$META_DIR/${FUNC_NAME}.meta"

{
    echo "function_name=$FUNC_NAME"
    for i in "${!PNAMES[@]}"; do
        echo "param=${PNAMES[$i]}|${PDEFAULTS[$i]}|${PTYPES[$i]}"
    done
} > "$META_FILE"

echo "✓ Metadata written to $META_FILE"
echo ""

# ----------------------------------------------------------------------
# STEP 4: Generate parameter data declarations
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
        strval="${PDEFAULTS[$i]}"
        strval_esc=$(echo "$strval" | sed "s/'/''/g")
        PARAM_DATA+="    ${FUNC_NAME}_${name}_default db '${strval_esc}', 0"$'\n'
    elif [ "$dtype" == "float" ] && [ -n "${PDEFAULTS[$i]}" ]; then
        fval="${PDEFAULTS[$i]}"
        PARAM_DATA+="    ${FUNC_NAME}_${name}_default db '${fval}', 0"$'\n'
    fi
done

# ----------------------------------------------------------------------
# STEP 5: Extract data and function body from generated build_output.asm
# ----------------------------------------------------------------------
echo "Step 5: Extracting function body..."

# Extract data section from local build_output.asm
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
        # Skip template lines but KEEP variable declarations
        if echo "$line" | grep -qE '^[[:space:]]*(;|COLOR_|TYPE_|true_str|false_str|null_str|undefined_str|hex_prefix|float_scale|float_ten|space|newline|$)'; then
            continue
        fi
       
        # Keep only actual data lines (including variable declarations)
        LOCAL_DATA+="$line"$'\n'
    fi
done < "$LOCAL_FILE"

# Extract the function body
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
        # Skip template comments but keep everything else
        if echo "$line" | grep -qE '^[[:space:]]*;.*(Your code here|Example usage|mov rax, 42|mov rdx, TYPE_NUMBER|call print|mov rax, newline|mov rdx, TYPE_STRING)'; then
            continue
        fi
       
        FUNCTION_BODY+="$line"$'\n'
    fi
done < "$LOCAL_FILE"

# Clean up function body (remove leading/trailing whitespace but keep newlines)
FUNCTION_BODY=$(echo "$FUNCTION_BODY" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

echo "✓ Function body extracted"
echo ""

# ----------------------------------------------------------------------
# STEP 5.4: Generate missing data declarations and copy code
# ----------------------------------------------------------------------
echo "Step 5.4: Generating data declarations and copy code for local variables..."

# Generate data declarations and copy code for variable-to-variable assignments
COPY_CODE=""
LOCAL_VAR_DATA=""

while IFS= read -r line; do
    # Look for lines like: <js-start>    var eita=num1;    <js-end>
    if [[ "$line" =~ \<js-start\>[[:space:]]*(var|let|const)[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*=[[:space:]]*([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*\;?[[:space:]]*\<js-end\> ]]; then
        dest="${BASH_REMATCH[2]}"
        src="${BASH_REMATCH[3]}"
        
        # Add data declaration for destination variable
        LOCAL_VAR_DATA+="    ; Local variable: ${dest}"$'\n'
        LOCAL_VAR_DATA+="    ${dest}_defined_flag db 1"$'\n'
        LOCAL_VAR_DATA+="    ${dest} dq 0"$'\n'
        LOCAL_VAR_DATA+="    ${dest}_float_val dq 0"$'\n'
        LOCAL_VAR_DATA+="    ${dest}_str times 32 db 0"$'\n'
        LOCAL_VAR_DATA+="    ${dest}_type dq TYPE_NUMBER"$'\n'
        
        # Add copy code
        if [[ "$dest" != "$src" ]]; then
            COPY_CODE+="    ; Copy variable ${src} to ${dest}"$'\n'
            COPY_CODE+="    mov rax, [${src}]"$'\n'
            COPY_CODE+="    mov [${dest}], rax"$'\n'
            COPY_CODE+="    mov rax, [${src}_type]"$'\n'
            COPY_CODE+="    mov [${dest}_type], rax"$'\n'
            COPY_CODE+="    mov byte [${dest}_defined_flag], 1"$'\n'
        fi
    fi
done < "$RUN_OUTPUT_FILE"

# Add generated local variable data to LOCAL_DATA
if [ -n "$LOCAL_VAR_DATA" ]; then
    if [ -n "$LOCAL_DATA" ]; then
        LOCAL_DATA+=$'\n'
    fi
    LOCAL_DATA+="$LOCAL_VAR_DATA"
    echo "✓ Generated data declarations for local variables"
fi

if [ -n "$COPY_CODE" ]; then
    # Prepend the copy code to the function body
    FUNCTION_BODY="${COPY_CODE}"$'\n'"${FUNCTION_BODY}"
    echo "✓ Added copy code for variable assignments"
else
    echo "✓ No simple variable copy assignments detected"
fi
echo ""

# ----------------------------------------------------------------------
# STEP 5.5: Apply variable scoping (prefix ONLY locally-declared variables)
# ----------------------------------------------------------------------
echo "Step 5.5: Applying variable scoping..."

# Build list of LOCAL variables
declare -A RENAME_MAP

# Add parameter names (they are local to the function)
for pname in "${PNAMES[@]}"; do
    if [ -n "$pname" ]; then
        RENAME_MAP["$pname"]=1
    fi
done

# Parse the run_output to find variables declared INSIDE the function
while IFS= read -r line; do
    if [[ "$line" =~ (var|let|const)[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*) ]]; then
        var_name="${BASH_REMATCH[2]}"
        RENAME_MAP["$var_name"]=1
    fi
done < "$RUN_OUTPUT_FILE"

# Build sorted list of identifiers
mapfile -t idents < <(printf "%s\n" "${!RENAME_MAP[@]}" | awk '{ print length, $0 }' | sort -rn | cut -d' ' -f2-)

# Function to apply renames
apply_renames() {
    local text="$1"
    local result="$text"
   
    for orig in "${idents[@]}"; do
        if [ -z "$orig" ]; then
            continue
        fi
       
        local new="${FUNC_NAME}_${orig}"
       
        result=$(echo "$result" | sed -E "
            s/\[${orig}\]/[${new}]/g
            s/\b${orig}_type\b/${new}_type/g
            s/\b${orig}_defined_flag\b/${new}_defined_flag/g
            s/\b${orig}_float_val\b/${new}_float_val/g
            s/\b${orig}_str\b/${new}_str/g
            s/\b${orig}\b/${new}/g
        ")
    done
   
    echo "$result"
}

# Apply renames to all components
if [ ${#idents[@]} -gt 0 ]; then
    PARAM_DATA=$(apply_renames "$PARAM_DATA")
    LOCAL_DATA=$(apply_renames "$LOCAL_DATA")
    FUNCTION_BODY=$(apply_renames "$FUNCTION_BODY")
   
    echo "✓ Renamed ${#idents[@]} local identifiers with prefix '${FUNC_NAME}_'"
else
    echo "✓ No local identifiers to rename"
fi
echo ""

# Prepare the function code to append to parent
FUNCTION_CODE="${FUNC_NAME}:"$'\n'
FUNCTION_CODE+="${FUNCTION_BODY}"$'\n'
FUNCTION_CODE+="    ret"$'\n'

# Combine parameter data and local data for insertion
ALL_DATA=""
if [ -n "$PARAM_DATA" ]; then
    ALL_DATA+="$PARAM_DATA"
fi
if [ -n "$LOCAL_DATA" ]; then
    if [ -n "$ALL_DATA" ]; then
        ALL_DATA+=$'\n'
    fi
    ALL_DATA+="$LOCAL_DATA"
fi

echo "✓ Function body with scoped variables prepared"
echo ""

# ----------------------------------------------------------------------
# STEP 6: Append function to parent build_output.asm
# ----------------------------------------------------------------------
echo "Step 6: Appending function to parent build_output.asm..."

# Create temporary file for parent build_output.asm
TEMP_FILE=$(mktemp)

# Process parent build_output.asm
awk -v all_data="$ALL_DATA" -v function_code="$FUNCTION_CODE" -v with_call="$WITH_CALL" '
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
    if (with_call) {
        skip_old_start = 1
        print ""
        print "_start:"
        print "    mov rax, 60"
        print "    xor rdi, rdi"
        print "    syscall"
        next
    }
}
skip_old_start && /^[[:space:]]*mov[[:space:]]+rax,[[:space:]]*60$/ {
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
    if (!inserted_function) {
        print function_code
        if (with_call) {
            print ""
            print "_start:"
            print "    mov rax, 60"
            print "    xor rdi, rdi"
            print "    syscall"
        }
    }
}
' "$PARENT_FILE" > "$TEMP_FILE"

mv "$TEMP_FILE" "$PARENT_FILE"

echo "✓ Function '$FUNC_NAME' successfully created"
echo ""
echo "All steps completed successfully!"
exit 0
