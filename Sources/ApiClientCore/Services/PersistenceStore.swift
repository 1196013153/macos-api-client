import Foundation

public enum PersistenceError: LocalizedError {
    case cannotCreateDirectory(String)
    case projectNotFound(UUID)
    case decodeFailed(file: String, underlying: String)
    case encodeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .cannotCreateDirectory(let path):
            return "无法创建数据目录：\(path)"
        case .projectNotFound(let id):
            return "项目不存在：\(id.uuidString)"
        case .decodeFailed(let file, let underlying):
            return "文件解析失败：\(file)（\(underlying)）"
        case .encodeFailed(let reason):
            return "序列化失败：\(reason)"
        }
    }
}

/// 存储布局：
/// ```
/// ~/Library/Application Support/APIClient/
/// ├── workspace.json          项目索引 / 打开的标签 / 设置
/// └── projects/<uuid>.json    单个项目的全部内容
/// ```
/// 一个项目一个文件，方便 git 管理与手工检查；单请求独立成文件是后续演进方向。
public struct PersistencePaths: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public var workspaceFile: URL { root.appendingPathComponent("workspace.json") }
    public var projectsDirectory: URL { root.appendingPathComponent("projects", isDirectory: true) }

    public func projectFile(_ id: UUID) -> URL {
        projectsDirectory.appendingPathComponent("\(id.uuidString).json")
    }
}

public final class PersistenceStore: @unchecked Sendable {
    public let paths: PersistencePaths
    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(root: URL? = nil) {
        self.paths = PersistencePaths(root: root ?? PersistenceStore.defaultRoot())
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    public static func defaultRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("APIClient", isDirectory: true)
    }

    // MARK: - 目录

    public func bootstrap() throws {
        do {
            try fileManager.createDirectory(at: paths.projectsDirectory, withIntermediateDirectories: true)
        } catch {
            throw PersistenceError.cannotCreateDirectory(paths.projectsDirectory.path)
        }
    }

    // MARK: - 工作区

    public func loadWorkspace() -> WorkspaceState {
        guard let data = try? Data(contentsOf: paths.workspaceFile) else {
            return WorkspaceState()
        }
        return (try? decoder.decode(WorkspaceState.self, from: data)) ?? WorkspaceState()
    }

    public func save(workspace: WorkspaceState) throws {
        try write(workspace, to: paths.workspaceFile)
    }

    // MARK: - 项目

    public func loadProjects() -> (projects: [Project], failures: [String]) {
        var projects: [Project] = []
        var failures: [String] = []
        let files = (try? fileManager.contentsOfDirectory(
            at: paths.projectsDirectory,
            includingPropertiesForKeys: nil
        )) ?? []

        for file in files where file.pathExtension == "json" {
            do {
                let data = try Data(contentsOf: file)
                projects.append(try decoder.decode(Project.self, from: data))
            } catch {
                failures.append("\(file.lastPathComponent): \(error.localizedDescription)")
            }
        }
        projects.sort { $0.createdAt < $1.createdAt }
        return (projects, failures)
    }

    public func save(project: Project) throws {
        try bootstrap()
        try write(project, to: paths.projectFile(project.id))
    }

    public func deleteProject(id: UUID) throws {
        let file = paths.projectFile(id)
        guard fileManager.fileExists(atPath: file.path) else { return }
        try fileManager.removeItem(at: file)
    }

    /// 从任意 JSON 文件读取一个项目（用于导入 / 单项目分享）。
    public func readProject(from url: URL) throws -> Project {
        let data = try Data(contentsOf: url)
        do {
            return try decoder.decode(Project.self, from: data)
        } catch {
            throw PersistenceError.decodeFailed(file: url.lastPathComponent, underlying: error.localizedDescription)
        }
    }

    /// 导出单个项目为 JSON 文件（分享 / 备份）。
    public func exportProject(_ project: Project, to url: URL) throws {
        try write(project, to: url)
    }

    // MARK: - 内部

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        do {
            let data = try encoder.encode(value)
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        } catch let error as PersistenceError {
            throw error
        } catch {
            throw PersistenceError.encodeFailed("\(url.lastPathComponent): \(error.localizedDescription)")
        }
    }
}
