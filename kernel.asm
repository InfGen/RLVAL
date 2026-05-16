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
    mov al, 0
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
    mov byte [need_redraw], 1
    call init_mouse
    
.main_loop:
    ; Check if mouse updated
    cmp byte [mouse_updated], 1
    je .handle_mouse
    
    ; Check if keyboard updated
    mov ah, 1
    int 0x16
    jnz .handle_keyboard
    
    ; If nothing happened but need_redraw is set
    cmp byte [need_redraw], 1
    je .do_render
    
    jmp .main_loop

.handle_mouse:
    mov byte [mouse_updated], 0
    
    ; --- Handle Window Interactions ---
    ; Check for Left Button Down (bit 0 of mouseButtons)
    mov al, [mouseButtons]
    test al, 1
    jz .not_dragging
    
    ; Was it already down?
    mov al, [prevMouseButtons]
    test al, 1
    jnz .continue_drag
    
    ; Left button just pressed - Hit detection
    
    ; 1. Check Taskbar (Y >= 180)
    mov ax, [mouseY]
    cmp ax, 180
    jl .check_start_menu
    
    ; Start Button? (X < 36)
    mov ax, [mouseX]
    cmp ax, 36
    jg .done_mouse ; For now, ignore other taskbar clicks
    
    xor byte [startMenuVisible], 1
    mov byte [need_redraw], 1
    jmp .done_mouse

.check_start_menu:
    cmp byte [startMenuVisible], 0
    je .check_window
    
    ; Inside Start Menu? (X < 120, Y between 70 and 180)
    mov ax, [mouseX]
    cmp ax, 120
    jg .close_start_menu
    mov ax, [mouseY]
    cmp ax, 70
    jl .close_start_menu
    ; Y < 180 is already true from previous check
    
    ; Check Tiles
    ; Terminal Tile (X: 10-55, Y: 80-125)
    mov ax, [mouseX]
    cmp ax, 10
    jl .check_calc_tile
    cmp ax, 55
    jg .check_calc_tile
    mov ax, [mouseY]
    cmp ax, 80
    jl .check_calc_tile
    cmp ax, 125
    jg .check_calc_tile
    
    mov byte [windowVisible], 1
    mov byte [windowType], 1 ; Terminal
    mov byte [startMenuVisible], 0
    mov byte [need_redraw], 1
    jmp .done_mouse

.check_calc_tile:
    ; Calculator Tile (X: 65-110, Y: 80-125)
    mov ax, [mouseX]
    cmp ax, 65
    jl .done_mouse ; Inside menu but no tile
    cmp ax, 110
    jg .done_mouse
    mov ax, [mouseY]
    cmp ax, 80
    jl .done_mouse
    cmp ax, 125
    jg .done_mouse
    
    mov byte [windowVisible], 1
    mov byte [windowType], 2 ; Calculator
    mov byte [startMenuVisible], 0
    mov byte [need_redraw], 1
    jmp .done_mouse

.close_start_menu:
    mov byte [startMenuVisible], 0
    mov byte [need_redraw], 1
    ; Fall through to check window

.check_window:
    ; 2. Check Window (if visible)
    cmp byte [windowVisible], 0
    je .check_icons
    
    ; Close button
    mov ax, [mouseX]
    mov bx, [windowX]
    add bx, 175
    cmp ax, bx
    jl .check_window_title
    add bx, 25
    cmp ax, bx
    jg .check_window_title
    mov ax, [mouseY]
    mov bx, [windowY]
    cmp ax, bx
    jl .check_window_title
    add bx, 22
    cmp ax, bx
    jg .check_window_title
    
    mov byte [windowVisible], 0
    mov byte [need_redraw], 1
    jmp .done_mouse

.check_window_title:
    mov ax, [mouseX]
    mov bx, [windowX]
    cmp ax, bx
    jl .check_icons
    add bx, 200
    cmp ax, bx
    jg .check_icons
    mov ax, [mouseY]
    mov bx, [windowY]
    cmp ax, bx
    jl .check_icons
    add bx, 22
    cmp ax, bx
    jg .check_icons
    
    mov byte [isDragging], 1
    mov ax, [mouseX]
    sub ax, [windowX]
    mov [dragOffsetX], ax
    mov ax, [mouseY]
    sub ax, [windowY]
    mov [dragOffsetY], ax
    jmp .done_mouse

