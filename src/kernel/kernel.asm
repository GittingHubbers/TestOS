[ORG 0x00020000]
BITS 16

start:
    mov AX, CS
    mov DS, AX
    mov ES, AX
    mov SP, 0x0600
    cld
    mov SI, string2
    call print

    lgdt [gdt_descriptor]

    cli
    mov EAX, CR0
    or EAX, 1
    mov CR0, EAX
    jmp dword 0x08:pm_entry

print:
    push si
    push ax
    push bx

print_loop:
    lodsb
    or  al, al
    jz  done_print

    mov ah, 0x0E
    mov bh, 0
    int 0x10
    jmp print_loop

done_print:
    pop bx
    pop ax
    pop si
    ret

boot_drive  db  0

; ---------- FLAT GDT (base=0) ----------
gdt_start:
    dq 0x0000000000000000          ; null descriptor
    dq 0x00CF9A000000FFFF          ; 0x08: 32-bit code, base=0
    dq 0x00CF92000000FFFF          ; 0x10: 32-bit data, base=0
gdt_end:

gdt_descriptor:
    dw gdt_end - gdt_start - 1
    dd gdt_start                   ; ORG already makes this the true linear address

string2 DB  "KERNEL Booting Protected Mode...",10,13,0

[BITS 32]
Error_msg   DB  'Illegal command. Please use "help" for assistance.', 0

Valid_commands  DB  "mkdir",0,"create",0,"delete",0,"echo",0,"dir",0,"clear",0,"edit",0,0 ;0 = mkdir, 1 = create, 2 = delete, 3 = echo, 4 = dir, 5 = clear, 5= edit
cur_row     DD  0
cur_col     DD  0
current_dir DB 96 dup (0)
msg         DB 128 dup(0)
Bottom_Margin   DB  3
input_start_row DD  0
input_start_col DD  0
VGA_Mem         DD  0xB8000

input_max   DB  80
input_buff  DB 80 dup(0)
input_len   DB  0
Active_cmd  DB  0
shift_flg   DB  0   ;0/1



BuildPrompt:
    mov EDI, msg
    cmp byte [current_dir], 0
        jne have_dir

        ;current_dir is empty default to C:\

        mov AL, "C"
        stosb
        mov AL, ':'
        stosb
        mov AL, '\'
        stosb
        mov AL, 0
        stosb
        jmp append_arrow

        have_dir:
            mov ESI, current_dir
        copy:
            lodsb
            stosb
            test AL, AL
                jnz copy

        append_arrow:
            mov BYTE [EDI-1], ' '
            mov byte [edi+0], '>'
            mov byte [EDI+1], ' '
            mov byte [EDI+2], 0
            ret

BytesPerSector      dd 0
SectorsPerCluster   dd 0
ReservedSectors     dd 0
FATCount            dd 0
SectorsPerFAT       dd 0
RootDirEntries      dd 0
RootDirSectors      dd 0
RootDirLBA          dd 0
DataRegionLBA       dd 0
; -------------------------------------------------------------
; ata_pio_read_sector
;   EAX = LBA
;   EDI = buffer (512 bytes)
;   Returns: AL = 0 on success, nonzero on error
; -------------------------------------------------------------
    ; After pushad, stack layout (top -> bottom):
    ;   [ESP+0]  EDI_saved
    ;   [ESP+4]  ESI
    ;   [ESP+8]  EBP
    ;   [ESP+12] ESP_before_pushad
    ;   [ESP+16] EBX
    ;   [ESP+20] EDX
    ;   [ESP+24] ECX
    ;   [ESP+28] EAX
    ;
    ; So original EAX (LBA) is at [ESP+28], original EDI (buffer) at [ESP+0]
;---------------- Wait for BSY=0 before sending command ----------------
ATA_IO_BASE     EQU 0x1F0
ATA_REG_DATA    EQU ATA_IO_BASE + 0
ATA_REG_ERROR   EQU ATA_IO_BASE + 1
ATA_REG_SECCNT  EQU ATA_IO_BASE + 2
ATA_REG_LBA0    EQU ATA_IO_BASE + 3
ATA_REG_LBA1    EQU ATA_IO_BASE + 4
ATA_REG_LBA2    EQU ATA_IO_BASE + 5
ATA_REG_DRIVE   EQU ATA_IO_BASE + 6
ATA_REG_STATUS  EQU ATA_IO_BASE + 7
ATA_REG_COMMAND EQU ATA_IO_BASE + 7

PRIMARY_CTRL    EQU 0x3F6

ATA_SR_BSY      EQU 0x80
ATA_SR_DF       EQU 0x20
ATA_SR_DRQ      EQU 0x08
ATA_SR_ERR      EQU 0x01

ATA_CMD_READ_SECTORS EQU 0x20

; EAX = LBA (28-bit)
; EDI = buffer (512 bytes)
; Returns:
;   EAX = 0 on success
;   EAX != 0 on error (1 = timeout BSY, 2 = timeout DRQ, 3 = ERR/DF)
ata_pio_read_sector:
    push    ebx
    push    ecx
    push    edx

    mov     ebx, eax              ; save LBA

    ; ---- Wait only for BSY=0 before command ----
    mov     dx, ATA_REG_STATUS
    mov     ecx, 100000
.wait_bsy_clear:
    in      al, dx
    test    al, ATA_SR_BSY
    jz      .bsy_ok
    loop    .wait_bsy_clear
    mov     eax, 1                ; timeout waiting BSY clear
    jmp     .done

.bsy_ok:
    ; ---- Select drive/head (primary master, LBA, high LBA bits) ----
    mov     dx, ATA_REG_DRIVE
    mov     eax, ebx
    shr     eax, 24               ; high 8 bits of LBA
    and     al, 0x0F              ; use low 4 bits as LBA[27:24]
    or      al, 0xE0              ; 1110xxxx: LBA + master
    out     dx, al

    ; Small 400ns delay via alt-status
    mov     dx, PRIMARY_CTRL
    in      al, dx
    in      al, dx
    in      al, dx
    in      al, dx

    ; ---- Set sector count = 1 ----
    mov     dx, ATA_REG_SECCNT
    mov     al, 1
    out     dx, al

    ; ---- Program LBA 0..23 into LBA0/LBA1/LBA2 ----
    mov     eax, ebx              ; full LBA

    mov     dx, ATA_REG_LBA0      ; bits 7:0
    out     dx, al

    shr     eax, 8                ; bits 15:8
    mov     dx, ATA_REG_LBA1
    out     dx, al

    shr     eax, 8                ; bits 23:16
    mov     dx, ATA_REG_LBA2
    out     dx, al

    ; ---- Issue READ SECTORS command ----
    mov     dx, ATA_REG_COMMAND
    mov     al, ATA_CMD_READ_SECTORS
    out     dx, al

    ; ---- Wait for BSY=0 and DRQ=1 ----
    mov     dx, ATA_REG_STATUS
    mov     ecx, 100000
.wait_drq:
    in      al, dx
    test    al, ATA_SR_ERR
    jnz     .pio_error
    test    al, ATA_SR_DF
    jnz     .pio_error
    test    al, ATA_SR_BSY
    jnz     .drq_dec
    test    al, ATA_SR_DRQ
    jnz     .drq_ok
.drq_dec:
    loop    .wait_drq
    mov     eax, 2                ; timeout waiting DRQ
    jmp     .done

.drq_ok:
    ; ---- Read 256 words (512 bytes) ----
    mov     dx, ATA_REG_DATA
    mov     ecx, 256
.read_loop:
    in      ax, dx
    mov     [edi], ax
    add     edi, 2
    loop    .read_loop

    xor     eax, eax              ; success
    jmp     .done

.pio_error:
    mov     eax, 3                ; ERR/DF set

.done:
    pop     edx
    pop     ecx
    pop     ebx
    ret

ATA_CMD_WRITE_SECTORS EQU 0x30

; -------------------------------------------------------------
; ata_pio_write_sector
;   EAX = LBA (28-bit)
;   ESI = buffer (512 bytes to WRITE)
;   Returns:
;     EAX = 0 on success
;     EAX != 0 on error (1 = timeout BSY, 2 = timeout DRQ, 3 = ERR/DF)
; -------------------------------------------------------------
ata_pio_write_sector:
    push    ebx
    push    ecx
    push    edx

    mov     ebx, eax              ; save LBA

    ; ---- Wait for BSY=0 before command ----
    mov     dx, ATA_REG_STATUS
    mov     ecx, 100000
.w_wait_bsy_clear:
    in      al, dx
    test    al, ATA_SR_BSY
    jz      .w_bsy_ok
    loop    .w_wait_bsy_clear
    mov     eax, 1                ; timeout waiting BSY clear
    jmp     .w_done

.w_bsy_ok:
    ; ---- Select drive/head (primary master, LBA mode) ----
    mov     dx, ATA_REG_DRIVE
    mov     eax, ebx
    shr     eax, 24               ; high 8 bits of LBA
    and     al, 0x0F              ; LBA[27:24]
    or      al, 0xE0              ; 1110xxxx: LBA + master
    out     dx, al

    ; Small 400ns delay via alt-status reads
    mov     dx, PRIMARY_CTRL
    in      al, dx
    in      al, dx
    in      al, dx
    in      al, dx

    ; ---- Set sector count = 1 ----
    mov     dx, ATA_REG_SECCNT
    mov     al, 1
    out     dx, al

    ; ---- Program LBA 0..23 into LBA0/LBA1/LBA2 ----
    mov     eax, ebx              ; full LBA

    mov     dx, ATA_REG_LBA0      ; bits 7:0
    out     dx, al

    shr     eax, 8                ; bits 15:8
    mov     dx, ATA_REG_LBA1
    out     dx, al

    shr     eax, 8                ; bits 23:16
    mov     dx, ATA_REG_LBA2
    out     dx, al

    ; ---- Issue WRITE SECTORS command ----
    mov     dx, ATA_REG_COMMAND
    mov     al, ATA_CMD_WRITE_SECTORS
    out     dx, al

    ; ---- Wait for BSY=0 and DRQ=1 ----
    mov     dx, ATA_REG_STATUS
    mov     ecx, 100000
