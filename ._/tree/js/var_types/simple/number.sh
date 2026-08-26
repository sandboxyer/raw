#!/bin/bash

# number.sh - Converts JavaScript number declarations to NASM assembly code
# Supports variables in expressions, runtime evaluation, and reassignment.
# All variables get storage for both integer and float representation.
# NEW: Handles single variable-to-variable copy without needing the source type.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && cd .. && pwd)"
cd "$SCRIPT_DIR/simple"

OUTPUT_FILE="../../../../build_output.asm"
INPUT_FILE="../../var_input"

REASSIGNMENT="${REASSIGNMENT:-false}"

# Initialize rpn_tokens as an empty array to satisfy set -u
rpn_tokens=()

if [ ! -f "$INPUT_FILE" ]; then
    echo "Error: $INPUT_FILE not found"
    exit 1
fi

INPUT_CONTENT=$(cat "$INPUT_FILE" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
INPUT_CONTENT="${INPUT_CONTENT%;}"

if [[ "$INPUT_CONTENT" =~ ^var[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
    VAR_NAME="${BASH_REMATCH[1]}"
    VAR_VALUE="${BASH_REMATCH[2]}"
elif [[ "$REASSIGNMENT" == "true" && "$INPUT_CONTENT" =~ ^([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
    VAR_NAME="${BASH_REMATCH[1]}"
    VAR_VALUE="${BASH_REMATCH[2]}"
else
    echo "Error: Invalid variable declaration format"
    exit 1
fi

VAR_VALUE=$(echo "$VAR_VALUE" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

# ----------------------------------------------------------------------
# Load existing variable types from build_output.asm
# Now scans BOTH static data (dq) and runtime assignments (mov)
# and keeps the LATEST occurrence for each variable.
# ----------------------------------------------------------------------
declare -A VAR_TYPE

load_variable_types() {
    VAR_TYPE=()
    while IFS= read -r line; do
        # Static: varname_type dq TYPE_FLOAT/NUMBER
        if [[ "$line" =~ ^[[:space:]]*([a-zA-Z_][a-zA-Z0-9_]*)_type[[:space:]]+dq[[:space:]]+TYPE_(FLOAT|NUMBER) ]]; then
            local var_name="${BASH_REMATCH[1]}"
            local type_name="${BASH_REMATCH[2]}"
            if [[ "$type_name" == "FLOAT" ]]; then
                VAR_TYPE["$var_name"]="float"
            else
                VAR_TYPE["$var_name"]="int"
            fi
        fi
        # Runtime: mov qword [varname_type], TYPE_FLOAT/NUMBER
        if [[ "$line" =~ ^[[:space:]]*mov[[:space:]]+qword[[:space:]]+\[([a-zA-Z_][a-zA-Z0-9_]*)_type\][[:space:]]*,[[:space:]]*TYPE_(FLOAT|NUMBER) ]]; then
            local var_name="${BASH_REMATCH[1]}"
            local type_name="${BASH_REMATCH[2]}"
            if [[ "$type_name" == "FLOAT" ]]; then
                VAR_TYPE["$var_name"]="float"
            else
                VAR_TYPE["$var_name"]="int"
            fi
        fi
    done < "$OUTPUT_FILE"
}

load_variable_types

# ----------------------------------------------------------------------
# Tokenizer
# ----------------------------------------------------------------------
tokenize() {
    local expr="$1"
    local tokens=()
    local i=0
    local len=${#expr}
    local prev_type="START"  # Track previous token type for unary minus detection
   
    while [ $i -lt $len ]; do
        local c="${expr:$i:1}"
        if [[ "$c" =~ [[:space:]] ]]; then
            i=$((i+1))
            continue
        fi
       
        # Handle minus sign (could be unary or binary)
        if [[ "$c" == "-" ]]; then
            # Check if this is a unary minus (start of expression, after operator, or after open paren)
            if [ "$prev_type" = "START" ] || [ "$prev_type" = "OP" ] || [ "$prev_type" = "LPAREN" ]; then
                # This is a unary minus - check if it's followed by a number or parenthesis
                i=$((i+1))
                if [ $i -lt $len ]; then
                    local nc="${expr:$i:1}"
                    if [[ "$nc" =~ [0-9] ]] || [[ "$nc" == "." ]]; then
                        # Parse negative number
                        local num="-$nc"
                        i=$((i+1))
                        local has_dot=false
                        [[ "$nc" == "." ]] && has_dot=true
                       
                        while [ $i -lt $len ]; do
                            local digit="${expr:$i:1}"
                            if [[ "$digit" =~ [0-9] ]]; then
                                num="${num}${digit}"
                                i=$((i+1))
                            elif [[ "$digit" == "." ]] && [ "$has_dot" = false ]; then
                                num="${num}${digit}"
                                has_dot=true
                                i=$((i+1))
                            elif [[ "$digit" =~ [eE] ]]; then
                                num="${num}${digit}"
                                i=$((i+1))
                                if [ $i -lt $len ]; then
                                    local sign="${expr:$i:1}"
                                    if [[ "$sign" =~ [\+\-] ]]; then
                                        num="${num}${sign}"
                                        i=$((i+1))
                                    fi
                                fi
                            else
                                break
                            fi
                        done
                       
                        if [[ "$num" =~ \. ]] || [[ "$num" =~ [eE] ]]; then
                            tokens+=("FLOAT:$num")
                        else
                            tokens+=("INT:$num")
                        fi
                        prev_type="NUM"
                        continue
                    elif [[ "$nc" == "(" ]]; then
                        # Unary minus before parenthesis: -(expr)
                        # We'll handle this as: 0 - (expr)
                        tokens+=("INT:0")
                        tokens+=("OP:-")
                        prev_type="OP"
                        # Don't consume the '(' here, let it be processed in the next iteration
                        continue
                    fi
                fi
            fi
            # Binary subtraction
            tokens+=("OP:-")
            prev_type="OP"
            i=$((i+1))
            continue
        fi
       
        if [[ "$c" =~ [0-9] ]] || [[ "$c" == "." ]]; then
            local num="$c"
            i=$((i+1))
            local has_dot=false
            [[ "$c" == "." ]] && has_dot=true
            while [ $i -lt $len ]; do
                local nc="${expr:$i:1}"
                if [[ "$nc" =~ [0-9] ]]; then
                    num="${num}${nc}"
                    i=$((i+1))
                elif [[ "$nc" == "." ]] && [ "$has_dot" = false ]; then
                    num="${num}${nc}"
                    has_dot=true
                    i=$((i+1))
                elif [[ "$nc" =~ [eE] ]]; then
                    num="${num}${nc}"
                    i=$((i+1))
                    if [ $i -lt $len ]; then
                        local sign="${expr:$i:1}"
                        if [[ "$sign" =~ [\+\-] ]]; then
                            num="${num}${sign}"
                            i=$((i+1))
                        fi
                    fi
                else
                    break
                fi
            done
            if [[ "$num" =~ \. ]] || [[ "$num" =~ [eE] ]]; then
                tokens+=("FLOAT:$num")
            else
                tokens+=("INT:$num")
            fi
            prev_type="NUM"
            continue
        fi
        if [[ "$c" =~ [a-zA-Z_] ]]; then
            local name="$c"
            i=$((i+1))
            while [ $i -lt $len ]; do
                local nc="${expr:$i:1}"
                if [[ "$nc" =~ [a-zA-Z0-9_] ]]; then
                    name="${name}${nc}"
                    i=$((i+1))
                else
                    break
                fi
            done
            case "$name" in
                var|let|const|if|else|while|for|function|return)
                    echo "Error: Unexpected keyword '$name' in expression" >&2
                    exit 1
                    ;;
            esac
            tokens+=("VAR:$name")
            prev_type="VAR"
            continue
        fi
        case "$c" in
            '+'|'*'|'/'|'%')
                tokens+=("OP:$c")
                prev_type="OP"
                i=$((i+1))
                ;;
            '(')
                tokens+=("OP:(")
                prev_type="LPAREN"
                i=$((i+1))
                ;;
            ')')
                tokens+=("OP:)")
                prev_type="RPAREN"
                i=$((i+1))
                ;;
            *)
                echo "Error: Unexpected character '$c'" >&2
                exit 1
                ;;
        esac
    done
    printf '%s\n' "${tokens[@]}"
}


# ----------------------------------------------------------------------
# Shunting-yard algorithm
# ----------------------------------------------------------------------
precedence() {
    case "$1" in
        '+'|'-') echo 1 ;;
        '*'|'/'|'%') echo 2 ;;
        *) echo 0 ;;
    esac
}

to_rpn() {
    local tokens=("$@")
    local output=()
    local stack=()
    for token in "${tokens[@]}"; do
        local type="${token%%:*}"
        local val="${token#*:}"
        if [ "$type" = "INT" ] || [ "$type" = "FLOAT" ] || [ "$type" = "VAR" ]; then
            output+=("$token")
        elif [ "$type" = "OP" ]; then
            case "$val" in
                '(')
                    stack+=("$token")
                    ;;
                ')')
                    while [ ${#stack[@]} -gt 0 ] && [ "${stack[-1]#*:}" != "(" ]; do
                        output+=("${stack[-1]}")
                        unset 'stack[-1]'
                    done
                    [ ${#stack[@]} -gt 0 ] && unset 'stack[-1]'
                    ;;
                *)
                    local prec=$(precedence "$val")
                    while [ ${#stack[@]} -gt 0 ]; do
                        local top="${stack[-1]}"
                        local top_op="${top#*:}"
                        [ "$top_op" = "(" ] && break
                        local top_prec=$(precedence "$top_op")
                        [ $top_prec -lt $prec ] && break
                        output+=("$top")
                        unset 'stack[-1]'
                    done
                    stack+=("$token")
                    ;;
            esac
        fi
    done
    while [ ${#stack[@]} -gt 0 ]; do
        output+=("${stack[-1]}")
        unset 'stack[-1]'
    done
    printf '%s
' "${output[@]}"
}

# ----------------------------------------------------------------------
# Determine if expression must be evaluated as float
# ----------------------------------------------------------------------
is_float_expression() {
    local tokens=("$@")
    for token in "${tokens[@]}"; do
        local type="${token%%:*}"
        local val="${token#*:}"
        if [ "$type" = "FLOAT" ]; then return 0; fi
        if [ "$type" = "OP" ] && [ "$val" = "/" ]; then return 0; fi
        if [ "$type" = "VAR" ]; then
            local vtype="${VAR_TYPE[$val]}"
            if [ "$vtype" = "float" ]; then return 0; fi
            if [ -z "$vtype" ]; then
                echo "Error: Variable '$val' used before declaration" >&2
                exit 1
            fi
        fi
    done
    return 1
}

# ----------------------------------------------------------------------
# Generate assembly code from RPN tokens
# ----------------------------------------------------------------------
generate_full_asm() {
    local mode="$1"
    local use_float=$2
    shift 2
    local rpn_tokens=("$@")
    local const_idx=0
    local DATA_SECTION=""
    local CODE_SECTION=""
    local uniq_suffix="$$"

    if [[ "$mode" == "declare" ]]; then
        DATA_SECTION+=$'    ; =========================================\n'
        DATA_SECTION+="    ; Variable: $VAR_NAME"$'\n'
        DATA_SECTION+="    ; Expression: $VAR_VALUE"$'\n'
        DATA_SECTION+=$'    ; =========================================\n'
        DATA_SECTION+="    ${VAR_NAME}_defined_flag db 1"$'\n'
        if [ "$use_float" = true ]; then
            DATA_SECTION+="    ${VAR_NAME}_float_val dq 0"$'\n'
            DATA_SECTION+="    ${VAR_NAME}_str times 32 db 0"$'\n'
            DATA_SECTION+="    ${VAR_NAME} dq ${VAR_NAME}_str"$'\n'
            DATA_SECTION+="    ${VAR_NAME}_type dq TYPE_FLOAT"$'\n'
        else
            DATA_SECTION+="    ${VAR_NAME} dq 0"$'\n'
            DATA_SECTION+="    ${VAR_NAME}_float_val dq 0"$'\n'
            DATA_SECTION+="    ${VAR_NAME}_str times 32 db 0"$'\n'
            DATA_SECTION+="    ${VAR_NAME}_type dq TYPE_NUMBER"$'\n'
        fi
    fi

    if [ "$use_float" = true ]; then
        for token in "${rpn_tokens[@]}"; do
            if [[ "$token" == FLOAT:* ]]; then
                local val="${token#*:}"
                if [[ "$mode" == "declare" ]]; then
                    DATA_SECTION+="    ${VAR_NAME}_float${const_idx} dq ${val}"$'\n'
                else
                    DATA_SECTION+="    ${VAR_NAME}_reassign_float${uniq_suffix}_${const_idx} dq ${val}"$'\n'
                fi
                const_idx=$((const_idx+1))
            fi
        done
    fi

    CODE_SECTION+=$'    ; =========================================\n'
    CODE_SECTION+="    ; Runtime evaluation of: $VAR_VALUE"$'\n'
    CODE_SECTION+="    ; Variable: $VAR_NAME"$'\n'
    if [ "$use_float" = true ]; then
        CODE_SECTION+=$'    ; Type: FLOAT (using x87 FPU)\n'
    else
        CODE_SECTION+=$'    ; Type: INTEGER
'
    fi
    CODE_SECTION+=$'    ; =========================================\n'

    const_idx=0
    for token in "${rpn_tokens[@]}"; do
        local type="${token%%:*}"
        local val="${token#*:}"
        if [ "$type" = "INT" ]; then
            if [ "$use_float" = true ]; then
                CODE_SECTION+=$'    ; Push integer '"$val"' and convert to float
'
                CODE_SECTION+="    push $val"$'\n'
                CODE_SECTION+=$'    fild qword [rsp]\n'
                CODE_SECTION+=$'    add rsp, 8
'
            else
                CODE_SECTION+=$'    ; Push integer '"$val"$'\n'
                CODE_SECTION+="    push $val"$'\n'
            fi
        elif [ "$type" = "FLOAT" ]; then
            if [[ "$mode" == "declare" ]]; then
                CODE_SECTION+="    ; Load float constant ${VAR_NAME}_float${const_idx}"$'\n'
                CODE_SECTION+="    fld qword [${VAR_NAME}_float${const_idx}]"$'\n'
            else
                CODE_SECTION+="    ; Load float constant ${VAR_NAME}_reassign_float${uniq_suffix}_${const_idx}"$'\n'
                CODE_SECTION+="    fld qword [${VAR_NAME}_reassign_float${uniq_suffix}_${const_idx}]"$'\n'
            fi
            const_idx=$((const_idx+1))
        elif [ "$type" = "VAR" ]; then
            local var="$val"
            local vtype="${VAR_TYPE[$var]}"
            if [ -z "$vtype" ]; then
                echo "Error: Variable '$var' not defined" >&2
                exit 1
            fi
            if [ "$use_float" = true ]; then
                if [ "$vtype" = "float" ]; then
                    CODE_SECTION+="    ; Load float variable $var"$'\n'
                    CODE_SECTION+="    fld qword [${var}_float_val]"$'\n'
                else
                    CODE_SECTION+="    ; Load integer variable $var and convert to float"$'\n'
                    CODE_SECTION+="    fild qword [${var}]"$'\n'
                fi
            else
                if [ "$vtype" != "int" ]; then
                    echo "Error: Variable '$var' is not an integer (cannot mix types in integer expression)" >&2
                    exit 1
                fi
                CODE_SECTION+="    ; Push integer variable $var"$'\n'
                CODE_SECTION+="    push qword [${var}]"$'\n'
            fi
        elif [ "$type" = "OP" ]; then
            if [ "$use_float" = true ]; then
                case "$val" in
                    '+') CODE_SECTION+=$'    ; Float addition
'
                         CODE_SECTION+=$'    faddp st1, st0
' ;;
                    '-') CODE_SECTION+=$'    ; Float subtraction
'
                         CODE_SECTION+=$'    fsubp st1, st0
' ;;
                    '*') CODE_SECTION+=$'    ; Float multiplication
'
                         CODE_SECTION+=$'    fmulp st1, st0
' ;;
                    '/') CODE_SECTION+=$'    ; Float division
'
                         CODE_SECTION+=$'    fdivp st1, st0
' ;;
                    '%') CODE_SECTION+=$'    ; Float modulo (a % b)\n'
                         CODE_SECTION+=$'    fxch           ; swap st0 and st1 so st0 = a, st1 = b
'
                         CODE_SECTION+=$'    fprem          ; st0 = a % b, st1 = b
'
                         CODE_SECTION+=$'    fstp st1       ; pop b, result in st0
' ;;
                esac
            else
                case "$val" in
                    '+') CODE_SECTION+=$'    ; Integer addition
'
                         CODE_SECTION+=$'    pop rbx
'
                         CODE_SECTION+=$'    pop rax
'
                         CODE_SECTION+=$'    add rax, rbx
'
                         CODE_SECTION+=$'    push rax
' ;;
                    '-') CODE_SECTION+=$'    ; Integer subtraction
'
                         CODE_SECTION+=$'    pop rbx
'
                         CODE_SECTION+=$'    pop rax
'
                         CODE_SECTION+=$'    sub rax, rbx
'
                         CODE_SECTION+=$'    push rax
' ;;
                    '*') CODE_SECTION+=$'    ; Integer multiplication
