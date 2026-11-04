; PeaBrain model arena prototype — Stage 1.
; 4GiB mmap arena + bump allocator + mincore accounting + PBMD save/load.
; Pure FASM, raw Linux syscalls, no libc. Standalone self-test binary.
; Build: fasm arena.asm arena && ./arena   (exit 0 = all PASS)
format ELF64 executable 3
entry _start

SYS_read     = 0
SYS_write    = 1
SYS_openat   = 257
SYS_close    = 3
SYS_fstat    = 5
SYS_mmap     = 9
SYS_mincore  = 27
SYS_fsync    = 74
SYS_renameat = 264
SYS_unlinkat = 263
SYS_getpid   = 39
SYS_exit     = 60

AT_FDCWD   = -100
O_RDONLY   = 0
O_RDWR     = 2
O_CREAT    = 64
O_EXCL     = 128
O_DIRECTORY = 65536

MAP_PRIVATE   = 2
MAP_ANONYMOUS = 32
MAP_NORESERVE = 16384

ARENA_SIZE = 0x100000000
MAXREG     = 64
REGENT_SZ  = 32
PAGE       = 4096
MINCORE_CHUNK = 0x10000000      ; 256MB per mincore call
VEC_SZ        = 65536           ; 256MB/4K vec bytes

FNV_OFF = 0xcbf29ce484222325
FNV_PRM = 0x100000001b3

PBMD_MAGIC = 0x444D4250         ; 'PBMD' LE
PBMD_VER   = 1
PBMD_ARCH  = 1                  ; x86-64, AVX2/FMA baseline

segment readable executable

; ---- print helpers (ABI: preserve rbx,r12-r15) ----
; print_str: rsi=ptr rdx=len
print_str:
    mov rax, SYS_write
    mov rdi, 1
    syscall
    ret

; print_u64: rax=value -> decimal + newline? no, bare number
print_u64:
    push rbx
    lea rsi, [numbuf + 31]
    mov rbx, 10
    cmp rax, 0
    jne .loop
    dec rsi
    mov byte [rsi], '0'
    jmp .done0
.loop:
    xor rdx, rdx
    div rbx
    add dl, '0'
    dec rsi
    mov [rsi], dl
    test rax, rax
    jne .loop
.done0:
    lea rdx, [numbuf + 31]
    sub rdx, rsi
    mov rax, SYS_write
    mov rdi, 1
    syscall
    pop rbx
    ret

; print_hex64: rax=value -> 16 hex nibbles
print_hex64:
    push rbx
    push r12
    mov rbx, rax
    lea r12, [numbuf]
    mov ecx, 16
.hexloop:
    rol rbx, 4
    mov rax, rbx
    and al, 0x0F
    cmp al, 10
    jb .dig
    add al, 'a' - 10 - '0'
.dig:
    add al, '0'
    mov [r12], al
    inc r12
    dec ecx
    jne .hexloop
    mov rsi, numbuf
    mov rdx, 16
    mov rax, SYS_write
    mov rdi, 1
    syscall
    pop r12
    pop rbx
    ret

; fail: rsi=msg rdx=len -> print + exit 1
fail:
    push rsi
    push rdx
    mov rax, SYS_write
    mov rdi, 1
    syscall
    pop rdx
    pop rsi
    mov rax, SYS_exit
    mov rdi, 1
    syscall

; ---- FNV-1a 64: rsi=ptr rdx=len -> rax=hash ----
fnv64:
    mov rax, FNV_OFF
    test rdx, rdx
    jz .done
.loop:
    movzx ecx, byte [rsi]
    xor rax, rcx
    mov rcx, FNV_PRM
    imul rax, rcx
    inc rsi
    dec rdx
    jne .loop
.done:
    ret

; ---- LCG fill/verify (u64 words; tail bytes zero-filled on fill, ignored on verify) ----
; lcg_fill: rdi=addr rcx=bytes rax=seed
lcg_fill:
    push rbx
    mov rbx, rax
    shr rcx, 3
    jz .tail
