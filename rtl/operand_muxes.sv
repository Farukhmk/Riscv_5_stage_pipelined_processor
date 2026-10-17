module operand_muxes (
    input  logic [31:0] rd1, rd2, imm_ext, pc_current,
    input  logic        alu_src,
    input  logic [1:0]  alu_a_src,
    output logic [31:0] alu_a,
    output logic [31:0] alu_b
);
    always_comb begin
        unique case (alu_a_src)
            2'b00:   alu_a = rd1;
            2'b01:   alu_a = 32'h0;
            2'b10:   alu_a = pc_current;
            default: alu_a = rd1;
        endcase
    end
    assign alu_b = alu_src ? imm_ext : rd2;
endmodule
