// ============================================================================
// macOS ARM64 (Apple Silicon) Word Count (wc) Clone - Pure System Call Version
// Assembler: GNU Assembler (GAS) syntax
// ============================================================================

.global _main
.align 2

// --- macOS ARM64 System Call Numbers (passed in register x16) ---
.equ SYS_exit,  1       // Terminate the process
.equ SYS_read,  3       // Read from a file descriptor
.equ SYS_write, 4       // Write to a file descriptor (1 = stdout)
.equ SYS_open,  5       // Open a file path
.equ SYS_close, 6       // Close a file descriptor

// --- File Access Flags ---
.equ O_RDONLY,  0       // Open for reading only

.data
// Output template string for our custom printing routine
out_msg:    .ascii  "Lines: "
line_buf:   .space  20      // Buffer for converted line count string
            .ascii  ", Words: "
word_buf:   .space  20      // Buffer for converted word count string
            .ascii  ", Chars: "
char_buf:   .space  20      // Buffer for converted char count string
            .ascii  "\n"
out_end:                    // Label to calculate total string length easily

.bss
.lcomm buffer, 4096        // Reserve a 4KB chunk in memory for file reading buffer

.text
_main:
    // ========================================================================
    // STEP 1: Parse Command-Line Arguments from Registers
    // When clang launches _main, x0 contains argc and x1 contains argv pointer.
    // ========================================================================
    cmp     x0, #2                  // Check if argc < 2 (missing file argument)
    b.lt    err_argc                // If less than 2, exit with error code 1

    ldr     x1, [x1, #8]            // Load argv[1] (pointer to the filename string)
    mov     x19, x1                 // Safely store filename pointer in callee-saved x19

    // ========================================================================
    // STEP 2: Open the File via Raw System Call (SYS_open = 5)
    // x0 = path pointer, x1 = flags (O_RDONLY), x16 = 5, svc #0x80
    // ========================================================================
    mov     x0, x19                 // Argument 1: Path string pointer
    mov     x1, #O_RDONLY           // Argument 2: Read-only access flag (0)
    mov     x2, #0                  // Argument 3: Mode (unused for opening existing files)
    mov     x16, #SYS_open          // Load open system call number (5) into x16
    svc     #0x80                   // Trigger kernel supervisor call
    
    // Check if the system call failed (macOS sets the carry flag, x0 holds the error code)
    b.cs    err_open                // If carry set, jump to error handler
    mov     x19, x0                 // Save the returned valid File Descriptor (FD) in x19

    // ========================================================================
    // STEP 3: Initialize Counting Accumulators
    // ========================================================================
    mov     x20, #0                 // x20 = Total Line Count
    mov     x21, #0                 // x21 = Total Word Count
    mov     x22, #0                 // x22 = Total Character Count
    mov     w23, #1                 // w23 = In-word state flag (1 = outside word, 0 = inside)

read_loop:
    // ========================================================================
    // STEP 4: Read a Chunk of the File via System Call (SYS_read = 3)
    // ========================================================================
    mov     x0, x19                 // Argument 1: File descriptor
    adrp    x1, buffer@PAGE         // Load page address of our 4KB buffer
    add     x1, x1, buffer@PAGEOFF  // Add page offset to get absolute buffer pointer
    mov     x2, #4096               // Argument 2: Maximum number of bytes to read
    mov     x16, #SYS_read          // Load read system call number (3) into x16
    svc     #0x80                   // Trigger kernel read

    b.cs    err_open                // If carry set, a read error occurred
    cbz     x0, finish_read         // If x0 == 0, we reached End-Of-File (EOF)

    mov     x4, x0                  // Store actual bytes read in x4 as chunk loop counter
    adrp    x1, buffer@PAGE         // Reset pointer x1 back to start of buffer
    add     x1, x1, buffer@PAGEOFF

process_buffer:
    ldrb    w5, [x1], #1            // Load single byte into w5, post-increment pointer x1 by 1
    add     x22, x22, #1            // Increment total character count (x22) by 1

    // --- Check for Newline (\n = 0x0A) ---
    cmp     w5, #0x0A
    b.ne    check_space
    add     x20, x20, #1            // Increment line count (x20) by 1

check_space:
    // --- Check for Whitespace (' ', '\t', '\n', '\r') ---
    cmp     w5, #' '                // Space
    b.eq    is_space
    cmp     w5, #0x09               // Horizontal Tab
    b.eq    is_space
    cmp     w5, #0x0A               // Newline
    b.eq    is_space
    cmp     w5, #0x0D               // Carriage Return
    b.eq    is_space

    // --- Non-Whitespace Character Found ---
    cbnz    w23, new_word           // If out-of-word flag is 1, we found a new word start
    b       next_byte               // Otherwise, continue inside current word

new_word:
    add     x21, x21, #1            // Increment word count (x21) by 1
    mov     w23, #0                 // Set in-word flag to 0 (now inside a word)
    b       next_byte

is_space:
    mov     w23, #1                 // Set in-word flag to 1 (currently in whitespace)

next_byte:
    sub     x4, x4, #1              // Decrement remaining bytes counter for this chunk
    cbnz    x4, process_buffer      // If bytes remain in chunk, loop to next byte
    b       read_loop               // Otherwise, fetch the next 4KB chunk from the file

finish_read:
    // ========================================================================
    // STEP 5: Close File via System Call (SYS_close = 6)
    // ========================================================================
    mov     x0, x19                 // File descriptor
    mov     x16, #SYS_close         // Load close system call number (6)
    svc     #0x80

    // ========================================================================
    // STEP 6: Convert Numeric Counts to Strings and Print via SYS_write
    // ========================================================================
    // Convert Line Count (x20) to string in line_buf
    adrp    x0, line_buf@PAGE
    add     x0, x0, line_buf@PAGEOFF
    mov     x1, x20
    bl      int_to_str

    // Convert Word Count (x21) to string in word_buf
    adrp    x0, word_buf@PAGE
    add     x0, x0, word_buf@PAGEOFF
    mov     x1, x21
    bl      int_to_str

    // Convert Char Count (x22) to string in char_buf
    adrp    x0, char_buf@PAGE
    add     x0, x0, char_buf@PAGEOFF
    mov     x1, x22
    bl      int_to_str

    // Write formatted output to stdout using SYS_write (4)
    mov     x0, #1                  // File descriptor 1 = Standard Output (stdout)
    adrp    x1, out_msg@PAGE
    add     x1, x1, out_msg@PAGEOFF // Pointer to start of output message template
    
    // Calculate exact message length dynamically using label offsets
    adrp    x2, out_end@PAGE
    add     x2, x2, out_end@PAGEOFF
    sub     x2, x2, x1              // Length = out_end - out_msg
    
    mov     x16, #SYS_write         // Load write system call number (4)
    svc     #0x80                   // Trigger write system call

    // ========================================================================
    // STEP 7: Exit Successfully (SYS_exit = 1)
    // ========================================================================
    mov     x0, #0                  // Exit code 0 (Success)
    mov     x16, #SYS_exit          // Load exit system call number (1)
    svc     #0x80


// ============================================================================
// Helper Routine: Convert Unsigned Integer to ASCII String (Right-to-Left)
// Input:  x0 = Destination buffer pointer (start of 20-byte slot), x1 = Integer
// ============================================================================
int_to_str:
    stp     x29, x30, [sp, #-32]!   // Save frame and extra space for scratch
    mov     x29, sp

    // We have a 20-byte buffer. Let's work from the end backwards to avoid reversing.
    add     x2, x0, #19             // Point x2 to the very last byte of the 20-byte buffer
    mov     w5, #0                  // Null or delimiter/padding
    strb    w5, [x2]                // Null-terminate at the end
    sub     x2, x2, #1

    mov     x3, x1                  // Copy integer value
    mov     x4, #10                 // Divisor for decimal base

    // Handle edge case if value is exactly 0
    cbnz    x3, 1f
    mov     w5, #'0'
    strb    w5, [x2]
    b       pad_spaces

1:  // Division loop: extract digits right-to-left
    cbz     x3, pad_spaces          // If number is fully processed, stop
    mov     x5, x3                  // Keep original for remainder calculation
    udiv    x3, x3, x4              // x3 = x3 / 10
    msub    x6, x3, x4, x5          // x6 = remainder (the digit: 0-9)
    add     w6, w6, #'0'            // Convert digit to ASCII character
    strb    w6, [x2], #-1           // Store byte and move pointer backwards
    b       1b

pad_spaces:
    // Optional: If you want to shift the final text to the left side of the 20-byte block, 
    // or leave it as is. For standard printing, let's copy the active digits to the start of x0.
    
    ldp     x29, x30, [sp], #32     // Restore frame
    ret                             // Return from subroutine

str_done:
    ldp     x29, x30, [sp], #16     // Restore frame
    ret                             // Return from subroutine


// ============================================================================
// Error Handlers
// ============================================================================
err_argc:
    mov     x0, #1                  // Exit code 1: Missing command-line arguments
    mov     x16, #SYS_exit
    svc     #0x80

err_open:
    mov     x0, #2                  // Exit code 2: File open or read error
    mov     x16, #SYS_exit
    svc     #0x80