.words:
    mov [rdi], rbx
    mov rax, rbx
    mov rdx, 6364136223846793005
    mul rdx
    mov rdx, 1442695040888963407
    add rax, rdx
    mov rbx, rax
    add rdi, 8
    dec rcx
    jne .words
.tail:
    pop rbx
    ret

; lcg_verify: rdi=addr rcx=bytes rax=seed -> rax=0 ok, 1 mismatch
lcg_verify:
    push rbx
    push r12
    mov rbx, rax
    shr rcx, 3
    jz .ok
.words:
    mov r12, [rdi]
    cmp r12, rbx
    jne .bad
    mov rax, rbx
    mov rdx, 6364136223846793005
    mul rdx
    mov rdx, 1442695040888963407
    add rax, rdx
    mov rbx, rax
    add rdi, 8
    dec rcx
    jne .words
.ok:
    xor eax, eax
    pop r12
    pop rbx
    ret
.bad:
    mov eax, 1
    pop r12
    pop rbx
    ret

; ---- arena ----
; arena_init -> rax=0 ok else -errno. sets [arenabase]
arena_init:
    mov rax, SYS_mmap
    xor edi, edi
    mov rsi, ARENA_SIZE
    mov edx, 3
    mov r10d, MAP_PRIVATE + MAP_ANONYMOUS + MAP_NORESERVE
    mov r8, -1
    xor r9d, r9d
    syscall
    cmp rax, -4095
    jae .err
    mov [arenabase], rax
    mov qword [acur], 0
    mov qword [nreg], 0
    xor eax, eax
    ret
.err:
    ret                             ; rax = -errno

; arena_alloc: rdi=size rsi=align(min 64, forced >=4096) rdx=tag -> rax=addr or 0
arena_alloc:
    push rbx
    push r12
    push r13
    mov rbx, rdi                    ; size
    mov r12, rsi                    ; align
    mov r13, rdx                    ; tag
    cmp r12, PAGE
    jae .alok
    mov r12, PAGE
.alok:
    mov rax, [acur]
    lea rcx, [r12 - 1]
    add rax, rcx
    not rcx
    and rax, rcx                    ; aligned offset
    mov rdx, rax
    add rdx, rbx
    jc .fail
    mov r10, ARENA_SIZE
    cmp rdx, r10
    ja .fail
    mov rcx, [nreg]
    cmp rcx, MAXREG
    jae .fail
    mov [acur], rdx
    ; entry = regtab + nreg*32
    mov rdx, rcx
    shl rdx, 5
    lea rdx, [regtab + rdx]
    mov [rdx], r13                 ; tag
    mov [rdx + 8], rax             ; off
    mov [rdx + 16], rbx            ; size
    mov [rdx + 24], r12            ; align
    inc qword [nreg]
    add rax, [arenabase]
    pop r13
    pop r12
    pop rbx
    ret
.fail:
    xor eax, eax
    pop r13
    pop r12
    pop rbx
    ret

; committed_bytes -> rax = mincore residency sum over live regions, or -1 on error
committed_bytes:
    push rbx
    push r12
    push r13
    push r14
    push r15
    xor r15d, r15d                  ; total resident pages
    xor r12d, r12d                  ; region idx
    mov r13, [nreg]
    test r13, r13
    jz .done
.regloop:
    mov rax, r12
    shl rax, 5
    lea rbx, [regtab + rax]
    mov r14, [rbx + 8]              ; off
    add r14, [arenabase]
    mov rax, [rbx + 16]             ; size
    add rax, PAGE - 1
    and rax, -PAGE                  ; query len, page-rounded
.pageloop:
    test rax, rax
    jz .nextreg
    mov rdx, MINCORE_CHUNK
    cmp rax, rdx
    jae .chunk
    mov rdx, rax
.chunk:                             ; rdx=chunk len, r14=addr, rax=remaining
    mov r10, rdx
    shr r10, 12                     ; vec entries this chunk
    push rax
    push r14
    mov rax, SYS_mincore
    mov rdi, r14
    mov rsi, rdx
    lea rdx, [minvec]
    syscall
    mov r11, rax                    ; save mincore rc
    pop r14
    pop rax                         ; remaining
    test r11, r11
    js .err
    ; count resident bits in minvec[0..r10)
    push rax
    lea rbx, [minvec]
    xor ecx, ecx
