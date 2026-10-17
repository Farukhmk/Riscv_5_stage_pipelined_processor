module control_unit (
    input  logic [6:0] opcode,
    input  logic [2:0] funct3,
    input  logic [6:0] funct7,
    output logic       reg_we,
    output logic       alu_src,
    output logic [1:0] alu_a_src,   // 00=rd1, 01=zero(LUI), 10=pc(AUIPC)
    output logic       mem_we,
    output logic [1:0] result_src,  // 00=alu, 01=mem, 10=pc+4
    output logic [2:0] imm_src,
    output logic [3:0] alu_ctrl,
    output logic       branch,
    output logic       jump,
    output logic       jalr
);
    localparam logic [6:0] OP_RTYPE  = 7'b0110011;
    localparam logic [6:0] OP_ITYPE  = 7'b0010011;
    localparam logic [6:0] OP_LOAD   = 7'b0000011;
    localparam logic [6:0] OP_STORE  = 7'b0100011;
    localparam logic [6:0] OP_BRANCH = 7'b1100011;
    localparam logic [6:0] OP_JAL    = 7'b1101111;
    localparam logic [6:0] OP_JALR   = 7'b1100111;
    localparam logic [6:0] OP_LUI    = 7'b0110111;
    localparam logic [6:0] OP_AUIPC  = 7'b0010111;

    logic [1:0] alu_op;

    always_comb begin
        reg_we = 1'b0; alu_src = 1'b0; alu_a_src = 2'b00; mem_we = 1'b0;
        result_src = 2'b00; imm_src = 3'b000; branch = 1'b0; jump = 1'b0;
        jalr = 1'b0; alu_op = 2'b00;

        unique case (opcode)
            OP_RTYPE:  begin reg_we=1; alu_src=0; result_src=2'b00; alu_op=2'b10; end
            OP_ITYPE:  begin reg_we=1; alu_src=1; result_src=2'b00; imm_src=3'b000; alu_op=2'b10; end
            OP_LOAD:   begin reg_we=1; alu_src=1; result_src=2'b01; imm_src=3'b000; alu_op=2'b00; end
            OP_STORE:  begin alu_src=1; mem_we=1; imm_src=3'b001; alu_op=2'b00; end
            OP_BRANCH: begin alu_src=0; imm_src=3'b010; branch=1; alu_op=2'b01; end
            OP_JAL:    begin reg_we=1; result_src=2'b10; imm_src=3'b100; jump=1; end
            OP_JALR:   begin reg_we=1; alu_src=1; result_src=2'b10; imm_src=3'b000; jump=1; jalr=1; end
            OP_LUI:    begin reg_we=1; alu_src=1; alu_a_src=2'b01; result_src=2'b00; imm_src=3'b011; alu_op=2'b11; end
            OP_AUIPC:  begin reg_we=1; alu_src=1; alu_a_src=2'b10; result_src=2'b00; imm_src=3'b011; alu_op=2'b11; end
            default:   begin reg_we=0; mem_we=0; end
        endcase
    end

    always_comb begin
        unique case (alu_op)
            2'b00: alu_ctrl = 4'b0000;
            2'b01: begin
                unique case (funct3)
                    3'b000, 3'b001: alu_ctrl = 4'b0001;
                    3'b100, 3'b101: alu_ctrl = 4'b1000;
                    3'b110, 3'b111: alu_ctrl = 4'b1001;
                    default:        alu_ctrl = 4'b0001;
                endcase
            end
            2'b11: alu_ctrl = 4'b0000;
            2'b10: begin
                unique case (funct3)
                    3'b000:  alu_ctrl = (opcode==OP_RTYPE && funct7[5]) ? 4'b0001 : 4'b0000;
                    3'b001:  alu_ctrl = 4'b0101;
                    3'b010:  alu_ctrl = 4'b1000;
                    3'b011:  alu_ctrl = 4'b1001;
                    3'b100:  alu_ctrl = 4'b0100;
                    3'b101:  alu_ctrl = funct7[5] ? 4'b0111 : 4'b0110;
                    3'b110:  alu_ctrl = 4'b0011;
                    3'b111:  alu_ctrl = 4'b0010;
                    default: alu_ctrl = 4'b0000;
                endcase
            end
            default: alu_ctrl = 4'b0000;
        endcase
    end
endmodule
