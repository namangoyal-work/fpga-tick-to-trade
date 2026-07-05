// ipv4_parser.sv — IPv4 header observer (frame bytes 14..33)
//
// Validates, in flight:
//   * version/IHL == 0x45 (IPv4, 20-byte header, no options)
//   * protocol   == 0x11 (UDP)
//   * not a fragment (MF clear, fragment offset zero)
//   * total length == IP_TOTAL_LEN (exactly one fixed-size datagram, v1 wire format)
//   * header checksum verifies (ones'-complement sum over all ten words == 0xFFFF)
//
// The checksum fold is pipelined across three cycles (bytes 34/35/36) so the
// carry chain terminates in a local register instead of feeding the trigger.
//
// Because options and fragments are rejected, all field offsets are fixed
// compile-time constants against the frame byte counter.

`default_nettype none

module ipv4_parser #(
    // 20 (IP header) + 8 (UDP header) + 16 (market-data message) = 44
    parameter logic [15:0] IP_TOTAL_LEN = 16'd44
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
    output logic        ip_ok,      // all IPv4 checks passed
    output logic        ip_done,    // checks finalized this frame (from byte 36)
    output logic [31:0] src_ip,
    output logic [31:0] dst_ip
);

    assign m_tdata  = s_tdata;
    assign m_tvalid = s_tvalid;
    assign m_tlast  = s_tlast;
    assign s_tready = m_tready;

    wire beat = s_tvalid && s_tready;

    // Runs past the last field (byte 33) so the pipelined checksum fold has
    // distinct cycles to fire in (counts 34, 35, 36); saturates at 40.
    logic [5:0] count;

    logic        ver_ihl_ok;
    logic        proto_ok;
    logic        nofrag_ok;
    logic        len_ok;
    logic [15:0] total_len;

    // 32-bit accumulator: carries from summing ten 16-bit words collect in the
    // upper bits losslessly; the ones'-complement fold happens once, at the end.
    logic [31:0] csum;
    logic [16:0] fold1_r;
    logic [15:0] fold2_r;
    logic        csum_ok_r;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            count      <= 6'd0;
            ver_ihl_ok <= 1'b0;
            proto_ok   <= 1'b0;
            nofrag_ok  <= 1'b0;
            len_ok     <= 1'b0;
            total_len  <= 16'h0000;
            ip_done    <= 1'b0;
            src_ip     <= 32'h0;
            dst_ip     <= 32'h0;
            csum       <= 32'h0;
            fold1_r    <= 17'h0;
            fold2_r    <= 16'h0;
            csum_ok_r  <= 1'b0;
        end else if (beat) begin
            if (s_tlast)            count <= 6'd0;
            else if (count < 6'd40) count <= count + 6'd1;

            if (count == 6'd0) begin
                // per-frame re-init
                ver_ihl_ok <= 1'b0;
                proto_ok   <= 1'b0;
                nofrag_ok  <= 1'b1;   // running AND: assume not-a-fragment until proven otherwise
                len_ok     <= 1'b0;
                ip_done    <= 1'b0;
                csum       <= 32'h0;
            end

            if (count == 6'd14) ver_ihl_ok <= (s_tdata == 8'h45);

            if (count == 6'd16) total_len[15:8] <= s_tdata;
            if (count == 6'd17) begin
                total_len[7:0] <= s_tdata;
                len_ok         <= ({total_len[15:8], s_tdata} == IP_TOTAL_LEN);
            end

            // flags/frag-offset: reject MF or any non-zero offset; DF (bit 6) is fine
            if (count == 6'd20 && (s_tdata & 8'h3F) != 8'h00) nofrag_ok <= 1'b0;
            if (count == 6'd21 && s_tdata != 8'h00)           nofrag_ok <= 1'b0;

            if (count == 6'd23) proto_ok <= (s_tdata == 8'h11);

            if (count >= 6'd26 && count <= 6'd29) src_ip <= {src_ip[23:0], s_tdata};
            if (count >= 6'd30 && count <= 6'd33) dst_ip <= {dst_ip[23:0], s_tdata};

            // Incremental checksum over the whole header, including the stored
            // checksum field: the receiver-side check is sum == 0xFFFF.
            if (count >= 6'd14 && count <= 6'd33) begin
                if (!count[0]) csum <= csum + {16'h0, s_tdata, 8'h00}; // even offset = high byte
                else           csum <= csum + {24'h0, s_tdata};        // odd offset  = low byte
            end

            // Pipelined ones'-complement fold: one short add per cycle.
            if (count == 6'd34) fold1_r   <= {1'b0, csum[15:0]} + {1'b0, csum[31:16]};
            if (count == 6'd35) fold2_r   <= fold1_r[15:0] + {15'b0, fold1_r[16]};
            if (count == 6'd36) begin
                csum_ok_r <= (fold2_r == 16'hFFFF);
                ip_done   <= 1'b1;
            end
        end
    end

    assign ip_ok = ip_done && ver_ihl_ok && proto_ok && nofrag_ok && len_ok && csum_ok_r;

endmodule

`default_nettype wire
