module id_ex_reg (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        bubble,  // force control signals to 0 (hazard stall or branch flush)
    input  logic [31:0] pc_in, pc_plus4_in, rd1_in, rd2_in, imm_ext_in,
    input  logic [4:0]  rd_f_in, rs1_f_in, rs2_f_in,
    input  logic [2:0]  funct3_in,
    input  logic        reg_we_in, alu_src_in, mem_we_in,
    input  logic [1:0]  alu_a_src_in, result_src_in,
    input  logic [3:0]  alu_ctrl_in,
    input  logic        branch_in, jump_in, jalr_in,

    output logic [31:0] pc_out, pc_plus4_out, rd1_out, rd2_out, imm_ext_out,
    output logic [4:0]  rd_f_out, rs1_f_out, rs2_f_out,
    output logic [2:0]  funct3_out,
    output logic        reg_we_out, alu_src_out, mem_we_out,
    output logic [1:0]  alu_a_src_out, result_src_out,
    output logic [3:0]  alu_ctrl_out,
    output logic        branch_out, jump_out, jalr_out
);
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            pc_out<='0; pc_plus4_out<='0; rd1_out<='0; rd2_out<='0; imm_ext_out<='0;
            rd_f_out<='0; rs1_f_out<='0; rs2_f_out<='0; funct3_out<='0;
            reg_we_out<=0; alu_src_out<=0; alu_a_src_out<='0; mem_we_out<=0;
            result_src_out<='0; alu_ctrl_out<='0; branch_out<=0; jump_out<=0; jalr_out<=0;
        end else begin
            pc_out<=pc_in; pc_plus4_out<=pc_plus4_in; rd1_out<=rd1_in; rd2_out<=rd2_in;
            imm_ext_out<=imm_ext_in;
            rd_f_out<=rd_f_in; rs1_f_out<=rs1_f_in; rs2_f_out<=rs2_f_in; funct3_out<=funct3_in;
            alu_a_src_out<=alu_a_src_in; alu_ctrl_out<=alu_ctrl_in;
            if (bubble) begin
                reg_we_out<=0; mem_we_out<=0; branch_out<=0; jump_out<=0; jalr_out<=0;
                alu_src_out<=0; result_src_out<='0;
            end else begin
                reg_we_out<=reg_we_in; alu_src_out<=alu_src_in; mem_we_out<=mem_we_in;
                result_src_out<=result_src_in; branch_out<=branch_in; jump_out<=jump_in; jalr_out<=jalr_in;
            end
        end
    end
endmodule
