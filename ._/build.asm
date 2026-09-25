; build.asm – corrected template generator with proper stack alignment
; Numbers and Floats = Gold/Yellow, Booleans = Bright Green
; FIX: output file is now opened with O_TRUNC so an older, longer
;      build_output.asm never leaves stale code after the new template.
; NEW: runtime helpers used by function calls (no new data labels were added,
;      so function.sh's template-data filter keeps working unchanged):
;        rt_to_double       - value/type -> double in xmm0
;        rt_parse_double    - decimal string -> double in xmm0
;        rt_to_double_str   - like rt_to_double, parses TYPE_FLOAT strings
;        rt_capture_result  - makes a function result stable (heap copy)
;        rt_demote_float    - TYPE_FLOAT -> truncated TYPE_NUMBER

section .data
    filename db "./build_output.asm", 0
    template db "section .data", 10
             db "    ; Constants (like JavaScript const)", 10
             db "    ; Example: MAX_SIZE equ 100", 10, 10
             
             db "    ; Global variables (like JavaScript let/var)", 10
             db "    ; Example: counter dq 0", 10
             db "    ; Example: message db 'Hello', 0", 10, 10
             
             db "    ; Function pointers", 10
             db "    ; Example: callback dq 0", 10, 10
             
             db "    ; ANSI Color Codes", 10
             db "    COLOR_RESET   db 27, '[0m', 0", 10
             db "    COLOR_BRIGHT  db 27, '[1m', 0", 10
             db "    COLOR_DARK    db 27, '[2m', 0", 10
             db "    COLOR_GREEN   db 27, '[32m', 0", 10
             db "    COLOR_GRAY    db 27, '[90m', 0   ; Dark gray", 10
             db "    COLOR_BLUE    db 27, '[34m', 0", 10
             db "    COLOR_GOLD    db 27, '[33m', 0   ; Gold/Yellow", 10, 10
             
             db "    ; Type constants for print function", 10
             db "    TYPE_STRING    equ 1", 10
             db "    TYPE_NUMBER    equ 2", 10
             db "    TYPE_CHAR      equ 3", 10
             db "    TYPE_BOOLEAN   equ 4", 10
             db "    TYPE_NULL      equ 5", 10
             db "    TYPE_UNDEFINED equ 6", 10
             db "    TYPE_FLOAT     equ 7", 10, 10
             
             db "    ; Boolean strings", 10
             db "    true_str db 'true', 0", 10
             db "    false_str db 'false', 0", 10
             db "    null_str db 'null', 0", 10
             db "    undefined_str db 'undefined', 0", 10
             db "    hex_prefix db '0x', 0", 10
             db "    float_scale dq 1000000000000000.0", 10
             db "    float_ten dq 10.0", 10, 10
             
             db "    ; Common utility strings", 10
             db "    space db ' ', 0", 10
             db "    newline db 10, 0", 10, 10
             
             db "section .bss", 10
             db "    print_buffer resb 32", 10
             db "    number_buffer resb 32", 10
             db "    temp_number resq 1", 10
             db "    temp_float resq 1", 10
             db "    heap_start resq 1", 10
             db "    heap_current resq 1", 10
             db "    heap_size resq 1", 10, 10
             
             db "section .text", 10
             db "    global _start", 10, 10
             
             db "; ==============================================", 10
             db "; Dynamic Memory Management", 10
             db "; ==============================================", 10, 10
             
             db "init_heap:", 10
             db "    ; Initialize heap with 1MB of memory", 10
             db "    push rbp", 10
             db "    mov rbp, rsp", 10
             db "    sub rsp, 16", 10
             db "    mov rax, 9", 10
             db "    xor rdi, rdi", 10
             db "    mov rsi, 1048576", 10
             db "    mov rdx, 3", 10
             db "    mov r10, 34", 10
             db "    mov r8, -1", 10
             db "    xor r9, r9", 10
             db "    syscall", 10
             db "    test rax, rax", 10
             db "    js .error", 10
             db "    mov [heap_start], rax", 10
             db "    mov [heap_current], rax", 10
             db "    mov qword [heap_size], 1048576", 10
             db "    xor rax, rax", 10
             db "    leave", 10
             db "    ret", 10
             db ".error:", 10
             db "    mov rax, 1", 10
             db "    leave", 10
             db "    ret", 10, 10
             
             db "allocate_string:", 10
             db "    ; Input: rsi = source string (null-terminated)", 10
             db "    ; Output: rax = pointer to allocated copy, 0 on error", 10
             db "    push rbp", 10
             db "    mov rbp, rsp", 10
             db "    push rbx", 10
             db "    push rcx", 10
             db "    push rdx", 10
             db "    push rdi", 10
             db "    push rsi", 10
             db "    push r8", 10
             db "    push r9", 10
             db "    push r10", 10, 10
             
             db "    test rsi, rsi", 10
             db "    jz .error", 10, 10
             
             db "    mov rdi, rsi", 10
             db "    xor rcx, rcx", 10
             db "    not rcx", 10
             db "    xor al, al", 10
             db "    repne scasb", 10
             db "    not rcx", 10
             db "    dec rcx", 10, 10
             
             db "    mov rax, [heap_current]", 10
             db "    add rax, rcx", 10
             db "    add rax, 16", 10
             db "    mov rdx, [heap_start]", 10
             db "    add rdx, [heap_size]", 10
             db "    cmp rax, rdx", 10
             db "    jl .copy_string", 10, 10
             
             db "    mov rax, 9", 10
             db "    xor rdi, rdi", 10
             db "    mov rsi, [heap_size]", 10
             db "    shl rsi, 1", 10
             db "    mov rdx, 3", 10
             db "    mov r10, 34", 10
             db "    mov r8, -1", 10
             db "    xor r9, r9", 10
             db "    syscall", 10
             db "    test rax, rax", 10
             db "    js .error", 10
             db "    mov [heap_start], rax", 10
             db "    mov [heap_current], rax", 10
             db "    mov rax, [heap_size]", 10
             db "    shl rax, 1", 10
             db "    mov [heap_size], rax", 10, 10
             
             db ".copy_string:", 10
             db "    mov rdi, [heap_current]", 10
             db "    mov rbx, rdi", 10
             db ".copy_loop:", 10
             db "    mov al, [rsi]", 10
             db "    mov [rdi], al", 10
             db "    inc rsi", 10
             db "    inc rdi", 10
             db "    test al, al", 10
             db "    jnz .copy_loop", 10, 10
             
             db "    mov [heap_current], rdi", 10
             db "    mov rax, rbx", 10
             db "    jmp .done", 10, 10
             
             db ".error:", 10
             db "    xor rax, rax", 10
             db ".done:", 10
             db "    pop r10", 10
             db "    pop r9", 10
             db "    pop r8", 10
             db "    pop rsi", 10
             db "    pop rdi", 10
             db "    pop rdx", 10
             db "    pop rcx", 10
             db "    pop rbx", 10
             db "    leave", 10
             db "    ret", 10, 10
             
             db "print_raw_string:", 10
             db "    ; Input: rsi = pointer to null-terminated string", 10
             db "    push rbp", 10
             db "    mov rbp, rsp", 10
             db "    push rdi", 10
             db "    push rcx", 10
             db "    push rdx", 10
             db "    push rsi", 10, 10
             
             db "    test rsi, rsi", 10
             db "    jz .done", 10, 10
             
             db "    mov rdi, rsi", 10
             db "    xor rcx, rcx", 10
             db "    not rcx", 10
             db "    xor al, al", 10
             db "    repne scasb", 10
             db "    not rcx", 10
             db "    dec rcx", 10
             db "    test rcx, rcx", 10
             db "    jz .done", 10, 10
             
             db "    mov rax, 1", 10
             db "    mov rdi, 1", 10
             db "    mov rdx, rcx", 10
             db "    syscall", 10, 10
             
             db ".done:", 10
             db "    pop rsi", 10
             db "    pop rdx", 10
             db "    pop rcx", 10
             db "    pop rdi", 10
             db "    leave", 10
             db "    ret", 10, 10
             
             db "print_raw_number:", 10
             db "    ; Input: [temp_number] = number to print", 10
             db "    push rbp", 10
             db "    mov rbp, rsp", 10
             db "    push rbx", 10
             db "    push rcx", 10
             db "    push rdx", 10
             db "    push rsi", 10
             db "    push rdi", 10
             db "    sub rsp, 8", 10, 10
             
             db "    mov rax, [temp_number]", 10
             db "    mov rbx, number_buffer", 10
             db "    add rbx, 30", 10
             db "    mov byte [rbx], 0", 10
             db "    mov rsi, rbx", 10
             db "    dec rsi", 10
             db "    mov rcx, 10", 10
             db "    mov rdi, rsi", 10
             db "    cmp rax, 0", 10
             db "    jge .convert", 10
             db "    neg rax", 10
             db ".convert:", 10
             db "    xor rdx, rdx", 10
             db "    div rcx", 10
             db "    add dl, '0'", 10
             db "    mov [rsi], dl", 10
             db "    dec rsi", 10
             db "    cmp rax, 0", 10
             db "    jne .convert", 10
             db "    inc rsi", 10
             db "    cmp qword [temp_number], 0", 10
             db "    jge .print", 10
             db "    dec rsi", 10
             db "    mov byte [rsi], '-'", 10
             db ".print:", 10
             db "    call print_raw_string", 10
             db "    add rsp, 8", 10
             db "    pop rdi", 10
             db "    pop rsi", 10
             db "    pop rdx", 10
             db "    pop rcx", 10
             db "    pop rbx", 10
             db "    leave", 10
             db "    ret", 10, 10
             
             db "float_to_str:", 10
             db "    ; Convert double in xmm0 to string", 10
             db "    ; Input: xmm0 = value, rdi = output buffer", 10
             db "    push rbp", 10
             db "    mov rbp, rsp", 10
             db "    push rax", 10
             db "    push rbx", 10
             db "    push rcx", 10
             db "    push rdx", 10
             db "    push rsi", 10
             db "    push r8", 10
             db "    push r9", 10
             db "    push r10", 10, 10
             
             db "    ; Clear buffer", 10
             db "    mov rcx, 32", 10
             db "    xor al, al", 10
             db "    rep stosb", 10
             db "    sub rdi, 32", 10, 10
             
             db "    ; Check for negative", 10
             db "    pxor xmm1, xmm1", 10
             db "    comisd xmm0, xmm1", 10
             db "    jae .positive", 10
             db "    mov byte [rdi], '-'", 10
             db "    inc rdi", 10
             db "    movsd xmm2, xmm1", 10
             db "    subsd xmm2, xmm0", 10
             db "    movsd xmm0, xmm2", 10
             db ".positive:", 10, 10
             
             db "    ; Extract integer part", 10
             db "    cvttsd2si r10, xmm0", 10
             db "    cvtsi2sd xmm1, r10", 10
             db "    subsd xmm0, xmm1", 10, 10
             
             db "    ; Convert integer part", 10
             db "    mov rbx, rdi", 10
             db "    mov rax, r10", 10
             db "    mov r8, 10", 10
             db "    test rax, rax", 10
             db "    jnz .int_loop", 10
             db "    mov byte [rdi], '0'", 10
             db "    inc rdi", 10
             db "    jmp .reverse_int", 10
             db ".int_loop:", 10
             db "    test rax, rax", 10
             db "    jz .reverse_int", 10
             db "    xor rdx, rdx", 10
             db "    div r8", 10
             db "    add dl, '0'", 10
             db "    mov [rdi], dl", 10
             db "    inc rdi", 10
             db "    jmp .int_loop", 10
             db ".reverse_int:", 10
             db "    mov rsi, rdi", 10
             db "    dec rsi", 10
             db ".reverse_loop:", 10
             db "    cmp rbx, rsi", 10
             db "    jae .fraction", 10
             db "    mov al, [rbx]", 10
             db "    mov ah, [rsi]", 10
             db "    mov [rbx], ah", 10
             db "    mov [rsi], al", 10
             db "    inc rbx", 10
             db "    dec rsi", 10
             db "    jmp .reverse_loop", 10
             db ".fraction:", 10
             db "    pxor xmm2, xmm2", 10
             db "    comisd xmm0, xmm2", 10
             db "    je .no_fraction", 10
             db "    mov byte [rdi], '.'", 10
             db "    inc rdi", 10
             db "    movsd xmm1, [float_scale]", 10
             db "    mulsd xmm0, xmm1", 10
             db "    cvttsd2si r9, xmm0", 10
             db "    mov rax, r9", 10
             db "    mov r8, 15", 10
             db "    mov r9, 100000000000000", 10
             db ".frac_loop:", 10
             db "    cmp r8, 0", 10
             db "    je .done_with_fraction", 10
             db "    xor rdx, rdx", 10
             db "    div r9", 10
             db "    add al, '0'", 10
             db "    mov [rdi], al", 10
             db "    inc rdi", 10
             db "    mov rax, rdx", 10
             db "    push rax", 10
             db "    xor rdx, rdx", 10
             db "    mov rax, r9", 10
             db "    mov rcx, 10", 10
             db "    div rcx", 10
             db "    mov r9, rax", 10
             db "    pop rax", 10
             db "    dec r8", 10
             db "    jmp .frac_loop", 10
             db ".no_fraction:", 10
             db "    mov byte [rdi], 0", 10
             db "    jmp .exit_float_to_str", 10
             db ".done_with_fraction:", 10
             db "    dec rdi", 10
             db ".remove_zeros:", 10
             db "    cmp byte [rdi], '0'", 10
             db "    jne .check_decimal", 10
             db "    dec rdi", 10
             db "    jmp .remove_zeros", 10
             db ".check_decimal:", 10
             db "    cmp byte [rdi], '.'", 10
             db "    jne .terminate", 10
             db "    dec rdi", 10
             db ".terminate:", 10
             db "    inc rdi", 10
             db "    mov byte [rdi], 0", 10
             db ".exit_float_to_str:", 10
             db "    pop r10", 10
             db "    pop r9", 10
             db "    pop r8", 10
             db "    pop rsi", 10
             db "    pop rdx", 10
             db "    pop rcx", 10
             db "    pop rbx", 10
             db "    pop rax", 10
             db "    leave", 10
             db "    ret", 10, 10
             
             db "print:", 10
             db "    ; Input: rax = value/pointer, rdx = type", 10
             db "    ; Colors: Numbers=Gold, Floats=Gold, Booleans=Bright Green", 10
             db "    push rbp", 10
             db "    mov rbp, rsp", 10
             db "    push rbx", 10
             db "    push rcx", 10
             db "    push rsi", 10
             db "    push rdi", 10, 10
             
             db "    mov rbx, rax", 10
             db "    mov rcx, rdx", 10, 10
             
             db "    cmp rcx, TYPE_STRING", 10
             db "    je .print_string", 10
             db "    cmp rcx, TYPE_NUMBER", 10
             db "    je .print_number", 10
             db "    cmp rcx, TYPE_FLOAT", 10
             db "    je .print_float", 10
             db "    cmp rcx, TYPE_CHAR", 10
             db "    je .print_char", 10
             db "    cmp rcx, TYPE_BOOLEAN", 10
             db "    je .print_boolean", 10
             db "    cmp rcx, TYPE_NULL", 10
             db "    je .print_null", 10
             db "    cmp rcx, TYPE_UNDEFINED", 10
             db "    je .print_undefined", 10
             db "    jmp .done", 10, 10
             
             db ".print_string:", 10
             db "    mov rsi, rbx", 10
             db "    call print_raw_string", 10
             db "    jmp .done", 10, 10
             
             db ".print_number:", 10
             db "    mov [temp_number], rbx", 10
             db "    mov rsi, COLOR_GOLD", 10
             db "    call print_raw_string", 10
             db "    call print_raw_number", 10
             db "    mov rsi, COLOR_RESET", 10
             db "    call print_raw_string", 10
             db "    jmp .done", 10, 10
             
             db ".print_float:", 10
             db "    mov rsi, COLOR_GOLD", 10
             db "    call print_raw_string", 10
             db "    mov rsi, rbx", 10
             db "    call print_raw_string", 10
             db "    mov rsi, COLOR_RESET", 10
             db "    call print_raw_string", 10
             db "    jmp .done", 10, 10
             
             db ".print_char:", 10
             db "    mov [print_buffer], bl", 10
             db "    mov byte [print_buffer + 1], 0", 10
             db "    mov rsi, print_buffer", 10
             db "    call print_raw_string", 10
             db "    jmp .done", 10, 10
             
             db ".print_boolean:", 10
             db "    mov rsi, COLOR_BRIGHT", 10
             db "    call print_raw_string", 10
             db "    mov rsi, COLOR_GREEN", 10
             db "    call print_raw_string", 10
             db "    test rbx, rbx", 10
             db "    jz .print_false", 10
             db "    mov rsi, true_str", 10
             db "    jmp .print_bool", 10
             db ".print_false:", 10
             db "    mov rsi, false_str", 10
             db ".print_bool:", 10
             db "    call print_raw_string", 10
             db "    mov rsi, COLOR_RESET", 10
             db "    call print_raw_string", 10
             db "    jmp .done", 10, 10
             
             db ".print_null:", 10
             db "    mov rsi, COLOR_DARK", 10
             db "    call print_raw_string", 10
             db "    mov rsi, COLOR_GRAY", 10
             db "    call print_raw_string", 10
             db "    mov rsi, null_str", 10
             db "    call print_raw_string", 10
             db "    mov rsi, COLOR_RESET", 10
             db "    call print_raw_string", 10
             db "    jmp .done", 10, 10
             
             db ".print_undefined:", 10
             db "    mov rsi, COLOR_DARK", 10
             db "    call print_raw_string", 10
             db "    mov rsi, COLOR_GRAY", 10
             db "    call print_raw_string", 10
             db "    mov rsi, undefined_str", 10
             db "    call print_raw_string", 10
             db "    mov rsi, COLOR_RESET", 10
             db "    call print_raw_string", 10
             db "    jmp .done", 10, 10
             
             db ".done:", 10
             db "    pop rdi", 10
             db "    pop rsi", 10
             db "    pop rcx", 10
             db "    pop rbx", 10
             db "    leave", 10
             db "    ret", 10, 10
             
             db "; ==============================================", 10
             db "; Runtime helpers for function calls", 10
             db "; ==============================================", 10, 10
             
             db "rt_to_double:", 10
             db "    ; Input: rax = value, rdx = type, xmm0 = double (kept for TYPE_FLOAT)", 10
             db "    ; Output: xmm0 = numeric value as double (rax/rdx preserved)", 10
             db "    cmp rdx, TYPE_FLOAT", 10
             db "    je .done", 10
             db "    cmp rdx, TYPE_NUMBER", 10
             db "    je .from_int", 10
             db "    cmp rdx, TYPE_BOOLEAN", 10
             db "    je .from_int", 10
             db "    pxor xmm0, xmm0", 10
             db "    ret", 10
             db ".from_int:", 10
             db "    cvtsi2sd xmm0, rax", 10
             db ".done:", 10
             db "    ret", 10, 10
             
             db "rt_parse_double:", 10
             db "    ; Input: rsi = pointer to null-terminated decimal string", 10
             db "    ; Output: xmm0 = parsed double (0.0 for a null pointer)", 10
             db "    push rbp", 10
             db "    mov rbp, rsp", 10
             db "    push rax", 10
             db "    push rbx", 10
             db "    push rcx", 10
             db "    push rdx", 10
             db "    push rsi", 10
             db "    push r8", 10
             db "    pxor xmm0, xmm0", 10
             db "    xor rbx, rbx", 10
             db "    test rsi, rsi", 10
             db "    jz .finish", 10
             db "    cmp byte [rsi], '-'", 10
             db "    jne .int_part", 10
             db "    mov rbx, 1", 10
             db "    inc rsi", 10
             db ".int_part:", 10
             db "    movzx rax, byte [rsi]", 10
             db "    cmp rax, '0'", 10
             db "    jb .check_dot", 10
             db "    cmp rax, '9'", 10
             db "    ja .check_dot", 10
             db "    mulsd xmm0, [float_ten]", 10
             db "    sub rax, '0'", 10
             db "    cvtsi2sd xmm1, rax", 10
             db "    addsd xmm0, xmm1", 10
             db "    inc rsi", 10
             db "    jmp .int_part", 10
             db ".check_dot:", 10
             db "    cmp byte [rsi], '.'", 10
             db "    jne .apply_sign", 10
             db "    inc rsi", 10
             db "    xor rcx, rcx", 10
             db "    xor rdx, rdx", 10
             db "    mov r8, 1", 10
             db "    cvtsi2sd xmm2, r8", 10
             db ".frac_loop:", 10
             db "    movzx rax, byte [rsi]", 10
             db "    cmp rax, '0'", 10
             db "    jb .frac_done", 10
             db "    cmp rax, '9'", 10
             db "    ja .frac_done", 10
             db "    cmp rdx, 17", 10
             db "    jae .frac_skip", 10
             db "    imul rcx, rcx, 10", 10
             db "    sub rax, '0'", 10
             db "    add rcx, rax", 10
             db "    mulsd xmm2, [float_ten]", 10
             db "    inc rdx", 10
             db ".frac_skip:", 10
             db "    inc rsi", 10
             db "    jmp .frac_loop", 10
             db ".frac_done:", 10
             db "    cvtsi2sd xmm1, rcx", 10
             db "    divsd xmm1, xmm2", 10
             db "    addsd xmm0, xmm1", 10
             db ".apply_sign:", 10
             db "    test rbx, rbx", 10
             db "    jz .finish", 10
             db "    pxor xmm1, xmm1", 10
             db "    subsd xmm1, xmm0", 10
             db "    movsd xmm0, xmm1", 10
             db ".finish:", 10
             db "    pop r8", 10
             db "    pop rsi", 10
             db "    pop rdx", 10
             db "    pop rcx", 10
             db "    pop rbx", 10
             db "    pop rax", 10
             db "    leave", 10
             db "    ret", 10, 10
             
             db "rt_to_double_str:", 10
             db "    ; Input: rax = value, rdx = type", 10
             db "    ; Output: xmm0 = double (TYPE_FLOAT values are parsed from the string at rax)", 10
             db "    cmp rdx, TYPE_FLOAT", 10
             db "    jne rt_to_double", 10
             db "    push rsi", 10
             db "    mov rsi, rax", 10
             db "    call rt_parse_double", 10
             db "    pop rsi", 10
             db "    ret", 10, 10
             
             db "rt_capture_result:", 10
             db "    ; Input: rax = value, rdx = type, xmm0 = double (valid for TYPE_FLOAT)", 10
             db "    ; Output: rax = stable value (float/string text copied to the heap),", 10
             db "    ;         rdx = type, xmm0 = numeric value as double", 10
             db "    push rbp", 10
             db "    mov rbp, rsp", 10
             db "    push rsi", 10
             db "    sub rsp, 8", 10
             db "    cmp rdx, TYPE_FLOAT", 10
             db "    je .copy_text", 10
             db "    cmp rdx, TYPE_STRING", 10
             db "    je .copy_string", 10
             db "    call rt_to_double", 10
             db "    jmp .done", 10
             db ".copy_string:", 10
             db "    pxor xmm0, xmm0", 10
             db ".copy_text:", 10
             db "    test rax, rax", 10
             db "    jz .done", 10
             db "    mov rsi, rax", 10
             db "    call allocate_string", 10
             db ".done:", 10
             db "    add rsp, 8", 10
             db "    pop rsi", 10
             db "    leave", 10
             db "    ret", 10, 10
             
             db "rt_demote_float:", 10
             db "    ; Input: rax = value, rdx = type, xmm0 = double", 10
             db "    ; Output: a TYPE_FLOAT value becomes a truncated TYPE_NUMBER in rax/rdx", 10
             db "    cmp rdx, TYPE_FLOAT", 10
             db "    jne .done", 10
             db "    cvttsd2si rax, xmm0", 10
             db "    mov rdx, TYPE_NUMBER", 10
             db ".done:", 10
             db "    ret", 10, 10
             
             db "_start:", 10
             db "    ; Initialize heap", 10
             db "    call init_heap", 10, 10
             db "    ; Your code here", 10
             db "    mov rax, 60", 10
             db "    xor rdi, rdi", 10
             db "    syscall", 10
    template_len equ $ - template

section .bss
    fd resq 1

section .text
    global _start

_start:
    ; open("./build_output.asm", O_WRONLY | O_CREAT | O_TRUNC, 0644)
    mov rax, 2
    mov rdi, filename
    mov rsi, 0o1101
    mov rdx, 0o644
    syscall
   
    cmp rax, 0
    jl exit_error
   
    mov [fd], rax

    mov rax, 1
    mov rdi, [fd]
    mov rsi, template
    mov rdx, template_len
    syscall

    mov rax, 3
    mov rdi, [fd]
    syscall

    mov rax, 60
    xor rdi, rdi
    syscall

exit_error:
    mov rax, 60
    mov rdi, 1
    syscall
