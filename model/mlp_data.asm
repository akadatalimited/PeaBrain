; ---- MLP data (appended inside writeable segment by splice) ----
pw1     rq 1
pb1     rq 1
pw2     rq 1
pb2     rq 1
pv1     rq 1
pvb1    rq 1
pv2     rq 1
pvb2    rq 1
hcur    dd 0
actf    dd 0
astride rq 1
bstride rq 1
cstride rq 1
bsave   rq 1
initsc  dd 1.0
lastloss dd 0.0
tsteps  rq 1
tlog    rq 1
tbatch  rq 1
tmpbatch rq 1
tmpoff  rq 1
hxptr   rq 1
htptr   rq 1
hn      rq 1
sv_pw1  rq 1
sv_pb1  rq 1
sv_pw2  rq 1
sv_pb2  rq 1
gcseed  rq 1
gcfn    rq 1
gcorig  dd 0.0
gcplus  dd 0.0
gcsave  dd 0.0
gc2eps  dd 0.0
gcmax   dd 0.0
gcallmax dd 0.0
gcfails rq 1
gcfailidx rq 1
mic_loss dd 10.24
mic_g0   dd 25.6
mic_g1   dd 38.4
mic_g2   dd 12.8
mic_g3   dd 11.84
mic_g4   dd 6.4
gcworst rq 1
gcidx   rq 1
linheld dd 0.0
nlinit  dd 0.0
nlinitheld dd 0.0
nlfinal dd 0.0
nlfinalheld dd 0.0
untrue  dd 0.0
xtbuf   rb 1024
ttbuf   rb 512
xhbuf   rb 512
thbuf   rb 256
z1buf   rb 8192
a1buf   rb 8192
ybuf    rb 512
gw1buf  rb 128
gb1buf  rb 64
gw2buf  rb 64
gb2buf  dd 0.0
w1tmp   rb 32
b1tmp   rb 16
w2tmp   rb 16
b2tmp   rb 4
aw1tmp  rb 32
ab1tmp  rb 16
aw2tmp  rb 16
ab2tmp  dd 0.0
lr      dd 0.02
lr1     dd 0.01
lr2     dd 0.005
mu      dd 0.9
leak    dd 0.01
c_1     dd 1.0
c_2     dd 2.0
c_3     dd 3.0
c_10    dd 10.0
c_a     dd 2.5
c_b     dd -1.7
c_c     dd 0.8
c_half  dd 0.5
datscale dd 2.0
sv_datscale dd 2.0
c_he4   dd 0.70710678
c_he16  dd 0.35355339
f_1     dd 1.0
f_1e6   dd 1000000.0
f_8388608 dd 8388608.0
f_4194304 dd 4194304.0
f_1em6  dd 0.000001
f_1em3  dd 0.001
f_1em3b dd 0.001
f_3em3  dd 0.003
f_15em3 dd 0.015
f_2em2  dd 0.02
c_100   dd 100.0
f_1e_8  dd 0.00000001
gceps   dd 0.01
gctol   dd 0.001
gcfloor dd 0.0001
gcmargin dd 0.05
gctries rq 1
gctmp   dd 0.0
mask_abs4 dd 0x7FFFFFFF, 0x7FFFFFFF, 0x7FFFFFFF, 0x7FFFFFFF
unseenXY dd -1.5, -0.5, 1.5, 0.5, -0.5, 1.5, 0.5, -1.5
         dd 1.9, -1.9, -1.9, 1.9, 0.0, 0.0, 1.0, -1.0