.w_wait_drq:
    in      al, dx
    test    al, ATA_SR_ERR
    jnz     .w_pio_error
    test    al, ATA_SR_DF
    jnz     .w_pio_error
    test    al, ATA_SR_BSY
    jnz     .w_drq_dec
    test    al, ATA_SR_DRQ
    jnz     .w_drq_ok
.w_drq_dec:
    loop    .w_wait_drq
    mov     eax, 2                ; timeout waiting DRQ
    jmp     .w_done

.w_drq_ok:
    ; ---- Write 256 words (512 bytes) ----
    mov     dx, ATA_REG_DATA
    mov     ecx, 256
.w_write_loop:
    lodsw                          ; AX = [ESI], ESI += 2
    out     dx, ax
    loop    .w_write_loop

    xor     eax, eax              ; success
    jmp     .w_done

.w_pio_error:
    mov     eax, 3                ; ERR/DF set

.w_done:
    pop     edx
    pop     ecx
    pop     ebx
    ret

; -------------------------------------------------------------
; FS_ReadSectors_LBA
;   EAX = start LBA
;   ECX = sector count
;   EDI = destination buffer
;   Returns:
;       AL = 1 on success
;       AL = 0 on failure
; -------------------------------------------------------------
FS_ReadSectors_LBA:
    push    ebx
    push    edx

    mov     ebx, eax              ; current LBA in EBX

.fsread_loop:
    cmp     ecx, 0
    je      .fsread_ok

    ; call low-level read
    mov     eax, ebx              ; LBA
    call    ata_pio_read_sector
    mov     [AtaLastError], eax
    test    eax, eax
    jnz     .fsread_fail

    ; advance buffer by BytesPerSector
    mov     edx, [BytesPerSector]
    add     edi, edx

    inc     ebx                   ; next LBA
    dec     ecx
    jmp     .fsread_loop

.fsread_ok:
    mov     al, 1
    jmp     .fsdone

.fsread_fail:
    xor     al, al

.fsdone:
    pop     edx
    pop     ebx
    ret

; -------------------------------------------------------------
; FS_WriteSectors_LBA
;   EAX = start LBA
;   ECX = sector count
;   ESI = source buffer
;   Returns:
;       AL = 1 on success
;       AL = 0 on failure
; -------------------------------------------------------------
FS_WriteSectors_LBA:
    push    ebx
    push    edx

    mov     ebx, eax              ; current LBA in EBX

.write_loop:
    cmp     ecx, 0
    je      .write_ok

    mov     eax, ebx              ; LBA
    call    ata_pio_write_sector
    mov     [AtaLastError], eax
    test    eax, eax
    jnz     .write_fail

    ; advance buffer by BytesPerSector
    mov     edx, [BytesPerSector]
    add     esi, edx

    inc     ebx
    dec     ecx
    jmp     .write_loop

.write_ok:
    mov     al, 1
    jmp     .fswdone

.write_fail:
    xor     al, al

.fswdone:
    pop     edx
    pop     ebx
    ret
FS_MountFat12:

    ; --- Read boot sector (LBA 0) ---
    xor     eax, eax                  ; LBA = 0
    mov     edi, SectorBuf
    call    ata_pio_read_sector       ; EAX = 0 if OK
    mov     [AtaLastError], eax
    test    eax, eax
    jnz     FS_MountFat12_Fail

    ; --- Parse BPB fields from boot sector ---
    movzx   eax, word [SectorBuf+11]      ; BytesPerSector
    mov     [BytesPerSector], eax

    movzx   eax, byte [SectorBuf+13]      ; SectorsPerCluster
    mov     [SectorsPerCluster], eax

    movzx   eax, word [SectorBuf+14]      ; ReservedSectors
    mov     [ReservedSectors], eax

    movzx   eax, byte [SectorBuf+16]      ; FATCount
    mov     [FATCount], eax

    movzx   eax, word [SectorBuf+17]      ; RootDirEntries
    mov     [RootDirEntries], eax

    movzx   eax, word [SectorBuf+22]      ; SectorsPerFAT
    mov     [SectorsPerFAT], eax

    ; --- Calc RootDirSectors = ceil(RootDirEntries*32 / BytesPerSector) ---
    mov     eax, [RootDirEntries]
    mov     ecx, 32
    mul     ecx                            ; EDX:EAX = entries * 32
    mov     ecx, [BytesPerSector]
    add     eax, ecx
    dec     eax                             ; eax = entries*32 + BPS - 1
    xor     edx, edx
    div     ecx                             ; eax = ceil(...)
    mov     [RootDirSectors], eax

    ; --- Calc RootDirLBA = ReservedSectors + FATCount * SectorsPerFAT ---
    mov     eax, [FATCount]
    mul     dword [SectorsPerFAT]
    add     eax, [ReservedSectors]
    mov     [RootDirLBA], eax

    ; --- Calc DataRegionLBA = RootDirLBA + RootDirSectors ---
    mov     ecx, [RootDirSectors]
    add     eax, ecx
    mov     [DataRegionLBA], eax

    ; --- Load entire root directory into RootDirBuf ---
    mov     eax, [RootDirLBA]         ; start LBA
    mov     ecx, [RootDirSectors]     ; how many sectors
    mov     edi, RootDirBuf           ; dest
    call    FS_ReadSectors_LBA
    test    al, al
    jz      FS_MountFat12_Fail

    mov     al, 1
    ret

FS_MountFat12_Fail:
    xor     al, al
    ret

mountfail   DB  "shit failed",0
AtaLastError    DD  0
pm_entry:
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov esp, 0x90000           ; some stack in low memory

    cld                        ; make sure DF = 0

    call FS_MountFat12
    test AL, AL
        jz mount_failed

    call ClearScreen
    call BuildPrompt
    mov ESI, msg
    call PrintPromptAtCursor
    call Set_input_Base_From_Cursor
    call kb_loop

    mount_failed:
        mov ESI, AtaLastError
        push ESI
        call PrintPromptAtCursor
        pop ESI

    halt:
        jmp halt

    kb_loop:
        ;Status bit. 1 = available 0 = no byte to read
        in AL, 0x64     ;KBD_STATUS
        test AL, 1
            jz kb_loop
        
        ; Read scancode
        in AL, 0x60     ;KBD_DATA
        movzx ECX, AL
        cmp ECX, 0xE0   ;ignore E0 Prefix
            je kb_loop
        test AL, 0x80
            jz make
        and ECX, 0x7f       ;released scancode
        cmp ECX, 0x2a       ; LShift up
            je shift_up
        cmp ECX, 0x36       ; RSHIFT up
            je shift_up
        jmp kb_loop        

     make:
        cmp ECX, 0x2a   ;LSHIFT down
            je shift_dn
        cmp ECX, 0x36   ;RSHIFT down
            je  shift_dn

        movzx EAX, byte [shift_flg]
        test EAX, EAX
            jz no_shift
        mov AL, BYTE [scan1_to_ascii_shift + ECX]
     jmp got_char

     no_shift:
     mov AL, BYTE [scan1_to_ascii_normal + ECX]

    got_char:
        test AL, AL
            jz kb_loop
        cmp AL, 8
            je do_bs

        cmp AL, 13
            je do_crlf
        call put_char
        jmp kb_loop

    do_bs:
        mov EBX, [cur_row]
        mov ECX, [cur_col]
        ; BLOCK if we're at the input start
        mov EDX, [input_start_row]
        cmp EBX, EDX
            jne not_base_row
        mov EDX, [input_start_col]
        cmp ECX, EDX
            je done

        not_base_row:
            test ECX, ECX
                jnz same_line
         ;we're at column 0 only wrap if strictly below the input start
            mov EDX, [input_start_row]
            cmp EBX, EDX
                jbe done
            dec EBX
            mov ECX, [Screen_W]
            dec ECX
            jmp erase_here
        same_line:
            mov EDX, [input_start_row]
            cmp EBX, EDX
                jne dec_ok
            mov EDX, [input_start_col]
            cmp ECX, edx
                Jbe done

            dec_ok:
                dec ECX
       
    erase_here:
        movzx EAX, byte [input_len]
        test EAX, EAX
            jz done
        dec EAX
        mov byte[input_buff+EAX],0 
        mov byte[input_len], AL


        no_shrink:
        mov EDI, [VGA_Mem]
        mov EAX, EBX
        imul EAX, [Screen_W]  ; row *80
        add EAX, ECX        ; row * 80 + col
        shl EAX, 1
        add EDI, EAX
        mov AX, 0x0F00
        stosw
        ;update software cursor to the erased position
        mov [cur_col], ECX
        mov [cur_row], EBX
        sub EDI, 2

        call Set_Cursor_pos_from_RC

        done:
        jmp kb_loop

    do_crlf:
        inc dword [cur_row]
        mov dword [cur_col], 0
        call ClampOrScrollToBottom
        call NullTerminateInput
        call CheckCommandValidation
        inc dword [cur_row]
        test AL, AL
            jz Error
        mov byte [input_len], 0
        ; print next prompt and re-arm protection
        call BuildPrompt
        mov ESI, msg
        call PrintPromptAtCursor
        call Set_input_Base_From_Cursor
        jmp kb_loop

        Error:
        call Set_Cursor_pos_from_RC
        call BuildPrompt
        mov ESI, msg
        call PrintPromptAtCursor
        mov byte [input_len], 0
        jmp kb_loop

shift_dn:
    mov byte [shift_flg], 1
    jmp kb_loop

shift_up:
    mov byte [shift_flg], 0
    jmp kb_loop