'
                         CODE_SECTION+=$'    pop rbx
'
                         CODE_SECTION+=$'    pop rax
'
                         CODE_SECTION+=$'    imul rbx
'
                         CODE_SECTION+=$'    push rax
' ;;
                    '/') CODE_SECTION+=$'    ; Integer division
'
                         CODE_SECTION+=$'    pop rbx
'
                         CODE_SECTION+=$'    pop rax
'
                         CODE_SECTION+=$'    cqo            ; sign-extend rax into rdx:rax
'
                         CODE_SECTION+=$'    idiv rbx
'
                         CODE_SECTION+=$'    push rax
' ;;
                    '%') CODE_SECTION+=$'    ; Integer modulo
'
                         CODE_SECTION+=$'    pop rbx
'
                         CODE_SECTION+=$'    pop rax
'
                         CODE_SECTION+=$'    cqo            ; sign-extend rax into rdx:rax
'
                         CODE_SECTION+=$'    idiv rbx
'
                         CODE_SECTION+=$'    push rdx
' ;;
                esac
            fi
        fi
    done

    CODE_SECTION+=$'\n    ; Store result in variable with type tag
'
    if [ "$use_float" = true ]; then
        CODE_SECTION+=$'    ; Store float result
'
        CODE_SECTION+=$'    sub rsp, 8
