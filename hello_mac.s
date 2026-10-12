// ============================================================================
// macOS ARM64 "Hello, World!" - First ever attempt at ARM64 assembly coding
// Compile: clang hello_mac.s -o hello_mac
// After compilation ./hello_mac (to execute)
// ============================================================================

// By default labels and functions are private - .global exports the label to the linker
.global _main // Add _main to Linker (make it available for execution, otherwise it's private)
.align 2 // ARM64 requires all instructions to be 4 bytes long (2**2)

// System call numbers for macOS ARM64
.equ SYS_write, 4
.equ SYS_exit,  1

.data // Variables section
msg:
    .ascii "Hello, World!\n" // Hello world in ASCII (normal text)

.text // Main execution section
_main:
    // Step 1: Write string to stdout
    mov     x0, #1              // File descriptor: 1 = standard output
    adrp    x1, msg@PAGE        // Load page address of our string
    add     x1, x1, msg@PAGEOFF // Add page offset to get exact string pointer
    mov     x2, #14             // Length of the string (including \n)
    mov     x16, #SYS_write     // Load write system call number into x16
    svc     #0x80               // Trigger kernel call

    // Step 2: Exit the program cleanly
    mov     x0, #0              // Return code 0 (success)
    mov     x16, #SYS_exit      // Load exit system call number into x16
    svc     #0x80               // Trigger kernel call