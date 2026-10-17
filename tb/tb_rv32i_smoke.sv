`timescale 1ns / 1ps

module tb_rv32i_smoke;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic [15:0] led_out;

    integer errors = 0;
    integer cycle_count = 0;

    rv32i_core_pipelined_full dut (
        .clk     (clk),
        .rst_n   (rst_n),
        .led_out (led_out)
    );

    always #5 clk = ~clk;

    always @(negedge clk) begin
        if (rst_n)
            cycle_count = cycle_count + 1;
    end

    task automatic check_reg(
        input integer reg_num,
        input logic [31:0] expected,
        input string name
    );
        logic [31:0] actual;
        begin
            // Current DUT register-file instance is u_rf.
            actual = dut.u_rf.regs[reg_num];

            if (actual !== expected) begin
                $display("FAIL %-4s Expected = %08h (%0d), Got = %08h (%0d)",
                         name, expected, $signed(expected),
                         actual, $signed(actual));
                errors = errors + 1;
            end
            else begin
                $display("PASS %-4s = %08h (%0d)",
                         name, actual, $signed(actual));
            end
        end
    endtask

    initial begin
        errors = 0;
        cycle_count = 0;

        $display("");
        $display("==============================================");
        $display("       COMPREHENSIVE RV32I SMOKE TEST");
        $display("==============================================");

        // Hold reset for two clock cycles.
        repeat (2) @(negedge clk);
        rst_n = 1'b1;

        $display("RESET RELEASED");

        // Allow the pipeline to execute and drain.
        repeat (80) @(negedge clk);
        #1;

        $display("");
        $display("---------- REGISTER RESULTS ----------");

        check_reg(0,  32'd0,          "x0");
        check_reg(1,  32'd10,         "x1");
        check_reg(2,  32'd20,         "x2");
        check_reg(3,  32'd30,         "x3");
        check_reg(4,  32'd20,         "x4");
        check_reg(5,  32'd0,          "x5");
        check_reg(6,  32'd30,         "x6");
        check_reg(7,  32'd30,         "x7");
        check_reg(8,  32'd40,         "x8");
        check_reg(9,  32'd2,          "x9");
        check_reg(10, 32'd10,         "x10");
        check_reg(11, 32'hFFFF_FFFC,  "x11");
        check_reg(12, 32'hFFFF_FFF0,  "x12");
        check_reg(13, 32'hFFFF_FFFC,  "x13");
        check_reg(14, 32'd1,          "x14");
        check_reg(15, 32'd1,          "x15");
        check_reg(16, 32'd99,         "x16");
        check_reg(17, 32'd0,          "x17");
        check_reg(18, 32'd256,        "x18");
        check_reg(19, 32'd30,         "x19");
        check_reg(20, 32'd50,         "x20");
        check_reg(21, 32'd96,         "x21");
        check_reg(22, 32'd5,          "x22");

        $display("");
        $display("Clock cycles = %0d", cycle_count);

        if (errors == 0) begin
            $display("");
            $display("==============================================");
            $display("     RV32I COMPREHENSIVE SMOKE TEST: PASS");
            $display("==============================================");
        end
        else begin
            $display("");
            $display("==============================================");
            $display("     RV32I COMPREHENSIVE SMOKE TEST: FAIL");
            $display("     Errors = %0d", errors);
            $display("==============================================");
        end

        $finish;
    end

endmodule