'
        CODE_SECTION+=$'    fstp qword [rsp]\n'
        CODE_SECTION+=$'    movsd xmm0, [rsp]\n'
        CODE_SECTION+=$'    add rsp, 8
'
        CODE_SECTION+="    movsd [${VAR_NAME}_float_val], xmm0"$'\n'
        CODE_SECTION+="    mov rdi, ${VAR_NAME}_str"$'\n'
        CODE_SECTION+="    movsd xmm0, [${VAR_NAME}_float_val]"$'\n'
        CODE_SECTION+=$'    call float_to_str
'
        CODE_SECTION+="    mov qword [${VAR_NAME}], ${VAR_NAME}_str"$'\n'
        CODE_SECTION+="    mov qword [${VAR_NAME}_type], TYPE_FLOAT"$'\n'
        CODE_SECTION+="    mov byte [${VAR_NAME}_defined_flag], 1"$'\n'
    else
        CODE_SECTION+=$'    ; Store integer result
'
        CODE_SECTION+=$'    pop rax
'
        CODE_SECTION+="    mov [${VAR_NAME}], rax"$'\n'
        CODE_SECTION+="    mov qword [${VAR_NAME}_type], TYPE_NUMBER"$'\n'
        CODE_SECTION+="    mov byte [${VAR_NAME}_defined_flag], 1"$'\n'
    fi

    echo "$DATA_SECTION"
    echo "DATA_CODE_SEPARATOR"
    echo "$CODE_SECTION"
}