.cnt:
    cmp rcx, r10
    jae .cntdone
    movzx edi, byte [rbx + rcx]
    test dil, 1
    jz .cnext
    inc r15
.cnext:
    inc rcx
    jmp .cnt
.cntdone:
    pop rax
    ; advance: chunk len was min(remaining, CHUNK)
    mov rdx, MINCORE_CHUNK
    cmp rax, rdx
    jae .advfull
    mov rdx, rax
.advfull:
    add r14, rdx
    sub rax, rdx
    jmp .pageloop
.nextreg:
    inc r12
    cmp r12, r13
    jb .regloop
.done:
    mov rax, r15
    shl rax, 12
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.err:
    mov rax, -1
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ---- io helpers ----
; write_all: rdi=fd rsi=ptr rdx=len -> rax=0 ok, -1 fail
write_all:
    push rbx
    push r12
    mov rbx, rsi
    mov r12, rdx
.loop:
    test r12, r12
    jz .ok
    mov rax, SYS_write
    mov rsi, rbx
    mov rdx, r12
    syscall                         ; rdi=fd preserved? syscall keeps rdi ✓
    cmp rax, -4                     ; EINTR
    je .loop
    cmp rax, 0
    jle .fail
    add rbx, rax
    sub r12, rax
    jmp .loop
.ok:
    xor eax, eax
    pop r12
    pop rbx
    ret
.fail:
    mov rax, -1
    pop r12
    pop rbx
    ret

; read_all: rdi=fd rsi=ptr rdx=len -> rax=0 ok, -1 fail/eof-short
read_all:
    push rbx
    push r12
    mov rbx, rsi
    mov r12, rdx
.loop:
    test r12, r12
    jz .ok
    mov rax, SYS_read
    mov rsi, rbx
    mov rdx, r12
    syscall
    cmp rax, -4
    je .loop
    cmp rax, 0
    jle .fail
    add rbx, rax
    sub r12, rax
    jmp .loop
.ok:
    xor eax, eax
    pop r12
    pop rbx
    ret
.fail:
    mov rax, -1
    pop r12
    pop rbx
    ret

; close_fd: rdi=fd
close_fd:
    mov rax, SYS_close
    syscall
    ret

; ---- model_save: rsi=target path (NUL-term) -> rax=0 ok, -1 fail ----
; tmp sibling = target + ".tmp.<pid>". two CRC passes, fsync, rename, dirsync.
model_save:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r15, rsi                    ; target
    ; build tmpname
    lea rdi, [tmpname]
    mov rbx, rdi
    xor ecx, ecx
.cp:
    mov al, [r15 + rcx]
    mov [rbx + rcx], al
    test al, al
    jz .cpdone
    inc rcx
    jmp .cp
.cpdone:
    lea rbx, [rbx + rcx]
    mov dword [rbx], '.tmp'
    add rbx, 4
    mov rax, SYS_getpid
    syscall
    ; rax=pid -> decimal
    mov r13, rax
    lea r12, [numbuf + 31]
    mov byte [r12], 0
    mov rax, r13
    mov r14d, 10
.pidloop:
    xor edx, edx
    div r14
    add dl, '0'
    dec r12
    mov [r12], dl
    test rax, rax
    jne .pidloop
.pcp:
    mov al, [r12]
    test al, al
    jz .pcpdone
    mov [rbx], al
    inc rbx
    inc r12
    jmp .pcp
.pcpdone:
    mov byte [rbx], 0
    ; PASS 1: per-region data CRCs -> crcbuf, then payload CRC
    xor r12d, r12d
    mov r13, [nreg]
    test r13, r13
    jz .pass1done
.pass1:
    mov rax, r12
    shl rax, 5
    lea rbx, [regtab + rax]
    mov rsi, [rbx + 8]
    add rsi, [arenabase]
    mov rdx, [rbx + 16]
    call fnv64
    mov qword [crcbuf + r12*8], rax
    inc r12
    cmp r12, r13
    jb .pass1
