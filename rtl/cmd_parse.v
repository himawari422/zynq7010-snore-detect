//=============================================================================
// cmd_parse.v
//   串口单字符命令解析 —— 让电脑也能做板上那两个按键能做的事
//
//   为什么用单字符而不是 "PAGE=REPORT\r\n" 这种文本协议：
//     ① PL 里解析字符串要缓冲、要比对、要处理超时，几十行状态机只为省一次按键；
//     ② 单字符在串口助手里直接敲一个字母就能用，不需要任何上位机；
//     ③ 误码时最坏结果是执行错一条命令，而不是卡在"半条命令"里等不到结尾。
//
//   命令表（大小写都收，串口助手不用切输入法）：
//     P / p        翻转当前页（实时 <-> 报告），等同按 key[0]
//     T / t / 0    强制切到实时页
//     R / r / 1    强制切到报告页
//     C / c        清零统计，等同按 key[1]
//     ?  / h / H   仅探活：不做任何动作，只让命令计数 +1（用来确认线路通）
//
//   其它任何字节（含 \r \n 和乱码）一律忽略，不会动页面。
//
//   所有合法命令都会让 cmd_cnt 加 1（3 位，0~7 循环），
//   这个数会随串口上报帧的 G 字段回到电脑 ——
//   上位机发完命令后看到它变了，就证明板子确实收到了，不用靠肉眼盯屏幕。
//=============================================================================
`timescale 1ns / 1ps

module cmd_parse (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       rx_valid,      // 来自 uart_rx 的单拍脉冲
    input  wire [7:0] rx_data,
    //---- 控制输出，均为单拍脉冲（page_set 除外，它带一个数据位）----
    output reg        page_tgl,      // 翻转页面
    output reg        page_set_en,   // 强制指定页面
    output reg        page_set_val,  // 0 实时 / 1 报告
    output reg        clr,           // 清零统计
    //---- 回显 ----
    output reg  [2:0] cmd_cnt,       // 已收到的合法命令数（循环）
    output reg        cmd_seen       // 开机以来是否收到过任何合法命令
);

    // 字符常量，避免代码里散落 0x50 这种魔数
    localparam [7:0] C_P_UP  = 8'h50, C_P_LO = 8'h70;   // 'P' 'p'
    localparam [7:0] C_T_UP  = 8'h54, C_T_LO = 8'h74;   // 'T' 't'
    localparam [7:0] C_R_UP  = 8'h52, C_R_LO = 8'h72;   // 'R' 'r'
    localparam [7:0] C_C_UP  = 8'h43, C_C_LO = 8'h63;   // 'C' 'c'
    localparam [7:0] C_Q     = 8'h3F;                   // '?'
    localparam [7:0] C_H_UP  = 8'h48, C_H_LO = 8'h68;   // 'H' 'h'
    localparam [7:0] C_0     = 8'h30;
    localparam [7:0] C_1     = 8'h31;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            page_tgl    <= 1'b0;
            page_set_en <= 1'b0;
            page_set_val<= 1'b0;
            clr         <= 1'b0;
            cmd_cnt     <= 3'd0;
            cmd_seen    <= 1'b0;
        end else begin
            // 默认全部拉低，只在下面命中时给一拍脉冲
            page_tgl    <= 1'b0;
            page_set_en <= 1'b0;
            clr         <= 1'b0;

            if (rx_valid) begin
                case (rx_data)
                    C_P_UP, C_P_LO: begin
                        page_tgl <= 1'b1;
                        cmd_cnt  <= cmd_cnt + 3'd1;
                        cmd_seen <= 1'b1;
                    end

                    C_T_UP, C_T_LO, C_0: begin
                        page_set_en  <= 1'b1;
                        page_set_val <= 1'b0;
                        cmd_cnt      <= cmd_cnt + 3'd1;
                        cmd_seen     <= 1'b1;
                    end

                    C_R_UP, C_R_LO, C_1: begin
                        page_set_en  <= 1'b1;
                        page_set_val <= 1'b1;
                        cmd_cnt      <= cmd_cnt + 3'd1;
                        cmd_seen     <= 1'b1;
                    end

                    C_C_UP, C_C_LO: begin
                        clr      <= 1'b1;
                        cmd_cnt  <= cmd_cnt + 3'd1;
                        cmd_seen <= 1'b1;
                    end

                    C_Q, C_H_UP, C_H_LO: begin
                        cmd_cnt  <= cmd_cnt + 3'd1;
                        cmd_seen <= 1'b1;
                    end

                    default: ;      // 静默丢弃
                endcase
            end
        end
    end

endmodule
