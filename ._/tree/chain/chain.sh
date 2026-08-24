#!/bin/bash

# chain.sh - Processes chain blocks and dispatches to appropriate handlers
# Identifies if chain is a function, if, for, etc. and executes accordingly

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

INPUT_FILE="chain_input"
ARCH_OUTPUT="arch_output"

if [ ! -f "$INPUT_FILE" ]; then
    echo "Error: $INPUT_FILE not found"
    exit 1
fi

# Read the chain content
CHAIN_CONTENT=$(cat "$INPUT_FILE")

# Create arch_output with the chain content for downstream processing
echo "$CHAIN_CONTENT" > "$ARCH_OUTPUT"

# Remove chain tags to get the actual content
CLEAN_CONTENT=$(echo "$CHAIN_CONTENT" | sed '/<chain-start>/d;/<chain-end>/d')

# Get the first meaningful line (skip empty lines)
FIRST_LINE=$(echo "$CLEAN_CONTENT" | grep -v '^[[:space:]]*$' | head -1)

if [ -z "$FIRST_LINE" ]; then
    echo "Error: Empty chain block"
    exit 1
fi

# Trim leading whitespace
FIRST_LINE=$(echo "$FIRST_LINE" | sed 's/^[[:space:]]*//')

echo "Processing chain type: $FIRST_LINE"

# Identify chain type based on first line
if [[ "$FIRST_LINE" =~ ^function[[:space:]] ]]; then
    echo "Detected: Function definition"
    
    # Check for function handler
    if [ -f "./function.sh" ]; then
        echo "Executing function handler..."
        bash ./function.sh "$@"
    elif [ -f "./function" ]; then
        echo "Executing function handler (binary)..."
        ./func "$@"
    else
        echo "Error: Function handler not found (function.sh or function)"
        exit 1
    fi
    
elif [[ "$FIRST_LINE" =~ ^if[[:space:]] ]]; then
    echo "Detected: If statement"
    
    # Check for if handler
    if [ -f "./if.sh" ]; then
        echo "Executing if handler..."
        bash ./if.sh "$@"
    elif [ -f "./if" ]; then
        echo "Executing if handler (binary)..."
        ./if "$@"
    else
        echo "Error: If handler not found (if.sh or if)"
        exit 1
    fi
    
elif [[ "$FIRST_LINE" =~ ^for[[:space:]] ]]; then
    echo "Detected: For loop"
    
    # Check for for handler
    if [ -f "./for.sh" ]; then
        echo "Executing for handler..."
        bash ./for.sh "$@"
    elif [ -f "./for" ]; then
        echo "Executing for handler (binary)..."
        ./for "$@"
    else
        echo "Error: For handler not found (for.sh or for)"
        exit 1
    fi
    
elif [[ "$FIRST_LINE" =~ ^while[[:space:]] ]]; then
    echo "Detected: While loop"
    
    # Check for while handler
    if [ -f "./while.sh" ]; then
        echo "Executing while handler..."
        bash ./while.sh "$@"
    elif [ -f "./while" ]; then
        echo "Executing while handler (binary)..."
        ./while "$@"
    else
        echo "Error: While handler not found (while.sh or while)"
        exit 1
    fi
    
else
    echo "Unknown chain type, treating as generic block"
    
    # For unknown types, just process the content as-is
    # The content is already in arch_output for the next step
    echo "Chain content written to arch_output"
    exit 0
fi

exit $?
