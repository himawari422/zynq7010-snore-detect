//=============================================================================
// tb_snore.v
//   自检用 testbench：
//   用一阶 sigma-delta 把 300Hz 正弦调制成 PDM 码流，喂给 DUT，
//   再把 CIC 输出的 PCM 写进 pcm_out.txt，交给 Python 做 FFT 验证。
//
//   验证目标（硬指标，不是"看起来像"）：
//     1) 采样率必须是 16.000kHz
//     2) 频谱峰值必须落在 300Hz
//     3) 幅度必须约等于 0.6 * 29800 ≈ 17880
//        （密度摆幅 0.3 -> x=2d-1 摆幅 0.6 -> 满量程 29800）
//=============================================================================
`timescale 1ns / 1ps

module tb_snore;

    reg  clk    = 1'b0;
    reg  rst_n  = 1'b0;
    reg  pdm_dat = 1'b0;

    wire pdm_clk;
    wire uart_txd;
    wire beep;
    wire [2:0] led;

    // 50MHz
    always #10 clk = ~clk;

    snore_top #(
        .LED_ACT_LOW (1)
    ) dut (
        .sys_clk   (clk),
        .sys_rst_n (rst_n),
        .pdm_dat   (pdm_dat),
        .pdm_clk   (pdm_clk),
        .uart_rxd  (1'b1),          // 串口空闲为高：本测试不发下行命令
        .uart_txd  (uart_txd),
        .beep      (beep),
        .led       (led),
        .key       (2'b11)          // 按键低有效，全高 = 都没按
    );

    //------------------------------------------------------------------
    // PDM 激励：一阶 sigma-delta，300Hz 正弦，幅度 0.3
    //------------------------------------------------------------------
    localparam real F_TONE = 300.0;
    localparam real AMP    = 0.30;
    localparam real PI2    = 6.283185307179586;

    real acc_v = 0.0;
    real vin_v;
    real t_now;

    always @(posedge pdm_clk) begin
        t_now = $realtime / 1.0e9;
        vin_v = 0.5 + AMP * $sin(PI2 * F_TONE * t_now);
        acc_v = acc_v + (vin_v - (pdm_dat ? 1.0 : 0.0));
        // 60ns 后才更新数据，模拟麦克风 tCO + 走线延时
        #60 pdm_dat <= (acc_v >= 0.0);
    end

    //------------------------------------------------------------------
    // 采集输出
    //------------------------------------------------------------------
    integer fd;
    integer nsmp = 0;
    localparam integer NSMP_MAX = 1024;

    initial begin
        fd = $fopen("pcm_out.txt", "w");
        if (fd == 0) begin
            $display("ERROR: cannot open pcm_out.txt");
            $finish;
        end
    end

    always @(posedge clk) begin
        if (dut.pcm_valid) begin
            $fdisplay(fd, "%0d", $signed(dut.pcm));
            nsmp = nsmp + 1;
            if (nsmp == NSMP_MAX) begin
                $fclose(fd);
                $display("SIM_DONE samples=%0d", nsmp);
                $finish;
            end
        end
    end

    //------------------------------------------------------------------
    // 复位
    //------------------------------------------------------------------
    initial begin
        rst_n = 1'b0;
        #200;
        rst_n = 1'b1;
    end

    //------------------------------------------------------------------
    // 串口解码器：把 uart_txd 上的 115200 8N1 数据还原成字符打印出来
    //   用来验证 uart_report 的格式化与握手逻辑，不占用 DUT 逻辑
    //------------------------------------------------------------------
    localparam integer UDIV = 434;      // 50MHz / 115200

    integer ustate = 0;
    integer ucnt   = 0;
    integer ubit   = 0;
    reg [7:0] ubyte = 8'd0;

    always @(posedge clk) begin
        if (!rst_n) begin
            ustate <= 0;
        end else begin
            case (ustate)
                0: if (!uart_txd) begin
                       ustate <= 1;
                       ucnt   <= UDIV + UDIV/2;   // 对准 bit0 的中点
                       ubit   <= 0;
                       ubyte  <= 8'd0;
                   end else begin
                       ucnt   <= 0;
                   end

                1: if (ucnt == 0) begin
                       ubyte[ubit] <= uart_txd;
                       if (ubit == 7) begin
                           ustate <= 2;
                           ucnt   <= UDIV - 1;
                       end else begin
                           ubit   <= ubit + 1;
                           ucnt   <= UDIV - 1;
                       end
                   end else begin
                       ucnt <= ucnt - 1;
                   end

                2: if (ucnt == 0) begin
                       $write("%c", ubyte);   // 直接拼成一行，便于肉眼检查
                       ustate <= 0;
                   end else begin
                       ucnt <= ucnt - 1;
                   end
            endcase
        end
    end

    initial begin
        #100_000_000;                      // 100ms 超时保护（正常 64ms 就采够 1024 点）
        $display("ERROR: timeout");
        $finish;
    end

endmodule
