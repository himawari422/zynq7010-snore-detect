#=============================================================================
# build.tcl  —  一键建工程 / 仿真 / 综合 / 生成比特流
#
# 用法（在任意目录下执行）：
#   vivado -mode batch -source build.tcl -tclargs <输出目录> sim
#   vivado -mode batch -source build.tcl -tclargs <输出目录> synth
#   vivado -mode batch -source build.tcl -tclargs <输出目录> impl
#
# 举例：
#   vivado -mode batch -source snore_pdm/scripts/build.tcl -tclargs C:/snore_build impl
#
# 注意：Vivado 对路径里的空格和中文极其敏感（正点原子资料里也提醒过）。
#       本脚本检测到源路径含空格时，会自动把 rtl/constr/tb 复制到
#       <输出目录>/_src 下再建工程。<输出目录> 必须是不含空格和中文的路径。
#=============================================================================

set root    [file dirname [file dirname [info script]]]
set outdir  [expr {[llength $argv] > 0 ? [lindex $argv 0] : [file join $root build]}]
set mode    [expr {[llength $argv] > 1 ? [lindex $argv 1] : "synth"}]

if {[string first " " $outdir] >= 0} {
    puts "ERROR: 输出目录不能含空格：$outdir"
    puts "       请换一个路径，例如 C:/snore_build"
    exit 1
}

puts "== ROOT   : $root"
puts "== OUTDIR : $outdir"
puts "== MODE   : $mode"

#--------------------------------------------------------------------
# 路径含空格时，先复制到干净目录
#--------------------------------------------------------------------
set stage $root
if {[string first " " $root] >= 0} {
    set stage [file join $outdir _src]
    file delete -force $stage
    foreach d {rtl constr tb} {
        file mkdir [file join $stage $d]
        foreach f [glob -nocomplain [file join $root $d *]] {
            file copy $f [file join $stage $d]
        }
    }
    puts "== 源路径含空格，已复制到: $stage"
}
puts "== STAGE  : $stage"

file mkdir $outdir
create_project -force snore_pdm $outdir -part xc7z010clg400-1

#---- 源文件（逐个别加，避免空格路径被拆开）----
foreach f [lsort [glob [file join $stage rtl *.v]]] {
    add_files -norecurse -fileset sources_1 $f
}
add_files -norecurse -fileset constrs_1 [file join $stage constr snore_pdm.xdc]
add_files -norecurse -fileset sim_1     [file join $stage tb tb_snore.v]
add_files -norecurse -fileset sim_1     [file join $stage tb tb_judge.v]
add_files -norecurse -fileset sim_1     [file join $stage tb tb_disp.v]
add_files -norecurse -fileset sim_1     [file join $stage tb tb_rx.v]

set_property top snore_top [get_filesets sources_1]
if {$mode eq "judge"} {
    set_property top tb_judge [get_filesets sim_1]
} elseif {$mode eq "disp"} {
    set_property top tb_disp [get_filesets sim_1]
} elseif {$mode eq "rx"} {
    set_property top tb_rx [get_filesets sim_1]
} else {
    set_property top tb_snore [get_filesets sim_1]
}
update_compile_order -fileset sources_1

if {$mode eq "sim" || $mode eq "judge" || $mode eq "disp" || $mode eq "rx"} {
    launch_simulation -mode behavioral
    run all
    close_sim
    puts "== SIM FINISHED"
} else {
    launch_runs synth_1 -jobs 4
    wait_on_run synth_1
    open_run synth_1 -name synth_1
    report_utilization -file [file join $outdir util_synth.rpt]
    report_timing_summary -file [file join $outdir timing_synth.rpt]
    puts "== SYNTH DONE"
}

if {$mode eq "impl"} {
    launch_runs impl_1 -to_step write_bitstream -jobs 4
    wait_on_run impl_1
    open_run impl_1
    report_utilization -file [file join $outdir util_impl.rpt]
    report_timing_summary -file [file join $outdir timing_impl.rpt]
    puts "== IMPL DONE"
    puts "== BITSTREAM: [file join $outdir snore_pdm.runs impl_1 snore_top.bit]"
}
