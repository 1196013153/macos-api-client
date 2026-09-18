import Foundation

// MARK: - 导入 / 导出

public extension AppStore {

    /// 导入 wac 工作区（多项目）或单个项目 JSON。
    /// - Returns: 新增的项目数量
    @discardableResult
    func importProjects(from url: URL) -> Int {
        do {
            let imported = try WACImport.projects(from: url)
            guard !imported.isEmpty else {
                setNotice("文件里没有可导入的项目", level: .error)
                return 0
            }

            var created: [Project] = []
            for var project in imported {
                let sourceName = project.name
                project.name = uniqueProjectName(sourceName)
                // 导入的项目若与已有项目同名，自动加序号，避免侧边栏认不出来
                if project.name != sourceName {
                    project.note = project.note.isEmpty
                        ? "由「\(sourceName)」导入"
                        : project.note + "\n（由「\(sourceName)」导入）"
                }
                created.append(project)
            }

            projects.append(contentsOf: created)
            if let first = created.first {
                activeProjectID = first.id
                sidebarFilter = ""
            }
            for project in created {
                enqueueSave(projects: [project])
            }
            flushSave()

            let requestCount = created.reduce(0) { $0 + $1.requests.count }
            setNotice("已导入 \(created.count) 个项目 / \(requestCount) 个接口")
            return created.count
        } catch {
            setNotice("导入失败：\(error.localizedDescription)", level: .error)
            return 0
        }
    }

    /// 导出单个项目为 JSON 文件。
    func exportProject(id: UUID, to url: URL) {
        guard let project = project(id: id) else { return }
        do {
            try storage.exportProject(project, to: url)
            setNotice("已导出「\(project.name)」")
        } catch {
            setNotice("导出失败：\(error.localizedDescription)", level: .error)
        }
    }

    private func uniqueProjectName(_ name: String) -> String {
        let existing = Set(projects.map(\.name))
        guard existing.contains(name) else { return name }
        var index = 2
        while existing.contains("\(name) (\(index))") {
            index += 1
        }
        return "\(name) (\(index))"
    }
}
