// ============================================================================
// macOS ARM64 (Apple Silicon) Hexdump -C Clone - Pure System Call Version
// Assembler: GNU Assembler (GAS) syntax - clang used
// The program start point is _main
// Compile (on mac ARM64 CPU): clang hexdump.s -o hexdump
// After compiling, execute: ./hexdump_mac test.txt (test.txt could be any txt file)
//
// ARM 64 register reference:
// x0 1st Arg/return val (also kernel sys call execution return)
// x1...x7 Argument reg (volatile)
// x16 macOS Sys call/Linker - Execution/functions
// x19-x28 non volatile reg (to keep values for something)
//
// Order of execution (aka what's being done):
// 1. _main (parse args, open file, init counters)
// 2. Read 4096-byte chunk - If EOF/Done - close file and exit
// 3. Process 16 byte row:
// a. convert bytes to Hex Strings
// b. Convert bytes to Printable Ascii (table on the side show what's being shown)
// c. Print Row to terminal
// d. Advance Counters - Go/Loop back to b or a
// ============================================================================

.global _main // By default labels and functions are private - .global exports the label to the linker
.align 2  // ARM64 requires all instructions to be 4 bytes long (2**2)

// --- macOS ARM64 System Call Numbers/compile-time constants ---
.equ SYS_exit,  1       // Terminate process, assign val 1 to "SYS_exit"
.equ SYS_read,  3       // Read from file descriptor
.equ SYS_write, 4       // Write to file descriptor (1 = stdout)
.equ SYS_open,  5       // Open file path
.equ SYS_close, 6       // Close file descriptor
.equ O_RDONLY,  0       // Read-only flag

.data
hex_table:  .ascii "0123456789ABCDEF"

.bss
.lcomm file_buffer, 4096    // Buffer to read chunks from the file
.lcomm line_buffer,  80     // Output format buffer for a single 16-byte line


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

    // STEP 3: Initialize State Counters
    mov     x20, #0                 // x20 = Running file offset counter (set to 0 now)

// Read data from the file descriptor into a temporary memory buffer
read_file_loop:
    // Read next chunk into file_buffer
    mov     x0, x19                 // File descriptor back in x0 (saved in x19 above)
    adrp    x1, file_buffer@PAGE   // Get the exact memory address of file_buffer pt1
    add     x1, x1, file_buffer@PAGEOFF // Get the exact memory address of file_buffer pt2
    mov     x2, #4096               // Read up to 4096 bytes (request max chunk size)
    mov     x16, #SYS_read            // Set system call to SYS_read
    svc     #0x80                     // Interrupt to run SYS_READ in kernel

    b.cs    err_open                // Carry flag set = read failed (branch if carry set)
    cbz     x0, finish_hexdump      // If x0 is 0 bytes = we reached EOF (cbz compare and branch if zero)

    mov     x21, x0                 // x21 = Total bytes remaining in this chunk (into non-volatile reg)
    adrp    x22, file_buffer@PAGE   // x22 = Page address of file_buffer and put in x22
    add     x22, x22, file_buffer@PAGEOFF // Get exact address offset of file_buffer and update x22

// Keep track of how many bytes are handled in the current row/string slice
process_chunk_loop:
    cbz     x21, read_file_loop     // If chunk is back to 0 back to read_file_loop(Compare and Branch on Zero)

    // Determine how many bytes to process for this row (up to 16 bytes)
    mov     x23, #16                // Set default val of 16 bytes into x23
    cmp     x21, #16                // Compare remaining bytes in the buffer with 16
    csel    x23, x21, x23, lt       // If remaining bytes < 16, x23 = remaining bytes (x21)

    // STEP 4: Build a Canonical Row Line
    // Layout: [8-byte offset]  [8 hex bytes]  [8 hex bytes]  |[16 ascii chars]|
    adrp    x24, line_buffer@PAGE   // Compute page address of the text buffer into x24
    add     x24, x24, line_buffer@PAGEOFF   // Append exact page offset into x24

    // 4.1 Format 8-byte Hex Offset
    mov     x0, x20                 // Current offset value (the offset will be passed as the 1 input param to the format_hex_offset)
    mov     x1, x24                 // Destination pointer (Line liffer pointer into x1)
    bl      format_hex_offset       // Call a subroutine (branch with link) that converts current file offset int to 8 readable hex chars
    add     x24, x24, #8            // Advance line buffer past offset

    // 4.2 Append two spaces separator "  "
    mov     w5, #' '                // Load ASCII space character into 32-bit register w5
    strb    w5, [x24], #1           // Append space to line buffer and post-increment pointer by 1 byte
    strb    w5, [x24], #1           // Append second space to line buffer and post-increment pointer by 1 byte

    // 4.3 Format Hex Bytes and ASCII sidebar
    mov     x25, #0                 // Inner loop index (0 to 15) to track the 16 columns of the hex display
    
