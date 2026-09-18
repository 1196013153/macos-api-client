import Foundation
import ApiClientCore

/// 命令行入口（与界面共用同一套存储与导入逻辑）。
@MainActor
enum CLI {

    /// `APIClient --import <file>`：批量导入 wac 工作区 / 项目 JSON。
    static func importFile(at path: String) async {
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        guard FileManager.default.fileExists(atPath: url.path) else {
            fail("文件不存在：\(url.path)", code: 2)
        }

        let store = AppStore()
        print("数据目录：\(store.storageRootPath)")
        print("导入前：\(store.projects.count) 个项目 / \(store.totalRequestCount) 个接口")

        let started = Date()
        let count = store.importProjects(from: url)
        await store.flushSaveAndWait()
        let elapsed = Date().timeIntervalSince(started)

        guard count > 0 else {
            fail("导入失败：\(store.notice?.text ?? "未知原因")", code: 1)
        }

        print(String(format: "导入 %d 个项目，耗时 %.2fs", count, elapsed))
        print("导入后：\(store.projects.count) 个项目 / \(store.totalRequestCount) 个接口")
        for project in store.projects.sorted(by: { $0.name < $1.name }) {
            print("  · \(project.name)：\(project.requests.count) 接口 / \(project.environments.count) 环境 / \(project.collection.count) 个顶层目录")
        }

        await store.waitForPendingWrites()
        exit(0)
    }

    /// `APIClient --info`：查看当前数据目录与项目概况。
    static func printInfo() async {
        let store = AppStore()
        print("数据目录：\(store.storageRootPath)")
        print("项目数：\(store.projects.count)，接口总数：\(store.totalRequestCount)")
        for project in store.projects.sorted(by: { $0.name < $1.name }) {
            let environment = project.activeEnvironment
            print("  · \(project.name)：\(project.requests.count) 接口 / \(project.environments.count) 环境")
            print("      当前环境：\(environment?.name ?? "-")  baseURL：\(environment?.baseURL ?? "-")")
        }
        if !store.loadFailures.isEmpty {
            print("读取失败的项目文件：")
            store.loadFailures.forEach { print("  ! \($0)") }
        }
        exit(0)
    }

    private static func fail(_ message: String, code: Int32) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(code)
    }
}
