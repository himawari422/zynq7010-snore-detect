//=============================================================================
// snore_report.v
//   鼾声统计与简略健康报告
//
//   设计原则：只做"能在几十个 LUT 里算清、且不需要存历史"的指标。
//   四个数字 + 一个三档评级，全部是计数器、移位和比较，没有除法器、没有 BRAM。
//
//   ① EVENTS  总判决次数
//        BCD 逐位累加（e3..e0），和 snore_display 里原来的 CNT 同一套写法，
//        省掉二进制转十进制的除法器。
//
//   ② RATE /H 每小时次数
//        用两个 30 秒桶拼出 1 分钟滑窗：rate = (上桶 + 本桶) × 60。
//        ×60 不做乘法器，写成 (x<<6) - (x<<2)，一个 16 位减法器。
//        滑窗而不是"从开机累计"，是为了让演示时几十秒内就能看到数，
//        而且每个事件都立刻反映出来，不必等整分钟。
//
//   ③ SNORE % 超阈帧占比
//        以 1024 帧（32.8 秒）为一个统计块：ratio = (响帧数 × 100) >> 10。
//        1024 是 2 的幂，所以"除以 1024"是一次移位，没有除法器。
//
//   ④ SILENCE 疑似静默次数（这条是唯一和"健康"有关的）
//        注意这不是临床上的呼吸暂停判定：麦克风只能听声音，
//        测不到气流，所以只能数"鼾声停止超过 10 秒后又恢复"这件事。
//        屏幕和报告里一律写 SILENCE / 疑似，不能写 apnea 或 AHI。
//
//   ⑤ LEVEL 三档评级
//        以 RATE 为主，若出现疑似静默则至少抬到中等、出现 3 次则抬到偏重。
//        阈值 120 / 400 次每小时：正常人偶发鼾声多在 100 以下，
//        习惯性打鼾常在 100~400，400 以上属于重度。这三个数是经验值，
//        换受试者/换房间需要重标，报告里要说清这一点。
//
//   时间基准：全部基于 frame_done（32ms/帧）。
//     旧的 frame_no 只有 16 位，65536×32ms = 35 分钟就回绕，
//     做长时统计必须另开计数器 —— 这里的桶计数器是 11 位(1875 帧)，
//     每 30 秒自然归零，不存在回绕问题。
//=============================================================================
`timescale 1ns / 1ps

module snore_report #(
    parameter integer FRAMES_PER_BUCKET = 937,   // 29.98s @32ms/帧
    parameter integer SIL_LIM           = 313    // 10.0s 算"疑似静默"
)(
    input  wire        clk,          // 50MHz 判据域
    input  wire        rst_n,
    input  wire        frame_done,   // 每 32ms 一个脉冲
    input  wire [3:0]  status,       // 判据状态位（bit0 响 / bit2 判为鼾声）
    input  wire        clr,          // 统计清零（按键，1 拍有效）
    //---- 给显示域（顶层在 frame_done 时锁存，值至少稳定 32ms）----
    output reg  [15:0] evt_bcd,      // 总判决次数      {d3,d2,d1,d0}
    output reg  [15:0] rate_bcd,     // 每小时次数      {r3,r2,r1,r0}
    output reg  [7:0]  ratio_bcd,    // 超阈占比 %      {十位,个位}
    output reg  [7:0]  sil_bcd,      // 疑似静默次数    {十位,个位}
    output reg  [1:0]  level,        // 0 轻微 / 1 中等 / 2 偏重
    output reg         nodata,       // 运行不足 1 分钟，不下结论
    output reg  [13:0] rate_bar      // 给评级条用（已钳位到 9999）
);

    //------------------------------------------------------------------
    // 判决脉冲：status[2] 的上升沿
    //   判据里 hold 保持 1 秒，两个呼吸周期之间（约 4 秒）hold 会掉，
    //   所以每个呼吸周期对应一个干净的上升沿。
    //------------------------------------------------------------------
    reg  st2_d;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) st2_d <= 1'b0;
        else        st2_d <= status[2];
    end

    wire evt_pulse = status[2] & ~st2_d;
    wire evt_evt   = frame_done & evt_pulse;      // 与帧边界对齐，便于同拍统计

    //==================================================================
    // ① 总判决次数（BCD 累加，9999 封顶）
    //==================================================================
    reg [3:0] e3, e2, e1, e0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n || clr) begin
            e3 <= 4'd0; e2 <= 4'd0; e1 <= 4'd0; e0 <= 4'd0;
        end else if (evt_evt) begin
            if (e0 != 4'd9) begin
                e0 <= e0 + 4'd1;
            end else begin
                e0 <= 4'd0;
                if (e1 != 4'd9) begin
                    e1 <= e1 + 4'd1;
                end else begin
                    e1 <= 4'd0;
                    if (e2 != 4'd9) begin
                        e2 <= e2 + 4'd1;
                    end else begin
                        e2 <= 4'd0;
                        if (e3 != 4'd9) e3 <= e3 + 4'd1;
                    end
                end
            end
        end
    end

    //==================================================================
    // ② 每小时次数：两个 30 秒桶 → 1 分钟滑窗 × 60
    //==================================================================
    reg [10:0] bkt_fr;       // 桶内帧计数 0..936
    reg [7:0]  evt_a;        // 上一个桶的事件数（已封存）
    reg [7:0]  evt_b;        // 当前桶的事件数（还在涨）

    wire tick_bkt = frame_done && (bkt_fr == FRAMES_PER_BUCKET - 1);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n || clr) begin
            bkt_fr <= 11'd0;
            evt_a  <= 8'd0;
            evt_b  <= 8'd0;
        end else if (frame_done) begin
            if (tick_bkt) begin
                bkt_fr <= 11'd0;
                evt_a  <= evt_b;
                evt_b  <= evt_pulse ? 8'd1 : 8'd0;   // 跨桶的那一拍归入新桶
            end else begin
                bkt_fr <= bkt_fr + 11'd1;
                if (evt_pulse && evt_b != 8'hFF)
                    evt_b <= evt_b + 8'd1;
            end
        end
    end

    wire [9:0]  per_min  = evt_a + evt_b;                        // 0..510
    wire [15:0] rate_raw = ({6'd0, per_min} << 6) -              // ×64
                           ({6'd0, per_min} << 2);               // -×4  => ×60
    wire [15:0] rate_show = (rate_raw > 16'd9999) ? 16'd9999 : rate_raw;

    //------------------------------------------------------------------
    // 二进制 → BCD（4 位）
    //   不用通用除法：每 30 秒才跑一次，用"逐次减"的串行状态机，
    //   最多约 20 拍（400ns），面积只有几十个 LUT。
    //   转换期间 cv_busy=1，显示快照会跳过，不会读到半成品。
    //------------------------------------------------------------------
    reg        cv_busy;
    reg [15:0] cv_rem;
    reg [3:0]  r3, r2, r1, r0;

    wire cvt_req = evt_evt || tick_bkt;

    // 延一拍再启动转换：evt_b / evt_a 是在 cvt_req 同一拍更新的，
    // 直接在本拍读数会漏掉刚来的那次事件（显示的速率永远差一个）。
    reg cvt_req_d;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n || clr) cvt_req_d <= 1'b0;
        else               cvt_req_d <= cvt_req;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n || clr) begin
            cv_busy <= 1'b0;
            cv_rem  <= 16'd0;
            r3 <= 4'd0; r2 <= 4'd0; r1 <= 4'd0; r0 <= 4'd0;
        end else if (cvt_req_d) begin
            cv_busy <= 1'b1;
            cv_rem  <= rate_show;
            r3 <= 4'd0; r2 <= 4'd0; r1 <= 4'd0; r0 <= 4'd0;
        end else if (cv_busy) begin
            if (cv_rem >= 16'd1000) begin
                cv_rem <= cv_rem - 16'd1000; r3 <= r3 + 4'd1;
            end else if (cv_rem >= 16'd100) begin
                cv_rem <= cv_rem - 16'd100;  r2 <= r2 + 4'd1;
            end else if (cv_rem >= 16'd10) begin
                cv_rem <= cv_rem - 16'd10;   r1 <= r1 + 4'd1;
            end else begin
                r0     <= cv_rem[3:0];
                cv_busy <= 1'b0;
            end
        end
    end

    //==================================================================
    // ③ 超阈占比：1024 帧一块
    //==================================================================
    reg [10:0] blk_fr;       // 0..1023
    reg [11:0] loud_fr;      // 0..1024
    reg [6:0]  ratio_v;      // 0..99

    // 块结束那一拍要把"本帧"也算进去，否则正好 1024 帧全响时会少 1
    wire [11:0] loud_nxt  = loud_fr + {11'd0, status[0]};
    // ×100 写成 ×64 + ×32 + ×4（纯移位加法），避免综合出乘法器占 DSP
    wire [18:0] ln19      = {7'd0, loud_nxt};                 // ≤ 1024
    wire [18:0] loud_x100 = (ln19 << 6) + (ln19 << 5) + (ln19 << 2);
    // (n × 100) >> 10，1024 是 2 的幂，全程没有除法器
    // 理论最大 102400>>10 = 100，钳到 99 以便只用两位数字显示
    wire [6:0]  ratio_raw = (loud_x100 > 19'd101_376) ? 7'd99 : loud_x100[16:10];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n || clr) begin
            blk_fr  <= 11'd0;
            loud_fr <= 12'd0;
            ratio_v <= 7'd0;
        end else if (frame_done) begin
            if (blk_fr == 11'd1023) begin
                ratio_v <= ratio_raw;
                loud_fr <= 12'd0;
                blk_fr  <= 11'd0;
            end else begin
                blk_fr <= blk_fr + 11'd1;
                if (status[0] && loud_fr != 12'd1024)
                    loud_fr <= loud_fr + 12'd1;
            end
        end
    end

    // 0..99 转两位 BCD：一条比较链，比通用转换器省得多
    function [7:0] bcd2;
        input [6:0] v;
        reg [3:0] t;
        begin
            if      (v >= 7'd90) t = 4'd9;
            else if (v >= 7'd80) t = 4'd8;
            else if (v >= 7'd70) t = 4'd7;
            else if (v >= 7'd60) t = 4'd6;
            else if (v >= 7'd50) t = 4'd5;
            else if (v >= 7'd40) t = 4'd4;
            else if (v >= 7'd30) t = 4'd3;
            else if (v >= 7'd20) t = 4'd2;
            else if (v >= 7'd10) t = 4'd1;
            else                 t = 4'd0;
            bcd2 = {t, (v - ((t << 3) + (t << 1)))};
        end
    endfunction

    //==================================================================
    // ④ 疑似静默：出现过判决之后，连续 10 秒没有新的判决
    //   只在"恢复"之前的第一次越限记一次，不重复计数。
    //   开机后还没判出过鼾声时不计数（否则每个安静的夜晚都算异常）。
    //==================================================================
    reg [9:0] idle_fr;
    reg       sil_armed;     // 至少出现过一次判决
    reg       sil_taken;     // 本次静默已经记过一次
    reg [3:0] s1, s0;

    wire sil_hit = sil_armed && !sil_taken && (idle_fr >= SIL_LIM);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n || clr) begin
            idle_fr   <= 10'd0;
            sil_armed <= 1'b0;
            sil_taken <= 1'b0;
            s1 <= 4'd0; s0 <= 4'd0;
        end else if (evt_evt) begin
            idle_fr   <= 10'd0;
            sil_armed <= 1'b1;
            sil_taken <= 1'b0;
        end else if (frame_done) begin
            if (idle_fr != 10'd1023)
                idle_fr <= idle_fr + 10'd1;

            if (sil_hit) begin
                sil_taken <= 1'b1;
                if (s0 != 4'd9) begin
                    s0 <= s0 + 4'd1;
                end else begin
                    s0 <= 4'd0;
                    if (s1 != 4'd9) s1 <= s1 + 4'd1;
                end
            end
        end
    end

    wire [6:0] sil_val = (({3'd0, s1} << 3) + ({3'd0, s1} << 1)) + {3'd0, s0};

    //==================================================================
    // ⑤ 三档评级
    //==================================================================
    wire [1:0] lv_rate = (rate_raw < 16'd120) ? 2'd0 :
                         (rate_raw < 16'd400) ? 2'd1 : 2'd2;
    wire [1:0] lv_sil  = (sil_val >= 7'd3) ? 2'd2 :
                         (sil_val >= 7'd1) ? 2'd1 : 2'd0;
    wire [1:0] lv_all  = (lv_rate > lv_sil) ? lv_rate : lv_sil;

    // 运行不足 1 分钟（两个桶都没走完）时不下结论，屏幕显示 WAIT
    reg [1:0] bkt_n;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n || clr)
            bkt_n <= 2'd0;
        else if (tick_bkt && bkt_n != 2'd2)
            bkt_n <= bkt_n + 2'd1;
    end

    wire no_data = (bkt_n < 2'd2);

    //==================================================================
    // 输出快照：只在转换完成时更新，避免把半成品送出去
    //==================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n || clr) begin
            evt_bcd  <= 16'd0;
            rate_bcd <= 16'd0;
            ratio_bcd <= 8'd0;
            sil_bcd  <= 8'd0;
            level    <= 2'd0;
            nodata   <= 1'b1;
            rate_bar <= 14'd0;
        end else if (frame_done && !cv_busy) begin
            evt_bcd   <= {e3, e2, e1, e0};
            rate_bcd  <= {r3, r2, r1, r0};
            ratio_bcd <= bcd2(ratio_v);
            sil_bcd   <= {s1, s0};
            level     <= no_data ? 2'd0 : lv_all;
            nodata    <= no_data;
            rate_bar  <= rate_show[13:0];
        end
    end

endmodule
