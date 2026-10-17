module pc_reg #(
    parameter logic [31:0] RESET_VECTOR = 32'h0000_0000
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        pc_write,      // stall support: 0 = hold
    input  logic [31:0] pc_next,
    output logic [31:0] pc_out
);
    always_ff @(posedge clk) begin
        if (!rst_n)
            pc_out <= RESET_VECTOR;
        else if (pc_write)
            pc_out <= pc_next;
    end
endmodule
