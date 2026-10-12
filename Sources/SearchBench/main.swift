// SearchBench 入口。实现见同目录 BenchSupport.swift。
//
// 数据集说明：
// - 默认生成 100000 条**内存合成**条目（--count 1000000 可到 100 万条），
//   不会在磁盘上创建对应文件，也不扫描任何用户目录。
// - 只有显式加 --scan-files N 才会在 NSTemporaryDirectory() 下真实创建 N 个小文件
//   测扫描吞吐（N 上限 20000，测完立即删除）。
// stdout 输出 JSON 报告，stderr 输出人读摘要，
// 退出码 0=自检通过，1=自检失败，2=参数错误。
import Foundation

let benchExitCode: Int32 = await SearchBenchRunner.run(arguments: Array(CommandLine.arguments.dropFirst()))
exit(benchExitCode)