put_char:
;param = AL
;puts typed char on screen
    mov DL, AL  ;save the char

    xor EAX, EAX
    mov BL, byte [input_max]
    sub BL, 1
    mov AL, byte [input_len]
    cmp AL, BL
        jae fin
    mov [input_buff+EAX], DL
    inc EAX
    mov byte[input_len], AL


    mov EBX, [cur_row]
    mov ECX, [cur_col]
    cmp ECX, [Screen_W]
        jb okcol
    xor ECX, ECX
    inc EBX

    okcol:
        mov ESI, [Screen_H]
        dec ESI
        cmp EBX, ESI
            jbe okrow
        mov EBX, ESI

    okrow:
        mov EAX, [Screen_W]
        dec EAX
        cmp EBX, ESI
            jne do_write
        cmp ECX, EAX
            je fin
    
    do_write:
        mov EDI, DWORD [VGA_Mem]
        mov EAX, EBX
        imul EAX, [Screen_W]  ; row *80
        add EAX, ECX        ; row * 80 + col
        shl EAX, 1
        add EDI, EAX
        mov AL, DL
        mov AH, 0x0F
        stosw

    ;advance the software cursor (wrap after writting the 80th char)
    inc ECX
    cmp ECX, [Screen_W]
        jb store
    xor ECX, ECX
    inc EBX
    mov EDX, [Screen_H]
    dec EDX
    cmp EBX, EDX
        jbe store
    mov EBX, EDX
    
    store:
        mov [cur_row], EBX
        mov [cur_col], ECX

    call Set_Cursor_pos_from_RC
    fin:
    ret

NullTerminateInput:
    movzx EAX, byte [input_len]
    mov byte [input_buff+eax], 0
    ret

ScrollUp2:
    ; shift everything up 2 rows, clear last 2 rows
    pushad
    cld

    ; EDI = start of VGA
    mov EDI, [VGA_Mem]
    mov ESI, [VGA_Mem]

    ; EAX = Screen_W * 2 (bytes per row)
    mov EAX, [Screen_W]
    shl EAX, 1

    ; move ESI down 2 rows
    mov EBX, EAX
    shl EBX, 1           ; EBX = Screen_W * 4
    add ESI, EBX

    ; ECX = (Screen_H - 2) * Screen_W * 2 (bytes to copy)
    mov ECX, [Screen_H]
    sub ECX, 2
    imul ECX, [Screen_W]
    shl ECX, 1

    rep movsb            ; copy video memory up

    ; === clear the last 2 rows ===
    mov EDX, [Screen_H]
    sub EDX, 2           ; row index of row (H-2)
    mov EAX, EDX
    imul EAX, [Screen_W]
    shl EAX, 1
    mov EDI, [VGA_Mem]
    add EDI, EAX

    ; clear 2 rows worth of characters
    mov ECX, [Screen_W]
    shl ECX, 1           ; *2 for two rows
    mov AX, 0x0F00
    rep stosw

    popad
    ret


; -------------------------------------------------------------
; ConsoleNewline
;   Move cursor to start of next output line.
;   Uses cur_row, cur_col, Screen_H, ScrollUp2, Set_Cursor_pos.
;   Assumes bottom 2 rows are reserved (ScrollUp2 behavior).
; -------------------------------------------------------------
ConsoleNewline:
    pushad

    inc dword [cur_row]
    mov dword [cur_col], 0
    ; re-use your existing scroll/clamp logic
    call ClampOrScrollToBottom
    ; and the routine that sets the HW cursor from cur_row/cur_col
    call Set_Cursor_pos_from_RC

    popad
    ret

Set_Cursor_pos_from_RC:
;uses the row and column mem values to set the cursor
mov EAX, [cur_row]
imul EAX, [Screen_W]
add EAX, [cur_col]
mov BX, AX

    mov DX, 0x3d4   ; VGA CRT Controller index register (color adapter)
    mov AL, 0x0F    ; let controller chip know we want to select the low byte of cursor index
    out DX, AL      ; tell CRT controller: "next write to 0x3D5 goes to register 0x0F" 
    inc DX          ; dx = 0x3D5 = VGA CRT Controller data register
    mov AL, BL
    out DX, AL      ; write low byte of cursor position (AL) into reg 0x0F

    mov DX, 0x3D4
    mov AL, 0x0E
    out DX, AL
    inc DX
    mov AL, BH
    out DX, AL
    ret

ClampOrScrollToBottom:
    mov EAX, [Screen_H]
    sub EAX, 2
    mov EDX, [cur_row]
    cmp EDX, EAX
        jbe ok
    call ScrollUp2
    mov [cur_row], EAX
    ok:
        ret

PrintPromptAtCursor:
    ;ESI = PARAM
    mov EBX, [cur_row]
    mov ECX, [cur_col]
    mov EAX, EBX
    imul EAX, [Screen_W]
    add EAX, ECX
    shl EAX, 1
    mov EDI, [VGA_Mem]
    add EDI, EAX
    pp_loop:
        lodsb
        test al, al
            jz done_pp
        mov AH, 0x0F
        stosw
        jmp pp_loop

        done_pp:
            call Set_Cursor_pos
            ret

ClearScreen:
;Clears the current screen buffer of all contents
pushad
mov EDI, [VGA_Mem]

mov CX, 2000
mov AX, 0x0f20

rep stosw
popad
ret

Set_Cursor_pos :
;param = EDI
;talks with the VGA CRT Controller chip. This chip controls text-mode screen layout (like rows, columns and the cursor)
    pushad
    mov EAX, EDI        ;EDI points to the last index
    sub EAX, dword [VGA_Mem]    ;subtract to get the last column
    shr EAX, 1          ; divide by 2 because 2 bytes per cell
    mov EBX, EAX        ;save EAX in EBX

    mov DX, 0x3d4   ; VGA CRT Controller index register (color adapter)
    mov AL, 0x0F    ; let controller chip know we want to select the low byte of cursor index
    out DX, AL      ; tell CRT controller: "next write to 0x3D5 goes to register 0x0F" 
    inc DX          ; dx = 0x3D5 = VGA CRT Controller data register
    mov AL, BL         ; restore EAX (cursor cell index was saved on stack earlier)
    out DX, AL      ; write low byte of cursor position (AL) into reg 0x0F

    mov DX, 0x3D4
    mov AL, 0x0E
    out DX, AL
    inc DX
    mov AL, BH
    out DX, AL

    mov EAX, EBX
    xor EDX, EDX
    mov ECX, [Screen_W]
    div ECX
    mov [cur_row], EAX
    mov [cur_col], EDX
    popad
    ret

    Set_input_Base_From_Cursor:
        mov EAX, [cur_col]
        mov [input_start_col], EAX
        mov EAX, [cur_row]
        mov [input_start_row], EAX
        ret

to_lower:
    ;takes the input of the command and makes it all lower
    pushad
next_char:
    mov AL, byte [EDI]
    test AL, AL
        jz lowerinp
    cmp AL, 'A'
        jb skip
    cmp AL, 'Z'
        ja skip
    add AL, 32
    mov byte [EDI], AL

    skip:
        inc EDI
        jmp next_char
    
    lowerinp:
        popad
        ret

ExecuteCmd:
;parameter = CL
; ESI still contains the parameter's data
;takes us to a command jump table for us to go into the corresponding command. returns true or false

    
    cmp CL, 6
    ja bad_index

    movzx EAX, CL
    call [CmdJumpTable + EAX*4]

    jmp out

    bad_index:
    xor AL, AL

    out:
    ret

    align 4
    CmdJumpTable:
        dd cmd_mkdir
        dd cmd_create
        dd cmd_delete
        dd cmd_echo
        dd cmd_dir
        dd cmd_clear
        dd cmd_edit

TmpName83       db 11 dup(0)        ; 8.3 name in FAT format (11 bytes, no terminator)
TmpNameStr      db 32 dup(0)        ; printable name "FOO.TXT", 0-terminated

StrDirTag       db ' <DIR>',0
StrNewline      db 13,10,0          ; adjust if your print routine doesn't like CRLF

; -------------------------------------------------------------
; Make83Name
;   ESI -> zero-terminated parameter string (e.g. "TEST" or "FOO.TXT")
;   writes 11-byte 8.3 name into TmpName83
;   Returns: CF=0 on success, CF=1 on error (invalid/too long/empty)
; -------------------------------------------------------------
Make83Name:
    push    eax
    push    ebx
    push    ecx
    push    edx
    push    edi

    ; fill with spaces
    mov     edi, TmpName83
    mov     ecx, 11
    mov     al, ' '
.fill_spaces:
    mov     [edi], al
    inc     edi
    loop    .fill_spaces

    ; skip leading spaces in input
    .skip_spaces:
        mov     al, [esi]
        cmp     al, ' '
        jne     .start_parse
        inc     esi
        jmp     .skip_spaces

    .start_parse:
        mov     al, [esi]
        test    al, al
        jz      .83fail      ; empty / only spaces

    mov     ebx, TmpName83 ; base name ptr
    mov     edi, TmpName83 ; current dest = base region
    mov     ecx, 0         ; base_len
    mov     edx, 0         ; ext_len
    mov     bl, 0          ; bl = 0 -> base, bl = 1 -> ext

.parse_loop:
    mov     al, [esi]
    inc     esi
    test    al, al
    jz      .end_parse     ; end of string
    cmp     al, ' '
    je      .end_parse     ; treat space as end

    cmp     al, '.'
    je      .switch_to_ext

    ; convert to uppercase if a-z
    cmp     al, 'a'
    jb      .store_char
    cmp     al, 'z'
    ja      .store_char
    sub     al, 32         ; 'a'..'z' -> 'A'..'Z'

.store_char:
    cmp     bl, 0
    jne     .store_ext_char    ; ext

    ; base name char
    cmp     ecx, 8
    jae     .83fail              ; too long
    mov     [TmpName83 + ecx], al
    inc     ecx
    jmp     .parse_loop

