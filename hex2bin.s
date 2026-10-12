// ============================================================================
// macOS ARM64 (Apple Silicon) Hex-to-Binary Converter (Reverse Hexdump)
// Assembler: GNU Assembler (GAS) syntax - clang used
// Compile (on mac ARM64 CPU): clang hex2bin.s -o hex2bin
// After compiling, execute: ./hex2bin hex_input.txt
// The program start point is _main
//
// ARM 64 register reference:
// x0 1st Arg/return val (also kernel's execution return)
// x1...x7 Argument reg
// x16 macOS Sys call/Linker - Execution/functions
// x19-x28 non volatile reg (to keep values for something)
// ============================================================================

// By default labels and functions are private - .global exports the label to the linker
.global _main // Add _main to Linker (make it available for execution, otherwise it's private)
.align 2  // ARM64 requires all instructions to be 4 bytes long (2**2)

// --- macOS ARM64 System Call Numbers/compile-time constants ---
.equ SYS_exit,  1       // Terminate process, assign val 1 to "SYS_exit"
.equ SYS_read,  3       // Read from file descriptor
.equ SYS_write, 4       // Write to file descriptor (1 = stdout)
.equ SYS_open,  5       // Open file path
.equ SYS_close, 6       // Close file descriptor
.equ O_RDONLY,  0       // Read-only flag

.bss
.lcomm text_buffer, 4096    // Buffer to read incoming text characters from the hex file
.lcomm bin_buffer,  2048    // Buffer to store reconstructed raw binary bytes

