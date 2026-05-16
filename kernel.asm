; ============================================================================
; kernel.asm - RLVAL OS kernel (16-bit real mode, VGA mode 13h)
; Assemble: nasm -f bin kernel.asm -o kernel.bin
; Loaded by boot.asm at 0x1000:0x0000.
;
; Phases:
;   1. Set mode 13h (320x200, 256 colors @ 0xA0000).
;   2. Install modern-dark palette in DAC indices 0..15.
;   3. Boot screen, Windows 11 style:
;        - dark background
;        - "RLVAL OS" wordmark centered
;        - rotating ring of 8 dots below it (spinner)
;        - faint "RLVAL Corporation" footer
;   4. Desktop GUI (wallpaper, menu bar, window, taskbar, cursor).
;   5. Wait for keypress, reboot.
;
; The spinner has 8 dots arranged on a circle.  Each frame, we pick a "head"
; dot index (0..7) that is fully bright; the dot before it is medium-bright,
; two before is dim, three before is very dim, the rest are background.
; The head advances by 1 every frame -> creates the rotating "comet" look that
; Windows 11 uses on its boot/sign-in spinner.
; ============================================================================

[BITS 16]
[ORG 0x0000]

KERNEL_START:
    mov [is_bios_mode], bx          ; Store the BIOS flag from bootloader

    mov ax, cs
    mov ds, ax
    mov es, ax

    ; Mode 13h
    mov ax, 0x0013
    int 0x10

    call install_palette

    cmp word [is_bios_mode], 1
    jne .skip_bios_menu
    call bios_menu_entry
.skip_bios_menu:

    ; ---- Boot screen ----
    mov al, 1
    call clear_screen

    ; Wordmark "RLVAL OS" using BIOS 8x8 font (text via INT 10h teletype).
    ; mode 13h = 40 cols x 25 rows.  "RLVAL OS" is 8 chars -> col (40-8)/2 = 16.
    mov dh, 9                       ; row
    mov dl, 16                      ; col
    call set_cursor
    mov si, str_title
    call print_str

    ; Footer text (small, faint look — same font, just lower)
    mov dh, 22
    mov dl, 11                      ; Centered better
    call set_cursor
    mov si, str_footer
    call print_str

    ; ---- Spinner animation (Windows 11 style) ----
    ; The spinner is centered at (160, 130) with radius 12.
    ; Run ~600 frames -> spinner makes ~75 full revolutions.
    mov word [frame], 0
.spin_loop:
    mov ax, [frame]
    cmp ax, 600
    jae .spin_done

    call draw_spinner
    call short_delay

    inc word [frame]
    jmp .spin_loop
.spin_done:

    call long_delay

    ; ---- Desktop ----
    call draw_desktop
    call init_mouse
    
    ; Initial save of background at starting position
    mov ax, [mouseX]
    mov [oldMouseX], ax
    mov ax, [mouseY]
    mov [oldMouseY], ax
    call save_cursor_bg
    call draw_cursor_at_mouse

.main_loop:
    ; Check if mouse moved
    cmp byte [mouse_updated], 1
    jne .check_keyboard
    
    mov byte [mouse_updated], 0
    
    call restore_cursor_bg
    
    mov ax, [mouseX]
    mov [oldMouseX], ax
    mov ax, [mouseY]
    mov [oldMouseY], ax
    
    call save_cursor_bg
    call draw_cursor_at_mouse

.check_keyboard:
    mov ah, 1
    int 0x16
    jz .main_loop

    ; Wait for keypress, then reboot
    mov ah, 0
    int 0x16
    int 0x19

.hang:
    cli
    hlt
    jmp .hang


; ============================================================================
; Mouse Driver & Support
; ============================================================================
init_mouse:
    pusha
    ; Enable mouse in BIOS
    mov ax, 0xC205
    mov bh, 3 ; 3-byte packet
    int 0x15
    jc .done

    ; Set mouse handler
    mov ax, 0xC207
    push cs
    pop es
    mov bx, mouse_handler
    int 0x15
    jc .done

    ; Enable mouse
    mov ax, 0xC200
    mov bh, 1 ; Enable
    int 0x15
.done:
    popa
    ret

