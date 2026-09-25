#!/bin/bash
# function.sh – Converts current build_output.asm into a named function
# Usage: ./function.sh [--call]
# Reads function definition from arch_output file.
# Appends the function to the parent build_output.asm
# Enhanced: Proper variable scoping, string handling, and metadata generation
# FIX: Pre-declare ALL parameters (even without defaults) before Raw.sh
# FIX: apply_renames is context-aware and rewrites bracketed operands,
#      leading data labels, and bare `orig_str` / `orig_float_val` /
#      `orig_defined_flag` tokens used in code (e.g. `mov rdi, quotient_str`).
# FIX: apply_renames now safely short-circuits when there are NO real
#      identifiers to rename (previously it invoked `sed -E` with an empty
#      script, producing a usage error and failing empty-body functions).
# FIX (nested calls / float arguments):
#   - The body is compiled with the types of the DEFAULT values. A function
#     like processValue(a=2,b=3,c=4) is compiled with integer arithmetic, so
#     when it received a float (e.g. the result of scaleAndShift) it used the
#     float's string POINTER as an integer (-> -4211318, 4211822, ...).
#     Now a second "floating-point variant" of the body is compiled (numeric
#     parameters declared as floats) and the function dispatches to it at
#     runtime whenever any argument has TYPE_FLOAT. All-integer calls still
#     run the exact same integer code as before.
#     Set RAWJS_DISABLE_FLOAT_VARIANT=1 to skip the second compilation (float
#     arguments are then truncated to integers instead of being misread).
#   - Every function now returns rax = value, rdx = type AND xmm0 = numeric
#     value as double, so callers keep float results exact.
#   - Functions without `return` now return undefined; integer / boolean /
#     null / undefined literal returns are supported.
#   - `call init_heap` is removed from function bodies (the heap is already
#     initialized in _start; re-initializing on every call leaked 1MB each).
#   - Parameters and the return variable always get value/_type/_float_val
#     labels, so call sites can always write all three.
#   - Data and code are handed to awk through ENVIRON (awk -v would process
#     backslash escapes inside the generated assembly).

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

LOCAL_FILE="./build_output.asm"
PARENT_FILE="../../build_output.asm"
INPUT_FILE="arch_output"
RUN_OUTPUT_FILE="run_output"
RAW_SCRIPT="../../../Raw.sh"
WITH_CALL=0
RAW_WAIT_SECONDS=30

for arg in "$@"; do
    case "$arg" in
        --call) WITH_CALL=1 ;;
        *) echo "Unknown option: $arg"; exit 1 ;;
    esac
done

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
# STEP 0: Parse function definition from arch_output BEFORE Raw.sh
# ----------------------------------------------------------------------
echo "Step 0: Parsing function definition..."

FUNC_LINE=$(grep -o 'function[[:space:]]*[^(]*([^)]*)' "$INPUT_FILE" | head -1)
if [ -z "$FUNC_LINE" ]; then
    echo "Error: No function definition found in $INPUT_FILE"
    exit 1
fi

FUNC_NAME=$(echo "$FUNC_LINE" | sed 's/function[[:space:]]*\([^(]*\)(.*/\1/' | tr -d '[:space:]')
if [ -z "$FUNC_NAME" ]; then
    echo "Error: Could not parse function name"
    exit 1
fi

PARAMS_STR=$(echo "$FUNC_LINE" | sed 's/.*(\(.*\)).*/\1/')
IFS=',' read -ra PARAMS <<< "$PARAMS_STR"

declare -a PNAMES
declare -a PDEFAULTS
declare -a PTYPES