.store_ext_char:
    cmp     edx, 3
    jae     .83fail              ; ext too long
    mov     [TmpName83 + 8 + edx], al
    inc     edx
    jmp     .parse_loop

.switch_to_ext:
    cmp     bl, 0
    jne     .83fail              ; second dot not allowed
    mov     bl, 1              ; now in extension
    jmp     .parse_loop

.end_parse:
    ; require at least base name
    cmp     ecx, 0
    je      .83fail

    clc                         ; success
    jmp     .83done

.83fail:
    stc

.83done:
    pop     edi
    pop     edx
    pop     ecx
    pop     ebx
    pop     eax
    ret

; -------------------------------------------------------------
; FindFreeRootEntry
;   Scans RootDirBuf for a free or unused entry
;   Returns:
;       CF=0, EDI = pointer to 32-byte free entry
;       CF=1, none available
; -------------------------------------------------------------
FindFreeRootEntry:
    push    eax
    push    ecx

    mov     edi, RootDirBuf
    mov     ecx, [RootDirEntries]

.scan_loop:
    cmp     ecx, 0
    je      .findfail

    mov     al, [edi]
    cmp     al, 0x00          ; 0x00 = never used, end-of-list
    je      .findok
    cmp     al, 0xE5          ; 0xE5 = deleted
    je      .findok

    add     edi, 32
    dec     ecx
    jmp     .scan_loop

.findok:
    clc
    jmp     .finddone

.findfail:
    stc

.finddone:
    pop     ecx
    pop     eax
    ret

; -------------------------------------------------------------
; FindRootEntryByName
;   ESI -> 11-byte 8.3 name (TmpName83)
;   Scans RootDirBuf for a matching name.
;   Returns:
;       CF = 0, EDI = pointer to matching 32-byte entry
;       CF = 1, not found
; -------------------------------------------------------------
FindRootEntryByName:
    push    eax
    push    ecx
    push    edx
    push    esi

    mov     edi, RootDirBuf
    mov     ecx, [RootDirEntries]

.fbnscan_loop:
    cmp     ecx, 0
    je      .fbnnot_found

    mov     al, [edi]         ; first byte of entry name
    cmp     al, 0x00          ; 0x00 => end of used entries
    je      .fbnnot_found
    cmp     al, 0xE5          ; deleted
    je      .fbnnext_entry

    ; compare first 11 bytes with TmpName83
    push    ecx
    push    edi
    push    esi

    mov     esi, TmpName83
    mov     edx, 11           ; local counter

.cmp11:
    mov     al, [esi]
    cmp     al, [edi]
    jne     .fbncmp_fail
    inc     esi
    inc     edi
    dec     edx
    jnz     .cmp11

    ; all 11 bytes matched
    pop     esi
    pop     edi
    pop     ecx
    clc                     ; success
    jmp     .fbndone

.fbncmp_fail:
    pop     esi
    pop     edi
    pop     ecx

.fbnnext_entry:
    add     edi, 32
    dec     ecx
    jmp     .fbnscan_loop

.fbnnot_found:
    stc                     ; CF = 1

.fbndone:
    pop     esi
    pop     edx
    pop     ecx
    pop     eax
    ret

cmd_mkdir:
    pushad
    ; 1) build 8.3 name
    call Make83Name
    jc fail_mkdir
    
    ; 2) find free root entry
    call    FindFreeRootEntry
    jc      fail_mkdir
    ; EDI = free 32-byte entry
    ; 3) write name (11 bytes)
    mov     esi, TmpName83
    mov     ecx, 11
.copy_name:
    lodsb
    stosb
    loop    .copy_name
    mov     byte [edi], 0x10      ; ATTR_DIRECTORY
    inc     edi                   ; now at offset 12
    ; 5) zero NTRes .. WrtDate (offsets 12..25 => 14 bytes)
    mov     ecx, 14
.zero_meta:
    mov     byte [edi], 0
    inc     edi
    loop    .zero_meta
    ; 6) file size = 0 at offset 28
    add     edi, 2                ; skip FstClusLO (leave 0)
    mov     dword [edi], 0
    ; 7) flush root dir to disk
    mov     eax, [RootDirLBA]
    mov     ecx, [RootDirSectors]
    mov     esi, RootDirBuf
    call    FS_WriteSectors_LBA
    test AL, AL
    jz fail_mkdir
    popad
    mov AL, 1
    ret

fail_mkdir:
    popad
    xor AL, AL
    ret


CurrentDirCluster dd 0           ; 0 = root, >0 = cluster of current dir

; EAX = cluster number (>= 2)
; returns EAX = first LBA of that cluster
LBA_FromCluster:
    push    ecx

    mov     ecx, [SectorsPerCluster]
    sub     eax, 2                  ; cluster-2
    imul    eax, ecx                ; (cluster-2)*SecPerCluster
    add     eax, [DataRegionLBA]    ; + data region start

    pop     ecx
    ret

; -------------------------------------------------------------
; BuildNameFrom83
;   ESI -> 11-byte FAT 8.3 name (entry[0..10])
;   EDI -> output buffer (TmpNameStr)
;   Output: 0-terminated string "NAME" or "NAME.EXT"
; -------------------------------------------------------------
BuildNameFrom83:
    push    eax
    push    ebx
    push    ecx
    push    edx

    mov     ebx, esi          ; base pointer to 8.3 name

    ; ---- Base name (0..7) ----
    mov     ecx, 8
    xor     edx, edx
.base_loop:
    mov     al, [ebx+edx]
    inc     edx
    cmp     al, ' '
    je      .base_done
    mov     [edi], al
    inc     edi
    loop    .base_loop
.base_done:

    ; ---- Check if any non-space in ext (8..10) ----
    mov     esi, ebx
    add     esi, 8
    mov     ecx, 3
.check_ext:
    mov     al, [esi]
    cmp     al, ' '
    jne     .has_ext
    inc     esi
    loop    .check_ext
    jmp     .finish           ; no ext

.has_ext:
    ; append '.' then copy ext up to space
    mov     esi, ebx
    add     esi, 8

    mov     byte [edi], '.'
    inc     edi

    mov     ecx, 3
.copy_ext:
    mov     al, [esi]
    inc     esi
    cmp     al, ' '
    je      .ext_done
    mov     [edi], al
    inc     edi
    loop    .copy_ext
.ext_done:

.finish:
    mov     byte [edi], 0     ; terminator

    pop     edx
    pop     ecx
    pop     ebx
    pop     eax
    ret

; -------------------------------------------------------------
; Dir_ListBuffer
;   ESI = pointer to directory entries buffer
;   ECX = number of entries (buffer_size / 32)
; -------------------------------------------------------------
Dir_ListBuffer:
    pushad

    mov     edi, esi          ; EDI = current entry

.entry_loop:
    cmp     ecx, 0
    je      .dlbdone

    mov     al, [edi]         ; first byte of name
    cmp     al, 0x00          ; 0x00 => no more valid entries
    je      .dlbdone
    cmp     al, 0xE5          ; deleted
    je      .next_entry

    mov     bl, [edi+11]      ; attribute

    ; skip volume labels (bit 0x08)
    test    bl, 0x08
    jnz     .next_entry

    ; build printable name from 8.3
    push    ecx
    push    edi

    mov     esi, edi          ; entry[0..10]
    mov     edi, TmpNameStr
    call    BuildNameFrom83

    ; print name
    push EBX
    mov     esi, TmpNameStr
    call    PrintPromptAtCursor
    pop EBX

    ; if directory, append " <DIR>"
    test    bl, 0x10          ; ATTR_DIRECTORY
    jz      .after_dir_tag
    push EBX
    mov     esi, StrDirTag
    call    PrintPromptAtCursor
    pop EBX

.after_dir_tag:
    call    ConsoleNewline  
    pop     edi
    pop     ecx

.next_entry:
    add     edi, 32           ; next entry
    dec     ecx
    jmp     .entry_loop

.dlbdone:
    popad
    ret

; -------------------------------------------------------------
; Dir_ListCurrent
;   If CurrentDirCluster = 0  -> list RootDirBuf
;   If >0                     -> read that cluster, list it
; -------------------------------------------------------------
Dir_ListCurrent:
    pushad

    mov     eax, [CurrentDirCluster]
    test    eax, eax
    jnz     .list_subdir

    ; ----- ROOT DIRECTORY -----
    mov     esi, RootDirBuf
    mov     ecx, [RootDirEntries]
    call    Dir_ListBuffer
    jmp     .done

.list_subdir:
    ; ----- SIMPLE SUBDIR (single cluster) -----
    call    LBA_FromCluster        ; EAX = first LBA
    mov     ecx, [SectorsPerCluster]
    mov     edi, DirScratchBuf
    call    FS_ReadSectors_LBA
    test    al, al
    jz      .done                  ; read failed

    ; entries = bytes_in_cluster / 32
    mov     eax, [BytesPerSector]
    mul     dword [SectorsPerCluster]  ; EAX = bytes per cluster
    mov     ecx, eax
    shr     ecx, 5                     ; /32

    mov     esi, DirScratchBuf
    call    Dir_ListBuffer

.done:
    popad
    ret