mouse_handler:
    push ds
    pusha
    mov ax, cs
    mov ds, ax
    mov bp, sp
    
    ; [BP+28] = Status
    ; [BP+26] = X displacement
    ; [BP+24] = Y displacement
    
    mov al, [bp+28]
    mov [mouseButtons], al
    
    ; Update X
    mov ax, [bp+26]
    and ax, 0x00FF
    test byte [bp+28], 0x10 ; X sign
    jz .x_pos
    or ax, 0xFF00
.x_pos:
    add [mouseX], ax
    
    ; Update Y
    mov ax, [bp+24]
    and ax, 0x00FF
    test byte [bp+28], 0x20 ; Y sign
    jz .y_pos
    or ax, 0xFF00
.y_pos:
    sub [mouseY], ax ; Y is inverted in BIOS
    
    ; Clamp X (0..311) - 8px width cursor
    cmp word [mouseX], 0
    jge .check_max_x
    mov word [mouseX], 0
    jmp .check_y
.check_max_x:
    cmp word [mouseX], 311
    jle .check_y
    mov word [mouseX], 311

.check_y:
    ; Clamp Y (0..187) - 12px height cursor
    cmp word [mouseY], 0
    jge .check_max_y
    mov word [mouseY], 0
    jmp .m_done
.check_max_y:
    cmp word [mouseY], 187
    jle .m_done
    mov word [mouseY], 187

.m_done:
    mov byte [mouse_updated], 1
    popa
    pop ds
    retf

save_cursor_bg:
    pusha
    push es
    mov ax, 0xA000
    mov es, ax
    mov si, cursor_bg_buffer
    
    mov dx, [mouseY]
    mov bx, [mouseX]
    
    mov cx, 12 ; height
.row:
    push cx
    push bx
    
    mov di, dx
    mov ax, di
    shl di, 8
    shl ax, 6
    add di, ax
    add di, bx
    
    mov cx, 8 ; width
.col:
    mov al, [es:di]
    mov [si], al
    inc di
    inc si
    loop .col
    
    pop bx
    pop cx
    inc dx
    loop .row
    
    pop es
    popa
    ret

restore_cursor_bg:
    pusha
    push es
    mov ax, 0xA000
    mov es, ax
    mov si, cursor_bg_buffer
    
    mov dx, [oldMouseY]
    mov bx, [oldMouseX]
    
    mov cx, 12 ; height
.row:
    push cx
    push bx
    
    mov di, dx
    mov ax, di
    shl di, 8
    shl ax, 6
    add di, ax
    add di, bx
    
    mov cx, 8 ; width
.col:
    mov al, [si]
    mov [es:di], al
    inc di
    inc si
    loop .col
    
    pop bx
    pop cx
    inc dx
    loop .row
    
    pop es
    popa
    ret

draw_cursor_at_mouse:
    pusha
    mov ax, [mouseX]
    mov [rx], ax
    mov ax, [mouseY]
    mov [ry], ax
    call draw_cursor
    popa
    ret

draw_rect_3d:
    pusha
    call fill_rect
    
    ; Outer Highlight
    mov ax, [rx]
    mov bx, [ry]
    mov cx, [rw]
    mov dx, [rh]
    
    mov byte [rc], 15
    mov word [rh], 1
    call fill_rect ; Top
    mov word [rh], dx
    mov word [rw], 1
    call fill_rect ; Left
    
    ; Outer Shadow
    mov byte [rc], 0
    mov ax, [rx]
    add ax, cx
    dec ax
    mov [rx], ax
    call fill_rect ; Right
    
    mov ax, [rx]
    sub ax, cx
    inc ax
    mov [rx], ax
    mov bx, [ry]
    add bx, dx
    dec bx
    mov [ry], bx
    mov word [rw], cx
    mov word [rh], 1
    call fill_rect ; Bottom
    
    popa
    ret


; ============================================================================
; draw_spinner: paints 8 dots on a circle around (160,130), with the
;   "head" at frame%8 being brightest and a trailing comet behind it.
;
;   dot index i (0..7):
;     angle = i * 45 degrees, starting at top (i=0 is straight up)
;   precomputed offsets (dx, dy) for radius 12:
;     i=0  ( 0,-12)   top
;     i=1  ( 8, -8)   top-right
;     i=2  (12,  0)   right
;     i=3  ( 8,  8)   bottom-right
;     i=4  ( 0, 12)   bottom
;     i=5  (-8,  8)   bottom-left
;     i=6  (-12, 0)   left
;     i=7  (-8, -8)   top-left
;
;   Brightness mapping (distance behind head in dots):
;     0 (head)       -> color 8 (white)
;     1              -> color 3 (accent blue, bright)
;     2              -> color 11 (mid blue)
;     3              -> color 12 (dim blue)
;     4..7           -> color 13 (very dim / near bg)
; ============================================================================

