import Foundation
import ApiClientCore

/// 无界面自检：`APIClient --self-check`
///
/// 这是本项目的官方测试套件，覆盖变量解析、请求编排、JSON 解析、项目模型、
/// 持久化往返、多项目 / 跨项目标签语义，以及从参考项目（uTools 版）导入工作区。
///
/// 刻意不依赖 XCTest：开发机只装了 Command Line Tools（不含 XCTest / swift-testing 模块），
/// 零依赖才能保证「任何环境都能跑一遍」，包括没有完整 Xcode 的 CI。
@MainActor
enum SelfCheck {

    private static var passed = 0
    private static var failed = 0
    private static var failureNames: [String] = []
    private static var sandbox: URL?

    static func run() async {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("apiclient-selfcheck-\(UUID().uuidString)")

        print("APIClient 自检")
        print(String(repeating: "─", count: 60))

        checkVariables()
        checkRequestBuilder()
        checkJSONParser()
        checkSSEStream()
        checkResponseTreeFilter()
        checkMock()
        checkFormData()
        checkEditorLocator()
        checkProjectModel()
        checkPersistenceRoundTrip()
        await checkFavorites()
        checkRequestSearch()
        await checkProjectsAndTabs()
        checkWorkspaceImport()
        await checkJavaSync()

        print(String(repeating: "─", count: 60))
        if failed == 0 {
            print("全部通过：\(passed) 项")
        } else {
            print("通过 \(passed) 项，失败 \(failed) 项：")
            failureNames.forEach { print("  · \($0)") }
        }

        cleanup()
        // 给 stdout 一点时间落盘，避免被 exit 截断。
        try? await Task.sleep(for: .milliseconds(50))
        exit(failed == 0 ? 0 : 1)
    }

    // MARK: - 断言基础设施

    private static func section(_ title: String) {
        print("\n[\(title)]")
    }

    private static func check(_ name: String, _ condition: @autoclosure () -> Bool, detail: String = "") {
        if condition() {
            passed += 1
            print("  ✓ \(name)")
        } else {
            failed += 1
            failureNames.append(name)
            print("  ✗ \(name)\(detail.isEmpty ? "" : " → \(detail)")")
        }
    }

    private static func expectEqual<T: Equatable>(_ name: String, _ actual: T, _ expected: T) {
        check(name, actual == expected, detail: "实际 \(actual)，期望 \(expected)")
    }

    // MARK: - 变量解析

    private static func checkVariables() {
        section("变量解析")

        let context = VariableContext(
            environment: ["host": "env.example.com", "token": "env-token"],
            globals: ["host": "global.example.com", "app": "demo-api"],
            runtime: [:],
            dynamic: ["$uuid": "UUID-FIXED"]
        )

        expectEqual("环境变量覆盖全局变量", VariableResolver.text("{{host}}", context: context), "env.example.com")
        expectEqual("全局变量可读取", VariableResolver.text("{{app}}", context: context), "demo-api")
        expectEqual("动态变量可解析", VariableResolver.text("{{$uuid}}", context: context), "UUID-FIXED")
        expectEqual("未定义变量原样保留", VariableResolver.text("{{missing}}", context: context), "{{missing}}")
        expectEqual("空格容错 {{ host }}", VariableResolver.text("{{ host }}", context: context), "env.example.com")
        expectEqual(
            "多个变量混合替换",
            VariableResolver.text("{{host}}/api?t={{token}}&x={{missing}}", context: context),
            "env.example.com/api?t=env-token&x={{missing}}"
        )
        expectEqual(
            "未定义变量被收集并去重",
            VariableResolver.resolve("{{a}}/{{b}}/{{a}}", context: context).unresolved,
            ["a", "b"]
        )
        expectEqual(
            "空环境变量值回落到全局变量",
            VariableResolver.text(
                "{{fallback}}",
                context: VariableContext(environment: ["fallback": ""], globals: ["fallback": "G"])
            ),
            "G"
        )

        let runtimeContext = VariableContext(
            environment: ["host": "env.example.com"],
            globals: ["host": "global.example.com"],
            runtime: ["host": "runtime.example.com"]
        )
        expectEqual("运行时变量优先级最高", VariableResolver.text("{{host}}", context: runtimeContext), "runtime.example.com")

        let dynamic = VariableResolver.dynamicVariables(projectName: "P", environmentName: "E")
        check("内置动态变量齐全", dynamic["$timestamp"] != nil && dynamic["$date"] != nil && dynamic["$projectName"] == "P")
        check("动态时间戳是合法数字", Int(dynamic["$timestamp"] ?? "") != nil && Int(dynamic["$timestampMs"] ?? "") != nil)
    }

    // MARK: - Mock

