//=============================================================================
// uart_rx.v
//   115200 8N1 串口接收器（与 uart_tx.v 配对）
//
//   引脚：板载 CH340 的 PL 侧 RX = T19（见 NAVIGATOR_ZYNQ_IO.xdc 的
//         "USB UART" 段，和 uart_txd=J15 同一组跳线）。
//
//   采样策略（异步串口的常规做法，重点是三处）：
//     ① 输入先打两拍再判断，避免亚稳态；
//     ② 检测到下降沿后不立刻采样，而是等半个位宽，确认仍是低电平
//        才认作起始位 —— 这样任何窄毛刺都被滤掉；
//     ③ 之后每隔一个完整位宽采一次，采样点正好落在每一位的中心，
//        对收发两端的时钟误差（这里约 0.007%）留出接近半位宽的余量。
//
//   50MHz / 115200 = 434.03，取 434。位宽 8.68us，半个位宽 4.34us。
//   接收失败（停止位不是高）时只丢弃这一字节，不输出 valid，不会误判成命令。
//=============================================================================
`timescale 1ns / 1ps

module uart_rx #(
    parameter integer CLK_FREQ = 50_000_000,
    parameter integer BAUD     = 115200
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire       rxd,      // 空闲为高
    output reg  [7:0] data,     // 收到的字节
    output reg        valid     // 单拍脉冲：data 有效
);

    localparam integer DIV  = CLK_FREQ / BAUD;        // 434
    localparam integer HALF = DIV / 2;                // 217

    localparam integer S_IDLE  = 2'd0;
    localparam integer S_START = 2'd1;
    localparam integer S_DATA  = 2'd2;
    localparam integer S_STOP  = 2'd3;

    //------------------------------------------------------------------
    // 输入同步 + 下降沿检测
    //------------------------------------------------------------------
    reg [1:0] rxd_sync;
    reg       rxd_d;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rxd_sync <= 2'b11;
            rxd_d    <= 1'b1;
        end else begin
            rxd_sync <= {rxd_sync[0], rxd};
            rxd_d    <= rxd_sync[1];
        end
    end

    wire fall_edge = rxd_d & ~rxd_sync[1];      // 高 -> 低

    //------------------------------------------------------------------
    // 接收状态机
    //------------------------------------------------------------------
    reg [1:0]  st;
    reg [15:0] cnt;
    reg [2:0]  bit_i;
    reg [7:0]  sh;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st    <= S_IDLE;
            cnt   <= 16'd0;
            bit_i <= 3'd0;
            sh    <= 8'd0;
            data  <= 8'd0;
            valid <= 1'b0;
        end else begin
            valid <= 1'b0;

            case (st)
                S_IDLE: begin
                    if (fall_edge) begin
                        cnt <= 16'd0;
                        st  <= S_START;
                    end
                end

                // 等半个位宽，确认不是毛刺
                S_START: begin
                    if (cnt == HALF) begin
                        cnt <= 16'd0;
                        if (!rxd_sync[1]) begin
                            bit_i <= 3'd0;
                            st    <= S_DATA;
                        end else begin
                            st    <= S_IDLE;    // 高电平回来了，是毛刺
                        end
                    end else begin
                        cnt <= cnt + 16'd1;
                    end
                end

                // 每隔一个位宽在位的中心采样，低位先到
                S_DATA: begin
                    if (cnt == DIV - 1) begin
                        cnt <= 16'd0;
                        sh  <= {rxd_sync[1], sh[7:1]};
                        if (bit_i == 3'd7) st <= S_STOP;
                        else               bit_i <= bit_i + 3'd1;
                    end else begin
                        cnt <= cnt + 16'd1;
                    end
                end

                // 停止位中点再看一眼：高才算这一帧有效
                S_STOP: begin
                    if (cnt == HALF) begin
                        cnt <= 16'd0;
                        if (rxd_sync[1]) begin
                            data  <= sh;        // 此时 sh 已收齐 8 位
                            valid <= 1'b1;
                        end
                        st <= S_IDLE;
                    end else begin
                        cnt <= cnt + 16'd1;
                    end
                end

                default: st <= S_IDLE;
            endcase
        end
    end

endmodule
