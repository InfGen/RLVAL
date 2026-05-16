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
    mov ax, cs
    mov ds, ax
    mov es, ax

    ; Mode 13h
    mov ax, 0x0013
    int 0x10

    call install_palette

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
    mov dl, 13
    call set_cursor
    mov si, str_footer
    call print_str

    ; ---- Spinner animation (Windows 11 style) ----
    ; The spinner is centered at (160, 130) with radius 12.
    ; Run ~80 frames -> spinner makes ~10 full revolutions.
    mov word [frame], 0
.spin_loop:
    mov ax, [frame]
    cmp ax, 80
    jae .spin_done

    call draw_spinner
    call short_delay

    inc word [frame]
    jmp .spin_loop
.spin_done:

    call long_delay

    ; ---- Desktop ----
    call draw_desktop

    ; Wait for keypress, then reboot
    mov ah, 0
    int 0x16
    int 0x19

.hang:
    cli
    hlt
    jmp .hang


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
draw_desktop:
    pusha

    mov al, 1
    call clear_screen

    ; Top menu bar
    mov word [rx],0
    mov word [ry],0
    mov word [rw],320
    mov word [rh],10
    mov byte [rc],2
    call fill_rect

    ; --- Desktop Icons ---
    ; This PC icon
    mov word [rx], 12
    mov word [ry], 20
    mov word [rw], 16
    mov word [rh], 16
    mov byte [rc], 3
    call fill_rect
    
    ; This PC text
    mov dh, 5
    mov dl, 1
    call set_cursor
    mov si, str_this_pc
    call print_str

    ; Recycle Bin icon
    mov word [rx], 12
    mov word [ry], 60
    mov word [rw], 16
    mov word [rh], 16
    mov byte [rc], 3
    call fill_rect

    ; Recycle text
    mov dh, 10
    mov dl, 1
    call set_cursor
    mov si, str_recycle
    call print_str

    ; Taskbar
    mov word [rx],0
    mov word [ry],184
    mov word [rw],320
    mov word [rh],16
    mov byte [rc],5
    call fill_rect

    ; Centered Start button (Win11 style)
    mov word [rx],110
    mov word [ry],188
    mov word [rw],44
    mov word [rh],8
    mov byte [rc],3
    call fill_rect

    ; Search button next to Start
    mov word [rx],159
    mov word [ry],188
    mov word [rw],48
    mov word [rh],8
    mov byte [rc],2
    call fill_rect

    ; Clock area
    mov word [rx],270
    mov word [ry],188
    mov word [rw],46
    mov word [rh],8
    mov byte [rc],2
    call fill_rect

    ; Window body (shifted right to make room for icons)
    mov word [rx],80
    mov word [ry],40
    mov word [rw],180
    mov word [rh],120
    mov byte [rc],6
    call fill_rect

    ; Title bar
    mov word [rx],80
    mov word [ry],40
    mov word [rw],180
    mov word [rh],12
    mov byte [rc],7
    call fill_rect

    ; Title bar buttons: Minimize, Maximize, Close
    ; Minimize
    mov word [rx],234
    mov word [ry],43
    mov word [rw],6
    mov word [rh],6
    mov byte [rc],3
    call fill_rect

    ; Maximize
    mov word [rx],244
    mov word [ry],43
    mov word [rw],6
    mov word [rh],6
    mov byte [rc],3
    call fill_rect

    ; Close (Red)
    mov word [rx],254
    mov word [ry],43
    mov word [rw],6
    mov word [rh],6
    mov byte [rc],9
    call fill_rect

    ; Top menu bar text
    mov dh,0
    mov dl,1
    call set_cursor
    mov si,str_menu
    call print_str

    ; Window title
    mov dh,5
    mov dl,11
    call set_cursor
    mov si,str_window_title
    call print_str

    ; Window body text
    mov dh,8
    mov dl,11
    call set_cursor
    mov si,str_welcome1
    call print_str

    mov dh,10
    mov dl,11
    call set_cursor
    mov si,str_welcome2
    call print_str

    mov dh,12
    mov dl,11
    call set_cursor
    mov si,str_welcome3
    call print_str

    mov dh,17
    mov dl,11
    call set_cursor
    mov si,str_press_key
    call print_str

    ; Taskbar items text
    mov dh,23
    mov dl,14
    call set_cursor
    mov si,str_start
    call print_str

    mov dh,23
    mov dl,20
    call set_cursor
    mov si,str_search
    call print_str

    mov dh,23
    mov dl,35
    call set_cursor
    mov si,str_clock
    call print_str

    call draw_cursor

    popa
    ret


; ============================================================================
; draw_cursor: small white arrow at (160,100)
draw_cursor:
    pusha
    mov byte [rc],8

    mov word [rx],160
    mov word [ry],100
    mov word [rw],1
    mov word [rh],1
    call fill_rect

    mov word [rx],160
    mov word [ry],101
    mov word [rw],2
    mov word [rh],1
    call fill_rect

    mov word [rx],160
    mov word [ry],102
    mov word [rw],3
    mov word [rh],1
    call fill_rect

    mov word [rx],160
    mov word [ry],103
    mov word [rw],4
    mov word [rh],1
    call fill_rect

    mov word [rx],160
    mov word [ry],104
    mov word [rw],5
    mov word [rh],1
    call fill_rect

    mov word [rx],160
    mov word [ry],105
    mov word [rw],6
    mov word [rh],1
    call fill_rect

    mov word [rx],160
    mov word [ry],106
    mov word [rw],7
    mov word [rh],1
    call fill_rect

    mov word [rx],160
    mov word [ry],107
    mov word [rw],4
    mov word [rh],1
    call fill_rect

    mov word [rx],162
    mov word [ry],108
    mov word [rw],2
    mov word [rh],1
    call fill_rect

    mov word [rx],163
    mov word [ry],109
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
    db 25, 30, 45      ; 10 (unused)
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
    mov ax,0xA000
    mov es,ax

    mov bp,[rh]
    mov ax,[ry]
.row:
    push ax
    mov di,ax
    mov bx,ax
    shl ax,8
    shl di,6
    add di,ax
    add di,[rx]
    mov cx,[rw]
    mov al,[rc]
.col:
    mov [es:di],al
    inc di
    loop .col
    pop ax
    inc ax
    dec bp
    jnz .row

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
    mov cx,0x0080
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
rx    dw 0
ry    dw 0
rw    dw 0
rh    dw 0
rc    db 0
frame dw 0
head  db 0
dist  db 0


; ============================================================================
; Strings
; ============================================================================
str_title        db "RLVAL OS",0
str_footer       db "RLVAL Corporation",0
str_menu         db "RLVAL OS  File  Edit  View  Help",0
str_window_title db "Welcome",0
str_welcome1     db "Hello, world!",0
str_welcome2     db "RLVAL OS booted successfully.",0
str_welcome3     db "GUI rendered in VGA mode 13h.",0
str_press_key    db "[Press any key to reboot]",0
str_start        db "Start",0
str_search       db "Search",0
str_this_pc      db "This PC",0
str_recycle      db "Recycle",0
str_clock        db "12:34",0


; ============================================================================
; Pad kernel to 32 sectors (16 KB)
; ============================================================================
times 16384-($-$$) db 0
