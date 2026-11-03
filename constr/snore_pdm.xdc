#=============================================================================
# snore_pdm.xdc  —  正点原子 领航者 ZYNQ7010（ATK-DF7010P，底板 V3.9）
#                   呼噜声检测 PDM 采集前端 引脚约束
#
# 引脚来源：《领航者ZYNQ IO引脚分配总表》(PL 表) + 底板原理图 V3.9 的 J3 排针
#=============================================================================

#---------------------------- 系统时钟 50MHz --------------------------------
set_property -dict {PACKAGE_PIN U18 IOSTANDARD LVCMOS33} [get_ports sys_clk]
create_clock -period 20.000 -name sys_clk [get_ports sys_clk]

#---------------------------- 复位按键（低有效）-----------------------------
set_property -dict {PACKAGE_PIN N16 IOSTANDARD LVCMOS33} [get_ports sys_rst_n]

#---------------------------- PDM 麦克风（J3 扩展口）------------------------
# J3-20 现为 LCD_B0 网络；J3-19 现为 LCD_B1 网络
# 这两个脚是 RGB LCD 蓝色最低两位，拔掉屏后完全空闲，占用影响可忽略
set_property -dict {PACKAGE_PIN W18 IOSTANDARD LVCMOS33} [get_ports pdm_clk]
set_property -dict {PACKAGE_PIN W19 IOSTANDARD LVCMOS33} [get_ports pdm_dat]

# 2MHz 方波走杜邦线，压摆率调慢一点可以减小过冲和辐射
set_property SLEW SLOW  [get_ports pdm_clk]
set_property DRIVE 8    [get_ports pdm_clk]

# pdm_dat 相对本地时钟是异步信号，已在逻辑中做了两级同步
set_false_path -from [get_ports pdm_dat]

#---------------------------- USB 串口（PL 侧，双向）-----------------------
# 板上跳线帽必须接到 PL 侧：丝印 "PL UART: Connect 3&5 4&6"
#   TXD = J15  板 -> 电脑，每 32ms 一行 38 字节遥测
#   RXD = T19  电脑 -> 板，单字符命令 P/T/R/C/?（切页、清零、探活）
# 两个脚来自 NAVIGATOR_ZYNQ_IO.xdc 的 "USB UART" 段，
# 不要和 "PL_UART(RS232)/RS485" 段的 K14/M15 弄混 —— 那组走的是 DB9，
# 板载 CH340 的 USB 口接不到。
set_property -dict {PACKAGE_PIN J15 IOSTANDARD LVCMOS33} [get_ports uart_txd]
set_property DRIVE 8 [get_ports uart_txd]

# 空闲为高，加上拉避免板子没接电脑时输入悬空、误收一串假起始位
set_property -dict {PACKAGE_PIN T19 IOSTANDARD LVCMOS33 PULLUP true} [get_ports uart_rxd]

# 串口是异步输入，逻辑里已做两级同步 + 半位宽复查，不需要时序约束
set_false_path -from [get_ports uart_rxd]

#---------------------------- 蜂鸣器 ---------------------------------------
set_property -dict {PACKAGE_PIN M14 IOSTANDARD LVCMOS33} [get_ports beep]

#---------------------------- LED（低电平点亮）------------------------------
set_property -dict {PACKAGE_PIN H15 IOSTANDARD LVCMOS33} [get_ports {led[0]}]
set_property -dict {PACKAGE_PIN L15 IOSTANDARD LVCMOS33} [get_ports {led[1]}]
set_property -dict {PACKAGE_PIN J16 IOSTANDARD LVCMOS33} [get_ports {led[2]}]

#---------------------------- PL 按键（低有效，内部上拉）--------------------
# 来源：《NAVIGATOR_ZYNQ_IO.xdc》的 PL_KEY 段
#   key[0] 切页：实时页 <-> 报告页
#   key[1] 清零统计
set_property -dict {PACKAGE_PIN L14 IOSTANDARD LVCMOS33 PULLUP true} [get_ports {key[0]}]
set_property -dict {PACKAGE_PIN K16 IOSTANDARD LVCMOS33 PULLUP true} [get_ports {key[1]}]

