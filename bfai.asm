%define SYS_READ 0
%define SYS_WRITE 1
%define SYS_OPEN 2
%define SYS_CLOSE 3
; %define SYS_FSTAT 5
%define SYS_MMAP 9
%define SYS_MUNMAP 11
%define SYS_EXIT 60
%define SYS_NEWFSTATAT 0x106

%define STDOUT 0
%define STDIN 1

; Size of the stat struct
%define stat_size 144
%define MAX_MEMORY 65536
%define read_buffer_size 16

section .bss
vm_memory resb MAX_MEMORY
read_buffer resb read_buffer_size

section .data
file_descriptor dd 0
file_contents_ptr dq 0
file_size dq 0

err_invalid_fd db "Unable to open file for reading", 10, 0
err_too_little_args db "Not enough arguments provided", 10, 0
err_failed_mmap db "Failed to map memory for file contents", 10, 0
err_failed_fstat db "Failed to fstat file", 10, 0

section .text

global _start

_start:
    cmp QWORD [rsp], 2                  ; Check argc >= 2
    jl .too_little_args

    ; Open the requested brainfuck file for reading
    mov rdx, 0x180                      ; S_IRUSR | S_IWUSR
    mov rsi, 0                          ; Flags (O_RDONLY)
    mov rdi, [rsp + 16]                 ; Get name of the file from argv
    mov rax, SYS_OPEN
    syscall

    cmp rax, 0                          ; Check if file was successfully opened
    jl .invalid_file_descriptor
    mov DWORD [file_descriptor], eax    ; Save file descriptor for later

    sub rsp, stat_size                  ; Make space on stack for a stat struct

    mov r10, 0                          ; Flags
    mov rdx, rsp                        ; Pointer to stat struct
    mov rsi, [rsp + stat_size + 16]     ; Gets name of the file from argv
    mov rdi, -100                       ; Special value AT_FDCWD
    mov rax, SYS_NEWFSTATAT
    syscall

    cmp rax, -1                         ; Check if fstatat call was successful
    je .failed_fstat

    ; Size of the file is stat.st_size (rsp+48)
    mov rbx, [rsp+48]                   ; Store the file size into rbx
    mov QWORD [file_size], rbx          ; Store the file size for later use

    ; mmap the file into memory
    mov r9, 0                           ; Offset: Start reading at the beginning
    mov r8d, DWORD [file_descriptor]    ; Fd: File descriptor of requested file
    mov r10, 0x2                        ; Flags: MAP_PRIVATE
    mov edx, 0x1                        ; Protection: PROT_READ
    mov rsi, [rsp+48]                   ; Size: Size of file obtained from fstatat
    mov rdi, 0                          ; Hint = NULL
    mov rax, SYS_MMAP
    syscall

    cmp rax, -1                         ; Check that the file contents were successfully mmaped
    je .failed_mmap

    mov [file_contents_ptr], rax        ; Store the pointer to the file contents

    call process_program                ; Run the program

    ; Unmap the file contents once no longer needed
    mov rsi, [file_size]                ; Size of memory to unmap
    mov rdi, [file_contents_ptr]        ; Pointer to memory to unmap
    mov rax, SYS_MUNMAP
    syscall

    ; Close the file as it is no longer needed
    mov rdi, [file_descriptor]          ; File descriptor of file
    mov rax, SYS_CLOSE
    syscall

    call exit_success                   ; Exit the program

    .failed_fstat:
    mov rsi, err_failed_fstat
    call puts
    call exit_failure

    .failed_mmap:
    mov rsi, err_failed_mmap
    call puts
    call exit_failure

    .invalid_file_descriptor:
    mov rsi, err_invalid_fd
    call puts
    call exit_failure

    .too_little_args:
    mov rsi, err_too_little_args
    call puts
    call exit_failure
;

