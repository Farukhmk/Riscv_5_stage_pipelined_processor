`timescale 1ns / 1ps
// =============================================================================
// regression_tb - large automated random regression for rv32i_core_pipelined_full
//
// Every iteration:
//   1. generates a random RV32I program (ALU, LUI/AUIPC, LB/LH/LW/LBU/LHU,
//      SB/SH/SW, forward branches of all 6 kinds, JAL, JALR, bounded loops,
//      pointer-register updates feeding load/store addresses),
//   2. runs it on a built-in instruction-set simulator (ISS) that decodes the
//      *encoded* instruction words (independent of the generator),
//   3. runs the same words on the DUT and compares
//        - all 32 registers,
//        - the 16-word data region,
//        - number of load-use stall cycles   (ISS replicates the hazard unit's
//          rs1/rs2-field compare exactly),
//        - number of branch/jump flush cycles (taken branches + jumps),
//        - termination (DUT must reach the end of the program in time).
//   Always-on monitors: stall/flush exclusion, PC + IF/ID freeze on stall, x0.
//
// Register usage inside generated programs
//   x1..x7 (pool, size varies per program: 2/3/5/7 regs -> hazard density)
//   x8  loop counter        x9  data pointer (always BASE+{0,4,8,12})
//   x10 JALR target scratch x15 data base (constant BASE)
//
// Plusargs:  +NUM=<programs>  +LEN=<body instrs>  +SEED=<n>  +STOP_ON_FAIL
//            +NOSTALLCHK (skip stall/flush count checks)
//            +UNALIGNED  (LH/LW/SH/SW at any byte address, incl. word-crossing)
// Failing programs are written to fail_prog_<n>.hex (loadable with $readmemh).
// =============================================================================
module regression_tb;

    // ------------------------------------------------------------------ config
    localparam logic [31:0] NOP_I = 32'h0000_0013;
    localparam int          BASE  = 32'h80;       // data region: bytes 0x80..0xBF (16 words)

    int NUM_PROGRAMS = 300;
    int BODY_LEN     = 60;
    int SEED         = 1;
    bit STOP_ON_FAIL = 1'b0;
    bit CHK_COUNTS   = 1'b1;
    bit UNALIGNED    = 1'b0;   // +UNALIGNED : LH/LW/SH/SW at any byte address (stays inside the 16-word region)

    // --------------------------------------------------------------------- DUT
    logic        clk   = 1'b0;
    logic        rst_n = 1'b0;
    logic [15:0] led_out;
    rv32i_core_pipelined_full dut (.clk(clk), .rst_n(rst_n), .led_out(led_out));
    always #5 clk = ~clk;

    // ------------------------------------------------------------ bookkeeping
    int errors = 0, checks = 0, progs_failed = 0, mon_errors = 0;
    int cur_idx = 0;
    longint tot_dyn = 0, tot_taken = 0, tot_jumps = 0, tot_stalls = 0, tot_loads = 0, tot_stores = 0;
    int dumped = 0;
    int skip_val;

    // ------------------------------------------------------- program buffer
    logic [31:0] prog [0:511];
    int plen = 0;
    int pool_n = 7;
    int pend_tgt = 0;   // highest instruction index targeted by an emitted forward jump/branch

    task automatic emit(input logic [31:0] i); prog[plen] = i; plen++; endtask

    // ======================================================================
    // Encoders
    // ======================================================================
    function automatic logic [31:0] enc_r(input logic [6:0] f7, input int rs2, input int rs1,
                                          input logic [2:0] f3, input int rd);
        return {f7, rs2[4:0], rs1[4:0], f3, rd[4:0], 7'b0110011};
    endfunction
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
    function automatic logic [31:0] enc_u(input logic [19:0] imm20, input int rd, input logic [6:0] op);
        return {imm20, rd[4:0], op};
    endfunction
    function automatic logic [31:0] ADDI(input int rd, input int rs1, input int imm);
        return enc_i(imm, rs1, 3'b000, rd, 7'b0010011);
    endfunction
    function automatic logic [31:0] SW(input int rs2, input int rs1, input int imm);
        return enc_s(imm, rs2, rs1, 3'b010);
    endfunction

    // R-type op index -> {funct7, funct3}
    function automatic logic [9:0] r_enc(input int op);
        case (op)
            0: return {7'b0000000, 3'b000};  1: return {7'b0100000, 3'b000};
            2: return {7'b0000000, 3'b111};  3: return {7'b0000000, 3'b110};
            4: return {7'b0000000, 3'b100};  5: return {7'b0000000, 3'b010};
            6: return {7'b0000000, 3'b011};  7: return {7'b0000000, 3'b001};
            8: return {7'b0000000, 3'b101};  default: return {7'b0100000, 3'b101};
        endcase
    endfunction

    // ======================================================================
    // ISS (golden model) - decodes real instruction words
    // ======================================================================
    logic [31:0] iss_r  [0:31];
    logic [7:0]  iss_m  [0:4095];

    function automatic logic [31:0] alu_model(input int op, input logic [31:0] a, input logic [31:0] b);
        case (op)
            0: return a + b;
            1: return a - b;
            2: return a & b;
            3: return a | b;
            4: return a ^ b;
            5: return ($signed(a) < $signed(b)) ? 32'd1 : 32'd0;
            6: return (a < b) ? 32'd1 : 32'd0;
            7: return a << b[4:0];
            8: return a >> b[4:0];
            default: return $signed(a) >>> b[4:0];
        endcase
    endfunction

    function automatic logic [31:0] iss_ld(input logic [31:0] a, input int nbytes);
        logic [31:0] v; v = 32'h0;
        for (int i = 0; i < nbytes; i++) v[8*i +: 8] = iss_m[(a + i) & 32'hFFF];
        return v;
    endfunction

    task automatic iss_st(input logic [31:0] a, input logic [31:0] d, input int nbytes);
        for (int i = 0; i < nbytes; i++) iss_m[(a + i) & 32'hFFF] = d[8*i +: 8];
    endtask

    // runs from instruction index 'start' until pc >= 4*stop; returns dynamic stats
    task automatic iss_run(input int start, input int stop,
                           output int dyn, output int taken, output int jumps,
                           output int stalls, output int loads, output int stores);
        logic [31:0] pc, ins, a, b, res, npc, ea, v;
        logic [6:0]  opc, f7;
        logic [2:0]  f3;
        logic [4:0]  rd, rs1, rs2;
        logic [31:0] immI, immS, immB, immU, immJ;
        logic        tk;
        int          op, prev_ld_rd;

        for (int i = 0; i < 32;   i++) iss_r[i] = 32'h0;
        for (int i = 0; i < 4096; i++) iss_m[i] = 8'h0;
        iss_r[15] = BASE; iss_r[9] = BASE;                 // set by the prologue

        dyn = 0; taken = 0; jumps = 0; stalls = 0; loads = 0; stores = 0;
        prev_ld_rd = 0;
        pc = 4*start;

        while (pc < 4*stop && dyn < 50000) begin
            ins = prog[pc >> 2];
            opc = ins[6:0]; rd = ins[11:7]; f3 = ins[14:12]; rs1 = ins[19:15]; rs2 = ins[24:20]; f7 = ins[31:25];
            immI = {{20{ins[31]}}, ins[31:20]};
            immS = {{20{ins[31]}}, ins[31:25], ins[11:7]};
            immB = {{20{ins[31]}}, ins[7], ins[30:25], ins[11:8], 1'b0};
            immU = {ins[31:12], 12'b0};
            immJ = {{12{ins[31]}}, ins[19:12], ins[20], ins[30:21], 1'b0};
            a = iss_r[rs1]; b = iss_r[rs2];
            npc = pc + 4;

            // replicate hazard_detection_unit (field compare, exactly as the RTL does it)
            if (prev_ld_rd != 0 && (rs1 == prev_ld_rd || rs2 == prev_ld_rd)) stalls++;
            prev_ld_rd = 0;

            case (opc)
                7'b0110011: begin                                  // R
                    case ({f7[5], f3})
                        4'b0000: op = 0;  4'b1000: op = 1;  4'b0111: op = 2;  4'b0110: op = 3;
                        4'b0100: op = 4;  4'b0010: op = 5;  4'b0011: op = 6;  4'b0001: op = 7;
                        4'b0101: op = 8;  default: op = 9;
                    endcase
                    if (rd != 0) iss_r[rd] = alu_model(op, a, b);
                end
                7'b0010011: begin                                  // I
                    case (f3)
                        3'b000: res = alu_model(0, a, immI);
                        3'b010: res = alu_model(5, a, immI);
                        3'b011: res = alu_model(6, a, immI);
                        3'b100: res = alu_model(4, a, immI);
                        3'b110: res = alu_model(3, a, immI);
                        3'b111: res = alu_model(2, a, immI);
                        3'b001: res = alu_model(7, a, {27'b0, ins[24:20]});
                        default: res = ins[30] ? alu_model(9, a, {27'b0, ins[24:20]})
                                               : alu_model(8, a, {27'b0, ins[24:20]});
                    endcase
                    if (rd != 0) iss_r[rd] = res;
                end
                7'b0110111: if (rd != 0) iss_r[rd] = immU;                 // LUI
                7'b0010111: if (rd != 0) iss_r[rd] = pc + immU;            // AUIPC
                7'b0000011: begin                                  // loads
                    ea = a + immI; loads++;
                    case (f3)
                        3'b000: begin v = iss_ld(ea, 1); v = {{24{v[7]}},  v[7:0]};  end
                        3'b001: begin v = iss_ld(ea, 2); v = {{16{v[15]}}, v[15:0]}; end
                        3'b010: v = iss_ld(ea, 4);
                        3'b100: v = iss_ld(ea, 1);
                        default: v = iss_ld(ea, 2);
                    endcase
                    if (rd != 0) iss_r[rd] = v;
                    prev_ld_rd = rd;
                end
                7'b0100011: begin                                  // stores
                    ea = a + immS; stores++;
                    case (f3)
                        3'b000: iss_st(ea, b, 1);
                        3'b001: iss_st(ea, b, 2);
                        default: iss_st(ea, b, 4);
                    endcase
                end
                7'b1100011: begin                                  // branches
                    case (f3)
                        3'b000: tk = (a == b);
                        3'b001: tk = (a != b);
                        3'b100: tk = ($signed(a) <  $signed(b));
                        3'b101: tk = ($signed(a) >= $signed(b));
                        3'b110: tk = (a <  b);
                        default: tk = (a >= b);
                    endcase
                    if (tk) begin npc = pc + immB; taken++; end
                end
                7'b1101111: begin                                  // JAL
                    if (rd != 0) iss_r[rd] = pc + 4;
                    npc = pc + immJ; jumps++;
                end
                7'b1100111: begin                                  // JALR
                    res = (a + immI) & 32'hFFFF_FFFE;
                    if (rd != 0) iss_r[rd] = pc + 4;
                    npc = res; jumps++;
                end
                default: ;
            endcase
            iss_r[0] = 32'h0;
            pc = npc;
            dyn++;
        end
    endtask

    // ======================================================================
    // Random program generator
    // ======================================================================
    function automatic int rdst();   // destination: pool, occasionally x0
        return ($urandom_range(0, 14) == 0) ? 0 : $urandom_range(1, pool_n);
    endfunction
    function automatic int rsrc();   // source: pool, occasionally x0
        return ($urandom_range(0, 9) == 0) ? 0 : $urandom_range(1, pool_n);
    endfunction

    task automatic gen_r();
        logic [9:0] rf;
        rf = r_enc($urandom_range(0, 9));
        emit(enc_r(rf[9:3], rsrc(), rsrc(), rf[2:0], rdst()));
    endtask

    task automatic gen_i();
        int op, imm, sh;
        logic [2:0] f3;
        logic [11:0] imm12;
        op  = $urandom_range(0, 8);
        imm = $urandom_range(0, 4095) - 2048;
        sh  = $urandom_range(0, 31);
        case (op)
            0: begin f3 = 3'b000; imm12 = imm[11:0]; end
            1: begin f3 = 3'b111; imm12 = imm[11:0]; end
            2: begin f3 = 3'b110; imm12 = imm[11:0]; end
            3: begin f3 = 3'b100; imm12 = imm[11:0]; end
            4: begin f3 = 3'b010; imm12 = imm[11:0]; end
            5: begin f3 = 3'b011; imm12 = imm[11:0]; end
            6: begin f3 = 3'b001; imm12 = {7'b0000000, sh[4:0]}; end
            7: begin f3 = 3'b101; imm12 = {7'b0000000, sh[4:0]}; end
            default: begin f3 = 3'b101; imm12 = {7'b0100000, sh[4:0]}; end
        endcase
        emit(enc_i(imm12, rsrc(), f3, rdst(), 7'b0010011));
    endtask

    task automatic gen_u();
        logic [19:0] u;
        u = $urandom();
        if ($urandom_range(0, 1)) emit(enc_u(u, rdst(), 7'b0110111));   // LUI
        else                      emit(enc_u(u, rdst(), 7'b0010111));   // AUIPC
    endtask

    // pick base register + legal offset for an access of 'sz' bytes (1/2/4)
    task automatic pick_addr(input int sz, output int base, output int imm);
        int maxoff;
        base = ($urandom_range(0, 2) == 0) ? 15 : 9;
        if (base == 9 && $urandom_range(0, 3) == 0)                  // pointer produced right before use
            emit(ADDI(9, 15, 4 * $urandom_range(0, 3)));
        maxoff = (base == 9) ? 48 : 60;
        if (UNALIGNED) imm = $urandom_range(0, maxoff);          // any byte offset (access ends inside the region)
        else           imm = sz * $urandom_range(0, maxoff / sz);
    endtask

    task automatic gen_load();
        int base, imm, k;
        k = $urandom_range(0, 9);
        if (k < 5) begin
            pick_addr(4, base, imm); emit(enc_i(imm, base, 3'b010, rdst(), 7'b0000011));   // LW
        end else if (k < 7) begin
            pick_addr(2, base, imm);
            emit(enc_i(imm, base, ($urandom_range(0,1) ? 3'b001 : 3'b101), rdst(), 7'b0000011)); // LH/LHU
        end else begin
            pick_addr(1, base, imm);
            emit(enc_i(imm, base, ($urandom_range(0,1) ? 3'b000 : 3'b100), rdst(), 7'b0000011)); // LB/LBU
        end
    endtask

    task automatic gen_store();
        int base, imm, k;
        k = $urandom_range(0, 9);
        if (k < 5) begin
            pick_addr(4, base, imm); emit(enc_s(imm, rsrc(), base, 3'b010));    // SW
        end else if (k < 7) begin
            pick_addr(2, base, imm); emit(enc_s(imm, rsrc(), base, 3'b001));    // SH
        end else begin
            pick_addr(1, base, imm); emit(enc_s(imm, rsrc(), base, 3'b000));    // SB
        end
    endtask

    // one non-control-flow instruction
    task automatic gen_simple();
        int k;
        k = $urandom_range(0, 99);
        if      (k < 32) gen_r();
        else if (k < 56) gen_i();
        else if (k < 64) gen_u();
        else if (k < 82) gen_load();
        else             gen_store();
    endtask

    task automatic gen_branch();
        int m, rs1, rs2, k;
        logic [2:0] f3;
        m   = $urandom_range(1, 4);
        rs1 = rsrc();
        rs2 = ($urandom_range(0, 5) == 0) ? rs1 : rsrc();     // same reg -> deterministic outcomes sometimes
        k   = $urandom_range(0, 5);
        case (k)
            0: f3 = 3'b000; 1: f3 = 3'b001; 2: f3 = 3'b100;
            3: f3 = 3'b101; 4: f3 = 3'b110; default: f3 = 3'b111;
        endcase
        pend_tgt = (plen + m > pend_tgt) ? plen + m : pend_tgt;
        emit(enc_b(4*m, rs2, rs1, f3));
    endtask

    task automatic gen_jal();
        int m;
        m = $urandom_range(1, 4);
        pend_tgt = (plen + m > pend_tgt) ? plen + m : pend_tgt;
        emit(enc_j(4*m, rdst()));
    endtask

    task automatic gen_jalr_pair();
        int m, imm, tgt;
        while (plen < pend_tgt) emit(NOP_I);                   // no pending target may land between ADDI and JALR
        m   = $urandom_range(1, 3);
        imm = 2 * $urandom_range(0, 3);
        tgt = 4 * (plen + 1 + m);                              // JALR will sit at index plen+1
        pend_tgt = (plen + 1 + m > pend_tgt) ? plen + 1 + m : pend_tgt;
        emit(ADDI(10, 0, tgt - imm));                          // scratch -> JALR base (distance 1)
        emit(enc_i(imm, 10, 3'b000, rdst(), 7'b1100111));
    endtask

    task automatic gen_loop();
        int cnt, k;
        cnt = $urandom_range(2, 4);
        k   = $urandom_range(2, 5);
        // no pending forward target may land inside the loop (it would skip the counter init)
        while (plen < pend_tgt) emit(NOP_I);
        emit(ADDI(8, 0, cnt));
        for (int i = 0; i < k; i++) gen_simple();
        emit(ADDI(8, 8, -1));                                  // counter -> BNE operand (distance 1)
        emit(enc_b(-4 * (k + 1), 0, 8, 3'b001));               // BNE x8,x0,loop_start
    endtask

    task automatic gen_program(input int body_len, output int body_start);
        int r, lim;
        // prologue: clear regs, set x9/x15 = BASE, clear data region, drain
        for (int i = 1; i < 32; i++) emit(ADDI(i, 0, (i == 9 || i == 15) ? BASE : 0));
        for (int w = 0; w < 16; w++) emit(SW(0, 0, BASE + 4*w));
        for (int i = 0; i < 4; i++) emit(NOP_I);
        body_start = plen;
        pend_tgt   = 0;
        lim = body_start + body_len;

        case ($urandom_range(0, 3))                      // hazard-density profile
            0: pool_n = 2;  1: pool_n = 3;  2: pool_n = 5;  default: pool_n = 7;
        endcase

        while (plen < lim) begin
            r = $urandom_range(0, 99);
            if      (r < 58) gen_simple();
            else if (r < 72) gen_branch();
            else if (r < 78) gen_jal();
            else if (r < 84) gen_jalr_pair();
            else if (r < 90) gen_loop();
            else if (r < 95) emit(ADDI(9, 15, 4 * $urandom_range(0, 3)));          // pointer update
            else             emit(NOP_I);
        end
    endtask

    // ======================================================================
    // Monitors
    // ======================================================================
    int stall_cnt = 0, flush_cnt = 0;

    always @(posedge clk) if (rst_n) begin
        if (dut.hazard_stall === 1'b1) stall_cnt++;
        if (dut.if_id_flush  === 1'b1) flush_cnt++;
    end

    always @(posedge clk)
        if (rst_n && dut.hazard_stall === 1'b1 && dut.if_id_flush === 1'b1) begin
            mon_errors++; errors++;
            $error("[prog %0d] stall and flush asserted together @%0t", cur_idx, $time);
        end

    logic        prev_stall = 1'b0;
    logic [31:0] prev_pc, prev_pc_id, prev_instr_id;
    always @(posedge clk) begin
        if (rst_n && prev_stall) begin
            if (dut.pc_out !== prev_pc) begin
                mon_errors++; errors++;
                $error("[prog %0d] PC moved during stall @%0t", cur_idx, $time);
            end
            if (dut.pc_id !== prev_pc_id || dut.instr_id !== prev_instr_id) begin
                mon_errors++; errors++;
                $error("[prog %0d] IF/ID changed during stall @%0t", cur_idx, $time);
            end
        end
        prev_stall    <= rst_n && (dut.hazard_stall === 1'b1);
        prev_pc       <= dut.pc_out;
        prev_pc_id    <= dut.pc_id;
        prev_instr_id <= dut.instr_id;
    end

    always @(posedge clk)
        if (rst_n && dut.u_rf.regs[0] !== 32'h0) begin
            mon_errors++; errors++;
            $error("[prog %0d] x0 non-zero @%0t", cur_idx, $time);
        end

    // ======================================================================
    // DUT run + compare
    // ======================================================================
    function automatic logic [31:0] dmem_word(input int w);
        return {dut.u_dmem.g_bank[3].mem[w], dut.u_dmem.g_bank[2].mem[w],
                dut.u_dmem.g_bank[1].mem[w], dut.u_dmem.g_bank[0].mem[w]};
    endfunction

    task automatic run_dut(input int end_idx, input int max_cycles, output bit timed_out);
        int cyc;
        rst_n = 1'b0;
        for (int i = 0; i < 1024; i++) dut.u_imem.mem[i] = NOP_I;
        for (int i = 0; i < plen;  i++) dut.u_imem.mem[i] = prog[i];
        // sentinel: extra NOPs already there (memory pre-filled)
        repeat (3) @(negedge clk);
        stall_cnt = 0; flush_cnt = 0;
        rst_n = 1'b1;
        cyc = 0;
        while (dut.pc_out < (4*end_idx + 16) && cyc < max_cycles) begin
            @(negedge clk); cyc++;
        end
        timed_out = (cyc >= max_cycles);
        repeat (12) @(negedge clk);                                   // drain
    endtask

    task automatic dump_failure(input int idx);
        int fd;
        if (dumped < 5) begin
            fd = $fopen($sformatf("fail_prog_%0d.hex", idx), "w");
            for (int i = 0; i < plen + 8; i++) $fwrite(fd, "%08h\n", (i < plen) ? prog[i] : NOP_I);
            $fclose(fd);
            dumped++;
            $display("      program written to fail_prog_%0d.hex", idx);
        end
    endtask

    task automatic run_one(input int idx);
        int body_start, dyn, taken, jumps, stalls, loads, stores;
        int err0;
        bit timed_out;
        logic [31:0] exp_w, got_w;

        cur_idx = idx;
        err0 = errors;
        plen = 0;
        gen_program(BODY_LEN, body_start);

        iss_run(body_start, plen, dyn, taken, jumps, stalls, loads, stores);
        if (idx == 0) $display("  INFO: prog 0: body_start=%0d, static=%0d, ISS dynamic=%0d", body_start, plen, dyn);
        checks++;
        if (dyn == 0) begin
            errors++;
            $error("[prog %0d] ISS executed 0 instructions (generator/ISS problem, not a DUT result)", idx);
        end
        run_dut(plen, 12 * dyn + 400, timed_out);

        checks++;
        if (timed_out) begin
            errors++;
            $error("[prog %0d] DUT did not reach end of program (pc_out=0x%08h, end=0x%08h)",
                   idx, dut.pc_out, 4*plen);
        end

        for (int r = 1; r < 32; r++) begin
            checks++;
            if (dut.u_rf.regs[r] !== iss_r[r]) begin
                errors++;
                $error("[prog %0d] x%0d = 0x%08h, ISS 0x%08h", idx, r, dut.u_rf.regs[r], iss_r[r]);
            end
        end
        for (int w = 0; w < 16; w++) begin
            checks++;
            got_w = dmem_word(BASE/4 + w);
            exp_w = iss_ld(BASE + 4*w, 4);
            if (got_w !== exp_w) begin
                errors++;
                $error("[prog %0d] dmem[0x%02h] = 0x%08h, ISS 0x%08h", idx, BASE + 4*w, got_w, exp_w);
            end
        end
        if (CHK_COUNTS) begin
            checks++;
            if (stall_cnt != stalls) begin
                errors++;
                $error("[prog %0d] load-use stall cycles = %0d, ISS expects %0d", idx, stall_cnt, stalls);
            end
            checks++;
            if (flush_cnt != taken + jumps) begin
                errors++;
                $error("[prog %0d] flush cycles = %0d, ISS expects %0d (taken %0d + jumps %0d)",
                       idx, flush_cnt, taken + jumps, taken, jumps);
            end
        end

        tot_dyn += dyn; tot_taken += taken; tot_jumps += jumps; tot_stalls += stalls;
        tot_loads += loads; tot_stores += stores;

        if (errors != err0) begin
            progs_failed++;
            $display("[FAIL] program %0d (pool=%0d, %0d static / %0d dynamic instrs)", idx, pool_n, plen, dyn);
            dump_failure(idx);
        end
    endtask

    // ======================================================================
    // Main
    // ======================================================================
    initial begin : watchdog
        #2_000_000_000;
        $fatal(1, "Watchdog timeout");
    end

    initial begin : main
        #1;
        if ($value$plusargs("NUM=%d",  NUM_PROGRAMS)) ;
        if ($value$plusargs("LEN=%d",  BODY_LEN))     ;
        if ($value$plusargs("SEED=%d", SEED))         ;
        if ($test$plusargs("STOP_ON_FAIL")) STOP_ON_FAIL = 1'b1;
        if ($test$plusargs("NOSTALLCHK"))   CHK_COUNTS   = 1'b0;
        if ($test$plusargs("UNALIGNED"))    UNALIGNED    = 1'b1;
        // xsim has no seeded $urandom(): vary the stream by skipping ahead instead
        for (int i = 0; i < SEED * 1009; i++) skip_val = $urandom();

        $display("=========== RV32I random regression ===========");
        $display("  programs=%0d  body=%0d instrs  seed=%0d  count-checks=%0d  unaligned=%0d",
                 NUM_PROGRAMS, BODY_LEN, SEED, CHK_COUNTS, UNALIGNED);

        for (int i = 0; i < NUM_PROGRAMS; i++) begin
            run_one(i);
            if (STOP_ON_FAIL && progs_failed != 0) break;
            if ((i + 1) % 50 == 0)
                $display("  ... %0d/%0d programs, %0d failed", i + 1, NUM_PROGRAMS, progs_failed);
        end

        $display("----------------------------------------------");
        $display("  dynamic instrs     : %0d", tot_dyn);
        $display("  loads / stores     : %0d / %0d", tot_loads, tot_stores);
        $display("  branches taken     : %0d   jumps: %0d", tot_taken, tot_jumps);
        $display("  load-use stalls    : %0d", tot_stalls);
        $display("  programs failed    : %0d   monitor errors: %0d   checks: %0d",
                 progs_failed, mon_errors, checks);
        if (errors == 0) $display("  *** REGRESSION PASSED ***");
        else             $display("  *** REGRESSION FAILED: %0d error(s) ***", errors);
        $display("==============================================");
        $finish;
    end

endmodule