    private static func checkMock() {
        section("Mock 响应生成")

        var project = Project(
            name: "演示项目",
            environments: [APIEnvironment(name: "测试环境1", baseURL: "https://t.example.com")]
        )
        project.globals = [KeyValueItem(key: "host", value: "global.example.com")]
        let context = RequestBuilder.context(
            project: project,
            environment: project.activeEnvironment,
            runtimeVariables: [:]
        )
        func resolve(_ request: APIRequest) -> ResolvedRequest? {
            try? RequestBuilder.resolve(
                request: request,
                project: project,
                environment: project.activeEnvironment
            )
        }

        // 请求体方式一：JSON —— 字段名原样镜像，值用编排后的真实值
        let jsonRequest = APIRequest(
            name: "账户余额",
            method: .post,
            url: "/account/balance",
            params: [KeyValueItem(key: "scene", value: "1", location: .query)],
            body: RequestBody(kind: .json, text: "{\"scene\": 1, \"appId\": \"{{host}}\"}")
        )
        let jsonMock = MockEngine.autoBody(
            request: jsonRequest,
            resolved: resolve(jsonRequest),
            context: context,
            config: MockConfig()
        )
        check("Mock 生成的是合法 JSON", JSONValueParser.parse(jsonMock.text) != nil)
        check("Mock 镜像了请求体字段", jsonMock.text.contains("\"scene\"") && jsonMock.text.contains("\"appId\""))
        check("Mock 用了变量替换后的值", jsonMock.text.contains("global.example.com"), detail: jsonMock.text)
        check("JSON 请求体的 Mock 是 JSON 响应", jsonMock.contentType.contains("application/json"))

        // 请求体方式二：Form —— 表单字段整理成 JSON
        let formRequest = APIRequest(
            name: "每日签到",
            method: .post,
            url: "/sign",
            body: RequestBody(
                kind: .formURLEncoded,
                fields: [KeyValueItem(key: "source", value: "app"), KeyValueItem(key: "name", value: "张三")]
            )
        )
        let formMock = MockEngine.autoBody(
            request: formRequest,
            resolved: resolve(formRequest),
            context: context,
            config: MockConfig()
        )
        check("表单字段进 Mock 的 data", formMock.text.contains("\"source\"") && formMock.text.contains("\"app\""))
        check("表单中文值正确解码", formMock.text.contains("张三"), detail: formMock.text)

        // 请求体方式三：Raw —— 回显原文，text/plain
        let rawRequest = APIRequest(
            name: "裸文本",
            method: .put,
            url: "/raw",
            body: RequestBody(kind: .raw, text: "hello {{host}}")
        )
        let rawMock = MockEngine.autoBody(
            request: rawRequest,
            resolved: resolve(rawRequest),
            context: context,
            config: MockConfig()
        )
        check("Raw 请求体的 Mock 是 text/plain", rawMock.contentType.contains("text/plain"))
        check("Raw 回显请求体原文", rawMock.text.contains("hello global.example.com"), detail: rawMock.text)

        // 请求体方式四：无 —— 回显 query 参数
        let getRequest = APIRequest(
            name: "列表",
            method: .get,
            url: "/list",
            params: [KeyValueItem(key: "page", value: "1", location: .query)]
        )
        let getMock = MockEngine.autoBody(
            request: getRequest,
            resolved: resolve(getRequest),
            context: context,
            config: MockConfig()
        )
        check("没有请求体时回显 query 参数", getMock.text.contains("\"page\""), detail: getMock.text)

        // 状态码 / 延迟 / 标记
        let payload = MockEngine.payload(
            request: getRequest,
            resolved: nil,
            context: context,
            config: MockConfig(delayMs: 250),
            mode: .perRequest
        )
        check("Mock 响应带 Mock 标记", payload.isMock)
        expectEqual("Mock 响应状态码", payload.statusCode, 200)
        expectEqual("Mock 模拟延迟计入耗时", payload.elapsed, 0.25)
        check("Mock 响应头带 X-Mock", payload.headers.contains { $0.name == "X-Mock" })

        let notFound = MockEngine.payload(
            request: getRequest,
            resolved: nil,
            context: context,
            config: MockConfig(statusCode: 404),
            mode: .perRequest
        )
        expectEqual("Mock 可造 404 验证异常分支", notFound.statusText.lowercased(), "not found")
        check("错误状态码时 code 不再是 0", notFound.text?.contains("\"code\": 404") == true, detail: notFound.text ?? "")

        let noContent = MockEngine.payload(
            request: getRequest,
            resolved: nil,
            context: context,
            config: MockConfig(statusCode: 204),
            mode: .perRequest
        )
        check("204 不带响应体", noContent.body.isEmpty)

        // 手写覆盖
        var custom = MockConfig()
        custom.setCustomBody("{\n  \"code\": 0,\n  \"data\": { \"t\": \"{{$projectName}}\" }\n}", for: .json)
        check("手写响应体被识别", custom.hasCustomBody(for: .json))
        let customPayload = MockEngine.payload(
            request: jsonRequest,
            resolved: nil,
            context: context,
            config: custom,
            mode: .perRequest
        )
        check("手写响应体覆盖自动生成", customPayload.text?.contains("\"code\": 0") == true)
        check("手写响应体里的变量会被替换", customPayload.text?.contains("{{$projectName}}") == false)
        custom.setCustomBody("", for: .json)
        check("清空后回到自动生成", !custom.hasCustomBody(for: .json))

        // 门禁：全局策略 × 接口开关
        var settings = AppSettings()
        expectEqual("Mock 默认按接口生效", settings.mockMode, .perRequest)
        check("按接口模式下没勾选就不 Mock", !settings.shouldMock(getRequest))
        var enabled = getRequest
        enabled.mock.isEnabled = true
        check("按接口模式下勾了就 Mock", settings.shouldMock(enabled))
        settings.mockMode = .off
        check("整体关闭后勾了也不 Mock", !settings.shouldMock(enabled))
        settings.mockMode = .always
        check("全量模式下未勾选也 Mock", settings.shouldMock(getRequest))

        // 老项目文件（没有 mock 字段）必须还能读出来
        let legacyJSON = """
        {
          "id": "\(UUID().uuidString)",
          "name": "老接口",
          "method": "GET",
          "url": "/old",
          "params": [],
          "headers": [],
          "body": { "kind": "none", "text": "", "fields": [] },
          "note": ""
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let legacy = try? decoder.decode(APIRequest.self, from: Data(legacyJSON.utf8))
        check("老项目文件缺 mock 字段也能解码", legacy != nil)
        expectEqual("老接口的 Mock 默认关闭", legacy?.mock.isEnabled, false)
        expectEqual("老接口的名字没丢", legacy?.name, "老接口")
    }

    // MARK: - form-data 与文件上传

    private static func checkFormData() {
        section("form-data 与文件上传")

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("apiclient-formdata-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent("avatar.png")
        let fileBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        try? fileBytes.write(to: fileURL)

        var project = Project(
            name: "上传项目",
            environments: [APIEnvironment(name: "测试环境", baseURL: "https://t.example.com")]
        )
        project.globals = [KeyValueItem(key: "biz", value: "avatar")]

        let request = APIRequest(
            name: "上传头像",
            method: .post,
            url: "/file/upload",
            body: RequestBody(
                kind: .formData,
                fields: [
                    KeyValueItem(key: "biz", value: "{{biz}}"),
                    KeyValueItem(key: "file", value: fileURL.path, valueKind: .file),
                    KeyValueItem(isEnabled: false, key: "skip", value: "x"),
                ]
            )
        )

        guard let resolved = try? RequestBuilder.resolve(
            request: request,
            project: project,
            environment: project.activeEnvironment
        ) else {
            check("form-data 编排成功", false)
            return
        }

        let contentType = resolved.headers.first { $0.name.lowercased() == "content-type" }?.value ?? ""
        check(
            "multipart 的 Content-Type 带 boundary",
            contentType.hasPrefix("multipart/form-data; boundary="),
            detail: contentType
        )
        let boundary = contentType.components(separatedBy: "boundary=").last ?? ""
        let body = resolved.body.flatMap { String(data: $0, encoding: .isoLatin1) } ?? ""

        check("正文以 boundary 开头", body.hasPrefix("--\(boundary)\r\n"), detail: String(body.prefix(50)))
        check("正文以结束分隔线收尾", body.hasSuffix("--\(boundary)--\r\n"))
        check("文本字段的值做了变量替换", body.contains("name=\"biz\"\r\n\r\navatar\r\n"))
        check("文件字段带 filename", body.contains("filename=\"avatar.png\""))
        check("文件字段带推断出的 MIME", body.contains("Content-Type: image/png"))
        check("未勾选的字段不参与发送", !body.contains("name=\"skip\""))
        check("文件字节原样写进正文", resolved.body?.range(of: fileBytes) != nil)
        expectEqual("文件字段清单保留下来", resolved.formParts.filter(\.isFile).count, 1)
        check("字段描述标出文件数", resolved.bodyDescription.contains("1 个文件"), detail: resolved.bodyDescription)

        // cURL 导出：multipart 走 -F，而不是 --data-raw
        let curl = RequestBuilder.curlCommand(for: resolved)
        check("cURL 用 -F 发文件", curl.contains("-F 'file=@\(fileURL.path);type=image/png'"), detail: curl)
        check("cURL 用 -F 发文本字段", curl.contains("-F 'biz=avatar'"))
        check("cURL 不重复给 multipart Content-Type", !curl.contains("multipart/form-data"))
        check("cURL 不用 --data-raw", !curl.contains("--data-raw"))

        // 发送前的拦截：文件没选 / 文件不见了
        var missing = request
        missing.body.fields[1].value = dir.appendingPathComponent("gone.png").path
        do {
            _ = try RequestBuilder.resolve(request: missing, project: project, environment: project.activeEnvironment)
            check("文件不存在会拦截发送", false)
        } catch let error as RequestBuildError {
            if case .fileMissing(let field) = error {
                expectEqual("报错指出是哪个字段", field, "file")
            } else {
                check("报错类型是 fileMissing", false, detail: "\(error)")
            }
        } catch {
            check("报错类型是 RequestBuildError", false, detail: "\(error)")
        }

        var unchosen = request
        unchosen.body.fields[1].value = ""
        do {
            _ = try RequestBuilder.resolve(request: unchosen, project: project, environment: project.activeEnvironment)
            check("没选文件会拦截发送", false)
        } catch let error as RequestBuildError {
            if case .fileNotChosen = error {
                check("没选文件会拦截发送", true)
            } else {
                check("没选文件会拦截发送", false, detail: "\(error)")
            }
        } catch {
            check("没选文件会拦截发送", false, detail: "\(error)")
        }

        // 文件字段的派生信息
        expectEqual("能取到文件名", request.body.fields[1].fileName, "avatar.png")
        check("能取到文件大小", request.body.fields[1].fileSize == Int64(fileBytes.count))
        check("文件真的存在", request.body.fields[1].fileExists)

        // Mock：multipart 出一份 JSON 镜像
        let context = RequestBuilder.context(
            project: project,
            environment: project.activeEnvironment,
            runtimeVariables: [:]
        )
        let mock = MockEngine.autoBody(request: request, resolved: resolved, context: context, config: MockConfig())
        check("Mock 的 multipart 响应是 JSON", mock.contentType.contains("application/json"))
        check("Mock 里文本字段是值本身", mock.text.contains("\"biz\"") && mock.text.contains("\"avatar\""))
        check("Mock 里文件字段标出文件名", mock.text.contains("[file] avatar.png"), detail: mock.text)

        // 老项目文件里的键值对没有 valueKind 字段
        let legacy = "{ \"id\": \"\(UUID().uuidString)\", \"isEnabled\": true, \"key\": \"a\", \"value\": \"1\", \"note\": \"\", \"location\": \"query\" }"
        let legacyItem = try? JSONDecoder().decode(KeyValueItem.self, from: Data(legacy.utf8))
        check("老键值对缺 valueKind 也能解码", legacyItem != nil)
        expectEqual("老键值对默认是文本", legacyItem?.valueKind, KeyValueKind.text)

        // 打开接口时的落点：只有说明的接口不再跳到说明
        let noteOnly = APIRequest(name: "上传文件", method: .post, url: "/file/upload", note: "Java: uploadFile")
        expectEqual("只有说明的接口停在参数分区", TabSession.preferredPane(for: noteOnly), .params)
        expectEqual("有 form-data 字段就停在请求体", TabSession.preferredPane(for: request), .body)

        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - 编辑器定位与高亮

    private static func checkEditorLocator() {
        section("编辑器定位与 JSON 高亮")

        expectEqual("空文本定位到 0", TextLocator.contentStart(in: ""), 0)
        expectEqual("跳过前导空行定位到正文", TextLocator.contentStart(in: "\n\n  {\n  \"a\": 1\n}"), 4)
        expectEqual("没有空行时定位到 0", TextLocator.contentStart(in: "{"), 0)
        expectEqual("全空白文本回落到 0", TextLocator.contentStart(in: "\n   \n"), 0)
        expectEqual("越界光标被夹回文本末尾", TextLocator.clamp(99, in: "{}"), 2)

        let json = "{\"name\": \"demo-api\", \"count\": 12, \"ok\": true, \"none\": null}"
        let tokens = CodeTokenizer.tokens(in: json, language: .json)

        func texts(of kind: CodeTokenizer.Kind) -> [String] {
            tokens.filter { $0.kind == kind }.map { (json as NSString).substring(with: $0.range) }
        }

        expectEqual("JSON 的键被单独识别", texts(of: .key), ["\"name\"", "\"count\"", "\"ok\"", "\"none\""])
        expectEqual("字符串值识别", texts(of: .string), ["\"demo-api\""])
        expectEqual("数字识别", texts(of: .number), ["12"])
        expectEqual("字面量识别", texts(of: .literal), ["true", "null"])
        expectEqual("标点识别", texts(of: .punctuation), ["{", ":", ",", ":", ",", ":", ",", ":", "}"])
        check("token 按出现顺序排列", zip(tokens, tokens.dropFirst()).allSatisfy { $0.range.location < $1.range.location })
        check("键与值用不同颜色", CodeTokenizer.color(for: .key) != CodeTokenizer.color(for: .string))
        check("纯文本模式不上色", CodeTokenizer.tokens(in: json, language: .plain).isEmpty)

        let dangling = CodeTokenizer.tokens(in: "{\"a\": \"没闭合\n}", language: .json).first { $0.kind == .string }
        check("没闭合的字符串在换行处收尾", (dangling?.range.length ?? 99) <= 4, detail: "长度 \(dangling?.range.length ?? -1)")

        // 打开标签时按内容自动落到对应分区（JSON 请求体 → 请求体那一栏）
        let jsonBodied = APIRequest(
            name: "r",
            method: .post,
            url: "/x",
            body: RequestBody(kind: .json, text: "{}")
        )
        expectEqual("有 JSON 请求体就停在请求体分区", TabSession.preferredPane(for: jsonBodied), .body)
        expectEqual(
            "有表单字段也停在请求体分区",
            TabSession.preferredPane(
                for: APIRequest(
                    name: "r",
                    method: .post,
                    url: "/x",
                    body: RequestBody(kind: .formURLEncoded, fields: [KeyValueItem(key: "a", value: "1")])
                )
            ),
            .body
        )
        expectEqual(
            "只有 Mock 配置时停在 Mock 分区",
            TabSession.preferredPane(for: APIRequest(name: "r", mock: MockConfig(isEnabled: true))),
            .mock
        )
        expectEqual("什么都没有时停在参数分区", TabSession.preferredPane(for: APIRequest(name: "r")), .params)

        // 每种请求体方式各记一份光标，互不覆盖
        var anchors: [String: BodyEditorAnchor] = [:]
        anchors["body-json"] = BodyEditorAnchor(caret: 12, selectionLength: 0, scrollY: 40)
        anchors["body-raw"] = BodyEditorAnchor(caret: 3, selectionLength: 0, scrollY: 0)
        expectEqual("位置按请求体方式分开记", anchors.count, 2)
        expectEqual("JSON 的光标位置", anchors["body-json"]?.caret, 12)
        expectEqual("Raw 的光标位置", anchors["body-raw"]?.caret, 3)
    }

    // MARK: - 请求编排

    private static func checkRequestBuilder() {
        section("请求编排")

        var project = Project(
            name: "演示项目",
            environments: [
                APIEnvironment(
                    name: "测试环境1",
                    baseURL: "https://api.test.com/v1/",
                    variables: [KeyValueItem(key: "token", value: "T1")]
                )
            ]
        )
        project.globalHeaders = [
            KeyValueItem(key: "version", value: "6.8.0"),
            KeyValueItem(key: "Authorization", value: "Bearer {{token}}"),
            KeyValueItem(isEnabled: false, key: "ignored", value: "x"),
        ]

        let request = APIRequest(
            name: "getUser",
            method: .post,
            url: "/user/:id",
            params: [
                KeyValueItem(key: "id", value: "42", location: .path),
                KeyValueItem(key: "page", value: "1", location: .query),
                KeyValueItem(isEnabled: false, key: "skipped", value: "no", location: .query),
            ],
            headers: [
                KeyValueItem(key: "Authorization", value: "Bearer OVERRIDE"),
                KeyValueItem(key: "X-Trace", value: "{{token}}-trace"),
            ],
            body: RequestBody(kind: .json, text: "{\"uid\":\"{{token}}\"}")
        )

        guard let resolved = try? RequestBuilder.resolve(
            request: request,
            project: project,
            environment: project.activeEnvironment
        ) else {
            check("请求编排成功", false)
            return
        }

        check("路径参数替换", resolved.urlString.hasPrefix("https://api.test.com/v1/user/42"), detail: resolved.urlString)
        check("query 参数附加", resolved.urlString.contains("page=1"), detail: resolved.urlString)
        check("禁用参数被忽略", !resolved.urlString.contains("skipped"), detail: resolved.urlString)

        let authorizationHeaders = resolved.headers.filter { $0.name.lowercased() == "authorization" }
        expectEqual("同名请求头只出现一次", authorizationHeaders.count, 1)
        expectEqual("请求头覆盖全局头", authorizationHeaders.first?.value, "Bearer OVERRIDE")
        check("全局头保留", resolved.headers.contains { $0.name == "version" && $0.value == "6.8.0" })
        check("禁用全局头被忽略", !resolved.headers.contains { $0.name == "ignored" })
        check("请求头变量替换", resolved.headers.contains { $0.name == "X-Trace" && $0.value == "T1-trace" })
        check(
            "自动补 Content-Type",
            resolved.headers.contains { $0.name.lowercased() == "content-type" && $0.value == "application/json" }
        )
        expectEqual(
            "请求体变量替换",
            resolved.body.flatMap { String(data: $0, encoding: .utf8) },
            "{\"uid\":\"T1\"}"
        )

        let curl = RequestBuilder.curlCommand(for: resolved)
        check("cURL 生成包含方法", curl.hasPrefix("curl -X POST"))
        check("cURL 生成包含请求体", curl.contains("--data-raw"))

        // 绝对地址不应再拼 baseURL
        let absolute = APIRequest(name: "abs", method: .get, url: "http://127.0.0.1:8080/ping")
        let absoluteResolved = try? RequestBuilder.resolve(request: absolute, project: project, environment: project.activeEnvironment)
        expectEqual("绝对地址不拼 baseURL", absoluteResolved?.urlString, "http://127.0.0.1:8080/ping")

        // 花括号风格路径参数
        let braceStyle = APIRequest(name: "brace", method: .get, url: "/user/{id}", params: [
            KeyValueItem(key: "id", value: "7", location: .path)
        ])
        let braceResolved = try? RequestBuilder.resolve(request: braceStyle, project: project, environment: project.activeEnvironment)
        check("花括号路径参数替换", braceResolved?.urlString.hasSuffix("/user/7") == true, detail: braceResolved?.urlString ?? "")

        // 显式 Content-Type 不被自动值覆盖
        let explicitType = APIRequest(
            name: "ct",
            method: .post,
            url: "/a",
            headers: [KeyValueItem(key: "Content-Type", value: "application/json;charset=UTF-8")],
            body: RequestBody(kind: .json, text: "{}")
        )
        let explicitResolved = try? RequestBuilder.resolve(request: explicitType, project: project, environment: project.activeEnvironment)
        expectEqual(
            "显式 Content-Type 不被覆盖",
            explicitResolved?.headers.filter { $0.name.lowercased() == "content-type" }.count,
            1
        )

        // 单引号需要为 shell 转义
        let quoted = APIRequest(name: "q", method: .post, url: "/a", headers: [
            KeyValueItem(key: "X-Q", value: "it's")
        ])
        let quotedResolved = try? RequestBuilder.resolve(request: quoted, project: project, environment: project.activeEnvironment)
        check("cURL 转义单引号", quotedResolved.map { RequestBuilder.curlCommand(for: $0).contains("'\\''") } == true)

        // 表单编码需要对非 ASCII 做百分号转义
        let form = APIRequest(
            name: "form",
            method: .post,
            url: "/a",
            body: RequestBody(kind: .formURLEncoded, fields: [
                KeyValueItem(key: "name", value: "张三"),
                KeyValueItem(key: "page", value: "1"),
            ])
        )
        if let formResolved = try? RequestBuilder.resolve(request: form, project: project, environment: project.activeEnvironment),
           let body = formResolved.body.flatMap({ String(data: $0, encoding: .utf8) }) {
            check("表单中文被百分号编码", body.contains("name=%E5%BC%A0%E4%B8%89"), detail: body)
            check("表单普通字段保留", body.contains("page=1"), detail: body)
        } else {
            check("表单编码", false)
        }

        // 动态变量可用于请求头
        let dynamicHeader = APIRequest(name: "d", method: .get, url: "/x", headers: [
            KeyValueItem(key: "timestamp", value: "{{$timestamp}}")
        ])
        let dynamicResolved = try? RequestBuilder.resolve(request: dynamicHeader, project: project, environment: project.activeEnvironment)
        let timestampValue = dynamicResolved?.headers.first { $0.name == "timestamp" }?.value
        check("动态变量可用于请求头", Int(timestampValue ?? "") != nil, detail: timestampValue ?? "")

        // 未解析变量应被上报
        let unresolvedRequest = APIRequest(name: "u", method: .get, url: "{{baseUrl}}/x", headers: [KeyValueItem(key: "T", value: "{{nope}}")])
        let unresolvedResolved = try? RequestBuilder.resolve(request: unresolvedRequest, project: project, environment: project.activeEnvironment)
        check("未解析变量上报", unresolvedResolved?.unresolvedVariables.contains("nope") == true)

        // 空地址报错
        do {
            _ = try RequestBuilder.resolve(request: APIRequest(name: "empty", url: "  "), project: project, environment: nil)
            check("空地址抛错", false)
        } catch {
            check("空地址抛错", true)
        }
    }

    // MARK: - JSON

    private static func checkJSONParser() {
        section("JSON 解析")

        let source = "{\"z\":1,\"a\":{\"big\":1234567890123456789,\"esc\":\"a\\\"b\\n\",\"uni\":\"\\u4e2d\\u6587\"},\"list\":[1,2.5,true,null,{}]}"
        guard let value = JSONValueParser.parse(source) else {
            check("解析 JSON", false)
            return
        }

        guard case .object(let entries) = value else {
            check("根节点是对象", false)
            return
        }

        expectEqual("字段顺序保持", entries.map(\.key), ["z", "a", "list"])

        let pretty = value.prettyPrinted()
        check("大整数精度不丢失", pretty.contains("1234567890123456789"))
        check("转义字符还原", pretty.contains("a\\\"b"))
        check("Unicode 转义还原", pretty.contains("中文"))
        check("浮点字面量保持", pretty.contains("2.5"))
        check("中文原样输出不转义", pretty.contains("\"中文\""))

        if case .object(let inner)? = entries.first(where: { $0.key == "a" })?.value {
            expectEqual("嵌套字段名", inner.map(\.key), ["big", "esc", "uni"])
        } else {
            check("嵌套对象解析", false)
        }

        if case .array(let items)? = entries.first(where: { $0.key == "list" })?.value {
            expectEqual("数组长度", items.count, 5)
            expectEqual("数组顺序", items.prefix(4).map(\.typeName), ["number", "number", "bool", "null"])
        } else {
            check("数组解析", false)
        }

        // UTF-16 代理对（emoji）
        if let emoji = JSONValueParser.parse("\"\\uD83D\\uDE00\""), case .string(let text) = emoji {
            expectEqual("代理对还原 emoji", text, "😀")
        } else {
            check("代理对还原 emoji", false)
        }

        check("非法 JSON 返回 nil", JSONValueParser.parse("{not json}") == nil)
        check("截断 JSON 返回 nil", JSONValueParser.parse("{\"a\": ") == nil)
        check("空串返回 nil", JSONValueParser.parse("") == nil)
    }

    // MARK: - 项目模型

    private static func checkProjectModel() {
        section("项目模型")

        var project = Project(name: "P")
        expectEqual("默认建一个环境", project.environments.count, 1)
        expectEqual("默认环境即当前环境", project.activeEnvironment?.id, project.environments.first?.id)

        let request = APIRequest(name: "r")
        project.insert(request, intoFolder: nil)
        expectEqual("插入请求到根", project.collection.count, 1)
        expectEqual("请求进入请求数组", project.requests.count, 1)
        expectEqual("节点名与请求名一致", project.collection.first?.name, "r")

        let doomed = project.removeNode(id: project.collection.first?.id ?? UUID())
        expectEqual("删除节点返回被删请求 id", doomed, [request.id])
        check("请求数组同步清理", project.requests.isEmpty)

        // 文件夹级联删除
        var nested = Project(name: "N")
        let folderID = UUID()
        nested.collection = [CollectionNode(id: folderID, kind: .folder, name: "组")]
        let first = APIRequest(name: "a")
        let second = APIRequest(name: "b")
        nested.insert(first, intoFolder: folderID)
        nested.insert(second, intoFolder: folderID)
        expectEqual("请求插入指定文件夹", nested.collection.first?.children.count, 2)
        let cascaded = Set(nested.removeNode(id: folderID))
        expectEqual("文件夹级联删除", cascaded, Set([first.id, second.id]))
        check("级联删除后请求清空", nested.requests.isEmpty)

        // 重命名同步
        var renaming = Project(name: "R")
        let target = APIRequest(name: "old")
        renaming.insert(target, intoFolder: nil)
        renaming.renameNode(id: renaming.collection.first?.id ?? UUID(), to: "new")
        expectEqual("重命名同步到请求", renaming.request(id: target.id)?.name, "new")
        renaming.renameNode(id: renaming.collection.first?.id ?? UUID(), to: "   ")
        expectEqual("空白名被忽略", renaming.request(id: target.id)?.name, "new")

        // 折叠与搜索：折叠状态由调用方传入的集合决定，节点本身不记
        let collapsed = CollectionNode(
            id: UUID(),
            kind: .folder,
            name: "账号",
            children: [
                CollectionNode(kind: .request, name: "getBalance", requestID: UUID()),
                CollectionNode(kind: .request, name: "getProfile", requestID: UUID()),
            ]
        )
        expectEqual("默认展开时渲染全部行", CollectionTree.rows(in: [collapsed]).count, 3)
        expectEqual("折叠时只渲染文件夹自身", CollectionTree.rows(in: [collapsed], collapsed: [collapsed.id]).count, 1)
        let filtered = CollectionTree.rows(in: [collapsed], filter: "balance", collapsed: [collapsed.id])
        expectEqual("搜索命中自动展开路径", filtered.count, 2)
        expectEqual("命中的是目标接口", filtered.last?.node.name, "getBalance")
        expectEqual(
            "搜索无结果时返回空",
            CollectionTree.rows(in: [collapsed], filter: "zzz", collapsed: [collapsed.id]).count,
            0
        )

        // 定位：反查祖先文件夹
        var locating = Project(name: "L")
        let outerFolder = CollectionNode(id: UUID(), kind: .folder, name: "外")
        let deepFolder = CollectionNode(id: UUID(), kind: .folder, name: "深")
        locating.collection = [outerFolder]
        locating.collection.mutateNode(id: outerFolder.id) { $0.children = [deepFolder] }
        let deepRequest = APIRequest(name: "deep")
        locating.insert(deepRequest, intoFolder: deepFolder.id)
        expectEqual(
            "祖先文件夹从根到父级",
            locating.collection.ancestorFolderIDs(of: deepRequest.id),
            [outerFolder.id, deepFolder.id]
        )
        expectEqual("全部文件夹 id", locating.collection.allFolderIDs(), [outerFolder.id, deepFolder.id])
        check("按请求反查节点 id", locating.collection.nodeID(forRequest: deepRequest.id) != nil)

        // 环境变量字典包含 baseUrl
        let environment = APIEnvironment(
            name: "dev",
            baseURL: "http://127.0.0.1:8080",
            variables: [KeyValueItem(key: "k", value: "v")]
        )
        expectEqual("环境变量含 baseUrl", environment.resolvedVariables["baseUrl"], "http://127.0.0.1:8080")
        expectEqual("环境变量含 baseURL 别名", environment.resolvedVariables["baseURL"], "http://127.0.0.1:8080")
        expectEqual("环境自定义变量", environment.resolvedVariables["k"], "v")
    }

    // MARK: - 持久化

    private static func checkPersistenceRoundTrip() {
        section("持久化")

        guard let root = sandbox else { return }
        let store = PersistenceStore(root: root)

        do {
            try store.bootstrap()
        } catch {
            check("创建数据目录", false, detail: error.localizedDescription)
            return
        }

        var project = Project(name: "落盘项目", environments: [APIEnvironment(name: "dev", baseURL: "http://127.0.0.1:8080")])
        let request = APIRequest(name: "ping", method: .get, url: "{{baseUrl}}/ping")
        project.insert(request, intoFolder: nil)
        project.globalHeaders = [KeyValueItem(key: "version", value: "6.8.0")]

        do {
            try store.save(project: project)
        } catch {
            check("保存项目", false, detail: error.localizedDescription)
            return
        }

        let loaded = store.loadProjects()
        expectEqual("读回项目数量", loaded.projects.count, 1)
        expectEqual("读回接口数量", loaded.projects.first?.requests.count, 1)
        expectEqual("读回接口地址", loaded.projects.first?.requests.first?.url, "{{baseUrl}}/ping")
        expectEqual("读回集合树节点", loaded.projects.first?.collection.count, 1)
        expectEqual("读回全局请求头", loaded.projects.first?.globalHeaders.first?.key, "version")
        expectEqual("读取失败数为 0", loaded.failures.count, 0)

        let tabID = UUID()
        let workspace = WorkspaceState(
            activeProjectID: project.id,
            openTabs: [TabRef(id: tabID, projectID: project.id, requestID: request.id)],
            activeTabID: tabID,
            settings: AppSettings(requestTimeout: 45, verifyTLS: false, followRedirects: false)
        )
        do {
            try store.save(workspace: workspace)
        } catch {
            check("保存工作区", false, detail: error.localizedDescription)
            return
        }

        let loadedWorkspace = store.loadWorkspace()
        expectEqual("读回活动项目", loadedWorkspace.activeProjectID, project.id)
        expectEqual("读回标签数量", loadedWorkspace.openTabs.count, 1)
        expectEqual("读回活动标签", loadedWorkspace.activeTabID, tabID)
        expectEqual("读回设置-超时", loadedWorkspace.settings.requestTimeout, 45)
        expectEqual("读回设置-TLS 校验", loadedWorkspace.settings.verifyTLS, false)

        // 缺失字段应回落默认值而不是解码失败
        let partial = Data("{\"activeProjectID\":null}".utf8)
        try? partial.write(to: store.paths.workspaceFile, options: .atomic)
        let tolerant = store.loadWorkspace()
        expectEqual("设置缺字段回落默认值", tolerant.settings.requestTimeout, 30)

        // 损坏的项目文件不应让启动失败
        let brokenRoot = root.appendingPathComponent("broken")
        let brokenStore = PersistenceStore(root: brokenRoot)
        try? brokenStore.bootstrap()
        try? Data("{ broken".utf8).write(to: brokenStore.paths.projectFile(UUID()), options: .atomic)
        let broken = brokenStore.loadProjects()
        check("损坏文件被记录而非崩溃", broken.projects.isEmpty && broken.failures.count == 1)

        // 删除项目文件
        try? store.deleteProject(id: project.id)
        expectEqual("删除项目后文件消失", store.loadProjects().projects.count, 0)
    }

    // MARK: - 多项目 + 跨项目标签

    // MARK: - 收藏

    private static func checkFavorites() async {
        section("收藏 / 置顶")

        // —— 模型层：切换语义与顺序 ——
        var project = Project(name: "收藏测试")
        let requestA = APIRequest(name: "接口A", method: .get, url: "/a")
        let requestB = APIRequest(name: "接口B", method: .post, url: "/b")
        let requestC = APIRequest(name: "接口C", method: .get, url: "/c")
        project.insert(requestA, intoFolder: nil)
        project.insert(requestB, intoFolder: nil)
        project.insert(requestC, intoFolder: nil)

        expectEqual("收藏返回新状态 true", project.toggleFavorite(requestA.id), true)
        expectEqual("再收藏返回 false", project.toggleFavorite(requestA.id), false)
        expectEqual("取消后不在收藏里", project.isFavorite(requestA.id), false)

        project.toggleFavorite(requestC.id)
        project.toggleFavorite(requestA.id)
        project.toggleFavorite(requestB.id)
        expectEqual(
            "置顶顺序 = 收藏顺序（追加到末尾）",
            project.favoriteRequestIDs,
            [requestC.id, requestA.id, requestB.id]
        )
        expectEqual(
            "favoriteRequests 按置顶顺序返回",
            project.favoriteRequests.map(\.id),
            [requestC.id, requestA.id, requestB.id]
        )

        // 失效 id 被跳过而不是炸掉
        var stale = project
        stale.favoriteRequestIDs.append(UUID())
        expectEqual("失效收藏 id 被跳过", stale.favoriteRequests.count, 3)

        // —— 删除清理 ——
        let doomedA = project.removeNode(id: project.collection.nodeID(forRequest: requestA.id)!)
        expectEqual("删除返回被删请求", doomedA, [requestA.id])
        check("删除接口同时取消收藏", !project.favoriteRequestIDs.contains(requestA.id))
        expectEqual("剩余收藏保持原顺序", project.favoriteRequestIDs, [requestC.id, requestB.id])

        // 文件夹连带删除时，里面的收藏也清掉
        var project2 = Project(name: "文件夹收藏")
        let inner = APIRequest(name: "文件夹内接口", method: .get, url: "/inner")
        project2.insert(inner, intoFolder: nil)
        var folder = CollectionNode.folder(name: "文件夹")
        let innerNode = CollectionNode.request(id: inner.id, name: inner.name)
        folder.children = [innerNode]
        project2.collection.removeNode(id: project2.collection.nodeID(forRequest: inner.id)!)
        project2.collection.append(folder)
        project2.toggleFavorite(inner.id)
        project2.removeNode(id: folder.id)
        check("删文件夹连带清理收藏", project2.favoriteRequestIDs.isEmpty)

        // —— AppStore 层：搜索过滤与持久化 ——
        guard let sandbox else { return }
        let root = sandbox.appendingPathComponent("favorites")
        let app = AppStore(storage: PersistenceStore(root: root))
        let projectX = app.createProject(name: "收藏项目X", baseURL: "https://x.example.com")
        var requestX = APIRequest(name: "余额查询", method: .get, url: "/balance")
        var requestY = APIRequest(name: "每日签到", method: .post, url: "/sign")
        app.updateProject(id: projectX.id) { project in
            project.insert(requestX, intoFolder: nil)
            project.insert(requestY, intoFolder: nil)
        }
        requestX = app.project(id: projectX.id)!.requests.first { $0.name == "余额查询" }!
        requestY = app.project(id: projectX.id)!.requests.first { $0.name == "每日签到" }!

        app.setActiveProject(id: projectX.id)
        expectEqual("AppStore 收藏返回 true", app.toggleFavorite(projectID: projectX.id, requestID: requestY.id), true)
        app.toggleFavorite(projectID: projectX.id, requestID: requestX.id)
        expectEqual(
            "侧边栏收藏区按置顶顺序",
            app.sidebarFavorites.map(\.id),
            [requestY.id, requestX.id]
        )

        // 搜索时侧边栏切换为平铺结果列表（收藏区不再单独过滤展示）
        app.sidebarFilter = "余额"
        expectEqual("按名称搜到", app.sidebarSearchResults.map(\.request.id), [requestX.id])
        app.sidebarFilter = "sign"
        expectEqual("按 URL 搜到", app.sidebarSearchResults.map(\.request.id), [requestY.id])
        app.sidebarFilter = "blc"
        expectEqual("模糊命中 URL", app.sidebarSearchResults.map(\.request.id), [requestX.id])
        app.sidebarFilter = "post"
        expectEqual("按方法搜到", app.sidebarSearchResults.map(\.request.id), [requestY.id])
        app.sidebarFilter = "不存在的词"
        check("无命中时结果为空", app.sidebarSearchResults.isEmpty)
        app.sidebarFilter = ""
        expectEqual("清空搜索后收藏区恢复完整", app.sidebarFavorites.count, 2)

        // 持久化往返
        await app.flushSaveAndWait()
        let reloaded = AppStore(storage: PersistenceStore(root: root))
        expectEqual(
            "重启后收藏仍在且顺序不变",
            reloaded.project(id: projectX.id)?.favoriteRequestIDs ?? [],
            [requestY.id, requestX.id]
        )

        // 老项目文件（没有 favoriteRequestIDs 字段）正常解码
        var legacyProject = reloaded.project(id: projectX.id)!
        legacyProject.favoriteRequestIDs = []
        let encoder = JSONEncoder()
        let data = try! encoder.encode(legacyProject)
        var object = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        object.removeValue(forKey: "favoriteRequestIDs")
        let legacyData = try! JSONSerialization.data(withJSONObject: object)
        let decoded = try? JSONDecoder().decode(Project.self, from: legacyData)
        check("老项目文件缺收藏字段也能解码", decoded != nil)
        check("缺字段回落为空收藏", decoded?.favoriteRequestIDs.isEmpty == true)
        expectEqual("解码后其余字段不丢", decoded?.requests.count, 2)

        // 收藏状态随请求走：另存为产生新 id，不继承收藏
        let copied = APIRequest(
            name: requestX.name, method: requestX.method, url: requestX.url,
            params: requestX.params, headers: requestX.headers, body: requestX.body
        )
        check("另存为的新接口不继承收藏", !project.isFavorite(copied.id))

        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - 接口搜索

    private static func checkRequestSearch() {
        section("接口搜索（URL 模糊匹配）")

        // —— 子序列模糊匹配 ——
        check(
            "accdet 模糊命中 /account/detail",
            RequestSearch.fuzzyScore(query: "accdet", in: "/account/detail") != nil
        )
        check(
            "字符顺序凑不齐则不命中",
            RequestSearch.fuzzyScore(query: "xyzq", in: "/account/detail") == nil
        )
        check(
            "关键词长于目标不命中",
            RequestSearch.fuzzyScore(query: "accountdetaillll", in: "/a") == nil
        )
        let consecutive = RequestSearch.fuzzyScore(query: "account", in: "/account/detail")!
        let scattered = RequestSearch.fuzzyScore(query: "acount", in: "/a/c/o/u/n/t/x")!
        check("连续命中得分高于分散命中", consecutive > scattered, detail: "\(consecutive) vs \(scattered)")
        let wordStart = RequestSearch.fuzzyScore(query: "det", in: "/account/detail")!
        let midWord = RequestSearch.fuzzyScore(query: "det", in: "/account/xdetay")!
        check("词首命中得分不低于词中命中", wordStart >= midWord)

        // —— 子串评分 ——
        check("子串命中", RequestSearch.substringScore(query: "balance", in: "/account/balance") != nil)
        check("子串未命中", RequestSearch.substringScore(query: "zzz", in: "/account/balance") == nil)
        let prefixHit = RequestSearch.substringScore(query: "acc", in: "account/balance")!
        let lateHit = RequestSearch.substringScore(query: "acc", in: "xxx/yyy/account")!
        check("前缀命中分高于靠后命中", prefixHit > lateHit)

        // —— 分档：名称子串 > URL 子串 > 完整 URL 子串 > 备注子串 > 名称模糊 > URL 模糊 > 方法 ——
        let named = APIRequest(name: "余额查询", method: .get, url: "/x", note: "")
        let byName = RequestSearch.score(request: named, fullURL: "/x", query: "余额")!
        let byURL = RequestSearch.score(
            request: APIRequest(name: "其他", method: .get, url: "/balance"),
            fullURL: "/balance", query: "balance")!
        let byFullURL = RequestSearch.score(
            request: APIRequest(name: "其他", method: .get, url: "/info"),
            fullURL: "https://t.example.com/balance/info", query: "balance")!
        let byNote = RequestSearch.score(
            request: APIRequest(name: "其他", method: .get, url: "/x", note: "Java: getBalance"),
            fullURL: "/x", query: "balance")!
        let byNameFuzzy = RequestSearch.score(
            request: APIRequest(name: "balanceQuery", method: .get, url: "/x"),
            fullURL: "/x", query: "blqy")!
        let byURLFuzzy = RequestSearch.score(
            request: APIRequest(name: "zzz", method: .get, url: "/account/detail"),
            fullURL: "/account/detail", query: "accdt")!
        let byMethod = RequestSearch.score(
            request: APIRequest(name: "zzz", method: .post, url: "/x"),
            fullURL: "/x", query: "post")!
        check("名称子串 > URL 子串", byName > 1000)
        check("URL 子串 > 完整 URL 子串", byURL > byFullURL, detail: "\(byURL) vs \(byFullURL)")
        check("完整 URL 子串 > 备注子串", byFullURL > byNote, detail: "\(byFullURL) vs \(byNote)")
        check("备注子串 > 名称模糊", byNote > byNameFuzzy, detail: "\(byNote) vs \(byNameFuzzy)")
        check("名称模糊 > URL 模糊", byNameFuzzy > byURLFuzzy, detail: "\(byNameFuzzy) vs \(byURLFuzzy)")
        check("URL 模糊 > 方法", byURLFuzzy > byMethod, detail: "\(byURLFuzzy) vs \(byMethod)")
        check("方法前缀匹配", RequestSearch.score(
            request: APIRequest(name: "x", method: .post, url: "/x"),
            fullURL: "/x", query: "po") != nil)
        check("完全不匹配返回 nil", RequestSearch.score(
            request: APIRequest(name: "x", method: .get, url: "/x"),
            fullURL: "/x", query: "qqqq") == nil)

        // —— fullURL 拼接 ——
        expectEqual(
            "相对路径拼 baseURL",
            RequestSearch.resolveFullURL("/account/balance", baseURL: "https://t.example.com/test1"),
            "https://t.example.com/test1/account/balance"
        )
        expectEqual(
            "baseURL 尾斜杠去重",
            RequestSearch.resolveFullURL("/a", baseURL: "https://t.example.com/"),
            "https://t.example.com/a"
        )
        expectEqual(
            "绝对地址原样",
            RequestSearch.resolveFullURL("https://a.com/x", baseURL: "https://t.example.com"),
            "https://a.com/x"
        )
        expectEqual(
            "无 baseURL 时就是原路径",
            RequestSearch.resolveFullURL("/a", baseURL: ""),
            "/a"
        )

        // —— 排序：分数降序，同分按名称 ——
        let requests = [
            APIRequest(name: "ccc 其他", method: .get, url: "/account/detail"),
            APIRequest(name: "账户余额", method: .post, url: "/account/balance"),
            APIRequest(name: "bbb 账户明细", method: .get, url: "/account/detail2"),
        ]
        let results = RequestSearch.search(requests, query: "account")
        check("URL 模糊能搜到多条", results.count >= 2)
        check("结果按分数降序", zip(results, results.dropFirst()).allSatisfy { $0.score >= $1.score })

        let pasteFull = RequestSearch.search(
            [APIRequest(name: "账户余额", method: .post, url: "/account/balance")],
            query: "https://k8s-test.example.com/test1/demo-api/account/balance",
            baseURL: "https://k8s-test.example.com/test1/demo-api"
        )
        expectEqual("粘贴完整 URL 也能搜到", pasteFull.count, 1)

        let byJavaName = RequestSearch.search(
            [APIRequest(name: "上传", method: .post, url: "/file/upload", note: "Java: uploadFile")],
            query: "uploadFile"
        )
        expectEqual("备注里的 Java 方法名可搜", byJavaName.count, 1)

        check("空关键词返回空", RequestSearch.search(requests, query: "  ").isEmpty)
    }

    private static func checkProjectsAndTabs() async {
        section("多项目与多标签")

        guard let root = sandbox else { return }
        let rootURL = root.appendingPathComponent("appstore")
        let app = AppStore(storage: PersistenceStore(root: rootURL))

        expectEqual("首次启动自动创建示例项目", app.projects.count, 1)

        let projectA = app.createProject(name: "项目A", baseURL: "https://a.example.com")
        let projectB = app.createProject(name: "项目B")
        expectEqual("创建多个项目", app.projects.count, 3)
        expectEqual("新建项目自动激活", app.activeProjectID, projectB.id)

        guard let requestA = app.addRequest(projectID: projectA.id, folderID: nil, name: "A1", method: .get, url: "/a1"),
              let requestB = app.addRequest(projectID: projectB.id, folderID: nil, name: "B1", method: .post, url: "/b1")
        else {
            check("新建接口", false)
            return
        }
        expectEqual("接口写入项目", app.project(id: projectA.id)?.requests.count, 1)

        app.openRequest(projectID: projectA.id, requestID: requestA)
        app.openRequest(projectID: projectB.id, requestID: requestB)
        expectEqual("跨项目标签共存", app.sessions.count, 2)
        expectEqual("打开标签时切换当前项目", app.activeProjectID, projectB.id)

        let firstTabID = app.sessions[0].id
        app.activateTab(id: firstTabID)
        expectEqual("激活其他项目标签时项目跟随", app.activeProjectID, projectA.id)

        app.setActiveProject(id: projectB.id)
        expectEqual("切换项目不清空标签", app.sessions.count, 2)

        app.openRequest(projectID: projectA.id, requestID: requestA)
        expectEqual("重复打开同一接口不新增标签", app.sessions.count, 2)

        // 定位信号：树行 / 收藏区点击（reveal: false）不展开目录、不触发滚动；切标签才定位
        if let folderID = app.addFolder(projectID: projectA.id, parentID: nil, name: "深层"),
           let nested = app.addRequest(projectID: projectA.id, folderID: folderID, name: "A2", method: .get, url: "/a2") {
            app.toggleFolder(projectID: projectA.id, nodeID: folderID)
            let ticketBefore = app.sidebarRevealTicket
            app.openRequest(projectID: projectA.id, requestID: nested, reveal: false)
            check("不定位打开：目录保持折叠", app.collapsedFolderIDs.contains(folderID))
            expectEqual("不定位打开：不触发滚动信号", app.sidebarRevealTicket, ticketBefore)
            app.activateTab(id: app.sessions[0].id)
            app.openRequest(projectID: projectA.id, requestID: nested)
            check("定位打开：展开所在目录", !app.collapsedFolderIDs.contains(folderID))
            expectEqual("定位打开：滚动信号 +2（切标签一次、定位一次）", app.sidebarRevealTicket, ticketBefore + 2)
            app.toggleFolder(projectID: projectA.id, nodeID: folderID)
            app.sidebarFilter = "a2"
            app.locateInSidebar(projectID: projectA.id, requestID: nested)
            expectEqual("主动定位：清空搜索词回到树", app.sidebarFilter, "")
            check("主动定位：展开所在目录", !app.collapsedFolderIDs.contains(folderID))
            expectEqual("主动定位：滚动信号 +1", app.sidebarRevealTicket, ticketBefore + 3)
            if let nestedTab = app.sessions.first(where: { $0.requestID == nested }) { app.closeTab(id: nestedTab.id) }
            app.deleteNode(projectID: projectA.id, nodeID: folderID)   // 还原，后面的检查按 A 只有一个接口算
        } else {
            check("新建目录与目录内接口", false)
        }

        // 标签按项目隔离：每个项目只看到自己的标签，各自记住自己停在哪一张
        expectEqual("项目A只看到自己的标签", app.visibleSessions.count, 1)
        expectEqual("项目A停在a1", app.activeSession?.requestID, requestA)
        app.setActiveProject(id: projectB.id)
        expectEqual("切到项目B只看到B的标签", app.visibleSessions.count, 1)
        expectEqual("切到项目B回到B自己的标签", app.activeSession?.requestID, requestB)
        app.setActiveProject(id: projectA.id)
        expectEqual("切回项目A恢复原来的标签", app.activeSession?.requestID, requestA)
        expectEqual("活动标签按项目各记一份", app.activeTabByProject.count, 2)
        expectEqual("标签归属项目互不串门", app.visibleSessions.filter { $0.projectID != projectA.id }.count, 0)

        // 关闭其他标签只作用于当前项目
        _ = app.newDraftTab(projectID: projectA.id)
        expectEqual("项目A有两个标签", app.visibleSessions.count, 2)
        app.closeOtherTabs(keeping: firstTabID)
        expectEqual("关闭其他标签后项目A只剩一个", app.visibleSessions.count, 1)
        check("关闭其他标签不动别的项目", app.sessions.contains { $0.projectID == projectB.id })

        // 两级标签：顶层只列出「有标签的项目」，按项目顺序稳定排列
        expectEqual("顶层项目标签只含有标签的项目", app.projectsWithTabs.map(\.id), [projectA.id, projectB.id])
        check("项目A此刻没有未保存标签", !app.hasDirtyTabs(projectID: projectA.id))
        if let current = app.activeTabID {
            app.updateBuffer(tabID: current) { $0.url = "/dirty-probe" }
            check("编辑后该项目被标记为有未保存", app.hasDirtyTabs(projectID: projectA.id))
            app.revertBuffer(tabID: current)
            check("丢弃修改后未保存标记消失", !app.hasDirtyTabs(projectID: projectA.id))
        }

        app.setActiveProject(id: projectA.id)
        app.activateAdjacentProjectTab(offset: 1)
        expectEqual("往后切到下一个项目标签", app.activeProjectID, projectB.id)
        app.activateAdjacentProjectTab(offset: 1)
        expectEqual("项目标签循环回第一个", app.activeProjectID, projectA.id)
        app.activateAdjacentProjectTab(offset: -1)
        expectEqual("往前切是循环的", app.activeProjectID, projectB.id)
        expectEqual("切项目标签不丢任何标签", app.sessions.count, 2)
        expectEqual("两级结构下每个项目各有活动标签", app.activeTabByProject.count, 2)
        app.setActiveProject(id: projectA.id)
        check("切回项目A仍停在a1", app.activeSession?.requestID == requestA)

        app.updateBuffer(tabID: firstTabID) { $0.url = "/a1/changed" }
        check("编辑缓冲标记脏", app.sessions[0].isDirty)
        expectEqual("未保存不落回项目", app.project(id: projectA.id)?.request(id: requestA)?.url, "/a1")

        let saved = app.saveTab(tabID: firstTabID)
        check("保存成功", saved)
        expectEqual("保存写回项目", app.project(id: projectA.id)?.request(id: requestA)?.url, "/a1/changed")
        expectEqual("保存后脏标记清除", app.sessions[0].isDirty, false)
        expectEqual("保存后集合树名称同步", app.project(id: projectA.id)?.collection.first?.name, "A1")

        // 环境切换影响实际发送地址
        app.openRequest(projectID: projectA.id, requestID: requestA)
        app.updateBuffer(tabID: app.activeTabID!) { $0.url = "/ping" }
        expectEqual("预览地址拼上 baseURL", app.previewURL(for: app.activeSession!)?.url, "https://a.example.com/ping")
        if let second = app.addEnvironment(projectID: projectA.id, name: "测试环境2", baseURL: "https://t2.example.com") {
            app.setActiveEnvironment(projectID: projectA.id, environmentID: second)
            expectEqual("切环境后预览地址变化", app.previewURL(for: app.activeSession!)?.url, "https://t2.example.com/ping")
        }

        // 草稿标签：保存后应变成正式接口
        let draft = app.newDraftTab(projectID: projectA.id)
        check("新建的是草稿标签", app.session(id: draft?.id ?? UUID())?.isDraft == true)
        app.updateBuffer(tabID: draft?.id ?? UUID()) { $0.url = "/draft" }
        _ = app.saveTab(tabID: draft?.id ?? UUID())
        expectEqual("草稿保存为正式接口", app.project(id: projectA.id)?.requests.count, 2)
        expectEqual("草稿保存后不再是草稿", app.session(id: draft?.id ?? UUID())?.isDraft, false)

        // 复制项目要重新生成所有标识
        // 注意：projectA 是创建时刻的值类型快照，计数要从 store 现取。
        let sourceRequestCount = app.project(id: projectA.id)?.requests.count ?? -1
        if let copy = app.duplicateProject(id: projectA.id) {
            expectEqual("副本接口数量一致", copy.requests.count, sourceRequestCount)
            check("副本接口 id 已重新生成", !copy.requests.contains { $0.id == requestA })
            check("副本集合树指向新接口", copy.collection.first?.requestID != requestA)
            expectEqual("副本名字加后缀", copy.name, "项目A 副本")
        } else {
            check("复制项目", false)
        }

        // 删除请求会关闭其标签
        let doomedRequest = app.project(id: projectA.id)?.requests.first?.id
        app.openRequest(projectID: projectA.id, requestID: doomedRequest ?? UUID())
        if let doomedRequest, let nodeID = app.project(id: projectA.id)?.collection.nodeID(forRequest: doomedRequest) {
            app.deleteNode(projectID: projectA.id, nodeID: nodeID)
        }
        check("删除接口同时关闭其标签", !app.sessions.contains { $0.requestID == doomedRequest })

        // 删除项目只关掉它自己的标签
        app.deleteProject(id: projectB.id)
        expectEqual("删除项目移除其标签", app.sessions.contains { $0.projectID == projectB.id }, false)
        expectEqual("删除项目后项目数", app.projects.count, 3)

        await app.flushSaveAndWait()

        // 重启：从磁盘恢复项目与标签
        let reloaded = AppStore(storage: PersistenceStore(root: rootURL))
        expectEqual("重启后恢复项目数", reloaded.projects.count, 3)
        check("重启后项目数据完整", (reloaded.project(id: projectA.id)?.requests.count ?? -1) == 1)
        check("重启后标签仍在", !reloaded.sessions.isEmpty)
        check("重启后活动标签属于当前项目", reloaded.activeSession?.projectID == reloaded.activeProjectID)
        check("重启后每个项目的活动标签都指向真实标签", reloaded.activeTabByProject.values.allSatisfy { tabID in
            reloaded.sessions.contains { $0.id == tabID }
        })

        // 指向已删除接口的失效标签不应复活
        let survivingRequest = reloaded.project(id: projectA.id)?.requests.first?.id
        if let survivingRequest,
           let nodeID = reloaded.project(id: projectA.id)?.collection.nodeID(forRequest: survivingRequest) {
            reloaded.deleteNode(projectID: projectA.id, nodeID: nodeID)
        }
        await reloaded.flushSaveAndWait()
        let reloadedAgain = AppStore(storage: PersistenceStore(root: rootURL))
        check("指向已删除接口的标签不会复活", !reloadedAgain.sessions.contains { $0.requestID == survivingRequest })
    }

    // MARK: - SSE 流式响应

    // MARK: - 响应树：路径 / 筛选 / 取子树

    private static func checkResponseTreeFilter() {
        section("响应树筛选")
        guard let json = JSONValueParser.parse(
            #"{"code":0,"data":{"items":[{"name":"iPhone","price":1},{"name":"pixel","price":2}],"a.b":true},"traceId":"x"}"#
        ) else {
            check("解析样例 JSON", false)
            return
        }

        let all = JSONTreeFlattener.rows(json, expandDepth: 99, toggled: [])
        expectEqual("根路径为 $", all.first?.keyPath, "$")
        check("对象成员路径用点号", all.contains { $0.keyPath == "$.data.items[0].name" && !$0.isClosing })
        check("含特殊字符的键用方括号", all.contains { $0.keyPath == #"$.data["a.b"]"# })
        expectEqual("按索引路径取子树", JSONTreeFlattener.node(in: json, at: "0/1/0/1")?.summary, "{2 个字段}")
        check("越界路径返回 nil", JSONTreeFlattener.node(in: json, at: "0/9") == nil)

        let byValue = JSONTreeFlattener.rows(json, expandDepth: 1, toggled: [], filter: "PIXEL")
        check("按值筛选不区分大小写", byValue.contains { $0.keyPath == "$.data.items[1].name" && !$0.isClosing })
        check("未命中的兄弟节点被隐藏", !byValue.contains { $0.keyPath == "$.data.items[0]" })
        check("命中路径上的祖先强制展开", byValue.contains { $0.keyPath == "$.data.items" && $0.isExpanded })
        check("命中之外的顶层字段被隐藏", !byValue.contains { $0.keyPath == "$.traceId" })

        let byKey = JSONTreeFlattener.rows(json, expandDepth: 1, toggled: [], filter: "items")
        check("按字段名筛选：自身命中的容器折叠显示", byKey.contains { $0.keyPath == "$.data.items" && !$0.isExpanded && $0.summary != nil })
        let byKeyOpened = JSONTreeFlattener.rows(json, expandDepth: 1, toggled: ["0/1/0"], filter: "items")
        check("自身命中的容器手动点开后展示完整子树", byKeyOpened.contains { $0.keyPath == "$.data.items[0]" })
        expectEqual("完全不命中返回空", JSONTreeFlattener.rows(json, expandDepth: 1, toggled: [], filter: "zzz").count, 0)
    }

    private static func checkSSEStream() {
        section("SSE 流式响应")

        var parser = SSEParser()
        let basic = parser.feed(Data("data: hello\n\n".utf8), at: 0.1)
        expectEqual("单个事件", basic.map(\.data), ["hello"])
        check("没有 event 字段时事件名为 nil", basic.first?.name == nil)
        expectEqual("事件序号从 1 起", basic.first?.id, 1)

        let rich = parser.feed(Data("event: tick\nid: 7\ndata: a\ndata: b\nretry: 3000\n\n".utf8), at: 0.2)
        expectEqual("多行 data 用换行拼接", rich.first?.data, "a\nb")
        expectEqual("event 字段是事件名", rich.first?.name, "tick")
        expectEqual("id 字段是事件 id", rich.first?.lastEventID, "7")
        expectEqual("序号递增", rich.first?.id, 2)

        let heartbeat = parser.feed(Data(": ping\n\n".utf8), at: 0.3)
        check("注释 / 心跳不产生事件", heartbeat.isEmpty)

        let crlf = parser.feed(Data("data: x\r\n\r\n".utf8), at: 0.4)
        expectEqual("CRLF 换行也能解析", crlf.map(\.data), ["x"])
        expectEqual("上一个事件的 id 会沿用", crlf.first?.lastEventID, "7")
        check("event 名不沿用", crlf.first?.name == nil)

        // 「你好」的 UTF-8 是 6 个字节，从第 4 个字节处切开，前半段不能产生事件也不能出乱码
        let bytes = Array("data: 你好\n\n".utf8)
        let first = parser.feed(Data(bytes[..<9]), at: 0.5)
        check("半行 / 半个字符先攒着", first.isEmpty)
        let second = parser.feed(Data(bytes[9...]), at: 0.6)
        expectEqual("跨块拼接后解码正确", second.map(\.data), ["你好"])

        let dangling = parser.feed(Data("data: last".utf8), at: 0.7)
        check("没收到空行不派发", dangling.isEmpty)
        expectEqual("连接结束时补发最后一个事件", parser.finish(at: 0.8).map(\.data), ["last"])
        check("结束后再 finish 不重复派发", parser.finish(at: 0.9).isEmpty)

        let empty = parser.feed(Data("event: only-name\n\n".utf8), at: 1.0)
        check("只有 event 没有 data 的空行不派发", empty.isEmpty)

        // 响应快照：流式追加与关闭
        var payload = HTTPResponsePayload(
            requestURL: "http://x/sse", method: "GET", statusCode: 200,
            headers: [HeaderField(name: "Content-Type", value: "text/event-stream")]
        )
        payload.stream = SSEStreamState()
        check("流式响应 isStream", payload.isStream)
        payload.appendStream(chunk: Data("data: a\n\n".utf8), events: basic, elapsed: 1.5)
        expectEqual("事件追加进 stream", payload.stream?.events.count, 1)
        expectEqual("原文随字节累积", payload.text, "data: a\n\n")
        check("流式响应不解析 JSON 树", payload.jsonValue == nil)
        payload.closeStream(reason: "服务端已结束", elapsed: 2)
        expectEqual("关闭后 isOpen 为 false", payload.stream?.isOpen, false)
        expectEqual("关闭原因", payload.stream?.endReason, "服务端已结束")

        // 标签页：接收中 → 手动停止保留事件
        let session = TabSession(projectID: UUID(), requestID: nil, buffer: APIRequest(url: "http://x/sse"))
        session.beginSending(task: Task {})
        var open = payload
        open.stream?.isOpen = true
        open.stream?.endReason = nil
        session.receiveStream(open)
        check("收到流式快照后进入 streaming", session.isStreaming && session.isSending)
        session.cancel()
        expectEqual("手动停止后标签结束", session.phase, TabSession.Phase.finished)
        expectEqual("停止后保留已收到的事件", session.response?.stream?.events.count, 1)
        expectEqual("停止原因", session.response?.stream?.endReason, "已手动停止")
        var late = open
        late.appendStream(chunk: Data(), events: rich, elapsed: 3)
        session.receiveStream(late)
        expectEqual("停止后迟到的快照被忽略", session.response?.stream?.events.count, 1)
    }

    // MARK: - Java 项目接口同步

    private static func checkJavaSync() async {
        section("Java 项目接口同步")

        guard let root = sandbox else { return }
        let rootURL = root.appendingPathComponent("java-project")
        let sourceDirectory = rootURL.appendingPathComponent("src/main/java/com/example")
        try? FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let controllerURL = sourceDirectory.appendingPathComponent("AccountController.java")
        let controller = """
        package com.example;

        @RestController
        @RequestMapping("/api/accounts")
        public class AccountController {
            @GetMapping("/{id}")
            public Account get(@PathVariable("id") String id,
                               @RequestParam(value = "withProfile", required = false) Boolean withProfile,
                               @RequestHeader("X-Tenant") String tenant,
                               @RequestBody Account body) {
                return body;
            }

            @PostMapping
            public String create(@RequestBody Map<String, Object> payload) {
                return "ok";
            }
        }
        """
        try? controller.write(to: controllerURL, atomically: true, encoding: .utf8)

        let requestType = """
        package com.example;

        public class GoodsDetailRequest {
            private String itemId;
            private String shopType;
        }
        """
        let requestTypeURL = sourceDirectory.appendingPathComponent("GoodsDetailRequest.java")
        try? requestType.write(to: requestTypeURL, atomically: true, encoding: .utf8)

        let goodsController = """
        package com.example;

        @RestController
        @RequestMapping("/goods")
        public class GoodsController {
            @GetMapping("/detail")
            public String detail(GoodsDetailRequest request) {
                return "ok";
            }
        }
        """
        let goodsControllerURL = sourceDirectory.appendingPathComponent("GoodsController.java")
        try? goodsController.write(to: goodsControllerURL, atomically: true, encoding: .utf8)

        do {
            let interfaces = try JavaProjectScanner.scan(at: rootURL)
            expectEqual("扫描 Controller 方法数", interfaces.count, 3)
            let getter = interfaces.first { $0.name == "get" }
            expectEqual("读取 GET 地址", getter?.url, "/api/accounts/{id}")
            expectEqual("读取请求方法", getter?.method, .get)
            check("路径参数", getter?.params.contains { $0.location == .path && $0.key == "id" } == true)
            check("查询参数", getter?.params.contains { $0.location == .query && $0.key == "withProfile" } == true)
            check("请求头参数", getter?.headers.contains { $0.key == "X-Tenant" } == true)
            expectEqual("请求体类型", getter?.body.kind, .json)

            let goodsDetail = interfaces.first { $0.name == "detail" }
            expectEqual("读取 POJO 请求地址", goodsDetail?.url, "/goods/detail")
            check("展开 GET POJO 字段", goodsDetail?.params.contains { $0.key == "itemId" && $0.location == .query } == true)
            check("展开 GET POJO 第二字段", goodsDetail?.params.contains { $0.key == "shopType" && $0.location == .query } == true)
            check("不再保留 request 占位参数", goodsDetail?.params.contains { $0.key == "request" } == false)

            let app = AppStore(storage: PersistenceStore(root: root.appendingPathComponent("java-store")))
            let project = app.createProject(name: "Java 项目")
            let manual = APIRequest(name: "手工接口", method: .get, url: "/manual")
            app.updateProject(id: project.id) { $0.insert(manual, intoFolder: nil) }
            await app.syncJavaInterfaces(projectID: project.id, folderURL: rootURL)
            let synced = app.project(id: project.id)
            expectEqual("同步后接口数量", synced?.requests.count, 4)
            let first = synced?.requests.first { $0.sourceKey?.contains("get") == true }
            check("同步 Controller 目录", synced?.collection.contains { $0.kind == .folder && $0.name == "AccountController" } == true)
            check("手工接口保留", synced?.requests.contains { $0.name == "手工接口" } == true)
            check("来源标记可匹配", first?.sourceKey == "src/main/java/com/example/AccountController.java#AccountController#get")

            let updatedController = controller.replacingOccurrences(of: "\"/{id}\"", with: "\"/v2/{id}\"")
            try updatedController.write(to: controllerURL, atomically: true, encoding: .utf8)
            await app.syncJavaInterfaces(projectID: project.id, folderURL: rootURL)
            let refreshed = app.project(id: project.id)
            expectEqual("二次同步接口数量", refreshed?.requests.count, 4)
            expectEqual("同一接口复用请求 id", refreshed?.requests.first { $0.sourceKey?.contains("get") == true }?.id, first?.id)
            expectEqual("地址按源码更新", refreshed?.requests.first { $0.sourceKey?.contains("get") == true }?.url, "/api/accounts/v2/{id}")
            check("记录绑定路径", refreshed?.javaSyncFolderPath == rootURL.path)
            check("记录同步时间", refreshed?.javaSyncedAt != nil)

            // 从别的工具导入的接口没有 sourceKey，只有 `Java: 类.方法` 备注。
            // 重新扫描时应该认领并原地更新它，而不是再生成一份同名接口；
            // 上一次同步已经生成的那份重复项则合并掉，打开的标签跟着改指。
            let importedProject = app.createProject(name: "导入后同步")
            let imported = APIRequest(
                name: "商品详情",
                method: .get,
                url: "/goods/detail",
                params: [KeyValueItem(key: "request")],
                note: "商品详情\nJava: GoodsController.detail"
            )
            let generatedDuplicate = APIRequest(
                name: "detail",
                method: .get,
                url: "/goods/detail",
                params: [KeyValueItem(key: "request")],
                sourceKey: "src/main/java/com/example/GoodsController.java#GoodsController#detail"
            )
            app.updateProject(id: importedProject.id) { project in
                project.requests = [imported, generatedDuplicate]
                project.collection = [
                    CollectionNode.folder(name: "GoodsController", children: [
                        CollectionNode.request(id: imported.id, name: imported.name),
                        CollectionNode.request(id: generatedDuplicate.id, name: generatedDuplicate.name)
                    ])
                ]
            }
            app.openRequest(projectID: importedProject.id, requestID: generatedDuplicate.id)
            await app.syncJavaInterfaces(projectID: importedProject.id, folderURL: rootURL)

            let mergedProject = app.project(id: importedProject.id)
            let adopted = mergedProject?.request(id: imported.id)
            check("导入的接口原地更新", adopted?.params.contains { $0.key == "itemId" && $0.location == .query } == true)
            check("导入的接口保留名字", adopted?.name == "商品详情")
            check("导入的接口补上来源标记", adopted?.sourceKey?.hasSuffix("#GoodsController#detail") == true)
            check("原有业务说明保留", adopted?.note.hasPrefix("商品详情\nJava: GoodsController.detail") == true)
            check("重复的同步接口被合并", mergedProject?.requests.contains { $0.id == generatedDuplicate.id } == false)
            check("合并后接口数量正确", mergedProject?.requests.count == 3)
            check("集合树不再有重复节点", mergedProject?.collection.containedRequestIDs().count == 3)
            check("标签改指保留下来的接口", app.sessions.contains { $0.requestID == imported.id })
            check(
                "重新扫描后标签参数立即刷新",
                app.sessions.first { $0.requestID == imported.id }?.buffer.params.contains { $0.key == "itemId" } == true
            )

            await app.syncJavaInterfaces(projectID: importedProject.id, folderURL: rootURL)
            let resynced = app.project(id: importedProject.id)
            check("再次同步不重复生成", resynced?.requests.count == 3)
            check(
                "再次同步说明不叠加",
                resynced?.request(id: imported.id)?.note
                    == "商品详情\nJava: GoodsController.detail\n文件: src/main/java/com/example/GoodsController.java"
            )
        } catch {
            check("扫描 Java Controller", false, detail: error.localizedDescription)
        }
    }

    // MARK: - 工作区导入

    private static func checkWorkspaceImport() {
        section("工作区导入（来自参考项目的 wac 格式）")

        let fixture = """
        {
          "format": "wac-workspace",
          "version": 1,
          "projects": [
            {
              "name": "demo",
              "description": "扫描自 Java 源码",
              "environments": [
                { "name": "测试环境1", "baseUrl": "https://t1.example.com/demo-api", "variables": [] },
                { "name": "本地", "baseUrl": "http://localhost:8081/demo-api", "variables": [] }
              ],
              "globals": [],
              "globalHeaders": [
                { "key": "version", "value": "6.8.0", "enabled": true, "remark": "App 版本号" }
              ],
              "requests": [
                {
                  "name": "getUser", "folderId": "f_1_UserController", "method": "GET",
                  "url": "/user/:id", "description": "Java: getUser",
                  "params": [ { "key": "id", "value": "1", "enabled": true, "remark": "", "type": "Long" } ],
                  "headers": [],
                  "body": { "mode": "none", "json": "", "raw": "", "form": [], "urlencoded": [] }
                },
                {
                  "name": "createUser", "folderId": "f_1_UserController", "method": "POST",
                  "url": "/user", "description": "Java: createUser",
                  "params": [],
                  "headers": [ { "key": "Content-Type", "value": "application/json", "enabled": true, "remark": "" } ],
                  "body": { "mode": "json", "json": "{\\n  \\"name\\": \\"\\"\\n}", "raw": "", "form": [], "urlencoded": [] }
                },
                {
                  "name": "upload", "folderId": "f_2_FileController", "method": "POST",
                  "url": "/file/upload", "description": "",
                  "params": [], "headers": [],
                  "body": { "mode": "form", "json": "", "raw": "", "form": [ { "key": "file", "value": "", "enabled": true, "remark": "", "type": "file" }, { "key": "biz", "value": "avatar", "enabled": true, "remark": "" } ], "urlencoded": [] }
                },
                {
                  "name": "ping", "folderId": "", "method": "GET",
                  "url": "/ping", "description": "",
                  "params": [], "headers": [],
                  "body": { "mode": "none", "json": "", "raw": "", "form": [], "urlencoded": [] }
                }
              ]
            }
          ]
        }
        """

        do {
            let projects = try WACImport.projects(from: Data(fixture.utf8))
            expectEqual("导入项目数", projects.count, 1)

            guard let project = projects.first else { return }
            expectEqual("导入接口数", project.requests.count, 4)
            expectEqual("导入环境数", project.environments.count, 2)
            expectEqual("导入全局请求头", project.globalHeaders.count, 1)
            expectEqual("环境 baseURL", project.environments.first?.baseURL, "https://t1.example.com/demo-api")

            let folders = project.collection.filter { $0.kind == .folder }
            expectEqual("按 Controller 归目录", folders.count, 2)
            check("目录名去掉扫描前缀", folders.contains { $0.name == "UserController" })
            expectEqual(
                "目录内接口数",
                folders.first { $0.name == "UserController" }?.children.count,
                2
            )
            check("无目录接口挂在根", project.collection.contains { $0.kind == .request && $0.name == "ping" })

            let getUser = project.requests.first { $0.name == "getUser" }
            expectEqual("路径参数被识别", getUser?.params.first?.location, ParamLocation.path)

            let createUser = project.requests.first { $0.name == "createUser" }
            expectEqual("JSON 请求体识别", createUser?.body.kind, RequestBodyKind.json)
            check("请求体内容保留", createUser?.body.text.contains("\"name\"") == true)

            let upload = project.requests.first { $0.name == "upload" }
            expectEqual("form-data 保留为 form-data", upload?.body.kind, RequestBodyKind.formData)
            check("不再写降级说明", upload?.note.contains("降级") == false)
            let fileField = upload?.body.fields.first { $0.key == "file" }
            expectEqual("file 字段被标成文件字段", fileField?.valueKind, KeyValueKind.file)
            let textField = upload?.body.fields.first { $0.key == "biz" }
            expectEqual("文本字段保留值", textField?.value, "avatar")
            expectEqual("文本字段仍是文本类型", textField?.valueKind, KeyValueKind.text)

            // 未知方法回落 GET
            let unknown = """
            { "format": "wac-collection", "name": "c", "requests": [
                { "name": "x", "method": "TRACE", "url": "/x" } ] }
            """
            let unknownProject = try? WACImport.projects(from: Data(unknown.utf8)).first
            expectEqual("未知方法回落 GET", unknownProject?.requests.first?.method, HTTPMethod.get)

            // 导入后可直接用于请求编排
            if let getUser {
                let resolved = try? RequestBuilder.resolve(
                    request: getUser,
                    project: project,
                    environment: project.environments.first
                )
                expectEqual("导入项目可直接编排请求", resolved?.urlString, "https://t1.example.com/demo-api/user/1")
            }
        } catch {
            check("导入 wac 工作区", false, detail: error.localizedDescription)
        }

        check("无法识别的文件报错", (try? WACImport.projects(from: Data("{\"foo\":1}".utf8))) == nil)
    }

    // MARK: - 清理

    private static func cleanup() {
        guard let sandbox else { return }
        try? FileManager.default.removeItem(at: sandbox)
    }
}
