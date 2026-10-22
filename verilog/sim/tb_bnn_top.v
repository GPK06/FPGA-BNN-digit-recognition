// -----------------------------------------------------------------------------
// Self-checking testbench: runs all N_IMAGES vectors through bnn_top and
// compares with expected_pred.mem (must be 1000/1000 - it was produced by the
// same raw-sum integer model). Also reports accuracy vs test_labels.mem.
//
// The .mem files must be in the simulator's working directory
// (Vivado: <proj>.sim/sim_1/behav/xsim). See README.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
module tb_bnn_top;
    parameter N_IMAGES   = 1000;
    parameter VERBOSE    = 0;          // 1: print every image
    parameter MAX_CYCLES = 20000;      // per-image watchdog

    reg          clk = 1'b0;
    reg          rst = 1'b1;
    reg          start = 1'b0;
    reg  [783:0] pix = 784'd0;
    wire         done, busy;
    wire [3:0]   pred;
    wire signed [11:0] score;

    bnn_top dut (.clk(clk), .rst(rst), .start(start), .pix(pix),
                 .busy(busy), .done(done), .pred(pred), .score(score));

    always #5 clk = ~clk;              // 100 MHz

    reg [783:0] img_mem [0:999];
    reg [3:0]   lbl_mem [0:999];
    reg [3:0]   exp_mem [0:999];

    integer i, k, cyc;
    integer mism_exp, mism_lbl, timeouts, shown;
    integer lat_min, lat_max;
    reg [3:0] p;

    initial begin
        $readmemb("test_images.mem",   img_mem);
        $readmemh("test_labels.mem",   lbl_mem);
        $readmemh("expected_pred.mem", exp_mem);
        mism_exp = 0; mism_lbl = 0; timeouts = 0; shown = 0;
        lat_min = 1 << 30; lat_max = 0;

        repeat (5) @(negedge clk);
        rst = 1'b0;
        repeat (3) @(negedge clk);

        for (i = 0; i < N_IMAGES; i = i + 1) begin
            // line char k (k=0 leftmost) is bit [783-k] after $readmemb -> pixel k
            for (k = 0; k < 784; k = k + 1) pix[k] = img_mem[i][783-k];

            @(negedge clk); start = 1'b1;
            @(negedge clk); start = 1'b0;

            cyc = 1;
            while (!done && cyc < MAX_CYCLES) begin
                @(negedge clk);
                cyc = cyc + 1;
            end

            if (!done) begin
                timeouts = timeouts + 1;
                $display("[%0t] image %0d: TIMEOUT", $time, i);
            end else begin
                p = pred;
                if (cyc < lat_min) lat_min = cyc;
                if (cyc > lat_max) lat_max = cyc;
                if (p !== exp_mem[i]) begin
                    mism_exp = mism_exp + 1;
                    if (shown < 10) begin
                        shown = shown + 1;
                        $display("MISMATCH image %0d: hw=%0d expected=%0d label=%0d score=%0d",
                                 i, p, exp_mem[i], lbl_mem[i], score);
                    end
                end
                if (p !== lbl_mem[i]) mism_lbl = mism_lbl + 1;
                if (VERBOSE)
                    $display("img %4d  hw=%0d exp=%0d label=%0d score=%0d  (%0d cycles) %s",
                             i, p, exp_mem[i], lbl_mem[i], score, cyc,
                             (p === exp_mem[i]) ? "ok" : "<-- MISMATCH");
            end
            if ((i % 100) == 99)
                $display("... %0d/%0d images done, %0d mismatches so far", i+1, N_IMAGES, mism_exp);
            @(negedge clk);   // let done fall before next start
        end

        $display("======================================================");
        $display(" images run              : %0d", N_IMAGES);
        $display(" match vs expected_pred  : %0d / %0d", N_IMAGES - mism_exp - timeouts, N_IMAGES);
        $display(" accuracy vs test_labels : %0d / %0d (%0d.%0d %%)", N_IMAGES - mism_lbl - timeouts, N_IMAGES,
                 (N_IMAGES - mism_lbl - timeouts) * 100 / N_IMAGES,
                 ((N_IMAGES - mism_lbl - timeouts) * 1000 / N_IMAGES) % 10);
        $display(" latency (cycles/image)  : min %0d  max %0d  (= %0d ns @100MHz)", lat_min, lat_max, lat_max*10);
        $display(" timeouts                : %0d", timeouts);
        if (mism_exp == 0 && timeouts == 0) $display(" RESULT: TEST PASSED (bit-exact)");
        else                                $display(" RESULT: TEST FAILED");
        $display("======================================================");
        $finish;
    end
endmodule
