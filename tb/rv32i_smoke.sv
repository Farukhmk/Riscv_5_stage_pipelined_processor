`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 17.10.2026 07:51:49
// Design Name: 
// Module Name: rv32i_smoke
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

module rv32i_smoke;

    logic clk = 0;
    logic rst_n = 0;
    logic [15:0] led_out;

    integer errors = 0;
    integer cycle_count = 0;

    // =========================================================
    // DUT
    // =========================================================

    rv32i_core_pipelined_full dut (
        .clk     (clk),
        .rst_n   (rst_n),
        .led_out (led_out)
    );

    // =========================================================
    // CLOCK
    // 10 ns period
    // =========================================================

    always #5 clk = ~clk;

    // =========================================================
    // CLOCK CYCLE COUNTER
    // =========================================================

    always @(negedge clk) begin
        if (rst_n)
            cycle_count = cycle_count + 1;
    end

    // =========================================================
    // TEST
    // =========================================================

    initial begin

        errors = 0;

        $display("==============================================");
        $display("     COMPREHENSIVE RV32I SMOKE TEST");
        $display("==============================================");

        // -----------------------------------------------------
        // RESET
        // -----------------------------------------------------

        repeat (2) @(negedge clk);
        rst_n = 1'b1;

        // -----------------------------------------------------
        // ALLOW PROCESSOR TO EXECUTE PROGRAM
        // -----------------------------------------------------

        repeat (40) @(negedge clk);
        #1;

        // =====================================================
        // REGISTER RESULTS
        // =====================================================

        $display("");
        $display("---------- REGISTER RESULTS ----------");

        $display("x0  = %0d", dut.u_rf.regs[0]);
        $display("x1  = %0d", dut.u_rf.regs[1]);
        $display("x2  = %0d", dut.u_rf.regs[2]);
        $display("x3  = %0d", dut.u_rf.regs[3]);
        $display("x4  = %0d", dut.u_rf.regs[4]);
        $display("x5  = %0d", dut.u_rf.regs[5]);
        $display("x6  = %0d", dut.u_rf.regs[6]);
        $display("x7  = %0d", dut.u_rf.regs[7]);
        $display("x8  = %0d", dut.u_rf.regs[8]);
        $display("x9  = %0d", dut.u_rf.regs[9]);
        $display("x10 = %0d", dut.u_rf.regs[10]);
        $display("x11 = %0d", dut.u_rf.regs[11]);
        $display("x12 = %0d", dut.u_rf.regs[12]);
        $display("x13 = %0d", dut.u_rf.regs[13]);
        $display("x14 = %0d", dut.u_rf.regs[14]);
        $display("x15 = %0d", dut.u_rf.regs[15]);
        $display("x16 = %0d", dut.u_rf.regs[16]);
        $display("x17 = %0d", dut.u_rf.regs[17]);
        $display("x18 = %0d", dut.u_rf.regs[18]);
        $display("x19 = %0d", dut.u_rf.regs[19]);
        $display("x20 = %0d", dut.u_rf.regs[20]);
        $display("x21 = %0d", dut.u_rf.regs[21]);
        $display("x22 = %0d", dut.u_rf.regs[22]);

        $display("Clock cycles = %0d", cycle_count);

        // =====================================================
        // CHECK RESULTS
        // =====================================================

        if (dut.u_rf.regs[0] !== 32'd0) begin
            $error("FAIL: x0 expected 0");
            errors = errors + 1;
        end

        if (dut.u_rf.regs[1] !== 32'd10) begin
            $error("FAIL: x1 expected 10");
            errors = errors + 1;
        end

        if (dut.u_rf.regs[2] !== 32'd20) begin
            $error("FAIL: x2 expected 20");
            errors = errors + 1;
        end

        if (dut.u_rf.regs[3] !== 32'd30) begin
            $error("FAIL: x3 expected 30");
            errors = errors + 1;
        end

        if (dut.u_rf.regs[4] !== 32'd20) begin
            $error("FAIL: x4 expected 20");
            errors = errors + 1;
        end

        if (dut.u_rf.regs[5] !== 32'd0) begin
            $error("FAIL: x5 expected 0");
            errors = errors + 1;
        end

        if (dut.u_rf.regs[6] !== 32'd30) begin
            $error("FAIL: x6 expected 30");
            errors = errors + 1;
        end

        if (dut.u_rf.regs[7] !== 32'd30) begin
            $error("FAIL: x7 expected 30");
            errors = errors + 1;
        end

        if (dut.u_rf.regs[8] !== 32'd40) begin
            $error("FAIL: x8 expected 40");
            errors = errors + 1;
        end

        if (dut.u_rf.regs[9] !== 32'd2) begin
            $error("FAIL: x9 expected 2");
            errors = errors + 1;
        end

        if (dut.u_rf.regs[10] !== 32'd10) begin
            $error("FAIL: x10 expected 10");
            errors = errors + 1;
        end

        if (dut.u_rf.regs[11] !== 32'hFFFFFFFC) begin
            $error("FAIL: x11 expected 0xFFFFFFFC (-4)");
            errors = errors + 1;
        end

        if (dut.u_rf.regs[12] !== 32'hFFFFFFF0) begin
            $error("FAIL: x12 expected 0xFFFFFFF0 (-16)");
            errors = errors + 1;
        end

        if (dut.u_rf.regs[13] !== 32'hFFFFFFFC) begin
            $error("FAIL: x13 expected 0xFFFFFFFC (-4)");
            errors = errors + 1;
        end

        if (dut.u_rf.regs[14] !== 32'd1) begin
            $error("FAIL: x14 expected 1");
            errors = errors + 1;
        end

        if (dut.u_rf.regs[15] !== 32'd1) begin
            $error("FAIL: x15 expected 1");
            errors = errors + 1;
        end

        if (dut.u_rf.regs[16] !== 32'd99) begin
            $error("FAIL: x16 expected 99");
            errors = errors + 1;
        end

        if (dut.u_rf.regs[17] !== 32'd0) begin
            $error("FAIL: x17 expected 0");
            errors = errors + 1;
        end

        if (dut.u_rf.regs[18] !== 32'd256) begin
            $error("FAIL: x18 expected 256");
            errors = errors + 1;
        end

        if (dut.u_rf.regs[19] !== 32'd30) begin
            $error("FAIL: x19 expected 30");
            errors = errors + 1;
        end

        if (dut.u_rf.regs[20] !== 32'd50) begin
            $error("FAIL: x20 expected 50");
            errors = errors + 1;
        end

        if (dut.u_rf.regs[21] !== 32'd96) begin
            $error("FAIL: x21 expected 96");
            errors = errors + 1;
        end

        if (dut.u_rf.regs[22] !== 32'd5) begin
            $error("FAIL: x22 expected 5");
            errors = errors + 1;
        end

        // =====================================================
        // FINAL RESULT
        // =====================================================

        $display("");

        if (errors == 0) begin

            $display("==============================================");
            $display("COMPREHENSIVE RV32I SMOKE TEST: PASS");
            $display("==============================================");

        end
        else begin

            $display("==============================================");
            $display("COMPREHENSIVE RV32I SMOKE TEST: FAIL (%0d errors)",
                     errors);
            $display("==============================================");

        end

        $finish;

    end

endmodule
