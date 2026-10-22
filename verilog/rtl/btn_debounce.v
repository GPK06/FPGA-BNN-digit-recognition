// 2-FF synchronizer + counter debounce for a push button / switch.
`timescale 1ns/1ps
module btn_debounce #(parameter CYC = 1000000) (   // 10 ms @ 100 MHz
    input  wire clk,
    input  wire in,
    output reg  out = 1'b0
);
    reg s0 = 1'b0, s1 = 1'b0;
    reg [31:0] cnt = 32'd0;
    always @(posedge clk) begin
        s0 <= in;
        s1 <= s0;
        if (s1 == out)            cnt <= 32'd0;
        else if (cnt >= CYC - 1)  begin out <= s1; cnt <= 32'd0; end
        else                      cnt <= cnt + 1'b1;
    end
endmodule