FAT_AllocResult   dd 0
FAT_AllocStatus   db 0
FAT_FirstLBA      dd 0
FAT_Bytes         dd 0
FAT_MaxCluster    dd 0
; -------------------------------------------------------------
; FAT12_AllocCluster
;   Find first free FAT12 cluster, mark it 0xFFF (EOC),
;   write FAT #1 (and #2 if present), and return cluster number.
;
;   OUT:
;     AX = new cluster number (>= 2) on success
;     CF = 0 on success
;     CF = 1 on failure (no free cluster / I/O error)
;
;   Uses:
;     BytesPerSector, SectorsPerFAT, FATCount, RootDirLBA
;     DirScratchBuf as FAT buffer
;     FS_ReadSectors_LBA, FS_WriteSectors_LBA
; -------------------------------------------------------------
FAT12_AllocCluster:
    pushad

    ; ---- Compute FAT #1 start LBA ----
    ; RootDirLBA = VolumeBaseLBA + Reserved + FATCount*SectorsPerFAT
    ; => FAT1_LBA = RootDirLBA - FATCount*SectorsPerFAT
    mov     eax, [SectorsPerFAT]
    imul    eax, [FATCount]
    mov     ebx, eax                ; EBX = FATCount * SectorsPerFAT
    mov     eax, [RootDirLBA]
    sub     eax, ebx                ; EAX = FAT1_LBA
    mov     [FAT_FirstLBA], eax

    ; ---- Compute bytes per FAT = BytesPerSector * SectorsPerFAT ----
    mov     eax, [BytesPerSector]
    imul    eax, [SectorsPerFAT]
    mov     [FAT_Bytes], eax        ; total bytes in one FAT

    ; ---- Read FAT #1 into DirScratchBuf ----
    mov     eax, [FAT_FirstLBA]     ; start LBA
    mov     ecx, [SectorsPerFAT]    ; sector count
    mov     edi, DirScratchBuf      ; dest buffer
    call    FS_ReadSectors_LBA
    test    al, al
        jz  .failClust                   ; read failed

    ; ---- Compute max cluster count ˜ (bytes_fat * 2)/3 ----
    mov     eax, [FAT_Bytes]
    shl     eax, 1                  ; *2
    mov     ecx, 3
    xor     edx, edx
    div     ecx                     ; EAX = (bytes_fat*2)/3
    mov     [FAT_MaxCluster], eax

    ; ---- Scan clusters starting from 2 ----
    mov     esi, 2                  ; ESI = current cluster

.scan_loop:
    mov     eax, [FAT_MaxCluster]
    cmp     esi, eax
        jae .no_free                ; ran out of FAT

    ; offset = (cluster * 3) / 2
    mov     eax, esi
    mov     edx, eax
    shl     eax, 1                  ; eax = c*2
    add     eax, edx                ; eax = c*3
    shr     eax, 1                  ; eax = (c*3)/2
    mov     ebx, DirScratchBuf
    add     ebx, eax                ; EBX = ptr into FAT

    ; read the 12-bit value for this cluster
    test    esi, 1
        jz  .even_cluster           ; even cluster

    ; ----- odd cluster -----
    mov     dx, [ebx]               ; two bytes
    shr     dx, 4                   ; upper 12 bits
    and     dx, 0x0FFF
    cmp     dx, 0
        je  .alloc_odd              ; free (0)
    inc     esi
    jmp     .scan_loop

.even_cluster:
    mov     dx, [ebx]
    and     dx, 0x0FFF              ; lower 12 bits
    cmp     dx, 0
        je  .alloc_even
    inc     esi
    jmp     .scan_loop

.alloc_even:
    ; set lower 12 bits to 0xFFF, keep upper 4 bits
    mov     dx, [ebx]
    and     dx, 0xF000
    or      dx, 0x0FFF
    mov     [ebx], dx
    jmp     .got_cluster

.alloc_odd:
    ; set upper 12 bits to 0xFFF, keep low nibble
    mov     dx, [ebx]
    and     dx, 0x000F
    or      dx, 0xFFF0
    mov     [ebx], dx
    jmp     .got_cluster

.got_cluster:
    ; ESI = new cluster
    mov     [FAT_AllocResult], esi

    ; ---- Write FAT #1 back ----
    mov     eax, [FAT_FirstLBA]
    mov     ecx, [SectorsPerFAT]
    mov     esi, DirScratchBuf
    call    FS_WriteSectors_LBA
    test    al, al
        jz  .fail_io

    ; ---- Mirror to FAT #2 if present ----
    mov     eax, [FATCount]
    cmp     eax, 1
        jbe .success                ; only one FAT

    mov     eax, [FAT_FirstLBA]
    add     eax, [SectorsPerFAT]    ; FAT2_LBA = FAT1_LBA + SectorsPerFAT
    mov     ecx, [SectorsPerFAT]
    mov     esi, DirScratchBuf
    call    FS_WriteSectors_LBA
    test    al, al
        jz  .fail_io

.success:
    mov     byte [FAT_AllocStatus], 1
    jmp     .doneClust

.no_free:
.fail_io:
.failClust:
    mov     byte [FAT_AllocStatus], 0
    mov     dword [FAT_AllocResult], 0

.doneClust:
    popad
    mov     ax, [FAT_AllocResult]
    cmp     byte [FAT_AllocStatus], 0
        je  .ret_fail
    clc                     ; CF = 0 success
    ret

.ret_fail:
    stc                     ; CF = 1 failure
    ret
cmd_create:
    pushad

    ; 1) Build 8.3 name from parameter (ESI already points to it)
    call    Make83Name
    jc      .CC_fail            ; CF=1 => invalid/empty/too long name

    ; 2) Check if an entry with this name already exists in ROOT
    mov     esi, TmpName83
    call    FindRootEntryByName
    jnc     .exists             ; CF=0 => found

    ; 3) Find a free root entry
    call    FindFreeRootEntry
    jc      .CC_fail            ; no free entries

    ; EDI = free 32-byte entry
    mov     ebx, edi            ; *** SAVE ENTRY BASE HERE ***

    ; 4) Fill directory entry as a normal file (ATTR = 0x20)
    mov     esi, TmpName83
    mov     ecx, 11
.CC_copy_name:
    lodsb
    stosb                       ; writes name[0..10]
    loop    .CC_copy_name

    ; attribute byte at offset 11
    mov     byte [edi], 0x20    ; ATTR_ARCHIVE / normal file
    inc     edi                 ; now at offset 12

    ; Zero everything from offset 12..31 (20 bytes):
    ;   NTRes, time stamps, FstClusLO, FileSize = 0
    mov     ecx, 32 - 12        ; 20 bytes
    xor     eax, eax
.zero_rest:
    stosb
    loop    .zero_rest

    ; 4.5) Allocate a data cluster for this new file
    call    FAT12_AllocCluster
    jc      .CC_fail            ; no free cluster / FAT error

    ; AX = new cluster
    mov     [ebx+26], ax        ; FstClusLO = cluster number

    ; 5) Flush updated root directory back to disk
    mov     eax, [RootDirLBA]
    mov     ecx, [RootDirSectors]
    mov     esi, RootDirBuf
    call    FS_WriteSectors_LBA
    test    al, al
        jz  .CC_fail            ; write failed

    ; success
    popad
    mov     al, 1
    ret

.exists:
    popad
    xor     al, al
    ret

.CC_fail:
    ; optional: clear entry again so it's obviously unused
    ; mov byte [ebx], 0
    popad
    xor     al, al
    ret
Delete_NotFoundMsg  db "del: file not found.",0
Delete_IOMsg        db "del: disk I/O error.",0
cmd_delete:
    ; --- 1) Build 8.3 name from ESI -> "file.txt" ---
    ; Edit_Build83NameFromCString always writes into Edit_Name83
    pushad
    mov edi, Edit_Name83
    call Edit_Build83NameFromCString

    ;Read root directory into RootDirBuf
    mov     eax, [RootDirLBA]
    mov     ecx, [RootDirSectors]
    mov     edi, RootDirBuf
    call    FS_ReadSectors_LBA
    test AL, AL
        jz .io_error
    ; --- 3) Find the directory entry for this 8.3 name ---
    mov     esi, Edit_Name83
    call    Edit_FindRootEntryByName
    test    al, al
        jz  .not_founddelete
    ; On success:
    ;   Edit_DirEntryPtr -> dir entry in RootDirBuf
    ;   Edit_StartCluster = starting cluster
    ;   Edit_FileSize     = size (bytes)
    ;
    ; For now, we:
    ;   - mark dir entry deleted by writing 0xE5 to first byte
    ;   - optionally clear start cluster + size

    mov     edi, [Edit_DirEntryPtr]

    ; mark as deleted
    mov     byte [edi], 0xE5

    ; optional: clear start cluster + size
    mov     word [edi+26], 0       ; start cluster = 0
    mov     dword [edi+28], 0      ; file size = 0

    ; --- 4) Write updated root directory back to disk ---
    mov     eax, [RootDirLBA]
    mov     ecx, [RootDirSectors]
    mov     esi, RootDirBuf
    call    FS_WriteSectors_LBA
    test    al, al
        jz  .io_error
    popad
    mov AL, 1
    ret
.io_error:

    mov     esi, Delete_IOMsg
    call    PrintPromptAtCursor
    popad
    mov     al, 1
    ret    
.not_founddelete:
    mov     esi, Delete_NotFoundMsg
    call    PrintPromptAtCursor
    popad
    mov     al, 1
    ret

SaveConsoleState:
pushad

;compute the screen space in bytes screen_w *screen_h * 2
mov EAX, [Screen_W]
mov EBX, [Screen_H]
imul EAX, EBX
shl EAX, 1
mov ECX, EAX

;copy VGA Buffer -> ScreenSaveBuf
mov ESI,[VGA_Mem]
mov EDI, ScreenSaveBuf
rep movsb

;save cursor position
mov EAX, [cur_row]
mov [SavedCurRow], EAX
mov EAX, [cur_col]
mov [SavedCurCol], EAX
mov EAX, [input_start_row]
mov [SavedInputBaseRow], EAX
mov EAX, [input_start_col]
mov [SavedInputBaseCol], EAX


popad
ret

RestorConnsoleState:
    pushad
    mov ESI, ScreenSaveBuf
    mov EDI, [VGA_Mem]

    mov EAX, [Screen_W]
    mov EBX, [Screen_H]
    imul EAX, EBX
    shl EAX, 1
    mov ECX, EAX

    ;copy screensavebuf to vga buf
    rep movsb

    ;restore cursor var
    mov EAX, [SavedCurRow]
    mov [cur_row], EAX
    mov EAX, [SavedCurCol]
    mov [cur_col], EAX
    mov EAX, [SavedInputBaseRow]
    mov [input_start_row], EAX

    mov EAX, [SavedInputBaseCol]
    mov [input_start_col], EAX
    ;update hardware cursor
    call Set_Cursor_pos_from_RC
    popad
    ret

