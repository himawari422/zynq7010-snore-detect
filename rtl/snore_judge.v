//=============================================================================
// snore_judge.v
//   鼾声判据（A 方案：可解释的三条件融合，不依赖神经网络）
//
//   为什么要换掉单纯的门限？
//     只比"这一帧响不响"，风噪、说话、关门、吹风机全会触发。
//     鼾声真正区别于其他声音的是三点：
//       ① 够响      —— 包络超过标定门限
//       ② 够长      —— 一次鼾声持续 0.4~3s；关门声只有几十 ms
//       ③ 有节律    —— 鼾声随呼吸起伏，两次之间隔 0.1~3s，连续出现多次
//
//   判据 = ①∩②∩③。三条都满足才判为鼾声。
//
//   一个重要的副产物：
//     持续稳定的强噪声（风扇、吹风机、白噪声）永远不会"结束"，
//     所以它一次有效 burst 都凑不齐 —— 天然不会误报。
//
//-----------------------------------------------------------------------------
//   v2 的关键改动：为什么要加包络跟踪
//
//   2026-10-28 第一次真人实测（20s / 628 帧）暴露了问题：
//     超阈帧 31%，节律链进得去，但鼾声判决 0 次。
//   把 25 段超阈 burst 画出来才看明白：
//     相邻 burst 的间隔大多是 1~6 帧（32~192ms），
//     而旧参数 GAP_MIN_F=8（256ms）要求"间隔至少 256ms 才算一次间隔"，
//     于是判据把一次连续发声切成了十几块碎片，
//     每块都 < MIN_ON_F，节律链永远建立不起来。
//
//   解决：不再拿单帧 peak 比门限，而是先做包络跟踪
//         响度包络 = 峰值包络（快起 + 慢落）
//     快起：peak 一超过包络就立刻跟上 —— 鼾声起始点不失真
//     慢落：peak 掉下去后按 1/2^ENV_SHIFT 逐帧衰减 —— 把音节间隙填平
//     ENV_SHIFT=3 → 时间常数 8 帧 = 256ms，
//     从满幅衰减到门限约需 7 帧（224ms），
//     正好覆盖实测到的 1~6 帧间隙，而真正的呼吸间隔（≥0.5s）依然会被切开。
//
//   这个结构在信号处理里就是经典的"峰值包络检波器"，
//   好处是只用移位和比较，不占乘法器、不占 DSP，且完全可解释。
//
//-----------------------------------------------------------------------------
//   v3：真人分段实测标定（2026-10-28，6 段 / 3648 帧 / 117s）
//
//   用 snore_test.py 采集「安静→说话→拍手→鼾声→安静」5 段真实声音，
//   把每一帧的 peak 存进 CSV，再用 tune.py 在 PC 上把判据原样重跑，
//   对 TH / ENV_SHIFT / MIN_ON / GAP_MIN / GAP_MAX 做全组合网格搜索。
//
//   结论（关键的一条）：
//     说话和鼾声的"响度"几乎无法区分 —— 说话段包络 p90=759，
//     鼾声段 p90=855，两者重叠严重。真正能分开的是**间隔尺度**：
//       说话：句子内音节间隙 50~300ms，句子间停顿 0.3~1s
//       鼾声：一次 1.5~2s，两次之间隔 2~3s
//     所以 GAP_MIN_F 从 2 抬到 9（288ms）是压制说话误报的主力，
//     而 TH 抬高到 525 只是把说话的低声部分排除在 burst 之外。
//
//   旧参数 (TH400/ES3/MO12/GM2) 在实测数据上是「15 秒说话误报 4 次」，
//   新参数在 0.7~1.3 倍音量范围内全部 0 误报、鼾声段稳定检出 5~10 次。
//
//-----------------------------------------------------------------------------
//   时间参数（帧周期 32ms @16kHz / 512 点）：
//     ENV_SHIFT = 4   -> 包络释放时间常数 512ms（填平 300ms 以内的间隙）
//     MIN_ON_F  = 8   -> 256ms   最短有效鼾声
//     GAP_MIN_F = 9   -> 288ms   两次鼾声最小间隔（切掉说话的音节间隙）
//     GAP_MAX_F = 96  -> 3072ms  两次鼾声最大间隔（覆盖慢呼吸周期）
//     N_PERIOD  = 3   -> 连续 3 次节律才判决
//=============================================================================
`timescale 1ns / 1ps

module snore_judge #(
    parameter [15:0] TH         = 16'd525,   // 响度包络门限（实测标定）
    parameter integer ENV_SHIFT = 4,         // 包络释放速度：越大落得越慢
    parameter integer MIN_ON_F  = 8,         // 有效 burst 最短帧数
    parameter integer GAP_MIN_F = 9,         // 节律间隔下限（帧）
    parameter integer GAP_MAX_F = 96,        // 节律间隔上限（帧）
    parameter integer N_PERIOD  = 3,         // 需要连续几次节律
    parameter integer HOLD_F    = 32,        // 判定后指示灯保持（帧）
    parameter integer BEEP_F    = 7          // 蜂鸣器时长（帧，约 224ms）
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        frame_done,
    input  wire [15:0] peak,
    output reg   [2:0] led,                  // [0]有声音 [1]持续发声 [2]判定鼾声
    output reg         beep,
    output reg   [3:0] status,               // 串口上报的状态位
    //---- 以下三个只用于串口观测（调参用），不影响判据 ----
    output wire [15:0] env,                  // 响度包络（本帧参与判断的值）
    output reg  [7:0]  on_cnt,               // 当前 burst 已连续超阈的帧数（包络口径）
    output wire [7:0]  raw_len,              // 当前 burst 内原始超阈帧数（MIN_ON 判的就是它）
    output reg  [3:0]  rhythm                // 已积累的节律次数
);

    //---- 参数转成定宽常量，避免对 integer 做位选 ----
    localparam [7:0]  MIN_ON  = MIN_ON_F;
    localparam [9:0]  GAP_MIN = GAP_MIN_F;
    localparam [9:0]  GAP_MAX = GAP_MAX_F;
    localparam [3:0]  NPER    = N_PERIOD;
    localparam [7:0]  HOLDF   = HOLD_F;
    localparam [7:0]  BEEPF   = BEEP_F;

    reg [9:0]  idle_cnt;    // 距上一个 burst 结束的帧数（饱和）
    reg [9:0]  gap_lat;     // 本次 burst 起始时锁存的间隔
    reg [7:0]  hold;        // 判决保持计数
    reg [7:0]  btim;        // 蜂鸣器倒计时
    reg [15:0] env_r;       // 包络寄存值
    reg [7:0]  raw_cnt;     // burst 内"原始 peak 直接超阈"的帧数

    //------------------------------------------------------------------
    // 峰值包络检波器：快起慢落
    //   peak >= env  ->  env 直接等于 peak（0 延迟跟随）
    //   peak <  env  ->  env 按 1/2^ENV_SHIFT 指数衰减
    // 用本帧的"下一拍值"参与判断，避免整整一帧的滞后
    //------------------------------------------------------------------
    wire [15:0] env_nxt = (peak >= env_r) ? peak
                                          : (env_r - (env_r >> ENV_SHIFT));

    // 输出用寄存值 env_r，而不是组合的 env_nxt。
    // 原因：uart_report 在 frame_done 那一拍采样，采到的是"本帧更新前"的值，
    // status/on_cnt/rhythm 都是寄存器，所以 E 也必须是寄存器，
    // 否则会出现「E 已经超过门限、但 S 的响位还是 0」这种自相矛盾的数据，
    // 调参时会被误导。（实测过：E=472 而 S=0，下一帧 E=362 而 S=1，正好差一帧）
    assign env = env_r;
    assign raw_len = raw_cnt;

    wire loud = (env_nxt > TH);

    //------------------------------------------------------------------
    // 原始超阈：直接用本帧 peak 比门限，不经过包络
    //
    // 为什么要单独判一次？
    //   包络"慢落"会把一次很短的响声拉长成很宽的高电平：
    //   实测 4 帧（128ms）的咔哒声 @2000，衰减到门限 525 要走 21 帧，
    //   于是 on_cnt 数到 25 帧，轻轻松松满足 MIN_ON=8 ——
    //   "够长"这条判据就被包络骗过去了。
    //   所以 MIN_ON 必须用 raw_cnt（原始超阈帧数）来判，
    //   包络只负责"切分"，不负责"计长"。
    //------------------------------------------------------------------
    wire loud_raw = (peak > TH);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            env_r    <= 16'd0;
            on_cnt   <= 8'd0;
            raw_cnt  <= 8'd0;
            idle_cnt <= 10'd0;
            gap_lat  <= 10'd0;
            rhythm   <= 4'd0;
            hold     <= 8'd0;
            btim     <= 8'd0;
            led      <= 3'b000;
            beep     <= 1'b0;
            status   <= 4'b0000;
        end else if (frame_done) begin

            //---- 包络跟踪 ----
            env_r <= env_nxt;

            //---- 先倒计时（下面若触发会覆盖）----
            if (hold != 8'd0) hold <= hold - 8'd1;
            if (btim != 8'd0) begin
                btim <= btim - 8'd1;
                beep <= 1'b1;
            end else begin
                beep <= 1'b0;
            end

            //---- 主判据 ----
            if (loud) begin
                if (on_cnt == 8'd0) begin
                    // burst 开始的那一拍：锁存"距上次 burst 有多久"，
                    // 同时把原始计数归零（不能留上一个 burst 的残值）
                    gap_lat <= idle_cnt;
                    raw_cnt <= loud_raw ? 8'd1 : 8'd0;
                end else if (loud_raw) begin
                    // 包络还高着，本帧原始峰值也超阈 -> 累加"真实发声"长度
                    raw_cnt <= (raw_cnt == 8'hFF) ? raw_cnt : (raw_cnt + 8'd1);
                end
                on_cnt   <= (on_cnt == 8'hFF) ? on_cnt : (on_cnt + 8'd1);
                idle_cnt <= 10'd0;
            end else begin
                if (raw_cnt >= MIN_ON) begin
                    // 一个"声音本身够长"的 burst 刚刚结束
                    // （判 raw_cnt 而不是 on_cnt，否则短促咔哒会被包络拉长后蒙混过关）
                    if (rhythm != 4'd0 &&
                        gap_lat >= GAP_MIN && gap_lat <= GAP_MAX) begin
                        if (rhythm + 4'd1 >= NPER) begin
                            rhythm <= NPER;
                            hold   <= HOLDF;
                            btim   <= BEEPF;
                        end else begin
                            rhythm <= rhythm + 4'd1;
                        end
                    end else begin
                        // 间隔不在鼾声节律范围内，重新起链
                        rhythm <= 4'd1;
                    end
                end
                on_cnt  <= 8'd0;
                raw_cnt <= 8'd0;
                if (idle_cnt != 10'd1023)
                    idle_cnt <= idle_cnt + 10'd1;

                // 太久没有新的 burst，节律链断开
                if (idle_cnt > GAP_MAX && rhythm != 4'd0)
                    rhythm <= 4'd0;
            end

            //---- 输出（用本拍更新前的值，差一帧可忽略）----
            led[0] <= loud;
            led[1] <= (raw_cnt >= MIN_ON);
            led[2] <= (hold != 8'd0);

            status[0] <= loud;                  // 响
            status[1] <= (raw_cnt >= MIN_ON);   // 原始发声持续够长
            status[2] <= (hold != 8'd0);        // 判为鼾声
            status[3] <= (rhythm >= 4'd2);      // 已进入节律
        end
    end

endmodule
