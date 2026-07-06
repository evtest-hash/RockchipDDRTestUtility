/*
 * OS_REG probe — RK3568 DDR auto-detect feasibility spike.
 *
 * Runs as a DDR Test Tool "test item": downloaded via bulk (opcode 0x02) to the
 * cfg download base 0xFDCC4000 and entered via RunMemory (opcode 0x03). Runs IN
 * PLACE (no self-relocation). Reads the 12 PMU_GRF OS_REG words the rkbin DDR
 * bin populated during auto-detect and prints them so the host can read them
 * back over the USB printf channel (opcode 0x80).
 *
 * IMPORTANT — two output channels (confirmed by RE of rk3568 Boot):
 *   0xFDCC1010 puts -> putc -> UART (serial only; host's 0x80 never sees it)
 *   0xFDCC1004 puts -> RAM ring buffer at 0xFDCC38B8 -> what 0x80 returns  ★USB
 * So we MUST use 0xFDCC1004. We format hex ourselves (the hex vector 0xFDCC1018
 * also goes to UART) and emit ASCII via 0xFDCC1004.
 *
 * OS_REG: PMU_GRF base 0xFDC20000, OS_REG0 at +0x200 (OS_REG0..OS_REG11).
 * Host parses the block between OSREG_BEGIN / OSREG_END: 12 8-digit hex words.
 */
    .text
    .globl _start
    .align 2
_start:
    stp     x29, x30, [sp, #-48]!
    mov     x29, sp
    str     x19, [sp, #16]              // callee-saved: our loop index
                                        // [sp+24 .. sp+40] = hex string scratch

    adr     x0, .Lbegin
    bl      .Lputs

    mov     w19, #0
.Lloop:
    movz    x9, #0x0200
    movk    x9, #0xFDC2, lsl #16        // x9 = 0xFDC20200 (OS_REG0)
    add     x10, x9, x19, lsl #2
    ldr     w0, [x10]                   // w0 = OS_REG[i]
    add     x1, sp, #24                 // hex scratch buffer
    bl      .Lhex8                      // format 8 hex chars + NUL at [sp+24]
    add     x0, sp, #24
    bl      .Lputs                      // puts(hex) via USB ring
    adr     x0, .Lnl
    bl      .Lputs
    add     w19, w19, #1
    cmp     w19, #12
    b.lt    .Lloop

    adr     x0, .Lend
    bl      .Lputs

    mov     w0, #0                      // result = 0 (pass)
    ldr     x19, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

/* puts(x0) via the USB-ring entry 0xFDCC1004; tail-call (RETs to our caller). */
.Lputs:
    movz    x8, #0x1004
    movk    x8, #0xFDCC, lsl #16        // USB puts entry 0xFDCC1004
    br      x8

/* .Lhex8: write value w0 as 8 lowercase hex chars to [x1], then a NUL.
   Leaf; clobbers w2,w4,w5,w6 and x1. Preserves x19. */
.Lhex8:
    mov     w4, #28                     // start at the most-significant nibble
.Lhexloop:
    lsr     w5, w0, w4
    and     w5, w5, #0xF
    cmp     w5, #10
    add     w6, w5, #48                 // '0' + nib
    add     w5, w5, #87                 // 'a' - 10 + nib
    csel    w5, w5, w6, ge              // nib >= 10 -> letter, else digit
    strb    w5, [x1], #1
    subs    w4, w4, #4
    b.ge    .Lhexloop
    strb    wzr, [x1]                   // NUL terminate
    ret

    .align 3
.Lbegin: .asciz "\nOSREG_BEGIN\n"
.Lnl:    .asciz "\n"
.Lend:   .asciz "OSREG_END\n"