; -------------------------------------------------------------
; Edit_Build83NameFromCString
;   IN:  ESI -> "FOO.TXT",0
;        EDI -> 11-byte dest (Edit_Name83)
;   OUT: Edit_Name83 filled with 8.3 name (space padded, uppercase)
;        (no error reporting, assumes simple ASCII name)
; -------------------------------------------------------------
Edit_Build83NameFromCString:
    pushad
    ; fill 11 bytes with spaces
    mov     edi, Edit_Name83
    mov     ecx, 11
    mov     al, ' '
    ; fill 11 bytes with spaces
    rep stosb
   ; reset dest pointer to start
    mov     edi, Edit_Name83      ; start of name
    mov     ecx, 8

.basename_loop:
    lodsb                         ; AL = [ESI++]
    test    al, al
        jz  .done83                 ; end of string, no extension
    cmp     al, '.'
        je  .start_ext            ; hit dot, go fill extension
    call    Edit_UpperIfAlpha
    stosb                         ; store in name
    loop    .basename_loop        ; stop after 8 chars

    ; if more chars until '.', just skip them
.skip_until_dot:
    lodsb
    test    al, al
        jz  .done83
    cmp     al, '.'
        jne .skip_until_dot
        
.scan_to_dot_or_end:
    lodsb
    test    al, al
        jz  .done83
    cmp     al, '.'
        jne .scan_to_dot_or_end
    ; found '.', now fill extension
    mov     edi, Edit_Name83
    add     edi, 8
    mov     ecx, 3
    jmp     .ext_loop

.start_ext:
    ; ---- extension (up to 3 chars) ----
    mov     edi, Edit_Name83
    add     edi, 8                ; extension position
    mov     ecx, 3

.ext_loop:
    lodsb
    test    al, al
        jz  .done83
    call    Edit_UpperIfAlpha
    stosb
    loop    .ext_loop

.done83:
    popad
    ret

Edit_UpperIfAlpha:
    push    ebx
    cmp     al, 'a'
        jb  .u_ret
    cmp     al, 'z'
        ja  .u_ret
    sub     al, 32
.u_ret:
    pop     ebx
    ret

; -------------------------------------------------------------
; Edit_FindRootEntryByName
;   IN:  ESI -> 11-byte FAT name
;   OUT: AL = 1 if found, 0 if not
;        EDI -> matching 32-byte entry if found
; -------------------------------------------------------------
Edit_FindRootEntryByName:
    push    ebx
    push    ecx
    push    edx
    push    edi
    ; compute number of root entries:
    ; entries = RootDirSectors * BytesPerSector / 32
    mov     eax, [RootDirSectors]
    imul    eax, [BytesPerSector]    ; total bytes
    mov     ecx, 32
    xor     edx, edx
    div     ecx                      ; EAX = entry count
    mov     ecx, eax                 ; ECX = remaining entries

    mov     ebx, RootDirBuf          ; EBX = pointer to current entry       
.next_entry:
    test    ecx, ecx
        jz  .not_found

    ; check first byte
    mov     al, [ebx]
    cmp     al, 0
        je  .not_found               ; end marker
    cmp     al, 0xE5
        je  .skip_entry              ; deleted entry

    ; skip volume labels
    mov     al, [ebx+11]             ; attribute byte
    test    al, 0x08
        jnz .skip_entry              ; volume label

    ; compare 11 name bytes
    push    ecx
    push    ebx

    mov     edi, ebx                 ; DIR entry
    mov     edx, 11

.cmp_loop:
    mov     al, [esi]
    mov     ah, [edi]
    cmp     al, ah
        jne .cmp_mismatch
    inc     esi
    inc     edi
    dec     edx
        jnz .cmp_loop

    ; match!
    pop     ebx
    pop     ecx

    ; read first cluster (offset 26, 2 bytes)
    mov     ax, [ebx+26]
    mov     [Edit_StartCluster], ax

    ; read file size (offset 28, 4 bytes)
    mov     eax, [ebx+28]
    mov     [Edit_FileSize], eax
    mov dword [Edit_DirEntryPtr], EBX

    mov     al, 1
    jmp     .Finddone

.cmp_mismatch:
    pop     ebx
    pop     ecx

.skip_entry:
    add     ebx, 32
    dec     ecx
    jmp     .next_entry

.not_found:
    xor     al, al

.Finddone:
    pop     edi
    pop     edx
    pop     ecx
    pop     ebx
    ret

Edit_LoadFileToBuffer:
    pushad

    mov EDI, Edit_Name83
    call Edit_Build83NameFromCString

    mov     eax, [RootDirLBA]
    mov     ecx, [RootDirSectors]
    mov     edi, RootDirBuf
    call    FS_ReadSectors_LBA
    test AL, AL
        jz fail_edit

    mov ESI, Edit_Name83
    call Edit_FindRootEntryByName
    test AL, AL
        jz fail_edit

    ;if file size is 0, nothing to load into the editor
    mov EAX, [Edit_FileSize]
    test EAX, EAX
        jz .no_data
    ; load first cluster into FileEditBuf
    movzx eax, word [Edit_StartCluster]
    cmp EAX, 2
        jb fail_edit

    call LBA_FromCluster
    mov ECX, [SectorsPerCluster]
    mov EDI, FileEditBuf
    call FS_ReadSectors_LBA
    test AL, AL
        jz fail_edit
    ; ---- Null-terminate at Edit_FileSize (so buffer is C-string friendly) ----
    mov eax, [Edit_FileSize]
    mov edx, FileEditBufSize
    dec edx                     ; keep 1 byte for terminator
    cmp eax, edx
        jbe .size_ok
    mov eax, edx                ; clamp if somehow oversized
    mov [Edit_FileSize], eax
.size_ok:
    mov     edi, FileEditBuf
    add     edi, eax
    mov     byte [edi], 0
.no_data:
    popad
    mov AL, 1
    ret

fail_edit:
    popad
    mov AL, 0
    ret
; -------------------------------------------------------------
; Editor_PaintFileBufToScreen
;   Uses:
;     FileEditBuf      - file bytes (already loaded)
;     Edit_FileSize    - number of bytes to paint
;     input_start_row
;     input_start_col
;     Screen_W, Screen_H, VGA_Mem
;   Effect:
;     Draws the buffer into the editor area, starting at
;     (input_start_row, input_start_col), filling cells
;     left-to-right, top-to-bottom. Cursor ends at the end.
; -------------------------------------------------------------
Editor_PainFileBufToScreen:
    pushad

    ; if no data, nothing to do
    mov     ecx, [Edit_FileSize]
    test    ecx, ecx
        jle .donepaint

    ; idx_base = input_start_row * Screen_W + input_start_col
    mov     eax, [input_start_row]
    imul    eax, [Screen_W]
    add     eax, [input_start_col]
    mov     ebx, eax                ; EBX = idx_base (current cell index)

    mov     esi, FileEditBuf        ; source ptr

.paint_loop:
    ; compute (row, col) from cell index EBX
    mov     eax, ebx
    xor     edx, edx
    div     dword [Screen_W]        ; EAX=row, EDX=col

    mov     [cur_row], eax
    mov     [cur_col], edx

    mov     al, [esi]               ; next file byte
    ; if it's 0, treat like space (or you can just let Edit_put_char skip it)
    cmp     al, 0
        jne .have_char
    mov     al, ' '
.have_char:
    call    Edit_put_char           ; this advances cursor safely

    inc     esi
    inc     ebx                     ; next cell index
    loop    .paint_loop

.donepaint:
    popad
    ret

EditorPrompt    DB  "CTRL + O = Save, CTRL + X = Exit",0 
Edit_DirEntryPtr dd 0
cmd_edit:
pushad
    mov byte [CTRL_Flag], 0
    mov byte [shift_flg], 0
call Edit_LoadFileToBuffer
test AL, AL
    jz Load_Fail       

;save shell screen
call SaveConsoleState

; Clear screen buffer for editor UI
call ClearScreen
mov EDI, [VGA_Mem]
call Set_Cursor_pos

mov ESI, EditorPrompt
call PrintPromptAtCursor

mov dword [cur_row], 1
mov dword [cur_col], 0
mov dword [input_start_row], 1
mov dword [input_start_col], 0 
call Set_Cursor_pos_from_RC

mov EAX, [Edit_FileSize]
test EAX, EAX
    jz no_initial_content

call Editor_PainFileBufToScreen

no_initial_content:

editor_kb:
        ;Status bit. 1 = available 0 = no byte to read
        in AL, 0x64     ;KBD_STATUS
        test AL, 1
            jz editor_kb
        
        ; Read scancode
        in AL, 0x60     ;KBD_DATA
        movzx ECX, AL
        cmp ECX, 0xE0   ;ignore E0 Prefix
            je editor_ext_key
        test AL, 0x80
            jz editor_make
        and ECX, 0x7f       ;released scancode
        cmp ECX, 0x2a       ; LShift up
            je editor_shift_up
        cmp ECX, 0x36       ; RSHIFT up
            je editor_shift_up
        cmp ECX, 0x1D
            je ctrl_up
        jmp editor_kb
; -------------------------------------------------------------
; editor_ext_key
;   We saw 0xE0. Read the next byte and handle arrows:
;   Up    = 0x48
;   Down  = 0x50
;   Left  = 0x4B
;   Right = 0x4D
; -------------------------------------------------------------
editor_ext_key:
    ; wait for the second byte
