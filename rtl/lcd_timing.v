//=============================================================================
// lcd_timing.v
//   ATK-4384（4.3 寸 800x480 RGB 屏）行场时序发生器
//
//   参数来源（两处独立资料互相印证，不是我猜的）：
//     ① 《领航者ZYNQ之FPGA开发指南V3.4》表 29.1.3「不同分辨率的LCD屏时序参数」
//     ② 官方课件《第24讲 RGB LCD彩条显示实验》第 12 页
//     800*480 一行：行同步 128 + 后沿 88 + 有效 800 + 前沿 40 = 1056
//     800*480 一帧：场同步   2 + 后沿 33 + 有效 480 + 前沿 10 = 525
//
//   时钟取 25MHz（官方例程对 4384 也是给 25MHz，见 表 29.4.2）：
//     刷新率 = 25e6 / (1056*525) = 45.1Hz
//   比表里的 33.3MHz(60Hz) 低一些，但官方在**这块板 + 这块屏**上验证过，
//   45Hz 能稳定显示。用 25MHz 的好处是只要二分频、不需要 MMCM，
//   第一版先把"能亮"这件事做稳，需要更顺滑再换 MMCM 出 33.3MHz。
//
//   同步方式：DE 模式（官方例程同为 DE 模式）
//     官方原话：「当选择 DE 同步模式时，此时行场同步信号 VSYNC 和 HSYNC
//     必须为高电平」——所以 hs/vs 恒为 1，靠 DE 框出有效区域。
//
//   像素流水线（决定画面会不会左右偏一列）：
//     h_cnt/v_cnt 计数 -> 组合出 x/y -> 打一拍得 xpos/ypos + de_r
//     -> 显示模块据此算出颜色再打一拍 -> 顶层把 de_r 也再延一拍
//     两级延迟严格对齐，颜色和 DE 指向同一个像素。
//=============================================================================
`timescale 1ns / 1ps

module lcd_timing #(
    parameter integer H_SYNC  = 128,
    parameter integer H_BACK  = 88,
    parameter integer H_DISP  = 800,
    parameter integer H_TOTAL = 1056,
    parameter integer V_SYNC  = 2,
    parameter integer V_BACK  = 33,
    parameter integer V_DISP  = 480,
    parameter integer V_TOTAL = 525
)(
    input  wire        clk,        // 像素时钟 25MHz
    input  wire        rst_n,
    output wire        lcd_clk,    // 送屏的像素时钟
    output wire        lcd_hs,     // DE 模式下恒为 1
    output wire        lcd_vs,     // DE 模式下恒为 1
    output reg         de_r,       // 与 xpos/ypos 同拍的 DE
    output reg  [10:0] xpos,       // 0 ~ H_DISP-1
    output reg  [10:0] ypos        // 0 ~ V_DISP-1
);

    localparam integer H_VAL0 = H_SYNC + H_BACK;      // 216
    localparam integer V_VAL0 = V_SYNC + V_BACK;      // 35

    reg [10:0] h_cnt;
    reg [10:0] v_cnt;

    //------------------------------------------------------------------
    // 行 / 场计数器
    //------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            h_cnt <= 11'd0;
        else if (h_cnt == H_TOTAL - 1)
            h_cnt <= 11'd0;
        else
            h_cnt <= h_cnt + 11'd1;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            v_cnt <= 11'd0;
        else if (h_cnt == H_TOTAL - 1) begin
            if (v_cnt == V_TOTAL - 1)
                v_cnt <= 11'd0;
            else
                v_cnt <= v_cnt + 11'd1;
        end
    end

    //------------------------------------------------------------------
    // 有效区域判断 + 坐标（组合），随后打一拍输出
    //------------------------------------------------------------------
    wire in_disp = (h_cnt >= H_VAL0) && (h_cnt < H_VAL0 + H_DISP) &&
                   (v_cnt >= V_VAL0) && (v_cnt < V_VAL0 + V_DISP);

    wire [10:0] x_now = h_cnt - H_VAL0;
    wire [10:0] y_now = v_cnt - V_VAL0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            xpos <= 11'd0;
            ypos <= 11'd0;
            de_r <= 1'b0;
        end else begin
            xpos <= x_now;
            ypos <= y_now;
            de_r <= in_disp;
        end
    end

    //------------------------------------------------------------------
    // 直通信号
    //------------------------------------------------------------------
    assign lcd_clk = clk;
    assign lcd_hs  = 1'b1;
    assign lcd_vs  = 1'b1;

endmodule
