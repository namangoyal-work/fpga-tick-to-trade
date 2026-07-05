// axis_skid.sv — single-slot AXI-Stream skid buffer (registered elastic stage)
//
// Breaks the combinational tready path between pipeline stages. Upstream sees
// a tready derived from a local register; the one-cycle staleness of that view
// is absorbed by exactly one spare storage slot (the "skid" slot).
//
// Interface: byte-wide AXI-Stream subset (tdata/tvalid/tlast/tready).

`default_nettype none

module axis_skid (
    input  wire        clk,
    input  wire        rst_n,

    // slave (input) side
    input  wire  [7:0] s_tdata,
    input  wire        s_tvalid,
    input  wire        s_tlast,
    output wire        s_tready,

    // master (output) side
    output logic [7:0] m_tdata,
    output logic       m_tvalid,
    output logic       m_tlast,
    input  wire        m_tready
);

    typedef enum logic [0:0] {EMPTY, FULL} state_t;
    state_t state;

    logic [7:0] skid_data;
    logic       skid_last;

    wire s_beat    = s_tvalid && s_tready;
    wire m_beat    = m_tvalid && m_tready;
    wire out_ready = !m_tvalid || m_beat;   // output slot empty, or draining this cycle

    // Ready is a 1-gate decode of a local register: no combinational path from
    // downstream tready to upstream tready through this stage.
    assign s_tready = (state == EMPTY);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state     <= EMPTY;
            m_tdata   <= 8'h00;
            m_tvalid  <= 1'b0;
            m_tlast   <= 1'b0;
            skid_data <= 8'h00;
            skid_last <= 1'b0;
        end else begin
            if (out_ready) begin
                if (state == FULL) begin
                    // drain the spare slot into the output register
                    m_tdata  <= skid_data;
                    m_tlast  <= skid_last;
                    m_tvalid <= 1'b1;
                    state    <= EMPTY;
                end else begin
                    // normal flow-through: a gap in (no beat) is a gap out
                    m_tdata  <= s_tdata;
                    m_tlast  <= s_tlast;
                    m_tvalid <= s_beat;
                end
            end else begin
                // output stalled: the one legally-late byte lands in the skid slot
                if (s_beat) begin
                    skid_data <= s_tdata;
                    skid_last <= s_tlast;
                    state     <= FULL;
                end
            end
        end
    end

`ifdef FORMAL
    logic f_past_valid = 1'b0;
    always_ff @(posedge clk) f_past_valid <= 1'b1;

    initial assume (!rst_n);

    // Environment: upstream obeys AXI-Stream — a stalled offer stays stable.
    always_ff @(posedge clk) begin
        if (f_past_valid && $past(rst_n) && rst_n) begin
            if ($past(s_tvalid && !s_tready)) begin
                assume (s_tvalid);
                assume ($stable(s_tdata));
                assume ($stable(s_tlast));
            end
        end
    end

    always_ff @(posedge clk) begin
        if (f_past_valid && $past(rst_n) && rst_n) begin
            // We obey AXI-Stream on the master side: a stalled offer stays stable.
            if ($past(m_tvalid && !m_tready)) begin
                assert (m_tvalid);
                assert ($stable(m_tdata));
                assert ($stable(m_tlast));
            end
        end
    end

    // Single-slot invariant: while the skid slot is occupied we must not accept.
    always_comb begin
        if (rst_n && state == FULL) assert (!s_tready);
    end
`endif

endmodule

`default_nettype wire
