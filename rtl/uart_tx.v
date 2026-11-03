//=============================================================================
// uart_tx.v
//   最简单的 8N1 串口发送器，115200bps @50MHz（分频 434）
//   50e6/115200 = 434.03，误差 0.007%，任何串口助手都能收
//=============================================================================
`timescale 1ns / 1ps

module uart_tx #(
    parameter integer CLK_FREQ = 50_000_000,
    parameter integer BAUD     = 115200
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire [7:0] data,
    input  wire       start,
    output reg        busy,
    output reg        txd
);

    localparam integer DIV = CLK_FREQ / BAUD;

    localparam integer S_IDLE = 1'd0;
    localparam integer S_SEND = 1'd1;

    reg [1:0]  st;
    reg [15:0] cnt;
    reg [3:0]  bit_i;
    reg [9:0]  sh;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st    <= S_IDLE;
            cnt   <= 16'd0;
            bit_i <= 4'd0;
            sh    <= 10'h3FF;
            txd   <= 1'b1;
            busy  <= 1'b0;
        end else begin
            case (st)
                S_IDLE: begin
                    txd  <= 1'b1;
                    busy <= 1'b0;
                    if (start) begin
                        sh    <= {1'b1, data, 1'b0};   // 停止位 + 数据 + 起始位
                        txd   <= 1'b0;                 // 起始位
                        cnt   <= 16'd0;
                        bit_i <= 4'd0;
                        busy  <= 1'b1;
                        st    <= S_SEND;
                    end
                end

                S_SEND: begin
                    if (cnt == DIV-1) begin
                        cnt <= 16'd0;
                        if (bit_i == 4'd9) begin
                            st   <= S_IDLE;
                            busy <= 1'b0;
                            txd  <= 1'b1;
                        end else begin
                            bit_i <= bit_i + 4'd1;
                            txd   <= sh[1];
                            sh    <= {1'b1, sh[9:1]};
                        end
                    end else begin
                        cnt <= cnt + 16'd1;
                    end
                end
            endcase
        end
    end

endmodule
