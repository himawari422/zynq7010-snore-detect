#=============================================================================
# program.tcl
#   通过 JTAG 把比特流下载到 PL。
#
#   用法：
#     vivado -mode batch -source scripts/program.tcl
#     可选 -tclargs <bit 文件路径>，缺省用工程里的 out/snore_top.bit
#
#   注意：这是"下载到 PL"，掉电即失效。要掉电保持得烧 QSPI Flash，
#         本脚本不做那件事。
#=============================================================================

set stage [file normalize [file join [file dirname [info script]] ..]]
set bit   [file join $stage out snore_top.bit]

if {$argc >= 1 && [lindex $argv 0] ne ""} {
    set bit [lindex $argv 0]
}

if {![file exists $bit]} {
    puts "PROGRAM_ERROR: bitstream not found: $bit"
    exit 1
}
puts "PROGRAM_INFO: bitstream = $bit ([file size $bit] bytes)"

#---- 打开硬件管理器并连接本地 hw_server ----
# Vivado 2018.3 这条命令叫 open_hw（open_hw_manager 是 2019 以后才有的）
open_hw
if {[catch {connect_hw_server} err]} {
    if {[catch {connect_hw_server -url localhost:3121} err2]} {
        puts "PROGRAM_ERROR: cannot connect hw_server: $err / $err2"
        exit 2
    }
}

#---- 打开目标（先尝试已有 target，失败再尝试新建）----
set targets [get_hw_targets]
if {[llength $targets] == 0} {
    puts "PROGRAM_ERROR: no JTAG target found (check USB cable / board power)"
    exit 3
}
puts "PROGRAM_INFO: targets = $targets"

if {[catch {open_hw_target [lindex $targets 0]} err]} {
    puts "PROGRAM_ERROR: cannot open hw_target: $err"
    exit 4
}

#---- 选 PL 器件（xc7z010_1 是 PL，_0 是 ARM）----
set dev ""
foreach d [get_hw_devices] {
    if {[string match "*xc7z010*" $d] && [string match "*1" $d]} {
        set dev $d
    }
}
if {$dev eq ""} {
    set dev [lindex [get_hw_devices] 0]
}
if {$dev eq ""} {
    puts "PROGRAM_ERROR: no device on chain"
    exit 5
}
puts "PROGRAM_INFO: device = $dev"

current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev

#---- 下载 ----
set_property PROGRAM.FILE $bit $dev
if {[catch {program_hw_devices $dev} err]} {
    puts "PROGRAM_ERROR: program failed: $err"
    exit 6
}

refresh_hw_device $dev

# DONE 状态不查 REGISTER.IR.BIT3_DONE（2018.3 没有这个属性）：
# program_hw_devices 会自己打印 "End of startup status: HIGH"，
# 那就是 DONE 拉高的意思；这里只做一次不带 probe 的刷新确认器件还在。
if {[catch {set prop [get_property PROGRAM.FILE $dev]} err]} {
    puts "PROGRAM_INFO: refresh warning: $err"
} else {
    puts "PROGRAM_INFO: loaded file = $prop"
}

close_hw_target
disconnect_hw_server
close_hw

puts "PROGRAM_DONE: OK"
