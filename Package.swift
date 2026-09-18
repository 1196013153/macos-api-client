// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "APIClient",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "APIClient", targets: ["APIClient"]),
        .library(name: "ApiClientCore", targets: ["ApiClientCore"]),
    ],
    targets: [
        // 纯逻辑层：模型 / 持久化 / 变量解析 / 请求引擎 / 状态机。不 import SwiftUI，可独立验证。
        .target(name: "ApiClientCore", path: "Sources/ApiClientCore"),

        // 界面层：SwiftUI 视图 + 应用入口。
        .executableTarget(name: "APIClient", dependencies: ["ApiClientCore"], path: "Sources/APIClient"),
    ]
)