.check_icons:
    ; Check Terminal Icon (X: 28-44, Y: 100-116)
    mov ax, [mouseX]
    cmp ax, 28
    jl .check_this_pc
    cmp ax, 44
    jg .check_this_pc
    mov ax, [mouseY]
    cmp ax, 100
    jl .check_this_pc
    cmp ax, 116
    jg .check_this_pc
    
    mov byte [windowVisible], 1
    mov byte [windowType], 1 ; Terminal
    mov byte [need_redraw], 1
    jmp .done_mouse

.check_this_pc:
    ; Check This PC Icon (X: 28-44, Y: 20-36)
    mov ax, [mouseX]
    cmp ax, 28
    jl .check_recycle
    cmp ax, 44
    jg .check_recycle
    mov ax, [mouseY]
    cmp ax, 20
    jl .check_recycle
    cmp ax, 36
    jg .check_recycle
    
    mov byte [windowVisible], 1
    mov byte [windowType], 0 ; Welcome/This PC
    mov byte [need_redraw], 1
    jmp .done_mouse

.check_recycle:
    ; Check Recycle Bin Icon (X: 28-44, Y: 60-76)
    mov ax, [mouseX]
    cmp ax, 28
    jl .done_mouse
    cmp ax, 44
    jg .done_mouse
    mov ax, [mouseY]
    cmp ax, 60
    jl .done_mouse
    cmp ax, 76
    jg .done_mouse
    
    mov byte [windowVisible], 1
    mov byte [windowType], 0 ; Recycle
    mov byte [need_redraw], 1
    jmp .done_mouse

.continue_drag:
    cmp byte [isDragging], 1
    jne .done_mouse
    
    ; Update window position
    mov ax, [mouseX]
    sub ax, [dragOffsetX]
    mov [windowX], ax
    mov ax, [mouseY]
    sub ax, [dragOffsetY]
    mov [windowY], ax
    mov byte [need_redraw], 1
    jmp .done_mouse

.not_dragging:
    mov byte [isDragging], 0


.done_mouse:
    mov al, [mouseButtons]
    mov [prevMouseButtons], al
    jmp .do_render

.handle_keyboard:
    mov ah, 0
    int 0x16
    
    ; If Terminal is visible, handle input there
    cmp byte [windowVisible], 1
    jne .reboot_check
    cmp byte [windowType], 1
    jne .reboot_check
    
    ; Handle Enter (process command)
    cmp al, 13
    je .process_command
    
    ; Handle Backspace
    cmp al, 8
    je .handle_backspace
    
    ; Handle printable chars
    cmp al, 32
    jl .main_loop
    cmp al, 126
    jg .main_loop
    
    ; Append to buffer if not full
    mov bx, [term_buffer_len]
    cmp bx, 60 ; max length
    jae .main_loop
    
    mov di, term_buffer
    add di, bx
    mov [di], al
    inc word [term_buffer_len]
    mov byte [di+1], 0 ; Null terminate
    mov byte [need_redraw], 1
    jmp .do_render
    
.handle_backspace:
    mov bx, [term_buffer_len]
    or bx, bx
    jz .main_loop
    dec word [term_buffer_len]
    dec bx
    mov di, term_buffer
    add di, bx
    mov byte [di], 0
    mov byte [need_redraw], 1
    jmp .do_render
    
.process_command:
    ; check 'exit'
    mov si, term_buffer
    cmp byte [si], 'e'
    jne .check_cls
    cmp byte [si+1], 'x'
    jne .check_cls
    cmp byte [si+2], 'i'
    jne .check_cls
    cmp byte [si+3], 't'
    jne .check_cls
    cmp byte [si+4], 0
    jne .check_cls
    mov byte [windowVisible], 0
    mov byte [need_redraw], 1
    jmp .clear_buffer


.check_cls:
    ; check 'cls'
    mov si, term_buffer
    cmp byte [si], 'c'
    jne .clear_buffer
    cmp byte [si+1], 'l'
    jne .clear_buffer
    cmp byte [si+2], 's'
    jne .clear_buffer
    cmp byte [si+3], 0
    jne .clear_buffer
    ; fallthrough to clear_buffer

.clear_buffer:
    mov word [term_buffer_len], 0
    push es
    push ds
    pop es
    mov di, term_buffer
    mov cx, 64
    xor al, al
    rep stosb
    pop es
    mov byte [need_redraw], 1
    jmp .do_render

.reboot_check:
    int 0x19

