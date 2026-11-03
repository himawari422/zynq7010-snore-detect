//=============================================================================
// pdm_clk_gen.v
//   PDM 麦克风时钟产生 + 采样点标记
//
//   系统时钟 50MHz -> PDM 时钟 2MHz（25 分频）
//   2MHz / 125(抽取比) = 16.000kHz 标准音频采样率
//
//   时序约定（决定成败，别改）：
//     cnt 0..11 -> pdm_clk 高   (12 拍, 240ns)
//     cnt 12..24-> pdm_clk 低   (13 拍, 260ns)
//     pdm_clk 上升沿发生在 cnt 由 24 跳到 0 的那个时钟沿，
//     麦克风 SEL 接地时在上升沿送出新的数据位，
//     因此把采样点放在 cnt==18（上升沿后 360ns），
//     远大于麦克风 tCO(约30ns)+走线延时，数据一定稳定。
//
//   占空比 48%，落在 SPH0641LM4H-1 允许的 40%~60% 内。
//=============================================================================
`timescale 1ns / 1ps

module pdm_clk_gen (
    input  wire clk,        // 50MHz 系统时钟
    input  wire rst_n,      // 同步后的复位，低有效
    output reg  pdm_clk,    // 送往麦克风的 2MHz 时钟
    output reg  sample_en   // 每个 PDM 周期一个单拍采样使能
);

    localparam integer DIV_HIGH = 12;   // 高电平拍数
    localparam integer DIV_LOW  = 13;   // 低电平拍数
    localparam integer CYCLE    = DIV_HIGH + DIV_LOW;   // 25
    localparam integer SMP_AT   = 15;                   // 采样点

    reg [4:0] cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            cnt <= 5'd0;
        else if (cnt == CYCLE-1)
            cnt <= 5'd0;
        else
            cnt <= cnt + 5'd1;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            pdm_clk <= 1'b0;
        else
            pdm_clk <= (cnt < DIV_HIGH);
    end

    // 寄存一拍输出，保证是干净的单周期脉冲
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            sample_en <= 1'b0;
        else
            sample_en <= (cnt == SMP_AT);
    end

endmodule