for p in "${PARAMS[@]}"; do
    p=$(echo "$p" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    if [ -z "$p" ]; then continue; fi
   
    if [[ "$p" == *=* ]]; then
        name="${p%%=*}"
        default="${p#*=}"
        name=$(echo "$name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        default=$(echo "$default" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
       
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

INT_PREFIX="${FUNC_NAME}"
FLOAT_PREFIX="${FUNC_NAME}__fv"

# ----------------------------------------------------------------------
# STEP 1: Create run_output (integer variant) and the float variant source
# ----------------------------------------------------------------------
echo "Step 1: Creating run_output from arch_output with parameter declarations..."

awk '
BEGIN { chain_depth = 0; skip_line = 0 }
{
    line = $0
   
    if (line ~ /<chain-start>/) {
        if (chain_depth == 0) {
            line = ""
            skip_line = 1
        }
        chain_depth++
    }
   
    if (line ~ /<chain-end>/) {
        chain_depth--
        if (chain_depth == 0) {
            line = ""
            skip_line = 1
        }
    }
   
    if (line ~ /^[[:space:]]*function[[:space:]]*[^(]*\([^)]*\)/) {
        line = ""
        skip_line = 1
    }
   
    if (!skip_line) {
        print line
    }
   
    skip_line = 0
}
' "$INPUT_FILE" > "$RUN_OUTPUT_FILE.tmp"

BODY_JS="$(cat "$RUN_OUTPUT_FILE.tmp")"
rm -f "$RUN_OUTPUT_FILE.tmp"

INT_DECLS=""
FLOAT_DECLS=""
NEEDS_FLOAT_VARIANT=0

for i in "${!PNAMES[@]}"; do
    name="${PNAMES[$i]}"
    default="${PDEFAULTS[$i]}"
    dtype="${PTYPES[$i]}"
   
    case "$dtype" in
        none)
            int_line="<js-start>    var ${name} = undefined;    <js-end>"
            float_line="<js-start>    var ${name} = 0.0;    <js-end>"
            NEEDS_FLOAT_VARIANT=1
            ;;
        string)
            escaped_default="${default//\"/\\\"}"
            int_line="<js-start>    var ${name} = \"${escaped_default}\";    <js-end>"
            float_line="$int_line"
            ;;
        number)
            int_line="<js-start>    var ${name} = ${default};    <js-end>"
            float_line="<js-start>    var ${name} = ${default}.0;    <js-end>"
            NEEDS_FLOAT_VARIANT=1
            ;;
        float)
            int_line="<js-start>    var ${name} = ${default};    <js-end>"
            float_line="$int_line"
            NEEDS_FLOAT_VARIANT=1
            ;;
        *)
            int_line="<js-start>    var ${name} = ${default};    <js-end>"
            float_line="$int_line"
            ;;
    esac
   
    INT_DECLS+="${int_line}"$'\n'
    FLOAT_DECLS+="${float_line}"$'\n'
done

# Marker statements: everything the float build generates BEFORE the marker
# (e.g. code initializing the float parameter defaults) is removed later, so
# it can never overwrite the arguments passed at call time.
FLOAT_MARKERS="<js-start>    var rawjs_seed_marker = 0;    <js-end>"$'\n'
FLOAT_MARKERS+="<js-start>    var rawjs_body_marker = rawjs_seed_marker*1;    <js-end>"$'\n'

RUN_INT_CONTENT="${INT_DECLS}${BODY_JS}"
RUN_FLOAT_CONTENT="${FLOAT_DECLS}${FLOAT_MARKERS}${BODY_JS}"

printf '%s\n' "$RUN_INT_CONTENT" > "$RUN_OUTPUT_FILE"

if [ ! -s "$RUN_OUTPUT_FILE" ]; then
    echo "Error: Failed to create run_output"
    exit 1
fi

echo "✓ run_output created successfully (with parameter declarations)"
echo ""

# ----------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------
RAW_SCRIPT_ABS="$(cd "$(dirname "$RAW_SCRIPT")" && pwd)/$(basename "$RAW_SCRIPT")"

if [ -f "$RAW_SCRIPT_ABS/.rawjs_private" ] || [ -n "$RAWJS_PRIVATE_MODE" ]; then
    ORIGINAL_RAW=""
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

