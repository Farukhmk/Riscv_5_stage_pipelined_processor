module hazard_detection_unit (
    input  logic [4:0] rs1_id, rs2_id,
    input  logic [4:0] rd_ex,
    input  logic [1:0] result_src_ex,   // 01 = load, currently in EX (was ID/EX output)
    output logic       stall
);
    // result_src_ex == 2'b01 means the instruction now in EX is a load
    always_comb begin
        if ((result_src_ex == 2'b01) && (rd_ex != 5'd0) &&
            ((rd_ex == rs1_id) || (rd_ex == rs2_id)))
            stall = 1'b1;
        else
            stall = 1'b0;
    end
endmodule
