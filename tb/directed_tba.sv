`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 15.10.2026 15:32:45
// Design Name: 
// Module Name: directed_tba
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


`timescale 1ns / 1ps
// =============================================================================
// directed_tb - directed tests closing the gaps the random regression cannot reach
//
//   1. GPIO write path       : SW to 0xFFFFFFF0 -> led_out; neighbours/aliases must
//                              NOT touch led_out; GPIO store must NOT touch dmem;
//                              reset clears led_out.
//   2. imm_gen               : (a) standalone: all 5 formats + invalid imm_src,
//                                  walking-1 / walking-0 / random words vs an
//                                  independent bit-by-bit reference.
//                              (b) in-core: far JAL / far branch (|offset| >= 2048),
//                                  forward and backward.
//   3. JALR bit-0 masking    : odd base, odd imm, negative imm.
//   4. Stronger checker      : ALL 31 registers + ALL 1024 data-memory words vs an
//                              expectation built by each test, plus led_out history.
//
// Each test builds its own program and its own expectation (exp_reg / exp_mem),
// so there is no ISS dependency. Registers are cleared by the program prologue.
// Unexpected clobbers anywhere are flagged (expectation defaults to 0).
// =============================================================================
module directed_tba;

    localparam logic [31:0] NOP_I = 32'h0000_0013;

    // --------------------------------------------------------------------- DUT
    logic        clk   = 1'b0;
    logic        rst_n = 1'b0;
    logic [15:0] led_out;
    rv32i_core_pipelined_full dut (.clk(clk), .rst_n(rst_n), .led_out(led_out));
    always #5 clk = ~clk;

    // standalone imm_gen instance for the unit test
    logic [31:0] t_instr;
    logic [2:0]  t_src;
    logic [31:0] t_imm;
    imm_gen u_imm_t (.instr(t_instr), .imm_src(t_src), .imm_ext(t_imm));

    // ------------------------------------------------------------ bookkeeping
    int errors = 0, checks = 0;

    logic [31:0] prog    [0:1023];
    logic [31:0] exp_reg [0:31];
    logic [31:0] exp_mem [0:1023];
    int plen = 0;

    // ======================================================================
    // Encoders
    // ======================================================================
    function automatic logic [31:0] enc_i(input int imm, input int rs1, input logic [2:0] f3,
                                          input int rd, input logic [6:0] op);
        return {imm[11:0], rs1[4:0], f3, rd[4:0], op};
    endfunction
    function automatic logic [31:0] enc_s(input int imm, input int rs2, input int rs1, input logic [2:0] f3);
        logic [11:0] i12; i12 = imm[11:0];
        return {i12[11:5], rs2[4:0], rs1[4:0], f3, i12[4:0], 7'b0100011};
    endfunction
    function automatic logic [31:0] enc_b(input int off, input int rs2, input int rs1, input logic [2:0] f3);
        logic [12:0] o; o = off[12:0];
        return {o[12], o[10:5], rs2[4:0], rs1[4:0], f3, o[4:1], o[11], 7'b1100011};
    endfunction
    function automatic logic [31:0] enc_j(input int off, input int rd);
        logic [20:0] o; o = off[20:0];
        return {o[20], o[10:1], o[11], o[19:12], rd[4:0], 7'b1101111};
    endfunction
    function automatic logic [31:0] ADDI(input int rd, input int rs1, input int imm);
        return enc_i(imm, rs1, 3'b000, rd, 7'b0010011);
    endfunction

    function automatic logic [31:0] enc_r(
        input int rd,
        input int rs1,
        input int rs2,
        input logic [2:0] funct3,
        input logic [6:0] funct7
    );
        return {funct7, rs2[4:0], rs1[4:0], funct3, rd[4:0], 7'b0110011};
    endfunction

    function automatic logic [31:0] R_ADD(input int rd, input int rs1, input int rs2);
        return enc_r(rd, rs1, rs2, 3'b000, 7'b0000000);
    endfunction

    function automatic logic [31:0] R_SUB(input int rd, input int rs1, input int rs2);
        return enc_r(rd, rs1, rs2, 3'b000, 7'b0100000);
    endfunction

    function automatic logic [31:0] R_AND(input int rd, input int rs1, input int rs2);
        return enc_r(rd, rs1, rs2, 3'b111, 7'b0000000);
    endfunction

    function automatic logic [31:0] R_OR(input int rd, input int rs1, input int rs2);
        return enc_r(rd, rs1, rs2, 3'b110, 7'b0000000);
    endfunction

    function automatic logic [31:0] R_XOR(input int rd, input int rs1, input int rs2);
        return enc_r(rd, rs1, rs2, 3'b100, 7'b0000000);
    endfunction

    function automatic logic [31:0] R_SLL(input int rd, input int rs1, input int rs2);
        return enc_r(rd, rs1, rs2, 3'b001, 7'b0000000);
    endfunction

    function automatic logic [31:0] R_SRL(input int rd, input int rs1, input int rs2);
        return enc_r(rd, rs1, rs2, 3'b101, 7'b0000000);
    endfunction

    function automatic logic [31:0] R_SRA(input int rd, input int rs1, input int rs2);
        return enc_r(rd, rs1, rs2, 3'b101, 7'b0100000);
    endfunction

    function automatic logic [31:0] R_SLT(input int rd, input int rs1, input int rs2);
        return enc_r(rd, rs1, rs2, 3'b010, 7'b0000000);
    endfunction

    function automatic logic [31:0] R_SLTU(input int rd, input int rs1, input int rs2);
        return enc_r(rd, rs1, rs2, 3'b011, 7'b0000000);
    endfunction

    function automatic logic [31:0] LUI(input int rd, input logic [19:0] imm20);
        return {imm20, rd[4:0], 7'b0110111};
    endfunction
    function automatic logic [31:0] JALR(input int rd, input int rs1, input int imm);
        return enc_i(imm, rs1, 3'b000, rd, 7'b1100111);
    endfunction
    function automatic logic [31:0] SW(input int rs2, input int rs1, input int imm);
        return enc_s(imm, rs2, rs1, 3'b010);
    endfunction
    function automatic logic [31:0] SB(input int rs2, input int rs1, input int imm);
        return enc_s(imm, rs2, rs1, 3'b000);
    endfunction

    task automatic emit(input logic [31:0] i); prog[plen] = i; plen++; endtask

    task automatic clear_exp();
        for (int i = 0; i < 32;   i++) exp_reg[i] = 32'h0;
        for (int w = 0; w < 1024; w++) exp_mem[w] = 32'h0;
    endtask

    task automatic prologue();                 // clear x1..x31, then drain with NOPs
        plen = 0;
        for (int i = 1; i < 32; i++) emit(ADDI(i, 0, 0));
        for (int i = 0; i < 4;  i++) emit(NOP_I);
    endtask

    // ======================================================================
    // Monitors
    // ======================================================================
    // led_out change history (only after reset is released)
    logic [15:0] hist [0:63];
    int          hist_n   = 0;
    logic [15:0] led_prev = 16'h0;
    always @(posedge clk) begin
        if (rst_n && (led_out !== led_prev) && hist_n < 64) begin
            hist[hist_n] = led_out;
            hist_n++;
        end
        led_prev <= led_out;
    end

    always @(posedge clk) begin
        if (rst_n && dut.u_rf.regs[0] !== 32'h0) begin
            errors++; $error("x0 non-zero @%0t", $time);
        end
        if (rst_n && dut.hazard_stall === 1'b1 && dut.if_id_flush === 1'b1) begin
            errors++; $error("stall and flush asserted together @%0t", $time);
        end
    end

    // ======================================================================
    // DUT access helpers
    // ======================================================================
    function automatic logic [31:0] dmem_word(input int w);
        return {dut.u_dmem.g_bank[3].mem[w], dut.u_dmem.g_bank[2].mem[w],
                dut.u_dmem.g_bank[1].mem[w], dut.u_dmem.g_bank[0].mem[w]};
    endfunction

    task automatic clear_dmem();
        for (int w = 0; w < 1024; w++) begin
            dut.u_dmem.g_bank[0].mem[w] = 8'h00;
            dut.u_dmem.g_bank[1].mem[w] = 8'h00;
            dut.u_dmem.g_bank[2].mem[w] = 8'h00;
            dut.u_dmem.g_bank[3].mem[w] = 8'h00;
        end
    endtask

    task automatic run_prog();
        int cyc, maxc;
        maxc = 4 * plen + 2000;
        rst_n = 1'b0;
        for (int i = 0; i < 1024; i++) dut.u_imem.mem[i] = NOP_I;
        for (int i = 0; i < plen;  i++) dut.u_imem.mem[i] = prog[i];
        clear_dmem();
        repeat (3) @(negedge clk);
        hist_n = 0;
        rst_n  = 1'b1;
        cyc = 0;
        while (dut.pc_out < (4 * plen + 16) && cyc < maxc) begin
            @(negedge clk); cyc++;
        end
        checks++;
        if (cyc >= maxc) begin
            errors++;
            $error("DUT did not reach end of program (pc_out=0x%08h, end=0x%08h)", dut.pc_out, 4 * plen);
        end
        repeat (12) @(negedge clk);                       // drain
    endtask

    // full-state check: 31 registers + 1024 memory words
    task automatic check_all(input string name);
        int e0;
        e0 = errors;
        for (int r = 1; r < 32; r++) begin
            checks++;
            if (dut.u_rf.regs[r] !== exp_reg[r]) begin
                errors++;
                $error("[%s] x%0d = 0x%08h, expected 0x%08h", name, r, dut.u_rf.regs[r], exp_reg[r]);
            end
        end
        for (int w = 0; w < 1024; w++) begin
            checks++;
            if (dmem_word(w) !== exp_mem[w]) begin
                errors++;
                $error("[%s] dmem word %0d (byte 0x%03h) = 0x%08h, expected 0x%08h",
                       name, w, 4 * w, dmem_word(w), exp_mem[w]);
            end
        end
        if (errors == e0) $display("  [PASS] %s", name);
        else              $display("  [FAIL] %s", name);
    endtask

    // ======================================================================
    // (2a) imm_gen standalone unit test
    // ======================================================================
    // Independent reference, built bit-by-bit from the RISC-V spec field layout.
    function automatic logic [31:0] ref_imm(input logic [31:0] ins, input logic [2:0] src);
        logic [31:0] r;
        r = 32'h0;
        case (src)
            3'd0: begin                                           // I
                r[11:0] = ins[31:20];
                for (int i = 12; i < 32; i++) r[i] = ins[31];
            end
            3'd1: begin                                           // S
                r[4:0]  = ins[11:7];
                r[11:5] = ins[31:25];
                for (int i = 12; i < 32; i++) r[i] = ins[31];
            end
            3'd2: begin                                           // B
                r[0]    = 1'b0;
                r[4:1]  = ins[11:8];
                r[10:5] = ins[30:25];
                r[11]   = ins[7];
                r[12]   = ins[31];
                for (int i = 13; i < 32; i++) r[i] = ins[31];
            end
            3'd3: begin                                           // U
                r[31:12] = ins[31:12];
            end
            3'd4: begin                                           // J
                r[0]     = 1'b0;
                r[10:1]  = ins[30:21];
                r[11]    = ins[20];
                r[19:12] = ins[19:12];
                r[20]    = ins[31];
                for (int i = 21; i < 32; i++) r[i] = ins[31];
            end
            default: r = 32'h0;                                   // invalid imm_src
        endcase
        return r;
    endfunction

    task automatic chk_imm(input logic [31:0] ins, input logic [2:0] src);
        logic [31:0] e;
        t_instr = ins; t_src = src;
        #1;
        e = ref_imm(ins, src);
        checks++;
        if (t_imm !== e) begin
            errors++;
            $error("[imm_gen] src=%0d instr=0x%08h got 0x%08h expected 0x%08h", src, ins, t_imm, e);
        end
    endtask

    task automatic imm_unit_test();
        int e0;
        logic [2:0] s;
        e0 = errors;
        for (int si = 0; si < 8; si++) begin                      // 0-4 valid, 5-7 invalid -> 0
            s = si[2:0];
            chk_imm(32'h0000_0000, s);
            chk_imm(32'hFFFF_FFFF, s);
            for (int k = 0; k < 32; k++) begin
                chk_imm(32'h1 << k,    s);                        // walking one
                chk_imm(~(32'h1 << k), s);                        // walking zero
            end
            for (int n = 0; n < 4000; n++) chk_imm($urandom(), s);
        end
        if (errors == e0) $display("  [PASS] imm_gen standalone (all formats, walking + random)");
        else              $display("  [FAIL] imm_gen standalone");
    endtask


    // ======================================================================
    // ALU R-type operation coverage
    //   Exercises every RV32I R-type ALU operation:
    //   ADD, SUB, AND, OR, XOR, SLL, SRL, SRA, SLT, SLTU.
    // ======================================================================
    task automatic test_alu_ops();
        int e0;
        e0 = errors;
        clear_exp();
        prologue();

        // Operands:
        // x1 = 10, x2 = 3, x3 = -10
        emit(ADDI(1, 0, 10));
        emit(ADDI(2, 0, 3));
        emit(ADDI(3, 0, -10));

        // All ten R-type ALU operations.
        emit(R_ADD (4,  1, 2));   // 10 + 3  = 13
        emit(R_SUB (5,  1, 2));   // 10 - 3  = 7
        emit(R_AND (6,  1, 2));   // 10 & 3  = 2
        emit(R_OR  (7,  1, 2));   // 10 | 3  = 11
        emit(R_XOR (8,  1, 2));   // 10 ^ 3  = 9
        emit(R_SLL (9,  1, 2));   // 10 << 3  = 80
        emit(R_SRL (10, 1, 2));   // 10 >> 3  = 1
        emit(R_SRA (11, 3, 2));   // -10 >>> 3 = -2
        emit(R_SLT (12, 3, 1));   // -10 < 10 signed = 1
        emit(R_SLTU(13, 3, 1));   // 0xFFFFFFF6 < 10 unsigned = 0

        exp_reg[1]  = 32'd10;
        exp_reg[2]  = 32'd3;
        exp_reg[3]  = 32'hFFFF_FFF6;
        exp_reg[4]  = 32'd13;
        exp_reg[5]  = 32'd7;
        exp_reg[6]  = 32'd2;
        exp_reg[7]  = 32'd11;
        exp_reg[8]  = 32'd9;
        exp_reg[9]  = 32'd80;
        exp_reg[10] = 32'd1;
        exp_reg[11] = 32'hFFFF_FFFE;
        exp_reg[12] = 32'd1;
        exp_reg[13] = 32'd0;

        run_prog();
        check_all("ALU: all R-type operations");

        if (errors == e0) $display("  [PASS] ALU: all R-type operations");
        else              $display("  [FAIL] ALU: all R-type operations");
    endtask

    // ======================================================================
    // (1) GPIO write path + (4) led_out history / reset check
    // ======================================================================
    task automatic test_gpio();
        int e0;
        logic [15:0] exp_hist [0:4];
        e0 = errors;
        clear_exp(); prologue();

        emit(ADDI(1, 0, -16));                         // x1 = 0xFFFFFFF0 (ADDI sign-extends; no LUI needed)
        emit(LUI (2, 20'h12345)); emit(ADDI(2, 2, 'h678));   // x2 = 0x12345678
        emit(LUI (3, 20'h0000A)); emit(ADDI(3, 3, 'h5A5));   // x3 = 0x0000A5A5
        emit(ADDI(4, 0, -12));                         // x4 = 0xFFFFFFF4 (just above GPIO)
        emit(ADDI(5, 0, -20));                         // x5 = 0xFFFFFFEC (just below GPIO)

        emit(SW(2, 1, 0));     // GPIO write            -> led = 0x5678
        emit(SW(3, 1, 0));     // GPIO write            -> led = 0xA5A5
        emit(SW(2, 4, 0));     // 0xFFFFFFF4: dmem only -> led unchanged
        emit(SW(3, 5, 0));     // 0xFFFFFFEC: dmem only -> led unchanged
        emit(SB(2, 1, 0));     // CHARACTERISATION: gpio_leds ignores funct3, led <= wdata[15:0] = 0x5678
        emit(SW(0, 1, 0));     // GPIO write of 0       -> led = 0x0000
        emit(SW(3, 1, 0));     // GPIO write            -> led = 0xA5A5

        exp_reg[1] = 32'hFFFF_FFF0;  exp_reg[2] = 32'h1234_5678;  exp_reg[3] = 32'h0000_A5A5;
        exp_reg[4] = 32'hFFFF_FFF4;  exp_reg[5] = 32'hFFFF_FFEC;
        // dmem aliases addr[11:2]. GPIO word (0xFF0 -> 1020) must stay 0.
        exp_mem[1021] = 32'h1234_5678;                 // from SW to 0xFFFFFFF4
        exp_mem[1019] = 32'h0000_A5A5;                 // from SW to 0xFFFFFFEC

        exp_hist[0] = 16'h5678; exp_hist[1] = 16'hA5A5; exp_hist[2] = 16'h5678;
        exp_hist[3] = 16'h0000; exp_hist[4] = 16'hA5A5;

        run_prog();
        check_all("gpio: regs + full dmem");

        checks++;
        if (hist_n != 5) begin
            errors++; $error("[gpio] led_out changed %0d times, expected 5", hist_n);
        end
        for (int i = 0; i < 5 && i < hist_n; i++) begin
            checks++;
            if (hist[i] !== exp_hist[i]) begin
                errors++; $error("[gpio] led change #%0d = 0x%04h, expected 0x%04h", i, hist[i], exp_hist[i]);
            end
        end
        checks++;
        if (led_out !== 16'hA5A5) begin
            errors++; $error("[gpio] final led_out = 0x%04h, expected 0xA5A5", led_out);
        end

        // reset must clear the LEDs
        rst_n = 1'b0;
        repeat (2) @(negedge clk);
        checks++;
        if (led_out !== 16'h0000) begin
            errors++; $error("[gpio] led_out = 0x%04h after reset, expected 0", led_out);
        end

        if (errors == e0) $display("  [PASS] gpio: led history + reset");
        else              $display("  [FAIL] gpio: led history + reset");
    endtask

    // ======================================================================
    // (3) JALR bit-0 masking
    //   each case:  ADDI x10 ; JALR x(16+c) ; poison ; poison ; L0 ; L1
    //   target = (x10 + imm) & ~1 must land on L0 or L1; poison must never run
    // ======================================================================
    task automatic jalr_case(input int c, input int base_adj, input int imm, input int land_off);
        int ji, l0;
        ji = plen + 1;                                  // JALR index
        l0 = plen + 4;                                  // L0 index
        emit(ADDI(10, 0, 4 * l0 + base_adj));
        emit(JALR(16 + c, 10, imm));
        emit(ADDI(12, 0, 'h7FF));                       // poison (wrong path)
        emit(ADDI(12, 0, 'h7FF));
        emit(ADDI(13, 13, 1));                          // L0
        emit(ADDI(14, 14, 1));                          // L1
        exp_reg[10]   = 4 * l0 + base_adj;
        exp_reg[16+c] = 4 * (ji + 1);                   // link = JALR pc + 4
        exp_reg[14]   = exp_reg[14] + 1;
        if (land_off == 0) exp_reg[13] = exp_reg[13] + 1;
    endtask

    task automatic test_jalr();
        clear_exp(); prologue();
        jalr_case(0, 1, 0,  0);      // odd base, imm 0        -> bit0 masked, lands L0
        jalr_case(1, 0, 1,  0);      // even base, odd imm     -> bit0 masked, lands L0
        jalr_case(2, 2, 3,  1);      // sum = +5               -> masked to +4, lands L1
        jalr_case(3, 3, 2,  1);      // odd base, imm 2        -> +5 -> +4, lands L1
        jalr_case(4, 9, -8, 0);      // negative imm, sum +1   -> masked, lands L0
        run_prog();
        check_all("jalr: bit-0 masking");
    endtask

    // ======================================================================
    // (2b) far JAL / far branch through the core (|offset| >= 2048)
    //   a   : ctl#1  -> c           (forward  +2080)
    //   a+1 : marker B (x23)        (reached by backward ctl#2)
    //   a+2 : ctl#3  -> d           (forward  +2084)
    //   ...poison fill...
    //   c   : marker C (x21)
    //   c+1 : ctl#2  -> a+1         (backward -2080)
    //   c+2 : poison
    //   d   : marker D (x25)
    // ======================================================================
    task automatic emit_ctl(input bit use_branch, input int rd, input int off);
        if (use_branch) emit(enc_b(off, 0, 0, 3'b000));   // BEQ x0,x0 : always taken
        else            emit(enc_j(off, rd));
    endtask

    task automatic test_far(input bit use_branch);
        int a, b, c, d;
        clear_exp(); prologue();
        a = plen; b = a + 1; c = a + 520; d = c + 3;
        emit_ctl(use_branch, 20, 4 * (c - a));
        emit(ADDI(23, 0, 'h66));
        emit_ctl(use_branch, 0,  4 * (d - (a + 2)));
        while (plen < c) emit(ADDI(22, 22, 1));           // poison: must never execute
        emit(ADDI(21, 0, 'h55));
        emit_ctl(use_branch, 24, 4 * (b - (c + 1)));
        emit(ADDI(22, 22, 1));                            // poison
        emit(ADDI(25, 0, 'h77));

        exp_reg[21] = 32'h55;  exp_reg[23] = 32'h66;  exp_reg[25] = 32'h77;
        if (!use_branch) begin
            exp_reg[20] = 4 * (a + 1);                    // JAL link
            exp_reg[24] = 4 * (c + 2);
        end
        run_prog();
        // NOTE: do not use `cond ? "str_a" : "str_b"` as a string argument - xsim crashes on it
        if (use_branch) check_all("far BEQ  (fwd+bwd, |off|>=2048)");
        else            check_all("far JAL  (fwd+bwd, |off|>=2048)");
    endtask

    // ======================================================================
    // Main
    // ======================================================================
    initial begin : watchdog
        #500_000_000;
        $fatal(1, "Watchdog timeout");
    end

    initial begin : main
        #1;
        $display("=========== directed tests ===========");
        imm_unit_test();
        test_alu_ops();
        test_gpio();
        test_jalr();
        test_far(1'b0);
        test_far(1'b1);
        $display("----------------------------------------------");
        $display("  checks: %0d   errors: %0d", checks, errors);
        if (errors == 0) $display("  *** DIRECTED TESTS PASSED ***");
        else             $display("  *** DIRECTED TESTS FAILED: %0d error(s) ***", errors);
        $display("==============================================");
        $finish;
    end

endmodule