.wait_next:
    in al, 0x64
    test al, 1
        jz .wait_next

    in al, 0x60
    movzx ecx, al
    test al, 0x80
        jnz editor_kb
    cmp ecx, 0x48
        je editor_arrow_up
    cmp ecx, 0x50
        je editor_arrow_down
    cmp ecx, 0x4B
        je editor_arrow_left
    cmp ecx, 0x4D
        je editor_arrow_right
editor_arrow_left:
    pushad
    mov ebx, [cur_row]
    mov ecx, [cur_col]
    ; if col > 0, just move left
    test ecx, ecx
        jnz .dec_col
    ; col == 0, so wrap to previous row if possible
    test ebx, ebx
        jz .storeleft              ; already at row 0,0

    dec ebx                 ; row--
    mov ecx, [Screen_W]
    dec ecx                 ; last column
    jmp .storeleft

.dec_col:
    dec ecx

.storeleft:
    mov [cur_row], ebx
    mov [cur_col], ecx
    call Set_Cursor_pos_from_RC
    popad
    jmp editor_kb

editor_arrow_right:
    pushad
    mov     ebx, [cur_row]
    mov     ecx, [cur_col]
    mov     eax, [Screen_W]
    dec     eax                ; last valid column index
    cmp     ecx, eax
        jb  .inc_col           ; not at last column yet
    ; at last column: maybe wrap to next row
    mov eax, [Screen_H]
    dec eax                ; last row index
    cmp ebx, eax
        jae .storeright             ; bottom-right: can't move further
    inc ebx                ; next row
    xor ecx, ecx           ; col = 0
    jmp .storeright
.inc_col:
    inc     ecx
.storeright:
    mov     [cur_row], ebx
    mov     [cur_col], ecx
    call    Set_Cursor_pos_from_RC
    popad
    jmp     editor_kb

editor_arrow_up:
    pushad
    mov     ebx, [cur_row]
    mov     ecx, [cur_col]
    ; if we're already at row 0, stay there
    test    ebx, ebx
        jz  .storeup
    dec     ebx
.storeup:
    mov     [cur_row], ebx
    mov     [cur_col], ecx
    call    Set_Cursor_pos_from_RC
    popad
    jmp     editor_kb
editor_arrow_down:
    pushad
    mov ebx, [cur_row]
    mov ecx, [cur_col]
    mov eax, [Screen_H]
    dec eax                ; last row index
    cmp ebx, eax
        jae .storedown             ; already at bottom row
    inc     ebx

.storedown:
    mov [cur_row], ebx
    mov [cur_col], ecx
    call Set_Cursor_pos_from_RC

    popad
    jmp editor_kb

     editor_make:
        cmp ECX, 0x2a   ;LSHIFT down
            je editor_shift_dn
        cmp ECX, 0x36   ;RSHIFT down
            je  editor_shift_dn
        cmp ECX, 0x1D
            je ctrl_down

        movzx EAX, byte [shift_flg]
        test EAX, EAX
            jz editor_no_shift
        mov AL, BYTE [scan1_to_ascii_shift + ECX]
     jmp editor_got_char

     editor_no_shift:
     mov AL, BYTE [scan1_to_ascii_normal + ECX]

    editor_got_char:
        test AL, AL
            jz editor_kb
        cmp byte [CTRL_Flag], 1
            jne no_ctrl
        cmp al, 'o'
            je  editor_ctrl_O
        cmp al, 'O'
            je  editor_ctrl_O
        cmp al, 'x'
            je  editor_ctrl_X
        cmp al, 'X'
            je  editor_ctrl_X

    no_ctrl:
        test AL, AL
            jz editor_kb
        cmp AL, 8
            je editor_do_bs

        cmp AL, 13
            je editor_do_crlf
        call Edit_put_char
        jmp editor_kb

editor_ctrl_O:
    call Editor_CopyScreenToFileBuf
    call Editor_SaveCurrentFile
    jmp editor_kb

Editor_CopyScreenToFileBuf:
Editor_CopyScreenToFileBuf:
    pushad

    ; ---- compute base index (first editable cell) ----
    mov     eax, [input_start_row]
    imul    eax, [Screen_W]
    add     eax, [input_start_col]
    mov     ebx, eax                   ; EBX = idx_base

    ; ---- compute last cell index in editor region ----
    mov     eax, [Screen_H]
    dec     eax                        ; last row index
    imul    eax, [Screen_W]
    mov     edx, [Screen_W]
    dec     edx                        ; last col index
    add     eax, edx                   ; EAX = idx_end
    mov     esi, eax                   ; ESI = current idx scanning backward

    ; ---- scan backward for last *non-space* char ----
.find_last:
    cmp     esi, ebx
        jb  .empty                     ; nothing but spaces

    ; row,col from index ESI
    mov     eax, esi
    xor     edx, edx
    div     dword [Screen_W]           ; EAX=row, EDX=col

    mov     edi, [VGA_Mem]
    mov     ecx, eax                   ; row
    imul    ecx, [Screen_W]
    add     ecx, edx                   ; row*W + col
    shl     ecx, 1                     ; *2 bytes/char
    add     edi, ecx

    mov     al, [edi]                  ; char byte

    ; if it's ' ' or 0 => EMPTY, keep scanning
    cmp     al, ' '
        je  .prev_cell
    cmp     al, 0
        je  .prev_cell

    ; anything else = real content
    jmp     .found_last_char

.prev_cell:
    dec     esi
    jmp     .find_last

.found_last_char:
    ; length = (idx_last - idx_base + 1)
    sub     esi, ebx
    inc     esi
    mov     edx, esi                   ; EDX = length

    ; clamp length
    mov     eax, FileEditBufSize
    dec     eax                        ; max usable
    cmp     edx, eax
        jbe .len_ok
    mov     edx, eax
.len_ok:
    mov     [Edit_FileSize], edx

    ; ---- copy loop ----
    mov     edi, FileEditBuf           ; dest ptr
    mov     esi, ebx                   ; cell index = idx_base
    mov     ecx, edx                   ; loop count = length

.copy_loop:
    ; compute row,col from cell index in ESI
    mov     eax, esi
    xor     edx, edx
    div     dword [Screen_W]           ; EAX=row, EDX=col

    mov     ebx, eax                   ; row
    mov     eax, ebx
    imul    eax, [Screen_W]
    add     eax, edx                   ; + col
    shl     eax, 1                     ; *2

    mov     ebx, [VGA_Mem]
    add     ebx, eax
    mov     al, [ebx]                  ; char byte
    stosb

    inc     esi
    loop    .copy_loop

    jmp     .finalize

.empty:
    xor     eax, eax
    mov     [Edit_FileSize], eax

.finalize:
    ; null-terminate
    mov     eax, [Edit_FileSize]
    mov     edi, FileEditBuf
    add     edi, eax
    mov     byte [edi], 0

    popad
    ret
; -------------------------------------------------------------
; Editor_SaveCurrnetFile
;   Uses:
;     Edit_StartCluster   (word)
;     Edit_FileSize       (dword)
;     Edit_DirEntryPtr    (dd -> dir entry in RootDirBuf)
;     FileEditBuf         (text buffer)
;     BytesPerSector, SectorsPerCluster
;     RootDirLBA, RootDirSectors
;     LBA_FromCluster, FS_WriteSectors_LBA
; -------------------------------------------------------------
Editor_SaveCurrentFile:
    pushad

    ; ---- 1) Get starting cluster ----
    movzx   eax, word [Edit_StartCluster]
    cmp     eax, 2
        jb  .failsave              ; no valid cluster

    ; ---- 2) Clamp file size to one cluster (for now) ----
    mov     ecx, [BytesPerSector]
    imul    ecx, [SectorsPerCluster] ; ECX = bytes_per_cluster

    mov     edx, [Edit_FileSize]
    cmp     edx, ecx
        jbe .size_ok
    mov     edx, ecx                ; clamp
    mov     [Edit_FileSize], edx
.size_ok:

    ; ---- 3) Convert cluster -> LBA ----
    push    edx                     ; save size
    call    LBA_FromCluster         ; IN: EAX=cluster, OUT: EAX=LBA
    mov     ebx, eax                ; EBX = first LBA of cluster
    pop     edx                     ; restore size (not strictly needed later)

    ; ---- 4) Write one cluster from FileEditBuf ----
    mov     eax, ebx                ; start LBA
    mov     ecx, [SectorsPerCluster]
    mov     esi, FileEditBuf
    call    FS_WriteSectors_LBA
    test    al, al
        jz  .failsave                   ; write failed

    ; ---- 5) Update directory entry file size ----
    mov     edi, [Edit_DirEntryPtr]
    mov     eax, [Edit_FileSize]
    mov     [edi+28], eax           ; FileSize (4 bytes)

    ; ---- 6) Flush updated root directory back to disk ----
    mov     eax, [RootDirLBA]
    mov     ecx, [RootDirSectors]
    mov     esi, RootDirBuf
    call    FS_WriteSectors_LBA
    test    al, al
        jz  .failsave

    ; success
    popad
    ret

.failsave:
    ; (optional: print "save failed")
    popad
    ret


editor_ctrl_X:
    jmp complete
  
Edit_put_char:
    pushad
    ;max row = screen_h - 1
    mov EBX, 25
    dec EBX
    ;max col = screen_w - 1
    mov EDX, 80
    dec EDX

    mov     ecx, [cur_row]
    mov     esi, [cur_col]
    cmp ECX, ebx
        jne do_draw
    cmp ESI, EDX
        jne do_draw
    popad
    ret
do_draw:
    ; draw character at (cur_row, cur_col)
    push EDX
    mov DL, AL
    mov     edi, [VGA_Mem]
    mov     eax, ecx
    imul    eax, [Screen_W]     ; row * Screen_W
    add     eax, esi            ; + col
    shl     eax, 1              ; *2 bytes/char
    add     edi, eax
    mov     ah, 0x0F            ; attribute
    mov AL, DL
    pop EDX
    stosw                       ; write char+attr
    

    ; If we’re at last cell, do NOT advance
    cmp     ecx, ebx
        jne .not_last_cell
    cmp     esi, edx
        je  .store_pos_only