.do_render:
    mov byte [need_redraw], 0
    
    ; Redraw everything to backbuffer
    mov word [draw_seg], BUF_SEG
    call draw_desktop
    
    ; Draw cursor to backbuffer
    mov ax, [mouseX]
    mov [rx], ax
    mov ax, [mouseY]
    mov [ry], ax
    call draw_cursor
    
    ; Flip
    call flip_buffer
    jmp .main_loop

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
    mov byte [rc], 0                ; bg color (black)
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
    mov word [rx], 28
    mov word [ry], 20
    mov si, this_pc_icon
    call draw_icon
    
    ; This PC text
    mov word [rx], 8
    mov word [ry], 40
    mov byte [rc], 4
    mov si, str_this_pc
    call draw_text

    ; Recycle Bin icon
    mov word [rx], 28
    mov word [ry], 60
    mov si, recycle_bin_icon
    call draw_icon

    ; Recycle text
    mov word [rx], 8
    mov word [ry], 80
    mov byte [rc], 4
    mov si, str_recycle
    call draw_text

    ; Terminal icon
    mov word [rx], 28
    mov word [ry], 100
    mov si, terminal_icon
    call draw_icon

    ; Terminal text
    mov word [rx], 8
    mov word [ry], 120
    mov byte [rc], 4
    mov si, str_terminal
    call draw_text

    ; Taskbar
    mov word [rx],0
    mov word [ry],180
    mov word [rw],320
    mov word [rh],20
    mov byte [rc],5 ; Dark Gray
    call fill_rect

    ; Start button
    mov word [rx],0
    mov word [ry],180
    mov word [rw],36
    mov word [rh],20
    mov byte [rc],5
    call fill_rect

    ; Windows logo in Start button
    mov byte [rc], 8
    mov word [rw], 6
    mov word [rh], 6
    mov word [rx], 11
    mov word [ry], 184
    call fill_rect
    mov word [rx], 19
    mov word [ry], 184
    call fill_rect
    mov word [rx], 11
    mov word [ry], 191
    call fill_rect
    mov word [rx], 19
    mov word [ry], 191
    call fill_rect

    ; Search box
    mov word [rx],36
    mov word [ry],182
    mov word [rw],80
    mov word [rh],16
    mov byte [rc],10 ; White/Light gray
    call fill_rect

    mov word [rx], 40
    mov word [ry], 186
    mov byte [rc], 4 ; Gray text
    mov si, str_search
    call draw_text

    ; System Tray
    mov word [rx], 280
    mov word [ry], 180
    mov word [rw], 40
    mov word [rh], 20
    mov byte [rc], 5
    call fill_rect
    
    mov word [rx], 285
    mov word [ry], 186
    mov byte [rc], 8
    mov si, str_clock
    call draw_text

    ; Start Menu
    cmp byte [startMenuVisible], 1
    jne .skip_start_menu
    call draw_start_menu
.skip_start_menu:

    ; Window body (Flat)
    cmp byte [windowVisible], 0
    je .skip_window

    mov ax, [windowX]
    mov [rx], ax
    mov ax, [windowY]
    mov [ry], ax
    mov word [rw], 200
    mov word [rh], 140
    mov byte [rc], 6 ; Window BG
    call fill_rect

    ; Title bar (Flat, Dark)
    mov ax, [windowX]
    mov [rx], ax
    mov ax, [windowY]
    mov [ry], ax
    mov word [rw], 200
    mov word [rh], 22
    mov byte [rc], 7 ; Title Bar
    call fill_rect

    ; Window title
    mov ax, [windowX]
    add ax, 8
    mov [rx], ax
    mov ax, [windowY]
    add ax, 6
    mov [ry], ax
    mov byte [rc], 8
    
    cmp byte [windowType], 1
    je .term_title
    cmp byte [windowType], 2
    je .calc_title
    mov si, str_window_title
    jmp .draw_t
.term_title:
    mov si, str_term_title
    jmp .draw_t
.calc_title:
    mov si, str_calc_title
.draw_t:
    call draw_text

    ; Close button (Red rectangle with X)
    mov ax, [windowX]
    add ax, 175
    mov [rx], ax
    mov ax, [windowY]
    mov [ry], ax
    mov word [rw], 25
    mov word [rh], 22
    mov byte [rc], 9 ; Red
    call fill_rect
    
    ; 'X' on Close button
    mov ax, [windowX]
    add ax, 185
    mov [rx], ax
    mov ax, [windowY]
    add ax, 6
    mov [ry], ax
    mov byte [rc], 8 ; White
    mov si, str_x
    call draw_text

    ; --- Window Content ---
    cmp byte [windowType], 1
    je .draw_terminal_content
    cmp byte [windowType], 2
    je .draw_calc_content

    ; Welcome content
    mov byte [rc], 4
    mov ax, [windowX]
    add ax, 8
    mov [rx], ax
    mov ax, [windowY]
    add ax, 40
    mov [ry], ax
    mov si, str_welcome1
    call draw_text

    mov ax, [windowY]
    add ax, 56
    mov [ry], ax
    mov si, str_welcome2
    call draw_text

    mov ax, [windowY]
    add ax, 72
    mov [ry], ax
    mov si, str_welcome3
    call draw_text

    mov ax, [windowY]
    add ax, 120
    mov [ry], ax
    mov si, str_press_key
    call draw_text
    jmp .skip_window