ckpt_path  db '/tmp/pbmlp.pbmd', 0
final_path db '/tmp/pbmlp_final.pbmd', 0
final2_path db '/tmp/pbmlp_final2.pbmd', 0
msg_lin      db 'LIN 2->8->1 t=2.5x-1.7y+0.8', 10
msg_lin_l    = $ - msg_lin
msg_micro    db 'MICRO ok', 10
msg_micro_l  = $ - msg_micro
msg_init     db 'INIT train='
msg_init_l   = $ - msg_init
msg_he0      db ' held='
msg_he0_l    = $ - msg_he0
msg_step     db 'STEP '
msg_step_l   = $ - msg_step
msg_tr       db ' train='
msg_tr_l     = $ - msg_tr
msg_he       db ' held='
msg_he_l     = $ - msg_he
msg_0x       db ' (0x'
msg_0x_l     = $ - msg_0x
msg_rp       db ')'
msg_rp_l     = $ - msg_rp
msg_linfinal db 'LINFINAL held='
msg_linfinal_l = $ - msg_linfinal
msg_unseen   db 'UNSEEN maxerr-e6='
msg_unseen_l = $ - msg_unseen
msg_nlhdr    db 'NL 2->16->1 leakyrelu f=3x^2-2y+1', 10
msg_nlhdr_l  = $ - msg_nlhdr
msg_save     db 'SAVE mstep='
msg_save_l   = $ - msg_save
msg_held     db ' held=0x'
msg_held_l   = $ - msg_held
msg_final    db 'FINAL mstep='
msg_final_l  = $ - msg_final
msg_trf      db ' train=0x'
msg_trf_l    = $ - msg_trf
msg_resume   db 'RESUME mstep='
msg_resume_l = $ - msg_resume
msg_rfinal   db 'RFINAL mstep='
msg_rfinal_l = $ - msg_rfinal
msg_gclin    db 'GRADCHK linear'
msg_gclin_l  = $ - msg_gclin
msg_gcrelu   db 'GRADCHK leaky'
msg_gcrelu_l = $ - msg_gcrelu
msg_gcrel    db ' maxrel-e6='
msg_gcrel_l  = $ - msg_gcrel
msg_gw1      db '  W1'
msg_gw1_l    = $ - msg_gw1
msg_gb1      db '  b1'
msg_gb1_l    = $ - msg_gb1
msg_gw2      db '  W2'
msg_gw2_l    = $ - msg_gw2
msg_gb2      db '  b2'
msg_gb2_l    = $ - msg_gb2
msg_ok       db ' ok', 10
msg_ok_l     = $ - msg_ok
msg_y0       db ' y0=0x'
msg_y0_l     = $ - msg_y0
msg_y1       db ' y1=0x'
msg_y1_l     = $ - msg_y1
msg_y2       db ' y2=0x'
msg_y2_l     = $ - msg_y2
msg_y3       db ' y3=0x'
msg_y3_l     = $ - msg_y3
e_arena   db 'FAIL arena', 10
e_arena_l = $ - e_arena
e_allocm  db 'FAIL alloc', 10
e_allocm_l = $ - e_allocm
e_lin     db 'FAIL linear', 10
e_lin_l   = $ - e_lin
e_nl      db 'FAIL nonlinear', 10
e_nl_l    = $ - e_nl
e_savem   db 'FAIL save', 10
e_savem_l = $ - e_savem
e_loadm   db 'FAIL load', 10
e_loadm_l = $ - e_loadm
e_nreg    db 'FAIL nreg', 10
e_nreg_l  = $ - e_nreg
e_gctol   db 'FAIL gradtol', 10
e_gctol_l = $ - e_gctol
e_gcfail  db 'fails='
e_gcfail_l = $ - e_gcfail
msg_idx   db ' idx='
msg_idx_l = $ - msg_idx
msg_pfail db 'PFAIL idx='
msg_pfail_l = $ - msg_pfail
msg_rel2  db ' rel-e6='
msg_rel2_l = $ - msg_rel2
msg_abs2  db ' absdiff-e6='
msg_abs2_l = $ - msg_abs2
msg_maxr  db ' maxrel-e6='
msg_maxr_l = $ - msg_maxr
e_gcrestore db 'FAIL gradrestore', 10
e_gcrestore_l = $ - e_gcrestore
e_gckink  db 'FAIL gradkink', 10
e_gckink_l = $ - e_gckink
e_micro   db 'FAIL micro', 10
e_micro_l = $ - e_micro
