//=============================================================================
// snore_top.v
//   呼噜声检测 —— 纯 PL 实现（不依赖 PS）
//
//   数据流：
//     SPH0641LM4H-1 (PDM)  --2MHz 1bit-->  pdm_cic  --16kHz 16bit-->
//     frame_meter(32ms/帧) --> snore_judge(三条件判据) --+
//                                                       +--> 串口 / LED / 蜂鸣器
//                                                       +--> LCD 实时页 + 报告页
//     控制：板上 key[0]/key[1]，或电脑经串口发单字符命令（见 cmd_parse.v）
//
//   板级连接（领航者 ZYNQ7010 / 底板 V3.9，J3 扩展口）：
//     J3-20  (LCD_B0 / W18) -> PDM_CLK   麦克风 CLK
//     J3-19  (LCD_B1 / W19) -> PDM_DAT   麦克风 DAT
//     J3-38  (+3.3V)        -> 麦克风 3V
//     J3-37/39 (GND)        -> 麦克风 GND
//     麦克风 SEL 接 GND（左声道，数据在 CLK 上升沿有效）
//
//   ★ 关于 W18/W19 与 LCD 的共存（2026-10-29 处理）
//     W18/W19 在原理图上就是 RGB LCD 的 B0/B1。插上 ATK-4384 之后，
//     屏的 B0/B1 输入脚由麦克风的 CLK/DAT 顺带驱动。
//     这不冲突，因为：
//       ① 屏侧 B0/B1 是输入（高阻），不往外驱动；
//       ② W18 是输出、W19 是输入，不存在两个输出对打。
//     代价只有：蓝色最低两位带 2MHz 抖动，占蓝色量程 2/256 ≈ 0.8%，
//     而且本设计用 RGB565 —— B0/B1 本来就不需要。
//     所以 lcd_rgb 端口声明成 [23:2]，最低两位**根本不存在的端口**，
//     不可能被 Vivado 随便分配到别的管脚上去。
//
//     J3-19/20 与 RGB LCD 的 B0/B1 共网，不插屏时完全空闲。
//
//   ★ 串口双向（2026-10-29 增加）
//     TXD = J15，RXD = T19，同一组 CH340（跳线接 PL 侧）。
//     下行：电脑发 P/T/R/C/? 单字符 → 切页 / 清零 / 探活
//     上行：每 32ms 一行 38 字节遥测，末尾 G 字段回显页号与命令计数
//     这样电脑端点一下按钮，既能操作，也能确认操作到了。
//=============================================================================
`timescale 1ns / 1ps

module snore_top #(
    parameter integer LED_ACT_LOW = 1           // 领航者板载 LED 为低电平点亮
)(
    input  wire       sys_clk,                  // U18, 50MHz
    input  wire       sys_rst_n,                // N16, 低有效
    input  wire       pdm_dat,                  // 麦克风数据（输入）
    output wire       pdm_clk,                  // 麦克风时钟（输出，2MHz）
    input  wire       uart_rxd,                 // T19, 电脑下行命令
    output wire       uart_txd,                 // J15, 115200 8N1
    output wire       beep,                     // M14, 有源蜂鸣器
    output wire [2:0] led,                      // H15/L15/J16
    //---- PL 侧按键（低有效）----
    //     key[0] = L14：切换"实时页 / 报告页"
    //     key[1] = K16：清零统计
    input  wire [1:0] key,
    //---- RGB LCD（ATK-4384 / 800x480 / DE 模式）----
    //     注意位宽是 [23:2]：B0/B1 是麦克风占用，故意不声明
    output wire [23:2] lcd_rgb,
    output wire        lcd_clk,
    output wire        lcd_de,
    output wire        lcd_hs,
    output wire        lcd_vs,
    output wire        lcd_bl,
    output wire        lcd_rst_n
);

    //------------------------------------------------------------------
    // 复位同步：异步置位、同步释放
    //------------------------------------------------------------------
    reg [1:0] rst_sync;

    always @(posedge sys_clk or negedge sys_rst_n) begin
        if (!sys_rst_n)
            rst_sync <= 2'b00;
        else
            rst_sync <= {rst_sync[0], 1'b1};
    end

    wire rst_n = rst_sync[1];

    //------------------------------------------------------------------
    // PDM 数据同步（两级触发器）
    //   实际采样点距时钟上升沿约 340ns，不存在亚稳态风险，
    //   这里仍然加两级，属于习惯做法，也便于将来改时钟频率。
    //------------------------------------------------------------------
    reg [1:0] dat_sync;

    always @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n)
            dat_sync <= 2'b00;
        else
            dat_sync <= {dat_sync[0], pdm_dat};
    end

    wire pdm_bit = dat_sync[1];

    //------------------------------------------------------------------
    // 1. PDM 时钟产生
    //------------------------------------------------------------------
    wire pdm_clk_i;
    wire sample_en;

    pdm_clk_gen u_clkgen (
        .clk       (sys_clk),
        .rst_n     (rst_n),
        .pdm_clk   (pdm_clk_i),
        .sample_en (sample_en)
    );

    assign pdm_clk = pdm_clk_i;

    //------------------------------------------------------------------
    // 2. CIC 抽取：2MHz/1bit -> 16kHz/16bit
    //------------------------------------------------------------------
    (* mark_debug = "true" *) wire signed [15:0] pcm;
    (* mark_debug = "true" *) wire               pcm_valid;

    pdm_cic #(
        .R         (125),       // 2MHz / 125 = 16.000kHz
        .OUT_SHIFT (13)         // 满量程约 ±29800，改小=加增益
    ) u_cic (
        .clk       (sys_clk),
        .rst_n     (rst_n),
        .en        (sample_en),
        .din       (pdm_bit),
        .pcm       (pcm),
        .pcm_valid (pcm_valid)
    );

    //------------------------------------------------------------------
    // 3. 分帧统计（512 点 = 32ms）
    //------------------------------------------------------------------
    (* mark_debug = "true" *) wire [15:0] peak;
    (* mark_debug = "true" *) wire [15:0] mean_abs;
    (* mark_debug = "true" *) wire        frame_done;

    frame_meter #(
        .FRAME_LEN (512)
    ) u_meter (
        .clk        (sys_clk),
        .rst_n      (rst_n),
        .pcm        (pcm),
        .pcm_valid  (pcm_valid),
        .peak       (peak),
        .mean_abs   (mean_abs),
        .frame_done (frame_done)
    );

    reg [15:0] frame_no;

    always @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n)
            frame_no <= 16'd0;
        else if (frame_done)
            frame_no <= frame_no + 16'd1;
    end

    //------------------------------------------------------------------
    // 4. 鼾声判据：响度 + 持续时间 + 节律（见 snore_judge.v）
    //    旧的 alarm_ctrl.v 只比单帧门限，已停用，文件保留作参考
    //------------------------------------------------------------------
    wire [2:0] leds_n;

    (* mark_debug = "true" *) wire [3:0]  judge_status;
    (* mark_debug = "true" *) wire [15:0] judge_env;
    (* mark_debug = "true" *) wire [7:0]  judge_ocnt;      // 包络口径的 burst 长度，只留给 ILA 看
    (* mark_debug = "true" *) wire [7:0]  judge_rawlen;
    (* mark_debug = "true" *) wire [3:0]  judge_rhythm;

    snore_judge #(
        .TH         (16'd525),      // 响度包络门限（2026-10-28 实测标定）
        .ENV_SHIFT  (4),            // 包络释放时间常数 16 帧 = 512ms
        .MIN_ON_F   (8),            // 256ms 最短有效声事件
        .GAP_MIN_F  (9),            // 288ms 最小节律间隔（切掉说话的音节间隙）
        .GAP_MAX_F  (96),           // 3072ms 最大节律间隔
        .N_PERIOD   (3),            // 连续 3 次节律判决
        .HOLD_F     (32),           // 指示灯保持 1s
        .BEEP_F     (7)             // 蜂鸣 224ms
    ) u_judge (
        .clk        (sys_clk),
        .rst_n      (rst_n),
        .frame_done (frame_done),
        .peak       (peak),
        .led        (leds_n),
        .beep       (beep),
        .status     (judge_status),
        .env        (judge_env),
        .on_cnt     (judge_ocnt),
        .raw_len    (judge_rawlen),
        .rhythm     (judge_rhythm)
    );

    assign led = LED_ACT_LOW ? ~leds_n : leds_n;

    //==================================================================
    // 5. 按键消抖：key[0] 切页，key[1] 清零统计
    //    板载按键低有效、无硬件滤波，直接拿来当脉冲会抖出好几次，
    //    所以先同步两拍，再要求信号连续 21ms 保持不变才认。
    //==================================================================
    reg [1:0] key_sync;
    reg [1:0] key_stable;
    reg [1:0] key_stable_d;
    reg [19:0] db_cnt;

    always @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) key_sync <= 2'b11;
        else        key_sync <= key;
    end

    always @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) begin
            key_stable <= 2'b11;
            db_cnt     <= 20'd0;
        end else if (key_sync != key_stable) begin
            if (&db_cnt) begin                  // 1048575 × 20ns ≈ 21ms
                key_stable <= key_sync;
                db_cnt     <= 20'd0;
            end else begin
                db_cnt <= db_cnt + 20'd1;
            end
        end else begin
            db_cnt <= 20'd0;
        end
    end

    always @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) key_stable_d <= 2'b11;
        else        key_stable_d <= key_stable;
    end

    // 下降沿 = 按下（按一下给 1 拍脉冲）
    wire key0_press = key_stable_d[0] & ~key_stable[0];
    wire key1_press = key_stable_d[1] & ~key_stable[1];

    //==================================================================
    // 5b. 串口下行命令：电脑也能切页 / 清零
    //     单字符协议（P/T/R/C/?），细节见 cmd_parse.v。
    //     和按键共用同一个页面寄存器，谁都能改，
    //     所以"按一下板上按键"和"点一下电脑按钮"在逻辑上完全等价。
    //==================================================================
    wire       rx_valid;
    wire [7:0] rx_data;

    uart_rx #(
        .CLK_FREQ (50_000_000),
        .BAUD     (115200)
    ) u_urx (
        .clk   (sys_clk),
        .rst_n (rst_n),
        .rxd   (uart_rxd),
        .data  (rx_data),
        .valid (rx_valid)
    );

    wire       cmd_page_tgl;
    wire       cmd_page_set_en;
    wire       cmd_page_set_val;
    wire       cmd_clr;
    wire [2:0] cmd_cnt;

    cmd_parse u_cmd (
        .clk          (sys_clk),
        .rst_n        (rst_n),
        .rx_valid     (rx_valid),
        .rx_data      (rx_data),
        .page_tgl     (cmd_page_tgl),
        .page_set_en  (cmd_page_set_en),
        .page_set_val (cmd_page_set_val),
        .clr          (cmd_clr),
        .cmd_cnt      (cmd_cnt),
        .cmd_seen     ()            // 只用于调试；G 字段用 cmd_cnt != 0 判断
    );

    //---- 页面寄存器：按键与串口命令的共同出口 ----
    //     优先级：按键 > 串口强制指定 > 串口翻转。
    //     两者同时到达的概率可以忽略，这里只是为了综合出确定的逻辑。
    reg page_r;

    always @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n)                   page_r <= 1'b0;
        else if (key0_press)          page_r <= ~page_r;
        else if (cmd_page_set_en)     page_r <= cmd_page_set_val;
        else if (cmd_page_tgl)        page_r <= ~page_r;
    end

    //---- 统一清零源：按键 key[1] 或串口 'C' ----
    //     report 在 50MHz 域，直接吃这个单拍脉冲；
    //     display 在 25MHz 域，拍宽只有 20ns 会被漏采，
    //     所以另外转成"每清一次翻转一次"的电平送过去。
    wire stat_clr = key1_press | cmd_clr;

    reg clr_tgl;

    always @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n)        clr_tgl <= 1'b0;
        else if (stat_clr) clr_tgl <= ~clr_tgl;
    end

    //==================================================================
    // 6. 统计与简略健康报告（见 snore_report.v）
    //    四个计数器 + 三档评级，全是移位和比较，不占 BRAM 也不占 DSP
    //==================================================================
    wire [15:0] rpt_evt;
    wire [15:0] rpt_rate;
    wire [7:0]  rpt_ratio;
    wire [7:0]  rpt_sil;
    wire [1:0]  rpt_level;
    wire        rpt_nodata;
    wire [13:0] rpt_bar;

    snore_report u_rep (
        .clk        (sys_clk),
        .rst_n      (rst_n),
        .frame_done (frame_done),
        .status     (judge_status),
        .clr        (stat_clr),
        .evt_bcd    (rpt_evt),
        .rate_bcd   (rpt_rate),
        .ratio_bcd  (rpt_ratio),
        .sil_bcd    (rpt_sil),
        .level      (rpt_level),
        .nodata     (rpt_nodata),
        .rate_bar   (rpt_bar)
    );

    //------------------------------------------------------------------
    // 7. 串口上报（含判据状态位 + 包络/burst长度/节律计数 + 页面回显）
    //    C 字段上报的是 raw_len（原始峰值超阈帧数），也就是 MIN_ON 判的那个数
    //
    //    ★ 上报专用流水（2026-10-29）
    //      frame_meter 的 mean_abs 到 uart_report 的 f_ma 是 0 级逻辑直连，
    //      布局把这两个寄存器拉开后，保持余量只剩 12ps（WHS +0.012ns），
    //      是全设计最薄的一条路径。这里插一级寄存器，长线被切成两段，
    //      每段各自都有充裕余量。
    //      六个字段一起延迟一拍，所以每行遥测的各字段仍然严格同帧，
    //      只是整条数据比屏幕上的状态晚 32ms —— 对人眼没有区别。
    //------------------------------------------------------------------
    reg [15:0] tx_peak, tx_mean, tx_env;
    reg [3:0]  tx_st, tx_rh;
    reg [7:0]  tx_oc;

    always @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_peak <= 16'd0;
            tx_mean <= 16'd0;
            tx_env  <= 16'd0;
            tx_st   <= 4'd0;
            tx_oc   <= 8'd0;
            tx_rh   <= 4'd0;
        end else begin
            tx_peak <= peak;
            tx_mean <= mean_abs;
            tx_env  <= judge_env;
            tx_st   <= judge_status;
            tx_oc   <= judge_rawlen;
            tx_rh   <= judge_rhythm;
        end
    end

    uart_report u_report (
        .clk        (sys_clk),
        .rst_n      (rst_n),
        .frame_done (frame_done),
        .frame_no   (frame_no),
        .peak       (tx_peak),
        .mean_abs   (tx_mean),
        .env        (tx_env),
        .status     (tx_st),
        .on_cnt     (tx_oc),
        .rhythm     (tx_rh),
        .page       (page_r),
        .cmd_cnt    (cmd_cnt),
        .txd        (uart_txd)
    );

    //==================================================================
    // 8. LCD 显示（ATK-4384，800x480，DE 模式）
    //    第 0 页实时波形 / 第 1 页统计与建议，由 page_r 选择
    //==================================================================

    //------------------------------------------------------------------
    // 像素时钟 25MHz：50MHz 二分频，过 BUFG 走全局时钟网络
    //
    // 为什么不用 33.3MHz（表里的标准值，60Hz）：
    //   33.3 不是 50 的整数分频，必须例化 MMCM。
    //   而官方例程对 4384 用的就是 25MHz（表 29.4.2），
    //   说明这块屏在 45Hz 下能稳定显示。
    //   第一版先把"能亮"做稳，要更顺滑再换 MMCM。
    //------------------------------------------------------------------
    reg clk25_r;

    always @(posedge sys_clk or negedge sys_rst_n) begin
        if (!sys_rst_n)
            clk25_r <= 1'b0;
        else
            clk25_r <= ~clk25_r;
    end

    wire lcd_pclk;

    BUFG u_bufg_pclk (
        .I (clk25_r),
        .O (lcd_pclk)
    );

    // 25MHz 域的复位：异步置位、同步释放
    reg [1:0] rst25_sync;

    always @(posedge lcd_pclk or negedge sys_rst_n) begin
        if (!sys_rst_n)
            rst25_sync <= 2'b00;
        else
            rst25_sync <= {rst25_sync[0], 1'b1};
    end

    wire rst_n25 = rst25_sync[1];

    //------------------------------------------------------------------
    // 跨时钟域：每帧把判据结果打包送过去
    //
    //   wr_tgl 每帧翻转一次当"数据有效"握手信号；
    //   env/status/rhythm 在同一个时钟沿锁存，随后稳定 32ms，
    //   显示模块等翻转信号同步过来再一起采样 —— 采到的一定是同一帧，
    //   不会出现"波形是这一帧、灯还是上一帧"的错位。
    //------------------------------------------------------------------
    reg        wr_tgl;
    reg [15:0] env_snap;
    reg [3:0]  st_snap;
    reg [3:0]  rh_snap;

    // 报告页的六个慢变量走同一套握手：它们最多 30 秒才变一次，
    // 在 frame_done 这一拍整体锁存，稳定时间远大于两拍同步，不会撕裂。
    reg [15:0] evt_snap;
    reg [15:0] rate_snap;
    reg [7:0]  ratio_snap;
    reg [7:0]  sil_snap;
    reg [1:0]  lvl_snap;
    reg        nd_snap;
    reg [13:0] rbar_snap;

    always @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_tgl    <= 1'b0;
            env_snap  <= 16'd0;
            st_snap   <= 4'd0;
            rh_snap   <= 4'd0;
            evt_snap  <= 16'd0;
            rate_snap <= 16'd0;
            ratio_snap<= 8'd0;
            sil_snap  <= 8'd0;
            lvl_snap  <= 2'd0;
            nd_snap   <= 1'b1;
            rbar_snap <= 14'd0;
        end else if (frame_done) begin
            wr_tgl    <= ~wr_tgl;
            env_snap  <= judge_env;
            st_snap   <= judge_status;
            rh_snap   <= judge_rhythm;
            evt_snap  <= rpt_evt;
            rate_snap <= rpt_rate;
            ratio_snap<= rpt_ratio;
            sil_snap  <= rpt_sil;
            lvl_snap  <= rpt_level;
            nd_snap   <= rpt_nodata;
            rbar_snap <= rpt_bar;
        end
    end

    // 页面选择是人为动作（几十毫秒级的慢信号），同步两拍进像素域
    reg [1:0] page_sync;

    always @(posedge lcd_pclk or negedge rst_n25) begin
        if (!rst_n25) page_sync <= 2'b00;
        else          page_sync <= {page_sync[0], page_r};
    end

    //------------------------------------------------------------------
    // 行场时序 + 显示渲染
    //------------------------------------------------------------------
    wire [10:0] px_pos, py_pos;
    wire        de_r;
    wire [23:0] disp_rgb;

    lcd_timing u_lcdtim (
        .clk     (lcd_pclk),
        .rst_n   (rst_n25),
        .lcd_clk (lcd_clk),
        .lcd_hs  (lcd_hs),
        .lcd_vs  (lcd_vs),
        .de_r    (de_r),
        .xpos    (px_pos),
        .ypos    (py_pos)
    );

    snore_display #(
        .TH (16'd525)
    ) u_disp (
        .clk         (lcd_pclk),
        .rst_n       (rst_n25),
        .wr_tgl      (wr_tgl),
        .env_snap    (env_snap),
        .status_snap (st_snap),
        .rhythm_snap (rh_snap),
        .clr_tgl     (clr_tgl),
        .page        (page_sync[1]),
        .evt_snap    (evt_snap),
        .rate_snap   (rate_snap),
        .ratio_snap  (ratio_snap),
        .sil_snap    (sil_snap),
        .level_snap  (lvl_snap),
        .nodata_snap (nd_snap),
        .rbar_snap   (rbar_snap),
        .xpos        (px_pos),
        .ypos        (py_pos),
        .rgb         (disp_rgb)
    );

    // 颜色比坐标晚一拍，DE 也再延一拍，两者严格对齐
    reg de_r2;

    always @(posedge lcd_pclk or negedge rst_n25) begin
        if (!rst_n25)
            de_r2 <= 1'b0;
        else
            de_r2 <= de_r;
    end

    assign lcd_de    = de_r2;
    assign lcd_rgb   = de_r2 ? disp_rgb[23:2] : 22'd0;
    assign lcd_bl    = 1'b1;      // 背光常亮（不亮就全黑，最容易误判断时序）
    assign lcd_rst_n = 1'b1;      // 屏复位释放

endmodule
