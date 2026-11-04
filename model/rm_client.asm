; PeaBrain Stage 6b: isolated RM client + device alloc/free prototype.
; Pure FASM, raw Linux syscalls, no libc, no libcuda, no .so.
; Does NOT touch the model, the database, DRM modeset, or VFIO.
;
; Flow:
;   1. PCI discovery: scan /dev/dri/by-path for "pci-*-render", verify
;      /sys/bus/pci/devices/<addr>/{vendor,device} = 10de/2504 and the
;      driver symlink points at "nvidia". (Informational; RM ops use
;      /dev/nvidiactl as proven by observed libcuda traffic.)
;   2. open /dev/nvidiactl, 0x2b-zeroed alloc -> RM client handle.
;   3. 0x2b {hc,hc,0,0x80=NV01_DEVICE_0, NV0080{deviceId=0}} -> device.
;   4. 0x29 free device, 0x29 free client. close. Exit 0 = ALL PASS.
;
; ABI provenance (driver 610.57.04, MIT-published + observed libcuda
; traffic, confirmed by direct C experiments before porting):
;   0x2b/48B = RM_ALLOC {hClient,hParent,hObject,hClass,pParams,...562b6f0
;   0x29/16B = RM_FREE {hClient,hParent,hObject,flags}
;   NV01_DEVICE_0 = 0x80 (class/cl0080.h @ tag 610.57.04)
;   ioctl cmds: _IOWR('F',0x2b,48) = 0xC030462B, _IOWR('F',0x29,16).
; Repeat: for i in $(seq 20); do ./rm_client || break; done
; then dmesg | grep -iE 'nvrm|xid' must stay empty.
format ELF64 executable 3
entry _start

SYS_write    = 1
SYS_close    = 3
SYS_openat   = 257
SYS_ioctl    = 16
SYS_getdents = 217
SYS_readlink = 89                  ; readlink(path, buf, len), NOT readlinkat
SYS_exit     = 60

AT_FDCWD = -100
O_RDONLY = 0
O_RDWR   = 2

RM_ALLOC_CMD = 0xC030462B          ; _IOWR('F', 0x2b, 48)
RM_FREE_CMD  = 0xC0104629          ; _IOWR('F', 0x29, 16)
NV01_DEVICE_0 = 0x80
PCI_VID_NVIDIA = 0x10DE
PCI_DID_GA106  = 0x2504

segment readable executable

_start:
    call discover_pci
    test rax, rax
    jnz .die
    ; fd = openat(nvidiactl, O_RDWR)
    mov rax, SYS_openat
    mov rdi, AT_FDCWD
    lea rsi, [path_ctl]
    mov edx, O_RDWR
    syscall
    cmp rax, -4095
    jae .fail_open
    mov r14, rax
    ; --- RM client alloc (zeroed 48B) ---
    lea rdi, [arg48]
    mov ecx, 48
    xor eax, eax
    rep stosb
    mov rax, SYS_ioctl
    mov rdi, r14
    mov esi, RM_ALLOC_CMD
    lea rdx, [arg48]
    syscall
    test rax, rax
    js .fail_client
    mov eax, dword [arg48 + 8]          ; hObject assigned
    test eax, eax
    jz .fail_client
    mov dword [h_cli], eax
    push rax                      ; handle survives out_cstr below
    lea rsi, [m_client]
    call out_cstr
    pop rax
    call out_hex32
    call out_nl
    ; --- device alloc: {hc,hc,0,0x80, &nv0080, 0...} ---
    lea rdi, [arg48]
    mov ecx, 48
    xor eax, eax
    rep stosb
    mov eax, dword [h_cli]
    mov dword [arg48], eax
    mov dword [arg48 + 4], eax
    mov dword [arg48 + 12], NV01_DEVICE_0
    lea rax, [nv0080]
    mov qword [arg48 + 16], rax         ; pAllocParams (nv0080 zeroed in BSS,
    mov dword [nv0080], 0         ; deviceId 0 = first GPU)
    mov rax, SYS_ioctl
    mov rdi, r14
    mov esi, RM_ALLOC_CMD
    lea rdx, [arg48]
    syscall
    test rax, rax
    js .fail_dev
    mov eax, dword [arg48 + 8]
    test eax, eax
    jz .fail_dev
    mov dword [h_dev], eax
    push rax
    lea rsi, [m_device]
    call out_cstr
    pop rax
    call out_hex32
    call out_nl
    ; --- free device {hc,hc,hd,0} ---
    lea rdi, [arg16]
    mov ecx, 16
    xor eax, eax
    rep stosb
    mov eax, dword [h_cli]
    mov dword [arg16], eax
    mov dword [arg16 + 4], eax
    mov eax, dword [h_dev]
    mov dword [arg16 + 8], eax
    mov rax, SYS_ioctl
    mov rdi, r14
    mov esi, RM_FREE_CMD
    lea rdx, [arg16]
    syscall
    test rax, rax
    js .fail_free
    ; --- free client {hc,hc,hc,0} ---
    mov eax, dword [h_cli]
    mov dword [arg16], eax
    mov dword [arg16 + 4], eax
    mov dword [arg16 + 8], eax
    mov dword [arg16 + 12], 0
    mov rax, SYS_ioctl
    mov rdi, r14
    mov esi, RM_FREE_CMD
    lea rdx, [arg16]
    syscall
    test rax, rax
    js .fail_free
    mov rax, SYS_close
    mov rdi, r14
    syscall
    lea rsi, [m_pass]
    call out_cstr
    xor edi, edi
    mov rax, SYS_exit
    syscall
.fail_open:
    lea rsi, [m_noopen]
    call out_cstr
    jmp .die
.fail_client:
    lea rsi, [m_nocli]
    call out_cstr
    jmp .die
.fail_dev:
    lea rsi, [m_nodev]
    call out_cstr
    jmp .die
.fail_free:
    lea rsi, [m_nofree]
    call out_cstr
.die:
    mov edi, 1
    mov rax, SYS_exit
    syscall

; discover_pci: scan /dev/dri/by-path for pci-*-render, verify sysfs.
; rax 0 ok / 1 fail. Prints the chosen PCI address.
discover_pci:
    mov rax, SYS_openat
    mov rdi, AT_FDCWD
    lea rsi, [path_bypath]
    mov edx, O_RDONLY + 65536     ; O_RDONLY|O_DIRECTORY
    syscall
    cmp rax, -4095
    jae .fail
    mov r15, rax                  ; dirfd
.scan:
    mov rax, SYS_getdents
    mov rdi, r15
    lea rsi, [dentbuf]
    mov edx, 4096
    syscall
    test rax, rax
    jle .nomatch                  ; 0 = end, <0 = err
    mov rbx, rax                  ; bytes
    lea r12, [dentbuf]
.next:
    cmp rbx, 0
    je .scan                       ; next chunk
    movzx ecx, word [r12 + 16]    ; reclen
    test ecx, ecx
    jz .nomatch
    lea rsi, [r12 + 19]           ; name
    ; match "pci-" prefix (byte-wise, no endianness games)
    cmp byte [rsi], 'p'
    jne .adv
    cmp byte [rsi + 1], 'c'
    jne .adv
    cmp byte [rsi + 2], 'i'
    jne .adv
    cmp byte [rsi + 3], '-'
    jne .adv
    ; match "-render" suffix: find NUL, step back 7
    mov rdi, rsi
.find0:
    cmp byte [rdi], 0
    je .have_end
    inc rdi
    jmp .find0
.have_end:
    sub rdi, 7
    cmp rdi, rsi
    jbe .adv
    cmp byte [rdi], '-'
    jne .adv
    cmp byte [rdi + 1], 'r'
    jne .adv
    cmp byte [rdi + 2], 'e'
    jne .adv
    cmp byte [rdi + 3], 'n'
    jne .adv
    cmp byte [rdi + 4], 'd'
    jne .adv
    cmp byte [rdi + 5], 'e'
    jne .adv
    cmp byte [rdi + 6], 'r'
    jne .adv
    ; copy [rsi+4, rdi) (the "0000:01:00.0" part) to pciaddr
    mov rbx, rdi                  ; end (saved: rdi reused below)
    lea rdx, [rsi + 4]
    lea rdi, [pciaddr]
.copy:
    cmp rdx, rbx
    jae .copied
    mov al, [rdx]
    mov [rdi], al
    inc rdx
    inc rdi
    jmp .copy
.copied:
    mov byte [rdi], 0
    jmp .found
.adv:
    add r12, rcx
    sub rbx, rcx
    jmp .next
.nomatch:
    lea rsi, [m_nopci]
    call out_cstr
    mov rax, SYS_close
    mov rdi, r15
    syscall
    mov eax, 1
    ret
.fail:
    ; openat itself failed (r15 unset): no fd to close
    lea rsi, [m_nopci]
    call out_cstr
    mov eax, 1
    ret
.found:
    mov rax, SYS_close
    mov rdi, r15
    syscall
    ; print pci addr
    lea rsi, [m_pci]
    call out_cstr
    lea rsi, [pciaddr]
    call out_cstr
    call out_nl
    ; verify /sys/bus/pci/devices/<addr>/{vendor,device}
    lea rdi, [syspath]
    lea rsi, [syspre]
    call strcpy
    lea rsi, [pciaddr]
    call strcpy
    lea rsi, [syssuf_v]
    call strcpy                   ; syspath = .../vendor
    mov rax, SYS_openat
    mov rdi, AT_FDCWD
    lea rsi, [syspath]
    xor edx, edx
    syscall
    cmp rax, -4095
    jae .fail2
    mov rdi, rax
    lea rsi, [hex4buf]
    mov edx, 8
    mov rax, 0                    ; SYS_read
    syscall
    mov rbx, rax
    mov rax, 3                    ; SYS_close
    syscall
    ; parse "0x10de\n"
    lea rsi, [hex4buf]
    call parse_hex
    cmp eax, PCI_VID_NVIDIA
    jne .fail2
    ; device file: rebuild syspath with device suffix
    lea rdi, [syspath]
    lea rsi, [syspre]
    call strcpy
    lea rsi, [pciaddr]
    call strcpy
    lea rsi, [syssuf_d]
    call strcpy
    mov rax, SYS_openat
    mov rdi, AT_FDCWD
    lea rsi, [syspath]
    xor edx, edx
    syscall
    cmp rax, -4095
    jae .fail2
    mov rdi, rax
    lea rsi, [hex4buf]
    mov edx, 8
    mov rax, 0
    syscall
    mov rax, 3
    syscall
    lea rsi, [hex4buf]
    call parse_hex
    cmp eax, PCI_DID_GA106
    jne .fail2
    ; driver symlink must resolve into "nvidia"
    lea rdi, [syspath]
    lea rsi, [syspre]
    call strcpy
    lea rsi, [pciaddr]
    call strcpy
    lea rsi, [syssuf_drv]
    call strcpy
    mov rax, SYS_readlink         ; readlink(path, buf, len)
    lea rdi, [syspath]
    lea rsi, [linkbuf]
    mov edx, 256
    syscall
    test rax, rax
    js .fail2
    ; basename ends with "nvidia": scan tail (byte-wise)
    lea rsi, [linkbuf]
    add rsi, rax                  ; end
    sub rsi, 6
    cmp byte [rsi], 'n'
    jne .fail2
    cmp byte [rsi + 1], 'v'
    jne .fail2
    cmp byte [rsi + 2], 'i'
    jne .fail2
    cmp byte [rsi + 3], 'd'
    jne .fail2
    cmp byte [rsi + 4], 'i'
    jne .fail2
    cmp byte [rsi + 5], 'a'
    jne .fail2
    xor eax, eax
    ret
.fail2:
    lea rsi, [m_badsys]
    call out_cstr
    mov eax, 1
    ret

; ---- small utils (clobber rax,rcx,rdx,rsi,rdi) ----
; strcpy: rdi=dst, rsi=src -> rdi=end. preserves rbx,r12-r15.
strcpy:
.cp:
    mov al, [rsi]
    test al, al
    jz .done
    mov [rdi], al
    inc rsi
    inc rdi
    jmp .cp
.done:
    ret

; parse_hex: rsi="0x...." -> eax value.
parse_hex:
    xor eax, eax
    add rsi, 2
.lp:
    movzx ecx, byte [rsi]
    cmp cl, 10
    je .done
    test cl, cl
    jz .done
    shl eax, 4
    cmp cl, 'a'
    jae .lo
    cmp cl, 'A'
    jae .up
    sub cl, '0'
    jmp .acc
.lo:
    sub cl, 'a' - 10
    jmp .acc
.up:
    sub cl, 'A' - 10
.acc:
    and ecx, 0xF
    or eax, ecx
    inc rsi
    jmp .lp
.done:
    ret

out_cstr:
    push rsi
    xor edx, edx
.len:
    cmp byte [rsi + rdx], 0
    je .have
    inc rdx
    jmp .len
.have:
    mov rax, 1
    mov edi, 1
    pop rsi
    syscall
    ret

out_nl:
    lea rsi, [m_nl]
    jmp out_cstr

out_hex32:
    push rax
    mov rcx, 8
    lea rsi, [hexbuf + 8]
.dig:
    mov edx, eax
    and edx, 0xF
    cmp dl, 10
    jb .d09
    add dl, 'a' - 10
    jmp .sto
.d09:
    add dl, '0'
.sto:
    dec rsi
    mov [rsi], dl
    shr eax, 4
    dec rcx
    jne .dig
    mov rdx, 8
    mov rax, 1
    mov edi, 1
    syscall
    pop rax
    ret

segment readable writeable
path_ctl    db '/dev/nvidiactl', 0
path_bypath db '/dev/dri/by-path', 0
syspre      db '/sys/bus/pci/devices/', 0
syssuf_v    db '/vendor', 0
syssuf_d    db '/device', 0
syssuf_drv  db '/driver', 0
m_pci     db 'pci=', 0
m_client  db 'client=', 0
m_device  db ' device=', 0
m_nl      db 10, 0
m_pass    db 'RM68-PASS', 10, 0
m_noopen  db 'RM68-FAIL: open', 10, 0
m_nocli   db 'RM68-FAIL: client', 10, 0
m_nodev   db 'RM68-FAIL: device', 10, 0
m_nofree  db 'RM68-FAIL: free', 10, 0
m_nopci   db 'RM68-FAIL: pci-scan', 10, 0
m_badsys  db 'RM68-FAIL: sysfs', 10, 0
pciaddr   rb 32
syspath   rb 128
hex4buf   rb 16
linkbuf   rb 256
dentbuf   rb 4096
hexbuf    rb 16
arg48     rb 48
arg16     rb 16
nv0080    rb 56
h_cli     rd 1
h_dev     rd 1
