// -----------------------------------------------------------------------------
// bnn_layer : one fully-connected binarized layer, time-multiplexed.
//
//   * Processes ONE neuron at a time, CH=64 inputs per clock (XNOR + popcount).
//   * Hidden layer  (IS_OUT=0): y[n] = (x >= T[n]),  x = 2*popcount(XNOR(a,w)) - N_IN
//   * Output layer  (IS_OUT=1): raw x, running argmax, NO thresholds.
//       Neurons are visited in order 0..N_OUT-1 and the best is replaced only
//       on a STRICTLY greater value -> lowest index wins ties (== np.argmax).
//
// BIT ORDER: each line of the W*.mem file is read by $readmemb with the
// LEFTMOST character in the MSB. Input 0 is the leftmost character, so
//   input i  <->  w_row[N_IN-1-i]
// (handled below). Ports a_in / y use "bit i = input / neuron i".
//
// Pipeline (all stages registered, short paths for 100 MHz):
//   BRAM read -> BRAM output reg -> chunk mux + XNOR -> popcount -> accumulate
// Latency per neuron = 2 (fetch) + NC (chunks) + 2 (flush) + 1 (finish) cycles.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
module bnn_layer #(
    parameter N_IN   = 784,
    parameter N_OUT  = 256,
    parameter IS_OUT = 0,
    parameter W_FILE = "W0.mem",
    parameter T_FILE = "T0.mem"
)(
    input  wire                  clk,
    input  wire                  rst,        // synchronous, active high
    input  wire                  start,      // 1-cycle pulse, accepted when idle
    input  wire [N_IN-1:0]       a_in,       // bit i = input i (latched on start)
    output reg                   busy,
    output reg                   done,       // 1-cycle pulse, results valid
    output reg  [N_OUT-1:0]      y,          // hidden layers: bit n = neuron n
    output reg  [3:0]            pred,       // output layer: argmax
    output reg  signed [11:0]    best_val    // output layer: winning raw sum
);
    localparam CH  = 64;
    localparam NC  = (N_IN + CH - 1) / CH;
    localparam PAD = NC * CH - N_IN;
    localparam IW  = (N_OUT > 1) ? $clog2(N_OUT) : 1;
    localparam CW  = (NC    > 1) ? $clog2(NC)    : 1;
    localparam signed [11:0] NIN = N_IN;

    // ---------------------------------------------------------------- ROMs
    reg [N_IN-1:0] wmem [0:N_OUT-1];
    reg [10:0]     tmem [0:N_OUT-1];
    initial begin
        $readmemb(W_FILE, wmem);
        if (IS_OUT == 0) $readmemh(T_FILE, tmem);
    end

    // ------------------------------------------------------------- state
    localparam [2:0] S_IDLE = 0, S_FETCH = 1, S_FETCH2 = 2, S_ACC = 3,
                     S_FL1 = 4, S_FL2 = 5, S_FIN = 6;
    reg [2:0]      st;
    reg [IW-1:0]   n;
    reg [CW-1:0]   c;
    reg [10:0]     acc;
    reg [N_IN-1:0] a_reg;

    // registered ROM reads (infer block RAM + its optional output register)
    reg [N_IN-1:0] w_row, w_row_q;
    reg [10:0]     t_q1, t_q;
    always @(posedge clk) begin
        w_row   <= wmem[n];
        w_row_q <= w_row;
        t_q1    <= tmem[n];
        t_q     <= t_q1;
    end

    // Bit-order handling (no per-clock reversal of the wide weight row):
    //   weight of input i sits at w_row[N_IN-1-i]  ($readmemb: leftmost char = MSB).
    //   Shift the row left by PAD (filling with 1s) -> weight of input i is at
    //   w_big[NC*CH-1-i].  So we reverse the (rarely changing) ACTIVATION vector
    //   the same way:  a_big[NC*CH-1-i] = a_reg[i]  (0 for i >= N_IN).
    //   Padding then gives XNOR(a=0, w=1) = 0 -> contributes nothing.
    wire [NC*CH-1:0] a_big;
    genvar gi;
    generate for (gi = 0; gi < NC*CH; gi = gi + 1) begin : g_rev
        if (gi < N_IN) begin : g_real
            assign a_big[NC*CH-1-gi] = a_reg[gi];
        end else begin : g_pad
            assign a_big[NC*CH-1-gi] = 1'b0;
        end
    end endgenerate

    wire [NC*CH-1:0] w_big;
    generate if (PAD > 0) begin : g_wpad
        assign w_big = {w_row_q, {PAD{1'b1}}};
    end else begin : g_wnopad
        assign w_big = w_row_q;
    end endgenerate

    // chunk c = inputs 64c .. 64c+63 (stored MSB-first, identically in a and w)
    wire [31:0]   cr   = NC - 1 - c;
    wire [CH-1:0] a_ch = a_big[cr*CH +: CH];
    wire [CH-1:0] w_ch = w_big[cr*CH +: CH];
    wire [CH-1:0] xn   = ~(a_ch ^ w_ch);

    // popcount of one byte (SWAR; small adders -> cheap in LUTs, fast in simulation)
    function [3:0] pc8(input [7:0] v);
        reg [7:0] t;
        begin
            t   = v - ((v >> 1) & 8'h55);
            t   = (t & 8'h33) + ((t >> 2) & 8'h33);
            pc8 = {1'b0, t[3:0]} + {1'b0, t[7:4]};
        end
    endfunction

    function [6:0] pc64(input [63:0] v);
        integer g;
        reg [6:0] t;
        begin
            t = 7'd0;
            for (g = 0; g < 8; g = g + 1) t = t + pc8(v[g*8 +: 8]);
            pc64 = t;
        end
    endfunction

    // x = 2*popcount - N_IN   (range -784..+784, fits easily in 12 bits signed)
    wire signed [11:0] x = $signed({acc, 1'b0}) - NIN;

    // ------------------------------------------------ datapath pipeline
    reg [CH-1:0] xn_q;          // stage A: chunk select + XNOR
    reg [6:0]    pc_q;          // stage B: popcount of the chunk
    reg          v_a, v_b;      // valid flags for stage A / B results
    always @(posedge clk) begin
        xn_q <= xn;
        pc_q <= pc64(xn_q);
        v_a  <= rst ? 1'b0 : (st == S_ACC);
        v_b  <= rst ? 1'b0 : v_a;
    end

    // --------------------------------------------------------------- FSM
    always @(posedge clk) begin
        done <= 1'b0;
        if (v_b) acc <= acc + pc_q;               // stage C: accumulate (overridden below at neuron start)
        if (rst) begin
            st <= S_IDLE; busy <= 1'b0; n <= 0; c <= 0; acc <= 0;
            pred <= 4'd0; best_val <= 12'sd0;
        end else begin
            case (st)
            S_IDLE: if (start) begin
                a_reg <= a_in;
                n <= 0; c <= 0; acc <= 0;
                busy <= 1'b1;
                st <= S_FETCH;
            end
            S_FETCH:  st <= S_FETCH2;             // BRAM read
            S_FETCH2: st <= S_ACC;                // BRAM output register -> w_row_q valid
            S_ACC: begin
                if (c == NC-1) st <= S_FL1; else c <= c + 1'b1;
            end
            S_FL1: st <= S_FL2;                   // drain pipeline stage A
            S_FL2: st <= S_FIN;                   // drain stage B (acc final at end of this cycle)
            S_FIN: begin
                if (IS_OUT != 0) begin
                    if (n == 0 || x > best_val) begin   // strict '>' : lowest index wins ties
                        best_val <= x;
                        pred     <= n;
                    end
                end else begin
                    y[n] <= (x >= $signed(t_q));        // signed compare, always >=
                end
                if (n == N_OUT-1) begin
                    busy <= 1'b0; done <= 1'b1; st <= S_IDLE;
                end else begin
                    n <= n + 1'b1; c <= 0; acc <= 0; st <= S_FETCH;
                end
            end
            default: st <= S_IDLE;
            endcase
        end
    end
endmodule