# ----------------------------------------------------------------------
# Main logic
# ----------------------------------------------------------------------
DATA_SECTION=""
CODE_SECTION=""
IS_FLOAT=false
FULL_OUTPUT=""
MODE="declare"
if [[ "$REASSIGNMENT" == "true" ]]; then
    MODE="reassign"
fi

# 1) Hex/binary/octal literal handling (always integer)
if [[ "$VAR_VALUE" =~ ^-?0[xX][0-9a-fA-F]+$ ]] || \
   [[ "$VAR_VALUE" =~ ^-?0[bB][01]+$ ]] || \
   [[ "$VAR_VALUE" =~ ^-?0[0-7]+$ ]]; then
    if [[ "$MODE" == "declare" ]]; then
        DATA_SECTION="    ; ========================================="$'\n'
        DATA_SECTION+="    ; Variable: $VAR_NAME = $VAR_VALUE"$'\n'
        DATA_SECTION+="    ; Type: INTEGER (literal)"$'\n'
        DATA_SECTION+="    ; ========================================="$'\n'
        DATA_SECTION+="    ${VAR_NAME}_defined_flag db 1"$'\n'
        DATA_SECTION+="    ${VAR_NAME} dq $VAR_VALUE"$'\n'
        DATA_SECTION+="    ${VAR_NAME}_float_val dq 0"$'\n'
        DATA_SECTION+="    ${VAR_NAME}_str times 32 db 0"$'\n'
        DATA_SECTION+="    ${VAR_NAME}_type dq TYPE_NUMBER"$'\n'
    else
        CODE_SECTION="    ; Reassign integer variable: $VAR_NAME = $VAR_VALUE"$'\n'
        CODE_SECTION+="    mov qword [$VAR_NAME], $VAR_VALUE"$'\n'
        CODE_SECTION+="    mov qword [${VAR_NAME}_type], TYPE_NUMBER"$'\n'
        CODE_SECTION+="    mov byte [${VAR_NAME}_defined_flag], 1"$'\n'
    fi