.draw_calc_content:
    mov byte [rc], 4
    mov ax, [windowX]
    add ax, 8
    mov [rx], ax
    mov ax, [windowY]
    add ax, 40
    mov [ry], ax
    mov si, str_calc_text
    call draw_text
    jmp .skip_window

.draw_terminal_content:
    ; Terminal Background
    mov ax, [windowX]
    add ax, 2
    mov [rx], ax
    mov ax, [windowY]
    add ax, 22
    mov [ry], ax
    mov word [rw], 196
    mov word [rh], 116
    mov byte [rc], 0 ; Black
    call fill_rect

    ; Prompt
    mov ax, [windowX]
    add ax, 5
    mov [rx], ax
    mov ax, [windowY]
    add ax, 30
    mov [ry], ax
    mov byte [rc], 3 ; Accent blue
    mov si, str_prompt
    call draw_text

    ; Current buffer
    mov ax, [windowX]
    add ax, 45 ; Offset for "C:\> "
    mov [rx], ax
    mov si, term_buffer
    mov byte [rc], 8 ; White
    call draw_text

    .skip_window:
    popa
    ret

; ============================================================================
; draw_start_menu: dark gray rectangle with tiles
; ============================================================================
draw_start_menu:
    pusha
    
    ; Menu BG
    mov word [rx], 0
    mov word [ry], 70
    mov word [rw], 120
    mov word [rh], 110
    mov byte [rc], 6 ; Start Menu Gray
    call fill_rect
    
    ; "Terminal" Tile
    mov word [rx], 10
    mov word [ry], 80
    mov word [rw], 45
    mov word [rh], 45
    mov byte [rc], 3 ; Blue
    call fill_rect
    
    mov word [rx], 12
    mov word [ry], 115
    mov byte [rc], 8
    mov si, str_terminal_small
    call draw_text
    
    ; "Calculator" Tile
    mov word [rx], 65
    mov word [ry], 80
    mov word [rw], 45
    mov word [rh], 45
    mov byte [rc], 3 ; Blue
    call fill_rect
    
    mov word [rx], 67
    mov word [ry], 115
    mov byte [rc], 8
    mov si, str_calc_small
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
    db  0,  0,  0      ; 0: Black
    db  0, 18, 38      ; 1: Dark Blue (Gradient Bottom)
    db 10, 31, 55      ; 2: Mid Blue (Gradient Top)
    db  0, 48, 86      ; 3: Windows Blue (Tiles)
    db 50, 50, 50      ; 4: Medium Gray
    db  5,  5,  5      ; 5: Dark Gray (Taskbar)
    db  8,  8,  8      ; 6: Start Menu Gray
    db 12, 12, 12      ; 7: Title Bar Gray
    db 63, 63, 63      ; 8: White (Logo, Text)
    db 60,  0,  0      ; 9: Close Red
    db 63, 63, 63      ; 10: Search Box (White)
    db  0, 24, 48      ; 11: Boot Spinner (Mid Blue)
    db  0, 15, 30      ; 12: Boot Spinner (Dim Blue)
    db  0,  8, 16      ; 13: Boot Spinner (Darker Blue)
    db 20, 20, 20      ; 14: Unused
    db 40, 40, 40      ; 15: Unused


; ============================================================================
; flip_buffer: copy BUF_SEG to VGA_SEG
; ============================================================================
flip_buffer:
    pusha
    push ds
    push es
    mov ax, BUF_SEG
    mov ds, ax
    xor si, si
    mov ax, VGA_SEG
    mov es, ax
    xor di, di
    mov cx, 32000
    rep movsw
    pop es
    pop ds
    popa
    ret

