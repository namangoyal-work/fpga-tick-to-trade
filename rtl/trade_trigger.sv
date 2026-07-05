// trade_trigger.sv — fixed-latency trade decision engine
//
// Watches the same byte stream as the parsers and, for every completed frame
// (or runt), emits exactly one decision at a constant offset: LATENCY cycles
// after the anchor beat (frame byte 57, the last MDM-16 byte). The decision
// is data-independent in *time* — accept, reject, and runt all produce their
// verdict on the same cycle — which is what makes the engine's latency a
// number rather than a distribution.
//
// Strategy (v1): single-symbol threshold crossing.
//   * QUOTE, side==ASK, price <= BUY_THRESH   -> BUY  (lift the offer)
//   * QUOTE, side==BID, price >= SELL_THRESH  -> SELL (hit the bid)
// Order quantity is the message quantity capped at MAX_QTY (risk limit).
//
// Fail-closed: any header/payload check failure, unknown message type,
// symbol mismatch, or runt frame yields action NONE. The no-fire-without-
// validation property is proven formally (see `ifdef FORMAL below).

`default_nettype none

module trade_trigger #(
    parameter logic [15:0] SYMBOL_ID   = 16'h0001,
    parameter logic [31:0] BUY_THRESH  = 32'd1_000_000,  // ticks of 1e-4
    parameter logic [31:0] SELL_THRESH = 32'd1_010_000,
    parameter logic [15:0] MAX_QTY     = 16'd100,
    parameter int unsigned LATENCY     = 5               // anchor beat -> decision_valid
) (
    input  wire        clk,
    input  wire        rst_n,

    // slave (input) side — observer tap, combinational passthrough
    input  wire  [7:0] s_tdata,
    input  wire        s_tvalid,
    input  wire        s_tlast,
    output wire        s_tready,
    output wire  [7:0] m_tdata,
    output wire        m_tvalid,
    output wire        m_tlast,
    input  wire        m_tready,

    // validation flags from the parser stages (registered in their modules)
    input  wire        mac_ok,
    input  wire        eth_type_ok,
    input  wire        ip_ok,
    input  wire        udp_ok,
    input  wire        md_ok,

    // parsed market-data fields (registered in md_parser, stable at anchor+1)
    input  wire  [3:0] msg_type,
    input  wire [15:0] symbol_id,
    input  wire        side,        // 0=BID, 1=ASK
    input  wire [31:0] price,
    input  wire [15:0] qty,
    input  wire [31:0] seq,

    // decision output: one pulse per frame, exactly LATENCY cycles after anchor
    output logic        decision_valid,
    output logic  [1:0] decision_action,   // 00=NONE, 01=BUY, 10=SELL
    output logic [15:0] decision_symbol,
    output logic [31:0] decision_price,
    output logic [15:0] decision_qty,
    output logic [31:0] decision_seq
);

    localparam logic [1:0] ACT_NONE = 2'b00;
    localparam logic [1:0] ACT_BUY  = 2'b01;
    localparam logic [1:0] ACT_SELL = 2'b10;

    // Record registers are sampled once per frame at anchor+1 and must survive
    // until the decision emerges at anchor+LATENCY; the next frame's earliest
    // field write lands ~44 cycles after the anchor, so LATENCY is bounded well
    // below that with margin.
    initial begin
        if (LATENCY < 2 || LATENCY > 16)
            $fatal(1, "trade_trigger: LATENCY must be in [2,16]");
    end

    assign m_tdata  = s_tdata;
    assign m_tvalid = s_tvalid;
    assign m_tlast  = s_tlast;
    assign s_tready = m_tready;

    wire beat = s_tvalid && s_tready;

    logic [5:0] count;   // lockstep with the parser counters; saturates at 58

    // Anchor: the beat that carries frame byte 57 (last MDM-16 byte).
    // Runt: the frame ended before its header+payload completed.
    wire hdr_event  = beat && (count == 6'd57);
    wire runt_event = beat && s_tlast && (count < 6'd57);

    logic ev_q, runt_q;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            count  <= 6'd0;
            ev_q   <= 1'b0;
            runt_q <= 1'b0;
        end else begin
            if (beat) begin
                if (s_tlast)            count <= 6'd0;
                else if (count < 6'd58) count <= count + 6'd1;
            end
            // registered one cycle so the flags/fields captured on the anchor
            // beat have settled into the parser flip-flops before sampling
            ev_q   <= hdr_event;
            runt_q <= runt_event;
        end
    end

    wire flags_all = mac_ok && eth_type_ok && ip_ok && udp_ok && md_ok;
    wire sym_hit   = (symbol_id == SYMBOL_ID);
    wire is_quote  = (msg_type == 4'd1);
    wire want_buy  = (side == 1'b1) && (price <= BUY_THRESH);
    wire want_sell = (side == 1'b0) && (price >= SELL_THRESH);

    // Reject-unless-proven-good: a runt overrides everything, then every
    // validation flag must be high before price logic is even consulted.
    logic [1:0] action_now;
    always_comb begin
        action_now = ACT_NONE;
        if (!runt_q && flags_all && sym_hit && is_quote) begin
            if      (want_buy)  action_now = ACT_BUY;
            else if (want_sell) action_now = ACT_SELL;
        end
    end

    wire [15:0] qty_capped = (qty > MAX_QTY) ? MAX_QTY : qty;

    // Delay line: verdict-due bit and action travel in lockstep. Record fields
    // are captured once at anchor+1; at most one decision is in flight because
    // frames are >= 58 beats apart while LATENCY <= 16.
    localparam int unsigned P = LATENCY - 1;

    logic [P-1:0] v_pipe;
    logic [1:0]   a_pipe [0:P-1];
    logic [15:0]  rec_symbol;
    logic [31:0]        rec_price;
    logic [15:0]        rec_qty;
    logic [31:0]        rec_seq;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            v_pipe     <= '0;
            for (int i = 0; i < P; i++) a_pipe[i] <= 2'b00;
            rec_symbol <= 16'h0000;
            rec_price  <= 32'h0;
            rec_qty    <= 16'h0000;
            rec_seq    <= 32'h0;
        end else begin
            v_pipe[0] <= ev_q || runt_q;
            a_pipe[0] <= action_now;
            for (int i = 1; i < P; i++) begin
                v_pipe[i] <= v_pipe[i-1];
                a_pipe[i] <= a_pipe[i-1];
            end
            if (ev_q) begin
                rec_symbol <= symbol_id;
                rec_price  <= price;
                rec_qty    <= qty_capped;
                rec_seq    <= seq;
            end
        end
    end

    assign decision_valid  = v_pipe[P-1];
    assign decision_action = a_pipe[P-1];
    assign decision_symbol = rec_symbol;
    assign decision_price  = rec_price;
    assign decision_qty    = rec_qty;
    assign decision_seq    = rec_seq;

`ifdef FORMAL
    // Environment: start in reset, release it after one cycle, no re-reset.
    logic f_past_valid = 1'b0;
    logic [7:0] f_cycles = 8'd0;
    always_ff @(posedge clk) begin
        f_past_valid <= 1'b1;
        if (f_cycles != 8'hFF) f_cycles <= f_cycles + 8'd1;
    end
    initial assume (!rst_n);
    always_comb if (f_past_valid) assume (rst_n);

    // Upstream obeys AXI-Stream: a stalled offer stays stable.
    always_ff @(posedge clk) begin
        if (f_cycles >= 8'd2 && $past(s_tvalid && !s_tready)) begin
            assume (s_tvalid);
            assume ($stable(s_tdata));
            assume ($stable(s_tlast));
        end
    end

    // P1 — fixed latency: a decision emerges exactly LATENCY cycles after an
    // anchor or runt event, and never otherwise.
    always_ff @(posedge clk) begin
        if (f_cycles > 8'(LATENCY + 1))
            assert (decision_valid == $past(hdr_event || runt_event, LATENCY));
    end

    // P2 — no fire without validation: any non-NONE action implies that, at
    // sampling time (LATENCY-1 cycles earlier), every parser flag was high,
    // the symbol matched, the message was a QUOTE, and the frame was not a runt.
    always_ff @(posedge clk) begin
        if (f_cycles > 8'(LATENCY + 1)) begin
            if (decision_valid && decision_action != ACT_NONE)
                assert ($past(flags_all && sym_hit && is_quote && !runt_q, LATENCY - 1));
        end
    end

    // P3 — risk limit: an emitted quantity never exceeds MAX_QTY.
    always_ff @(posedge clk) begin
        if (f_past_valid && rst_n)
            assert (rec_qty <= MAX_QTY);
    end
`endif

endmodule

`default_nettype wire
