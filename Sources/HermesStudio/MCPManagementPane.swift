import StudioCore
import SwiftUI

@MainActor
struct MCPManagementPane: View {
    @ObservedObject var management: MCPManagement
    let roles: [Role]
    let test: (MCPServer) async -> Void
    @State private var editor: MCPServer?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("MCP 管理").font(.system(size: 28, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text("外部服务仅对勾选的角色开放，变更从下一轮对话生效。")
                        .font(.system(size: 12)).foregroundStyle(StudioPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                StudioPrimaryButton(title: "添加服务", symbol: "plus") { editor = MCPServer() }
                    .disabled(management.loadError != nil)
            }
            if let error = management.loadError ?? error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.system(size: 12)).foregroundStyle(StudioPalette.accent)
            }
            builtInService
            if management.servers.isEmpty, management.loadError == nil {
                VStack(alignment: .leading, spacing: 6) {
                    Text("未添加外部服务").font(.system(size: 14, weight: .semibold))
                    Text("添加本地命令或 HTTP 地址，测试连接后为角色勾选服务。")
                        .font(.system(size: 12)).foregroundStyle(StudioPalette.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
                .background(StudioPalette.sidebar, in: RoundedRectangle(cornerRadius: 9))
            }
            LazyVStack(spacing: 0) {
                ForEach(management.servers) { service in
                    MCPServerRow(server: service, roles: roles, testState: management.tests[service.id],
                        edit: { editor = service }, test: { Task { await test(service) } },
                        setEnabled: { enabled in mutate { try management.setEnabled(enabled, for: service.id) } },
                        assign: { role, assigned in mutate { try management.assign(assigned, roleID: role, to: service.id) } },
                        remove: { mutate { try management.remove(service.id) } })
                    if service.id != management.servers.last?.id { StudioRule() }
                }
            }
            .background(StudioPalette.sidebar, in: RoundedRectangle(cornerRadius: 9))
        }
        .sheet(item: $editor) { service in
            let editing = management.servers.contains { $0.id == service.id }
            MCPServerEditor(server: service, editing: editing) { updated in
                try management.saveConnection(updated, editing: editing)
                error = nil
            }
        }
    }

