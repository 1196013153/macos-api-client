import SwiftUI
import ApiClientCore

/// 环境的语义颜色。
///
/// 环境没有"颜色"这个字段，也不该为了配色去改数据模型——这里按名字推断：
/// 生产红、预发黄、测试绿，认不出来的用中性品牌色。
/// 目的只有一个：发请求前，用余光就能知道自己打在哪个环境上。
enum EnvironmentTone {
    static func color(for environment: APIEnvironment?) -> Color {
        guard let environment else { return DS.color.textTertiary }
        let name = (environment.name + " " + environment.baseURL).lowercased()

        if contains(name, ["生产", "线上", "正式", "prod", "release"]) { return DS.color.danger }
        if contains(name, ["预发", "灰度", "staging", "stage", "pre", "uat"]) { return DS.color.warning }
        if contains(name, ["测试", "开发", "本地", "test", "dev", "local", "sit"]) { return DS.color.success }
        return DS.color.brand
    }

    /// 生产环境值得多提醒一句。
    static func isProduction(_ environment: APIEnvironment?) -> Bool {
        guard let environment else { return false }
        let name = (environment.name + " " + environment.baseURL).lowercased()
        return contains(name, ["生产", "线上", "正式", "prod", "release"])
    }

    private static func contains(_ haystack: String, _ needles: [String]) -> Bool {
        needles.contains { haystack.contains($0) }
    }
}

/// 内容区顶部的环境色轨。
struct EnvironmentRail: View {
    @Environment(AppStore.self) private var store

    private var environment: APIEnvironment? { store.activeProject?.activeEnvironment }

    var body: some View {
        Rectangle()
            .fill(EnvironmentTone.color(for: environment))
            .frame(height: 2)
            .help("当前环境：\(environment?.name ?? "未选择")")
            .animation(DS.motion.select, value: environment?.id)
    }
}