#=============================================================================
# RGB LCD（ATK-4384 / 4.3 寸 800x480 / 40PIN FPC）
#
# 引脚来源：《NAVIGATOR_ZYNQ_IO.xdc》（正点原子官方引脚约束）
#
# ★ 关键：lcd_rgb 只约束 [23:2]，**故意跳过 [1:0]**
#   lcd_rgb[0] = W18 = 麦克风 PDM_CLK
#   lcd_rgb[1] = W19 = 麦克风 PDM_DAT
#   如果这里也约束了 [1:0]，Vivado 会把 lcd_rgb 的低两位分配到 W18/W19，
#   和麦克风抢同一根线；而端口声明成 [23:2] 之后这两根线根本不存在，
#   物理上就不可能被抢走。
#   RGB565 只用 B[7:3]，B0/B1 本来就不需要。
#=============================================================================

#---------------------------- 颜色数据 RGB888（去掉 B0/B1）------------------
set_property -dict {PACKAGE_PIN R16 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[2]}]
set_property -dict {PACKAGE_PIN R17 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[3]}]
set_property -dict {PACKAGE_PIN W20 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[4]}]
set_property -dict {PACKAGE_PIN V20 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[5]}]
set_property -dict {PACKAGE_PIN P18 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[6]}]
set_property -dict {PACKAGE_PIN N17 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[7]}]
set_property -dict {PACKAGE_PIN V17 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[8]}]
set_property -dict {PACKAGE_PIN V18 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[9]}]
set_property -dict {PACKAGE_PIN T17 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[10]}]
set_property -dict {PACKAGE_PIN R18 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[11]}]
set_property -dict {PACKAGE_PIN Y18 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[12]}]
set_property -dict {PACKAGE_PIN Y19 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[13]}]
set_property -dict {PACKAGE_PIN P15 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[14]}]
set_property -dict {PACKAGE_PIN P16 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[15]}]
set_property -dict {PACKAGE_PIN V16 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[16]}]
set_property -dict {PACKAGE_PIN W16 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[17]}]
set_property -dict {PACKAGE_PIN T14 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[18]}]
set_property -dict {PACKAGE_PIN T15 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[19]}]
set_property -dict {PACKAGE_PIN Y17 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[20]}]
set_property -dict {PACKAGE_PIN Y16 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[21]}]
set_property -dict {PACKAGE_PIN T16 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[22]}]
set_property -dict {PACKAGE_PIN U17 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[23]}]

#---------------------------- 控制信号 --------------------------------------
set_property -dict {PACKAGE_PIN P19 IOSTANDARD LVCMOS33} [get_ports lcd_clk]
set_property -dict {PACKAGE_PIN U20 IOSTANDARD LVCMOS33} [get_ports lcd_de]
set_property -dict {PACKAGE_PIN N18 IOSTANDARD LVCMOS33} [get_ports lcd_hs]
set_property -dict {PACKAGE_PIN T20 IOSTANDARD LVCMOS33} [get_ports lcd_vs]
set_property -dict {PACKAGE_PIN M20 IOSTANDARD LVCMOS33} [get_ports lcd_bl]
set_property -dict {PACKAGE_PIN L17 IOSTANDARD LVCMOS33} [get_ports lcd_rst_n]

# 像素时钟是 sys_clk 二分频后过 BUFG 得到的，显式声明为生成时钟，
# 否则时序分析会把它当成无约束时钟（不影响功能，但报告里会有一堆警告）
create_generated_clock -name lcd_pclk -source [get_ports sys_clk] \
    -divide_by 2 [get_pins u_bufg_pclk/O]

# 25MHz 方波走 FPC 排线，压摆率调慢减小过冲与辐射
set_property SLEW SLOW  [get_ports lcd_clk]
set_property DRIVE 8    [get_ports lcd_clk]
set_property SLEW SLOW  [get_ports {lcd_rgb[*]}]
set_property DRIVE 8    [get_ports {lcd_rgb[*]}]
