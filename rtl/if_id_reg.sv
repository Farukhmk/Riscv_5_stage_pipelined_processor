// -----------------------------------------------------------------------------
// if_id_reg  (CHANGED - mandatory fix M1)
//
// The instruction word is NOT registered here any more: the synchronous
// instruction BRAM's own output register already is the IF/ID instruction
// register (it captures mem[pc_out] on the same edge this module captures
// pc_out). Registering it again would add a pipeline stage and mis-pair PC and
// instruction.
//
// What this module still does:
//   * registers pc / pc+4 (paired with the BRAM output)
//   * keeps a 'valid' bit that models stall / flush / reset for the instruction
//     that is physically sitting in the BRAM output register:
//        flush or reset : valid <= 0  -> instr_out forced to NOP (bubble)
//        stall          : hold pc, pc+4, valid  (BRAM is held via its 'en')
//        otherwise      : valid <= 1
//
// Ports are unchanged; instr_out is now combinational (mux) from instr_in.
// -----------------------------------------------------------------------------
module if_id_reg (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        stall,   // hold current contents (BRAM 'en' must also be low)
    input  logic        flush,   // force bubble (NOP)
    input  logic [31:0] pc_in, pc_plus4_in, instr_in,   // instr_in = instr BRAM output
    output logic [31:0] pc_out, pc_plus4_out, instr_out
);
    localparam logic [31:0] NOP = 32'h0000_0013;   // addi x0,x0,0

    logic valid;

    always_ff @(posedge clk) begin
        if (!rst_n || flush) begin
            pc_out       <= 32'h0;
            pc_plus4_out <= 32'h0;
            valid        <= 1'b0;
        end else if (!stall) begin
            pc_out       <= pc_in;
            pc_plus4_out <= pc_plus4_in;
            valid        <= 1'b1;
        end
        // else: stall - hold
    end

    assign instr_out = valid ? instr_in : NOP;
endmodule