process_program:

    ; r8 will point to the cell that we are currently editing
    mov r8, vm_memory

    ; R9 will be the instruction pointer
    mov r9, [file_contents_ptr]

    ; R10 will hold the address past which execution should stop
    mov r10, r9
    add r10, [file_size]

    ; RCX will hold the count of brackets
    xor rcx, rcx

    .main_loop:

    ; Check what kind of character the IP is currently pointing to

    cmp BYTE [r9], 0x3C ; <
    je .move_left
    cmp BYTE [r9], 0x3E ; >
    je .move_right
    cmp BYTE [r9], 0x2B ; +
    je .increment
    cmp BYTE [r9], 0x2D ; -
    je .decrement
    cmp BYTE [r9], 0x2E ; .
    je .output
    cmp BYTE [r9], 0x2C ; ,
    je .input
    cmp BYTE [r9], 0x5B ; [
    je .loop_begin
    cmp BYTE [r9], 0x5D ; ]
    je .loop_end

    jmp .instruction_after              ; If the character is not an instruction skip it

    .move_left:
    dec r8                              ; Decrement IP
    jmp .instruction_after

    .move_right:
    inc r8                              ; Increment IP
    jmp .instruction_after

    .increment:
    inc BYTE [r8]                       ; Increment the value pointed to by the IP
    jmp .instruction_after

    .decrement:
    dec BYTE [r8]                       ; Decrement the value pointed to by the IP
    jmp .instruction_after

    .output:
    xor rax, rax                        ; Clear RAX
    mov al, BYTE [r8]                   ; Move into al the char to be printed
    call putc                           ; Print the char
    jmp .instruction_after

    .input:
        ; Get input from stdin
        mov rdx, read_buffer_size       ; Number of characters to read
        mov rsi, read_buffer            ; Buffer to store the characters
        mov rdi, STDIN                  ; Read from STDIN
        mov rax, SYS_READ
        syscall

        mov al, [read_buffer]           ; No conversion is needed the value read in is a char

        mov BYTE [r8], al               ; Store the read in value at the IP
        jmp .instruction_after

    .loop_begin:
        cmp BYTE [r8], 0                ; Check if current cell is 0
        jne .instruction_after          ; If no, move to next instruction
        xor rcx, rcx                    ; Clear RCX

        .loop_search_loop_end:
        inc r9                          ; Increment the IP
        
        cmp BYTE [r9], 0x5B ; [         ; Check if the IP points to a [
        jne .skip_bracket_count_inc     ; If no, dont increment bracket depth

        inc rcx                         ; If yes, increment bracket depth and continue searching
        jmp .loop_search_loop_end

        .skip_bracket_count_inc:
        cmp BYTE [r9], 0x5D ; ]         ; Check if the IP points to a ]
        jne .loop_search_loop_end       ; If no, keep searching

        cmp rcx, 0                      ; Check if the bracket depth is 0
        je .instruction_after           ; If yes, move to next instruction

        dec rcx                         ; If not decrement bracket depth and continue searching
        jmp .loop_search_loop_end

    .loop_end:
        cmp BYTE [r8], 0                ; Check if current cell is 0
        je .instruction_after           ; If yes, move to next instruction
        xor rcx, rcx                    ; Clear RCX

        .loop_search_loop_begin:
        dec r9                          ; Decrement the IP
        
        cmp BYTE [r9], 0x5D ; ]         ; Check if the IP points to a ]
        jne .skip_bracket_count_inc_two ; If no, dont increment bracket depth
        
        inc rcx                         ; If yes, increment bracket depth and continue searching
        jmp .loop_search_loop_begin     

        .skip_bracket_count_inc_two:
        cmp BYTE [r9], 0x5B ; [         ; Check if the IP points to a [
        jne .loop_search_loop_begin     ; If no, keep searching

        cmp rcx, 0                      ; Check if the bracket depth is 0
        je .instruction_after           ; If yes, move to next instruction

        dec rcx                         ; If not decrement bracket depth and continue searching
        jmp .loop_search_loop_begin

    .instruction_after:
    inc r9                              ; Increment the IP

    cmp r9, r10                         ; Check if the end of the file has been reached
    jne .main_loop                      ; If no, continue to execute

    mov rax, 0x0A                       ; Move \n into rax
    call putc                           ; Print it

    ret

;
; Returns the length of a string excluding the null terminator
; RAX: Return value, length of string
; RDI: char* string
;
strlen:
    xor rax, rax        ; Zero RAX
    
    .loop_begin:
    cmp BYTE [rdi], 0
    je .end
    inc rax
    inc rdi
    jmp .loop_begin

    .end:
    ret

;
; Prints a string to the screen
; RSI: char* string
;
puts:
    mov rdi, rsi        ; Move char* string into RDI for strlen
    call strlen

    mov rdx, rax        ; Move string length into rdx
    ; RSI set by caller
    mov rdi, STDOUT
    mov rax, SYS_WRITE
    syscall
    ret

;
; Prints a single character to the screen
; RAX: character to print
;
putc:
    dec rsp

    mov BYTE [rsp], al

    mov rdx, 1
    mov rsi, rsp
    mov rdi, STDOUT
    mov rax, SYS_WRITE
    syscall

    inc rsp

    ret

;
; Exits the program with the provided exit code
; RDI: Exit code
;
exit:
    mov rax, SYS_EXIT
    syscall

exit_failure:
    mov rax, SYS_EXIT
    mov rdi, 1
    syscall

exit_success:
    mov rax, SYS_EXIT
    mov rdi, 0
    syscall