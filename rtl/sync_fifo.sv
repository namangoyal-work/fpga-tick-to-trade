// sync_fifo.sv — synchronous FIFO, registered occupancy count
//
// Single-clock FIFO used to decouple the fixed-latency trigger (which can
// never stall) from the decision-record serializer (which drains at the pace
// of the downstream consumer). First-word fall-through read semantics:
// rd_data is valid whenever !empty; rd_en pops.

`default_nettype none

module sync_fifo #(
    parameter int unsigned WIDTH = 96,
    parameter int unsigned DEPTH = 4    // must be a power of two
) (
    input  wire              clk,
    input  wire              rst_n,

    input  wire              wr_en,
    input  wire  [WIDTH-1:0] wr_data,
    output wire              full,

    input  wire              rd_en,
    output wire  [WIDTH-1:0] rd_data,
    output wire              empty
);

    localparam int unsigned AW = $clog2(DEPTH);

    initial begin
        if (DEPTH < 2 || (DEPTH & (DEPTH - 1)) != 0)
            $fatal(1, "sync_fifo: DEPTH must be a power of two >= 2");
    end

    logic [WIDTH-1:0] mem [0:DEPTH-1];
    logic [AW-1:0]    wr_ptr, rd_ptr;
    logic [AW:0]      count;   // one bit wider than the pointers: counts 0..DEPTH

    // Guarded internally: an erroneous push/pop against a full/empty FIFO is
    // ignored rather than corrupting the pointers.
    wire do_wr = wr_en && !full;
    wire do_rd = rd_en && !empty;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            wr_ptr <= '0;
            rd_ptr <= '0;
            count  <= '0;
        end else begin
            if (do_wr) begin
                mem[wr_ptr] <= wr_data;
                wr_ptr      <= wr_ptr + 1'b1;
            end
            if (do_rd) rd_ptr <= rd_ptr + 1'b1;

            case ({do_wr, do_rd})
                2'b10:   count <= count + 1'b1;
                2'b01:   count <= count - 1'b1;
                default: count <= count;
            endcase
        end
    end

    assign rd_data = mem[rd_ptr];
    assign full    = (count == (AW+1)'(DEPTH));
    assign empty   = (count == '0);

`ifdef FORMAL
    logic f_past_valid = 1'b0;
    always_ff @(posedge clk) f_past_valid <= 1'b1;
    initial assume (!rst_n);
    always_comb if (f_past_valid) assume (rst_n);

    // Occupancy is bounded and consistent with the flags.
    always_comb begin
        if (rst_n) begin
            assert (count <= (AW+1)'(DEPTH));
            assert (empty == (count == 0));
            assert (full  == (count == (AW+1)'(DEPTH)));
            // pointer/count coherence: occupancy mod DEPTH == pointer distance
            assert (count[AW-1:0] == (wr_ptr - rd_ptr));
        end
    end
`endif

endmodule

`default_nettype wire
