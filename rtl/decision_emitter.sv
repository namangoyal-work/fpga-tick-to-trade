// decision_emitter.sv — decision-record queue and AXI-Stream serializer
//
// Accepts one decision per frame from the fixed-latency trigger and, for
// decisions that fire (action != NONE), emits a 16-byte TTD-16 record on a
// byte-wide AXI-Stream. This stream is the hardware/software boundary: a DMA
// engine (or the on-board UART in the demo wrapper) drains it into host
// memory, where the software SPSC ring consumer picks it up.
//
// TTD-16 record layout (see docs/PROTOCOL.md):
//   +0   magic     0x5A
//   +1   action    0x01 = BUY, 0x02 = SELL
//   +2   symbol_id 16-bit, network order
//   +4   price     32-bit, network order
//   +8   qty       16-bit, network order (already risk-capped by the trigger)
//   +10  seq       32-bit, network order (echo of the triggering tick)
//   +14  flags     0x00 (reserved)
//   +15  check     XOR of bytes 0..14 (host-side integrity check)
//
// The trigger can never be backpressured (its latency is the product), so a
// full queue drops the record and raises a sticky overflow flag instead of
// stalling upstream. The queue only fills if decisions fire faster than the
// consumer drains — a condition the host must observe, hence the flag.

`default_nettype none

module decision_emitter #(
    parameter int unsigned QUEUE_DEPTH = 4
) (
    input  wire        clk,
    input  wire        rst_n,

    // from trade_trigger
    input  wire        decision_valid,
    input  wire  [1:0] decision_action,
    input  wire [15:0] decision_symbol,
    input  wire [31:0] decision_price,
    input  wire [15:0] decision_qty,
    input  wire [31:0] decision_seq,

    // decision-record stream (DMA-facing)
    output logic [7:0] m_tdata,
    output wire        m_tvalid,
    output wire        m_tlast,
    input  wire        m_tready,

    output wire        fire,       // pulse: a record was enqueued this cycle
    output logic       overflow    // sticky: a record was lost to a full queue
);

    localparam int unsigned REC_W = 8 + 16 + 32 + 16 + 32;   // action..seq, 104 bits

    wire [REC_W-1:0] enq_rec = {6'b0, decision_action,
                                decision_symbol,
                                decision_price,
                                decision_qty,
                                decision_seq};

    wire want_enq = decision_valid && (decision_action != 2'b00);

    wire             q_full, q_empty;
    wire [REC_W-1:0] q_rd;
    logic            q_pop;

    assign fire = want_enq && !q_full;

    sync_fifo #(.WIDTH(REC_W), .DEPTH(QUEUE_DEPTH)) u_queue (
        .clk     (clk),
        .rst_n   (rst_n),
        .wr_en   (want_enq),
        .wr_data (enq_rec),
        .full    (q_full),
        .rd_en   (q_pop),
        .rd_data (q_rd),
        .empty   (q_empty)
    );

    always_ff @(posedge clk) begin
        if (!rst_n)                    overflow <= 1'b0;
        else if (want_enq && q_full)   overflow <= 1'b1;
    end

    // Serializer: pop one record, walk its 16 bytes, accumulate the XOR check
    // as the bytes go out, emit the accumulated check as byte 15.
    logic             busy;
    logic [3:0]       idx;
    logic [7:0]       chk;
    logic [REC_W-1:0] cur;

    wire [1:0]  cur_action = cur[97:96];
    wire [15:0] cur_symbol = cur[95:80];
    wire [31:0] cur_price  = cur[79:48];
    wire [15:0] cur_qty    = cur[47:32];
    wire [31:0] cur_seq    = cur[31:0];

    assign q_pop    = !q_empty && !busy;
    assign m_tvalid = busy;
    assign m_tlast  = busy && (idx == 4'd15);

    wire out_beat = m_tvalid && m_tready;

    always_comb begin
        case (idx)
            4'd0:    m_tdata = 8'h5A;
            4'd1:    m_tdata = {6'b0, cur_action};
            4'd2:    m_tdata = cur_symbol[15:8];
            4'd3:    m_tdata = cur_symbol[7:0];
            4'd4:    m_tdata = cur_price[31:24];
            4'd5:    m_tdata = cur_price[23:16];
            4'd6:    m_tdata = cur_price[15:8];
            4'd7:    m_tdata = cur_price[7:0];
            4'd8:    m_tdata = cur_qty[15:8];
            4'd9:    m_tdata = cur_qty[7:0];
            4'd10:   m_tdata = cur_seq[31:24];
            4'd11:   m_tdata = cur_seq[23:16];
            4'd12:   m_tdata = cur_seq[15:8];
            4'd13:   m_tdata = cur_seq[7:0];
            4'd14:   m_tdata = 8'h00;
            default: m_tdata = chk;   // byte 15: XOR of bytes 0..14
        endcase
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            busy <= 1'b0;
            idx  <= 4'd0;
            chk  <= 8'h00;
            cur  <= '0;
        end else begin
            if (q_pop) begin
                cur  <= q_rd;
                busy <= 1'b1;
                idx  <= 4'd0;
                chk  <= 8'h00;
            end else if (out_beat) begin
                if (idx == 4'd15) busy <= 1'b0;
                else begin
                    chk <= chk ^ m_tdata;
                    idx <= idx + 4'd1;
                end
            end
        end
    end

endmodule

`default_nettype wire
