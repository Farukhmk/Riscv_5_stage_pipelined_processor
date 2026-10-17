// -----------------------------------------------------------------------------
// reg_file  (CHANGED - mandatory fix M2)
//
// Asynchronous-read register file with WRITE-THROUGH (WB -> ID bypass).
//
// Why: an instruction in WB writes at the END of its WB cycle, but the
// instruction 3 slots behind it is in ID in that same cycle and reads the OLD
// value. The EX-stage forwarding unit only covers producers in MEM and WB
// while the consumer is in EX, so this distance-3 case is not covered anywhere
// else. Bypassing the write data to the read port closes the gap.
//
// Ports are unchanged. x0 stays hard-wired to zero (rd != 0 guard).
// -----------------------------------------------------------------------------
module reg_file (
    input  logic        clk,
    input  logic [4:0]  rs1,
    input  logic [4:0]  rs2,
    input  logic [4:0]  rd,
    input  logic [31:0] wd,
    input  logic        we,
    output logic [31:0] rd1,
    output logic [31:0] rd2
);
    logic [31:0] regs [0:31];

    initial begin
        for (int i = 0; i < 32; i++)
            regs[i] = 32'h0;
    end

    logic wr_en;
    assign wr_en = we && (rd != 5'd0);

    always_ff @(posedge clk)
        if (wr_en)
            regs[rd] <= wd;

    // write-through: same-cycle WB write is visible to the ID-stage read
    assign rd1 = (rs1 == 5'd0)           ? 32'h0 :
                 (wr_en && (rd == rs1))  ? wd    : regs[rs1];
    assign rd2 = (rs2 == 5'd0)           ? 32'h0 :
                 (wr_en && (rd == rs2))  ? wd    : regs[rs2];
endmodule
