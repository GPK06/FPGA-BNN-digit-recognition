// Smoke test of the Zedboard wrapper (button path + auto mode) with shortened timers.
`timescale 1ns/1ps
module tb_zed_demo;
    localparam AUTO = 10000;
    reg GCLK = 1'b0, BTNC = 1'b0, BTNU = 1'b0;
    reg [7:0] SW = 8'd0;
    wire [7:0] LD;
    zed_demo_top #(.DEB_CYCLES(4), .AUTO_CYCLES(AUTO)) dut (
        .GCLK(GCLK), .BTNC(BTNC), .BTNU(BTNU), .SW(SW), .LD(LD));
    always #5 GCLK = ~GCLK;

    reg [3:0] exp_mem [0:999];
    reg [3:0] lbl_mem [0:999];
    integer errors = 0;

    task check(input integer img);
        begin
            if (LD[3:0] !== exp_mem[img] || LD[7:4] !== lbl_mem[img]) begin
                errors = errors + 1;
                $display("image %0d: LD=%b (pred %0d, label %0d)  expected pred %0d label %0d  <-- FAIL",
                         img, LD, LD[3:0], LD[7:4], exp_mem[img], lbl_mem[img]);
            end else
                $display("image %0d: LD=%b (pred %0d, label %0d)  ok", img, LD, LD[3:0], LD[7:4]);
        end
    endtask

    integer k;
    initial begin
        $readmemh("expected_pred.mem", exp_mem);
        $readmemh("test_labels.mem",   lbl_mem);
        repeat (50) @(posedge GCLK);
        // button path: image 0
        BTNC = 1; repeat (20) @(posedge GCLK); BTNC = 0;
        repeat (8000) @(posedge GCLK);
        check(0);
        // auto mode: images 1..3
        SW[0] = 1;
        repeat (AUTO + 8000) @(posedge GCLK);
        check(1);
        for (k = 2; k <= 3; k = k + 1) begin
            repeat (AUTO) @(posedge GCLK);
            check(k);
        end
        // reset button returns to image 0
        SW[0] = 0; BTNU = 1; repeat (20) @(posedge GCLK); BTNU = 0;
        repeat (50) @(posedge GCLK);
        BTNC = 1; repeat (20) @(posedge GCLK); BTNC = 0;
        repeat (8000) @(posedge GCLK);
        check(0);
        if (errors == 0) $display("ZED DEMO SMOKE TEST PASSED");
        else             $display("ZED DEMO SMOKE TEST FAILED");
        $finish;
    end
endmodule
