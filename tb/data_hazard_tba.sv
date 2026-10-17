`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 15.10.2026 08:37:22
// Design Name: 
// Module Name: data_hazard_tba
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
// data_hazard_tb  -  self-checking data-hazard testbench for rv32i_core_pipelined_full
//
// How it works
//   * Every test builds a small program with the encoder functions below, writes
//     it straight into the instruction BRAM array (dut.u_imem.mem), resets the
//     core, lets it run, then checks the register file / data memory / LEDs
//     against hand-computed expected values.
//   * Every program starts with a "prologue" that is itself executed by the core:
//     it zeroes x1..x31 and data-memory words 0..15. So tests never depend on
//     leftovers from the previous test and no hierarchical writes into the
//     register file or data memory are needed.
//     x31 is reserved as a scratch register for loading preset memory values.
//   * Each expected result differs from the "stale" (unforwarded) value, so a
//     missing/incorrect forward shows up as a wrong result.
//
// Hazard classes covered
//   RAW through EX/MEM forward  (distance 1)        rs1 / rs2 / both
//   RAW through MEM/WB forward  (distance 2)        rs1 / rs2
//   RAW through reg-file write-through (distance 3)
//   No-hazard control (distance 4)
//   Forward priority (MEM beats WB), x0 never forwarded, same reg on both ports
//   Load-use stall (rs1, rs2, store data, store base, branch operand, load->load)
//   Load result forwarded from WB without a stall (distance 2) and write-through (3)
//   WAW ordering (load followed by ALU write to same rd)
//   Forwarding into store data, store address, branch compare, JALR base
//   Wrong-path producer must not forward after a taken branch
//   GPIO store with forwarded address and data
//   Constrained-random straight-line programs checked against a software model
//
// Plus always-on monitors: stall/flush mutual exclusion, PC/IF-ID freeze during a
// stall, x0 stays zero, and a forwarding-path coverage summary.
//
// Notes
//   * program.hex is not needed (the TB overwrites the instruction memory), but
//     $readmemh in instr_mem_bram will print a warning if the file is missing.
//   * Run with:  xsim / Vivado "Run Behavioral Simulation", top = data_hazard_tb.
//     Optional plusarg: +SEED=<n> to change the random-test seed.
// =============================================================================
module data_hazard_tba;

    // ------------------------------------------------------------------ config
    localparam logic [31:0] NOP_I      = 32'h0000_0013;
    localparam int          NUM_RANDOM = 100;   // random programs
    localparam int          RAND_LEN   = 40;    // instructions per random program
    localparam bit          VERBOSE    = 1'b0;  // 1 = print every individual check

    // --------------------------------------------------------------------- DUT
    logic        clk   = 1'b0;
    logic        rst_n = 1'b0;
    logic [15:0] led_out;

    rv32i_core_pipelined_full dut (.clk(clk), .rst_n(rst_n), .led_out(led_out));

    always #5 clk = ~clk;

    // ------------------------------------------------------- bookkeeping state
    int    errors      = 0;
    int    checks      = 0;
    int    tests_run   = 0;
    int    tests_failed= 0;
    int    test_err0   = 0;
    string cur_name    = "";

    // ------------------------------------------------------- program buffer
    logic [31:0] prog [0:511];
    int          plen = 0;

    // ======================================================================
    // Instruction encoders
    // ======================================================================
    function automatic logic [31:0] enc_r(input logic [6:0] f7, input int rs2, input int rs1,
                                          input logic [2:0] f3, input int rd);
        return {f7, rs2[4:0], rs1[4:0], f3, rd[4:0], 7'b0110011};
    endfunction

    function automatic logic [31:0] enc_i(input int imm, input int rs1, input logic [2:0] f3,
                                          input int rd, input logic [6:0] op);
        return {imm[11:0], rs1[4:0], f3, rd[4:0], op};
    endfunction

    function automatic logic [31:0] enc_s(input int imm, input int rs2, input int rs1,
                                          input logic [2:0] f3);
        logic [11:0] i12;
        i12 = imm[11:0];
        return {i12[11:5], rs2[4:0], rs1[4:0], f3, i12[4:0], 7'b0100011};
    endfunction

    function automatic logic [31:0] enc_b(input int off, input int rs2, input int rs1,
                                          input logic [2:0] f3);
        logic [12:0] o;
        o = off[12:0];
        return {o[12], o[10:5], rs2[4:0], rs1[4:0], f3, o[4:1], o[11], 7'b1100011};
    endfunction

    function automatic logic [31:0] enc_j(input int off, input int rd);
        logic [20:0] o;
        o = off[20:0];
        return {o[20], o[10:1], o[11], o[19:12], rd[4:0], 7'b1101111};
    endfunction

    function automatic logic [31:0] ADD  (input int rd, input int rs1, input int rs2);
        return enc_r(7'b0000000, rs2, rs1, 3'b000, rd);
    endfunction
    function automatic logic [31:0] SUB  (input int rd, input int rs1, input int rs2);
        return enc_r(7'b0100000, rs2, rs1, 3'b000, rd);
    endfunction
    function automatic logic [31:0] ADDI (input int rd, input int rs1, input int imm);
        return enc_i(imm, rs1, 3'b000, rd, 7'b0010011);
    endfunction
    function automatic logic [31:0] LW   (input int rd, input int rs1, input int imm);
        return enc_i(imm, rs1, 3'b010, rd, 7'b0000011);
    endfunction
    function automatic logic [31:0] SW   (input int rs2, input int rs1, input int imm);
        return enc_s(imm, rs2, rs1, 3'b010);
    endfunction
    function automatic logic [31:0] BEQ  (input int rs1, input int rs2, input int off);
        return enc_b(off, rs2, rs1, 3'b000);
    endfunction
    function automatic logic [31:0] JAL  (input int rd, input int off);
        return enc_j(off, rd);
    endfunction
    function automatic logic [31:0] JALR (input int rd, input int rs1, input int imm);
        return enc_i(imm, rs1, 3'b000, rd, 7'b1100111);
    endfunction
    function automatic logic [31:0] LUI  (input int rd, input logic [19:0] imm20);
        return {imm20, rd[4:0], 7'b0110111};
    endfunction

    // ======================================================================
    // Program-building helpers
    // ======================================================================
    task automatic emit(input logic [31:0] instr);
        prog[plen] = instr;
        plen++;
    endtask

    task automatic emit_nops(input int n);
        for (int i = 0; i < n; i++) emit(NOP_I);
    endtask

    // load a 32-bit constant into rd (LUI+ADDI when needed)
    task automatic emit_li(input int rd, input logic [31:0] val);
        logic signed [11:0] lo;
        int                 lo_i;
        logic [31:0]        hi;
        lo = val[11:0];
        lo_i = lo;
        hi = (val - {{20{lo[11]}}, lo}) >> 12;
        if (hi[19:0] != 20'd0) begin
            emit(LUI(rd, hi[19:0]));
            emit(ADDI(rd, rd, lo_i));
        end else begin
            emit(ADDI(rd, 0, lo_i));
        end
    endtask

    // preset data-memory word 'w' (through the pipeline, using scratch x31)
    task automatic poke(input int w, input logic [31:0] val);
        emit_li(31, val);
        emit(SW(31, 0, 4*w));
    endtask

    // call after the last poke(): clears the scratch reg and drains the pipe
    task automatic end_setup();
        emit(ADDI(31, 0, 0));
        emit_nops(4);
    endtask

    // ======================================================================
    // Test control
    // ======================================================================
    int stall_cnt = 0;

    task automatic begin_test(input string name);
        cur_name  = name;
        test_err0 = errors;
        plen      = 0;
        stall_cnt = 0;
        // prologue: zero x1..x31 and data-memory words 0..15
        for (int r = 1; r < 32; r++) emit(ADDI(r, 0, 0));
        for (int w = 0; w < 16; w++) emit(SW(0, 0, 4*w));
        emit_nops(4);
    endtask

    task automatic run_test();
        rst_n = 1'b0;
        for (int i = 0; i < 1024; i++) dut.u_imem.mem[i] = NOP_I;
        for (int i = 0; i < plen;  i++) dut.u_imem.mem[i] = prog[i];
        repeat (3) @(negedge clk);
        rst_n = 1'b1;
        repeat (plen + 40) @(negedge clk);   // program + generous drain for stalls/flushes
    endtask

    task automatic end_test(input bit quiet = 1'b0);
        tests_run++;
        if (errors != test_err0) begin
            tests_failed++;
            $display("[FAIL] %s", cur_name);
        end else if (!quiet) begin
            $display("[PASS] %s", cur_name);
        end
    endtask

    // ---------------------------------------------------------------- checkers
    task automatic chk_reg(input int r, input logic [31:0] exp, input string msg = "");
        logic [31:0] got;
        got = dut.u_rf.regs[r];
        checks++;
        if (got !== exp) begin
            errors++;
            $error("[%s] x%0d = 0x%08h, expected 0x%08h  %s", cur_name, r, got, exp, msg);
        end else if (VERBOSE) begin
            $display("   ok  [%s] x%0d = 0x%08h %s", cur_name, r, got, msg);
        end
    endtask

    function automatic logic [31:0] dmem_word(input int w);
        return {dut.u_dmem.g_bank[3].mem[w], dut.u_dmem.g_bank[2].mem[w],
                dut.u_dmem.g_bank[1].mem[w], dut.u_dmem.g_bank[0].mem[w]};
    endfunction

    task automatic chk_mem(input int w, input logic [31:0] exp, input string msg = "");
        logic [31:0] got;
        got = dmem_word(w);
        checks++;
        if (got !== exp) begin
            errors++;
            $error("[%s] dmem word %0d = 0x%08h, expected 0x%08h  %s", cur_name, w, got, exp, msg);
        end else if (VERBOSE) begin
            $display("   ok  [%s] dmem[%0d] = 0x%08h %s", cur_name, w, got, msg);
        end
    endtask

    task automatic chk_stalls(input int exp, input string msg = "");
        checks++;
        if (stall_cnt != exp) begin
            errors++;
            $error("[%s] load-use stall cycles = %0d, expected %0d  %s", cur_name, stall_cnt, exp, msg);
        end else if (VERBOSE) begin
            $display("   ok  [%s] stall cycles = %0d %s", cur_name, stall_cnt, msg);
        end
    endtask

    // ======================================================================
    // Always-on monitors
    // ======================================================================
    // stall counter (only meaningful for the current test)
    always @(posedge clk)
        if (rst_n && dut.hazard_stall === 1'b1) stall_cnt++;

    // invariant from the core: a stall (load in EX) and a flush (branch/jump in EX) never coincide
    always @(posedge clk)
        if (rst_n && dut.hazard_stall === 1'b1 && dut.if_id_flush === 1'b1) begin
            errors++;
            $error("[%s] hazard_stall and if_id_flush asserted together @%0t", cur_name, $time);
        end

    // while stalled, PC and the IF/ID stage contents must hold for the next cycle
    logic        prev_stall = 1'b0;
    logic [31:0] prev_pc, prev_pc_id, prev_instr_id;
    always @(posedge clk) begin
        if (rst_n && prev_stall) begin
            if (dut.pc_out !== prev_pc) begin
                errors++;
                $error("[%s] PC changed during load-use stall @%0t (0x%08h -> 0x%08h)",
                       cur_name, $time, prev_pc, dut.pc_out);
            end
            if (dut.pc_id !== prev_pc_id || dut.instr_id !== prev_instr_id) begin
                errors++;
                $error("[%s] IF/ID changed during load-use stall @%0t", cur_name, $time);
            end
        end
        prev_stall    <= rst_n && (dut.hazard_stall === 1'b1);
        prev_pc       <= dut.pc_out;
        prev_pc_id    <= dut.pc_id;
        prev_instr_id <= dut.instr_id;
    end

    // x0 must always read zero
    always @(posedge clk)
        if (rst_n && dut.u_rf.regs[0] !== 32'h0) begin
            errors++;
            $error("[%s] x0 is non-zero (0x%08h) @%0t", cur_name, dut.u_rf.regs[0], $time);
        end

    // forwarding-path coverage
    int cov_fa_mem = 0, cov_fa_wb = 0, cov_fb_mem = 0, cov_fb_wb = 0;
    int cov_wb_load_fwd = 0, cov_wthru = 0, cov_stall = 0, cov_flush = 0;
    always @(posedge clk) if (rst_n) begin
        if (dut.forward_a === 2'b01) cov_fa_mem++;
        if (dut.forward_a === 2'b10) cov_fa_wb++;
        if (dut.forward_b === 2'b01) cov_fb_mem++;
        if (dut.forward_b === 2'b10) cov_fb_wb++;
        if ((dut.forward_a === 2'b10 || dut.forward_b === 2'b10) && dut.result_src_wb === 2'b01)
            cov_wb_load_fwd++;
        if (dut.reg_we_wb === 1'b1 && dut.rd_wb != 5'd0 &&
            (dut.rd_wb == dut.rs1_id || dut.rd_wb == dut.rs2_id))
            cov_wthru++;
        if (dut.hazard_stall === 1'b1) cov_stall++;
        if (dut.if_id_flush  === 1'b1) cov_flush++;
    end

    // ======================================================================
    // Directed tests - ALU -> ALU forwarding
    // ======================================================================
    task automatic t_fwd_mem_rs1();                       // distance 1, rs1
        begin_test("EX/MEM forward, distance 1, rs1");
        emit(ADDI(1, 0, 5));
        emit(ADDI(2, 1, 3));
        run_test();
        chk_reg(1, 5); chk_reg(2, 8); chk_stalls(0);
        end_test();
    endtask

    task automatic t_fwd_mem_rs2();                       // distance 1, rs2
        begin_test("EX/MEM forward, distance 1, rs2");
        emit(ADDI(1, 0, 7));
        emit(ADD (3, 0, 1));
        run_test();
        chk_reg(1, 7); chk_reg(3, 7); chk_stalls(0);
        end_test();
    endtask

    task automatic t_fwd_wb_rs1();                        // distance 2, rs1
        begin_test("MEM/WB forward, distance 2, rs1");
        emit(ADDI(1, 0, 10));
        emit(NOP_I);
        emit(ADDI(2, 1, 1));
        run_test();
        chk_reg(2, 11); chk_stalls(0);
        end_test();
    endtask

    task automatic t_fwd_wb_rs2();                        // distance 2, rs2
        begin_test("MEM/WB forward, distance 2, rs2");
        emit(ADDI(3, 0, 20));
        emit(NOP_I);
        emit(ADD (4, 0, 3));
        run_test();
        chk_reg(4, 20); chk_stalls(0);
        end_test();
    endtask

    task automatic t_writethrough();                      // distance 3: only the reg-file bypass covers it
        begin_test("Reg-file write-through, distance 3");
        emit(ADDI(5, 0, 30));
        emit(NOP_I);
        emit(NOP_I);
        emit(ADDI(6, 5, 1));
        emit(ADD (7, 0, 5));                              // distance 4, rs2: plain read
        run_test();
        chk_reg(6, 31); chk_reg(7, 30); chk_stalls(0);
        end_test();
    endtask

    task automatic t_no_hazard_dist4();
        begin_test("No hazard, distance 4 (control)");
        emit(ADDI(7, 0, 40));
        emit_nops(3);
        emit(ADDI(8, 7, 1));
        run_test();
        chk_reg(8, 41); chk_stalls(0);
        end_test();
    endtask

    task automatic t_two_sources_a();                     // rs1 from WB, rs2 from MEM
        begin_test("Two producers: rs1<-WB, rs2<-MEM");
        emit(ADDI(1, 0, 4));
        emit(ADDI(2, 0, 6));
        emit(ADD (3, 1, 2));
        run_test();
        chk_reg(3, 10);
        end_test();
    endtask

    task automatic t_two_sources_b();                     // rs1 from MEM, rs2 from WB
        begin_test("Two producers: rs1<-MEM, rs2<-WB");
        emit(ADDI(1, 0, 4));
        emit(ADDI(2, 0, 6));
        emit(SUB (3, 2, 1));
        run_test();
        chk_reg(3, 2);
        end_test();
    endtask

    task automatic t_priority();                          // MEM must win over WB for the same rd
        begin_test("Forward priority: MEM beats WB (same rd)");
        emit(ADDI(1, 0, 1));
        emit(ADDI(1, 0, 2));
        emit(ADD (2, 1, 1));                              // must see 2, not 1
        run_test();
        chk_reg(1, 2); chk_reg(2, 4);
        end_test();
    endtask

    task automatic t_chain();
        begin_test("Dependent chain x1->x2->x3->x4");
        emit(ADDI(1, 0, 1));
        emit(ADD (2, 1, 1));
        emit(ADD (3, 2, 2));
        emit(ADD (4, 3, 3));
        run_test();
        chk_reg(1, 1); chk_reg(2, 2); chk_reg(3, 4); chk_reg(4, 8); chk_stalls(0);
        end_test();
    endtask

    task automatic t_accumulate();                        // x1 += ... repeatedly (self-dependency)
        begin_test("Accumulate into same register");
        emit(ADDI(1, 0, 1));
        emit(ADDI(1, 1, 2));
        emit(ADDI(1, 1, 3));
        emit(ADDI(1, 1, 4));
        emit(ADD (1, 1, 1));
        run_test();
        chk_reg(1, 20); chk_stalls(0);
        end_test();
    endtask

    task automatic t_same_reg_both_ports();
        begin_test("Same register on rs1 and rs2");
        emit(ADDI(1, 0, 9));
        emit(ADD (2, 1, 1));
        run_test();
        chk_reg(2, 18);
        end_test();
    endtask

    task automatic t_x0();
        begin_test("x0 is never forwarded");
        emit(ADDI(0, 0, 5));                              // write to x0 is discarded
        emit(ADD (1, 0, 0));                              // must be 0
        emit(ADDI(2, 0, 3));                              // must be 3
        emit(ADDI(3, 0, 7));
        emit(ADD (0, 3, 3));                              // would be 14 if x0 were written
        emit(ADD (4, 0, 3));                              // must be 7
        emit(ADD (5, 3, 0));                              // must be 7
        run_test();
        chk_reg(1, 0); chk_reg(2, 3); chk_reg(4, 7); chk_reg(5, 7); chk_reg(0, 0);
        end_test();
    endtask

    // ======================================================================
    // Directed tests - loads (stall + forward)
    // ======================================================================
    task automatic t_load_use_rs1();
        begin_test("Load-use stall, rs1 and rs2 both match");
        poke(0, 32'h55); end_setup();
        emit(LW (1, 0, 0));
        emit(ADD(2, 1, 1));
        run_test();
        chk_reg(1, 32'h55); chk_reg(2, 32'hAA); chk_stalls(1);
        end_test();
    endtask

    task automatic t_load_use_rs2();
        begin_test("Load-use stall, rs2 only");
        poke(0, 32'h11); end_setup();
        emit(ADDI(3, 0, 5));
        emit(LW  (1, 0, 0));
        emit(ADD (2, 3, 1));
        run_test();
        chk_reg(2, 32'h16); chk_stalls(1);
        end_test();
    endtask

    task automatic t_load_use_rs1_only();
        begin_test("Load-use stall, rs1 only");
        poke(0, 32'h11); end_setup();
        emit(ADDI(3, 0, 5));
        emit(LW  (1, 0, 0));
        emit(SUB (2, 1, 3));
        run_test();
        chk_reg(2, 32'h0C); chk_stalls(1);
        end_test();
    endtask

    task automatic t_load_gap1();                         // distance 2: forward load data from WB, no stall
        begin_test("Load -> 1 gap -> use: WB forward of load data, no stall");
        poke(0, 32'h55); end_setup();
        emit(LW (1, 0, 0));
        emit(NOP_I);
        emit(ADD(2, 1, 1));
        run_test();
        chk_reg(2, 32'hAA); chk_stalls(0);
        end_test();
    endtask

    task automatic t_load_gap2();                         // distance 3: write-through of load data
        begin_test("Load -> 2 gaps -> use: write-through of load data");
        poke(0, 32'h55); end_setup();
        emit(LW (1, 0, 0));
        emit(NOP_I);
        emit(NOP_I);
        emit(ADD(2, 1, 1));
        run_test();
        chk_reg(2, 32'hAA); chk_stalls(0);
        end_test();
    endtask

    task automatic t_load_then_waw();                     // younger ALU write must beat the older load
        begin_test("Load then ALU write to same rd (WAW), then use");
        poke(0, 32'h55); end_setup();
        emit(LW  (1, 0, 0));
        emit(ADDI(1, 0, 3));
        emit(ADD (2, 1, 1));                              // must use 3 (from MEM), not load data
        emit_nops(3);
        emit(ADD (3, 1, 1));                              // x1 must still be 3 after the load retires
        run_test();
        chk_reg(1, 3); chk_reg(2, 6); chk_reg(3, 6); chk_stalls(0);
        end_test();
    endtask

    task automatic t_load_use_chain();                    // stall, then dependent op on the stalled result
        begin_test("Load-use then second dependent op");
        poke(0, 32'h05); end_setup();
        emit(LW (1, 0, 0));
        emit(ADD(2, 1, 1));                               // 10
        emit(ADD(3, 2, 1));                               // 15
        run_test();
        chk_reg(2, 10); chk_reg(3, 15); chk_stalls(1);
        end_test();
    endtask

    task automatic t_load_load_chase();                   // pointer chase: lw -> lw (base) -> use
        begin_test("Pointer chase: load -> load(base) -> use");
        poke(0, 32'd4);
        poke(1, 32'h20); end_setup();
        emit(LW (1, 0, 0));                               // x1 = 4
        emit(LW (2, 1, 0));                               // base = x1 (stall), x2 = mem[4] = 0x20
        emit(ADD(3, 2, 2));                               // stall, 0x40
        run_test();
        chk_reg(1, 4); chk_reg(2, 32'h20); chk_reg(3, 32'h40); chk_stalls(2);
        end_test();
    endtask

    task automatic t_load_to_store_data();                // store data (rs2) depends on load -> stall
        begin_test("Load -> store data (rs2) stall");
        poke(0, 32'hCAFEF00D); end_setup();
        emit(LW(1, 0, 0));
        emit(SW(1, 0, 4));
        run_test();
        chk_mem(1, 32'hCAFEF00D); chk_stalls(1);
        end_test();
    endtask

    task automatic t_load_to_store_base();                // store base (rs1) depends on load -> stall
        begin_test("Load -> store base address (rs1) stall");
        poke(0, 32'd8); end_setup();
        emit(ADDI(2, 0, 32'h77));
        emit(LW  (1, 0, 0));
        emit(SW  (2, 1, 0));                              // mem[x1=8] = 0x77  (word 2)
        run_test();
        chk_mem(2, 32'h77); chk_stalls(1);
        end_test();
    endtask

    // ======================================================================
    // Directed tests - store data / address / memory RAW
    // ======================================================================
    task automatic t_store_data_fwd();
        begin_test("Forward into store data (MEM and WB)");
        emit(ADDI(1, 0, 32'h7B));
        emit(SW  (1, 0, 16));                             // distance 1 -> word 4
        emit(ADDI(2, 0, 32'h7C));
        emit(NOP_I);
        emit(SW  (2, 0, 20));                             // distance 2 -> word 5
        run_test();
        chk_mem(4, 32'h7B); chk_mem(5, 32'h7C); chk_stalls(0);
        end_test();
    endtask

    task automatic t_store_addr_fwd();
        begin_test("Forward into store base address + data");
        emit(ADDI(1, 0, 24));
        emit(ADDI(2, 0, 32'h33));
        emit(SW  (2, 1, 0));                              // base<-WB, data<-MEM  -> word 6
        emit(ADDI(3, 0, 28));
        emit(ADDI(4, 0, 32'h44));
        emit(SW  (3, 3, 0));                              // base and data are the same reg (x3, distance 2 -> WB)
        run_test();
        chk_mem(6, 32'h33);
        chk_mem(7, 32'd28);                               // mem[28] = 28 -> word 7
        end_test();
    endtask

    task automatic t_store_then_load();                   // memory RAW: SW immediately followed by LW
        begin_test("Memory RAW: SW then LW back-to-back, then use");
        emit(ADDI(1, 0, 32'h42));
        emit(SW  (1, 0, 0));
        emit(LW  (2, 0, 0));
        emit(ADD (3, 2, 1));                              // load-use stall
        run_test();
        chk_reg(2, 32'h42); chk_reg(3, 32'h84); chk_stalls(1);
        end_test();
    endtask

    // ======================================================================
    // Directed tests - control hazards interacting with data hazards
    // ======================================================================
    task automatic t_branch_operands_taken();
        begin_test("BEQ taken with forwarded operands");
        emit(ADDI(1, 0, 5));
        emit(ADDI(2, 0, 5));
        emit(BEQ (1, 2, 12));                             // x1<-WB, x2<-MEM ; skip next two
        emit(ADDI(3, 0, 99));                             // wrong path
        emit(ADDI(4, 0, 98));                             // wrong path
        emit(ADDI(5, 0, 1));                              // target
        run_test();
        chk_reg(3, 0); chk_reg(4, 0); chk_reg(5, 1); chk_stalls(0);
        end_test();
    endtask

    task automatic t_branch_operands_nottaken();
        begin_test("BEQ not taken with forwarded operands");
        emit(ADDI(1, 0, 5));
        emit(ADDI(2, 0, 6));
        emit(BEQ (1, 2, 8));
        emit(ADDI(3, 0, 1));                              // must execute
        emit(ADDI(4, 0, 2));
        run_test();
        chk_reg(3, 1); chk_reg(4, 2);
        end_test();
    endtask

    task automatic t_load_to_branch();
        begin_test("Load -> branch operand stall, branch taken");
        poke(0, 32'd5); end_setup();
        emit(ADDI(2, 0, 5));
        emit(LW  (1, 0, 0));
        emit(BEQ (1, 2, 12));                             // stall, then taken
        emit(ADDI(3, 0, 99));
        emit(ADDI(4, 0, 98));
        emit(ADDI(5, 0, 1));
        run_test();
        chk_reg(3, 0); chk_reg(4, 0); chk_reg(5, 1); chk_stalls(1);
        end_test();
    endtask

    task automatic t_wrong_path_producer();               // killed wrong-path write must not forward or commit
        begin_test("Wrong-path producer must not forward/commit");
        emit(ADDI(1, 0, 1));
        emit(ADDI(2, 0, 1));
        emit(BEQ (1, 2, 8));                              // taken, skips next
        emit(ADDI(1, 0, 99));                             // wrong path
        emit(ADD (3, 1, 1));                              // target: must use x1 = 1
        run_test();
        chk_reg(1, 1); chk_reg(3, 2);
        end_test();
    endtask

    task automatic t_jalr_base_fwd();
        int base;
        begin_test("JALR with forwarded base register");
        base = plen;
        emit(ADDI(1, 0, 4*(base+5)));                     // x1 = address of the target
        emit(JALR(2, 1, 0));                              // base<-MEM
        emit(ADDI(3, 0, 99));                             // wrong path
        emit(ADDI(4, 0, 98));
        emit(ADDI(6, 0, 97));
        emit(ADDI(5, 0, 1));                              // target
        run_test();
        chk_reg(2, 4*(base+2));                           // link = pc+4
        chk_reg(3, 0); chk_reg(4, 0); chk_reg(6, 0); chk_reg(5, 1);
        end_test();
    endtask

    task automatic t_link_use();
        int base;
        begin_test("Use link register right after JAL");
        base = plen;
        emit(JAL (1, 8));
        emit(ADDI(3, 0, 99));                             // wrong path
        emit(ADD (2, 1, 1));                              // target: x1 = link = 4*(base+1)
        run_test();
        chk_reg(1, 4*(base+1)); chk_reg(2, 8*(base+1)); chk_reg(3, 0);
        end_test();
    endtask

    // ======================================================================
    // GPIO store with forwarded address/data
    // ======================================================================
    task automatic t_gpio();
        begin_test("SW to GPIO with forwarded address and data");
        emit(ADDI(1, 0, 32'hAB));
        emit(ADDI(2, 0, -16));                            // 0xFFFFFFF0
        emit(SW  (1, 2, 0));                              // data<-WB, addr<-MEM
        run_test();
        checks++;
        if (led_out !== 16'h00AB) begin
            errors++;
            $error("[%s] led_out = 0x%04h, expected 0x00AB", cur_name, led_out);
        end
        end_test();
    endtask

    // ======================================================================
    // Constrained-random straight-line programs vs. software model
    // ======================================================================
    function automatic logic [31:0] alu_model(input int op, input logic [31:0] a, input logic [31:0] b);
        case (op)
            0:       return a + b;
            1:       return a - b;
            2:       return a & b;
            3:       return a | b;
            4:       return a ^ b;
            5:       return ($signed(a) < $signed(b)) ? 32'd1 : 32'd0;
            6:       return (a < b) ? 32'd1 : 32'd0;
            7:       return a << b[4:0];
            8:       return a >> b[4:0];
            default: return $signed(a) >>> b[4:0];
        endcase
    endfunction

    // R-type op index -> {funct7, funct3}
    function automatic logic [9:0] r_enc(input int op);
        case (op)
            0:       return {7'b0000000, 3'b000};   // ADD
            1:       return {7'b0100000, 3'b000};   // SUB
            2:       return {7'b0000000, 3'b111};   // AND
            3:       return {7'b0000000, 3'b110};   // OR
            4:       return {7'b0000000, 3'b100};   // XOR
            5:       return {7'b0000000, 3'b010};   // SLT
            6:       return {7'b0000000, 3'b011};   // SLTU
            7:       return {7'b0000000, 3'b001};   // SLL
            8:       return {7'b0000000, 3'b101};   // SRL
            default: return {7'b0100000, 3'b101};   // SRA
        endcase
    endfunction

    task automatic t_random(input int idx);
        logic [31:0] gr [0:31];
        logic [31:0] gm [0:15];
        int          kind, op, rd, rs1, rs2, w, sh, imm;
        logic [9:0]  rf;
        logic [31:0] bval;
        logic [2:0]  f3;
        logic [11:0] imm12;

        begin_test($sformatf("random program %0d", idx));
        for (int i = 0; i < 32; i++) gr[i] = 32'h0;
        for (int i = 0; i < 16; i++) gm[i] = 32'h0;

        // seed x1..x7 with random values
        for (int r = 1; r <= 7; r++) begin
            imm = $urandom_range(0, 4095) - 2048;
            emit(ADDI(r, 0, imm));
            gr[r] = imm;
        end

        for (int n = 0; n < RAND_LEN; n++) begin
            kind = $urandom_range(0, 99);
            rd   = $urandom_range(0, 7);       // small pool + x0 -> lots of hazards
            rs1  = $urandom_range(0, 7);
            rs2  = $urandom_range(0, 7);
            if (kind < 35) begin                                   // R-type
                op = $urandom_range(0, 9);
                rf = r_enc(op);
                emit(enc_r(rf[9:3], rs2, rs1, rf[2:0], rd));
                if (rd != 0) gr[rd] = alu_model(op, gr[rs1], gr[rs2]);
            end else if (kind < 60) begin                          // I-type ALU
                op  = $urandom_range(0, 8);
                imm = $urandom_range(0, 4095) - 2048;
                sh  = $urandom_range(0, 31);
                case (op)
                    0: begin f3 = 3'b000; imm12 = imm[11:0];            bval = imm; end   // ADDI
                    1: begin f3 = 3'b111; imm12 = imm[11:0];            bval = imm; end   // ANDI
                    2: begin f3 = 3'b110; imm12 = imm[11:0];            bval = imm; end   // ORI
                    3: begin f3 = 3'b100; imm12 = imm[11:0];            bval = imm; end   // XORI
                    4: begin f3 = 3'b010; imm12 = imm[11:0];            bval = imm; end   // SLTI
                    5: begin f3 = 3'b011; imm12 = imm[11:0];            bval = imm; end   // SLTIU
                    6: begin f3 = 3'b001; imm12 = {7'b0000000, sh[4:0]}; bval = sh;  end   // SLLI
                    7: begin f3 = 3'b101; imm12 = {7'b0000000, sh[4:0]}; bval = sh;  end   // SRLI
                    default: begin f3 = 3'b101; imm12 = {7'b0100000, sh[4:0]}; bval = sh; end // SRAI
                endcase
                emit(enc_i(imm12, rs1, f3, rd, 7'b0010011));
                if (rd != 0) begin
                    case (op)
                        0: gr[rd] = alu_model(0, gr[rs1], bval);
                        1: gr[rd] = alu_model(2, gr[rs1], bval);
                        2: gr[rd] = alu_model(3, gr[rs1], bval);
                        3: gr[rd] = alu_model(4, gr[rs1], bval);
                        4: gr[rd] = alu_model(5, gr[rs1], bval);
                        5: gr[rd] = alu_model(6, gr[rs1], bval);
                        6: gr[rd] = alu_model(7, gr[rs1], bval);
                        7: gr[rd] = alu_model(8, gr[rs1], bval);
                        default: gr[rd] = alu_model(9, gr[rs1], bval);
                    endcase
                end
            end else if (kind < 80) begin                          // LW
                w = $urandom_range(0, 15);
                emit(LW(rd, 0, 4*w));
                if (rd != 0) gr[rd] = gm[w];
            end else begin                                         // SW
                w = $urandom_range(0, 15);
                emit(SW(rs2, 0, 4*w));
                gm[w] = gr[rs2];
            end
        end

        run_test();

        for (int r = 1; r < 32; r++) chk_reg(r, gr[r]);
        for (int i = 0; i < 16; i++) chk_mem(i, gm[i]);
        end_test(1'b1);   // quiet on pass; failures still print
    endtask

    // ======================================================================
    // Main
    // ======================================================================
    int seed_arg;
    int skip_val;

    initial begin : watchdog
        #200_000_000;
        $fatal(1, "Watchdog timeout - testbench did not finish");
    end

    initial begin : main
        #1;   // let the memories' initial blocks finish before we touch them
        if ($value$plusargs("SEED=%d", seed_arg)) begin
            // xsim has no seeded $urandom(): vary the stream by skipping ahead instead
            for (int i = 0; i < seed_arg * 1009; i++) skip_val = $urandom();
            $display("INFO: random seed = %0d", seed_arg);
        end

        $display("=========== RV32I data-hazard testbench ===========");

        // ALU -> ALU forwarding
        t_fwd_mem_rs1();
        t_fwd_mem_rs2();
        t_fwd_wb_rs1();
        t_fwd_wb_rs2();
        t_writethrough();
        t_no_hazard_dist4();
        t_two_sources_a();
        t_two_sources_b();
        t_priority();
        t_chain();
        t_accumulate();
        t_same_reg_both_ports();
        t_x0();

        // loads
        t_load_use_rs1();
        t_load_use_rs2();
        t_load_use_rs1_only();
        t_load_gap1();
        t_load_gap2();
        t_load_then_waw();
        t_load_use_chain();
        t_load_load_chase();
        t_load_to_store_data();
        t_load_to_store_base();

        // stores / memory
        t_store_data_fwd();
        t_store_addr_fwd();
        t_store_then_load();

        // control + data interaction
        t_branch_operands_taken();
        t_branch_operands_nottaken();
        t_load_to_branch();
        t_wrong_path_producer();
        t_jalr_base_fwd();
        t_link_use();

        // peripheral
        t_gpio();

        // random regression
        for (int i = 0; i < NUM_RANDOM; i++) t_random(i);
        $display("[INFO] %0d random programs run", NUM_RANDOM);

        // coverage summary
        $display("---------------- forwarding coverage ----------------");
        $display("  forward_a <- EX/MEM : %0d", cov_fa_mem);
        $display("  forward_a <- MEM/WB : %0d", cov_fa_wb);
        $display("  forward_b <- EX/MEM : %0d", cov_fb_mem);
        $display("  forward_b <- MEM/WB : %0d", cov_fb_wb);
        $display("  WB forward of load data : %0d", cov_wb_load_fwd);
        $display("  reg-file write-through hits : %0d", cov_wthru);
        $display("  load-use stall cycles : %0d", cov_stall);
        $display("  branch/jump flush cycles : %0d", cov_flush);
        if (cov_fa_mem == 0 || cov_fa_wb == 0 || cov_fb_mem == 0 || cov_fb_wb == 0 ||
            cov_wb_load_fwd == 0 || cov_wthru == 0 || cov_stall == 0 || cov_flush == 0) begin
            errors++;
            $error("Coverage hole: at least one forwarding/stall path was never exercised");
        end

        $display("=====================================================");
        $display("  tests run: %0d   tests failed: %0d   checks: %0d   errors: %0d",
                 tests_run, tests_failed, checks, errors);
        if (errors == 0) $display("  *** ALL DATA-HAZARD TESTS PASSED ***");
        else             $display("  *** %0d ERROR(S) - SEE LOG ***", errors);
        $display("=====================================================");
        $finish;
    end

endmodule
