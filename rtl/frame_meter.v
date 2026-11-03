//=============================================================================
// frame_meter.v
//   按帧统计 PCM 的峰值与平均绝对值（帧长 512 点 = 32ms @16kHz）
//
//   peak     : 一帧内 |pcm| 的最大值，对撞击类声音（咳嗽、拍手）敏感
//   mean_abs : 一帧内 |pcm| 的均值，等价于包络，适合看鼾声的起伏节奏
//
//   512 = 2^9，所以均值直接右移 9 位，不需要除法器。
//=============================================================================
`timescale 1ns / 1ps

module frame_meter #(
    parameter integer FRAME_LEN = 512
)(
    input  wire               clk,
    input  wire               rst_n,
    input  wire signed [15:0] pcm,
    input  wire               pcm_valid,
    output reg  [15:0]        peak,
    output reg  [15:0]        mean_abs,
    output reg                frame_done
);

    reg  [9:0]  n;
    reg  [15:0] pk_acc;
    reg  [24:0] sum_acc;              // 512 * 32768 = 1.67e7 -> 25bit

    // |pcm|，注意 -32768 取绝对值后是 0x8000(=32768)，作为无符号数使用没问题
    wire [15:0] a = pcm[15] ? (~pcm + 16'd1) : pcm;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            n          <= 10'd0;
            pk_acc     <= 16'd0;
            sum_acc    <= 25'd0;
            peak       <= 16'd0;
            mean_abs   <= 16'd0;
            frame_done <= 1'b0;
        end else begin
            frame_done <= 1'b0;
            if (pcm_valid) begin
                if (n == FRAME_LEN-1) begin
                    // 最后一拍要把当前样本算进去
                    peak     <= (a > pk_acc) ? a : pk_acc;
                    mean_abs <= (sum_acc + a) >> 9;
                    n        <= 10'd0;
                    pk_acc   <= 16'd0;
                    sum_acc  <= 25'd0;
                    frame_done <= 1'b1;
                end else begin
                    if (a > pk_acc) pk_acc <= a;
                    sum_acc <= sum_acc + a;
                    n       <= n + 10'd1;
                end
            end
        end
    end

endmodule
