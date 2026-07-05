// uart_tx.sv — 8N1 UART transmitter with an AXI-Stream byte input
//
// Board-demo transport: drains the decision-record stream to the host over
// the Arty's USB-UART so decision records can be observed with nothing but a
// serial terminal. Not part of the reusable core (a real deployment drains
// the record stream over DMA).

`default_nettype none

module uart_tx #(
    parameter int unsigned CLK_HZ = 100_000_000,
    parameter int unsigned BAUD   = 115_200
) (
    input  wire       clk,
    input  wire       rst_n,

    input  wire [7:0] s_tdata,
    input  wire       s_tvalid,
    output wire       s_tready,

    output logic      txd
);

    localparam int unsigned DIV = CLK_HZ / BAUD;

    logic [$clog2(DIV)-1:0] baud_cnt;
    logic [3:0]             bit_idx;   // 0 = start, 1..8 = data, 9 = stop
    logic [7:0]             sh;
    logic                   busy;

    assign s_tready = !busy;

    wire tick = (baud_cnt == DIV - 1);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            baud_cnt <= '0;
            bit_idx  <= 4'd0;
            sh       <= 8'h00;
            busy     <= 1'b0;
            txd      <= 1'b1;   // line idles high
        end else if (!busy) begin
            txd      <= 1'b1;
            baud_cnt <= '0;
            if (s_tvalid) begin
                sh      <= s_tdata;
                bit_idx <= 4'd0;
                busy    <= 1'b1;
                txd     <= 1'b0;   // start bit begins immediately on accept
            end
        end else begin
            baud_cnt <= tick ? '0 : baud_cnt + 1'b1;
            if (tick) begin
                bit_idx <= bit_idx + 4'd1;
                if (bit_idx <= 4'd7) begin
                    txd <= sh[0];          // data bits, LSB first
                    sh  <= {1'b0, sh[7:1]};
                end else if (bit_idx == 4'd8) begin
                    txd <= 1'b1;           // stop bit
                end else begin
                    busy <= 1'b0;          // stop bit complete, line stays high
                end
            end
        end
    end

endmodule

`default_nettype wire
