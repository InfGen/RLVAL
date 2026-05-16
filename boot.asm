; ============================================================================
; boot.asm - Stage 1 bootloader for RLVAL OS
; Assemble: nasm -f bin boot.asm -o boot.bin   (produces a 512-byte sector)
;
; Responsibilities:
;   * BIOS loads us at 0x7C00 in 16-bit real mode with DL = boot drive.
;   * Set up segments and a stack.
;   * Load the kernel (next 32 sectors of the disk image) to 0x1000:0x0000.
;   * Jump to the kernel.  All graphics/UI happens in the kernel itself.
; ============================================================================

[BITS 16]
[ORG 0x7C00]

start:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00
    sti

    mov [boot_drive], dl

    mov si, msg_boot
    call print_str

    ; --- Wait for ESC key (approx 2 seconds) ---
    xor bp, bp      ; bp = 0 (default: normal boot)
    mov ah, 0x00
    int 0x1a        ; Get system ticks (CX:DX)
    mov bx, dx
    add bx, 36      ; 18.2 ticks per second * 2 = ~36 ticks

.wait_esc:
    mov ah, 0x01    ; BIOS: check for keystroke
    int 0x16
    jz .no_key      ; No key pressed

    mov ah, 0x00    ; BIOS: get keystroke
    int 0x16
    cmp al, 27      ; ESC key?
    jne .no_key
    mov bp, 1       ; ESC pressed! set flag
    jmp .load_kernel ; Skip waiting

.no_key:
    mov ah, 0x00
    int 0x1a
    cmp dx, bx
    jb .wait_esc

.load_kernel:
    ; --- Load kernel: 32 sectors starting at LBA 2 -> ES:BX = 0x1000:0x0000 ---
    mov ax, 0x1000
    mov es, ax
    xor bx, bx

    mov ah, 0x02            ; BIOS: read sectors
    mov al, 32              ; 32 * 512 = 16 KB
    mov ch, 0
    mov cl, 2               ; sector 2 (sector 1 is this bootloader)
    mov dh, 0
    mov dl, [boot_drive]
    int 0x13
    jc disk_error

    mov bx, bp              ; Pass BIOS flag to kernel in BX
    mov ax, 0x1000
    mov ds, ax
    mov es, ax
    jmp 0x1000:0x0000

disk_error:
    mov si, msg_err
    call print_str
.hang:
    cli
    hlt
    jmp .hang

print_str:
    pusha
.next:
    lodsb
    or al, al
    jz .done
    mov ah, 0x0E
    mov bx, 0x0007
    int 0x10
    jmp .next
.done:
    popa
    ret

boot_drive db 0
msg_boot   db "RLVAL OS - Press ESC for Setup...", 13, 10, 0
msg_err    db "Disk read error. Halted.", 13, 10, 0

times 510-($-$$) db 0
dw 0xAA55
