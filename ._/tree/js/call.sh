#!/bin/bash

# call.sh - Handles generic function calls and appends them to build_output.asm
# FIXED: Simplified variable handling, uses dynamic allocation for strings
# FIXED: Nested calls are now fully recursive (the old process_nested_call only
#        handled ONE level; deeper calls were emitted as `mov rax, [f(1,2)]`).
# FIXED: Nested calls no longer clobber parameters. Every argument is first
#        evaluated into its own temporary slot; only after ALL arguments are
#        evaluated are they copied into the callee's parameters.
# FIXED: Float results keep their exact double value (*_float_val / xmm0) and
#        their text is copied to the heap, so they are never passed on as a
#        raw pointer and are not overwritten by later calls.
# FIXED: String/float constants are emitted as byte lists (NASM does not
#        support '' escaping inside single-quoted strings).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

OUTPUT_FILE="../../build_output.asm"
INPUT_FILE="call_input"
META_DIR="../function_meta"

if [ ! -f "$INPUT_FILE" ]; then
    echo "Error: $INPUT_FILE not found"
    exit 1
fi

CALL_STMT=$(cat "$INPUT_FILE" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
CALL_STMT=$(echo "$CALL_STMT" | sed 's/;.*$//')

ASSIGNMENT_MODE=0
VAR_NAME=""
if [[ "$CALL_STMT" =~ ^[[:space:]]*(var|let|const)[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
    ASSIGNMENT_MODE=1
    VAR_NAME="${BASH_REMATCH[2]}"
    CALL_STMT="${BASH_REMATCH[3]}"
    CALL_STMT=$(echo "$CALL_STMT" | sed 's/;.*$//')
    CALL_STMT=$(echo "$CALL_STMT" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
fi

if [[ "$CALL_STMT" =~ ^([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*\((.*)\)$ ]]; then
    FUNC_NAME="${BASH_REMATCH[1]}"
    ARGS="${BASH_REMATCH[2]}"
else
    echo "Error: Invalid function call format: $CALL_STMT"
    exit 1
fi

CALL_ID="call_$(date +%s%N 2>/dev/null || date +%s)_$$"

STRING_CONSTANTS=""
TEMP_DATA=""
CALL_CODE=""
declare -A DECLARED_TEMPS=()

escape_string() {
    local str="$1"
   
    if [ -z "$str" ]; then
        echo "0"
        return
    fi
   
    local processed=""
    local i=0
    while [ $i -lt ${#str} ]; do
        local c="${str:$i:1}"
        if [ "$c" = '\' ] && [ $((i+1)) -lt ${#str} ]; then
            local n="${str:$((i+1)):1}"
            case "$n" in
                n)  processed+=$'\n'; i=$((i+2)); continue ;;
                t)  processed+=$'\t'; i=$((i+2)); continue ;;
                r)  processed+=$'\r'; i=$((i+2)); continue ;;
                \\) processed+='\\'; i=$((i+2)); continue ;;
                \") processed+='"'; i=$((i+2)); continue ;;
                \') processed+="'"; i=$((i+2)); continue ;;
            esac
        fi
        processed+="$c"
        i=$((i+1))
    done
   
    local bytes=$(printf "%s" "$processed" | hexdump -v -e '1/1 "%d, "')
    bytes="${bytes%, }"
   
    if [ -n "$bytes" ]; then
        echo "${bytes}, 0"
    else
        echo "0"
    fi
}

# Parse comma-separated argument string with quote and paren awareness
parse_args() {
    local args_str="$1"
    local args=()
    local current=""
    local in_quote=false
    local quote_char=""
    local paren_depth=0
    local i=0
   
    if [[ -z "${args_str// }" ]]; then
        return
    fi
   
    while [ $i -lt ${#args_str} ]; do
        local c="${args_str:$i:1}"
       
        if [[ "$c" =~ [\"\'] ]]; then
            if [ "$in_quote" = false ]; then
                in_quote=true
                quote_char="$c"
            elif [ "$c" = "$quote_char" ]; then
                in_quote=false
                quote_char=""
            fi
        fi
       
        if [ "$in_quote" = false ]; then
            if [ "$c" = '(' ]; then
                paren_depth=$((paren_depth + 1))
            elif [ "$c" = ')' ]; then
                paren_depth=$((paren_depth - 1))
            fi
        fi
       
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

# Append one line of assembly to the generated code
emit() {
    CALL_CODE+="$1"$'\n'
}

# Declare a value slot (value, _type, _float_val) exactly once
declare_temp() {
    local name="$1"
    if [ -n "${DECLARED_TEMPS[$name]:-}" ]; then
        return 0
    fi
    DECLARED_TEMPS["$name"]=1
    TEMP_DATA+="    ${name} dq 0"$'\n'
    TEMP_DATA+="    ${name}_type dq TYPE_UNDEFINED"$'\n'
    TEMP_DATA+="    ${name}_float_val dq 0"$'\n'
}

# Check whether a data label is already declared in the output file
label_exists() {
    local label="$1"
    if [ ! -f "$OUTPUT_FILE" ]; then
        return 1
    fi
    grep -qE "^[[:space:]]*${label}[[:space:]]+(db|dq|dd|dw|equ|times|resb|resq|resd|resw)([[:space:]]|$)" "$OUTPUT_FILE"
}

# Make a float literal acceptable to NASM's `dq` (".5" -> "0.5", "-.5" -> "-0.5")
normalize_float_literal() {
    local v="$1"
    if [[ "$v" == -.* ]]; then
        v="-0${v:1}"
    elif [[ "$v" == .* ]]; then
        v="0${v}"
    fi
    echo "$v"
}

# Copy a full value slot (value, type and double) from src to dest
copy_value() {
    local src="$1"
    local dest="$2"
    emit "    mov rax, [${src}]"
    emit "    mov [${dest}], rax"
    emit "    mov rax, [${src}_type]"
    emit "    mov [${dest}_type], rax"
    emit "    movsd xmm0, [${src}_float_val]"
    emit "    movsd [${dest}_float_val], xmm0"
}

# Store undefined into a full value slot
emit_undefined_into() {
    local dest="$1"
    emit "    mov qword [${dest}], 0"
    emit "    mov qword [${dest}_type], TYPE_UNDEFINED"
    emit "    pxor xmm0, xmm0"
    emit "    movsd [${dest}_float_val], xmm0"
}

# Generate code computing expr into [dest], [dest_type] and [dest_float_val].
# Temporary labels are prefixed by `prefix`.
generate_value_into() {
    local expr="$1"
    local prefix="$2"
    local dest="$3"
    local stripped escaped normalized
   
    if [ -z "$expr" ] || [ "$expr" = "undefined" ]; then
        emit_undefined_into "$dest"
        return 0
    fi
   
    # String literal
    if [[ "$expr" =~ ^\".*\"$ ]] || [[ "$expr" =~ ^\'.*\'$ ]]; then
        stripped="${expr:1:${#expr}-2}"
        escaped=$(escape_string "$stripped")
        STRING_CONSTANTS+="    ${prefix}_str db ${escaped}"$'\n'
        emit "    mov rsi, ${prefix}_str"
        emit "    call allocate_string"
        emit "    mov [${dest}], rax"
        emit "    mov qword [${dest}_type], TYPE_STRING"
        emit "    pxor xmm0, xmm0"
        emit "    movsd [${dest}_float_val], xmm0"
        return 0
    fi
   
    # Integer literal
    if [[ "$expr" =~ ^-?[0-9]+$ ]]; then
        emit "    mov rax, ${expr}"
        emit "    mov [${dest}], rax"
        emit "    mov qword [${dest}_type], TYPE_NUMBER"
        emit "    cvtsi2sd xmm0, rax"
        emit "    movsd [${dest}_float_val], xmm0"
        return 0
    fi
   
    # Float literal
    if [[ "$expr" =~ ^-?[0-9]*\.[0-9]+$ ]]; then
        escaped=$(escape_string "$expr")
        normalized=$(normalize_float_literal "$expr")
        STRING_CONSTANTS+="    ${prefix}_str db ${escaped}"$'\n'
        STRING_CONSTANTS+="    ${prefix}_dbl dq ${normalized}"$'\n'
        emit "    mov rsi, ${prefix}_str"
        emit "    call allocate_string"
        emit "    mov [${dest}], rax"
        emit "    mov qword [${dest}_type], TYPE_FLOAT"
        emit "    movsd xmm0, [${prefix}_dbl]"
        emit "    movsd [${dest}_float_val], xmm0"
        return 0
    fi
   
    # Boolean
    if [ "$expr" = "true" ] || [ "$expr" = "false" ]; then
        if [ "$expr" = "true" ]; then
            emit "    mov rax, 1"
        else
            emit "    xor rax, rax"
        fi
        emit "    mov [${dest}], rax"
        emit "    mov qword [${dest}_type], TYPE_BOOLEAN"
        emit "    cvtsi2sd xmm0, rax"
        emit "    movsd [${dest}_float_val], xmm0"
        return 0
    fi
   
    # null
    if [ "$expr" = "null" ]; then
        emit "    mov qword [${dest}], 0"
        emit "    mov qword [${dest}_type], TYPE_NULL"
        emit "    pxor xmm0, xmm0"
        emit "    movsd [${dest}_float_val], xmm0"
        return 0
    fi
   
    # Simple variable identifier
    if [[ "$expr" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
        emit "    ; Copy variable ${expr}"
        emit "    mov rax, [${expr}]"
        emit "    mov [${dest}], rax"
        emit "    mov rdx, [${expr}_type]"
        emit "    mov [${dest}_type], rdx"
        if label_exists "${expr}_float_val"; then
            emit "    movsd xmm0, [${expr}_float_val]"
            emit "    call rt_to_double"
        else
            emit "    call rt_to_double_str"
        fi
        emit "    movsd [${dest}_float_val], xmm0"
        return 0
    fi
   
    # Nested function call -> recurse
    if [[ "$expr" =~ ^[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*\(.*\)$ ]]; then
        emit "    ; Nested function call as argument: ${expr}"
        generate_function_call "$expr" "$prefix"
        copy_value "${prefix}_result" "$dest"
        return 0
    fi
   
    # Fallback
    emit_undefined_into "$dest"
}

# Generate code for a function call, storing the return value in
# [prefix_result], [prefix_result_type] and [prefix_result_float_val].
generate_function_call() {
    local call_expr="$1"
    local prefix="$2"
    local result="${prefix}_result"
   
    local func_name=""
    local args_str=""
   
    declare_temp "$result"
   
    if [[ "$call_expr" =~ ^([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*\((.*)\)$ ]]; then
        func_name="${BASH_REMATCH[1]}"
        args_str="${BASH_REMATCH[2]}"
    else
        echo "Error: Invalid function call format: $call_expr" >&2
        emit_undefined_into "$result"
        return 0
    fi
   
    local meta_file="$META_DIR/${func_name}.meta"
    if [ ! -f "$meta_file" ]; then
        echo "Error: No metadata for function $func_name (expected at $meta_file)" >&2
        emit_undefined_into "$result"
        return 0
    fi
   
    local -a param_names=()
    local -a param_defaults=()
    local -a param_types=()
    local line param_info pname pdefault ptype
   
    while IFS= read -r line; do
        if [[ "$line" == param=* ]]; then
            param_info="${line#param=}"
            IFS='|' read -r pname pdefault ptype <<< "$param_info"
            param_names+=("$pname")
            param_defaults+=("$pdefault")
            param_types+=("$ptype")
        fi
    done < "$meta_file"
   
    local -a call_args=()
    if [ -n "${args_str// }" ]; then
        mapfile -t call_args < <(parse_args "$args_str")
    fi
   
    local i expr tmp
   
    # Phase 1: evaluate EVERY argument into its own temporary slot.
    emit "    ; Evaluate arguments of ${func_name} into temporaries"
    for ((i=0; i<${#param_names[@]}; i++)); do
        tmp="${prefix}_a${i}_v"
        declare_temp "$tmp"
       
        if [ $i -lt ${#call_args[@]} ]; then
            expr="${call_args[$i]}"
        else
            pdefault="${param_defaults[$i]}"
            ptype="${param_types[$i]}"
            case "$ptype" in
                number|float)
                    if [ -n "$pdefault" ]; then
                        expr="$pdefault"
                    else
                        expr="undefined"
                    fi
                    ;;
                string)
                    expr="\"${pdefault}\""
                    ;;
                *)
                    expr="undefined"
                    ;;
            esac
        fi
       
        generate_value_into "$expr" "${prefix}_a${i}" "$tmp"
    done
   
    # Phase 2: copy the evaluated arguments into the parameters and call.
    emit "    ; Copy evaluated arguments into ${func_name} parameters"
    for ((i=0; i<${#param_names[@]}; i++)); do
        copy_value "${prefix}_a${i}_v" "${func_name}_${param_names[$i]}"
    done
   
    emit "    call ${func_name}"
    emit "    call rt_capture_result"
    emit "    mov [${result}], rax"
    emit "    mov [${result}_type], rdx"
    emit "    movsd [${result}_float_val], xmm0"
}

mapfile -t ARGS_ARRAY < <(parse_args "$ARGS")

META_FILE="$META_DIR/${FUNC_NAME}.meta"

if [ -f "$META_FILE" ]; then
    CALL_CODE="    ; Function call with parameters: ${FUNC_NAME}(${ARGS})"$'\n'
   
    generate_function_call "${FUNC_NAME}(${ARGS})" "$CALL_ID"
   
    if [ "$ASSIGNMENT_MODE" -eq 1 ]; then
        emit "    ; Store return value from function"
        emit "    mov rax, [${CALL_ID}_result]"
        emit "    mov [${VAR_NAME}], rax"
        emit "    mov rax, [${CALL_ID}_result_type]"
        emit "    mov [${VAR_NAME}_type], rax"
        emit "    movsd xmm0, [${CALL_ID}_result_float_val]"
        emit "    movsd [${VAR_NAME}_float_val], xmm0"
    fi
   
else
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

if [ ! -f "$OUTPUT_FILE" ]; then
    echo "Error: $OUTPUT_FILE not found"
    exit 1
fi

DATA_INSERT=""
if [ -n "$STRING_CONSTANTS" ]; then
    DATA_INSERT="$STRING_CONSTANTS"
fi
if [ -n "$TEMP_DATA" ]; then
    DATA_INSERT+="${TEMP_DATA}"
fi
if [ "$ASSIGNMENT_MODE" -eq 1 ]; then
    VAR_DECLARATIONS="    ${VAR_NAME} dq 0"$'\n'
    VAR_DECLARATIONS+="    ${VAR_NAME}_type dq TYPE_UNDEFINED"$'\n'
    VAR_DECLARATIONS+="    ${VAR_NAME}_float_val dq 0"$'\n'
    DATA_INSERT+="${VAR_DECLARATIONS}"
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
        if [ "$DATA_DONE" -eq 0 ] && [ -n "$DATA_INSERT" ]; then
            printf '%s' "$DATA_INSERT" >> "$TEMP_FILE"
            DATA_DONE=1
        fi
        IN_DATA=0
    fi
   
    if [[ "$line" == "_start:" ]]; then
        IN_START=1
    fi
   
    if [ "$IN_START" -eq 1 ] && [ "$CODE_DONE" -eq 0 ] && \
       [[ "$line" =~ ^[[:space:]]*mov[[:space:]]+rax,[[:space:]]*60$ ]]; then
        printf '%s' "$CALL_CODE" >> "$TEMP_FILE"
        CODE_DONE=1
    fi
   
    echo "$line" >> "$TEMP_FILE"
done < "$OUTPUT_FILE"

if [ "$IN_DATA" -eq 1 ] && [ "$DATA_DONE" -eq 0 ] && [ -n "$DATA_INSERT" ]; then
    printf '%s' "$DATA_INSERT" >> "$TEMP_FILE"
fi

if [ "$CODE_DONE" -eq 0 ] && [ -n "$CALL_CODE" ]; then
    printf '%s' "$CALL_CODE" >> "$TEMP_FILE"
fi

mv "$TEMP_FILE" "$OUTPUT_FILE"

echo "Successfully appended function call: ${FUNC_NAME}(${ARGS})"
exit 0
