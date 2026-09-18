import Foundation

/// 串行落盘队列。
///
/// 项目的 JSON 可能到 MB 级，直接在主线程写会卡顿；actor 保证写入按顺序执行，
/// 又不会像并发 Task 那样出现「旧快照后写覆盖新快照」。
public actor PersistenceWriter {
    private let store: PersistenceStore

    public init(store: PersistenceStore) {
        self.store = store
    }

    public func save(projects: [Project], workspace: WorkspaceState?) {
        for project in projects {
            try? store.save(project: project)
        }
        if let workspace {
            try? store.save(workspace: workspace)
        }
    }

    public func save(project: Project) {
        try? store.save(project: project)
    }

    public func deleteProject(id: UUID) {
        try? store.deleteProject(id: id)
    }
}
