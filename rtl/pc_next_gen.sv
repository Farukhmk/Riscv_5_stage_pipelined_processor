module pc_next_gen (
    input  logic [31:0] pc_current,
    input  logic [31:0] branch_target,
    input  logic [31:0] jump_target,
    input  logic [1:0]  pc_src,
    output logic [31:0] pc_next
);
    logic [31:0] pc_plus4;
    assign pc_plus4 = pc_current + 32'd4;

    always_comb begin
        unique case (pc_src)
            2'b00:   pc_next = pc_plus4;
            2'b01:   pc_next = branch_target;
            2'b10:   pc_next = jump_target;
            default: pc_next = pc_plus4;
        endcase
    end
endmodule
