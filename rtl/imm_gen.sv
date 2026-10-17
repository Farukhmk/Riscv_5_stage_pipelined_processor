module imm_gen (
    input  logic [31:0] instr,
    input  logic [2:0]  imm_src,
    output logic [31:0] imm_ext
);
    always_comb begin
        unique case (imm_src)
            3'b000:  imm_ext = {{20{instr[31]}}, instr[31:20]};                                    // I
            3'b001:  imm_ext = {{20{instr[31]}}, instr[31:25], instr[11:7]};                       // S
            3'b010:  imm_ext = {{20{instr[31]}}, instr[7], instr[30:25], instr[11:8], 1'b0};       // B
            3'b011:  imm_ext = {instr[31:12], 12'b0};                                              // U
            3'b100:  imm_ext = {{12{instr[31]}}, instr[19:12], instr[20], instr[30:21], 1'b0};     // J
            default: imm_ext = 32'h0;
        endcase
    end
endmodule
