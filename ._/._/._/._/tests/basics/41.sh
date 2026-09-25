#!/bin/bash

# Self-extracting JavaScript file generator
# This script will recreate the original JavaScript file

set -e

# Get the original filename from the script name
SCRIPT_NAME="$(basename "$0")"
OUTPUT_FILE="${SCRIPT_NAME%.*}.js"

# Auto-overwrite if file exists (no prompt)
if [ -f "$OUTPUT_FILE" ]; then
    echo "Overwriting existing file: $OUTPUT_FILE"
fi

# Find where the embedded data starts
# Look for the base64 data after the marker
SCRIPT_END_MARKER="#===BEGIN_BASE64_DATA==="

# Get the line number of the marker
MARKER_LINE=$(grep -n "^${SCRIPT_END_MARKER}$" "$0" | cut -d: -f1)

if [ -z "$MARKER_LINE" ]; then
    echo "Error: Could not find embedded data marker" >&2
    exit 1
fi

# Extract the base64 data (starts after the marker)
DATA_START_LINE=$((MARKER_LINE + 1))

# Get all lines from the data start to end of file
# and decode from base64
# Compatible with both GNU base64 (--decode) and BusyBox base64 (-d)
tail -n +"${DATA_START_LINE}" "$0" | base64 -d > "$OUTPUT_FILE" 2>/dev/null || \
tail -n +"${DATA_START_LINE}" "$0" | base64 --decode > "$OUTPUT_FILE"

# Verify extraction
if [ $? -eq 0 ] && [ -f "$OUTPUT_FILE" ]; then
    echo "Successfully created: $OUTPUT_FILE"
    echo "Size: $(wc -c < "$OUTPUT_FILE") bytes"
    
    # Make executable if it starts with shebang
    if head -n1 "$OUTPUT_FILE" | grep -q "^#!"; then
        chmod +x "$OUTPUT_FILE"
        echo "Made executable (has shebang)"
    fi
else
    echo "Error: Failed to extract JavaScript file" >&2
    exit 1
fi

exit 0

