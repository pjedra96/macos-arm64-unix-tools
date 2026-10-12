# ARM64 assembly for macOS

Small utility programs written in ARM64 assembly for Apple Silicon Macs.
They don't use the C library. They call the macOS kernel directly with `svc #0x80`.

## hello_mac.s

First ever attempt at macOS assembly. It is a standard "Hello World" message.

## wc.s

Counts the lines, words and characters in a file, like `wc`.
A word is any run of characters between spaces, tabs or line breaks.

    clang wc.s -o wc
    ./wc file.txt

## hexdump.s

Reads a file and prints it in the same layout as `hexdump -C`:
the offset, 16 bytes in hex, and the printable characters on the right.

    clang hexdump.s -o hexdump
    ./hexdump file.txt

## hex2bin.s

Does the reverse. Reads a text file of hex pairs and writes the raw bytes to stdout.
Spaces, newlines and other characters that aren't hex digits are skipped.

    clang hex2bin.s -o hex2bin
    ./hex2bin hex_input.txt > output.bin

## What's in the code

- Raw system calls: `open`, `read`, `write`, `close`, `exit`
- Reading files in 4096-byte chunks
- Converting between bytes and hex with a lookup table and bit shifts
- Turning a number into decimal text with `udiv` and `msub`
- Loading addresses with `adrp` / `@PAGEOFF`
- Small subroutines that save and restore the frame on the stack
- Exit codes: 1 if no file is given, 2 if the file can't be opened or read

Most lines have a comment explaining what they do.
