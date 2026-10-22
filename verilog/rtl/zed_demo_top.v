// -----------------------------------------------------------------------------
// zed_demo_top : on-board demo for the Zedboard (XC7Z020-CLG484-1, 100 MHz GCLK)
//
//   The 1000 test images (test_images.mem) live in block RAM.
//   BTNC   : classify the next image (one press = one image)
//   SW[0]  : 1 = free-running, one image every ~0.5 s
//   BTNU   : reset (image counter back to 0)
//   LD[3:0]: hardware prediction (binary)      LD[7:4]: true label (binary)
//   -> the two nibbles should be equal whenever the net is right (97.2 % here).
//
// No PS/ARM involvement: pure PL design, so no block design is needed.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
module zed_demo_top #(
    parameter DEB_CYCLES  = 1000000,     // debounce, 10 ms @ 100 MHz
    parameter AUTO_CYCLES = 50000000,    // auto mode period, 0.5 s (must be > ~7100)
    parameter N_IMG       = 1000,
    parameter IMG_FILE    = "test_images.mem",
    parameter LBL_FILE    = "test_labels.mem"
)(
    input  wire       GCLK,
    input  wire       BTNC,
    input  wire       BTNU,
    input  wire [7:0] SW,
    output wire [7:0] LD
);
    wire clk = GCLK;

    // ----- power-on reset + debounced reset button
    reg [3:0] por_cnt = 4'd0;
    wire por = ~&por_cnt;
    always @(posedge clk) if (por) por_cnt <= por_cnt + 1'b1;
    wire rst_btn;
    btn_debounce #(.CYC(DEB_CYCLES)) u_db_rst (.clk(clk), .in(BTNU), .out(rst_btn));
    wire rst = por | rst_btn;

    // ----- debounced "next" button, rising-edge pulse
    wire btnc_clean;
    btn_debounce #(.CYC(DEB_CYCLES)) u_db_c (.clk(clk), .in(BTNC), .out(btnc_clean));
    reg btnc_d = 1'b0;
    always @(posedge clk) btnc_d <= btnc_clean;
    wire c_rise = btnc_clean & ~btnc_d;

    // ----- auto-advance timer
    reg [31:0] auto_cnt = 32'd0;
    wire auto_tick = SW[0] && (auto_cnt == AUTO_CYCLES - 1);
    always @(posedge clk) begin
        if (rst || !SW[0] || auto_cnt == AUTO_CYCLES - 1) auto_cnt <= 32'd0;
        else                                              auto_cnt <= auto_cnt + 1'b1;
    end

    // ----- image / label ROM (registered read -> block RAM)
    (* rom_style = "block" *) reg [783:0] img_rom [0:N_IMG-1];
    reg [3:0]   lbl_rom [0:N_IMG-1];
    initial begin
        $readmemb(IMG_FILE, img_rom);
        $readmemh(LBL_FILE, lbl_rom);
    end
    reg [9:0]   idx = 10'd0;
    reg [783:0] img_q;
    reg [3:0]   lbl_q;
    always @(posedge clk) begin
        img_q <= img_rom[idx];
        lbl_q <= lbl_rom[idx];
    end

    // .mem line char k is bit [783-k]; the net wants pix[k] = pixel k
    wire [783:0] pix;
    genvar gi;
    generate for (gi = 0; gi < 784; gi = gi + 1) begin : g_pix
        assign pix[gi] = img_q[783-gi];
    end endgenerate

    // ----- BNN
    reg        start_r = 1'b0;
    wire       bnn_done, bnn_busy;
    wire [3:0] bnn_pred;
    wire signed [11:0] bnn_score;
    bnn_top u_bnn (.clk(clk), .rst(rst), .start(start_r), .pix(pix),
                   .busy(bnn_busy), .done(bnn_done), .pred(bnn_pred), .score(bnn_score));

    // ----- sequencer
    reg       running = 1'b0;
    reg [3:0] pred_led = 4'd0, lbl_led = 4'd0;
    always @(posedge clk) begin
        start_r <= 1'b0;
        if (rst) begin
            running <= 1'b0; idx <= 10'd0; pred_led <= 4'd0; lbl_led <= 4'd0;
        end else if (!running) begin
            if (c_rise || auto_tick) begin start_r <= 1'b1; running <= 1'b1; end
        end else if (bnn_done) begin
            pred_led <= bnn_pred;
            lbl_led  <= lbl_q;
            idx      <= (idx == N_IMG - 1) ? 10'd0 : idx + 1'b1;
            running  <= 1'b0;
        end
    end

    assign LD = {lbl_led, pred_led};
endmodule