.text
_main:
    // STEP 1: Parse Command-Line Arguments from Registers
    cmp     x0, #2                  // Check argc (in x0) < 2
    b.lt    err_argc                // Exit if no file provided (checks the cmp above)

    ldr     x1, [x1, #8]            // Load argv[1] (filename pointer, in ARM64 8 bytes)
    mov     x19, x1                 // Save filename pointer in x19 (x19-x28 are non-volatile reg)

    // STEP 2: Open File via Raw System Call (SYS_open = 5)
    mov     x0, x19                 // Path pointer (move the filename pointer into x0)
    mov     x1, #O_RDONLY           // Read-only mode (pass read-only flag to x1)
    mov     x2, #0                  // File permissions - unused
    mov     x16, #SYS_open          // Open syscall number - Open file
    svc     #0x80                   // Trigger kernel call (software interrupt to hand control over to the macOS sys call)
    
    b.cs    err_open                // macOS sets the carry flag on syscall failure (x0 holds the error code) - branch if carry set
    mov     x19, x0                 // The Kernel value becomes a File Descriptor, we overwrite the filename in x19

// Read formatted hex characters from the file descriptor into memory
read_text_loop:
    // Read next chunk of text into text_buffer
    mov     x0, x19                 // File descriptor back in x0 (saved in x19 above)
    adrp    x1, text_buffer@PAGE    // Get the exact memory address of text_buffer pt1
    add     x1, x1, text_buffer@PAGEOFF // Get the exact memory address of text_buffer pt2
    mov     x2, #4096               // Read up to 4096 text bytes (request max chunk size)
    mov     x16, #SYS_read          // Set system call to SYS_read
    svc     #0x80                   // Interrupt to run SYS_READ in kernel

    b.cs    err_open                // Carry flag set = read failed (branch if carry set)
    cbz     x0, finish_reverse      // If x0 is 0 bytes = we reached EOF (cbz compare and branch if zero)

    mov     x20, x0                 // x20 = Total text characters read in this chunk (into non-volatile reg)
    mov     x21, #0                 // x21 = Active index index counter tracking position within text_buffer
    adrp    x26, text_buffer@PAGE   // x26 = Page address of text_buffer (base pointer for loading characters)
    add     x26, x26, text_buffer@PAGEOFF // Get exact address offset of text_buffer and update x26

    adrp    x22, bin_buffer@PAGE    // x22 = Page address of bin_buffer and put in x22
    add     x22, x22, bin_buffer@PAGEOFF // Get exact address offset of bin_buffer and update x22

// Parse out hex characters and convert them back into numeric bytes
parse_loop:
    // Ensure we have at least 2 characters left in the text window to form a full byte pair
    sub     x23, x20, x21           // x23 = characters remaining in text_buffer (total x20 - current x21)
    cmp     x23, #2                 // Compare remaining character count with 2
    b.lt    flush_and_read          // If fewer than 2 characters remain, go flush buffer and load new chunk

    // --- Process High Nibble ---
    ldrb    w5, [x26, x21]          // Load first ASCII character element (e.g. '4') out of text_buffer (base x26 + index x21)
    add     x21, x21, #1            // Advance our text buffer index counter forward by 1 byte
    bl      ascii_to_nibble         // Call subroutine to translate character code into actual numeric digit value
    cmp     w0, #0xFF               // Check if the returned token matches our invalid hex flag (0xFF)
    b.eq    parse_loop              // If invalid (e.g. a layout space, newline, or '|'), discard it and skip ahead
    lsl     w24, w0, #4             // Logical Shift Left by 4 bits to position this value as the upper nibble (e.g. 4 becomes 0x40)

next_low_nibble:
    // --- Process Low Nibble ---
    cmp     x21, x20                // Check if the index has reached the end of the characters read in this chunk
    b.ge    flush_and_read          // If no characters are left, drop the unpaired high nibble and go load the next chunk
    ldrb    w5, [x26, x21]          // Load second ASCII character element (e.g. '1') out of text_buffer (base x26 + index x21)
    add     x21, x21, #1            // Advance our text buffer index counter forward by 1 byte
    bl      ascii_to_nibble         // Call subroutine to translate character code into actual numeric digit value
    cmp     w0, #0xFF               // Check if the returned token matches our invalid hex flag (0xFF)
    b.eq    next_low_nibble         // If a whitespace character snuck in between hex pairs, loop back to wait for a valid match
    
    orr     w24, w24, w0            // Bitwise OR the high nibble (w24) and low nibble (w0) together (e.g. 0x40 OR 0x01 = 0x41)
    
    // Store reconstructed byte into the output binary buffer
    strb    w24, [x22], #1          // Store the unified numeric byte into bin_buffer and post-increment binary cursor by 1
    b       parse_loop              // Loop back to evaluate next byte sequence

flush_and_read:
    // Calculate how many binary bytes were actually generated
    adrp    x25, bin_buffer@PAGE    // Get page-aligned address of bin_buffer start point
    add     x25, x25, bin_buffer@PAGEOFF // Compute absolute start address of bin_buffer into x25
    sub     x2, x22, x25            // Pointer arithmetic: end pointer (x22) - start pointer (x25) = binary payload length in x2
    cbz     x2, read_text_loop      // If buffer payload length is 0, skip writing and jump straight to loading next chunk

    // Print raw binary out to stdout
    mov     x0, #1                  // File descriptor 1 = stdout (pass target output channel to x0)
    mov     x1, x25                 // Pass pointer to the beginning of our raw output binary buffer to x1
    mov     x16, #SYS_write         // Load system call number for writing into scratch register x16
    svc     #0x80                   // Software interrupt to transfer execution context to macOS write system call
    b       read_text_loop          // Jump back to load next text chunk from file source

finish_reverse:
    // STEP 7: Close File and Exit Successfully
    mov     x0, x19                 // Move saved file descriptor from x19 back to x0 (arg 1 for close)
    mov     x16, #SYS_close         // Load system call number for closing files into x16
    svc     #0x80                   // Trigger kernel software interrupt to release OS file locks

    mov     x0, #0                  // Load exit status code 0 (indicates clean execution success) into x0
    mov     x16, #SYS_exit          // Load system call number for process termination into x16
    svc     #0x80                   // Final kernel software interrupt to end program execution completely

// Helper Routine: Convert an ASCII Hex Character into a 4-bit Numeric Nibble
// Input: w5 = ASCII character
// Output: w0 = 0-15 numerical value, or 0xFF if invalid hex (whitespace/delimiters)
ascii_to_nibble:
    // Check for '0' through '9' (ASCII 0x30 - 0x39)
    cmp     w5, #'0'                // Compare incoming character value to ASCII literal '0'
    b.lt    not_numeric             // If less than '0', it cannot be a numeric digit value
    cmp     w5, #'9'                // Compare incoming character value to ASCII literal '9'
    b.gt    check_uppercase         // If greater than '9', step forward to check alpha conversion blocks
    sub     w0, w5, #'0'            // Value conversion math: subtract base '0' ASCII code from w5, output result in w0
    ret                             // Return control to calling instruction address

check_uppercase:
    // Check for 'A' through 'F' (ASCII 0x41 - 0x46)
    cmp     w5, #'A'                // Compare character value to uppercase letter 'A'
    b.lt    not_hex                 // If less than 'A', it falls in the layout dead zone between '9' and 'A'
    cmp     w5, #'F'                // Compare character value to uppercase letter 'F'
    b.gt    check_lowercase         // If greater than 'F', step forward to evaluate potential lowercase choices
    sub     w0, w5, #'A'            // Calculate index offset relative to character 'A'
    add     w0, w0, #10             // Add 10 to balance numerical value scaling mapping (e.g. 'A' becomes value 10)
    ret                             // Return control to calling instruction address

check_lowercase:
    // Check for 'a' through 'f' (ASCII 0x61 - 0x66)
    cmp     w5, #'a'                // Compare character value to lowercase letter 'a'
    b.lt    not_hex                 // If less than 'a', it falls in the layout dead zone between 'F' and 'a'
    cmp     w5, #'f'                // Compare character value to lowercase letter 'f'
    b.gt    not_hex                 // If greater than 'f', it is completely outside standard hexadecimal range bounds
    sub     w0, w5, #'a'            // Calculate index offset relative to character 'a'
    add     w0, w0, #10             // Add 10 to balance numerical value scaling mapping (e.g. 'a' becomes value 10)
    ret                             // Return control to calling instruction address

not_numeric:
not_hex:
    mov     w0, #0xFF               // Load immediate value 0xFF into w0 to serve as our invalid syntax/layout token flag
    ret                             // Return control to calling instruction address

// Error Handlers
err_argc:
    mov     x0, #1                  // Load failure status code 1 (invalid execution parameters) into x0
    mov     x16, #SYS_exit          // Load process termination system call code into x16
    svc     #0x80                   // Abort execution via macOS kernel call

err_open:
    mov     x0, #2                  // Load failure status code 2 (unable to target or access file path) into x0
    mov     x16, #SYS_exit          // Load process termination system call code into x16
    svc     #0x80                   // Abort execution via macOS kernel call