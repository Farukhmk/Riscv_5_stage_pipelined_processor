
`timescale 1ns / 1ps

module gpio_leds_tb;
    logic        clk = 1'b0, rst_n = 1'b0, we = 1'b0;
    logic [31:0] addr = 32'h0, wdata = 32'h0;
    logic [15:0] led_out;
    int errors = 0, checks = 0;

    gpio_leds dut (.clk(clk), .rst_n(rst_n), .addr(addr), .wdata(wdata), .we(we), .led_out(led_out));
    always #5 clk = ~clk;

    task automatic expect_led(input logic [15:0] exp, input string msg);
        checks++;
        if (led_out !== exp) begin
            errors++;
            $error("%s: led_out = 0x%04h, expected 0x%04h", msg, led_out, exp);
        end else $display("[PASS] %s (led_out = 0x%04h)", msg, led_out);
    endtask

    // one write attempt: drive for one clock, then sample
    task automatic write_try(input logic [31:0] a, input logic [31:0] d, input logic w);
        @(negedge clk);
        addr = a; wdata = d; we = w;
        @(negedge clk);
        we = 1'b0;
    endtask

    initial begin
        repeat (3) @(negedge clk);
        expect_led(16'h0000, "held in reset: LEDs are 0");
        rst_n = 1'b1;
        @(negedge clk);

        write_try(32'hFFFF_FFF0, 32'h0000_00AB, 1'b1);
        expect_led(16'h00AB, "write at LED address with we=1");

        write_try(32'hFFFF_FFF4, 32'h0000_00CD, 1'b1);
        expect_led(16'h00AB, "we=1 but WRONG address (+4): no change");

        write_try(32'h0000_0100, 32'h0000_00EE, 1'b1);
        expect_led(16'h00AB, "we=1 but ordinary data address: no change");

        write_try(32'h7FFF_FFF0, 32'h0000_0011, 1'b1);
        expect_led(16'h00AB, "we=1 but only upper address bit differs: no change");

        write_try(32'hFFFF_FFF0, 32'h0000_0077, 1'b0);
        expect_led(16'h00AB, "LED address but we=0: no change");

        write_try(32'hFFFF_FFF0, 32'hDEAD_BEEF, 1'b1);
        expect_led(16'hBEEF, "only wdata[15:0] is latched");

        write_try(32'hFFFF_FFF0, 32'h0000_0000, 1'b1);
        expect_led(16'h0000, "write zero");

        write_try(32'hFFFF_FFF0, 32'h0000_1234, 1'b1);
        expect_led(16'h1234, "write after zero");
        rst_n = 1'b0;
        @(negedge clk); @(negedge clk);
        expect_led(16'h0000, "reset clears LEDs");

        $display("-----------------------------------------");
        $display("  checks: %0d   errors: %0d", checks, errors);
        if (errors == 0) $display("  *** GPIO_LEDS TEST PASSED ***");
        else             $display("  *** GPIO_LEDS TEST FAILED ***");
        $finish;
    end
endmodule