.not_last_cell:
    ; advance one column
    inc     esi
    cmp     esi, [Screen_W]
        jl  .store_pos_only

    ; wrap to next row
    xor     esi, esi            ; col = 0
    inc     ecx
    cmp     ecx, [Screen_H]
        jl  .store_pos_only

    ; if we went beyond last row, clamp to last cell
    mov     ecx, ebx            ; last row
    mov     esi, edx            ; last col

.store_pos_only:
    mov     [cur_row], ecx
    mov     [cur_col], esi
    call    Set_Cursor_pos_from_RC
    popad
    ret
    
editor_do_bs:
    mov     ebx, [cur_row]
    mov     ecx, [cur_col]

    ; BLOCK if we're at the editor's base position
    mov     edx, [input_start_row]
    cmp     ebx, edx
        jne editor_not_base_row
    mov     edx, [input_start_col]
    cmp     ecx, edx
        je  editor_done           ; can't erase before prompt

        editor_not_base_row:
            test ECX, ECX
                jnz editor_same_line
         ;we're at column 0 only wrap if strictly below the input start
            mov EDX, [input_start_row]
            cmp EBX, EDX
                jbe editor_done
            dec EBX
            mov ECX, [Screen_W]
            dec ECX
            jmp editor_erase_here

        editor_same_line:
            mov EDX, [input_start_row]
            cmp EBX, EDX
                jne editor_dec_ok
            mov EDX, [input_start_col]
            cmp ECX, edx
                Jbe editor_done

            editor_dec_ok:
                dec ECX
       
    editor_erase_here:
        mov EDI, [VGA_Mem]
        mov EAX, EBX
        imul EAX, [Screen_W]  ; row *80
        add EAX, ECX        ; row * 80 + col
        shl EAX, 1
        add EDI, EAX
        mov AX, 0x0F20
        stosw
        ;update software cursor to the erased position
        mov [cur_col], ECX
        mov [cur_row], EBX
        sub EDI, 2

        call Set_Cursor_pos_from_RC

        editor_done:
        jmp editor_kb

    editor_do_crlf:
        mov EBX, [cur_row]
        cmp EBX, 24
            jae editor_kb

        inc dword [cur_row]
        mov dword [cur_col], 0
        call Set_Cursor_pos_from_RC
        jmp editor_kb

editor_shift_dn:
    mov byte [shift_flg], 1
    jmp editor_kb

editor_shift_up:
    mov byte [shift_flg], 0
    jmp editor_kb

CTRL_Flag   DB  0
ctrl_up:
    mov byte [CTRL_Flag], 0
    jmp editor_kb

ctrl_down:
    mov byte [CTRL_Flag], 1
    jmp editor_kb

complete:
    mov byte [CTRL_Flag], 0
    mov byte [shift_flg], 0
    call RestorConnsoleState    

popad
mov AL, 1
ret

;failed to locate file
cmd_errmsg  DB  "File does not exist in current directory.",0
Load_Fail:
    popad
    call RestorConnsoleState
    mov ESI, cmd_errmsg
    call PrintPromptAtCursor
    mov dword [cur_col], 0
    mov AL, 1
    ret
ErrorEcho   DB  "File Not Found",0
cmd_echo:
    pushad

    call    Edit_LoadFileToBuffer
    test    al, al
        jz  .not_foundfile          ; AL = 0 -> failed to locate/load
    mov ESI, FileEditBuf
    call PrintPromptAtCursor
    mov dword [cur_col], 0
    popad
    mov AL, 1
    ret

    .not_foundfile:
    mov ESI, ErrorEcho
    call PrintPromptAtCursor
    popad
    mov AL, 1
    ret


cmd_dir:
    pushad
    call    Dir_ListCurrent
    popad
    mov     al, 1
    ret   

cmd_clear:
    call ClearScreen
    mov dword [cur_row], 0
    mov dword [cur_col], 0
    mov EDI, [VGA_Mem]
    call Set_Cursor_pos
    call BuildPrompt
    call Set_input_Base_From_Cursor
    mov AL, 1
    ret

SkipSpacesESI:
    s1:
    cmp ECX, 10     ;failsafe, change this nnumber if we have larger commands
        je noparam
    mov AL, byte[ESI]
    cmp AL, ' '
        je s2
    cmp AL, 0
        je s2
    inc ESI
    inc ECX
    jmp s1
    s2:
        mov byte[ESI], 0
        inc ESI ;do not make it point at the null-term it will now point to the parameters
        mov AL, 1
        ret
    noparam:
        xor AL, AL
        ret

CheckCommand:
;split the command and parameter. locate the first space
    
    mov ESI, input_buff
    mov EDI, input_buff
    xor ECX, ECX
    call SkipSpacesESI
    test AL, AL
        jz  invalid

    call to_lower
    test AL, AL
        jz invalid

    xor ECX, ECX
    mov EDX, Valid_commands
    ;ESI now holds the parameter's location, that means EDI should be the command
    ;ECX will be the counter for failchecking our commmands to make sure the input is correct
    CmdCheck:
    mov AL, byte [EDI]
    inc EDI
    cmp byte [EDX], AL
        jne SkipCmd
    inc EDX
    mov BL, byte [EDX]
    test BL, BL
        jnz CmdCheck
    mov AL, byte[EDI]
    cmp AL, BL
        jne invalid

    ;CL will contain the command we're using
    ;ESI will contain the parameter data
    call ExecuteCmd
    test AL, AL
        jz invalid
    mov AL, 1
    ret


    SkipCmd:
        mov AL, byte [EDX]
        inc EDX
        test AL, AL
            jz ComSkipCmd
        jmp SkipCmd
        
        ComSkipCmd:
            mov EDI, input_buff ;reset EDI
            inc ECX ;ECX will be our value of maximum commands we checked
            cmp ECX, 7  ; (increament this number if we increase commands)
                jge invalid
            jmp CmdCheck

    invalid:
        xor AL, AL
        ret

CheckCommandValidation:
    pushad

    call CheckCommand
    test AL, AL
        jz errmsg
    popad
    mov AL, 1
    ret

    errmsg:
    mov ESI, Error_msg
    call PrintPromptAtCursor
    mov DWORD [cur_col], 0
    popad
    mov AL, 0
    ret

SavedCurRow DD  0
SavedCurCol DD  0
SavedInputBaseRow   DD  0
SavedInputBaseCol   DD  0

SectorBuf       EQU 0x60000
RootDirBuf      EQU 0x60200          ; 14 * 512 bytes reserved in comments
DirScratchBuf   EQU 0x62000          ; 512 bytes

FileEditBuf     EQU 0x62200          ; for edit command
FileEditBufSize EQU 4096
Edit_Name83       db 11 dup(0)    ; 8.3 FAT name
Edit_FileSize     dd 0            ; actual file size in bytes (from dir entry)
Edit_StartCluster dw 0            ; starting cluster
ScreenSaveBuf   EQU 0x63200          ; for SaveConsoleState/RestoreConsoleState

; ------------------------------
; Tables (Scancode Set 1)
; Only common printable keys; others 0
; ------------------------------
section .rodata

Screen_W    DD  80
Screen_H    DD  25

; ----------------------------
; Set 1 - Unshifted (ASCII)
; ----------------------------
scan1_to_ascii_normal:
    ; 00..01
    db 0, 27                ; 00: none, 01: ESC (ASCII 27)
    ; 02..0D: 1..0 - =
    db '1','2','3','4','5','6','7','8','9','0','-','='
    db 8                    ; 0E: Backspace (ASCII 8)
    db 9                    ; 0F: Tab (ASCII 9)
    ; 10..19: q..p
    db 'q','w','e','r','t','y','u','i','o','p'
    db '[',']'              ; 1A..1B
    db 13                   ; 1C: Enter (ASCII 13)
    db 0                    ; 1D: Ctrl
    ; 1E..26: a..l
    db 'a','s','d','f','g','h','j','k','l'
    db ';',''''             ; 27..28  (semicolon, apostrophe)
    db '`'                  ; 29      (backtick)
    db 0                    ; 2A: LShift
    db '\'                  ; 2B      (backslash)
    ; 2C..32: z..m
    db 'z','x','c','v','b','n','m'
    db ',', '.', '/'        ; 33..35
    db 0                    ; 36: RShift
    db '*'                  ; 37: keypad * (ASCII 42)
    db 0                    ; 38: Alt
    db ' '                  ; 39: Space (ASCII 32)
    ; 3A..40: Caps, F1..F6 (no ASCII)
    db 0,0,0,0,0,0,0
    ; 41..47: F7..F12/Home (no ASCII)
    db 0,0,0,0,0,0,0
    ; 48..7F: rest unmapped ? 0
    times (128-0x48) db 0

; ----------------------------
; Set 1 - Shifted (ASCII)
; ----------------------------
scan1_to_ascii_shift:
    db 0, 27                ; 00 none, 01 ESC
    db '!','@','#','$','%','^','&','*','(',')','_','+'
    db 8                    ; Backspace
    db 9                    ; Tab
    db 'Q','W','E','R','T','Y','U','I','O','P'
    db '{','}'
    db 13                   ; Enter
    db 0                    ; Ctrl
    db 'A','S','D','F','G','H','J','K','L'
    db ':','"'              ; 27..28  (colon, double-quote)
    db '~'                  ; 29
    db 0                    ; LShift
    db '|'                  ; 2B
    db 'Z','X','C','V','B','N','M'
    db '<','>','?'          ; 33..35
    db 0                    ; RShift
    db '*'                  ; keypad *
    db 0                    ; Alt
    db ' '                  ; Space
    db 0,0,0,0,0,0,0        ; 3A..40
    db 0,0,0,0,0,0,0        ; 41..47
    times (128-0x48) db 0