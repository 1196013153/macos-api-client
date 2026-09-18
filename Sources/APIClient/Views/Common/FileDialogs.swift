import AppKit
import UniformTypeIdentifiers

/// 原生文件选择面板封装。
enum FileDialogs {
    static func openJSON(message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = message
        panel.prompt = "选择"
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func saveJSON(defaultName: String) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = defaultName
        panel.prompt = "导出"
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// 为 form-data 的文件字段选本地文件（不限制类型，接口可能收任意格式）。
    static func openUploadFile(message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.resolvesAliases = true
        panel.message = message
        panel.prompt = "选择文件"
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func revealInFinder(path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