.pass1done:
    ; payload_crc = fnv over all region bytes in order
    mov rax, FNV_OFF
    mov [hdr_payloadcrc], rax
    xor r12d, r12d
    test r13, r13
    jz .pass1bdone
.pass1b:
    mov rax, r12
    shl rax, 5
    lea rbx, [regtab + rax]
    mov rsi, [rbx + 8]
    add rsi, [arenabase]
    mov rdx, [rbx + 16]
    mov rax, [hdr_payloadcrc]
    ; fnv continuing from rax: inline
    test rdx, rdx
    jz .bnext
.bloop:
    movzx ecx, byte [rsi]
    xor rax, rcx
    mov rcx, FNV_PRM
    imul rax, rcx
    inc rsi
    dec rdx
    jne .bloop
.bnext:
    mov [hdr_payloadcrc], rax
    inc r12
    cmp r12, r13
    jb .pass1b
.pass1bdone:
    ; open tmp O_RDWR|O_CREAT|O_EXCL 0600
    mov rax, SYS_openat
    mov rdi, AT_FDCWD
    lea rsi, [tmpname]
    mov edx, O_RDWR + O_CREAT + O_EXCL
    mov r10d, 384                  ; 0600
    syscall
    cmp rax, -4095
    jae .fail
    mov r14, rax                    ; fd
    ; build file table: count*32 from regtab + crcbuf merge into tabbuf
    xor r12d, r12d
    test r13, r13
    jz .tabbuilt
.tabbuild:
    mov rax, r12
    shl rax, 5
    lea rsi, [regtab + rax]
    lea rdi, [tabbuf + rax]
    mov rdx, [rsi]                  ; tag
    mov [rdi], rdx
    mov rdx, [rsi + 8]              ; aren_off
    mov [rdi + 8], rdx
    mov rdx, [rsi + 16]             ; size
    mov [rdi + 16], rdx
    mov rdx, qword [crcbuf + r12*8]
    mov [rdi + 24], rdx
    inc r12
    cmp r12, r13
    jb .tabbuild
.tabbuilt:
    ; table_crc over the FILE table bytes (exactly what we write)
    mov rax, r13
    shl rax, 5
    mov r10, rax                    ; table bytes (r10 survives calls below)
    mov rsi, tabbuf
    mov rdx, rax
    call fnv64
    mov qword [hdr_tablecrc], rax
    ; compose header in hdrbuf
    mov dword [hdrbuf], PBMD_MAGIC
    mov dword [hdrbuf + 4], PBMD_VER
    mov dword [hdrbuf + 8], PBMD_ARCH
    mov dword [hdrbuf + 12], 0
    mov eax, dword [nreg]
    mov dword [hdrbuf + 16], eax
    mov dword [hdrbuf + 20], 0
    mov rax, [mstep]
    mov qword [hdrbuf + 24], rax
    ; payload_bytes = sum sizes
    xor r12d, r12d
    xor ebx, ebx
    test r13, r13
    jz .sumdone
.sum:
    mov rax, r12
    shl rax, 5
    add rbx, qword [regtab + rax + 16]
    inc r12
    cmp r12, r13
    jb .sum
.sumdone:
    mov qword [hdrbuf + 32], rbx
    mov rax, [hdr_tablecrc]
    mov qword [hdrbuf + 40], rax
    mov rax, [hdr_payloadcrc]
    mov qword [hdrbuf + 48], rax
    mov qword [hdrbuf + 56], 0
    ; write header
    mov rdi, r14
    lea rsi, [hdrbuf]
    mov edx, 64
    call write_all
    test rax, rax
    jnz .failclose
    ; write file table
    mov rax, r10
    test rax, rax
    jz .nopayloadtab
    mov rdi, r14
    lea rsi, [tabbuf]
    mov rdx, rax
    call write_all
    test rax, rax
    jnz .failclose
.nopayloadtab:
    ; write payload regions in order
    xor r12d, r12d
    test r13, r13
    jz .paydone
.pay:
    mov rax, r12
    shl rax, 5
    lea rbx, [regtab + rax]
    mov rdi, r14
    mov rsi, [rbx + 8]
    add rsi, [arenabase]
    mov rdx, [rbx + 16]
    call write_all
    test rax, rax
    jnz .failclose
    inc r12
    cmp r12, r13
    jb .pay
