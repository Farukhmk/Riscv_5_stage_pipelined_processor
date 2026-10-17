module branch_jump_unit (
    input  logic [31:0] pc_current, imm_ext, rs1_val,
    input  logic        branch, jump, jalr,
    input  logic [2:0]  funct3,
    input  logic        alu_zero, alu_result_lt,
    output logic [31:0] pc_target,
    output logic [1:0]  pc_src
);
    logic taken;
    logic [31:0] jalr_target, pcrel_target;

    assign jalr_target  = (rs1_val + imm_ext) & 32'hFFFF_FFFE;
    assign pcrel_target = pc_current + imm_ext;
    assign pc_target    = jalr ? jalr_target : pcrel_target;

    always_comb begin
        unique case (funct3)
            3'b000:  taken = alu_zero;
            3'b001:  taken = ~alu_zero;
            3'b100:  taken = alu_result_lt;
            3'b101:  taken = ~alu_result_lt;
            3'b110:  taken = alu_result_lt;
            3'b111:  taken = ~alu_result_lt;
            default: taken = 1'b0;
        endcase
    end

    always_comb begin
        if (jump)                  pc_src = 2'b10;
        else if (branch && taken)  pc_src = 2'b01;
        else                       pc_src = 2'b00;
    end
endmodule
