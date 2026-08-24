#!/bin/bash
# func.sh – Converts current build_output.asm into a named function
# Usage: ./func.sh [--call]
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

if [ ! -f "$LOCAL_FILE" ]; then
    echo "Error: $LOCAL_FILE not found"
    exit 1
fi

if [ ! -f "$PARENT_FILE" ]; then
    echo "Error: $PARENT_FILE not found"
    exit 1
fi

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

# Extract data section from local build_output.asm (variables specific to this function)
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
        # Skip common utility strings and constants that are already in parent
        if [[ "$line" =~ ^[[:space:]]*(COLOR_|TYPE_|true_str|false_str|null_str|undefined_str|hex_prefix|float_scale|float_ten|space|newline) ]]; then
            continue
        fi
        # Keep function-specific data (like log strings)
        LOCAL_DATA+="$line"$'\n'
    fi
done < "$LOCAL_FILE"

# Extract the function body from local build_output.asm
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
    if [ $IN_FUNCTION -eq 1 ] && [[ "$line" =~ ^[[:space:]]*mov[[:space:]]+rax,[[:space:]]*60$ ]]; then
        # Add ret before the exit
        FUNCTION_BODY+="    ret"$'\n'
        CAPTURE=0
        IN_FUNCTION=0
        continue
    fi
    
    # Skip the exit syscall lines
    if [ $IN_FUNCTION -eq 0 ] && [[ "$line" =~ ^[[:space:]]*(xor|syscall) ]]; then
        continue
    fi
    
    # Capture the function body
    if [ $CAPTURE -eq 1 ]; then
        FUNCTION_BODY+="$line"$'\n'
    fi
done < "$LOCAL_FILE"

# Prepare the function code to append to parent
FUNCTION_CODE=""
FUNCTION_CODE+="${FUNC_NAME}:"$'\n'
FUNCTION_CODE+="${FUNCTION_BODY}"

# Combine parameter data and local data for insertion
ALL_DATA="${LOCAL_DATA}${PARAM_DATA}"

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

echo "Successfully created function '$FUNC_NAME'"
if [ $WITH_CALL -eq 1 ]; then
    echo "Added test call in _start"
fi
exit 0