draw_spinner:
    pusha

    ; First, erase the spinner area by filling a small box behind it
    ; (16+12 px each side -> 32x32 box centered at 160,130 -> top-left 144,114).
    mov word [rx], 144
    mov word [ry], 114
    mov word [rw], 32
    mov word [rh], 32
    mov byte [rc], 1                ; bg color
    call fill_rect

    ; head = frame % 8
    mov ax, [frame]
    and ax, 7
    mov [head], al

    ; For each of 8 dots, compute its "distance behind head" and pick color.
    mov cx, 8
    mov bx, 0                       ; bx = dot index i
.dot_loop:
    push cx

    ; distance = (head - i) & 7
    mov al, [head]
    sub al, bl
    and al, 7
    mov [dist], al

    ; pick color from brightness table
    mov si, brightness_table
    add si, ax                      ; ax = dist (0..7), high byte is 0
    mov al, [si]
    mov [rc], al

    ; compute pixel coords:
    ;   offsetX = dot_offsets[i*2 + 0]    (signed byte)
    ;   offsetY = dot_offsets[i*2 + 1]    (signed byte)
    mov si, dot_offsets
    mov ax, bx
    shl ax, 1                       ; i*2
    add si, ax

    ; X = 160 + (signed) offset
    mov al, [si]
    cbw                             ; sign-extend AL into AX
    add ax, 160
    sub ax, 2                       ; center the 4x4 dot on the point
    mov [rx], ax

    ; Y = 130 + (signed) offset
    mov al, [si+1]
    cbw
    add ax, 130
    sub ax, 2
    mov [ry], ax

    mov word [rw], 4
    mov word [rh], 4
    call fill_rect

    inc bx
    pop cx
    loop .dot_loop

    popa
    ret

brightness_table:
    ; index = distance behind head (0..7)
    db 8        ; 0: head - white
    db 3        ; 1: accent bright blue
    db 11       ; 2: mid blue
    db 12       ; 3: dim blue
    db 13       ; 4: very dim
    db 13       ; 5
    db 13       ; 6
    db 13       ; 7

dot_offsets:
    db   0, -12      ; i=0  top
    db   8,  -8      ; i=1  top-right
    db  12,   0      ; i=2  right
    db   8,   8      ; i=3  bottom-right
    db   0,  12      ; i=4  bottom
    db  -8,   8      ; i=5  bottom-left
    db -12,   0      ; i=6  left
    db  -8,  -8      ; i=7  top-left


; ============================================================================
; ============================================================================
; BIOS Menu Entry
; ============================================================================
bios_menu_entry:
    pusha
    mov byte [selected_option], 0

.menu_loop:
    mov al, 10                      ; Windows Blue background
    call clear_screen

    ; Title "Choose an option"
    mov word [rx], 96
    mov word [ry], 32
    mov byte [rc], 8                ; White
    mov si, str_bios_title
    call draw_text

    call draw_tiles

    ; Wait for key
    mov ah, 0
    int 0x16

    ; Navigation
    cmp ah, 0x4B                    ; Left Arrow
    je .prev_option
    cmp ah, 0x4D                    ; Right Arrow
    je .next_option
    cmp al, 13                      ; Enter
    je .select_option
    jmp .menu_loop

.prev_option:
    dec byte [selected_option]
    jns .menu_loop
    mov byte [selected_option], 2
    jmp .menu_loop

.next_option:
    inc byte [selected_option]
    cmp byte [selected_option], 3
    jb .menu_loop
    mov byte [selected_option], 0
    jmp .menu_loop

.select_option:
    mov al, [selected_option]
    cmp al, 0
    je .done                        ; Continue
    cmp al, 1
    je .reboot                      ; Reboot
    cmp al, 2
    je .shutdown                    ; Shutdown
    jmp .menu_loop

.reboot:
    int 0x19

