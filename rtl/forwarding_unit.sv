module forwarding_unit (
    input  logic [4:0] rs1_ex, rs2_ex,
    input  logic [4:0] rd_mem, rd_wb,
    input  logic       reg_we_mem, reg_we_wb,
    output logic [1:0] forward_a, forward_b
);
    always_comb begin
        // ForwardA
        if (reg_we_mem && (rd_mem != 5'd0) && (rd_mem == rs1_ex))
            forward_a = 2'b01;               // from EX/MEM (most recent)
        else if (reg_we_wb && (rd_wb != 5'd0) && (rd_wb == rs1_ex))
            forward_a = 2'b10;               // from MEM/WB
        else
            forward_a = 2'b00;               // no forward, use reg file value

        // ForwardB
        if (reg_we_mem && (rd_mem != 5'd0) && (rd_mem == rs2_ex))
            forward_b = 2'b01;
        else if (reg_we_wb && (rd_wb != 5'd0) && (rd_wb == rs2_ex))
            forward_b = 2'b10;
        else
            forward_b = 2'b00;
    end
endmodule
