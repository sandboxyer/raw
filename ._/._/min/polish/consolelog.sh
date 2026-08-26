#!/bin/bash

# consolelog.sh - Transform complex console.log arguments into variable declarations
# Generates declarations that match the const.sh transformation style

INPUT_FILE="$1"
OUTPUT_FILE="${2:-output.js}"

if [ ! -f "$INPUT_FILE" ]; then
    echo "Usage: $0 <input.js> [output.js]"
    exit 1
fi

CONTENT=$(<"$INPUT_FILE")

# Generate unique variable name matching const.sh style
generate_name() {
    local prefix="${1:-log}"
    prefix=$(echo "$prefix" | tr -cd 'a-zA-Z0-9_')
    if [ -z "$prefix" ]; then prefix="log"; fi
    echo "${prefix}_$(date +%s%N)_${RANDOM}"
}

# Check if argument is simple
is_simple() {
    local arg="$1"
    arg=$(echo "$arg" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    
    # Identifier (covers true, false, null, undefined)
    if echo "$arg" | grep -qE '^[a-zA-Z_$][a-zA-Z0-9_$]*$'; then
        return 0
    fi
    # Number
    if echo "$arg" | grep -qE '^[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?$'; then
        return 0
    fi
    # Single-quoted string
    if echo "$arg" | grep -qE "^'([^'\\]|\\\\.)*'$"; then
        return 0
    fi
    # Double-quoted string
    if echo "$arg" | grep -qE '^"([^"\\]|\\.)*"$'; then
        return 0
    fi
    return 1
}

# Main processing function
process_js() {
    local input="$1"
    local len=${#input}
    local output=""
    local current_pos=0
    
    while (( current_pos < len )); do
        # Skip whitespace and newlines
        while (( current_pos < len )) && [[ "${input:$current_pos:1}" =~ [[:space:]] ]]; do
            output+="${input:$current_pos:1}"
            ((current_pos++))
        done
        
        if (( current_pos >= len )); then
            break
        fi
        
        # Check if we're at the start of console.log
        if [[ "${input:$current_pos:11}" == "console.log" ]]; then
            # Check if it's not part of a larger identifier
            local prev_char=""
            if (( current_pos > 0 )); then
                prev_char="${input:$((current_pos-1)):1}"
            fi
            
            if [[ "$prev_char" =~ [a-zA-Z0-9_$] ]]; then
                # Part of larger identifier, skip
                output+="${input:$current_pos:1}"
                ((current_pos++))
                continue
            fi
            
            # Find the opening parenthesis
            local paren_pos=$((current_pos + 11))
            while (( paren_pos < len )) && [[ "${input:$paren_pos:1}" =~ [[:space:]] ]]; do
                paren_pos=$((paren_pos + 1))
            done
            
            if [[ "${input:$paren_pos:1}" != "(" ]]; then
                # Not a function call, just copy
                output+="${input:$current_pos:11}"
                current_pos=$((current_pos + 11))
                continue
            fi
            
            # Find matching closing parenthesis
            local close_paren=$((paren_pos + 1))
            local depth=1
            local in_string=0
            local string_char=""
            
            while (( close_paren < len )); do
                local c="${input:$close_paren:1}"
                
                if (( in_string )); then
                    if [[ "$c" == "$string_char" && "${input:$((close_paren-1)):1}" != "\\" ]]; then
                        in_string=0
                    fi
                else
                    if [[ "$c" == "'" || "$c" == '"' || "$c" == '`' ]]; then
                        in_string=1
                        string_char="$c"
                    elif [[ "$c" == "(" ]]; then
                        ((depth++))
                    elif [[ "$c" == ")" ]]; then
                        ((depth--))
                        if (( depth == 0 )); then
                            break
                        fi
                    fi
                fi
                ((close_paren++))
            done
            
            if (( close_paren >= len )); then
                # No closing parenthesis found
                output+="${input:$current_pos:11}"
                current_pos=$((current_pos + 11))
                continue
            fi
            
            # Extract the argument
            local args="${input:$((paren_pos+1)):$((close_paren - paren_pos - 1))}"
            local trimmed_args="$(echo "$args" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
            
            # Check if it contains comma (multiple arguments)
            if [[ "$trimmed_args" == *","* ]]; then
                # Copy as-is
                output+="${input:$current_pos:$((close_paren - current_pos + 1))}"
                current_pos=$((close_paren + 1))
                continue
            fi
            
            # Check if simple
            if is_simple "$trimmed_args"; then
                # Copy as-is
                output+="${input:$current_pos:$((close_paren - current_pos + 1))}"
                current_pos=$((close_paren + 1))
                continue
            fi
            
            # Complex argument - generate declaration
            local name=$(generate_name "log")
            local declaration="const ${name} = ${trimmed_args};"
            
            # Write declaration and console.log
            output+="$declaration"$'\n'
            output+="console.log(${name})"
            
            # Move past the closing parenthesis
            current_pos=$((close_paren + 1))
            
            # Check for semicolon after
            while (( current_pos < len )) && [[ "${input:$current_pos:1}" =~ [[:space:]] ]]; do
                output+="${input:$current_pos:1}"
                ((current_pos++))
            done
            
            if [[ "${input:$current_pos:1}" == ";" ]]; then
                output+=";"
                ((current_pos++))
            fi
            
            continue
        fi
        
        # Regular character, copy to output
        output+="${input:$current_pos:1}"
        ((current_pos++))
    done
    
    echo "$output"
}

# Execute transformation
RESULT=$(process_js "$CONTENT")
echo "$RESULT" > "$OUTPUT_FILE"
echo "Transformation complete. Output saved to $OUTPUT_FILE"