.shutdown:
    ; APM Shutdown
    mov ax, 0x5301
    xor bx, bx
    int 0x15
    mov ax, 0x530e
    xor bx, bx
    mov cx, 0x0102
    int 0x15
    mov ax, 0x5307
    mov bx, 0x0001
    mov cx, 0x0003
    int 0x15

    ; Fallback: just hang
.hang:
    cli
    hlt
    jmp .hang

.done:
    popa
    ret

; ============================================================================
; draw_tiles: renders three 60x60 square tiles for BIOS menu
; ============================================================================
draw_tiles:
    pusha

    ; Tile 0: Continue
    mov word [tile_x], 35
    mov byte [rc], 2                ; Slightly lighter than background
    call .draw_single_tile
    mov word [rx], 48
    mov word [ry], 112
    mov byte [rc], 8
    mov si, str_continue
    call draw_text

    ; Tile 1: Reboot
    mov word [tile_x], 130
    mov byte [rc], 2
    call .draw_single_tile
    mov word [rx], 144
    mov word [ry], 112
    mov byte [rc], 8
    mov si, str_reboot
    call draw_text

    ; Tile 2: Shutdown
    mov word [tile_x], 225
    mov byte [rc], 2
    call .draw_single_tile
    mov word [rx], 232
    mov word [ry], 112
    mov byte [rc], 8
    mov si, str_shutdown
    call draw_text

    popa
    ret

.draw_single_tile:
    ; Check if this tile is selected
    mov al, [selected_option]
    mov bl, 0
    cmp word [tile_x], 35
    je .check_sel
    inc bl
    cmp word [tile_x], 130
    je .check_sel
    inc bl
.check_sel:
    cmp al, bl
    jne .not_selected

    ; Draw white border for selected tile
    mov ax, [tile_x]
    sub ax, 2
    mov [rx], ax
    mov word [ry], 78
    mov word [rw], 64
    mov word [rh], 64
    mov byte [rc], 8                ; White
    call fill_rect

.not_selected:
    mov ax, [tile_x]
    mov [rx], ax
    mov word [ry], 80
    mov word [rw], 60
    mov word [rh], 60
    mov byte [rc], 2                ; Tile color
    call fill_rect
    ret


; ============================================================================
draw_desktop:
    pusha

    call draw_bg_pattern

    ; Top menu bar
    mov word [rx],0
    mov word [ry],0
    mov word [rw],320
    mov word [rh],10
    mov byte [rc],2
    call fill_rect

    ; --- Desktop Icons ---
    ; This PC icon
    mov word [rx], 20
    mov word [ry], 20
    mov si, this_pc_icon
    call draw_icon
    
    ; This PC text
    mov word [rx], 0
    mov word [ry], 40
    mov byte [rc], 4
    mov si, str_this_pc
    call draw_text

    ; Recycle Bin icon
    mov word [rx], 20
    mov word [ry], 60
    mov si, recycle_bin_icon
    call draw_icon

    ; Recycle text
    mov word [rx], 0
    mov word [ry], 80
    mov byte [rc], 4
    mov si, str_recycle
    call draw_text

    ; Taskbar
    mov word [rx],0
    mov word [ry],176
    mov word [rw],320
    mov word [rh],24
    mov byte [rc],5
    call fill_rect

    ; Centered Start button
    mov word [rx],100
    mov word [ry],184
    mov word [rw],58
    mov word [rh],12
    mov byte [rc],3
    call draw_rect_3d

    ; Start button icon (4 white squares)
    mov byte [rc], 8
    mov word [rw], 2
    mov word [rh], 2
    
    mov word [rx], 104
    mov word [ry], 188
    call fill_rect
    
    mov word [rx], 107
    mov word [ry], 188
    call fill_rect
    
    mov word [rx], 104
    mov word [ry], 191
    call fill_rect
    
    mov word [rx], 107
    mov word [ry], 191
    call fill_rect

    ; Search button next to Start
    mov word [rx],162
    mov word [ry],184
    mov word [rw],54
    mov word [rh],12
    mov byte [rc],2
    call draw_rect_3d

    ; Clock area
    mov word [rx],270
    mov word [ry],184
    mov word [rw],46
    mov word [rh],12
    mov byte [rc],2
    call draw_rect_3d

    ; Window body
    mov word [rx],80
    mov word [ry],40
    mov word [rw],180
    mov word [rh],120
    mov byte [rc],6
    call draw_rect_3d

    ; Title bar
    mov word [rx],80
    mov word [ry],40
    mov word [rw],180
    mov word [rh],12
    mov byte [rc],7
    call draw_rect_3d

    ; Title bar buttons: Minimize, Maximize, Close
    ; Minimize
    mov word [rx],234
    mov word [ry],43
    mov word [rw],6
    mov word [rh],6
    mov byte [rc],3
    call draw_rect_3d

    ; Maximize
    mov word [rx],244
    mov word [ry],43
    mov word [rw],6
    mov word [rh],6
    mov byte [rc],3
    call draw_rect_3d

    ; Close (Red)
    mov word [rx],254
    mov word [ry],43
    mov word [rw],6
    mov word [rh],6
    mov byte [rc],9
    call draw_rect_3d

    ; --- Text Elements ---
    ; Top menu bar text
    mov word [rx], 8
    mov word [ry], 1
    mov byte [rc], 4
    mov si, str_menu
    call draw_text

    ; Window title
    mov word [rx], 88
    mov word [ry], 42
    mov byte [rc], 8
    mov si, str_window_title
    call draw_text

    ; Window body text
    mov byte [rc], 4
    mov word [rx], 88
    mov word [ry], 60
    mov si, str_welcome1
    call draw_text

    mov word [ry], 76
    mov si, str_welcome2
    call draw_text

    mov word [ry], 92
    mov si, str_welcome3
    call draw_text

    mov word [ry], 140
    mov si, str_press_key
    call draw_text

    ; Taskbar items text
    mov byte [rc], 8
    mov word [rx], 109
    mov word [ry], 186
    mov si, str_start
    call draw_text

    mov word [rx], 165
    mov si, str_search
    call draw_text

    mov word [rx], 276
    mov si, str_clock
    call draw_text

    popa
    ret


