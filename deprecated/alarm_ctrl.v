//=============================================================================
// alarm_ctrl.v
//   LED 电平柱 + 蜂鸣器报警
//
//   去抖动的思路（很重要，否则打呼噜没报警、翻个身倒报警了）：
//     必须连续 CNT_ON 帧（默认 4 帧 = 128ms）都超过门限才触发，
//     触发后响 BEEP_CYC 个时钟（默认 200ms），响完自动停。
//
//   门限 TH_LV1/2/3 是十六进制数，对应 PCM 峰值，标定方法见 README：
//     安静房间   -> P 大概是 0005~0020
//     正常说话   -> 0200~0800
//     近距离鼾声 -> 0400~2000
//     拍手/咳嗽  -> 3000 以上（会削顶到 7FFF）
//=============================================================================
`timescale 1ns / 1ps

module alarm_ctrl #(
    parameter [15:0]  TH_LV1   = 16'd100,
    parameter [15:0]  TH_LV2   = 16'd400,
    parameter [15:0]  TH_LV3   = 16'd1200,
    parameter integer TH_ON    = 4,
    parameter integer BEEP_CYC = 10_000_000      // 200ms @50MHz
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire       frame_done,
    input  wire [15:0] peak,
    output reg        beep,
    output reg  [2:0] leds
);

    reg [3:0]  hit;
    reg [26:0] btim;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hit  <= 4'd0;
            btim <= 27'd0;
            beep <= 1'b0;
            leds <= 3'b000;
        end else begin
            //---- 电平柱：每帧刷新 ----
            if (frame_done) begin
                leds[0] <= (peak > TH_LV1);
                leds[1] <= (peak > TH_LV2);
                leds[2] <= (peak > TH_LV3);

                //---- 连续超门限计数 ----
                if (peak > TH_LV2) begin
                    if (hit < TH_ON) hit <= hit + 4'd1;
                    if (hit + 4'd1 >= TH_ON && btim == 27'd0)
                        btim <= BEEP_CYC;
                end else begin
                    hit <= 4'd0;
                end
            end

            //---- 蜂鸣器倒计时 ----
            if (btim != 27'd0) begin
                btim <= btim - 27'd1;
                beep <= 1'b1;
            end else begin
                beep <= 1'b0;
            end
        end
    end

endmodule