else
    mapfile -t tokens < <(tokenize "$VAR_VALUE")

    # NEW: Handle single variable-to-variable copy without needing type info
    if [ ${#tokens[@]} -eq 1 ] && [[ "${tokens[0]}" == VAR:* ]]; then
        source_var="${tokens[0]#VAR:}"
        if [[ "$MODE" == "declare" ]]; then
            DATA_SECTION="    ; ========================================="$'\n'
            DATA_SECTION+="    ; Variable: $VAR_NAME = $source_var (copy)"$'\n'
            DATA_SECTION+="    ; ========================================="$'\n'
            DATA_SECTION+="    ${VAR_NAME}_defined_flag db 1"$'\n'
            DATA_SECTION+="    ${VAR_NAME} dq 0"$'\n'
            DATA_SECTION+="    ${VAR_NAME}_float_val dq 0"$'\n'
            DATA_SECTION+="    ${VAR_NAME}_str times 32 db 0"$'\n'
            DATA_SECTION+="    ${VAR_NAME}_type dq TYPE_UNDEFINED"$'\n'
            CODE_SECTION="    ; Copy variable $source_var to $VAR_NAME"$'\n'
            CODE_SECTION+="    mov rax, [${source_var}]"$'\n'
            CODE_SECTION+="    mov [${VAR_NAME}], rax"$'\n'
            CODE_SECTION+="    mov rax, [${source_var}_type]"$'\n'
            CODE_SECTION+="    mov [${VAR_NAME}_type], rax"$'\n'
            CODE_SECTION+="    mov byte [${VAR_NAME}_defined_flag], 1"$'\n'
        else
            # Reassignment copy
            DATA_SECTION=""   # No new data needed
            CODE_SECTION="    ; Reassign variable $VAR_NAME from $source_var"$'\n'
            CODE_SECTION+="    mov rax, [${source_var}]"$'\n'
            CODE_SECTION+="    mov [${VAR_NAME}], rax"$'\n'
            CODE_SECTION+="    mov rax, [${source_var}_type]"$'\n'
            CODE_SECTION+="    mov [${VAR_NAME}_type], rax"$'\n'
            CODE_SECTION+="    mov byte [${VAR_NAME}_defined_flag], 1"$'\n'
        fi
        IS_FLOAT=false  # We don't know; type is copied dynamically
        # Skip the rest of evaluation
        FULL_OUTPUT=""
    elif [ ${#tokens[@]} -eq 1 ]; then
        # Existing single token handling (literal FLOAT or INT)
        token="${tokens[0]}"
        ttype="${token%%:*}"
        tval="${token#*:}"
        if [ "$ttype" = "FLOAT" ]; then
            IS_FLOAT=true
            FLOAT_VAL=$(printf "%.10f" "$tval" 2>/dev/null | sed 's/\.0*$//' || echo "$tval")
            if [[ "$MODE" == "declare" ]]; then
                DATA_SECTION="    ; ========================================="$'\n'
                DATA_SECTION+="    ; Variable: $VAR_NAME = $tval"$'\n'
                DATA_SECTION+="    ; Type: FLOAT (literal)"$'\n'
                DATA_SECTION+="    ; ========================================="$'\n'
                DATA_SECTION+="    ${VAR_NAME}_defined_flag db 1"$'\n'
                DATA_SECTION+="    ${VAR_NAME}_float_val dq 0"$'\n'
                DATA_SECTION+="    ${VAR_NAME}_str times 32 db 0"$'\n'
                DATA_SECTION+="    ${VAR_NAME} dq ${VAR_NAME}_str"$'\n'
                DATA_SECTION+="    ${VAR_NAME}_float dq $FLOAT_VAL"$'\n'
                DATA_SECTION+="    ${VAR_NAME}_type dq TYPE_FLOAT"$'\n'
                CODE_SECTION="    ; Initialize float value at runtime"$'\n'
                CODE_SECTION+="    fld qword [${VAR_NAME}_float]"$'\n'
                CODE_SECTION+="    fstp qword [${VAR_NAME}_float_val]"$'\n'
                CODE_SECTION+="    mov rdi, ${VAR_NAME}_str"$'\n'
                CODE_SECTION+="    movsd xmm0, [${VAR_NAME}_float_val]"$'\n'
                CODE_SECTION+=$'    call float_to_str
'
                CODE_SECTION+="    mov qword [${VAR_NAME}], ${VAR_NAME}_str"$'\n'
                CODE_SECTION+="    mov qword [${VAR_NAME}_type], TYPE_FLOAT"$'\n'
                CODE_SECTION+="    mov byte [${VAR_NAME}_defined_flag], 1"$'\n'
            else
                uniq_suffix="$$"
                DATA_SECTION="    ; Temporary float constant for reassignment"$'\n'
                DATA_SECTION+="    ${VAR_NAME}_reassign_float${uniq_suffix}_0 dq $FLOAT_VAL"$'\n'
                CODE_SECTION="    ; Reassign float variable: $VAR_NAME = $tval"$'\n'
                CODE_SECTION+="    fld qword [${VAR_NAME}_reassign_float${uniq_suffix}_0]"$'\n'
                CODE_SECTION+="    fstp qword [${VAR_NAME}_float_val]"$'\n'
                CODE_SECTION+="    mov rdi, ${VAR_NAME}_str"$'\n'
                CODE_SECTION+="    movsd xmm0, [${VAR_NAME}_float_val]"$'\n'
                CODE_SECTION+=$'    call float_to_str
'
                CODE_SECTION+="    mov qword [${VAR_NAME}], ${VAR_NAME}_str"$'\n'
                CODE_SECTION+="    mov qword [${VAR_NAME}_type], TYPE_FLOAT"$'\n'
                CODE_SECTION+="    mov byte [${VAR_NAME}_defined_flag], 1"$'\n'
            fi
        elif [ "$ttype" = "INT" ]; then
            if [[ "$MODE" == "declare" ]]; then
                DATA_SECTION="    ; ========================================="$'\n'
                DATA_SECTION+="    ; Variable: $VAR_NAME = $tval"$'\n'
                DATA_SECTION+="    ; Type: INTEGER (literal)"$'\n'
                DATA_SECTION+="    ; ========================================="$'\n'
                DATA_SECTION+="    ${VAR_NAME}_defined_flag db 1"$'\n'
                DATA_SECTION+="    ${VAR_NAME} dq $tval"$'\n'
                DATA_SECTION+="    ${VAR_NAME}_float_val dq 0"$'\n'
                DATA_SECTION+="    ${VAR_NAME}_str times 32 db 0"$'\n'
                DATA_SECTION+="    ${VAR_NAME}_type dq TYPE_NUMBER"$'\n'
            else
                CODE_SECTION="    ; Reassign integer variable: $VAR_NAME = $tval"$'\n'
                CODE_SECTION+="    mov qword [$VAR_NAME], $tval"$'\n'
                CODE_SECTION+="    mov qword [${VAR_NAME}_type], TYPE_NUMBER"$'\n'
                CODE_SECTION+="    mov byte [${VAR_NAME}_defined_flag], 1"$'\n'
            fi
        fi
    else
        # Multiple tokens: existing RPN evaluation
        mapfile -t rpn_tokens < <(to_rpn "${tokens[@]}")
        if is_float_expression "${tokens[@]}"; then
            IS_FLOAT=true
            FULL_OUTPUT=$(generate_full_asm "$MODE" true "${rpn_tokens[@]}")
        else
            IS_FLOAT=false
            FULL_OUTPUT=$(generate_full_asm "$MODE" false "${rpn_tokens[@]}")
        fi
        DATA_SECTION=$(echo "$FULL_OUTPUT" | sed -n '1,/DATA_CODE_SEPARATOR/p' | head -n -1)
        CODE_SECTION=$(echo "$FULL_OUTPUT" | sed -n '/DATA_CODE_SEPARATOR/,$p' | tail -n +2)
    fi
fi

# ----------------------------------------------------------------------
# Insert into build_output.asm
# ----------------------------------------------------------------------
TEMP_FILE=$(mktemp)
IN_DATA=0
IN_START=0
DATA_DONE=0
CODE_DONE=0

while IFS= read -r line; do
    if [[ "$line" == "section .data" ]]; then
        IN_DATA=1
    elif [[ "$line" == section* ]] && [ "$IN_DATA" -eq 1 ]; then
        if [ "$DATA_DONE" -eq 0 ] && [ -n "$DATA_SECTION" ]; then
            echo "$DATA_SECTION" >> "$TEMP_FILE"
            DATA_DONE=1
        fi
        IN_DATA=0
    fi

    if [[ "$line" == "_start:" ]]; then
        IN_START=1
    fi

    if [ "$IN_START" -eq 1 ] && [ "$CODE_DONE" -eq 0 ] && \
       [[ "$line" =~ ^[[:space:]]*mov[[:space:]]+rax,[[:space:]]*60 ]] && \
       [ -n "$CODE_SECTION" ]; then
        echo "$CODE_SECTION" >> "$TEMP_FILE"
        CODE_DONE=1
    fi

    echo "$line" >> "$TEMP_FILE"
done < "$OUTPUT_FILE"

if [ "$IN_DATA" -eq 1 ] && [ "$DATA_DONE" -eq 0 ] && [ -n "$DATA_SECTION" ]; then
    echo "$DATA_SECTION" >> "$TEMP_FILE"
fi

if [ "$CODE_DONE" -eq 0 ] && [ -n "$CODE_SECTION" ]; then
    echo "$CODE_SECTION" >> "$TEMP_FILE"
fi

mv "$TEMP_FILE" "$OUTPUT_FILE"

if [ "$IS_FLOAT" = true ]; then
    if [[ "$MODE" == "reassign" ]]; then
        echo "✓ Successfully reassigned float variable: $VAR_NAME = $VAR_VALUE"
    else
        echo "✓ Successfully added float variable: $VAR_NAME = $VAR_VALUE"
    fi
    echo "  - Runtime type tag: TYPE_FLOAT"
    echo "  - All calculations performed at assembly runtime"
else
    if [[ "$MODE" == "reassign" ]]; then
        echo "✓ Successfully reassigned integer variable: $VAR_NAME = $VAR_VALUE"
    else
        echo "✓ Successfully added integer variable: $VAR_NAME = $VAR_VALUE"
    fi
    echo "  - Runtime type tag: TYPE_NUMBER"
    if [ ${#rpn_tokens[@]} -gt 0 ]; then
        echo "  - Expression evaluated at assembly runtime"
    else
        echo "  - Literal value stored directly"
    fi
fi

echo "  - Variable accessible via: mov rax, [$VAR_NAME]"
echo "  - Type accessible via: mov rdx, [${VAR_NAME}_type]"

exit 0
