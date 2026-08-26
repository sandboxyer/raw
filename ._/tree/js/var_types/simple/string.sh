#!/bin/bash

# string.sh - String declarations and reassignments
# FIXED: Uses dynamic memory allocation via allocate_string

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && cd .. && pwd)"
cd "$SCRIPT_DIR/simple"

OUTPUT_FILE="../../../../build_output.asm"
INPUT_FILE="../../var_input"

REASSIGNMENT="${REASSIGNMENT:-false}"

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

escape_for_nasm() {
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

extract_string_content() {
    local value="$1"
    value=$(echo "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    if [[ "$value" =~ ^\"([^\"]*)\"$ ]]; then
        echo "${BASH_REMATCH[1]}"
        return
    fi
    if [[ "$value" =~ ^\'([^\']*)\'$ ]]; then
        echo "${BASH_REMATCH[1]}"
        return
    fi
    if [[ "$value" =~ \+ ]]; then
        local result=""
        IFS='+' read -ra PARTS <<< "$value"
        for part in "${PARTS[@]}"; do
            part=$(echo "$part" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            if [[ "$part" =~ ^\"([^\"]*)\"$ ]]; then
                result+="${BASH_REMATCH[1]}"
            elif [[ "$part" =~ ^\'([^\']*)\'$ ]]; then
                result+="${BASH_REMATCH[1]}"
            else
                result+="$part"
            fi
        done
        echo "$result"
        return
    fi
    echo "$value"
}

STRING_CONTENT=$(extract_string_content "$VAR_VALUE")
ESCAPED_STRING=$(escape_for_nasm "$STRING_CONTENT")

UNIQUE_ID="str_$(date +%s%N 2>/dev/null || date +%s)_$$"

if [[ "$REASSIGNMENT" == "true" ]]; then
    CODE_SECTION="    ; Reassign string variable: $VAR_NAME"$'\n'
    CODE_SECTION+="    mov rsi, ${UNIQUE_ID}_new_str"$'\n'
    CODE_SECTION+="    call allocate_string"$'\n'
    CODE_SECTION+="    mov [${VAR_NAME}], rax"$'\n'
    CODE_SECTION+="    mov qword [${VAR_NAME}_type], TYPE_STRING"$'\n'
    CODE_SECTION+="    mov byte [${VAR_NAME}_defined_flag], 1"$'\n'

    DATA_SECTION="    ${UNIQUE_ID}_new_str db $ESCAPED_STRING"$'\n'

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

    echo "✓ Successfully reassigned string variable: $VAR_NAME"
    exit 0
fi

# Initial declaration
ASSEMBLY_DATA="    ; ========================================="$'\n'
ASSEMBLY_DATA+="    ; Variable: $VAR_NAME"$'\n'
ASSEMBLY_DATA+="    ; Type: STRING"$'\n'
ASSEMBLY_DATA+="    ; ========================================="$'\n'
ASSEMBLY_DATA+="    ${VAR_NAME}_defined_flag db 1"$'\n'
ASSEMBLY_DATA+="    ${VAR_NAME}_static_str db $ESCAPED_STRING"$'\n'
ASSEMBLY_DATA+="    ${VAR_NAME} dq ${VAR_NAME}_static_str"$'\n'
ASSEMBLY_DATA+="    ${VAR_NAME}_type dq TYPE_STRING"$'\n'

INIT_CODE="    ; Initialize string variable: $VAR_NAME"$'\n'
INIT_CODE+="    mov qword [${VAR_NAME}], ${VAR_NAME}_static_str"$'\n'
INIT_CODE+="    mov qword [${VAR_NAME}_type], TYPE_STRING"$'\n'
INIT_CODE+="    mov byte [${VAR_NAME}_defined_flag], 1"$'\n'

TEMP_FILE=$(mktemp)
IN_DATA=0
IN_START=0
DATA_DONE=0
CODE_DONE=0

while IFS= read -r line; do
    if [[ "$line" == "section .data" ]]; then
        IN_DATA=1
        echo "$line" >> "$TEMP_FILE"
        continue
    fi
    
    if [[ "$IN_DATA" -eq 1 ]] && [[ "$line" == section* ]]; then
        if [ "$DATA_DONE" -eq 0 ]; then
            echo "$ASSEMBLY_DATA" >> "$TEMP_FILE"
            DATA_DONE=1
        fi
        IN_DATA=0
    fi
    
    if [[ "$line" == "_start:" ]]; then
        IN_START=1
    fi
    
    if [ "$IN_START" -eq 1 ] && [ "$CODE_DONE" -eq 0 ] && \
       [[ "$line" =~ ^[[:space:]]*mov[[:space:]]+rax,[[:space:]]*60 ]]; then
        echo "$INIT_CODE" >> "$TEMP_FILE"
        CODE_DONE=1
    fi
    
    echo "$line" >> "$TEMP_FILE"
done < "$OUTPUT_FILE"

if [[ "$IN_DATA" -eq 1 ]] && [ "$DATA_DONE" -eq 0 ]; then
    echo "$ASSEMBLY_DATA" >> "$TEMP_FILE"
fi

if [ "$CODE_DONE" -eq 0 ]; then
    echo "$INIT_CODE" >> "$TEMP_FILE"
fi

mv "$TEMP_FILE" "$OUTPUT_FILE"

echo "✓ Successfully added string variable: $VAR_NAME"
exit 0
