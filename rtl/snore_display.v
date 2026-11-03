//=============================================================================
// snore_display.v
//   鼾声识别的实时可视化（800x480，无帧缓存，按坐标现算）
//
//   为什么不做帧缓存：
//     800*480*16bit = 768KB，而 XC7Z010 全部 BRAM 只有 264KB，装不下。
//     所以这里不存画面，只存"历史包络值"（1024 个 12bit，约 12Kb），
//     每个像素的颜色由 (xpos,ypos) 当场判断出来。
//     显存需求从 768KB 降到 1.5KB，代价是多几百个比较器。
//
//   屏幕上画了什么（对应判据的每一环）：
//     ┌────────────────────────────────┬──────────────┐
//     │ 滚动包络波形（20 秒窗口）        │ LOUD    [灯] │ ← 判据①响度
//     │ 红色虚线 = 门限 TH               │ LONG    [灯] │ ← 判据②时长
//     │ 过门限的部分画成亮绿             │ RHYTHM  ○○○ │ ← 判据③节律
//     │                                 │  ┌────────┐  │
//     │                                 │  │ SNORE  │  │ ← 判决结果
//     │                                 │  └────────┘  │
//     │                                 │ CNT 0000     │ ← 累计次数
//     │                                 │ ENV 0A3C     │ ← 包络值(与串口一致)
//     └────────────────────────────────┴──────────────┘
//     底部：TH / MIN / GAP / SHIFT 参数，答辩时不用另讲
//
//   第二页（报告页，由 key[0] 切换）：
//     ┌──────────────────────────────────────────────────┐
//     │ SNORE  REPORT                        ATK-4384     │
//     │  EVENTS   0000                                    │
//     │  RATE /H  0180                                    │
//     │  SNORE %  38                                      │
//     │  SILENCE  02                                      │
//     │  LEVEL  [████████████░░░░░░░░░░]         MID      │
//     │  MODERATE: TRY SLEEPING ON YOUR SIDE.             │
//     │  KEEP THE ROOM HUMID, AVOID ALCOHOL.              │
//     │  SCREENING ONLY - NOT A MEDICAL DIAGNOSIS.        │
//     └──────────────────────────────────────────────────┘
//     三档建议在文字层里各占两行（17/18、20/21、23/24），
//     显示时把行号加 3*level 再查表，所以三档都落在同一位置，不会上下跳。
//
//   时钟域：
//     clk 是 25MHz 像素时钟；wr_tgl / env_snap / status_snap / rhythm_snap
//     来自 50MHz 判据域，每帧（32ms）才变一次。
//     用 wr_tgl 做"数据有效"握手：50MHz 侧翻转，这里同步后检边沿，
//     边沿到来时把同一帧的 env/status/rhythm 一起锁进来 ——
//     既解决了跨时钟域，又天然保证"写进波形的那一列"和"灯的状态"是同一帧。
//=============================================================================
`timescale 1ns / 1ps

module snore_display #(
    parameter [15:0] TH = 16'd525          // 与 snore_judge 的门限保持一致
)(
    input  wire        clk,           // 25MHz 像素时钟
    input  wire        rst_n,
    //---- 来自 50MHz 判据域（每帧更新，稳定 32ms）----
    input  wire        wr_tgl,        // 每来一帧翻转一次
    input  wire [15:0] env_snap,      // 该帧的响度包络
    input  wire [3:0]  status_snap,   // bit0响 bit1持续 bit2鼾声 bit3节律
    input  wire [3:0]  rhythm_snap,   // 已积累节律次数
    input  wire        clr_tgl,       // 清零统计：每清一次翻转（跨时钟域用的握手）
    //---- 报告页数据（同样来自 50MHz 域，慢变，走同一套握手）----
    input  wire        page,          // 0 实时页 / 1 报告页
    input  wire [15:0] evt_snap,      // 总判决次数（BCD）
    input  wire [15:0] rate_snap,     // 每小时次数（BCD）
    input  wire [7:0]  ratio_snap,    // 超阈占比 %（BCD 两位）
    input  wire [7:0]  sil_snap,      // 疑似静默次数（BCD 两位）
    input  wire [1:0]  level_snap,    // 0 轻微 / 1 中等 / 2 偏重
    input  wire        nodata_snap,   // 运行不足 1 分钟
    input  wire [13:0] rbar_snap,     // 评级条长度依据
    //---- 像素坐标（已寄存一拍）----
    input  wire [10:0] xpos,
    input  wire [10:0] ypos,
    output reg  [23:0] rgb
);

    //------------------------------------------------------------------
    // 配色（24bit RGB888，屏只用高 5/6/5 位，低位置 0 也无所谓）
    //------------------------------------------------------------------
    localparam [23:0] C_BG      = 24'h06090D;   // 主背景
    localparam [23:0] C_HDR     = 24'h0E1A26;   // 顶栏
    localparam [23:0] C_PANEL   = 24'h0A1219;   // 右侧面板底
    localparam [23:0] C_WAVE    = 24'h0C1620;   // 波形区底
    localparam [23:0] C_GRID    = 24'h16242E;   // 网格
    localparam [23:0] C_BORDER  = 24'h2A4A66;   // 边框
    localparam [23:0] C_WAVELO  = 24'h1E9E52;   // 波形（未过门限）
    localparam [23:0] C_WAVEHI  = 24'h66FF99;   // 波形（过门限）
    localparam [23:0] C_THLINE  = 24'hE04040;   // 门限线
    localparam [23:0] C_LAMPOFF = 24'h18242A;   // 灯灭
    localparam [23:0] C_LOUD    = 24'h30D860;   // 判据①亮
    localparam [23:0] C_LONG    = 24'h40B0FF;   // 判据②亮
    localparam [23:0] C_RHY     = 24'hFFC020;   // 判据③亮
    localparam [23:0] C_VERDON  = 24'hD82020;   // 判决：是鼾声
    localparam [23:0] C_VERDOFF = 24'h14202A;   // 判决：不是
    localparam [23:0] C_FG      = 24'hD8E4EC;   // 文字
    localparam [23:0] C_FGWHITE = 24'hFFFFFF;   // 判决区文字

    //---- 报告页 ----
    localparam [23:0] C_BARBG   = 24'h12202C;   // 评级条底槽
    localparam [23:0] C_LV0     = 24'h30D860;   // 轻微（绿）
    localparam [23:0] C_LV1     = 24'hFFC020;   // 中等（琥珀）
    localparam [23:0] C_LV2     = 24'hE04040;   // 偏重（红）

    //------------------------------------------------------------------
    // 版面坐标
    //------------------------------------------------------------------
    localparam [10:0] WX0 = 11'd8,   WX1 = 11'd647;    // 波形区 x: 640 列
    localparam [10:0] WY0 = 11'd48,  WY1 = 11'd447;    // 波形区 y: 400 行
    localparam [10:0] PX0 = 11'd656, PX1 = 11'd791;    // 右侧面板

    localparam [10:0] LAMP_X0 = 11'd752, LAMP_X1 = 11'd791;

    // 波形纵向：存的是 env>>3，画的时候乘 2 就是 env>>2
    //   门限 525 -> 高度 131 -> 画在 y = 447-131 = 316
    localparam [9:0]  WAVE_HMAX = 10'd400;
    localparam [9:0]  TH_STORE  = TH[15:3];             // 525>>3 = 65
    localparam [9:0]  TH_H      = {TH_STORE[8:0], 1'b0};// 130
    localparam [10:0] TH_Y      = WY1 - TH_H;           // 317（11bit 减法取 10bit 也行）

    //------------------------------------------------------------------
    // 跨时钟域：wr_tgl 同步 + 边沿检测
    //------------------------------------------------------------------
    reg [1:0] tgl_sync;
    reg       tgl_d;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tgl_sync <= 2'b00;
            tgl_d    <= 1'b0;
        end else begin
            tgl_sync <= {tgl_sync[0], wr_tgl};
            tgl_d    <= tgl_sync[1];
        end
    end

    wire new_smp = tgl_sync[1] ^ tgl_d;

    //------------------------------------------------------------------
    // 清零握手的同步：和 wr_tgl 同一套做法
    //   清零脉冲只有 20ns（50MHz 一拍），而这里是 25MHz 域 ——
    //   直接拿电平采会丢，所以顶层把它转成"每清一次翻转一次"的电平，
    //   同步过来再检边沿，保证一次都不漏。
    //------------------------------------------------------------------
    reg [1:0] ctgl_sync;
    reg       ctgl_d;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ctgl_sync <= 2'b00;
            ctgl_d    <= 1'b0;
        end else begin
            ctgl_sync <= {ctgl_sync[0], clr_tgl};
            ctgl_d    <= ctgl_sync[1];
        end
    end

    wire clr_ev = ctgl_sync[1] ^ ctgl_d;

    //------------------------------------------------------------------
    // 历史包络环形缓冲（写读都在 25MHz 域）
    //
    // ★ 必须写成"写在一个 always、读在另一个 always"的形态，Vivado 才会
    //   推断成分布式 RAM（LUTRAM）。如果写和读挤在同一个带复位的 always 里，
    //   综合器会老老实实生成 1024×12 = 12288 个触发器，外加一棵 1024:1 的
    //   异步读多路树 —— 实测那样会多吃掉 5000 多个 LUT、12000 多个 FF。
    //   分开写之后是 192 个 LUTRAM，LUT 占用降到原来的三分之一以下。
    //------------------------------------------------------------------
    (* ram_style = "distributed" *) reg [11:0] mem [0:1023];
    reg [9:0]  wp;

    // 写端口：每帧一列
    always @(posedge clk) begin
        if (new_smp)
            mem[wp] <= env_snap[15:3];
    end

    // 锁存到本域的观测值
    reg [3:0]  st_q;
    reg [3:0]  rh_q;

    // 判决次数，直接存 BCD，省掉二进制转十进制的除法器
    reg [3:0]  d0, d1, d2, d3;

    // 写指针与观测值：只跟新帧有关，不受清零影响
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wp   <= 10'd0;
            st_q <= 4'd0;
            rh_q <= 4'd0;
        end else if (new_smp) begin
            wp   <= wp + 10'd1;
            st_q <= status_snap;
            rh_q <= rhythm_snap;
        end
    end

    // 判决计数：可被按键 key[1] 或串口 'C' 清零
    //   单独一个 always，是因为清零是"事件"，和"新帧到来"不同步，
    //   挤在一起写会让优先级绕不清（清零和新帧同拍时该信谁）。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            d0 <= 4'd0; d1 <= 4'd0; d2 <= 4'd0; d3 <= 4'd0;
        end else if (clr_ev) begin
            d0 <= 4'd0; d1 <= 4'd0; d2 <= 4'd0; d3 <= 4'd0;
        end else if (new_smp && status_snap[2] && !st_q[2]) begin
            // status[2] 上升沿 = 又判出一次鼾声
            if (d0 != 4'd9) begin
                d0 <= d0 + 4'd1;
            end else begin
                d0 <= 4'd0;
                if (d1 != 4'd9) begin
                    d1 <= d1 + 4'd1;
                end else begin
                    d1 <= 4'd0;
                    if (d2 != 4'd9) begin
                        d2 <= d2 + 4'd1;
                    end else begin
                        d2 <= 4'd0;
                        if (d3 != 4'd9) d3 <= d3 + 4'd1;
                    end
                end
            end
        end
    end

    // 波形：最右一列是当前帧，往左是历史
    wire [9:0]  wcol  = xpos[9:0] - WX0[9:0];          // 0~639
    wire [9:0]  waddr = wp + wcol - 10'd640;           // 自动按 1024 回绕
    wire [11:0] wval  = mem[waddr];
    wire [9:0]  whgt  = (wval > 12'd200) ? WAVE_HMAX : {wval[8:0], 1'b0};
    wire [9:0]  wdy   = WY1[9:0] - ypos[9:0];          // 距底部的像素数，0~399
    wire        wabove = (wval > {2'b00, TH_STORE});   // 这一列是否过门限

    //------------------------------------------------------------------
    // 文字层
    //------------------------------------------------------------------
    wire [6:0] cell_col = xpos[9:3];
    wire [4:0] cell_row = ypos[8:4];
    wire [2:0] gx       = xpos[2:0];
    wire [3:0] gy       = ypos[3:0];

    //------------------------------------------------------------------
    // 两个静态文字层：实时页 / 报告页。
    // 报告页的建议文案按 level 选档 —— 把行号加 3*level 再查表，
    // 三档文案就都落在屏幕上同一个位置（17/18 行）。
    //------------------------------------------------------------------
    wire [7:0] ch_static;
    wire [7:0] ch_report;

    text_layer u_text (
        .col (cell_col),
        .row (cell_row),
        .ch  (ch_static)
    );

    wire [4:0] rrow = (cell_row >= 5'd19 && cell_row <= 5'd20)
                      ? (cell_row + {level_snap, 1'b0} + {1'b0, level_snap})
                      : cell_row;

    text_layer_report u_text_rpt (
        .col (cell_col),
        .row (rrow),
        .ch  (ch_report)
    );

    // 十六进制半字节转 ASCII（0-9 / A-F）
    function [7:0] hx;
        input [3:0] v;
        begin
            hx = (v < 10) ? (8'h30 + {4'd0, v}) : (8'h37 + {4'd0, v});
        end
    endfunction

    reg [7:0] ch_sel;

    always @(*) begin
        if (!page) begin
            //=============== 实时页 ===============
            ch_sel = ch_static;

            // CNT：判决次数（BCD）
            if (cell_row == 5'd17) begin
                case (cell_col)
                    7'd86: ch_sel = hx(d3);
                    7'd87: ch_sel = hx(d2);
                    7'd88: ch_sel = hx(d1);
                    7'd89: ch_sel = hx(d0);
                    default: ;
                endcase
            end

            // ENV：本帧包络，十六进制，和串口里的 E 字段完全一致
            if (cell_row == 5'd19) begin
                case (cell_col)
                    7'd86: ch_sel = hx(env_snap[15:12]);
                    7'd87: ch_sel = hx(env_snap[11:8]);
                    7'd88: ch_sel = hx(env_snap[7:4]);
                    7'd89: ch_sel = hx(env_snap[3:0]);
                    default: ;
                endcase
            end

            // RHY：节律计数
            if (cell_row == 5'd21 && cell_col == 7'd86)
                ch_sel = hx(rh_q);
        end else begin
            //=============== 报告页 ===============
            // 标签由文字层给，这里只覆盖数字。数值早已是 BCD，直接拆半字节。
            ch_sel = ch_report;

            // 22~26 行是三档建议的"备选源文案"，只供上面的行偏移取用，
            // 屏幕上永远不直接显示 —— 否则三档会同时出现。
            if (cell_row >= 5'd22 && cell_row <= 5'd26)
                ch_sel = 8'h20;

            case (cell_row)
                5'd4: case (cell_col)          // EVENTS 0000
                    7'd32: ch_sel = hx(evt_snap[15:12]);
                    7'd33: ch_sel = hx(evt_snap[11:8]);
                    7'd34: ch_sel = hx(evt_snap[7:4]);
                    7'd35: ch_sel = hx(evt_snap[3:0]);
                    default: ;
                endcase
                5'd7: case (cell_col)          // RATE /H 0000
                    7'd32: ch_sel = hx(rate_snap[15:12]);
                    7'd33: ch_sel = hx(rate_snap[11:8]);
                    7'd34: ch_sel = hx(rate_snap[7:4]);
                    7'd35: ch_sel = hx(rate_snap[3:0]);
                    default: ;
                endcase
                5'd10: case (cell_col)         // SNORE % 00
                    7'd32: ch_sel = hx(ratio_snap[7:4]);
                    7'd33: ch_sel = hx(ratio_snap[3:0]);
                    default: ;
                endcase
                5'd13: case (cell_col)         // SILENCE 00
                    7'd32: ch_sel = hx(sil_snap[7:4]);
                    7'd33: ch_sel = hx(sil_snap[3:0]);
                    default: ;
                endcase
                default: ;
            endcase

            // 数据还不够时不下结论：把建议那两行留白
            if (nodata_snap && cell_row >= 5'd19 && cell_row <= 5'd20)
                ch_sel = 8'h20;
        end
    end

    wire [7:0] glyph;
    font_rom u_font (
        .ch   (ch_sel),
        .row  (gy),
        .bits (glyph)
    );

    wire pix_on = glyph[7 - gx];

    //------------------------------------------------------------------
    // 大字（2 倍放大）：两页各有一块，共用同一个字库实例
    //   实时页：SNORE / QUIET，5 个字 = 80x32，落在判决框中央
    //   报告页：LOW / MID / HIGH，4 个字 = 64x32，落在评级条右侧
    //   做法是把坐标右移一位再查字库 —— 最近邻放大，不占额外存储。
    //   两页不会同时显示，所以字库实例按 page 复用，综合时仍是两份
    //   （字库是组合 LUT，两个实例才好布线，代价约 200 个 LUT）。
    //------------------------------------------------------------------
    localparam [10:0] BG_X0 = 11'd684;      // 实时页判决大字
    localparam [10:0] BG_Y0 = 11'd184;
    localparam [10:0] LV_X0 = 11'd700;      // 报告页评级大字
    localparam [10:0] LV_Y0 = 11'd240;

    wire in_big0 = (xpos >= BG_X0) && (xpos < BG_X0 + 11'd80) &&
                   (ypos >= BG_Y0) && (ypos < BG_Y0 + 11'd32);
    wire in_big1 = (xpos >= LV_X0) && (xpos < LV_X0 + 11'd64) &&
                   (ypos >= LV_Y0) && (ypos < LV_Y0 + 11'd32);

    wire        in_big = page ? in_big1 : in_big0;

    wire [10:0] bx     = page ? (xpos - LV_X0) : (xpos - BG_X0);
    wire [10:0] by     = page ? (ypos - LV_Y0) : (ypos - BG_Y0);

    wire [2:0]  big_ch  = bx >> 4;                      // 第几个字
    wire [2:0]  big_gx  = (bx & 11'd15) >> 1;
    wire [3:0]  big_gy  = (by & 11'd31) >> 1;

    reg  [7:0]  ch_big;

    always @(*) begin
        if (!page) begin
            if (st_q[2]) begin
                case (big_ch)
                    3'd0: ch_big = 8'h53;   // S
                    3'd1: ch_big = 8'h4E;   // N
                    3'd2: ch_big = 8'h4F;   // O
                    3'd3: ch_big = 8'h52;   // R
                    default: ch_big = 8'h45; // E
                endcase
            end else begin
                case (big_ch)
                    3'd0: ch_big = 8'h51;   // Q
                    3'd1: ch_big = 8'h55;   // U
                    3'd2: ch_big = 8'h49;   // I
                    3'd3: ch_big = 8'h45;   // E
                    default: ch_big = 8'h54; // T
                endcase
            end
        end else if (nodata_snap) begin
            case (big_ch)                   // WAIT
                3'd0: ch_big = 8'h57;   // W
                3'd1: ch_big = 8'h41;   // A
                3'd2: ch_big = 8'h49;   // I
                default: ch_big = 8'h54; // T
            endcase
        end else begin
            case (level_snap)
                2'd0: case (big_ch)         // LOW
                    3'd0: ch_big = 8'h4C;   // L
                    3'd1: ch_big = 8'h4F;   // O
                    3'd2: ch_big = 8'h57;   // W
                    default: ch_big = 8'h20;
                endcase
                2'd1: case (big_ch)         // MID
                    3'd0: ch_big = 8'h4D;   // M
                    3'd1: ch_big = 8'h49;   // I
                    3'd2: ch_big = 8'h44;   // D
                    default: ch_big = 8'h20;
                endcase
                default: case (big_ch)      // HIGH
                    3'd0: ch_big = 8'h48;   // H
                    3'd1: ch_big = 8'h49;   // I
                    3'd2: ch_big = 8'h47;   // G
                    default: ch_big = 8'h48; // H
                endcase
            endcase
        end
    end

    wire [7:0] glyph_big;
    font_rom u_font_big (
        .ch   (ch_big),
        .row  (big_gy),
        .bits (glyph_big)
    );

    wire pix_on_big = glyph_big[7 - big_gx];

    //------------------------------------------------------------------
    // 逐像素判决
    //------------------------------------------------------------------
    wire in_wave  = (xpos >= WX0) && (xpos <= WX1) && (ypos >= WY0) && (ypos <= WY1);
    wire in_panel = (xpos >= PX0) && (xpos <= PX1) && (ypos >= WY0) && (ypos <= WY1);
    wire in_verd  = (xpos >= PX0) && (xpos <= PX1) && (ypos >= 11'd160) && (ypos <= 11'd239);
    wire in_loud  = (xpos >= LAMP_X0) && (xpos <= LAMP_X1) && (ypos >= 11'd64)  && (ypos <= 11'd79);
    wire in_long  = (xpos >= LAMP_X0) && (xpos <= LAMP_X1) && (ypos >= 11'd96)  && (ypos <= 11'd111);

    wire in_pip1  = (xpos >= 11'd752) && (xpos <= 11'd761) && (ypos >= 11'd128) && (ypos <= 11'd143);
    wire in_pip2  = (xpos >= 11'd766) && (xpos <= 11'd775) && (ypos >= 11'd128) && (ypos <= 11'd143);
    wire in_pip3  = (xpos >= 11'd780) && (xpos <= 11'd789) && (ypos >= 11'd128) && (ypos <= 11'd143);

    // 网格：竖线每 128 像素（128*32ms ≈ 4 秒），横线每 100 像素
    // 直接列点判断，比取模省逻辑，也不会算错相位
    wire grid_v = (xpos == 11'd136) || (xpos == 11'd264) ||
                  (xpos == 11'd392) || (xpos == 11'd520);
    wire grid_h = (ypos == 11'd147) || (ypos == 11'd247) || (ypos == 11'd347);
    wire border = (xpos == WX0) || (xpos == WX1) || (ypos == WY0) || (ypos == WY1);

    //------------------------------------------------------------------
    // 报告页：评级条
    //   满量程 600 次/小时。长度用 (x - x>>3) 近似 x*0.875 得来，
    //   600 -> 525 会略微超出 512 的槽宽，最后再钳一次。
    //   这样只用移位和减法，不引入除法器。
    //------------------------------------------------------------------
    localparam [10:0] BAR_X0 = 11'd168, BAR_X1 = 11'd679;   // 512 像素
    localparam [10:0] BAR_Y0 = 11'd240, BAR_Y1 = 11'd263;

    wire in_bar = (xpos >= BAR_X0) && (xpos <= BAR_X1) &&
                  (ypos >= BAR_Y0) && (ypos <= BAR_Y1);

    wire in_bar_edge = ((xpos == BAR_X0 || xpos == BAR_X1) &&
                        (ypos >= BAR_Y0 && ypos <= BAR_Y1)) ||
                       ((ypos == BAR_Y0 || ypos == BAR_Y1) &&
                        (xpos >= BAR_X0 && xpos <= BAR_X1));

    wire [10:0] bar_x  = xpos - BAR_X0;
    wire [10:0] rlim   = (rbar_snap > 14'd600) ? 11'd600 : rbar_snap[10:0];
    wire [10:0] rfill  = rlim - (rlim >> 3);
    wire [10:0] barfill = (rfill > 11'd512) ? 11'd512 : rfill;

    wire in_bar_fill = in_bar && (bar_x < barfill);

    wire [23:0] lvl_col = (level_snap == 2'd0) ? C_LV0 :
                          (level_snap == 2'd1) ? C_LV1 : C_LV2;

    reg [23:0] rgb_c;

    always @(*) begin
        //---- 底色 ----
        if (ypos < 11'd40)
            rgb_c = C_HDR;
        else
            rgb_c = C_BG;

        if (!page) begin
            //=================== 实时页 ===================
            if (in_wave) begin
                rgb_c = C_WAVE;

                if (grid_v || grid_h) rgb_c = C_GRID;

                if (ypos == TH_Y)
                    rgb_c = C_THLINE;                 // 门限线：画在波形上方，压着柱子走
                else if (wdy <= whgt && wdy != 10'd0)
                    rgb_c = wabove ? C_WAVEHI : C_WAVELO;

                if (border) rgb_c = C_BORDER;
            end

            if (in_panel) rgb_c = C_PANEL;

            if (in_loud)  rgb_c = st_q[0] ? C_LOUD : C_LAMPOFF;
            if (in_long)  rgb_c = st_q[1] ? C_LONG : C_LAMPOFF;

            if (in_pip1)  rgb_c = (rh_q >= 4'd1) ? C_RHY : C_LAMPOFF;
            if (in_pip2)  rgb_c = (rh_q >= 4'd2) ? C_RHY : C_LAMPOFF;
            if (in_pip3)  rgb_c = (rh_q >= 4'd3) ? C_RHY : C_LAMPOFF;

            if (in_verd)  rgb_c = st_q[2] ? C_VERDON : C_VERDOFF;
        end else begin
            //=================== 报告页 ===================
            if (in_bar)      rgb_c = C_BARBG;
            if (in_bar_fill) rgb_c = lvl_col;
            if (in_bar_edge) rgb_c = C_BORDER;
        end

        //---- 文字盖在图形上 ----
        if (pix_on)
            rgb_c = (!page && in_verd) ? C_FGWHITE : C_FG;

        //---- 大字（最后画，压住一切）----
        if (in_big && pix_on_big)
            rgb_c = C_FGWHITE;
    end

    // 再打一拍输出：让"渲染"和"送管脚"之间隔一级寄存器，
    // 输出路径变成 FF -> OBUF，走 FPC 排线更稳，综合也容易收敛。
    // 顶层据此把 DE 也延一拍（de_r2），两者仍然对齐。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            rgb <= 24'd0;
        else
            rgb <= rgb_c;
    end

endmodule
