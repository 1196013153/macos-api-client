import Foundation
import ApiClientCore

// 入口分流。
//
// 顶层代码不支持 `await`，所以命令行分支都放进 Task，再靠主 RunLoop 驱动到结束
// （SelfCheck / CLI 内部完成时会自行 exit）。
let arguments = CommandLine.arguments

func value(after flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

if arguments.contains("--self-check") {
    Task { await SelfCheck.run() }
    RunLoop.main.run()
} else if let path = value(after: "--import") {
    Task { await CLI.importFile(at: path) }
    RunLoop.main.run()
} else if let path = value(after: "--snapshot") {
    Task { await SnapshotRenderer.run(outputDirectory: path) }
    RunLoop.main.run()
} else if arguments.contains("--info") {
    Task { await CLI.printInfo() }
    RunLoop.main.run()
} else {
    APIClientApp.main()
}
