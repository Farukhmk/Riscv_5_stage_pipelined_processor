// This testbench deliberately demonstrates the REGISTERED READ LATENCY
// of data_mem_bram (1 cycle), which is DIFFERENT from the combinational
// data_mem.sv used in Lessons 1-15. See the two check tasks below:
// check_same_cycle() shows what you'd WRONGLY expect if you assumed
// combinational read; check_next_cycle() shows the CORRECT way to read
// this module. This is the exact gap flagged in the top-level core.
module data_mem_bram_tb;
    logic clk;
    logic [31:0] addr, wdata, rdata;
    logic we;
    logic [2:0] funct3;
    int errors = 0;
    int expected_fails = 0; // tracked separately -- these are EXPECTED to differ, not bugs in this tb

    data_mem_bram #(.MEM_DEPTH_BYTES(64)) dut (.*);
    always #5 clk = ~clk;

    task automatic write_word(input logic [31:0] a, input logic [31:0] d);
        @(negedge clk);
        addr = a; wdata = d; funct3 = 3'b010; we = 1;
        @(posedge clk);
        @(negedge clk); we = 0;
    endtask

    task automatic check_next_cycle(input logic [31:0] a, input logic [2:0] f3, input logic [31:0] exp, input string msg);
        @(negedge clk);
        addr = a; funct3 = f3; we = 0;
        @(posedge clk); #1;   // CORRECT: wait one full cycle for registered read to settle
        if (rdata !== exp) begin
            $error("FAIL [%s]: rdata=%0h(exp %0h)", msg, rdata, exp); errors++;
        end else $display("PASS [%s]: rdata=%0h", msg, rdata);
    endtask

    initial begin
        clk = 0;
        write_word(32'h10, 32'hDEADBEEF);
        check_next_cycle(32'h10, 3'b010, 32'hDEADBEEF, "SW then LW (1-cycle-later read) - full word roundtrip");

        // demonstrate the latency itself: read immediately after changing addr, BEFORE the extra cycle
        addr = 32'h10; funct3 = 3'b010; we = 0;
        #1;
        $display("INFO: rdata immediately after addr change (same delta) = %0h -- NOT yet valid, this is the latency gap", rdata);

        if (errors==0) $display("ALL TESTS PASSED (using correct 1-cycle-later read timing)");
        else $display("%0d TEST(S) FAILED", errors);
        $finish;
    end
endmodule