.paydone:
    ; fsync, rename, dirsync
    mov rax, SYS_fsync
    mov rdi, r14
    syscall
    test rax, rax
    js .failclose
    mov rdi, r14
    call close_fd
    mov rax, SYS_renameat
    mov rdi, AT_FDCWD
    lea rsi, [tmpname]
    mov rdx, AT_FDCWD
    mov r10, r15
    syscall
    test rax, rax
    js .failunlink
    ; dirsync /tmp
    mov rax, SYS_openat
    mov rdi, AT_FDCWD
    lea rsi, [filedir]
    mov edx, O_RDONLY + O_DIRECTORY
    xor r10d, r10d
    syscall
    cmp rax, -4095
    jae .oknodir                   ; rename already done; dirsync best-effort
    mov rdi, rax
    mov rbx, rax
    mov rax, SYS_fsync
    syscall
    mov rdi, rbx
    call close_fd
.oknodir:
    xor eax, eax
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.failclose:
    mov rdi, r14
    call close_fd
.failunlink:
    mov rax, SYS_unlinkat
    mov rdi, AT_FDCWD
    lea rsi, [tmpname]
    xor edx, edx
    syscall
.fail:
    mov rax, -1
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ---- model_load: rsi=target path -> rax=0 ok, -1 fail (current model preserved) ----
model_load:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r15, rsi
    mov rax, SYS_openat
    mov rdi, AT_FDCWD
    mov edx, O_RDONLY
    xor r10d, r10d
    syscall
    cmp rax, -4095
    jae .fail
    mov r14, rax                    ; fd
    ; fstat size
    mov rax, SYS_fstat
    mov rdi, r14
    lea rsi, [statbuf]
    syscall
    test rax, rax
    js .failclose
    mov r13, qword [statbuf + 48]         ; file size
    ; read header
    mov rdi, r14
    lea rsi, [hdrbuf]
    mov edx, 64
    call read_all
    test rax, rax
    jnz .failclose
    ; validate magic/ver/arch
    cmp dword [hdrbuf], PBMD_MAGIC
    jne .failclose
    cmp dword [hdrbuf + 4], PBMD_VER
    jne .failclose
    cmp dword [hdrbuf + 8], PBMD_ARCH
    jne .failclose
    mov eax, dword [hdrbuf + 16]          ; count
    cmp eax, MAXREG
    ja .failclose
    mov r12d, eax                   ; count
    ; expected size check
    mov rax, r12
    shl rax, 5
    add rax, 64
    add rax, qword [hdrbuf + 32]          ; + payload_bytes
    cmp rax, r13
    jne .failclose
    ; read table
    mov rax, r12
    shl rax, 5
    test rax, rax
    jz .tabok
    mov rdi, r14
    lea rsi, [tabbuf]
    mov rdx, rax
    call read_all
    test rax, rax
    jnz .failclose
.tabok:
    ; table_crc over tabbuf (count*32)
    mov rax, r12
    shl rax, 5
    mov rsi, tabbuf
    mov rdx, rax
    call fnv64
    cmp rax, qword [hdrbuf + 40]
    jne .failclose
    ; staging: save mark
    mov rax, [acur]
    mov [savemark], rax
    mov rax, [nreg]
    mov [savenreg], rax
    ; per-region: alloc + read + data_crc
    xor ebx, ebx                    ; idx (ebx preserved? pushed ✓)
    test r12d, r12d
    jz .allstaged
.stage:
    mov rax, rbx
    shl rax, 5
    lea r10, [tabbuf + rax]
    mov rdi, [r10 + 16]             ; size
    mov rsi, PAGE                   ; align
    mov rdx, [r10]                  ; tag
    push r10
    push rbx
    call arena_alloc
    pop rbx
    pop r10
    test rax, rax
    jz .rollback
    ; read size bytes
    mov rdi, r14
    mov rsi, rax
    mov rdx, [r10 + 16]
    push rax
    push r10
    push rbx
    call read_all
    pop rbx
    pop r10
    pop r11                         ; addr into r11? careful: popped to r11 ✓
    test rax, rax
    jnz .rollback
    ; verify data_crc
    mov rsi, r11
    mov rdx, [r10 + 16]
    push r10
    push rbx
    call fnv64
    pop rbx
    pop r10
    cmp rax, [r10 + 24]
    jne .rollback
    inc rbx
    cmp ebx, r12d
    jb .stage
