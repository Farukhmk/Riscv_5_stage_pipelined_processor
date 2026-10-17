module mem_wb_reg (
    input  logic        clk,
    input  logic        rst_n,
    input  logic [31:0] mem_rdata_in, alu_result_in, pc_plus4_in,
    input  logic [4:0]  rd_f_in,
    input  logic         reg_we_in,
    input  logic [1:0]  result_src_in,

    output logic [31:0] mem_rdata_out, alu_result_out, pc_plus4_out,
    output logic [4:0]  rd_f_out,
    output logic        reg_we_out,
    output logic [1:0]  result_src_out
);
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            mem_rdata_out<='0; alu_result_out<='0; pc_plus4_out<='0;
            rd_f_out<='0; reg_we_out<=0; result_src_out<='0;
        end else begin
            mem_rdata_out<=mem_rdata_in; alu_result_out<=alu_result_in; pc_plus4_out<=pc_plus4_in;
            rd_f_out<=rd_f_in; reg_we_out<=reg_we_in; result_src_out<=result_src_in;
        end
    end
endmodule