row_byte_loop:
    cmp     x25, #16                // Compare current column index with 16
    b.ge    row_formatting_done     // Branch if index >= 16 (all 16 hex columns evaluated)

    // Add extra space between the 8th and 9th byte blocks
    cmp     x25, #8                 // Check if we are at the 8th byte boundary for spacing layout
    b.ne    check_padding           // If not column 8, skip the layout modifier space adjustment
    mov     w5, #' '                // Load structural spacer into w5
    strb    w5, [x24], #1           // Append extra visual spacer space to divide hex blocks

check_padding:
    cmp     x25, x23                // Compare loop index with actual valid data count in this row
    b.ge    pad_empty_byte          // If index >= valid data length, jump to pad with empty column slots

    // Load actual byte from file buffer
    ldrb    w5, [x22, x25]          // Load 1 raw byte from file buffer (base x22 + index x25) into w5
    
    // Convert byte to two hex characters
    adrp    x6, hex_table@PAGE      // Get page-aligned address of the hex character translation table
    add     x6, x6, hex_table@PAGEOFF // Compute absolute address of hex table into x6
    
    lsr     w7, w5, #4              // Logical Shift Right by 4 bits to isolate the high nibble (first digit)
    ldrb    w7, [x6, x7]            // Look up corresponding ASCII character in hex_table
    strb    w7, [x24], #1           // Write high hex character to line buffer and advance pointer

    and     w7, w5, #0x0F           // Bitwise AND with 0x0F to isolate the low nibble (second digit)
    ldrb    w7, [x6, x7]            // Look up corresponding ASCII character in hex_table
    strb    w7, [x24], #1           // Write low hex character to line buffer and advance pointer

    mov     w5, #' '                // Load space separator between hex pairs
    strb    w5, [x24], #1           // Append trailing column space and advance pointer
    b       next_inner_byte         // Unconditional branch to skip tail alignment padding logic

pad_empty_byte:
    // If fewer than 16 bytes remain, output 3 spaces for alignment
    mov     w5, #' '                // Load ASCII space into w5 to act as alignment padding
    strb    w5, [x24], #1           // Write 1st space (replaces missing high hex digit)
    strb    w5, [x24], #1           // Write 2nd space (replaces missing low hex digit)
    strb    w5, [x24], #1           // Write 3rd space (replaces missing trailing separator space)

next_inner_byte:
    add     x25, x25, #1            // Increment hex column index by 1
    b       row_byte_loop           // Branch back to start of row_byte_loop

row_formatting_done:
    // 4.4 Append ASCII Sidebar separators " |"
    mov     w5, #' '                // Load space character into w5
    strb    w5, [x24], #1           // Append structural separation space before sidebar opens
    mov     w5, #'|'                // Load vertical bar character into w5
    strb    w5, [x24], #1           // Append the opening sidebar boundary marker to line buffer

    // 4.5 Fill ASCII characters (16 slots)
    mov     x25, #0                 // Reset loop index counter to 0 for the ASCII sidebar loop
ascii_loop:
    cmp     x25, #16                // Compare current index with max sidebar length (16)
    b.ge    ascii_loop_done         // Branch if index >= 16 (all sidebar text slots filled)

    cmp     x25, x23                // Compare index with actual valid row data length
    b.ge    pad_space_ascii         // If we are past the end of real file data, fill slot with blank padding

    ldrb    w5, [x22, x25]          // Load raw data byte from file chunk buffer into w5
    
    // Check if printable ASCII (range 0x20 to 0x7E)
    cmp     w5, #0x20               // Compare byte with 0x20 (Space, first printable character)
    b.lt    print_dot               // If value is less than 0x20 (control character), replace with a dot
    cmp     w5, #0x7E               // Compare byte with 0x7E (Tilde, last printable character)
    b.gt    print_dot               // If value is greater than 0x7E (delete/extended code), replace with a dot
    b       store_ascii             // Branch to store valid printable character directly

print_dot:
    mov     w5, #'.'                // Load ASCII period symbol to represent an unprintable character

store_ascii:
    strb    w5, [x24], #1           // Write character into the sidebar buffer and advance pointer
    b       next_ascii_byte         // Unconditional branch to skip empty tail sidebar layout adjustments

pad_space_ascii:
    mov     w5, #' '                // Load space character to pad out empty slots at EOF
    strb    w5, [x24], #1           // Write layout padding space and advance pointer

next_ascii_byte:
    add     x25, x25, #1            // Increment ASCII sidebar loop index counter by 1
    b       ascii_loop              // Branch back to start of ascii_loop