; ============================================================================
; clear_screen(al=color)
; ============================================================================
clear_screen:
    pusha
    push es
    mov ax, [draw_seg]
    mov es, ax
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
    mov ax, [draw_seg]
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
; draw_bg_pattern: fills screen with a vertical blue gradient and Hero logo
; ============================================================================
draw_bg_pattern:
    pusha
    push es
    mov ax, [draw_seg]
    mov es, ax
    xor di, di
    
    ; Vertical gradient from index 2 (top) to index 1 (bottom)
    ; 200 rows. We'll use index 2 for top 100 rows and index 1 for bottom 100 rows
    ; Or better: actually interpolate? Mode 13h only has 256 colors.
    ; Let's just do a simple split or a few bands.
    
    mov al, 2 ; Top color
    mov cx, 320 * 100 / 2
    rep stosw
    
    mov al, 1 ; Bottom color
    mov cx, 320 * 100 / 2
    rep stosw
    
    call draw_hero_logo
    
    pop es
    popa
    ret

draw_hero_logo:
    pusha
    ; Draw the 4 panes of the Windows logo
    ; Centered roughly. Screen is 320x200.
    ; Pane size: 30x30 with small gap
    mov byte [rc], 8 ; White
    
    ; Top-Left
    mov word [rx], 128
    mov word [ry], 70
    mov word [rw], 30
    mov word [rh], 30
    call fill_rect
    
    ; Top-Right
    mov word [rx], 162
    mov word [ry], 68
    mov word [rw], 32
    mov word [rh], 32
    call fill_rect
    
    ; Bottom-Left
    mov word [rx], 128
    mov word [ry], 104
    mov word [rw], 30
    mov word [rh], 30
    call fill_rect
    
    ; Bottom-Right
    mov word [rx], 162
    mov word [ry], 104
    mov word [rw], 32
    mov word [rh], 32
    call fill_rect
    
    popa
    ret


; ============================================================================
; draw_icon: draws 16x16 icon from SI at (rx, ry)
; ============================================================================
draw_icon:
    pusha
    push es
    mov ax, [draw_seg]
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
    
    ; Get BIOS 8x8 font pointer
    mov ax, 0x1130
    mov bh, 0x03
    int 0x10
    ; es:bp points to font
    
    mov dx, es ; save font segment
    
.char_loop:
    ; Reset temp_y for the next character to fix staircase bug
    mov ax, [ry]
    mov [temp_y], ax

    lodsb
    or al, al
    jz .done
    
    pusha
    ; char in AL
    mov bl, al
    xor bh, bh
    shl bx, 3 ; bx * 8
    add bp, bx
    
    mov cx, 8 ; 8 rows
.row_loop:
    mov es, dx ; restore font segment
    mov al, [es:bp] ; get font byte
    
    push cx
    mov cx, 8 ; 8 pixels
.pixel_loop:
    test al, 0x80
    jz .skip_pixel
    
    ; Draw pixel
    push ax
    push cx

    mov ax, [draw_seg]
    mov es, ax
    mov di, [temp_y]
    mov bx, di
    shl di, 8
    shl bx, 6
    add di, bx
    add di, [temp_x]

    mov al, [rc]
    mov [es:di], al

    pop cx
    pop ax
    
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
VGA_SEG         equ 0xA000
BUF_SEG         equ 0x8000

is_bios_mode    dw 0
draw_seg        dw VGA_SEG
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
prevMouseButtons db 0
mouse_updated   db 0

windowX         dw 80
windowY         dw 40
windowVisible   db 1
windowType      db 0 ; 0=Welcome, 1=Terminal
startMenuVisible db 0
isDragging      db 0
dragOffsetX     dw 0
dragOffsetY     dw 0

; Terminal State
termX           dw 40
termY           dw 30
term_buffer     times 64 db 0
term_buffer_len dw 0

need_redraw     db 0

oldMouseX       dw 160
oldMouseY       dw 100
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

terminal_icon:
    db 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    db 0, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 0
    db 0, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 8, 0
    db 0, 8, 0, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 8, 0
    db 0, 8, 0, 0, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 8, 0
    db 0, 8, 0, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 8, 0
    db 0, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 8, 0
    db 0, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 8, 0
    db 0, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 8, 0
    db 0, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 8, 0
    db 0, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 8, 0
    db 0, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 8, 0
    db 0, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 8, 0
    db 0, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 0
    db 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
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
str_terminal     db "Terminal",0
str_terminal_small db "Term",0
str_calc_small     db "Calc",0
str_clock        db "12:34",0
str_term_title   db "Command Prompt",0
str_calc_title   db "Calculator",0
str_calc_text    db "0",0
str_prompt       db "C:\> ",0
str_x            db "X",0

; BIOS Menu Strings
str_bios_title   db "Choose an option",0
str_continue     db "Continue",0
str_reboot       db "Reboot",0
str_shutdown     db "Shutdown",0


; ============================================================================
; Pad kernel to 64 sectors (32 KB)
; ============================================================================
times 32768-($-$$) db 0
