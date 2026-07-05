// eth_parser.sv — Ethernet II header observer (frame bytes 0..13)
//
// Taps a byte-wide AXI-Stream and validates, in flight:
//   * destination MAC == MY_MAC, or broadcast (ff:ff:ff:ff:ff:ff)
//   * EtherType == 0x0800 (IPv4)
//
// The stream itself passes through combinationally: this stage is an observer,
// not a buffer. Elasticity, when needed, is a separate module (axis_skid).
//
// Flags are registered and only meaningful once hdr_done is high; they are
// re-initialized at byte 0 of every frame.

`default_nettype none

module eth_parser #(
    parameter logic [47:0] MY_MAC = 48'h02_00_00_C0_FF_EE
) (
    input  wire        clk,
    input  wire        rst_n,

    // slave (input) side
    input  wire  [7:0] s_tdata,
    input  wire        s_tvalid,
    input  wire        s_tlast,
    output wire        s_tready,

    // master (output) side — combinational passthrough
    output wire  [7:0] m_tdata,
    output wire        m_tvalid,
    output wire        m_tlast,
    input  wire        m_tready,

    // parse results (registered)
    output logic        mac_ok,     // dst MAC matched (unicast-to-us or broadcast)
    output logic        type_ok,    // EtherType == IPv4
    output logic        hdr_done,   // full 14-byte header observed this frame
    output logic [15:0] ethertype
);

    assign m_tdata  = s_tdata;
    assign m_tvalid = s_tvalid;
    assign m_tlast  = s_tlast;
    assign s_tready = m_tready;

    wire beat = s_tvalid && s_tready;

    // Byte offset within the frame; saturates at 14 (this stage is done),
    // returns to 0 only at a true frame boundary (tlast).
    logic [3:0] count;

    // Expected destination-MAC byte for the current offset.
    logic [7:0] mac_byte;
    always_comb begin
        case (count)
            4'd0:    mac_byte = MY_MAC[47:40];
            4'd1:    mac_byte = MY_MAC[39:32];
            4'd2:    mac_byte = MY_MAC[31:24];
            4'd3:    mac_byte = MY_MAC[23:16];
            4'd4:    mac_byte = MY_MAC[15:8];
            default: mac_byte = MY_MAC[7:0];
        endcase
    end

    logic mac_match;    // running AND over dst-MAC bytes vs MY_MAC
    logic bcast_match;  // running AND over dst-MAC bytes vs ff:ff:...

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            count       <= 4'd0;
            mac_match   <= 1'b0;
            bcast_match <= 1'b0;
            hdr_done    <= 1'b0;
            ethertype   <= 16'h0000;
        end else if (beat) begin
            if (s_tlast)             count <= 4'd0;
            else if (count < 4'd14)  count <= count + 4'd1;

            if (count == 4'd0) begin
                // running-match baseline: assume match until a byte disproves it
                mac_match   <= (s_tdata == MY_MAC[47:40]);
                bcast_match <= (s_tdata == 8'hFF);
                hdr_done    <= 1'b0;
            end else if (count < 4'd6) begin
                // sticky-false: one mismatching byte disqualifies permanently
                if (s_tdata != mac_byte) mac_match   <= 1'b0;
                if (s_tdata != 8'hFF)    bcast_match <= 1'b0;
            end

            if (count == 4'd12) ethertype[15:8] <= s_tdata;  // network order: MSB first
            if (count == 4'd13) begin
                ethertype[7:0] <= s_tdata;
                hdr_done       <= 1'b1;
            end
        end
    end

    // Verdicts are gated on hdr_done so downstream never reads a partial result.
    assign mac_ok  = hdr_done && (mac_match || bcast_match);
    assign type_ok = hdr_done && (ethertype == 16'h0800);

endmodule

`default_nettype wire