; ============================================================================
; draw_cursor: small white arrow at (rx, ry)
draw_cursor:
    pusha
    mov byte [rc],8

    mov ax, [rx]
    mov bx, [ry]

    mov word [rw],1
    mov word [rh],1
    call fill_rect

    mov word [ry],bx
    inc word [ry]
    mov word [rw],2
    call fill_rect
    
    inc word [ry]
    mov word [rw],3
    call fill_rect
    
    inc word [ry]
    mov word [rw],4
    call fill_rect
    
    inc word [ry]
    mov word [rw],5
    call fill_rect
    
    inc word [ry]
    mov word [rw],6
    call fill_rect
    
    inc word [ry]
    mov word [rw],7
    call fill_rect
    
    inc word [ry]
    mov word [rw],4
    call fill_rect
    
    inc word [ry]
    mov word [rx],ax
    add word [rx],2
    mov word [rw],2
    call fill_rect
    
    inc word [ry]
    mov word [rx],ax
    add word [rx],3
    mov word [rw],2
    mov word [rh],3
    call fill_rect

    popa
    ret


; ============================================================================
; install_palette: program DAC entries 0..15 (modern-dark / Win11-ish)
; ============================================================================
install_palette:
    pusha
    mov dx,0x03C8
    mov al,0
    out dx,al
    inc dx
    mov si,palette_data
    mov cx,16*3
.next:
    lodsb
    out dx,al
    loop .next
    popa
    ret

