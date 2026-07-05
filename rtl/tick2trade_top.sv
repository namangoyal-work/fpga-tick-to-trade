// tick2trade_top.sv — tick-to-trade core: frame in, trade decision out
//
// Pure integration, no logic of its own. The parser stages and the trigger
// all pass the byte stream through combinationally, so every stage sees byte
// N on the same cycle and every per-stage byte counter stays in lockstep —
// the property that makes fixed compile-time byte offsets correct.
//
// Ingress is never backpressured (s_tready is tied high): market data cannot
// be stalled, so the core is designed to keep up at one byte per cycle
// unconditionally. Egress (m_*) carries 16-byte TTD-16 decision records and
// tolerates arbitrary downstream stall via the emitter's internal queue.

`default_nettype none

module tick2trade_top #(
    parameter logic [47:0] MY_MAC      = 48'h02_00_00_C0_FF_EE,
    parameter logic [15:0] LISTEN_PORT = 16'd47100,
    parameter logic [15:0] SYMBOL_ID   = 16'h0001,
    parameter logic [31:0] BUY_THRESH  = 32'd1_000_000,
    parameter logic [31:0] SELL_THRESH = 32'd1_010_000,
    parameter logic [15:0] MAX_QTY     = 16'd100,
    parameter int unsigned LATENCY     = 5
) (
    input  wire        clk,
    input  wire        rst_n,

    // market-data frame ingress (byte-wide AXI-Stream; never backpressured)
    input  wire  [7:0] s_tdata,
    input  wire        s_tvalid,
    input  wire        s_tlast,
    output wire        s_tready,

    // decision-record egress (byte-wide AXI-Stream, DMA-facing)
    output wire  [7:0] m_tdata,
    output wire        m_tvalid,
    output wire        m_tlast,
    input  wire        m_tready,

    // observability
    output wire        decision_valid,   // one pulse per frame, fixed latency
    output wire  [1:0] decision_action,
    output wire        fire,             // a record was enqueued
    output wire        overflow          // sticky: a record was dropped
);

    // inter-stage stream taps (combinational passthrough end to end)
    logic [7:0] d1, d2, d3, d4;
    logic       v1, v2, v3, v4;
    logic       l1, l2, l3, l4;
    logic       r1, r2, r3, r4;

    // parser verdict flags
    logic mac_ok, eth_type_ok, ip_ok, udp_ok, md_ok;

    // parsed market-data fields
    logic  [3:0] msg_type;
    logic [15:0] symbol_id;
    logic        side;
    logic [31:0] price;
    logic [15:0] qty;
    logic [31:0] seq;

    // trigger decision fields
    logic [15:0] decision_symbol;
    logic [31:0] decision_price;
    logic [15:0] decision_qty;
    logic [31:0] decision_seq;

    eth_parser #(.MY_MAC(MY_MAC)) u_eth (
        .clk(clk), .rst_n(rst_n),
        .s_tdata(s_tdata), .s_tvalid(s_tvalid), .s_tlast(s_tlast), .s_tready(s_tready),
        .m_tdata(d1), .m_tvalid(v1), .m_tlast(l1), .m_tready(r1),
        .mac_ok(mac_ok), .type_ok(eth_type_ok), .hdr_done(), .ethertype()
    );

    ipv4_parser #(.IP_TOTAL_LEN(16'd44)) u_ipv4 (
        .clk(clk), .rst_n(rst_n),
        .s_tdata(d1), .s_tvalid(v1), .s_tlast(l1), .s_tready(r1),
        .m_tdata(d2), .m_tvalid(v2), .m_tlast(l2), .m_tready(r2),
        .ip_ok(ip_ok), .ip_done(), .src_ip(), .dst_ip()
    );

    udp_parser #(.LISTEN_PORT(LISTEN_PORT), .UDP_TOTAL_LEN(16'd24)) u_udp (
        .clk(clk), .rst_n(rst_n),
        .s_tdata(d2), .s_tvalid(v2), .s_tlast(l2), .s_tready(r2),
        .m_tdata(d3), .m_tvalid(v3), .m_tlast(l3), .m_tready(r3),
        .udp_ok(udp_ok), .udp_done(), .src_port(), .dst_port(), .udp_len()
    );

    md_parser u_md (
        .clk(clk), .rst_n(rst_n),
        .s_tdata(d3), .s_tvalid(v3), .s_tlast(l3), .s_tready(r3),
        .m_tdata(d4), .m_tvalid(v4), .m_tlast(l4), .m_tready(r4),
        .md_ok(md_ok), .md_done(),
        .msg_type(msg_type), .symbol_id(symbol_id), .side(side),
        .price(price), .qty(qty), .seq(seq)
    );

    trade_trigger #(
        .SYMBOL_ID(SYMBOL_ID), .BUY_THRESH(BUY_THRESH),
        .SELL_THRESH(SELL_THRESH), .MAX_QTY(MAX_QTY), .LATENCY(LATENCY)
    ) u_trigger (
        .clk(clk), .rst_n(rst_n),
        .s_tdata(d4), .s_tvalid(v4), .s_tlast(l4), .s_tready(r4),
        .m_tdata(), .m_tvalid(), .m_tlast(),
        // the frame stream terminates here: the trigger is the last observer,
        // and a line-rate ingress can never be stalled from inside the core
        .m_tready(1'b1),
        .mac_ok(mac_ok), .eth_type_ok(eth_type_ok), .ip_ok(ip_ok),
        .udp_ok(udp_ok), .md_ok(md_ok),
        .msg_type(msg_type), .symbol_id(symbol_id), .side(side),
        .price(price), .qty(qty), .seq(seq),
        .decision_valid(decision_valid), .decision_action(decision_action),
        .decision_symbol(decision_symbol), .decision_price(decision_price),
        .decision_qty(decision_qty), .decision_seq(decision_seq)
    );

    decision_emitter #(.QUEUE_DEPTH(4)) u_emitter (
        .clk(clk), .rst_n(rst_n),
        .decision_valid(decision_valid), .decision_action(decision_action),
        .decision_symbol(decision_symbol), .decision_price(decision_price),
        .decision_qty(decision_qty), .decision_seq(decision_seq),
        .m_tdata(m_tdata), .m_tvalid(m_tvalid), .m_tlast(m_tlast), .m_tready(m_tready),
        .fire(fire), .overflow(overflow)
    );

endmodule

`default_nettype wire
