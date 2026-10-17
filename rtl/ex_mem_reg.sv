module ex_mem_reg (
    input  logic        clk,
    input  logic        rst_n,
    input  logic [31:0] alu_result_in, store_data_in, pc_plus4_in,
    input  logic [4:0]  rd_f_in,
    input  logic [2:0]  funct3_in,
    input  logic        reg_we_in, mem_we_in,
    input  logic [1:0]  result_src_in,

    output logic [31:0] alu_result_out, store_data_out, pc_plus4_out,
    output logic [4:0]  rd_f_out,
    output logic [2:0]  funct3_out,
    output logic        reg_we_out, mem_we_out,
    output logic [1:0]  result_src_out
);
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            alu_result_out<='0; store_data_out<='0; pc_plus4_out<='0;
            rd_f_out<='0; funct3_out<='0; reg_we_out<=0; mem_we_out<=0; result_src_out<='0;
        end else begin
            alu_result_out<=alu_result_in; store_data_out<=store_data_in; pc_plus4_out<=pc_plus4_in;
            rd_f_out<=rd_f_in; funct3_out<=funct3_in;
            reg_we_out<=reg_we_in; mem_we_out<=mem_we_in; result_src_out<=result_src_in;
        end
    end
endmodule