#===BEGIN_BASE64_DATA===
Ly8gRnVuY3Rpb25zIHdpdGggdmFyaWVkIHBhcmFtZXRlciBwYXR0ZXJucyBhbmQgb3BlcmF0aW9u
cwpmdW5jdGlvbiBwcm9jZXNzVmFsdWUoYSA9IDIsIGIgPSAzLCBjID0gNCkgewogIGxldCB0b3Rh
bCA9IGEgKiBiICsgYwogIHJldHVybiB0b3RhbAp9CgpmdW5jdGlvbiB0cmFuc2Zvcm0oeCA9IDUs
IHkgPSAyLCB6ID0gMywgdyA9IDEpIHsKICBsZXQgcmVzdWx0ID0gKHggKyB5KSAqICh6IC0gdykK
ICByZXR1cm4gcmVzdWx0Cn0KCmZ1bmN0aW9uIHNjYWxlQW5kU2hpZnQobnVtID0gNiwgc2NhbGUg
PSAyLCBzaGlmdCA9IDMsIGRpdmlkZSA9IDIpIHsKICBsZXQgb3V0cHV0ID0gKG51bSAqIHNjYWxl
ICsgc2hpZnQpIC8gZGl2aWRlCiAgcmV0dXJuIG91dHB1dAp9CgpmdW5jdGlvbiBhZ2dyZWdhdGUo
cCA9IDEsIHEgPSAyLCByID0gMykgewogIGxldCB2YWx1ZSA9IHAgKiBxIC0gcgogIHJldHVybiB2
YWx1ZQp9CgovLyBTaW1wbGUgY2FsbHMgd2l0aCBkaWZmZXJlbnQgYXJndW1lbnRzCmNvbnNvbGUu
bG9nKHByb2Nlc3NWYWx1ZSg1LCAyLCAzKSkKbGV0IGluaXRpYWwgPSB0cmFuc2Zvcm0oNCwgMywg
NSwgMikKY29uc29sZS5sb2coaW5pdGlhbCkKCi8vIFR3by1sZXZlbCBuZXN0aW5nIHdpdGggbXVs
dGlwbGUgYXJndW1lbnRzCmNvbnNvbGUubG9nKHNjYWxlQW5kU2hpZnQocHJvY2Vzc1ZhbHVlKDMs
IDQsIDIpLCB0cmFuc2Zvcm0oMiwgMywgNCwgMSksIDUsIDMpKQpjb25zb2xlLmxvZyhhZ2dyZWdh
dGUodHJhbnNmb3JtKDYsIDIsIDMsIDEpLCBwcm9jZXNzVmFsdWUoNCwgMiwgNSksIHNjYWxlQW5k
U2hpZnQoMywgMiwgNCwgMikpKQoKLy8gVGhyZWUtbGV2ZWwgbmVzdGluZwpjb25zb2xlLmxvZyhw
cm9jZXNzVmFsdWUoCiAgdHJhbnNmb3JtKHNjYWxlQW5kU2hpZnQoNCwgMywgMiwgMiksIDIsIDUs
IDEpLAogIGFnZ3JlZ2F0ZShwcm9jZXNzVmFsdWUoMiwgMywgNCksIHRyYW5zZm9ybSgzLCAyLCA0
LCAxKSwgMiksCiAgc2NhbGVBbmRTaGlmdCh0cmFuc2Zvcm0oMywgMiwgNSwgMSksIDIsIDMsIDIp
CikpCgpjb25zb2xlLmxvZyh0cmFuc2Zvcm0oCiAgc2NhbGVBbmRTaGlmdCgKICAgIHByb2Nlc3NW
YWx1ZSg1LCAzLCAyKSwKICAgIGFnZ3JlZ2F0ZSg0LCAzLCAyKSwKICAgIDYsIDMKICApLAogIHBy
b2Nlc3NWYWx1ZSgKICAgIHRyYW5zZm9ybSgyLCAzLCA0LCAxKSwKICAgIHNjYWxlQW5kU2hpZnQo
MywgMiwgNSwgMiksCiAgICA3CiAgKSwKICBhZ2dyZWdhdGUoCiAgICBzY2FsZUFuZFNoaWZ0KDYs
IDIsIDMsIDIpLAogICAgdHJhbnNmb3JtKDQsIDIsIDMsIDEpLAogICAgNQogICksCiAgcHJvY2Vz
c1ZhbHVlKDMsIDQsIDIpCikpCgovLyBGb3VyLWxldmVsIGFuZCBmaXZlLWxldmVsIG5lc3RpbmcK
Y29uc29sZS5sb2coYWdncmVnYXRlKAogIHRyYW5zZm9ybSgKICAgIHNjYWxlQW5kU2hpZnQoCiAg
ICAgIHByb2Nlc3NWYWx1ZSgKICAgICAgICB0cmFuc2Zvcm0oMiwgMywgNSwgMSksCiAgICAgICAg
NCwgMwogICAgICApLAogICAgICBhZ2dyZWdhdGUoNSwgMywgMiksCiAgICAgIDQsIDIKICAgICks
CiAgICBwcm9jZXNzVmFsdWUoMywgMiwgNSksCiAgICBzY2FsZUFuZFNoaWZ0KDQsIDIsIDMsIDIp
LAogICAgMgogICksCiAgcHJvY2Vzc1ZhbHVlKAogICAgc2NhbGVBbmRTaGlmdCgKICAgICAgdHJh
bnNmb3JtKDMsIDQsIDYsIDIpLAogICAgICBhZ2dyZWdhdGUoMiwgMywgMSksCiAgICAgIDUsIDMK
ICAgICksCiAgICB0cmFuc2Zvcm0oMiwgMywgNCwgMSksCiAgICBhZ2dyZWdhdGUoNCwgMiwgMykK
ICApLAogIHRyYW5zZm9ybSgKICAgIGFnZ3JlZ2F0ZSgKICAgICAgcHJvY2Vzc1ZhbHVlKDIsIDUs
IDMpLAogICAgICBzY2FsZUFuZFNoaWZ0KDMsIDQsIDIsIDIpLAogICAgICA0CiAgICApLAogICAg
MywgMiwgNSwgMQogICkKKSkKCg==
