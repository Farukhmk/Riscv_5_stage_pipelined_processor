module gpio_leds #(
    parameter logic [31:0] LED_ADDR = 32'hFFFF_FFF0
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic [31:0] addr,
    input  logic [31:0] wdata,
    input  logic        we,
    output logic [15:0] led_out
);
    always_ff @(posedge clk) begin
        if (!rst_n)
            led_out <= 16'h0;
        else if (we && addr == LED_ADDR)
            led_out <= wdata[15:0];
    end
endmodule
