// -----------------------------------------------------------------------------
// instr_mem_bram  (CHANGED - mandatory fix M1)
//
// Synchronous-read instruction memory (infers Block RAM on Xilinx 7-series).
//
// TIMING CONTRACT (this is what the rest of the core relies on):
//   * addr is presented in cycle N  (addr = pc_out, straight from the PC flop).
//   * instr is valid in cycle N+1, together with if_id_reg.pc_out == that addr.
//   => instr is the IF/ID *instruction register*. There is NO second register
//      between this output and the ID stage.
//   * en = 0 holds the output register (used for the load-use stall, so the
//     instruction sitting in ID is not overwritten). Maps to the BRAM ENA pin.
//
// Changes vs. original:
//   1. Added 'en' port (stall hold).
//   2. Index uses only the low address bits (addr[AW+1:2]) so a wrong-path /
//      out-of-range PC aliases like the hardware does instead of producing X in
//      simulation. No change to synthesised hardware.
// -----------------------------------------------------------------------------
module instr_mem_bram #(
    parameter int MEM_DEPTH_WORDS = 1024,
    parameter string INIT_FILE    = "program.hex"
) (
    input  logic        clk,
    input  logic        en,      // 1 = normal fetch, 0 = hold output (stall)
    input  logic [31:0] addr,
    output logic [31:0] instr
);
    localparam int AW = $clog2(MEM_DEPTH_WORDS);

    logic [31:0] mem [0:MEM_DEPTH_WORDS-1];

    initial begin
        for (int i = 0; i < MEM_DEPTH_WORDS; i++)
            mem[i] = 32'h0000_0013; // NOP fill (addi x0,x0,0)
        $readmemh(INIT_FILE, mem);
    end

    // synchronous read -> infers Block RAM on Xilinx tools
    always_ff @(posedge clk)
        if (en)
            instr <= mem[addr[AW+1:2]];
endmodule
