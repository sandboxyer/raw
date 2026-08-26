#!/bin/bash

# call.sh - Handles generic function calls and appends them to build_output.asm
# Enhanced: Proper metadata-based parameter handling with string support
# FIX: Strings are stored directly at the variable's address

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

OUTPUT_FILE="../../build_output.asm"
INPUT_FILE="call_input"
META_DIR="../function_meta"

if [ ! -f "$INPUT_FILE" ]; then
    echo "Error: $INPUT_FILE not found"
    exit 1
fi

# Read and clean the call statement
CALL_STMT=$(cat "$INPUT_FILE" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
CALL_STMT=$(echo "$CALL_STMT" | sed 's/;.*$//')
CALL_STMT=$(echo "$CALL_STMT" | sed 's/))$/)/')

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
CALL_ID="call_$(date +%s%N 2>/dev/null || date +%s)_$$"

# Parse arguments (respecting quotes and nested parentheses)
parse_args() {
    local args=()
    local current=""
    local in_quote=false
    local quote_char=""
    local paren_depth=0
    local i=0
    
    if [[ -z "${ARGS// }" ]]; then
        return
    fi
    
    while [ $i -lt ${#ARGS} ]; do
        local c="${ARGS:$i:1}"
        
        # Handle quotes
        if [[ "$c" =~ [\"\'] ]]; then
            if [ "$in_quote" = false ]; then
                in_quote=true
                quote_char="$c"
            elif [ "$c" = "$quote_char" ]; then
                in_quote=false
                quote_char=""
            fi
        fi
        
        # Handle parentheses (for nested function calls)
        if [ "$in_quote" = false ]; then
            if [ "$c" = '(' ]; then
                paren_depth=$((paren_depth + 1))
            elif [ "$c" = ')' ]; then
                paren_depth=$((paren_depth - 1))
            fi
        fi
        
        # Split on comma only at top level
        if [ "$c" = ',' ] && [ "$in_quote" = false ] && [ $paren_depth -eq 0 ]; then
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

# Generate string copy code using a loop in assembly
generate_string_copy() {
    local src_label="$1"
    local dest_label="$2"
    local temp_label="${3:-copy_loop}"
    
    cat << EOF
    ; Copy string from ${src_label} to ${dest_label}
    mov rsi, ${src_label}
    mov rdi, ${dest_label}
.${temp_label}:
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    test al, al
    jnz .${temp_label}
EOF
}

# Main execution
mapfile -t ARGS_ARRAY < <(parse_args)

# Check if metadata exists for this function
META_FILE="$META_DIR/${FUNC_NAME}.meta"
STRING_CONSTANTS=""
CALL_CODE=""

if [ -f "$META_FILE" ]; then
    echo "Debug - Found metadata for $FUNC_NAME" >&2
    
    # Load metadata
    declare -a param_names
    declare -a param_defaults
    declare -a param_types
    
    while IFS= read -r line; do
        if [[ "$line" == param=* ]]; then
            param_info="${line#param=}"
            IFS='|' read -r pname pdefault ptype <<< "$param_info"
            param_names+=("$pname")
            param_defaults+=("$pdefault")
            param_types+=("$ptype")
            echo "Debug - Loaded param: name='$pname', default='$pdefault', type='$ptype'" >&2
        fi
    done < "$META_FILE"
    
    echo "Debug - Total parameters: ${#param_names[@]}" >&2
    echo "Debug - Provided arguments: ${#ARGS_ARRAY[@]}" >&2
    
    # Generate metadata-based call code
    CALL_CODE="    ; Function call with parameters: ${FUNC_NAME}(${ARGS})"$'\n'
    
    for ((i=0; i<${#param_names[@]}; i++)); do
        param_name="${param_names[$i]}"
        param_default="${param_defaults[$i]}"
        param_type="${param_types[$i]}"
        scoped_param_name="${FUNC_NAME}_${param_name}"
        
        echo "Debug - Processing param $i: '$param_name' (scoped: '$scoped_param_name')" >&2
        
        if [ $i -lt ${#ARGS_ARRAY[@]} ]; then
            arg="${ARGS_ARRAY[$i]}"
            echo "Debug -   Argument provided: '$arg'" >&2
            
            # String literal (double quotes)
            if [[ "$arg" =~ ^\".*\"$ ]] || [[ "$arg" =~ ^\'.*\'$ ]]; then
                stripped="${arg:1:${#arg}-2}"
                stripped_esc=$(echo "$stripped" | sed "s/'/''/g")
                
                # Create a temporary string constant
                temp_str_label="${CALL_ID}_param${i}_temp_str"
                STRING_CONSTANTS+="    ${temp_str_label} db '${stripped_esc}', 0"$'\n'
                
                # Copy the string data directly to the parameter variable's address
                CALL_CODE+="$(generate_string_copy "$temp_str_label" "$scoped_param_name" "${CALL_ID}_copy${i}")"$'\n'
                CALL_CODE+="    mov qword [${scoped_param_name}_type], TYPE_STRING"$'\n'
                
            # Numeric literal
            elif [[ "$arg" =~ ^-?[0-9]+$ ]]; then
                CALL_CODE+="    mov qword [${scoped_param_name}], ${arg}"$'\n'
                CALL_CODE+="    mov qword [${scoped_param_name}_type], TYPE_NUMBER"$'\n'
                
            # Float literal
            elif [[ "$arg" =~ ^-?[0-9]*\.[0-9]+$ ]]; then
                # Store as string for simplicity
                temp_float_label="${CALL_ID}_param${i}_float_str"
                STRING_CONSTANTS+="    ${temp_float_label} db '${arg}', 0"$'\n'
                CALL_CODE+="$(generate_string_copy "$temp_float_label" "$scoped_param_name" "${CALL_ID}_floatcopy${i}")"$'\n'
                CALL_CODE+="    mov qword [${scoped_param_name}_type], TYPE_FLOAT"$'\n'
                
            # Boolean literal
            elif [[ "$arg" == "true" ]] || [[ "$arg" == "false" ]]; then
                if [ "$arg" == "true" ]; then
                    CALL_CODE+="    mov qword [${scoped_param_name}], 1"$'\n'
                else
                    CALL_CODE+="    mov qword [${scoped_param_name}], 0"$'\n'
                fi
                CALL_CODE+="    mov qword [${scoped_param_name}_type], TYPE_BOOLEAN"$'\n'
                
            # null or undefined
            elif [[ "$arg" == "null" ]]; then
                CALL_CODE+="    mov qword [${scoped_param_name}], 0"$'\n'
                CALL_CODE+="    mov qword [${scoped_param_name}_type], TYPE_NULL"$'\n'
            elif [[ "$arg" == "undefined" ]]; then
                CALL_CODE+="    mov qword [${scoped_param_name}], 0"$'\n'
                CALL_CODE+="    mov qword [${scoped_param_name}_type], TYPE_UNDEFINED"$'\n'
                
            # Variable reference
            else
                # For variable references, we need to handle strings specially
                CALL_CODE+="    ; Check if source variable is a string"$'\n'
                CALL_CODE+="    mov rax, [${arg}_type]"$'\n'
                CALL_CODE+="    cmp rax, TYPE_STRING"$'\n'
                CALL_CODE+="    je .${CALL_ID}_copy_string${i}"$'\n'
                CALL_CODE+="    ; Not a string, just copy value and type"$'\n'
                CALL_CODE+="    mov rax, [${arg}]"$'\n'
                CALL_CODE+="    mov [${scoped_param_name}], rax"$'\n'
                CALL_CODE+="    mov rax, [${arg}_type]"$'\n'
                CALL_CODE+="    mov [${scoped_param_name}_type], rax"$'\n'
                CALL_CODE+="    jmp .${CALL_ID}_done${i}"$'\n'
                CALL_CODE+=".${CALL_ID}_copy_string${i}:"$'\n'
                CALL_CODE+="    ; Copy string data"$'\n'
                CALL_CODE+="    mov rsi, [${arg}]"$'\n'
                CALL_CODE+="    mov rdi, ${scoped_param_name}"$'\n'
                CALL_CODE+=".${CALL_ID}_str_loop${i}:"$'\n'
                CALL_CODE+="    mov al, [rsi]"$'\n'
                CALL_CODE+="    mov [rdi], al"$'\n'
                CALL_CODE+="    inc rsi"$'\n'
                CALL_CODE+="    inc rdi"$'\n'
                CALL_CODE+="    test al, al"$'\n'
                CALL_CODE+="    jnz .${CALL_ID}_str_loop${i}"$'\n'
                CALL_CODE+="    mov qword [${scoped_param_name}_type], TYPE_STRING"$'\n'
                CALL_CODE+=".${CALL_ID}_done${i}:"$'\n'
            fi
        else
            # No argument, use default
            if [ -n "$param_default" ]; then
                echo "Debug -   Using default: '$param_default' (type: $param_type)" >&2
                
                case "$param_type" in
                    "number")
                        CALL_CODE+="    mov qword [${scoped_param_name}], ${param_default}"$'\n'
                        CALL_CODE+="    mov qword [${scoped_param_name}_type], TYPE_NUMBER"$'\n'
                        ;;
                    "string")
                        default_esc=$(echo "$param_default" | sed "s/'/''/g")
                        temp_default_label="${CALL_ID}_param${i}_default_str"
                        STRING_CONSTANTS+="    ${temp_default_label} db '${default_esc}', 0"$'\n'
                        CALL_CODE+="$(generate_string_copy "$temp_default_label" "$scoped_param_name" "${CALL_ID}_defcopy${i}")"$'\n'
                        CALL_CODE+="    mov qword [${scoped_param_name}_type], TYPE_STRING"$'\n'
                        ;;
                    "float")
                        temp_float_label="${CALL_ID}_param${i}_default_float"
                        STRING_CONSTANTS+="    ${temp_float_label} db '${param_default}', 0"$'\n'
                        CALL_CODE+="$(generate_string_copy "$temp_float_label" "$scoped_param_name" "${CALL_ID}_deffloatcopy${i}")"$'\n'
                        CALL_CODE+="    mov qword [${scoped_param_name}_type], TYPE_FLOAT"$'\n'
                        ;;
                    "variable")
                        # Similar to variable reference handling above
                        CALL_CODE+="    mov rax, [${param_default}_type]"$'\n'
                        CALL_CODE+="    cmp rax, TYPE_STRING"$'\n'
                        CALL_CODE+="    je .${CALL_ID}_default_copy_string${i}"$'\n'
                        CALL_CODE+="    mov rax, [${param_default}]"$'\n'
                        CALL_CODE+="    mov [${scoped_param_name}], rax"$'\n'
                        CALL_CODE+="    mov rax, [${param_default}_type]"$'\n'
                        CALL_CODE+="    mov [${scoped_param_name}_type], rax"$'\n'
                        CALL_CODE+="    jmp .${CALL_ID}_default_done${i}"$'\n'
                        CALL_CODE+=".${CALL_ID}_default_copy_string${i}:"$'\n'
                        CALL_CODE+="    mov rsi, [${param_default}]"$'\n'
                        CALL_CODE+="    mov rdi, ${scoped_param_name}"$'\n'
                        CALL_CODE+=".${CALL_ID}_default_str_loop${i}:"$'\n'
                        CALL_CODE+="    mov al, [rsi]"$'\n'
                        CALL_CODE+="    mov [rdi], al"$'\n'
                        CALL_CODE+="    inc rsi"$'\n'
                        CALL_CODE+="    inc rdi"$'\n'
                        CALL_CODE+="    test al, al"$'\n'
                        CALL_CODE+="    jnz .${CALL_ID}_default_str_loop${i}"$'\n'
                        CALL_CODE+="    mov qword [${scoped_param_name}_type], TYPE_STRING"$'\n'
                        CALL_CODE+=".${CALL_ID}_default_done${i}:"$'\n'
                        ;;
                    *)
                        CALL_CODE+="    mov qword [${scoped_param_name}], 0"$'\n'
                        CALL_CODE+="    mov qword [${scoped_param_name}_type], TYPE_UNDEFINED"$'\n'
                        ;;
                esac
            else
                echo "Debug -   No default, setting undefined" >&2
                CALL_CODE+="    mov qword [${scoped_param_name}], 0"$'\n'
                CALL_CODE+="    mov qword [${scoped_param_name}_type], TYPE_UNDEFINED"$'\n'
            fi
        fi
    done
    
    CALL_CODE+="    call ${FUNC_NAME}"$'\n'
    
else
    echo "Debug - No metadata, using stack method" >&2
    # Legacy stack-based method
    CALL_CODE="    ; Function call: ${FUNC_NAME}(${ARGS})"$'\n'
    
    if [ ${#ARGS_ARRAY[@]} -gt 0 ]; then
        for ((i=${#ARGS_ARRAY[@]}-1; i>=0; i--)); do
            arg="${ARGS_ARRAY[$i]}"
            if [[ "$arg" =~ ^\".*\"$ ]]; then
                stripped="${arg:1:${#arg}-2}"
                STRING_CONSTANTS+="    ${CALL_ID}_str${i} db '${stripped}', 0"$'\n'
                CALL_CODE+="    mov rax, ${CALL_ID}_str${i}"$'\n'
                CALL_CODE+="    push rax"$'\n'
            elif [[ "$arg" =~ ^-?[0-9]+$ ]]; then
                CALL_CODE+="    mov rax, $arg"$'\n'
                CALL_CODE+="    push rax"$'\n'
            else
                CALL_CODE+="    mov rax, [${arg}]"$'\n'
                CALL_CODE+="    push rax"$'\n'
            fi
        done
    fi
    
    CALL_CODE+="    call ${FUNC_NAME}"$'\n'
    
    if [ ${#ARGS_ARRAY[@]} -gt 0 ]; then
        CALL_CODE+="    add rsp, $((8 * ${#ARGS_ARRAY[@]}))"$'\n'
    fi
fi

# Insert into build_output.asm
if [ ! -f "$OUTPUT_FILE" ]; then
    echo "Error: $OUTPUT_FILE not found"
    exit 1
fi

TEMP_FILE=$(mktemp)
IN_DATA=0
IN_START=0
DATA_DONE=0
CODE_DONE=0

while IFS= read -r line; do
    if [[ "$line" == "section .data" ]]; then
        IN_DATA=1
    elif [[ "$line" == section* ]] && [ "$IN_DATA" -eq 1 ]; then
        if [ "$DATA_DONE" -eq 0 ] && [ -n "$STRING_CONSTANTS" ]; then
            echo "$STRING_CONSTANTS" >> "$TEMP_FILE"
            DATA_DONE=1
        fi
        IN_DATA=0
    fi
    
    if [[ "$line" == "_start:" ]]; then
        IN_START=1
    fi
    
    if [ "$IN_START" -eq 1 ] && [ "$CODE_DONE" -eq 0 ] && \
       [[ "$line" =~ ^[[:space:]]*mov[[:space:]]+rax,[[:space:]]*60$ ]]; then
        echo "$CALL_CODE" >> "$TEMP_FILE"
        CODE_DONE=1
    fi
    
    echo "$line" >> "$TEMP_FILE"
done < "$OUTPUT_FILE"

if [ "$IN_DATA" -eq 1 ] && [ "$DATA_DONE" -eq 0 ] && [ -n "$STRING_CONSTANTS" ]; then
    echo "$STRING_CONSTANTS" >> "$TEMP_FILE"
fi

if [ "$CODE_DONE" -eq 0 ] && [ -n "$CALL_CODE" ]; then
    echo "$CALL_CODE" >> "$TEMP_FILE"
fi

mv "$TEMP_FILE" "$OUTPUT_FILE"

echo "Successfully appended function call: ${FUNC_NAME}(${ARGS})"
exit 0