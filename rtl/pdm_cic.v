//=============================================================================
// pdm_cic.v
//   4 阶 CIC 抽取滤波器：2MHz 1bit PDM -> 16kHz 16bit PCM
//
//   参数：R = 125（抽取比），N = 4（阶数）
//   增益：DC 增益 = (R*M)^N = 125^4 = 244,140,625
//   位宽：log2(125^4) = 27.9 bit -> 内部用 32bit，足够且有余量
//
//   为什么输入映射成 +1/-1 而不是 0/1：
//     SPH0641 的 PDM 零点对应占空比 50%，映射成 +1/-1 后
//     数字静音 = 0，积分器不会一路累积到溢出（虽然模运算也能算对，
//     但这样 ILA 里看到的值是干净的，调试友好）。
//
//   注意：积分器是无条件累加的，长时间运行后内部必然发生 32bit 回绕，
//   CIC 的数学性质保证「差分后结果仍正确」（Hogenauer 经典结论），
//   这不是 bug，不要去"修"它。
//
//   输出归一化：满量程对应 (R^N)，右移 OUT_SHIFT(=13) 后满量程约 ±29800，
//   正好落在 16bit 有符号范围内。若实测数值偏小，把 OUT_SHIFT 调小。
//=============================================================================
`timescale 1ns / 1ps

module pdm_cic #(
    parameter integer R         = 125,
    parameter integer OUT_SHIFT = 13
)(
    input  wire               clk,        // 50MHz
    input  wire               rst_n,
    input  wire               en,         // 2MHz 采样使能（单拍）
    input  wire               din,        // PDM 数据位
    output reg  signed [15:0] pcm,        // 16kHz / 16bit 有符号 PCM
    output reg                pcm_valid   // 与 pcm 同拍的单周期有效标志
);

    localparam integer DW = 32;
    localparam integer CW = 8;            // 抽取计数器位宽（R<=255）

    //------------------------------------------------------------------
    // 0/1 -> +1/-1，并符号扩展到 32bit
    //------------------------------------------------------------------
    wire signed [1:0]    x2 = din ? 2'sd1 : -2'sd1;
    wire signed [DW-1:0] x  = {{(DW-2){x2[1]}}, x2};

    //------------------------------------------------------------------
    // 积分器级（输入速率 2MHz）
    //------------------------------------------------------------------
    reg signed [DW-1:0] i1, i2, i3, i4;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            i1 <= {DW{1'b0}};
            i2 <= {DW{1'b0}};
            i3 <= {DW{1'b0}};
            i4 <= {DW{1'b0}};
        end else if (en) begin
            i1 <= i1 + x;
            i2 <= i2 + i1;
            i3 <= i3 + i2;
            i4 <= i4 + i3;
        end
    end

    //------------------------------------------------------------------
    // 抽取计数器
    //------------------------------------------------------------------
    reg  [CW-1:0] dcnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            dcnt <= {CW{1'b0}};
        else if (en)
            dcnt <= (dcnt == R-1) ? {CW{1'b0}} : dcnt + 1'b1;
    end

    wire dec = en && (dcnt == R-1);

    //------------------------------------------------------------------
    // 梳状级（输出速率 16kHz）
    //------------------------------------------------------------------
    reg signed [DW-1:0] d1, d2, d3, d4;
    reg signed [DW-1:0] c1, c2, c3, c4;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            d1 <= {DW{1'b0}}; c1 <= {DW{1'b0}};
            d2 <= {DW{1'b0}}; c2 <= {DW{1'b0}};
            d3 <= {DW{1'b0}}; c3 <= {DW{1'b0}};
            d4 <= {DW{1'b0}}; c4 <= {DW{1'b0}};
        end else if (dec) begin
            c1 <= i4 - d1;  d1 <= i4;
            c2 <= c1 - d2;  d2 <= c1;
            c3 <= c2 - d3;  d3 <= c2;
            c4 <= c3 - d4;  d4 <= c3;
        end
    end

    //------------------------------------------------------------------
    // 归一化 + 饱和到 16bit
    //------------------------------------------------------------------
    function signed [15:0] sat16;
        input signed [DW-1:0] v;
        begin
            if (v > 32767)
                sat16 = 16'sh7FFF;
            else if (v < -32768)
                sat16 = 16'sh8000;
            else
                sat16 = v[15:0];
        end
    endfunction

    reg dec_d;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dec_d     <= 1'b0;
            pcm       <= 16'sd0;
            pcm_valid <= 1'b0;
        end else begin
            dec_d     <= dec;
            pcm_valid <= dec_d;
            if (dec_d)
                pcm <= sat16(c4 >>> OUT_SHIFT);
        end
    end

endmodule
