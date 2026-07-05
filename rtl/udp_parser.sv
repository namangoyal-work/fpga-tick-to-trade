// udp_parser.sv — UDP header observer (frame bytes 34..41)
//
// Validates, in flight:
//   * destination port == LISTEN_PORT
//   * UDP length == UDP_TOTAL_LEN (header + exactly one 16-byte message, v1)
//
// The UDP checksum is deliberately not verified here: it is computed over a
// pseudo-header that borrows IP-layer state, and verifying it would couple
// this stage to the IP parser. See SECURITY.md ("out of scope").

`default_nettype none

module udp_parser #(
    parameter logic [15:0] LISTEN_PORT   = 16'd47100,
    // 8 (UDP header) + 16 (market-data message) = 24
    parameter logic [15:0] UDP_TOTAL_LEN = 16'd24
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
    output logic        udp_ok,     // port and length checks passed
    output logic        udp_done,   // full 8-byte header observed this frame
    output logic [15:0] src_port,
    output logic [15:0] dst_port,
    output logic [15:0] udp_len
);

    assign m_tdata  = s_tdata;
    assign m_tvalid = s_tvalid;
    assign m_tlast  = s_tlast;
    assign s_tready = m_tready;

    wire beat = s_tvalid && s_tready;

    logic [5:0] count;   // saturates at 42; this stage's last field is byte 41

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            count    <= 6'd0;
            udp_done <= 1'b0;
            src_port <= 16'h0000;
            dst_port <= 16'h0000;
            udp_len  <= 16'h0000;
        end else if (beat) begin
            if (s_tlast)            count <= 6'd0;
            else if (count < 6'd42) count <= count + 6'd1;

            if (count == 6'd0) udp_done <= 1'b0;

            // explicit high/low writes make the network byte order unmistakable
            if (count == 6'd34) src_port[15:8] <= s_tdata;
            if (count == 6'd35) src_port[7:0]  <= s_tdata;
            if (count == 6'd36) dst_port[15:8] <= s_tdata;
            if (count == 6'd37) dst_port[7:0]  <= s_tdata;
            if (count == 6'd38) udp_len[15:8]  <= s_tdata;
            if (count == 6'd39) udp_len[7:0]   <= s_tdata;
            if (count == 6'd41) udp_done <= 1'b1;
        end
    end

    assign udp_ok = udp_done && (dst_port == LISTEN_PORT) && (udp_len == UDP_TOTAL_LEN);

endmodule

`default_nettype wire
