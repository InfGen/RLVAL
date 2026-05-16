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
    je bios_setup

.no_key:
    mov ah, 0x00
    int 0x1a
    cmp dx, bx
    jb .wait_esc

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

    mov ax, 0x1000
    mov ds, ax
    mov es, ax
    jmp 0x1000:0x0000

bios_setup:
    mov ax, 0x0003          ; Switch to VGA text mode 80x25
    int 0x10

    mov si, msg_bios
    call print_str

    mov ah, 0x00            ; Wait for key
    int 0x16

    int 0x19                ; Warm reboot

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
msg_bios   db "RLVAL BIOS SETUP MENU", 13, 10
           db "---------------------", 13, 10
           db "CPU: x86 (16-bit mode)", 13, 10
           db "RAM: 640 KB Base Memory", 13, 10
           db "Disk: Floppy/HDD Emulation", 13, 10, 13, 10
           db "Press any key to exit and reboot...", 0

times 510-($-$$) db 0
dw 0xAA55
