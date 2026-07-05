// md_parser.sv — MDM-16 market-data message observer (frame bytes 42..57)
//
// MDM-16 is this project's 16-byte fixed-size market-data wire format
// (see docs/PROTOCOL.md). Payload layout, offsets relative to frame byte 42:
//
//   +0   magic      0xA5
//   +1   ver/type   [7:4] version (must be 1), [3:0] type (1=QUOTE, 2=TRADE)
//   +2   symbol_id  16-bit, network order
//   +4   side       0x00 = BID, 0x01 = ASK
//   +5   reserved   must be 0x00
//   +6   price      32-bit unsigned, network order, ticks of 1e-4
//   +10  qty        16-bit unsigned, network order
//   +12  seq        32-bit unsigned, network order (echoed into the decision
//                   record for end-to-end tick-to-trade latency correlation)
//
// All checks are fail-closed: md_ok is only high once the full message has
// streamed past (md_done) with every structural check green.

`default_nettype none

module md_parser (
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
    output logic        md_ok,      // structurally valid MDM-16 message
    output logic        md_done,    // full 16-byte message observed this frame
    output logic  [3:0] msg_type,   // 1=QUOTE, 2=TRADE
    output logic [15:0] symbol_id,
    output logic        side,       // 0=BID, 1=ASK
    output logic [31:0] price,
    output logic [15:0] qty,
    output logic [31:0] seq
);

    assign m_tdata  = s_tdata;
    assign m_tvalid = s_tvalid;
    assign m_tlast  = s_tlast;
    assign s_tready = m_tready;

    wire beat = s_tvalid && s_tready;

    logic [5:0] count;   // saturates at 58; this stage's last field is byte 57

    logic magic_ok;
    logic ver_ok;
    logic type_ok;
    logic side_ok;
    logic resv_ok;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            count     <= 6'd0;
            md_done   <= 1'b0;
            magic_ok  <= 1'b0;
            ver_ok    <= 1'b0;
            type_ok   <= 1'b0;
            side_ok   <= 1'b0;
            resv_ok   <= 1'b0;
            msg_type  <= 4'h0;
            symbol_id <= 16'h0000;
            side      <= 1'b0;
            price     <= 32'h0;
            qty       <= 16'h0000;
            seq       <= 32'h0;
        end else if (beat) begin
            if (s_tlast)            count <= 6'd0;
            else if (count < 6'd58) count <= count + 6'd1;

            if (count == 6'd0) md_done <= 1'b0;

            if (count == 6'd42) magic_ok <= (s_tdata == 8'hA5);
            if (count == 6'd43) begin
                ver_ok   <= (s_tdata[7:4] == 4'd1);
                type_ok  <= (s_tdata[3:0] == 4'd1) || (s_tdata[3:0] == 4'd2);
                msg_type <= s_tdata[3:0];
            end
            if (count == 6'd44) symbol_id[15:8] <= s_tdata;
            if (count == 6'd45) symbol_id[7:0]  <= s_tdata;
            if (count == 6'd46) begin
                side    <= s_tdata[0];
                side_ok <= (s_tdata == 8'h00) || (s_tdata == 8'h01);
            end
            if (count == 6'd47) resv_ok <= (s_tdata == 8'h00);

            if (count >= 6'd48 && count <= 6'd51) price <= {price[23:0], s_tdata};
            if (count == 6'd52) qty[15:8] <= s_tdata;
            if (count == 6'd53) qty[7:0]  <= s_tdata;
            if (count >= 6'd54 && count <= 6'd57) seq <= {seq[23:0], s_tdata};

            if (count == 6'd57) md_done <= 1'b1;
        end
    end

    assign md_ok = md_done && magic_ok && ver_ok && type_ok && side_ok && resv_ok;

endmodule

`default_nettype wire