palette_data:
    db  0,  0,  0      ; 0 black
    db  7,  7, 11      ; 1 background  (#1e1e2e)
    db 10, 10, 15      ; 2 panel       (#2a2a3d)
    db 30, 40, 61      ; 3 accent blue (#7aa2f7) - bright
    db 51, 53, 61      ; 4 text light
    db  6,  6,  9      ; 5 taskbar
    db 12, 12, 17      ; 6 window bg
    db 17, 17, 22      ; 7 title bar
    db 63, 63, 63      ; 8 white (spinner head)
    db 63,  5,  5      ; 9 close red
    db  0, 30, 53      ; 10 Windows Blue
    db 20, 27, 40      ; 11 mid blue (spinner trail-1)
    db 14, 18, 28      ; 12 dim blue (spinner trail-2)
    db 10, 13, 20      ; 13 very dim blue (spinner trail-3+)
    db 30, 30, 35      ; 14
    db 45, 45, 50      ; 15


; ============================================================================
; clear_screen(al=color)
; ============================================================================
clear_screen:
    pusha
    push es
    mov bx,0xA000
    mov es,bx
    xor di,di
    mov ah,al
    mov cx,(320*200)/2
    rep stosw
    pop es
    popa
    ret


; ============================================================================
; fill_rect: reads rx, ry, rw, rh, rc and draws filled rectangle in mode 13h.
; ============================================================================
fill_rect:
    pusha
    push es
    mov ax, 0xA000
    mov es, ax

    mov ax, [ry]
    mov di, ax
    shl ax, 8
    shl di, 6
    add di, ax
    add di, [rx]

    mov dx, [rh]
    mov al, [rc]
.row:
    mov cx, [rw]
    push di
    rep stosb
    pop di
    add di, 320
    dec dx
    jnz .row

    pop es
    popa
    ret


; ============================================================================
; draw_bg_pattern: fills screen with color 1 and subtle dots of color 2
; ============================================================================
draw_bg_pattern:
    pusha
    mov al, 1
    call clear_screen
    
    mov ax, 0xA000
    mov es, ax
    
    mov word [ry], 0
.y_loop:
    mov word [rx], 0
.x_loop:
    mov ax, [rx]
    test ax, 7
    jnz .next_x
    mov ax, [ry]
    test ax, 7
    jnz .next_x
    
    mov di, [ry]
    mov bx, di
    shl di, 8
    shl bx, 6
    add di, bx
    add di, [rx]
    mov byte [es:di], 2
    
.next_x:
    inc word [rx]
    cmp word [rx], 320
    jb .x_loop
    
    inc word [ry]
    cmp word [ry], 200
    jb .y_loop
    
    popa
    ret


; ============================================================================
; draw_icon: draws 16x16 icon from SI at (rx, ry)
; ============================================================================
draw_icon:
    pusha
    push es
    mov ax, 0xA000
    mov es, ax
    
    mov bx, [ry]
    mov cx, 16
.row:
    push bx
    mov di, bx
    shl bx, 8
    shl di, 6
    add di, bx
    add di, [rx]
    
    push cx
    mov cx, 16
.col:
    lodsb
    or al, al
    jz .skip
    mov [es:di], al
.skip:
    inc di
    loop .col
    pop cx
    
    pop bx
    inc bx
    loop .row
    
    pop es
    popa
    ret


; ============================================================================
; draw_text: draws string SI at (rx, ry) with color rc using BIOS 8x8 font
; ============================================================================
draw_text:
    pusha
    push es
    
    ; Save initial coordinates
    mov ax, [rx]
    mov [temp_x], ax
    mov ax, [ry]
    mov [temp_y], ax
    
    ; Get BIOS 8x8 font pointer
    mov ax, 0x1130
    mov bh, 0x03
    int 0x10
    ; es:bp points to font
    
    mov dx, es ; save font segment
    
.char_loop:
    lodsb
    or al, al
    jz .done
    
    pusha
    ; char in AL
    mov bl, al
    xor bh, bh
    shl bx, 3 ; bx * 8
    add bp, bx
    
    mov es, dx ; restore font segment
    
    mov cx, 8 ; 8 rows
.row_loop:
    mov al, [es:bp] ; get font byte
    push cx
    mov cx, 8 ; 8 pixels
.pixel_loop:
    test al, 0x80
    jz .skip_pixel
    
    ; Draw pixel
    pusha
    mov ax, 0xA000
    mov es, ax
    mov di, [temp_y]
    mov bx, di
    shl di, 8
    shl bx, 6
    add di, bx
    add di, [temp_x]
    mov al, [rc]
    mov [es:di], al
    popa
    
.skip_pixel:
    shl al, 1
    inc word [temp_x]
    loop .pixel_loop
    
    pop cx
    sub word [temp_x], 8
    inc word [temp_y]
    inc bp
    loop .row_loop
    
    popa
    add word [temp_x], 8
    jmp .char_loop

.done:
    pop es
    popa
    ret


; ============================================================================
set_cursor:
    mov ah,0x02
    mov bh,0
    int 0x10
    ret

print_str:
    pusha
.next:
    lodsb
    or al,al
    jz .done
    mov ah,0x0E
    mov bx,0x0004
    int 0x10
    jmp .next
.done:
    popa
    ret


; ============================================================================
; Delays
; ============================================================================
short_delay:
    pusha
    mov cx,0x0020
    mov dx,0xFFFF
.d:
    dec dx
    jnz .d
    dec cx
    jnz .d
    popa
    ret

long_delay:
    pusha
    mov cx,0x0100
    mov dx,0xFFFF
.d:
    dec dx
    jnz .d
    dec cx
    jnz .d
    popa
    ret


; ============================================================================
; Globals
; ============================================================================
is_bios_mode    dw 0
selected_option db 0
tile_x          dw 0
rx    dw 0
ry    dw 0
rw    dw 0
rh    dw 0
rc    db 0
frame dw 0
head  db 0
dist  db 0
temp_x dw 0
temp_y dw 0

mouseX          dw 160
mouseY          dw 100
mouseButtons    db 0
oldMouseX       dw 160
oldMouseY       dw 100
mouse_updated   db 0
cursor_bg_buffer times 256 db 0

this_pc_icon:
    db 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    db 0, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 0
    db 0, 15, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 15, 0
    db 0, 15, 8, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 8, 15, 0
    db 0, 15, 8, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 8, 15, 0
    db 0, 15, 8, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 8, 15, 0
    db 0, 15, 8, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 8, 15, 0
    db 0, 15, 8, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 8, 15, 0
    db 0, 15, 8, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 8, 15, 0
    db 0, 15, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 15, 0
    db 0, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 0
    db 0, 0, 0, 0, 0, 0, 15, 15, 15, 15, 0, 0, 0, 0, 0, 0
    db 0, 0, 0, 0, 0, 15, 15, 15, 15, 15, 15, 0, 0, 0, 0, 0
    db 0, 0, 0, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 0, 0, 0
    db 0, 0, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 0, 0
    db 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0

recycle_bin_icon:
    db 0, 0, 0, 0, 0, 15, 15, 15, 15, 15, 15, 0, 0, 0, 0, 0
    db 0, 0, 0, 0, 15, 15, 15, 15, 15, 15, 15, 15, 0, 0, 0, 0
    db 0, 0, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 0, 0
    db 0, 0, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 0, 0
    db 0, 0, 0, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 0, 0, 0
    db 0, 0, 0, 15, 8, 15, 8, 15, 8, 15, 8, 15, 15, 0, 0, 0
    db 0, 0, 0, 15, 8, 15, 8, 15, 8, 15, 8, 15, 15, 0, 0, 0
    db 0, 0, 0, 15, 8, 15, 8, 15, 8, 15, 8, 15, 15, 0, 0, 0
    db 0, 0, 0, 15, 8, 15, 8, 15, 8, 15, 8, 15, 15, 0, 0, 0
    db 0, 0, 0, 15, 8, 15, 8, 15, 8, 15, 8, 15, 15, 0, 0, 0
    db 0, 0, 0, 15, 8, 15, 8, 15, 8, 15, 8, 15, 15, 0, 0, 0
    db 0, 0, 0, 15, 8, 15, 8, 15, 8, 15, 8, 15, 15, 0, 0, 0
    db 0, 0, 0, 0, 15, 15, 15, 15, 15, 15, 15, 15, 0, 0, 0, 0
    db 0, 0, 0, 0, 15, 15, 15, 15, 15, 15, 15, 15, 0, 0, 0, 0
    db 0, 0, 0, 0, 0, 15, 15, 15, 15, 15, 15, 0, 0, 0, 0, 0
    db 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0

; ============================================================================
; Strings
; ============================================================================
str_title        db "RLVAL OS",0
str_footer       db "RLVAL Corporation",0
str_menu         db "RLVAL OS  File  Edit  View  Help",0
str_window_title db "Welcome",0
str_welcome1     db "Hello, world!",0
str_welcome2     db "RLVAL OS booted.",0
str_welcome3     db "VGA 13h (320x200).",0
str_press_key    db "[Press any key to reboot]",0
str_start        db "Start",0
str_search       db "Search",0
str_this_pc      db "This PC",0
str_recycle      db "Recycle",0
str_clock        db "12:34",0

; BIOS Menu Strings
str_bios_title   db "Choose an option",0
str_continue     db "Continue",0
str_reboot       db "Reboot",0
str_shutdown     db "Shutdown",0


; ============================================================================
; Pad kernel to 32 sectors (16 KB)
; ============================================================================
times 16384-($-$$) db 0
