//=============================================================================
// tb_rx.v — 串口接收 + 命令解析的联合验证
//
//   验证四件事：
//     ① 位级采样对不对：115200 / 8N1，8 个字节的收发必须逐一对上（含 0x00/0xFF）；
//     ② 毛刺会不会被误判成起始位：故意打一个 200ns 的低脉冲，不能产生 valid；
//     ③ command dispatch对不对：P 翻转、T/R 强制切页、C 清零、? 只计数；
//     ④ 非法字节要静默丢弃，不能动页面、不能改命令计数。
//
//   仿真里不设 DUT 的时钟分频参数为默认值，直接用 50MHz / 115200 = 434，
//   和上板配置完全一致，避免"仿真过、上板不过"。
//=============================================================================
`timescale 1ns / 1ps

module tb_rx;

    localparam integer BIT_NS = 8680;       // 115200bps 的一位约 8.68us

    reg clk = 1'b0;
    reg rst_n = 1'b0;

    always #10 clk = ~clk;                  // 50MHz

    //------------------------------------------------------------------
    // DUT
    //------------------------------------------------------------------
    reg        rxd = 1'b1;
    wire [7:0] rx_data;
    wire       rx_valid;

    uart_rx #(
        .CLK_FREQ (50_000_000),
        .BAUD     (115200)
    ) u_rx (
        .clk   (clk),
        .rst_n (rst_n),
        .rxd   (rxd),
        .data  (rx_data),
        .valid (rx_valid)
    );

    wire       page_tgl;
    wire       page_set_en;
    wire       page_set_val;
    wire       clr;
    wire [2:0] cmd_cnt;
    wire       cmd_seen;

    cmd_parse u_cmd (
        .clk          (clk),
        .rst_n        (rst_n),
        .rx_valid     (rx_valid),
        .rx_data      (rx_data),
        .page_tgl     (page_tgl),
        .page_set_en  (page_set_en),
        .page_set_val (page_set_val),
        .clr          (clr),
        .cmd_cnt      (cmd_cnt),
        .cmd_seen     (cmd_seen)
    );

    //------------------------------------------------------------------
    // 页面模型：优先级与 snore_top 一致（强制指定 > 翻转）
    //------------------------------------------------------------------
    reg page = 1'b0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)                page <= 1'b0;
        else if (page_set_en)      page <= page_set_val;
        else if (page_tgl)         page <= ~page;
    end

    //------------------------------------------------------------------
    // 观测计数
    //------------------------------------------------------------------
    integer n_valid = 0;
    integer n_tgl   = 0;
    integer n_set   = 0;
    integer n_clr   = 0;
    integer n_err   = 0;

    reg [7:0] last_data = 8'd0;

    always @(posedge clk) begin
        if (rx_valid) begin
            n_valid   = n_valid + 1;
            last_data = rx_data;
        end
        if (page_tgl)    n_tgl = n_tgl + 1;
        if (page_set_en) n_set = n_set + 1;
        if (clr)         n_clr = n_clr + 1;
    end

    //------------------------------------------------------------------
    // 发一个字节（位宽与真实波特率一致）
    //------------------------------------------------------------------
    task send_byte;
        input [7:0] b;
        integer i;
        begin
            rxd = 1'b0;                     // 起始位
            #(BIT_NS);
            for (i = 0; i < 8; i = i + 1) begin
                rxd = b[i];                 // LSB 先发
                #(BIT_NS);
            end
            rxd = 1'b1;                     // 停止位
            #(BIT_NS);
        end
    endtask

    task expect_int;
        input [1023:0] what;
        input integer  got;
        input integer  want;
        begin
            if (got != want) begin
                $display("  [FAIL] %0s: want %0d, got %0d", what, want, got);
                n_err = n_err + 1;
            end else begin
                $display("  [ OK ] %0s = %0d", what, got);
            end
        end
    endtask

    //------------------------------------------------------------------
    // 主流程
    //------------------------------------------------------------------
    initial begin
        $display("========================================");
        $display(" uart_rx + cmd_parse simulation");
        $display("========================================");

        repeat (20) @(posedge clk);
        rst_n = 1'b1;
        repeat (10) @(posedge clk);

        //---- ① 毛刺：200ns 低脉冲，不能被当成起始位 ----
        $display("- glitch rejection");
        rxd = 1'b0;
        #200;
        rxd = 1'b1;
        #(BIT_NS * 2);
        expect_int("bytes from glitch", n_valid, 0);

        //---- ② bit-level rx：0x00 / 0xFF 是最容易错的两个边界 ----
        $display("- bit-level rx");
        send_byte(8'h00);
        expect_int("valid count after 0x00", n_valid, 1);
        expect_int("data of 0x00", last_data, 8'h00);
        send_byte(8'hFF);
        expect_int("valid count after 0xFF", n_valid, 2);
        expect_int("data of 0xFF", last_data, 8'hFF);

        // 这两个字节都不是命令，命令计数应当还是 0
        expect_int("cmd_cnt after non-cmd bytes", cmd_cnt, 0);
        expect_int("page after non-cmd bytes", page, 0);

        //---- ③ command dispatch ----
        $display("- command dispatch");

        send_byte("P");                     // 翻转
        repeat (10) @(posedge clk);
        expect_int("cmd_cnt after 'P'", cmd_cnt, 1);
        expect_int("page after 'P' (0->1)", page, 1);
        expect_int("toggle count after 'P'", n_tgl, 1);

        send_byte("t");                     // 强制实时页（小写）
        repeat (10) @(posedge clk);
        expect_int("cmd_cnt after 't'", cmd_cnt, 2);
        expect_int("page after 't' (->0)", page, 0);
        expect_int("page_set count", n_set, 1);

        send_byte("R");                     // 强制报告页
        repeat (10) @(posedge clk);
        expect_int("cmd_cnt after 'R'", cmd_cnt, 3);
        expect_int("page after 'R' (->1)", page, 1);

        send_byte("0");                     // 数字 0 等同 T
        repeat (10) @(posedge clk);
        expect_int("page after '0' (->0)", page, 0);
        send_byte("1");                     // 数字 1 等同 R
        repeat (10) @(posedge clk);
        expect_int("page after '1' (->1)", page, 1);

        send_byte("c");                     // 清零
        repeat (10) @(posedge clk);
        expect_int("cmd_cnt after 'c'", cmd_cnt, 6);
        expect_int("clr pulse count", n_clr, 1);

        send_byte("?");                     // 探活：只计数
        repeat (10) @(posedge clk);
        expect_int("cmd_cnt after '?'", cmd_cnt, 7);
        expect_int("'?' must not change page", page, 1);
        expect_int("'?' must not clear", n_clr, 1);

        // 计数到 7 之后再来一条会回到 0（3 位循环），这是设计如此
        send_byte("H");
        repeat (10) @(posedge clk);
        expect_int("cmd_cnt wrap to 0", cmd_cnt, 0);

        expect_int("cmd_seen flag", cmd_seen, 1);

        //---- ④ 帧间空闲足够长时不能把停止位误当成新起始位 ----
        $display("- long idle");
        #(BIT_NS * 8);
        expect_int("valid count after idle", n_valid, 10);

        $display("========================================");
        if (n_err == 0)
            $display(" RESULT: PASS (0 failures)");
        else
            $display(" RESULT: FAIL (%0d failures)", n_err);
        $display("========================================");
        $finish;
    end

    initial begin
        #20_000_000;
        $display("ERROR: timeout");
        $finish;
    end

endmodule
