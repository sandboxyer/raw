#!/bin/bash

# log.sh - Parses console.log() statements and generates assembly print calls
# FIXED: Simplified variable printing (no complex runtime type checks)
# FIXED: Proper UTF-8 support using hexdump

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

OUTPUT_FILE="../../../build_output.asm"
INPUT_FILE="log_input"

if [ ! -f "$INPUT_FILE" ]; then
    echo "Error: $INPUT_FILE not found"
    exit 1
fi

LOG_STMT=$(cat "$INPUT_FILE" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
LOG_STMT="${LOG_STMT%;}"

if [[ "$LOG_STMT" =~ console\.log\((.*)\) ]]; then
    CONTENT="${BASH_REMATCH[1]}"
else
    echo "Error: Invalid console.log format"
    exit 1
fi

LOG_ID="log_$(date +%s%N 2>/dev/null || date +%s)_$(od -An -N4 -tu4 /dev/urandom 2>/dev/null | tr -d ' ' || echo $$)"

# ----------------------------------------------------------------------
# Escape string for NASM with proper UTF-8 support
# ----------------------------------------------------------------------
escape_string() {
    local str="$1"
    
    if [ -z "$str" ]; then
        echo "0"
        return
    fi
    
    # Handle escape sequences first
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
    
    # Use hexdump to get exact byte values
    local bytes=$(printf "%s" "$processed" | hexdump -v -e '1/1 "%d, "')
    
    bytes="${bytes%, }"
    
    if [ -n "$bytes" ]; then
        echo "${bytes}, 0"
    else
        echo "0"
    fi
}

# ----------------------------------------------------------------------
# Parse arguments
# ----------------------------------------------------------------------
parse_args() {
    local args=()
    local current=""
    local in_quote=false
    local quote_char=""
    local i=0
    
    while [ $i -lt ${#CONTENT} ]; do
        local c="${CONTENT:$i:1}"
        
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

# ----------------------------------------------------------------------
# Generate string constants
# ----------------------------------------------------------------------
generate_strings() {
    local args=("$@")
    local strings=""
    local idx=0
    
    for arg in "${args[@]}"; do
        if [[ "$arg" =~ ^\".*\"$ ]] || [[ "$arg" =~ ^\'.*\'$ ]]; then
            local stripped="${arg:1:${#arg}-2}"
            local escaped=$(escape_string "$stripped")
            strings="${strings}    ${LOG_ID}_str${idx} db ${escaped}"$'\n'
        elif [[ "$arg" =~ ^-?[0-9]*\.[0-9]+$ ]] || [[ "$arg" =~ ^-?[0-9]+[eE][-+]?[0-9]+$ ]]; then
            local fval=$(echo "scale=10; $arg" | bc 2>/dev/null | sed 's/\.\?0\+$//')
            strings="${strings}    ${LOG_ID}_float${idx} db '${fval}', 0"$'\n'
        fi
        idx=$((idx+1))
    done
    
    echo "$strings"
}

# ----------------------------------------------------------------------
# Generate print code - SIMPLIFIED (original working approach)
# ----------------------------------------------------------------------
gen_print() {
    local arg="$1"
    local idx="$2"
    
    # Handle literals
    case "$arg" in
        true)
            echo "    mov rax, 1"
            echo "    mov rdx, TYPE_BOOLEAN"
            echo "    call print"
            return
            ;;
        false)
            echo "    mov rax, 0"
            echo "    mov rdx, TYPE_BOOLEAN"
            echo "    call print"
            return
            ;;
        null)
            echo "    mov rax, 0"
            echo "    mov rdx, TYPE_NULL"
            echo "    call print"
            return
            ;;
        undefined)
            echo "    mov rax, 0"
            echo "    mov rdx, TYPE_UNDEFINED"
            echo "    call print"
            return
            ;;
    esac
    
    # Handle string literals
    if [[ "$arg" =~ ^\".*\"$ ]] || [[ "$arg" =~ ^\'.*\'$ ]]; then
        echo "    mov rax, ${LOG_ID}_str${idx}"
        echo "    mov rdx, TYPE_STRING"
        echo "    call print"
        return
    fi
    
    # Handle numeric literals (integers)
    if [[ "$arg" =~ ^-?[0-9]+$ ]]; then
        echo "    mov rax, $arg"
        echo "    mov rdx, TYPE_NUMBER"
        echo "    call print"
        return
    fi
    
    # Handle float literals
    if [[ "$arg" =~ ^-?[0-9]*\.[0-9]+$ ]] || [[ "$arg" =~ ^-?[0-9]+[eE][-+]?[0-9]+$ ]]; then
        echo "    mov rax, ${LOG_ID}_float${idx}"
        echo "    mov rdx, TYPE_FLOAT"
        echo "    call print"
        return
    fi
    
    # For VARIABLES - SIMPLE ORIGINAL APPROACH
    # [var] contains pointer for strings/floats, value for numbers
    echo "    ; Print variable '${arg}'"
    echo "    mov rax, [${arg}]            ; Load value or pointer"
    echo "    mov rdx, [${arg}_type]       ; Load type"
    echo "    call print"
}

# ----------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------
mapfile -t ARGS < <(parse_args)

STRING_CONSTANTS=$(generate_strings "${ARGS[@]}")

# Generate print code
PRINT_CODE=""
if [ ${#ARGS[@]} -eq 0 ]; then
    PRINT_CODE="${PRINT_CODE}    mov rax, newline"$'\n'
    PRINT_CODE="${PRINT_CODE}    mov rdx, TYPE_STRING"$'\n'
    PRINT_CODE="${PRINT_CODE}    call print"$'\n'
else
    for i in "${!ARGS[@]}"; do
        PRINT_CODE="${PRINT_CODE}$(gen_print "${ARGS[$i]}" "$i")"$'\n'
        if [ $i -lt $((${#ARGS[@]} - 1)) ]; then
            PRINT_CODE="${PRINT_CODE}    mov rax, space"$'\n'
            PRINT_CODE="${PRINT_CODE}    mov rdx, TYPE_STRING"$'\n'
            PRINT_CODE="${PRINT_CODE}    call print"$'\n'
        fi
    done
    PRINT_CODE="${PRINT_CODE}    mov rax, newline"$'\n'
    PRINT_CODE="${PRINT_CODE}    mov rdx, TYPE_STRING"$'\n'
    PRINT_CODE="${PRINT_CODE}    call print"$'\n'
fi

# ----------------------------------------------------------------------
# Insert into file
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
        echo "$PRINT_CODE" >> "$TEMP_FILE"
        CODE_DONE=1
    fi
    
    echo "$line" >> "$TEMP_FILE"
done < "$OUTPUT_FILE"

if [ "$IN_DATA" -eq 1 ] && [ "$DATA_DONE" -eq 0 ] && [ -n "$STRING_CONSTANTS" ]; then
    echo "$STRING_CONSTANTS" >> "$TEMP_FILE"
fi

if [ "$CODE_DONE" -eq 0 ] && [ -n "$PRINT_CODE" ]; then
    echo "$PRINT_CODE" >> "$TEMP_FILE"
fi

mv "$TEMP_FILE" "$OUTPUT_FILE"

echo "Successfully appended console.log($CONTENT)"
exit 0