    private var builtInService: some View {
        let available = management.builtInExecutable != nil
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Label("暖光协作", systemImage: "person.2")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Text(available ? "内置 · 自动注册" : "内置 · 程序缺失")
                    .font(.system(size: 12))
                    .foregroundStyle(available ? StudioPalette.muted : StudioPalette.accent)
            }
            if available {
                Text("按需查询群记忆和历史。群内可按用户当前消息保存群记忆、邀请成员或读取链接。")
                    .font(.system(size: 12)).foregroundStyle(StudioPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(StudioCollaborationTool.allCases, id: \.self) { tool in
                    HStack(spacing: 8) {
                        Text(tool.title).font(.system(size: 12))
                        Text(tool.rawValue).font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(StudioPalette.muted).textSelection(.enabled)
                        if tool == .groupInvitation || tool == .groupLink || tool == .groupMemorySave {
                            Text("群内").font(.system(size: 11)).foregroundStyle(StudioPalette.muted)
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(StudioPalette.sidebar, in: RoundedRectangle(cornerRadius: 9))
    }

    private func mutate(_ action: () throws -> Void) {
        do {
            try action()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct MCPServerRow: View {
    let server: MCPServer
    let roles: [Role]
    let testState: MCPManagement.TestState?
    let edit: () -> Void
    let test: () -> Void
    let setEnabled: (Bool) -> Void
    let assign: (UUID, Bool) -> Void
    let remove: () -> Void
    @State private var confirmRemoval = false

    private var roleCount: Int { roles.filter { server.roleIDs.contains($0.id) }.count }
    private var testing: Bool {
        if case .testing = testState { return true }
        return false
    }

    private var destination: String {
        if server.connection.transport == .stdio { return server.connection.endpoint }
        var url = URLComponents(string: server.connection.endpoint)
        url?.query = nil
        return url?.string ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(server.connection.name).font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    Text("\(server.connection.transport == .stdio ? "STDIO" : "HTTP") · \(destination)")
                        .font(.system(size: 12)).foregroundStyle(StudioPalette.muted)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Toggle("启用 \(server.connection.name)", isOn: Binding(get: { server.enabled }, set: setEnabled))
                    .toggleStyle(.switch).labelsHidden().controlSize(.small)
                    .help(server.enabled ? "停用服务" : "启用服务")
                Button(testing ? "测试中…" : "测试连接", action: test)
                    .buttonStyle(QuietButton()).disabled(testing).fixedSize()
                    .accessibilityLabel("测试连接 \(server.connection.name)")
                Button("编辑", action: edit)
                    .buttonStyle(QuietButton()).fixedSize()
                    .accessibilityLabel("编辑 \(server.connection.name)")
                StudioIconButton(title: "移除 \(server.connection.name)", symbol: "trash") { confirmRemoval = true }
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(server.enabled ? "已启用" : "已停用")
                    .foregroundStyle(StudioPalette.muted)
                testStatus
            }
            .font(.system(size: 12))
            DisclosureGroup(roleCount == 0 ? "选择可用角色" : "可用角色 · \(roleCount) 个") {
                if roles.isEmpty {
                    Text("请先创建角色。").foregroundStyle(StudioPalette.muted).padding(.top, 6)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 156), spacing: 12)],
                        alignment: .leading, spacing: 8) {
                        ForEach(roles) { role in
                            Toggle(role.name, isOn: Binding(get: { server.roleIDs.contains(role.id) },
                                set: { assign(role.id, $0) }))
                                .toggleStyle(.checkbox).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.top, 8)
                }
            }
            .font(.system(size: 12))
        }
        .padding(16)
        .alert("移除 \(server.connection.name)？", isPresented: $confirmRemoval) {
            Button("取消", role: .cancel) {}
            Button("移除", role: .destructive, action: remove)
        } message: {
            Text("此服务和它的角色勾选将从暖光移除。")
        }
    }

    @ViewBuilder
    private var testStatus: some View {
        switch testState {
        case .none:
            Text("尚未测试连接").foregroundStyle(StudioPalette.muted)
        case .testing:
            Text("正在检测服务").foregroundStyle(StudioPalette.muted)
        case .passed(let result):
            VStack(alignment: .leading, spacing: 4) {
                Label(result.toolCount.map { "连接通过，发现 \($0) 个工具" } ?? "连接通过",
                    systemImage: "checkmark.circle").foregroundStyle(StudioPalette.connected)
                if !result.toolNames.isEmpty {
                    Text(result.toolNames.joined(separator: "、"))
                        .textSelection(.enabled).foregroundStyle(StudioPalette.muted)
                }
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.circle").foregroundStyle(StudioPalette.accent)
        }
    }
}

private struct MCPServerEditor: View {
    let editing: Bool
    let save: (MCPServer) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var server: MCPServer
    @State private var command = ""
    @State private var address = ""
    @State private var arguments = ""
    @State private var environment = ""
    @State private var headers = ""
    @State private var error: String?

    init(server: MCPServer, editing: Bool, save: @escaping (MCPServer) throws -> Void) {
        self.editing = editing
        self.save = save
        _server = State(initialValue: server)
        let connection = server.connection
        let variables = connection.variables.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
        if connection.transport == .stdio {
            _command = State(initialValue: connection.endpoint)
            _arguments = State(initialValue: connection.arguments.joined(separator: "\n"))
            _environment = State(initialValue: variables)
        } else {
            _address = State(initialValue: connection.endpoint)
            _headers = State(initialValue: variables)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(editing ? "编辑 MCP 服务" : "添加 MCP 服务")
                .font(.system(size: 21, weight: .semibold)).accessibilityAddTraits(.isHeader)
                .padding(20)
            StudioRule()
            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    field("服务名称", placeholder: "例如 calendar", text: $server.connection.name)
                    Picker("连接方式", selection: $server.connection.transport) {
                        Text("本地 STDIO").tag(MCPServer.Transport.stdio)
                        Text("远程 HTTP").tag(MCPServer.Transport.http)
                    }
                    .pickerStyle(.segmented)
                    if server.connection.transport == .stdio {
                        field("可执行命令", placeholder: "例如 /opt/homebrew/bin/uvx", text: $command)
                        multiline("命令参数（选填）", hint: "每行一个参数。相对路径会随工作目录变化，建议填写绝对路径。", text: $arguments)
                        multiline("环境变量（选填）", hint: "每行一项，例如 API_KEY=${MCP_API_KEY}。", text: $environment)
                    } else {
                        field("HTTP 服务地址", placeholder: "https://example.com/mcp", text: $address)
                        multiline("HTTP 请求头（选填）", hint: "每行一项，例如 Authorization=Bearer ${MCP_TOKEN}。", text: $headers)
                    }
                }
                .padding(20)
            }
            .frame(maxHeight: 386)
            StudioRule()
            VStack(alignment: .leading, spacing: 8) {
                if let error {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.system(size: 12)).foregroundStyle(StudioPalette.accent)
                }
                HStack {
                    Spacer()
                    Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("保存", action: saveChanges).keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
        }
        .frame(width: 530)
        .foregroundStyle(StudioPalette.ink)
        .background(.regularMaterial)
    }

    private func field(_ label: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 12, weight: .semibold))
            TextField(placeholder, text: text).accessibilityLabel(label)
        }
    }

    private func multiline(_ label: String, hint: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 12, weight: .semibold))
            TextEditor(text: text)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(5)
                .frame(height: 62)
                .background(StudioPalette.sidebar, in: RoundedRectangle(cornerRadius: 6))
                .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(StudioPalette.line).allowsHitTesting(false) }
                .accessibilityLabel(label)
            Text(hint).font(.system(size: 11)).foregroundStyle(StudioPalette.muted)
        }
    }

    private func saveChanges() {
        do {
            var updated = server
            updated.connection.name = server.connection.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let stdio = server.connection.transport == .stdio
            updated.connection.endpoint = (stdio ? command : address).trimmingCharacters(in: .whitespacesAndNewlines)
            updated.connection.arguments = stdio ? arguments.split(whereSeparator: \.isNewline).map(String.init) : []
            updated.connection.variables = try variablePairs(stdio ? environment : headers)
            try save(updated)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func variablePairs(_ text: String) throws -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let separator = line.firstIndex(of: "=") else {
                throw StudioError.message("环境变量和请求头每行均应使用「名称=值」。")
            }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, result[key] == nil else {
                throw StudioError.message("环境变量或请求头名称为空或重复。")
            }
            result[key] = String(line[line.index(after: separator)...])
        }
        return result
    }
}