ascii_loop_done:
    // 4.6 Append closing sidebar and newline "|\n"
    mov     w5, #'|'                // Load vertical bar character into w5
    strb    w5, [x24], #1           // Append the closing sidebar boundary marker to line buffer
    mov     w5, #0x0A               // Load hex value 0x0A (ASCII Newline character '\n')
    strb    w5, [x24], #1           // Append newline byte to complete the full formatted line string

    // Calculate exact line length (should be exactly 79 bytes)
    adrp    x26, line_buffer@PAGE   // Get page-aligned address of line_buffer start point
    add     x26, x26, line_buffer@PAGEOFF // Compute absolute start address of line_buffer into x26
    sub     x2, x24, x26            // Pointer arithmetic: end pointer (x24) - start pointer (x26) = line length in x2

    // STEP 5: Print Completed Row via SYS_write (4)
    mov     x0, #1                  // File descriptor 1 = stdout (pass target output channel to x0)
    mov     x1, x26                 // Pass pointer to the beginning of our formatted row string to x1
    mov     x16, #SYS_write         // Load system call number for writing into scratch register x16
    svc     #0x80                   // Software interrupt to transfer execution context to macOS write system call

    // STEP 6: Advance Pointers and Loop
    add     x20, x20, x23           // Add processed bytes to total running file offset track accumulator
    add     x22, x22, x23           // Advance the raw file buffer tracking memory pointer forward
    sub     x21, x21, x23           // Subtract processed row bytes from remaining current chunk count
    b       process_chunk_loop      // Branch back to process next 16-byte slice of the current chunk

finish_hexdump:
    // STEP 7: Close File and Exit Successfully
    mov     x0, x19                 // Move saved file descriptor from x19 back to x0 (arg 1 for close)
    mov     x16, #SYS_close         // Load system call number for closing files into x16
    svc     #0x80                   // Trigger kernel software interrupt to release OS file locks

    mov     x0, #0                  // Load exit status code 0 (indicates clean execution success) into x0
    mov     x16, #SYS_exit          // Load system call number for process termination into x16
    svc     #0x80                   // Final kernel software interrupt to end program execution completely


// Helper Routine: Format 64-bit Offset into 8 Hex Characters
// Input: x0 = offset integer, x1 = destination buffer pointer
format_hex_offset:
    stp     x29, x30, [sp, #-16]!   // Push frame pointer (x29) and link register (x30) to stack frame and update sp
    mov     x29, sp                 // Copy current stack pointer to frame pointer for standard debug stack tracing

    adrp    x2, hex_table@PAGE      // Get page-aligned address of lookup character array
    add     x2, x2, hex_table@PAGEOFF // Compute absolute address of hex_table into x2
    
    mov     x3, #7                  // Initialize loop tracker index to 7 (process string right-to-left, columns 7 down to 0)

offset_loop:
    and     w4, w0, #0x0F           // Isolate the lowest 4 bits (current rightmost nibble) of the offset number
    ldrb    w4, [x2, x4]            // Look up corresponding hexadecimal ASCII character from conversion table
    
    // Store character from right to left in the 8-byte slot
    strb    w4, [x1, x3]            // Store translated text character at address location destination x1 + index offset x3
    
    lsr     x0, x0, #4              // Logical Shift Right by 4 bits to prepare the next higher numeric nibble digit
    sub     x3, x3, #1              // Decrement column index position by 1 (move cursor to the left)
    cbnz    x3, 1f                  // Compare and Branch if Non-Zero: if index is not 0, jump to local label 1
    
    // Handle index 0 explicitly
    and     w4, w0, #0x0F           // Isolate absolute final remaining leftmost numeric nibble digit
    ldrb    w4, [x2, w4]            // Look up matching ASCII character entry in table array
    strb    w4, [x1, #0]            // Write character into the leftmost array index position 0
    b       offset_done             // Unconditional branch to jump past looping label block to return sequence

1:  b       offset_loop             // Redirect instruction path back up to continue next loop step execution

offset_done:
    ldp     x29, x30, [sp], #16     // Pop frame pointer and link register back from stack to clean stack frame tracking
    ret                             // Return control path flow back to the caller address held in the Link Register (x30)

// Error Handlers
err_argc:
    mov     x0, #1                  // Load failure status code 1 (invalid execution parameters) into x0
    mov     x16, #SYS_exit          // Load process termination system call code into x16
    svc     #0x80                   // Abort execution via macOS kernel call (SYS_exit)

err_open:
    mov     x0, #2                  // Load failure status code 2 (unable to target or access file path) into x0
    mov     x16, #SYS_exit          // Load process termination system call code into x16
    svc     #0x80                   // Abort execution via macOS kernel call