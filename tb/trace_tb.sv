`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 17.10.2026 08:15:44
// Design Name: 
// Module Name: trace_tb
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


`timescale 1ns/1ps
module trace_tb;
  logic clk=0, rst_n=0; logic [15:0] led_out;
  rv32i_core_pipelined_full dut(.clk(clk),.rst_n(rst_n),.led_out(led_out));
  always #5 clk=~clk;
  localparam logic [31:0] NOP=32'h13;
  function automatic logic [31:0] ADDI(int rd,int rs1,int imm); return {imm[11:0],rs1[4:0],3'b000,rd[4:0],7'b0010011}; endfunction
  function automatic logic [31:0] ADD(int rd,int rs1,int rs2);  return {7'b0,rs2[4:0],rs1[4:0],3'b000,rd[4:0],7'b0110011}; endfunction
  function automatic logic [31:0] LW(int rd,int rs1,int imm);   return {imm[11:0],rs1[4:0],3'b010,rd[4:0],7'b0000011}; endfunction
  function automatic logic [31:0] SW(int rs2,int rs1,int imm);  return {imm[11:5],rs2[4:0],rs1[4:0],3'b010,imm[4:0],7'b0100011}; endfunction
  logic [31:0] prog[0:63]; int n;
  task automatic e(input logic [31:0] i); prog[n]=i; n++; endtask

  // shadow copies of the instruction word per stage (for the trace only)
  logic [31:0] i_id, i_ex, i_mem, i_wb;
  assign i_id = dut.instr_id;
  always @(posedge clk) begin
    i_ex  <= (!rst_n || dut.id_ex_bubble) ? 32'h0 : dut.instr_id;
    i_mem <= i_ex;
    i_wb  <= i_mem;
  end
  function automatic string dis(input logic [31:0] w, input bit valid);
    string s;
    if (w==0 || !valid) return "(bubble)";
    case (w[6:0])
      7'b0010011: s = (w==32'h13) ? "nop" : $sformatf("addi x%0d,x%0d,%0d", w[11:7], w[19:15], $signed(w[31:20]));
      7'b0110011: s = $sformatf("add  x%0d,x%0d,x%0d", w[11:7], w[19:15], w[24:20]);
      7'b0000011: s = $sformatf("lw   x%0d,%0d(x%0d)", w[11:7], $signed(w[31:20]), w[19:15]);
      7'b0100011: s = $sformatf("sw   x%0d,%0d(x%0d)", w[24:20], $signed({w[31:25],w[11:7]}), w[19:15]);
      default: s = "?";
    endcase
    return s;
  endfunction

  int cyc;
  task automatic run(input string title, input int ncyc);
    rst_n=0;
    for (int i=0;i<1024;i++) dut.u_imem.mem[i]=NOP;
    for (int i=0;i<n;i++) dut.u_imem.mem[i]=prog[i];
    repeat(3) @(negedge clk);
    rst_n=1; cyc=0;
    $display("\n######## %s", title);
    $display("cyc | IF-addr  |  ID                |  EX                |  MEM               |  WB                | aluEX    memAddr  we | rd_mem  mem_rdata_mem mem_rdata_wb | we_wb rd_wb reg_wd_wb | stall flush fwdA fwdB");
    repeat(ncyc) begin
      @(negedge clk);
      $display("%3d | %08h | %-18s | %-18s | %-18s | %-18s | %08h %08h  %b  |  x%-2d   %08h      %08h     |  %b    x%-2d  %08h |   %b     %b    %b    %b",
        cyc, dut.pc_out, dis(i_id,1), dis(i_ex,1), dis(i_mem,1), dis(i_wb,1),
        dut.alu_result_ex, dut.alu_result_mem, dut.mem_we_mem,
        dut.rd_mem, dut.mem_rdata_mem, dut.mem_rdata_wb,
        dut.reg_we_wb, dut.rd_wb, dut.reg_wd_wb,
        dut.hazard_stall, dut.if_id_flush, dut.forward_a, dut.forward_b);
      cyc++;
    end
    $display("final: x2=%0d x3=%0d x18=%0d x19=%0d x20=%0d x21=%0d x22=%0d  dmem[0x100]=%08h dmem[0x104]=%08h",
      dut.u_rf.regs[2],dut.u_rf.regs[3],dut.u_rf.regs[18],dut.u_rf.regs[19],dut.u_rf.regs[20],dut.u_rf.regs[21],dut.u_rf.regs[22],
      {dut.u_dmem.g_bank[3].mem[64],dut.u_dmem.g_bank[2].mem[64],dut.u_dmem.g_bank[1].mem[64],dut.u_dmem.g_bank[0].mem[64]},
      {dut.u_dmem.g_bank[3].mem[65],dut.u_dmem.g_bank[2].mem[65],dut.u_dmem.g_bank[1].mem[65],dut.u_dmem.g_bank[0].mem[65]});
  endtask
  task automatic clear_mem(); for (int i=0;i<1024;i++) begin dut.u_dmem.g_bank[0].mem[i]=0; dut.u_dmem.g_bank[1].mem[i]=0; dut.u_dmem.g_bank[2].mem[i]=0; dut.u_dmem.g_bank[3].mem[i]=0; end
    for (int i=0;i<32;i++) dut.u_rf.regs[i]=0; endtask

  initial begin
    #1;
    // ---- Programs A: store -> load -> dependent ALU (cases 1,2,3,5) ----
    clear_mem(); n=0;
    e(ADDI(2,0,20)); e(ADDI(3,0,30)); e(ADDI(18,0,256));
    e(NOP); e(NOP); e(NOP);
    e(SW(3,18,0));      // store 30 -> [256]
    e(LW(19,18,0));     // case 5: load from same address, immediately after the store
    e(ADD(20,19,2));    // case 2/3: load-use
    run("A: SW x3,0(x18) ; LW x19,0(x18) ; ADD x20,x19,x2   (cases 1,2,3,5)", 20);

    // ---- Program B: load -> store of loaded value (case 4) ----
    clear_mem(); n=0;
    e(ADDI(3,0,30)); e(ADDI(18,0,256)); e(NOP); e(NOP); e(NOP);
    e(SW(3,18,0));
    e(NOP); e(NOP); e(NOP);
    e(LW(19,18,0));
    e(SW(19,18,4));     // store the just-loaded value to [260]
    e(LW(21,18,4));     // read it back
    e(ADD(22,21,21));
    run("B: LW x19,0(x18) ; SW x19,4(x18) ; LW x21,4(x18) ; ADD x22,x21,x21   (case 4)", 24);

    // ---- Program C: load with 1 and 2 independent instructions before the use ----
    clear_mem(); n=0;
    e(ADDI(2,0,20)); e(ADDI(3,0,30)); e(ADDI(18,0,256)); e(NOP); e(NOP); e(NOP);
    e(SW(3,18,0)); e(NOP); e(NOP); e(NOP);
    e(LW(19,18,0)); e(NOP); e(ADD(20,19,2));     // distance 2
    e(NOP); e(NOP); e(NOP);
    e(LW(21,18,0)); e(NOP); e(NOP); e(ADD(22,21,2));   // distance 3
    run("C: LW, 1 gap, use  /  LW, 2 gaps, use", 30);

    // ---- Program D: LW from an address that was NEVER written ----
    clear_mem(); n=0;
    e(ADDI(2,0,20)); e(ADDI(18,0,256)); e(NOP); e(NOP); e(NOP);
    e(LW(19,18,0)); e(ADD(20,19,2));
    run("D: LW x19,0(x18) with mem[256] never written ; ADD x20,x19,x2", 16);
    $finish;
  end
endmodule