# Run Raw.sh on the given JS content and wait for ./build_output.asm
run_raw_build() {
    local content="$1"
    local wait_count=0
   
    printf '%s\n' "$content" > "$RUN_OUTPUT_FILE"
    rm -f "$LOCAL_FILE"
   
    if [ -n "$RAWJS_PRIVATE_MODE" ]; then
        if ! env -u RAWJS_PRIVATE_MODE -u RAWJS_PRIVATE_ROOT bash "$RAW_SCRIPT_ABS" --tmp --asm "$RUN_OUTPUT_FILE"; then
            return 1
        fi
    else
        if ! bash "$RAW_SCRIPT_ABS" --tmp --asm "$RUN_OUTPUT_FILE"; then
            return 1
        fi
    fi
   
    while [ ! -f "$LOCAL_FILE" ]; do
        if [ "$wait_count" -ge "$RAW_WAIT_SECONDS" ]; then
            echo "Error: Timeout waiting for build_output.asm to be created"
            return 1
        fi
        sleep 1
        wait_count=$((wait_count + 1))
    done
   
    if [ ! -s "$LOCAL_FILE" ]; then
        echo "Error: build_output.asm is empty"
        return 1
    fi
   
    return 0
}

# Extract user data (EXTRACT_DATA) and _start body (EXTRACT_BODY) from a build
extract_build() {
    local file="$1"
    local line
    local in_data=0
    local in_function=0
    local capture=0
   
    EXTRACT_DATA=""
    EXTRACT_BODY=""
   
    while IFS= read -r line; do
        if [[ "$line" == "section .data" ]]; then
            in_data=1
            continue
        elif [[ "$line" == "section .bss" ]]; then
            in_data=0
            break
        fi
       
        if [ $in_data -eq 1 ]; then
            if echo "$line" | grep -qE '^[[:space:]]*(;|COLOR_|TYPE_|true_str|false_str|null_str|undefined_str|hex_prefix|float_scale|float_ten|space|newline|$)'; then
                continue
            fi
            EXTRACT_DATA+="$line"$'\n'
        fi
    done < "$file"
   
    while IFS= read -r line; do
        if [[ "$line" == "_start:" ]]; then
            in_function=1
            capture=1
            continue
        fi
       
        if [ $in_function -eq 1 ] && echo "$line" | grep -qE '^[[:space:]]*mov[[:space:]]+rax,[[:space:]]*60$'; then
            capture=0
            in_function=0
            continue
        fi
       
        if [ $in_function -eq 0 ] && echo "$line" | grep -qE '^[[:space:]]*(xor|syscall)'; then
            continue
        fi
       
        if [ $capture -eq 1 ]; then
            if echo "$line" | grep -qE '^[[:space:]]*;.*(Your code here|Example usage|mov rax, 42|mov rdx, TYPE_NUMBER|call print|mov rax, newline|mov rdx, TYPE_STRING)'; then
                continue
            fi
            # The heap is initialized once in _start; never re-initialize per call
            if echo "$line" | grep -qE '^[[:space:]]*call[[:space:]]+init_heap[[:space:]]*$'; then
                continue
            fi
            if echo "$line" | grep -qE '^[[:space:]]*;[[:space:]]*Initialize heap[[:space:]]*$'; then
                continue
            fi
            EXTRACT_BODY+="$line"$'\n'
        fi
    done < "$file"
   
    EXTRACT_BODY=$(echo "$EXTRACT_BODY" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
}

# Fill RENAME_IDENTS with parameter names + every var/let/const in content,
# longest first (so `ab` is renamed before `a`)
compute_idents() {
    local content="$1"
    local line pname id
    local -A ident_map=()
   
    RENAME_IDENTS=()
   
    for pname in "${PNAMES[@]}"; do
        if [ -n "$pname" ]; then
            ident_map["$pname"]=1
        fi
    done
   
    while IFS= read -r line; do
        if [[ "$line" =~ (var|let|const)[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*) ]]; then
            ident_map["${BASH_REMATCH[2]}"]=1
        fi
    done <<< "$content"
   
    if [ ${#ident_map[@]} -gt 0 ]; then
        while IFS= read -r id; do
            if [ -n "$id" ] && [[ "$id" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
                RENAME_IDENTS+=("$id")
            fi
        done < <(printf "%s\n" "${!ident_map[@]}" | awk 'NF { print length, $0 }' | sort -rn | cut -d' ' -f2-)
    fi
}

# ----------------------------------------------------------------------
# apply_renames TEXT PREFIX
#
# Renames identifiers (from RENAME_IDENTS) to PREFIX_identifier only where
# they can legitimately appear as a variable name in the generated assembly:
#   1. [orig]              -> [new]
#   2. [orig_suffix]       -> [new_suffix]
#   3. leading data label:  ^\s*orig\s+(db|dq|dd|dw|equ|times|resb|resq|resd|resw)
#   4. leading data label with underscore suffix:  ^\s*orig_
#   5. bare `orig_str` token in code
#   6. bare `orig_float_val` token in code
#   7. bare `orig_defined_flag` token in code
#
# This avoids over-aggressive `\borig\b` substitution which would corrupt
# NASM keywords/instructions like `times` and `add`.
#
# If there is nothing to rename, the input is returned verbatim WITHOUT
# invoking sed, so that empty-body functions like `function opa()` work.
# ----------------------------------------------------------------------
apply_renames() {
    local text="$1"
    local prefix="$2"
    local orig new
    local -a sed_args=()

    if [ -z "$text" ]; then
        printf '%s' ""
        return 0
    fi

    # Nothing to rename: return input verbatim
    if [ ${#RENAME_IDENTS[@]} -eq 0 ]; then
        printf '%s' "$text"
        return 0
    fi

    for orig in "${RENAME_IDENTS[@]}"; do
        if [ -z "$orig" ]; then
            continue
        fi

        new="${prefix}_${orig}"

        # 1. [orig] -> [new]
        sed_args+=(-e "s/\\[${orig}\\]/[${new}]/g")

        # 2. [orig_suffix] -> [new_suffix]
        sed_args+=(-e "s/\\[${orig}_/[${new}_/g")

        # 3. Leading data label with NASM directive
        sed_args+=(-e "s/^([[:space:]]*)${orig}([[:space:]]+(db|dq|dd|dw|equ|times|resb|resq|resd|resw))/\1${new}\2/")

        # 4. Leading data label with underscore suffix
        sed_args+=(-e "s/^([[:space:]]*)${orig}(_)/\1${new}\2/")

        # 5. Bare `orig_str` token in code (not preceded by `[` or word char)
        sed_args+=(-e "s/(^|[^A-Za-z0-9_\\[])${orig}_str([^A-Za-z0-9_]|$)/\1${new}_str\2/g")

        # 6. Bare `orig_float_val` token in code
        sed_args+=(-e "s/(^|[^A-Za-z0-9_\\[])${orig}_float_val([^A-Za-z0-9_]|$)/\1${new}_float_val\2/g")

        # 7. Bare `orig_defined_flag` token in code
        sed_args+=(-e "s/(^|[^A-Za-z0-9_\\[])${orig}_defined_flag([^A-Za-z0-9_]|$)/\1${new}_defined_flag\2/g")
    done

    # Defensive: if somehow sed_args still ended up empty, return verbatim.
    if [ ${#sed_args[@]} -eq 0 ]; then
        printf '%s' "$text"
        return 0
    fi

    printf '%s' "$text" | sed -E "${sed_args[@]}"
    return 0
}

# Remove everything generated before the marker statement in the float body
strip_float_prologue() {
    local body="$1"
    local idx start prev
    local sep_re='^;[[:space:]]*=+'
   
    idx=$(printf '%s\n' "$body" | grep -n 'Runtime evaluation of:.*rawjs_seed_marker' | head -n 1 | cut -d: -f1)
   
    if [ -z "$idx" ]; then
        printf '%s' "$body"
        return 0
    fi
   
    start="$idx"
    if [ "$idx" -gt 1 ]; then
        prev=$(printf '%s\n' "$body" | sed -n "$((idx - 1))p")
        if [[ "$prev" =~ $sep_re ]]; then
            start=$((idx - 1))
        fi
    fi
   
    printf '%s\n' "$body" | tail -n +"$start"
}

# Print every label DEFINED in the given assembly text (data or code labels)
collect_labels() {
    printf '%s\n' "$1" | sed -nE \
        -e 's/^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]+(db|dq|dd|dw|equ|times|resb|resq|resd|resw)([[:space:]].*)?$/\1/p' \
        -e 's/^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*):.*$/\1/p'
}

# Rename one whole label token everywhere in the text
rename_label() {
    local text="$1"
    local old="$2"
    local new="$3"
    printf '%s' "$text" | sed -E \
        -e "s/(^|[^A-Za-z0-9_.])${old}([^A-Za-z0-9_]|$)/\1${new}\2/g" \
        -e "s/(^|[^A-Za-z0-9_.])${old}([^A-Za-z0-9_]|$)/\1${new}\2/g"
}

# Append a data declaration when the label is not declared yet
ensure_data_label() {
    local data="$1"
    local label="$2"
    local decl="$3"
   
    if printf '%s\n' "$data" | grep -qE "^[[:space:]]*${label}[[:space:]]+(db|dq|dd|dw|equ|times|resb|resq|resd|resw)([[:space:]]|$)"; then
        printf '%s' "$data"
    elif [ -z "$data" ]; then
        printf '    %s' "$decl"
    else
        printf '%s\n    %s' "$data" "$decl"
    fi
}

# Guarantee value, _type and _float_val labels for a variable
ensure_value_labels() {
    local data="$1"
    local base="$2"
    data=$(ensure_data_label "$data" "$base" "${base} dq 0")
    data=$(ensure_data_label "$data" "${base}_type" "${base}_type dq TYPE_UNDEFINED")
    data=$(ensure_data_label "$data" "${base}_float_val" "${base}_float_val dq 0")
    printf '%s' "$data"
}

# Is the return expression a variable that needs data labels?
return_is_variable() {
    if [ -z "$RETURN_EXPR" ]; then
        return 1
    fi
    case "$RETURN_EXPR" in
        true|false|null|undefined) return 1 ;;
    esac
    if [[ "$RETURN_EXPR" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
        return 0
    fi
    return 1
}

# Generate the return sequence: rax = value, rdx = type, xmm0 = double
gen_return_code() {
    local prefix="$1"
    local scoped
   
    if [ -z "$RETURN_EXPR" ]; then
        printf '%s\n' "    ; No return statement: returns undefined" \
                      "    xor rax, rax" \
                      "    mov rdx, TYPE_UNDEFINED" \
                      "    pxor xmm0, xmm0"
    elif [[ "$RETURN_EXPR" =~ ^-?[0-9]+$ ]]; then
        printf '%s\n' "    ; Return value: ${RETURN_EXPR}" \
                      "    mov rax, ${RETURN_EXPR}" \
                      "    mov rdx, TYPE_NUMBER" \
                      "    cvtsi2sd xmm0, rax"
    elif [ "$RETURN_EXPR" = "true" ] || [ "$RETURN_EXPR" = "false" ]; then
        if [ "$RETURN_EXPR" = "true" ]; then
            printf '%s\n' "    ; Return value: true" "    mov rax, 1"
        else
            printf '%s\n' "    ; Return value: false" "    xor rax, rax"
        fi
        printf '%s\n' "    mov rdx, TYPE_BOOLEAN" \
                      "    cvtsi2sd xmm0, rax"
    elif [ "$RETURN_EXPR" = "null" ]; then
        printf '%s\n' "    ; Return value: null" \
                      "    xor rax, rax" \
                      "    mov rdx, TYPE_NULL" \
                      "    pxor xmm0, xmm0"
    elif [ "$RETURN_EXPR" = "undefined" ]; then
        printf '%s\n' "    ; Return value: undefined" \
                      "    xor rax, rax" \
                      "    mov rdx, TYPE_UNDEFINED" \
                      "    pxor xmm0, xmm0"
    elif [[ "$RETURN_EXPR" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
        scoped="${prefix}_${RETURN_EXPR}"
        printf '%s\n' "    ; Return value: ${RETURN_EXPR}" \
                      "    mov rax, [${scoped}]" \
                      "    mov rdx, [${scoped}_type]" \
                      "    movsd xmm0, [${scoped}_float_val]" \
                      "    call rt_to_double"
    else
        printf '%s\n' "    ; Return value: ${RETURN_EXPR} (literal not supported)" \
                      "    xor rax, rax" \
                      "    mov rdx, TYPE_UNDEFINED" \
                      "    pxor xmm0, xmm0"
    fi
    printf '%s\n' "    ret"
}

# ----------------------------------------------------------------------
# STEP 2: Run Raw.sh to generate the function bodies
# ----------------------------------------------------------------------
FLOAT_VARIANT_OK=0
FLOAT_DATA_RAW=""
FLOAT_BODY_RAW=""

if [ "$NEEDS_FLOAT_VARIANT" -eq 1 ] && [ "${RAWJS_DISABLE_FLOAT_VARIANT:-0}" != "1" ]; then
    echo "Step 2a: Running Raw.sh to generate the floating-point variant..."
    if run_raw_build "$RUN_FLOAT_CONTENT"; then
        extract_build "$LOCAL_FILE"
        FLOAT_DATA_RAW="$EXTRACT_DATA"
        FLOAT_BODY_RAW="$EXTRACT_BODY"
        FLOAT_VARIANT_OK=1
        echo "✓ Floating-point variant generated successfully"
    else
        echo "⚠ Floating-point variant could not be generated; float arguments will be truncated to integers"
    fi
    echo ""
fi

echo "Step 2: Running Raw.sh to generate function body..."

if ! run_raw_build "$RUN_INT_CONTENT"; then
    echo "Error: Raw.sh failed to generate the function body"
    exit 1
fi

echo "✓ Function body generated successfully"
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
# STEP 5: Extract data and function body from generated build_output.asm
# ----------------------------------------------------------------------
echo "Step 5: Extracting function body..."

extract_build "$LOCAL_FILE"
INT_DATA_RAW="$EXTRACT_DATA"
INT_BODY_RAW="$EXTRACT_BODY"

echo "✓ Function body extracted"
echo ""

# ----------------------------------------------------------------------
# STEP 5.5: Apply variable scoping
# ----------------------------------------------------------------------
echo "Step 5.5: Applying variable scoping..."

# Find return statement
RETURN_EXPR=""
while IFS= read -r line; do
    if [[ "$line" == *"return"* ]]; then
        expr=$(echo "$line" | sed 's/<js-end>.*$//' | sed -n 's/.*return[[:space:]]*\([^;]*\).*/\1/p')
        expr=$(echo "$expr" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        if [ -n "$expr" ]; then
            RETURN_EXPR="$expr"
            break
        fi
    fi
done <<< "$RUN_INT_CONTENT"

# Integer (default) variant
compute_idents "$RUN_INT_CONTENT"
if [ ${#RENAME_IDENTS[@]} -gt 0 ]; then
    INT_DATA=$(apply_renames "$INT_DATA_RAW" "$INT_PREFIX")
    INT_BODY=$(apply_renames "$INT_BODY_RAW" "$INT_PREFIX")
    echo "✓ Renamed ${#RENAME_IDENTS[@]} local identifiers with prefix '${INT_PREFIX}_'"
else
    INT_DATA=$(printf '%s' "$INT_DATA_RAW")
    INT_BODY="$INT_BODY_RAW"
    echo "✓ No local identifiers to rename"
fi

for pname in "${PNAMES[@]}"; do
    INT_DATA=$(ensure_value_labels "$INT_DATA" "${INT_PREFIX}_${pname}")
done
if return_is_variable; then
    INT_DATA=$(ensure_value_labels "$INT_DATA" "${INT_PREFIX}_${RETURN_EXPR}")
fi

# Floating-point variant
FLOAT_DATA=""
FLOAT_BODY=""
if [ "$FLOAT_VARIANT_OK" -eq 1 ]; then
    FLOAT_BODY_RAW=$(strip_float_prologue "$FLOAT_BODY_RAW")
   
    compute_idents "$RUN_FLOAT_CONTENT"
    FLOAT_DATA=$(apply_renames "$FLOAT_DATA_RAW" "$FLOAT_PREFIX")
    FLOAT_BODY=$(apply_renames "$FLOAT_BODY_RAW" "$FLOAT_PREFIX")
    echo "✓ Renamed ${#RENAME_IDENTS[@]} identifiers of the floating-point variant with prefix '${FLOAT_PREFIX}_'"
   
    for pname in "${PNAMES[@]}"; do
        FLOAT_DATA=$(ensure_value_labels "$FLOAT_DATA" "${FLOAT_PREFIX}_${pname}")
    done
    if return_is_variable; then
        FLOAT_DATA=$(ensure_value_labels "$FLOAT_DATA" "${FLOAT_PREFIX}_${RETURN_EXPR}")
    fi
   
    # Any other label defined by both variants (not a scoped variable) would
    # be a duplicate definition in NASM: rename it inside the float variant.
    declare -A INT_LABELS=()
    while IFS= read -r lbl; do
        if [ -n "$lbl" ]; then
            INT_LABELS["$lbl"]=1
        fi
    done < <(collect_labels "${INT_DATA}"$'\n'"${INT_BODY}")
   
    while IFS= read -r lbl; do
        if [ -z "$lbl" ]; then
            continue
        fi
        if [ -n "${INT_LABELS[$lbl]:-}" ]; then
            FLOAT_DATA=$(rename_label "$FLOAT_DATA" "$lbl" "${FLOAT_PREFIX}_dup_${lbl}")
            FLOAT_BODY=$(rename_label "$FLOAT_BODY" "$lbl" "${FLOAT_PREFIX}_dup_${lbl}")
            echo "  - renamed duplicated label '${lbl}' in the floating-point variant"
        fi
    done < <(collect_labels "${FLOAT_DATA}"$'\n'"${FLOAT_BODY}" | sort -u)
fi
echo ""

if [ -n "$RETURN_EXPR" ]; then
    echo "✓ Found return expression: $RETURN_EXPR"
fi

# ----------------------------------------------------------------------
# STEP 5.9: Assemble the final function code
# ----------------------------------------------------------------------
FUNCTION_CODE="${FUNC_NAME}:"$'\n'

if [ "$FLOAT_VARIANT_OK" -eq 1 ]; then
    FUNCTION_CODE+="    ; Runtime dispatch: any TYPE_FLOAT argument selects the floating-point variant"$'\n'
    for pname in "${PNAMES[@]}"; do
        FUNCTION_CODE+="    cmp qword [${INT_PREFIX}_${pname}_type], TYPE_FLOAT"$'\n'
        FUNCTION_CODE+="    je ${FUNC_NAME}__rawjs_float_entry"$'\n'
    done
   
    FUNCTION_CODE+="${FUNC_NAME}__rawjs_int_entry:"$'\n'
    FUNCTION_CODE+="${INT_BODY}"$'\n'
    FUNCTION_CODE+="$(gen_return_code "$INT_PREFIX")"$'\n'
   
    FUNCTION_CODE+="${FUNC_NAME}__rawjs_float_entry:"$'\n'
    FUNCTION_CODE+="    ; Copy arguments into the floating-point variant (numbers converted to double)"$'\n'
    for pname in "${PNAMES[@]}"; do
        FUNCTION_CODE+="    mov rax, [${INT_PREFIX}_${pname}]"$'\n'
        FUNCTION_CODE+="    mov [${FLOAT_PREFIX}_${pname}], rax"$'\n'
        FUNCTION_CODE+="    mov rdx, [${INT_PREFIX}_${pname}_type]"$'\n'
        FUNCTION_CODE+="    mov [${FLOAT_PREFIX}_${pname}_type], rdx"$'\n'
        FUNCTION_CODE+="    movsd xmm0, [${INT_PREFIX}_${pname}_float_val]"$'\n'
        FUNCTION_CODE+="    call rt_to_double"$'\n'
        FUNCTION_CODE+="    movsd [${FLOAT_PREFIX}_${pname}_float_val], xmm0"$'\n'
    done
   
    FUNCTION_CODE+="${FUNC_NAME}__rawjs_float_body:"$'\n'
    FUNCTION_CODE+="${FLOAT_BODY}"$'\n'
    FUNCTION_CODE+="$(gen_return_code "$FLOAT_PREFIX")"$'\n'
elif [ "$NEEDS_FLOAT_VARIANT" -eq 1 ]; then
    FUNCTION_CODE+="    ; No floating-point variant: float arguments are truncated to integers"$'\n'
    for i in "${!PNAMES[@]}"; do
        if [ "${PTYPES[$i]}" = "number" ] || [ "${PTYPES[$i]}" = "none" ]; then
            pname="${PNAMES[$i]}"
            FUNCTION_CODE+="    mov rax, [${INT_PREFIX}_${pname}]"$'\n'
            FUNCTION_CODE+="    mov rdx, [${INT_PREFIX}_${pname}_type]"$'\n'
            FUNCTION_CODE+="    movsd xmm0, [${INT_PREFIX}_${pname}_float_val]"$'\n'
            FUNCTION_CODE+="    call rt_demote_float"$'\n'
            FUNCTION_CODE+="    mov [${INT_PREFIX}_${pname}], rax"$'\n'
            FUNCTION_CODE+="    mov [${INT_PREFIX}_${pname}_type], rdx"$'\n'
        fi
    done
    FUNCTION_CODE+="${INT_BODY}"$'\n'
    FUNCTION_CODE+="$(gen_return_code "$INT_PREFIX")"$'\n'
else
    FUNCTION_CODE+="${INT_BODY}"$'\n'
    FUNCTION_CODE+="$(gen_return_code "$INT_PREFIX")"$'\n'
fi

if [ -n "$FLOAT_DATA" ]; then
    ALL_DATA="${INT_DATA}"$'\n'"${FLOAT_DATA}"
else
    ALL_DATA="$INT_DATA"
fi

echo "✓ Function body with scoped variables prepared"
echo ""

# ----------------------------------------------------------------------
# STEP 6: Append function to parent build_output.asm
# ----------------------------------------------------------------------
echo "Step 6: Appending function to parent build_output.asm..."

TEMP_FILE=$(mktemp)

export RAWJS_ALL_DATA="$ALL_DATA"
export RAWJS_FUNCTION_CODE="$FUNCTION_CODE"

awk -v with_call="$WITH_CALL" '
BEGIN {
    all_data = ENVIRON["RAWJS_ALL_DATA"]
    function_code = ENVIRON["RAWJS_FUNCTION_CODE"]
    inserted_data = 0
    inserted_function = 0
    skip_old_start = 0
}
/^section \.bss/ && !inserted_data {
    if (all_data != "") {
        print all_data
    }
    inserted_data = 1
}
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

unset RAWJS_ALL_DATA
unset RAWJS_FUNCTION_CODE

mv "$TEMP_FILE" "$PARENT_FILE"

echo "✓ Function '$FUNC_NAME' successfully created"
if [ "$FLOAT_VARIANT_OK" -eq 1 ]; then
    echo "✓ Floating-point variant '${FLOAT_PREFIX}' available (runtime dispatch)"
fi
echo ""
echo "All steps completed successfully!"
exit 0
