// fpga_top.sv — Arty A7 demonstration wrapper
//
// Not part of the reusable core. Streams a canned MDM-16 QUOTE frame from an
// on-chip ROM into the tick-to-trade core roughly three times a second, with
// switches that corrupt the frame live, and makes the outcome observable two
// ways: LEDs, and the raw 16-byte TTD-16 decision records on the USB-UART
// (115200 8N1 — read them with any serial terminal or the host tool in
// tools/read_decisions.py).
//
//   sw[0]  corrupt the quote price (byte 48): price no longer crosses -> no fire
//   sw[1]  corrupt the IP checksum (byte 24): header reject           -> no fire
//   sw[2]  corrupt the UDP dst port (byte 36): port reject            -> no fire
//   btn[0] reset (active high on the board, inverted here)
//
//   led[0] fire        (stretched ~0.17 s per fired decision)
//   led[1] decision    (stretched pulse per frame verdict, fire or not)
//   led[2] overflow    (sticky: decision queue dropped a record)
//   led[3] heartbeat   (~1.5 Hz: bitstream loaded and clock running)

`default_nettype none

module fpga_top (
    input  wire       CLK100MHZ,
    input  wire [3:0] btn,
    input  wire [3:0] sw,
    output wire [3:0] led,
    output wire       uart_rxd_out   // FPGA TX -> host RX
);

    wire clk   = CLK100MHZ;   // wire, not logic: must track the pad, not sample it once
    wire rst_n = ~btn[0];

    `include "demo_frame_rom.svh"

    // ---- pacing + frame replay -------------------------------------------
    // A frame starts each time the pacer wraps (2^25 cycles = ~0.34 s) and
    // streams at one byte per cycle; the parser sees realistic bursty traffic
    // with long idle gaps rather than an unbroken stream.
    logic [24:0] pace;
    logic        streaming;
    logic [5:0]  idx;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            pace      <= 25'd0;
            streaming <= 1'b0;
            idx       <= 6'd0;
        end else begin
            pace <= pace + 25'd1;
            if (!streaming) begin
                if (pace == 25'd0) begin
                    streaming <= 1'b1;
                    idx       <= 6'd0;
                end
            end else begin
                if (idx == 6'(DEMO_LEN - 1)) streaming <= 1'b0;
                else                         idx <= idx + 6'd1;
            end
        end
    end

    // live corruption: reuse the already-read byte (a constant array index
    // inside always_comb is not portable across simulators)
    logic [7:0] cur;
    always_comb begin
        cur = demo_rom(idx);
        if (sw[0] && idx == 6'd48) cur = cur ^ 8'h80;   // price high byte
        if (sw[1] && idx == 6'd24) cur = cur ^ 8'hFF;   // IP checksum high byte
        if (sw[2] && idx == 6'd36) cur = cur ^ 8'hFF;   // UDP dst port high byte
    end

    // ---- core -------------------------------------------------------------
    wire [7:0] rec_tdata;
    wire       rec_tvalid, rec_tready;
    wire       decision_valid, fire, overflow;

    tick2trade_top #(
        .MY_MAC     (48'h02_00_00_C0_FF_EE),
        .LISTEN_PORT(16'd47100),
        .SYMBOL_ID  (16'h0001),
        .BUY_THRESH (32'd1_000_000),
        .SELL_THRESH(32'd1_010_000),
        .MAX_QTY    (16'd100),
        .LATENCY    (5)
    ) u_core (
        .clk(clk), .rst_n(rst_n),
        .s_tdata(cur), .s_tvalid(streaming),
        .s_tlast(streaming && idx == 6'(DEMO_LEN - 1)), .s_tready(),
        .m_tdata(rec_tdata), .m_tvalid(rec_tvalid), .m_tlast(), .m_tready(rec_tready),
        .decision_valid(decision_valid), .decision_action(),
        .fire(fire), .overflow(overflow)
    );

    // ---- decision records out over the USB-UART ---------------------------
    uart_tx #(.CLK_HZ(100_000_000), .BAUD(115_200)) u_uart (
        .clk(clk), .rst_n(rst_n),
        .s_tdata(rec_tdata), .s_tvalid(rec_tvalid), .s_tready(rec_tready),
        .txd(uart_rxd_out)
    );

    // ---- LEDs --------------------------------------------------------------
    logic [23:0] fire_stretch;
    logic [21:0] dec_stretch;
    logic [25:0] beat;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            fire_stretch <= 24'd0;
            dec_stretch  <= 22'd0;
            beat         <= 26'd0;
        end else begin
            beat <= beat + 26'd1;
            if (fire)                     fire_stretch <= 24'hFFFFFF;
            else if (fire_stretch != 0)   fire_stretch <= fire_stretch - 24'd1;
            if (decision_valid)           dec_stretch  <= 22'h3FFFFF;
            else if (dec_stretch != 0)    dec_stretch  <= dec_stretch - 22'd1;
        end
    end

    assign led[0] = (fire_stretch != 24'd0);
    assign led[1] = (dec_stretch != 22'd0);
    assign led[2] = overflow;
    assign led[3] = beat[25];

endmodule

`default_nettype wire
