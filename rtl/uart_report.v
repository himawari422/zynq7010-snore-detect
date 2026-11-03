//=============================================================================
// uart_report.v
//   每帧把统计结果格式化成一行 ASCII 打印出来，格式固定 38 字节：
//
//       F0012 P01F4 A0033 E02A1 S9 C0E R2 G0\r\n
//       |     |     |     |     |   |   |  |
//       |     |     |     |     |   |   |  +-- G: 页面回显 {页号, 命令计数[2:0]}
//       |     |     |     |     |   |   +----- R: 已积累的节律次数 (0~N)
//       |     |     |     |     |   +--------- C: 当前 burst 已连续超阈帧数
//       |     |     |     |     +------------- S: 判据状态位 (1 位十六进制)
//       |     |     |     +------------------- E: 响度包络 (4 位十六进制)
//       |     |     +------------------------- A: 平均绝对值
//       |     +------------------------------- P: 峰值
//       +------------------------------------- F: 帧序号 (4 位十六进制，会循环)
//
//   S 的位定义（来自 snore_judge）：
//       bit0 = 当前帧响度包络超过门限
//       bit1 = 已连续超阈够长（一次有效的声事件）
//       bit2 = 判定为鼾声（带保持）
//       bit3 = 已进入节律链
//
//   E / C / R 三个字段是 v2 新增的"可观测性"字段：
//     调参阶段光看 P 值猜不出判据为什么不动，
//     把包络 E、burst 长度 C、节律计数 R 直接打出来，
//     任何一次误判/漏判都能一眼定位到是哪一条判据卡住。
//
//   G 是 v4 新增的"控制回显"字段（对应串口命令 P/T/R/C/?）：
//       bit3      = 当前显示的页  0 实时 / 1 报告
//       bit2..0   = 已收到的合法命令数（3 位循环，见 cmd_parse.v）
//     上位机发一条命令后，只要看到 G 的命令计数变了，就说明板子收到了，
//     不必靠肉眼盯屏幕确认。这个字段同时也是"页面状态"的权威来源 ——
//     电脑端的按钮高亮就按它来，不会和板子实际显示的页错开。
//
//   用十六进制而不是十进制，是为了省掉 PL 里的除法器；
//   配套的 snore_mon.py / snore_test.py / snore_ctl.py 直接按这个格式解析。
//
//   一行 38 字节 @115200 约 3.3ms，帧周期 32ms，占用带宽约 10.3%，不会丢。
//=============================================================================
`timescale 1ns / 1ps

module uart_report (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        frame_done,
    input  wire [15:0] frame_no,
    input  wire [15:0] peak,
    input  wire [15:0] mean_abs,
    input  wire [15:0] env,
    input  wire [3:0]  status,
    input  wire [7:0]  on_cnt,
    input  wire [3:0]  rhythm,
    //---- 控制回显（来自顶层：按键与串口命令合成的页面状态）----
    input  wire        page,        // 0 实时 / 1 报告
    input  wire [2:0]  cmd_cnt,     // 已收到的合法串口命令数
    output wire        txd
);

    localparam integer LINE_LEN = 38;

    //------------------------------------------------------------------
    // 串口发送器
    //------------------------------------------------------------------
    reg  [7:0] tx_data;
    reg        tx_start;
    wire       tx_busy;

    uart_tx #(
        .CLK_FREQ (50_000_000),
        .BAUD     (115200)
    ) u_uart (
        .clk   (clk),
        .rst_n (rst_n),
        .data  (tx_data),
        .start (tx_start),
        .busy  (tx_busy),
        .txd   (txd)
    );

    //------------------------------------------------------------------
    // 半字节转 ASCII
    //------------------------------------------------------------------
    function [7:0] hx;
        input [3:0] v;
        begin
            hx = (v < 10) ? (8'h30 + {4'd0, v}) : (8'h37 + {4'd0, v});
        end
    endfunction

    //------------------------------------------------------------------
    // 发送流程
    //------------------------------------------------------------------
    localparam integer S_IDLE = 2'd0;
    localparam integer S_PUT  = 2'd1;
    localparam integer S_WAIT = 2'd2;

    reg [1:0]  st;
    reg [5:0]  idx;
    reg [15:0] f_no;
    reg [15:0] f_pk;
    reg [15:0] f_ma;
    reg [15:0] f_ev;
    reg [3:0]  f_st;
    reg [7:0]  f_oc;
    reg [3:0]  f_rh;
    reg [3:0]  f_g;
    reg        busy_seen;
    reg [7:0]  byte_sel;

    always @(*) begin
        case (idx)
            6'd0 : byte_sel = 8'h46;                // 'F'
            6'd1 : byte_sel = hx(f_no[15:12]);
            6'd2 : byte_sel = hx(f_no[11:8]);
            6'd3 : byte_sel = hx(f_no[7:4]);
            6'd4 : byte_sel = hx(f_no[3:0]);
            6'd5 : byte_sel = 8'h20;                // ' '
            6'd6 : byte_sel = 8'h50;                // 'P'
            6'd7 : byte_sel = hx(f_pk[15:12]);
            6'd8 : byte_sel = hx(f_pk[11:8]);
            6'd9 : byte_sel = hx(f_pk[7:4]);
            6'd10: byte_sel = hx(f_pk[3:0]);
            6'd11: byte_sel = 8'h20;                // ' '
            6'd12: byte_sel = 8'h41;                // 'A'
            6'd13: byte_sel = hx(f_ma[15:12]);
            6'd14: byte_sel = hx(f_ma[11:8]);
            6'd15: byte_sel = hx(f_ma[7:4]);
            6'd16: byte_sel = hx(f_ma[3:0]);
            6'd17: byte_sel = 8'h20;                // ' '
            6'd18: byte_sel = 8'h45;                // 'E'
            6'd19: byte_sel = hx(f_ev[15:12]);
            6'd20: byte_sel = hx(f_ev[11:8]);
            6'd21: byte_sel = hx(f_ev[7:4]);
            6'd22: byte_sel = hx(f_ev[3:0]);
            6'd23: byte_sel = 8'h20;                // ' '
            6'd24: byte_sel = 8'h53;                // 'S'
            6'd25: byte_sel = hx(f_st);
            6'd26: byte_sel = 8'h20;                // ' '
            6'd27: byte_sel = 8'h43;                // 'C'
            6'd28: byte_sel = hx(f_oc[7:4]);
            6'd29: byte_sel = hx(f_oc[3:0]);
            6'd30: byte_sel = 8'h20;                // ' '
            6'd31: byte_sel = 8'h52;                // 'R'
            6'd32: byte_sel = hx(f_rh);
            6'd33: byte_sel = 8'h20;                // ' '
            6'd34: byte_sel = 8'h47;                // 'G'
            6'd35: byte_sel = hx(f_g);
            6'd36: byte_sel = 8'h0D;                // '\r'
            default: byte_sel = 8'h0A;              // '\n'
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st        <= S_IDLE;
            idx       <= 6'd0;
            f_no      <= 16'd0;
            f_pk      <= 16'd0;
            f_ma      <= 16'd0;
            f_ev      <= 16'd0;
            f_st      <= 4'd0;
            f_oc      <= 8'd0;
            f_rh      <= 4'd0;
            f_g       <= 4'd0;
            tx_data   <= 8'd0;
            tx_start  <= 1'b0;
            busy_seen <= 1'b0;
        end else begin
            case (st)
                S_IDLE: begin
                    tx_start <= 1'b0;
                    if (frame_done) begin
                        f_no <= frame_no;
                        f_pk <= peak;
                        f_ma <= mean_abs;
                        f_ev <= env;
                        f_st <= status;
                        f_oc <= on_cnt;
                        f_rh <= rhythm;
                        // 页号与命令计数在 frame_done 这一拍一起锁存。
                        // 命令可能在两句之间到达，最坏情况是本行 G 的
                        // 页号跟计数差一拍，下一行（32ms 后）就正确了 ——
                        // 上位机按 G 做状态同步时会连续读几帧，不受影响。
                        f_g  <= {page, cmd_cnt};
                        idx  <= 6'd0;
                        st   <= S_PUT;
                    end
                end

                S_PUT: begin
                    tx_data  <= byte_sel;
                    tx_start <= 1'b1;
                    st       <= S_WAIT;
                end

                S_WAIT: begin
                    tx_start <= 1'b0;
                    if (tx_busy)
                        busy_seen <= 1'b1;
                    else if (busy_seen) begin
                        busy_seen <= 1'b0;
                        if (idx == LINE_LEN-1) begin
                            st <= S_IDLE;
                        end else begin
                            idx <= idx + 6'd1;
                            st  <= S_PUT;
                        end
                    end
                end

                default: st <= S_IDLE;
            endcase
        end
    end

endmodule
