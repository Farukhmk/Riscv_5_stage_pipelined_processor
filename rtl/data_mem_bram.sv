// module data_mem_bram #(
//     parameter int MEM_DEPTH_BYTES = 4096
// ) (
//     input  logic        clk,
//     input  logic [31:0] addr,
//     input  logic [31:0] wdata,
//     input  logic        we,
//     input  logic [2:0]  funct3,
//     output logic [31:0] rdata
// );
//     logic [7:0] mem [0:MEM_DEPTH_BYTES-1];

//     initial begin
//         for (int i = 0; i < MEM_DEPTH_BYTES; i++)
//             mem[i] = 8'h00;
//     end

//     always_ff @(posedge clk) begin
//         if (we) begin
//             unique case (funct3)
//                 3'b000: mem[addr] <= wdata[7:0];
//                 3'b001: begin mem[addr] <= wdata[7:0]; mem[addr+1] <= wdata[15:8]; end
//                 3'b010: begin
//                     mem[addr]   <= wdata[7:0];   mem[addr+1] <= wdata[15:8];
//                     mem[addr+2] <= wdata[23:16]; mem[addr+3] <= wdata[31:24];
//                 end
//                 default: ;
//             endcase
//         end
//     end

//     // registered read (BRAM-style) — funct3 also registered to stay aligned with data
//     logic [2:0] funct3_r;
//     logic [31:0] addr_r;
//     always_ff @(posedge clk) begin
//         addr_r   <= addr;
//         funct3_r <= funct3;
//     end

//     logic [7:0] byte0, byte1, byte2, byte3;
//     assign byte0 = mem[addr_r];
//     assign byte1 = mem[addr_r+1];
//     assign byte2 = mem[addr_r+2];
//     assign byte3 = mem[addr_r+3];

//     always_comb begin
//         unique case (funct3_r)
//             3'b000:  rdata = {{24{byte0[7]}}, byte0};
//             3'b001:  rdata = {{16{byte1[7]}}, byte1, byte0};
//             3'b010:  rdata = {byte3, byte2, byte1, byte0};
//             3'b100:  rdata = {24'b0, byte0};
//             3'b101:  rdata = {16'b0, byte1, byte0};
//             default: rdata = {byte3, byte2, byte1, byte0};
//         endcase
//     end
// endmodule




`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 01.10.2026 16:47:18
// Design Name: 
// Module Name: data_mem_bram_new
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

// BRAM-friendly data memory
// - 4 byte-lane banks, each a word-addressed RAM with a synchronous read
//   (read-first, single address port) -> infers 4 BRAMs (or 4 slices of one).
// - Unaligned LB/LH/LW/SB/SH/SW still supported: each bank gets its own
//   word address (+1 for lanes that wrap past the word boundary), and the
//   read data is rotated back into place AFTER the BRAM output register.
// - Same ports/behaviour as the original: 1-cycle read latency,
//   rdata is valid the cycle after addr/funct3 are presented.


module data_mem_bram #(
    parameter int MEM_DEPTH_BYTES = 4096
) (
    input  logic        clk,
    input  logic [31:0] addr,
    input  logic [31:0] wdata,
    input  logic        we,
    input  logic [2:0]  funct3,
    output logic [31:0] rdata
);
    localparam int WORDS = MEM_DEPTH_BYTES / 4;
    localparam int AW    = $clog2(WORDS);

    // ------------------------------------------------------------------
    // Per-bank control (combinational, in front of the BRAM inputs)
    // ------------------------------------------------------------------
    logic [1:0]    off;
    logic [AW-1:0] waddr;
    assign off   = addr[1:0];
    assign waddr = addr[2 +: AW];

    logic [AW-1:0] bank_addr [4];
    logic          bank_we   [4];
    logic [7:0]    bank_wd   [4];
    logic [7:0]    bank_rd   [4];

    always_comb begin
        for (int b = 0; b < 4; b++) begin
            logic [1:0] k;                       // which byte of wdata lands in bank b
            k = 2'(b) - off;

            // lanes below the offset belong to the next word
            bank_addr[b] = (b < int'(off)) ? waddr + 1'b1 : waddr;
            bank_wd[b]   = wdata[8*k +: 8];

            unique case (funct3)
                3'b000:  bank_we[b] = we && (k == 2'd0);   // SB
                3'b001:  bank_we[b] = we && (k <  2'd2);   // SH
                3'b010:  bank_we[b] = we;                  // SW
                default: bank_we[b] = 1'b0;
            endcase
        end
    end

    // ------------------------------------------------------------------
    // 4 byte-wide BRAM banks, synchronous read (read-first)
    // ------------------------------------------------------------------
    for (genvar b = 0; b < 4; b++) begin : g_bank
        (* ram_style = "block" *) logic [7:0] mem [0:WORDS-1];

        initial begin
            for (int i = 0; i < WORDS; i++)
                mem[i] = 8'h00;
        end

        always_ff @(posedge clk) begin
            if (bank_we[b])
                mem[bank_addr[b]] <= bank_wd[b];
            bank_rd[b] <= mem[bank_addr[b]];     // plain registered output, no reset/enable logic
        end
    end

    // ------------------------------------------------------------------
    // Align control with the BRAM's 1-cycle read latency
    // ------------------------------------------------------------------
    logic [1:0] off_r;
    logic [2:0] funct3_r;
    always_ff @(posedge clk) begin
        off_r    <= off;
        funct3_r <= funct3;
    end

    // Rotate bank outputs back to byte order (byte0 = lowest address)
    logic [7:0] byte0, byte1, byte2, byte3;
    assign byte0 = bank_rd[off_r];
    assign byte1 = bank_rd[2'(off_r + 2'd1)];
    assign byte2 = bank_rd[2'(off_r + 2'd2)];
    assign byte3 = bank_rd[2'(off_r + 2'd3)];

    always_comb begin
        unique case (funct3_r)
            3'b000:  rdata = {{24{byte0[7]}}, byte0};            // LB
            3'b001:  rdata = {{16{byte1[7]}}, byte1, byte0};     // LH
            3'b010:  rdata = {byte3, byte2, byte1, byte0};       // LW
            3'b100:  rdata = {24'b0, byte0};                     // LBU
            3'b101:  rdata = {16'b0, byte1, byte0};              // LHU
            default: rdata = {byte3, byte2, byte1, byte0};
        endcase
    end
endmodule

