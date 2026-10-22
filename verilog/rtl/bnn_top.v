// -----------------------------------------------------------------------------
// bnn_top : 784 -> 256 -> 256 -> 10 binarized MLP (chains three bnn_layer).
//   pix[i]  = binarized pixel i (1 = pixel>=128), i = 0 is the top-left pixel,
//             row-major.  NOTE: bit i, not the MSB-first line order of the .mem.
//   start   = 1-cycle pulse (ignored while busy)
//   done    = 1-cycle pulse; pred / score valid while done=1 (and until next start)
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
module bnn_top #(
    parameter W0_FILE = "W0.mem", parameter T0_FILE = "T0.mem",
    parameter W1_FILE = "W1.mem", parameter T1_FILE = "T1.mem",
    parameter W2_FILE = "W2.mem"
)(
    input  wire              clk,
    input  wire              rst,
    input  wire              start,
    input  wire [783:0]      pix,
    output wire              busy,
    output wire              done,
    output wire [3:0]        pred,
    output wire signed [11:0] score
);
    reg run;
    wire go = start & ~run;
    wire d0, d1;
    wire [255:0] y0, y1;

    always @(posedge clk) begin
        if (rst)       run <= 1'b0;
        else if (go)   run <= 1'b1;
        else if (done) run <= 1'b0;
    end
    assign busy = run;

    bnn_layer #(.N_IN(784), .N_OUT(256), .IS_OUT(0), .W_FILE(W0_FILE), .T_FILE(T0_FILE)) u_l0 (
        .clk(clk), .rst(rst), .start(go), .a_in(pix),
        .busy(), .done(d0), .y(y0), .pred(), .best_val());

    bnn_layer #(.N_IN(256), .N_OUT(256), .IS_OUT(0), .W_FILE(W1_FILE), .T_FILE(T1_FILE)) u_l1 (
        .clk(clk), .rst(rst), .start(d0), .a_in(y0),
        .busy(), .done(d1), .y(y1), .pred(), .best_val());

    bnn_layer #(.N_IN(256), .N_OUT(10), .IS_OUT(1), .W_FILE(W2_FILE), .T_FILE("")) u_l2 (
        .clk(clk), .rst(rst), .start(d1), .a_in(y1),
        .busy(), .done(done), .y(), .pred(pred), .best_val(score));
endmodule
