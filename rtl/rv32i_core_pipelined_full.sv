module rv32i_core_pipelined_full (
    input  logic        clk,
    input  logic        rst_n,
    output logic [15:0] led_out
);
    // =========================================================================
    // Declarations hoisted to the top (CHANGED, cosmetic/portability): several
    // signals were used by instances/assigns before their declaration. Legal in
    // some tools, an error or a silent 1-bit implicit net in strict ones.
    // No functional change.
    // =========================================================================
    // hazard / control
    logic        hazard_stall;
    logic        pc_write, if_id_stall, if_id_flush, id_ex_bubble;
    // EX/MEM outputs (used by forwarding in EX)
    logic [31:0] alu_result_mem, store_data_mem, pc_plus4_mem;
    logic [4:0]  rd_mem;
    logic [2:0]  funct3_mem;
    logic        reg_we_mem, mem_we_mem;
    logic [1:0]  result_src_mem;
    // WB
    logic [31:0] reg_wd_wb;
    logic [4:0]  rd_wb;
    logic        reg_we_wb;

    // ============ IF STAGE ============
    logic [31:0] pc_out, pc_next, pc_plus4_if, instr_if;
    logic [31:0] pc_target_ex;
    logic [1:0]  pc_src_ex;

    assign pc_plus4_if = pc_out + 32'd4;

    pc_reg u_pc (.clk(clk), .rst_n(rst_n), .pc_write(pc_write), .pc_next(pc_next), .pc_out(pc_out));
    pc_next_gen u_pcnext (
        .pc_current(pc_out), .branch_target(pc_target_ex), .jump_target(pc_target_ex),
        .pc_src(pc_src_ex), .pc_next(pc_next)
    );

    // CHANGED (M1): address = pc_out (a flop). instr_if is the BRAM output
    // register and is valid in the NEXT cycle, i.e. in the same cycle as
    // pc_id/pc_plus4_id (if_id_reg). instr_if is therefore the IF/ID
    // instruction register - it is NOT registered a second time.
    // en = ~hazard_stall holds the BRAM output while the ID stage is stalled.
    // Note: the EX-stage branch decision (pc_src_ex / pc_target_ex) does NOT
    // reach the BRAM address or enable pins - it only reaches pc_reg.
    instr_mem_bram #(.MEM_DEPTH_WORDS(1024), .INIT_FILE("program.hex")) u_imem (
        .clk(clk), .en(~hazard_stall), .addr(pc_out), .instr(instr_if)
    );

    // ============ IF/ID ============
    logic [31:0] pc_id, pc_plus4_id, instr_id;
    assign if_id_flush = (pc_src_ex != 2'b00);   // branch/jump resolved in EX -> kill wrong-path fetch
    assign if_id_stall = hazard_stall;           // load-use stall
    assign pc_write    = ~hazard_stall;          // freeze PC on load-use stall
    // Invariant (assert in simulation): hazard_stall and if_id_flush are never
    // both 1 - a stall needs a LOAD in EX, a flush needs a BRANCH/JUMP in EX.

    if_id_reg u_ifid (
        .clk(clk), .rst_n(rst_n), .stall(if_id_stall), .flush(if_id_flush),
        .pc_in(pc_out), .pc_plus4_in(pc_plus4_if), .instr_in(instr_if),
        .pc_out(pc_id), .pc_plus4_out(pc_plus4_id), .instr_out(instr_id)
    );

    // ============ ID STAGE ============
    logic [6:0] opcode_id, funct7_id;
    logic [4:0] rd_id, rs1_id, rs2_id;
    logic [2:0] funct3_id;
    logic [31:0] imm_ext_id, rd1_id, rd2_id;
    logic reg_we_id, alu_src_id, mem_we_id, branch_id, jump_id, jalr_id;
    logic [1:0] alu_a_src_id, result_src_id;
    logic [2:0] imm_src_id;
    logic [3:0] alu_ctrl_id;

    instr_decode_fields u_dec (
        .instr(instr_id), .opcode(opcode_id), .rd(rd_id), .funct3(funct3_id),
        .rs1(rs1_id), .rs2(rs2_id), .funct7(funct7_id)
    );
    imm_gen u_imm (.instr(instr_id), .imm_src(imm_src_id), .imm_ext(imm_ext_id));
    // reg_file now has write-through (M2): WB write is visible to ID same cycle
    reg_file u_rf (
        .clk(clk), .rs1(rs1_id), .rs2(rs2_id), .rd(rd_wb),
        .wd(reg_wd_wb), .we(reg_we_wb), .rd1(rd1_id), .rd2(rd2_id)
    );
    control_unit u_ctrl (
        .opcode(opcode_id), .funct3(funct3_id), .funct7(funct7_id),
        .reg_we(reg_we_id), .alu_src(alu_src_id), .alu_a_src(alu_a_src_id), .mem_we(mem_we_id),
        .result_src(result_src_id), .imm_src(imm_src_id), .alu_ctrl(alu_ctrl_id),
        .branch(branch_id), .jump(jump_id), .jalr(jalr_id)
    );

    // ============ ID/EX ============
    logic [31:0] pc_ex, pc_plus4_ex, rd1_ex, rd2_ex, imm_ext_ex;
    logic [4:0] rd_ex, rs1_ex, rs2_ex;
    logic [2:0] funct3_ex;
    logic reg_we_ex, alu_src_ex, mem_we_ex, branch_ex, jump_ex, jalr_ex;
    logic [1:0] alu_a_src_ex, result_src_ex;
    logic [3:0] alu_ctrl_ex;

    hazard_detection_unit u_hazard (
        .rs1_id(rs1_id),
        .rs2_id(rs2_id),
        .rd_ex(rd_ex),
        .result_src_ex(result_src_ex),
        .stall(hazard_stall)
    );

    assign id_ex_bubble = hazard_stall || if_id_flush;

    id_ex_reg u_idex (
        .clk(clk), .rst_n(rst_n), .bubble(id_ex_bubble),
        .pc_in(pc_id), .pc_plus4_in(pc_plus4_id), .rd1_in(rd1_id), .rd2_in(rd2_id), .imm_ext_in(imm_ext_id),
        .rd_f_in(rd_id), .rs1_f_in(rs1_id), .rs2_f_in(rs2_id), .funct3_in(funct3_id),
        .reg_we_in(reg_we_id), .alu_src_in(alu_src_id), .alu_a_src_in(alu_a_src_id), .mem_we_in(mem_we_id),
        .result_src_in(result_src_id), .alu_ctrl_in(alu_ctrl_id), .branch_in(branch_id),
        .jump_in(jump_id), .jalr_in(jalr_id),
        .pc_out(pc_ex), .pc_plus4_out(pc_plus4_ex), .rd1_out(rd1_ex), .rd2_out(rd2_ex), .imm_ext_out(imm_ext_ex),
        .rd_f_out(rd_ex), .rs1_f_out(rs1_ex), .rs2_f_out(rs2_ex), .funct3_out(funct3_ex),
        .reg_we_out(reg_we_ex), .alu_src_out(alu_src_ex), .alu_a_src_out(alu_a_src_ex), .mem_we_out(mem_we_ex),
        .result_src_out(result_src_ex), .alu_ctrl_out(alu_ctrl_ex), .branch_out(branch_ex),
        .jump_out(jump_ex), .jalr_out(jalr_ex)
    );

    // ============ EX STAGE (with forwarding) ============
    logic [31:0] alu_a_ex, alu_b_ex, alu_result_ex;
    logic alu_zero_ex;
    logic [1:0] forward_a, forward_b;
    logic [31:0] rd1_fwd, rd2_fwd;

    // forwarding sources: EX/MEM's alu_result, MEM/WB's write-back value
    forwarding_unit u_fwd (
        .rs1_ex(rs1_ex), .rs2_ex(rs2_ex),
        .rd_mem(rd_mem), .rd_wb(rd_wb),
        .reg_we_mem(reg_we_mem), .reg_we_wb(reg_we_wb),
        .forward_a(forward_a), .forward_b(forward_b)
    );

    always_comb begin
        unique case (forward_a)
            2'b01:   rd1_fwd = alu_result_mem;
            2'b10:   rd1_fwd = reg_wd_wb;
            default: rd1_fwd = rd1_ex;
        endcase
        unique case (forward_b)
            2'b01:   rd2_fwd = alu_result_mem;
            2'b10:   rd2_fwd = reg_wd_wb;
            default: rd2_fwd = rd2_ex;
        endcase
    end

    operand_muxes u_muxes (
        .rd1(rd1_fwd), .rd2(rd2_fwd), .imm_ext(imm_ext_ex), .pc_current(pc_ex),
        .alu_src(alu_src_ex), .alu_a_src(alu_a_src_ex),
        .alu_a(alu_a_ex), .alu_b(alu_b_ex)
    );
    alu u_alu (.a(alu_a_ex), .b(alu_b_ex), .alu_ctrl(alu_ctrl_ex), .result(alu_result_ex), .zero(alu_zero_ex));

    branch_jump_unit u_bju (
        .pc_current(pc_ex), .imm_ext(imm_ext_ex), .rs1_val(rd1_fwd),
        .branch(branch_ex), .jump(jump_ex), .jalr(jalr_ex), .funct3(funct3_ex),
        .alu_zero(alu_zero_ex), .alu_result_lt(alu_result_ex[0]),
        .pc_target(pc_target_ex), .pc_src(pc_src_ex)
    );

    // ============ EX/MEM ============
    ex_mem_reg u_exmem (
        .clk(clk), .rst_n(rst_n),
        .alu_result_in(alu_result_ex), .store_data_in(rd2_fwd), .pc_plus4_in(pc_plus4_ex),
        .rd_f_in(rd_ex), .funct3_in(funct3_ex), .reg_we_in(reg_we_ex), .mem_we_in(mem_we_ex),
        .result_src_in(result_src_ex),
        .alu_result_out(alu_result_mem), .store_data_out(store_data_mem), .pc_plus4_out(pc_plus4_mem),
        .rd_f_out(rd_mem), .funct3_out(funct3_mem), .reg_we_out(reg_we_mem), .mem_we_out(mem_we_mem),
        .result_src_out(result_src_mem)
    );

    // ============ MEM STAGE ============
    // NOTE: data_mem_bram has a registered read. The address is presented in
    // the MEM cycle, rdata is valid in the following (WB) cycle. mem_rdata_mem
    // is therefore *already WB-aligned*: the BRAM output register plays the
    // role of the MEM/WB load-data register. (Name kept from the original.)
    logic [31:0] mem_rdata_mem;

    // simple address decode: reserved top address range -> GPIO, else data memory
    logic is_gpio_addr;
    assign is_gpio_addr = (alu_result_mem == 32'hFFFF_FFF0);

    data_mem_bram #(.MEM_DEPTH_BYTES(4096)) u_dmem (
        .clk(clk), .addr(alu_result_mem), .wdata(store_data_mem),
        .we(mem_we_mem && !is_gpio_addr), .funct3(funct3_mem), .rdata(mem_rdata_mem)
    );

    gpio_leds u_gpio (
        .clk(clk), .rst_n(rst_n),
        .addr(alu_result_mem), .wdata(store_data_mem), .we(mem_we_mem && is_gpio_addr),
        .led_out(led_out)
    );

    // ============ MEM/WB ============
    logic [31:0] mem_rdata_wb, alu_result_wb, pc_plus4_wb;
    logic [1:0] result_src_wb;

    // mem_rdata_wb (the registered copy) is intentionally NOT used below: it
    // would be one cycle too late for loads. It is left in place (unchanged
    // module) and is pruned by synthesis.
    mem_wb_reg u_memwb (
        .clk(clk), .rst_n(rst_n),
        .mem_rdata_in(mem_rdata_mem), .alu_result_in(alu_result_mem), .pc_plus4_in(pc_plus4_mem),
        .rd_f_in(rd_mem), .reg_we_in(reg_we_mem), .result_src_in(result_src_mem),
        .mem_rdata_out(mem_rdata_wb), .alu_result_out(alu_result_wb), .pc_plus4_out(pc_plus4_wb),
        .rd_f_out(rd_wb), .reg_we_out(reg_we_wb), .result_src_out(result_src_wb)
    );

    // ============ WB STAGE ============
    always_comb begin
        unique case (result_src_wb)
            2'b00:   reg_wd_wb = alu_result_wb;
            2'b01:   reg_wd_wb = mem_rdata_mem;   // BRAM output reg == WB-stage load data (see MEM STAGE note)
            2'b10:   reg_wd_wb = pc_plus4_wb;
            default: reg_wd_wb = alu_result_wb;
        endcase
    end

endmodule
