module alu (
    input  logic [31:0] a,
    input  logic [31:0] b,
    input  logic [3:0]  alu_ctrl,
    output logic [31:0] result,
    output logic        zero
);
    logic signed [31:0] a_signed, b_signed;
    assign a_signed = a;
    assign b_signed = b;

    always_comb begin
        unique case (alu_ctrl)
            4'b0000: result = a + b;                                    // ADD
            4'b0001: result = a - b;                                    // SUB
            4'b0010: result = a & b;                                    // AND
            4'b0011: result = a | b;                                    // OR
            4'b0100: result = a ^ b;                                    // XOR
            4'b0101: result = a << b[4:0];                              // SLL
            4'b0110: result = a >> b[4:0];                              // SRL
            4'b0111: result = a_signed >>> b[4:0];                      // SRA
            4'b1000: result = (a_signed < b_signed) ? 32'd1 : 32'd0;    // SLT
            4'b1001: result = (a < b) ? 32'd1 : 32'd0;                  // SLTU
            default: result = 32'h0;
        endcase
    end
    assign zero = (result == 32'h0);
endmodule
