//=============================================================================
// tb_judge.v — snore_judge 单元测试（不进音频，直接喂 peak 序列）
//
//   参数与 snore_top.v / snore_judge.v 完全一致（2026-10-28 实测标定）：
//     TH=525  ENV_SHIFT=4  MIN_ON=8  GAP_MIN=9  GAP_MAX=96  N_PERIOD=3
//
//   场景按 2026-10-28 真人分段实测的时间尺度设计，不再用拍脑袋的 0.45s：
//     实测鼾声   —— 一次 1.5s（47 帧）响，两次之间 2s（64 帧）静
//     实测说话   —— 一句之内音节间隙 0.2s（6 帧），句子之间 0.3~1s
//     帧周期 32ms（16kHz / 512 点）
//
//   包络是"快起慢落"，ENV_SHIFT=4 → 每帧衰减 1/16（τ=512ms）。
//   从不同幅值衰减到门限 TH=525 所需帧数：
//     1000 -> 10 帧    1400 -> 15 帧    2000 -> 21 帧
//     2600 -> 25 帧    3000 -> 27 帧
//   所以一段"静"里只有 (静帧数 - 衰减帧数) 帧才算真正的节律间隔。
//
//   场景表（前 7 个验逻辑，后 3 个验音量边界）：
//     [1] 3 x (47 响@2000 + 64 静)  -> 检测      典型鼾声
//     [2] 3 x ( 4 响@2000 + 40 静)  -> 不检测    短促咔哒声，够不上 MIN_ON
//     [3] 连续 300 帧一直响@2000    -> 不检测    风扇/吹风机，没有节律
//     [4] 3 x (47 响@2000 +150 静)  -> 不检测    间隔 4.8s 超出呼吸周期上限
//     [5] 3 x (60 响@3000 + 80 静)  -> 检测      慢而重的鼾声
//     [6] 3 x (30 响@2000 +  6 静)  -> 不检测    说话音节：间隙被包络填平
//     [7] 2 段鼾声 + 6.4s 停顿 + 1 段 -> 不检测 节律断链后重新计数
//     [8] 说话(3x30响/6静) 紧接 鼾声  -> 检测    混合段只认后半段
//     [9] 3 x (47 响@1400 + 64 静)  -> 检测      小音量（麦克风偏远）
//    [10] 3 x (47 响@2600 + 64 静)  -> 检测      大音量（贴近喇叭）
//=============================================================================
`timescale 1ns / 1ps

module tb_judge;

    localparam [15:0] P_TH  = 16'd525;
    localparam integer P_ES   = 4;
    localparam integer P_MO   = 8;
    localparam integer P_GMIN = 9;
    localparam integer P_GMAX = 96;
    localparam integer P_NPER = 3;

    reg         clk = 1'b0;
    reg         rst_n = 1'b0;
    reg         frame_done = 1'b0;
    reg  [15:0] peak = 16'd0;

    wire [2:0]  led;
    wire        beep;
    wire [3:0]  status;
    wire [15:0] env;
    wire [7:0]  on_cnt;
    wire [7:0]  raw_len;
    wire [3:0]  rhythm;

    integer det = 0;
    reg     st2 = 1'b0;
    integer max_rhythm = 0;
    integer align_err = 0;

    snore_judge #(
        .TH         (P_TH),
        .ENV_SHIFT  (P_ES),
        .MIN_ON_F   (P_MO),
        .GAP_MIN_F  (P_GMIN),
        .GAP_MAX_F  (P_GMAX),
        .N_PERIOD   (P_NPER),
        .HOLD_F     (32),
        .BEEP_F     (7)
    ) dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .frame_done (frame_done),
        .peak       (peak),
        .led        (led),
        .beep       (beep),
        .status     (status),
        .env        (env),
        .on_cnt     (on_cnt),
        .raw_len    (raw_len),
        .rhythm     (rhythm)
    );

    always #10 clk = ~clk;

    // 统计 status[2] 的上升沿 = 判决次数
    always @(posedge clk) begin
        st2 <= status[2];
        if (status[2] && !st2) begin
            det = det + 1;
            $display("        >> DETECT  rhythm=%0d", rhythm);
        end
        if (rhythm > max_rhythm) max_rhythm = rhythm;

        //------------------------------------------------------------------
        // 断言：串口上报的 E 与 S 必须严格同帧
        //   uart_report 在 frame_done 那一拍采样，读到的是"本帧更新前"的值。
        //   如果 env 是组合输出（env_nxt）而 status 是寄存器，两者就会差一帧，
        //   出现「E 已超门限但 S 响位为 0」的自相矛盾数据。
        //   这里在同样的采样时机上比对，等价于检查串口里看到的那一行。
        //------------------------------------------------------------------
        if (frame_done && ((env > P_TH) != status[0])) begin
            align_err = align_err + 1;
            if (align_err <= 5)
                $display("        !! ALIGN MISMATCH env=%0d status[0]=%0d", env, status[0]);
        end
    end

    // 连续 n 帧施加同一个 peak 值
    task frm(input [15:0] p, input integer n);
        integer i;
        begin
            for (i = 0; i < n; i = i + 1) begin
                @(posedge clk);
                peak       <= p;
                frame_done <= 1'b1;
                @(posedge clk);
                frame_done <= 1'b0;
                repeat (2) @(posedge clk);
            end
        end
    endtask

    // 「一次响 + 一次静」重复 k 次
    task burst(input [15:0] loud_p, input integer n_on,
               input [15:0] quiet_p, input integer n_off,
               input integer k);
        integer j;
        begin
            for (j = 0; j < k; j = j + 1) begin
                frm(loud_p, n_on);
                frm(quiet_p, n_off);
            end
        end
    endtask

    task reset_dut;
        begin
            rst_n = 1'b0;
            peak  = 16'd0;
            frame_done = 1'b0;
            repeat (8) @(posedge clk);
            rst_n = 1'b1;
            repeat (8) @(posedge clk);
            // 计数器必须等复位释放之后再清零：
            // 在 rst_n 拉低的那些时钟沿上，always 块读到的仍是上一场景的
            // rhythm 残留值，会把这个最大值记错（纯观测量问题，不影响判据）
            det        = 0;
            max_rhythm = 0;
        end
    endtask

    integer fails = 0;

    task check(input [255:0] name, input integer expect_det);
        begin
            if (expect_det == 1 && det >= 1) begin
                $display("  PASS  %0s  det=%0d  peak_rhythm=%0d", name, det, max_rhythm);
            end else if (expect_det == 0 && det == 0) begin
                $display("  PASS  %0s  det=%0d  peak_rhythm=%0d", name, det, max_rhythm);
            end else begin
                $display("  FAIL  %0s  det=%0d (expect %0d)  peak_rhythm=%0d",
                         name, det, expect_det, max_rhythm);
                fails = fails + 1;
            end
        end
    endtask

    initial begin
        $display("========================================");
        $display(" snore_judge 单元测试  (v3 实测标定版)");
        $display(" TH=%0d ES=%0d MIN_ON=%0d GAP=[%0d,%0d] NPER=%0d",
                 P_TH, P_ES, P_MO, P_GMIN, P_GMAX, P_NPER);
        $display("========================================");

        //---- 场景 1：典型鼾声 ----
        reset_dut;
        $display("[1] 3 x (47 响@2000 + 64 静)   期望: 检测");
        burst(16'd2000, 47, 16'd100, 64, 3);
        frm(16'd100, 100);
        check("s1_typical_snore", 1);

        //---- 场景 2：短促咔哒 ----
        reset_dut;
        $display("[2] 3 x ( 4 响@2000 + 40 静)   期望: 不检测（太短）");
        burst(16'd2000, 4, 16'd100, 40, 3);
        frm(16'd100, 100);
        check("s2_short_click", 0);

        //---- 场景 3：持续噪声 ----
        reset_dut;
        $display("[3] 连续 300 帧一直响@2000     期望: 不检测（无节律）");
        frm(16'd2000, 300);
        frm(16'd100, 200);
        check("s3_continuous_fan", 0);

        //---- 场景 4：呼吸太慢 ----
        reset_dut;
        $display("[4] 3 x (47 响@2000 +150 静)   期望: 不检测（间隔过长）");
        burst(16'd2000, 47, 16'd100, 150, 3);
        frm(16'd100, 100);
        check("s4_too_slow", 0);

        //---- 场景 5：慢而重的鼾声 ----
        reset_dut;
        $display("[5] 3 x (60 响@3000 + 80 静)   期望: 检测");
        burst(16'd3000, 60, 16'd100, 80, 3);
        frm(16'd100, 100);
        check("s5_slow_heavy", 1);

        //---- 场景 6：说话音节 ----
        reset_dut;
        $display("[6] 3 x (30 响@2000 +  6 静)   期望: 不检测（间隙被填平）");
        burst(16'd2000, 30, 16'd100, 6, 3);
        frm(16'd100, 100);
        check("s6_speech_syllable", 0);

        //---- 场景 7：节律断链 ----
        reset_dut;
        $display("[7] 2段鼾声 + 6.4s停顿 + 1段    期望: 不检测（断链重数）");
        burst(16'd2000, 47, 16'd100, 64, 2);
        frm(16'd100, 200);              // 6.4s 停顿，远超 GAP_MAX
        burst(16'd2000, 47, 16'd100, 64, 1);
        frm(16'd100, 100);
        check("s7_chain_broken", 0);

        //---- 场景 8：说话紧接鼾声 ----
        reset_dut;
        $display("[8] 说话3句 紧接 鼾声3次       期望: 检测");
        burst(16'd2000, 30, 16'd100, 6, 3);    // 说话，不产生节律
        frm(16'd100, 40);
        burst(16'd2000, 47, 16'd100, 64, 3);   // 鼾声，应当判出
        frm(16'd100, 100);
        check("s8_speech_then_snore", 1);

        //---- 场景 9：小音量（麦克风偏远）----
        reset_dut;
        $display("[9] 3 x (47 响@1400 + 64 静)   期望: 检测（音量 0.7x）");
        burst(16'd1400, 47, 16'd100, 64, 3);
        frm(16'd100, 100);
        check("s9_low_volume", 1);

        //---- 场景 10：大音量（贴近喇叭）----
        reset_dut;
        $display("[10] 3 x (47 响@2600 + 64 静)  期望: 检测（音量 1.3x）");
        burst(16'd2600, 47, 16'd100, 64, 3);
        frm(16'd100, 100);
        check("s10_high_volume", 1);

        $display("========================================");
        if (fails == 0) $display(" ALL PASS");
        else            $display(" FAILED: %0d 项", fails);
        if (align_err == 0) $display(" E/S 对齐检查: PASS (0 次错位)");
        else                $display(" E/S 对齐检查: FAIL (%0d 次错位)", align_err);
        $display("========================================");
        $finish;
    end

    initial begin
        #20_000_000;
        $display("ERROR: timeout");
        $finish;
    end

endmodule
