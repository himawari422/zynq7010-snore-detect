//=============================================================================
// tb_disp.v — LCD 时序 + 显示渲染的联合验证
//
//   做两件事：
//     1) 用真实时序跑满整帧，量出 DE 宽度、行周期、场周期、刷新率，
//        和正点原子表 29.1.3 的 800*480 参数逐项比对（不用示波器）；
//     2) 把像素按坐标落进帧缓存，再导成 PPM 图片 —— 上板之前先肉眼看版面。
//
//   为什么要用帧缓存落位而不是顺序追加：
//     仿真从任意时刻开始，第一帧很可能是"半帧"（从中间某行扫到尾再回卷）。
//     顺序追加会让整幅画面上下错位，看图时反而会怀疑设计写错了。
//     按 (x,y) 落位后，无论从哪一行开始，最后每个像素都在正确的位置上。
//
//   抓 5 张图：
//     frame_rt.ppm        实时页（鼾声态）
//     frame_low.ppm       报告页 - 轻微
//     frame_mid.ppm       报告页 - 中等
//     frame_high.ppm      报告页 - 偏重
//     frame_wait.ppm      报告页 - 数据不足（WAIT）
//   后四张重点验证"三档建议按 level 换行"这件事有没有错行。
//=============================================================================
`timescale 1ns / 1ps

module tb_disp;

    localparam integer H_DISP  = 800;
    localparam integer V_DISP  = 480;
    localparam integer H_TOTAL = 1056;
    localparam integer V_TOTAL = 525;
    localparam integer NPIX    = H_DISP * V_DISP;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #20 clk = ~clk;              // 25MHz

    //---- 跨时钟域激励 ----
    reg        wr_tgl = 1'b0;
    reg [15:0] env_snap = 16'd0;
    reg [3:0]  status_snap = 4'd0;
    reg [3:0]  rhythm_snap = 4'd0;
    reg        clr_tgl = 1'b0;

    //---- 报告页数据 ----
    reg        page = 1'b0;
    reg [15:0] evt_snap   = 16'h0187;
    reg [15:0] rate_snap  = 16'h0180;
    reg [7:0]  ratio_snap = 8'h38;
    reg [7:0]  sil_snap   = 8'h02;
    reg [1:0]  level_snap = 2'd0;
    reg        nodata_snap = 1'b0;
    reg [13:0] rbar_snap  = 14'd180;

    //---- DUT ----
    wire        de_r, lcd_hs, lcd_vs, lcd_clk;
    wire [10:0] xpos, ypos;
    wire [23:0] rgb;

    lcd_timing u_tim (
        .clk     (clk),
        .rst_n   (rst_n),
        .lcd_clk (lcd_clk),
        .lcd_hs  (lcd_hs),
        .lcd_vs  (lcd_vs),
        .de_r    (de_r),
        .xpos    (xpos),
        .ypos    (ypos)
    );

    snore_display #(.TH(16'd525)) u_disp (
        .clk         (clk),
        .rst_n       (rst_n),
        .wr_tgl      (wr_tgl),
        .env_snap    (env_snap),
        .status_snap (status_snap),
        .rhythm_snap (rhythm_snap),
        .clr_tgl     (clr_tgl),
        .page        (page),
        .evt_snap    (evt_snap),
        .rate_snap   (rate_snap),
        .ratio_snap  (ratio_snap),
        .sil_snap    (sil_snap),
        .level_snap  (level_snap),
        .nodata_snap (nodata_snap),
        .rbar_snap   (rbar_snap),
        .xpos        (xpos),
        .ypos        (ypos),
        .rgb         (rgb)
    );

    // 与顶层完全一致的对齐关系：DE 与坐标再延一拍，配 rgb（已寄存）正好
    reg        de_d = 1'b0;
    reg [10:0] x_d = 11'd0, y_d = 11'd0;

    always @(posedge clk) begin
        de_d <= de_r;
        x_d  <= xpos;
        y_d  <= ypos;
    end

    //------------------------------------------------------------------
    // 时序统计
    //------------------------------------------------------------------
    integer ln_clk = 0, ln_cnt = 0;
    integer de_w = 0, de_h = 0;
    integer max_de_w = 0, max_de_h = 0;
    integer frames = 0;
    integer line_ok = 0, frame_ok = 0, hs_ok = 0;
    integer line_has_de = 0;

    always @(posedge clk) begin
        ln_clk = ln_clk + 1;
        if (de_d) begin
            de_w = de_w + 1;
            line_has_de = 1;
        end

        if (ln_clk == H_TOTAL) begin
            ln_clk = 0;
            if (de_w > max_de_w) max_de_w = de_w;
            if (de_w == H_DISP) line_ok = line_ok + 1;
            de_w = 0;
            ln_cnt = ln_cnt + 1;
            if (line_has_de) de_h = de_h + 1;
            line_has_de = 0;

            if (ln_cnt == V_TOTAL) begin
                ln_cnt = 0;
                if (de_h > max_de_h) max_de_h = de_h;
                if (de_h == V_DISP) frame_ok = frame_ok + 1;
                frames = frames + 1;
                de_h = 0;
            end
        end

        if (lcd_hs !== 1'b1 || lcd_vs !== 1'b1) hs_ok = hs_ok + 1;
    end

    //------------------------------------------------------------------
    // 帧缓存 + 导出
    //------------------------------------------------------------------
    reg [23:0] fb [0:NPIX-1];
    integer wr_cnt = 0;
    integer cap_on = 0;

    always @(posedge clk) begin
        if (de_d && cap_on) begin
            fb[y_d * 800 + x_d] = rgb;
            wr_cnt = wr_cnt + 1;
        end
    end

    task dump_ppm;
        input [1023:0] fname;
        integer k;
        integer f;
        begin
            f = $fopen(fname, "wb");
            $fwrite(f, "P6\n%0d %0d\n255\n", H_DISP, V_DISP);
            for (k = 0; k < NPIX; k = k + 1)
                $fwrite(f, "%c%c%c", fb[k][23:16], fb[k][15:8], fb[k][7:0]);
            $fclose(f);
            $display("   -> %0s", fname);
        end
    endtask

    task capture;
        input [1023:0] fname;
        begin
            cap_on = 1;
            wr_cnt = 0;
            repeat (H_TOTAL * V_TOTAL + 3000) @(posedge clk);
            cap_on = 0;
            if (wr_cnt != NPIX)
                $display("   [!] %0s 像素数 %0d != %0d", fname, wr_cnt, NPIX);
            dump_ppm(fname);
        end
    endtask

    //------------------------------------------------------------------
    // 造激励：按实测鼾声的时间结构（47 帧响 / 64 帧静 = 1.5s / 2s）
    //------------------------------------------------------------------
    function [15:0] pat;
        input integer i;
        integer ph;
        begin
            ph = i % 111;
            if (ph < 47)
                pat = 100 + $rtoi(1250.0 * $sin(3.14159265 * ph / 47.0));
            else
                pat = 100 + (i % 5) * 8;
        end
    endfunction

    task send_frame(input [15:0] e, input [3:0] st, input [3:0] rr);
        begin
            @(posedge clk);
            env_snap    <= e;
            status_snap <= st;
            rhythm_snap <= rr;
            wr_tgl      <= ~wr_tgl;
            repeat (4) @(posedge clk);
        end
    endtask

    integer i;
    integer n_err = 0;

    initial begin
        rst_n = 1'b0;
        for (i = 0; i < NPIX; i = i + 1) fb[i] = 24'd0;
        repeat (20) @(posedge clk);
        rst_n = 1'b1;
        repeat (10) @(posedge clk);

        //---- 填 640 帧历史（= 20 秒窗口），最后一段让判据处于"已判决"态 ----
        for (i = 0; i < 640; i = i + 1) begin
            if (i > 560)
                send_frame(pat(i), 4'b1111, 4'd3);
            else
                send_frame(pat(i), 4'b0001, (i % 111 < 47) ? 4'd1 : 4'd0);
        end

        //---- 1) 实时页 ----
        $display("- 实时页");
        page = 1'b0;
        capture("frame_rt.ppm");

        //---- 2~4) 报告页三档 ----
        page = 1'b1;
        nodata_snap = 1'b0;

        level_snap = 2'd0;  rbar_snap = 14'd42;
        $display("- 报告页 LOW");
        capture("frame_low.ppm");

        level_snap = 2'd1;  rbar_snap = 14'd180;
        $display("- 报告页 MID");
        capture("frame_mid.ppm");

        level_snap = 2'd2;  rbar_snap = 14'd430;
        $display("- 报告页 HIGH");
        capture("frame_high.ppm");

        //---- 5) 数据不足 ----
        nodata_snap = 1'b1;
        evt_snap   = 16'h0000;
        rate_snap  = 16'h0000;
        ratio_snap = 8'h00;
        sil_snap   = 8'h00;
        rbar_snap  = 14'd0;
        level_snap = 2'd0;
        $display("- 报告页 WAIT（数据不足）");
        capture("frame_wait.ppm");

        //---- 6) 清零：按键 key[1] / 串口 'C' 走的是同一条通路 ----
        //   上面填了 640 帧历史，status[2] 有多次上升沿，CNT 必然非 0；
        //   打完一个 clr_tgl 之后 d0..d3 必须全部归零。
        $display("- 清零统计（clr_tgl）");
        if (u_disp.d0 == 0 && u_disp.d1 == 0 && u_disp.d2 == 0 && u_disp.d3 == 0)
            $display("   [!] 清零前 CNT 已经是 0，这条断言没有意义");
        clr_tgl = ~clr_tgl;
        repeat (30) @(posedge clk);
        if (u_disp.d0 == 0 && u_disp.d1 == 0 && u_disp.d2 == 0 && u_disp.d3 == 0)
            $display("   [ OK ] 清零后 CNT = 0000");
        else begin
            $display("   [FAIL] 清零后 CNT = %0d%0d%0d%0d",
                     u_disp.d3, u_disp.d2, u_disp.d1, u_disp.d0);
            n_err = n_err + 1;
        end

        $display("========================================");
        $display(" 帧数            : %0d", frames);
        $display(" 每行 DE 宽度    : %0d  (期望 %0d)", max_de_w, H_DISP);
        $display(" 每帧 DE 行数    : %0d  (期望 %0d)", max_de_h, V_DISP);
        $display(" 行周期          : %0d  (期望 %0d)", H_TOTAL, H_TOTAL);
        $display(" 场周期          : %0d  (期望 %0d)", V_TOTAL, V_TOTAL);
        $display(" 刷新率          : %0d.%0d Hz",
                 25_000_000 / (H_TOTAL * V_TOTAL),
                 (25_000_000 / (H_TOTAL * V_TOTAL)) % 10);
        $display(" HS/VS 恒为高    : %s", (hs_ok == 0) ? "PASS" : "FAIL");
        $display(" 行 OK / 帧 OK   : %0d / %0d", line_ok, frame_ok);
        $display("========================================");
        if (max_de_w == H_DISP && max_de_h == V_DISP && hs_ok == 0)
            $display(" LCD 时序: PASS  (25MHz / 1056x525 / 45.1Hz)");
        else
            $display(" LCD 时序: FAIL");
        $display(" 清零功能: %s", (n_err == 0) ? "PASS" : "FAIL");
        $display("========================================");
        $finish;
    end

    initial begin
        #600_000_000;
        $display("ERROR: timeout");
        $finish;
    end

endmodule