.allstaged:
    ; payload_crc: recompute over staged regions (they're the tail of regtab)
    mov rax, FNV_OFF
    mov [tmpcrc], rax
    mov rax, [savenreg]
    mov r11, [nreg]                 ; end idx
.stcrc:
    cmp rax, r11
    jae .stcrcdone
    push rax
    mov rdx, rax
    shl rdx, 5
    lea r10, [regtab + rdx]
    mov rsi, [r10 + 8]
    add rsi, [arenabase]
    mov rdx, [r10 + 16]
    mov rax, [tmpcrc]
    test rdx, rdx
    jz .stnext
.stloop:
    movzx ecx, byte [rsi]
    xor rax, rcx
    mov rcx, FNV_PRM
    imul rax, rcx
    inc rsi
    dec rdx
    jne .stloop
.stnext:
    mov [tmpcrc], rax
    pop rax
    inc rax
    jmp .stcrc
.stcrcdone:
    mov rax, [tmpcrc]
    cmp rax, qword [hdrbuf + 48]
    jne .rollbackfull
    ; accept: restore step
    mov rax, qword [hdrbuf + 24]
    mov [mstep], rax
    mov rdi, r14
    call close_fd
    xor eax, eax
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.rollback:
    ; NOTE: stack may hold stale pushes? .rollback reached with balanced stack
    ; (all call sequences above pop before jumping here) — verify by audit.
    jmp .rollbackfull
.rollbackfull:
    mov rax, [savemark]
    mov [acur], rax
    mov rax, [savenreg]
    mov [nreg], rax
    mov rdi, r14
    call close_fd
.failclose:
    mov rdi, r14
    call close_fd
.fail:
    mov rax, -1
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ---- self-test ----
_start:
    call arena_init
    test rax, rax
    jnz .fmmap
    ; base print
    mov rsi, msg_arena
    mov rdx, msg_arena_l
    call print_str
    mov rax, [arenabase]
    call print_hex64
    mov rsi, msg_nl
    mov rdx, msg_nl_l
    call print_str
    ; sparse commit probe at 3GiB
    mov rax, [arenabase]
    mov rdx, 0xC0000000
    add rax, rdx
    mov rdx, 0x123456789ABCDEF0
    mov qword [rax], rdx
    cmp qword [rax], rdx
    jne .fsparse
    mov qword [rax], 0               ; release back to zero page courtesy
    ; alloc 3 regions
    mov rdi, 4*1024*1024
    mov rsi, 64
    mov rdx, 0x57454947             ; 'WEIG'
    call arena_alloc
    test rax, rax
    jz .falloc
    mov [areg0], rax
    mov rdi, 1024*1024
    mov rsi, 64
    mov rdx, 0x42494153             ; 'BIAS'
    call arena_alloc
    test rax, rax
    jz .falloc
    mov [areg1], rax
    mov rdi, 65536
    mov rsi, 64
    mov rdx, 0x53435241             ; 'SCRA'
    call arena_alloc
    test rax, rax
    jz .falloc
    mov [areg2], rax
    ; fill LCG distinct seeds
    mov rdi, [areg0]
    mov rcx, 4*1024*1024
    mov rax, 0x1111111111111111
    call lcg_fill
    mov rdi, [areg1]
    mov rcx, 1024*1024
    mov rax, 0x2222222222222222
    call lcg_fill
    mov rdi, [areg2]
    mov rcx, 65536
    mov rax, 0x3333333333333333
    call lcg_fill
    ; alloc print
    mov rsi, msg_alloc
    mov rdx, msg_alloc_l
    call print_str
    mov rax, [acur]
    call print_u64
    mov rsi, msg_nl
    mov rdx, msg_nl_l
    call print_str
    ; committed print
    call committed_bytes
    cmp rax, -1
    je .falloc
    push rax
    mov rsi, msg_commit
    mov rdx, msg_commit_l
    call print_str
    pop rax
    call print_u64
    mov rsi, msg_nl
    mov rdx, msg_nl_l
    call print_str
    ; step marker + save
    mov qword [mstep], 12345
    lea rsi, [target_path]
    call model_save
    test rax, rax
    jnz .fsave
    mov rsi, msg_saveok
    mov rdx, msg_saveok_l
    call print_str
    ; wipe arena, load back
    mov qword [acur], 0
    mov qword [nreg], 0
    mov qword [mstep], 0
    lea rsi, [target_path]
    call model_load
    test rax, rax
    jnz .fload
    mov rsi, msg_loadok
    mov rdx, msg_loadok_l
    call print_str
    ; verify: nreg==3, step==12345, LCG compare all
    cmp qword [nreg], 3
    jne .fverify
    cmp qword [mstep], 12345
    jne .fverify
    mov rax, [nreg]
    ; region addrs changed after reload (fresh allocs) — fetch from regtab
    mov rax, qword [regtab + 8]
    add rax, [arenabase]
    mov rdi, rax
    mov rcx, 4*1024*1024
    mov rax, 0x1111111111111111
    call lcg_verify
    test rax, rax
    jnz .fverify
    mov rax, qword [regtab + 32 + 8]
    add rax, [arenabase]
    mov rdi, rax
    mov rcx, 1024*1024
    mov rax, 0x2222222222222222
    call lcg_verify
    test rax, rax
    jnz .fverify
    mov rax, qword [regtab + 64 + 8]
    add rax, [arenabase]
    mov rdi, rax
    mov rcx, 65536
    mov rax, 0x3333333333333333
    call lcg_verify
    test rax, rax
    jnz .fverify
    mov rsi, msg_verifyok
    mov rdx, msg_verifyok_l
    call print_str
    ; ---- negative tests (state must survive) ----
    ; oversized alloc
    mov rdi, 0x140000000             ; 5GiB
    mov rsi, 64
    mov rdx, 0x4641494C
    call arena_alloc
    test rax, rax
    jnz .fneg
    ; bad magic (unlink first for rerun-idempotence)
    mov rax, SYS_unlinkat
    mov rdi, AT_FDCWD
    lea rsi, [bad_path]
    xor edx, edx
    syscall
    mov rax, SYS_openat
    mov rdi, AT_FDCWD
    lea rsi, [bad_path]
    mov edx, O_RDWR + O_CREAT + O_EXCL
    mov r10d, 384
    syscall
    cmp rax, -4095
    jae .fneg
    mov r14, rax
    lea rsi, [hdrbuf]
    mov ecx, 64
.fillbad:
    mov byte [rsi], 0x41
    inc rsi
    dec ecx
    jnz .fillbad
    lea rsi, [hdrbuf]
    mov rdi, r14
    mov rdx, 64
    call write_all
    mov rdi, r14
    call close_fd
    lea rsi, [bad_path]
    call model_load
    cmp rax, -1
    jne .fneg
    ; truncated: valid header+table, body missing
    mov rax, SYS_unlinkat
    mov rdi, AT_FDCWD
    lea rsi, [trunc_path]
    xor edx, edx
    syscall
    mov rax, SYS_openat
    mov rdi, AT_FDCWD
    lea rsi, [target_path]
    mov edx, O_RDONLY
    xor r10d, r10d
    syscall
    cmp rax, -4095
    jae .fneg
    mov r15, rax
    mov rax, [nreg]
    shl rax, 5
    add rax, 64
    mov r13, rax                    ; head bytes to copy
    mov rdi, r15
    lea rsi, [tabbuf2]
    mov rdx, r13
    call read_all
    push rax
    mov rdi, r15
    call close_fd
    pop rax
    test rax, rax
    jnz .fneg
    mov rax, SYS_openat
    mov rdi, AT_FDCWD
    lea rsi, [trunc_path]
    mov edx, O_RDWR + O_CREAT + O_EXCL
    mov r10d, 384
    syscall
    cmp rax, -4095
    jae .fneg
    mov r14, rax
    mov rdi, r14
    lea rsi, [tabbuf2]
    mov rdx, r13
    call write_all
    test rax, rax
    jnz .fneg
    mov rdi, r14
    call close_fd
    lea rsi, [trunc_path]
    call model_load
    cmp rax, -1
    jne .fneg
    ; state survival: nreg==3, step==12345, region0 first word == LCG seed
    cmp qword [nreg], 3
    jne .fneg
    cmp qword [mstep], 12345
    jne .fneg
    mov rax, qword [regtab + 8]
    add rax, [arenabase]
    mov rdx, 0x1111111111111111
    cmp qword [rax], rdx
    jne .fneg
    mov rsi, msg_negok
    mov rdx, msg_negok_l
    call print_str
    mov rsi, msg_pass
    mov rdx, msg_pass_l
    call print_str
    mov rax, SYS_exit
    xor edi, edi
    syscall
.fmmap:
    mov rsi, e_mmap
    mov rdx, e_mmap_l
    call fail
.falloc:
    mov rsi, e_alloc
    mov rdx, e_alloc_l
    call fail
.fsparse:
    mov rsi, e_sparse
    mov rdx, e_sparse_l
    call fail
.fsave:
    mov rsi, e_save
    mov rdx, e_save_l
    call fail
.fload:
    mov rsi, e_load
    mov rdx, e_load_l
    call fail
.fverify:
    mov rsi, e_verify
    mov rdx, e_verify_l
    call fail
.fneg:
    mov rsi, e_neg
    mov rdx, e_neg_l
    call fail

segment readable writeable
arenabase rq 1
acur      rq 1
nreg      rq 1
mstep     rq 1
savemark  rq 1
savenreg  rq 1
tmpcrc    rq 1
hdr_tablecrc   rq 1
hdr_payloadcrc rq 1
areg0     rq 1
areg1     rq 1
areg2     rq 1
tabbuf2   rb 64 + MAXREG*REGENT_SZ
regtab    rb MAXREG*REGENT_SZ
minvec    rb VEC_SZ
numbuf    rb 32
hdrbuf    rb 64
tabbuf    rb MAXREG*REGENT_SZ
crcbuf    rq MAXREG
statbuf   rb 144
tmpname   rb 256
filedir   db '/tmp', 0

msg_arena   db 'ARENA base=0x'
msg_arena_l = $ - msg_arena
msg_alloc   db 'ALLOC bytes='
msg_alloc_l = $ - msg_alloc
msg_commit  db 'COMMITTED bytes='
msg_commit_l = $ - msg_commit
msg_saveok  db 'SAVE ok', 10
msg_saveok_l = $ - msg_saveok
msg_loadok  db 'LOAD ok', 10
msg_loadok_l = $ - msg_loadok
msg_verifyok db 'VERIFY ok', 10
msg_verifyok_l = $ - msg_verifyok
msg_negok   db 'NEG ok', 10
msg_negok_l = $ - msg_negok
msg_pass    db 'ALL PASS', 10
msg_pass_l  = $ - msg_pass
msg_nl      db 10
msg_nl_l    = $ - msg_nl
e_mmap      db 'FAIL mmap arena', 10
e_mmap_l    = $ - e_mmap
e_alloc     db 'FAIL alloc', 10
e_alloc_l   = $ - e_alloc
e_save      db 'FAIL save', 10
e_save_l    = $ - e_save
e_load      db 'FAIL load', 10
e_load_l    = $ - e_load
e_verify    db 'FAIL verify', 10
e_verify_l  = $ - e_verify
e_neg       db 'FAIL negative test', 10
e_neg_l     = $ - e_neg
e_sparse    db 'FAIL sparse commit', 10
e_sparse_l  = $ - e_sparse

target_path db '/tmp/pbtest.pbmd', 0
target_len  = $ - target_path - 1
bad_path    db '/tmp/pbbad.pbmd', 0
bad_len     = $ - bad_path - 1
trunc_path  db '/tmp/pbtrunc.pbmd', 0
trunc_len   = $ - trunc_path - 1
