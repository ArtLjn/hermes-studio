import StudioCore
import SwiftUI

struct ComposerRunSettingsButton: View {
    @ObservedObject var studio: StudioModel
    @State private var presented = false

    var body: some View {
        Button { presented.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.shield")
                Text(studio.runSettings?.editApproval.map { approvalTitle($0.value, fallback: $0.name) } ?? "权限")
                    .fixedSize()
                Text("·").accessibilityHidden(true)
                Text(studio.composerModelName)
                    .lineLimit(1)
                if let effort = studio.runSettings?.effort {
                    Text("·").accessibilityHidden(true)
                    Text(effortLabel(effort.value)).fixedSize()
                }
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .padding(.horizontal, 6)
            .frame(height: 27)
        }
        .buttonStyle(StudioRowButton(selected: presented))
        .accessibilityLabel("运行设置")
        .accessibilityValue([
            studio.runSettings?.editApproval.map { approvalTitle($0.value, fallback: $0.name) },
            studio.composerModelName,
            studio.runSettings?.effort.map { effortLabel($0.value) }
        ].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "，"))
        .help(studio.runningConversation == nil ? "设置当前对话的权限、模型与推理强度" : "回复结束后可调整运行设置")
        .disabled(!studio.available || studio.runningConversation != nil)
        .popover(isPresented: $presented, arrowEdge: .bottom) {
            ComposerRunSettings(studio: studio)
        }
        .onChange(of: studio.runSettingsContext) { _, _ in presented = false }
    }
}

private struct ComposerRunSettings: View {
    @ObservedObject var studio: StudioModel
    @State private var choosingModel = false
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("运行设置").font(.system(size: 14, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if studio.loadingRunSettings { ProgressView().controlSize(.small) }
            }
            StudioRule()
            if let approval = studio.runSettings?.editApproval, !approval.choices.isEmpty {
                approvalPicker(approval)
                if studio.runSettings?.model != nil || studio.runSettings?.effort != nil { StudioRule() }
            }
            if let model = studio.runSettings?.model {
                modelPicker(model)
            }
            if let effort = studio.runSettings?.effort {
                effortPicker(effort)
            }
            if let error = studio.runSettingsError {
                HStack {
                    Text(error).foregroundStyle(StudioPalette.muted)
                    Spacer()
                    Button("重试") { Task { await studio.updateRunSettings() } }
                        .buttonStyle(QuietButton())
                }
            } else if studio.runSettings == nil {
                Text(studio.loadingRunSettings ? "正在读取 Hermes 设置…" : "当前 Hermes 会话未提供可调整的设置。")
                    .foregroundStyle(StudioPalette.muted)
            }
        }
        .font(.system(size: 12))
        .padding(14)
        .frame(width: 330)
        .background(StudioPalette.sidebar)
        .foregroundStyle(StudioPalette.ink)
        .task { await studio.updateRunSettings() }
    }

    private func approvalPicker(_ selection: HermesRunSettings.Selection) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("编辑权限").foregroundStyle(StudioPalette.muted)
            ForEach(selection.choices) { choice in
                let selected = choice.id == selection.value
                Button {
                    choose(.editApproval, choice.id, current: selection.value)
                } label: {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(approvalTitle(choice.id, fallback: choice.name))
                                .fontWeight(.medium)
                            if let description = approvalDescription(choice.id) {
                                Text(description)
                                    .font(.system(size: 11))
                                    .foregroundStyle(StudioPalette.muted)
                            }
                        }
                        Spacer(minLength: 4)
                        if selected { Image(systemName: "checkmark") }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
                .buttonStyle(StudioRowButton(selected: selected))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .disabled(studio.loadingRunSettings)
    }

    private func modelPicker(_ selection: HermesRunSettings.Selection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("模型").foregroundStyle(StudioPalette.muted)
            Button {
                choosingModel.toggle()
                query = ""
            } label: {
                HStack {
                    Text(selection.name).lineLimit(1)
                    Spacer()
                    Image(systemName: choosingModel ? "chevron.up" : "chevron.down")
                }
                .padding(.horizontal, 8)
                .frame(height: 30)
                .background(StudioPalette.raised, in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("选择模型")
            .accessibilityValue(selection.name)
            if choosingModel {
                TextField("搜索模型", text: $query)
                    .textFieldStyle(.roundedBorder)
                let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
                let matches = selection.choices.filter {
                    search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)
                        || $0.id.localizedCaseInsensitiveContains(search)
                }
                if matches.isEmpty {
                    Text("没有匹配的模型").foregroundStyle(StudioPalette.muted)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(matches) { choice in
                                Button {
                                    choosingModel = false
                                    choose(.model, choice.id, current: selection.value)
                                } label: {
                                    HStack {
                                        Text(choice.name).lineLimit(1)
                                        Spacer()
                                        if choice.id == selection.value { Image(systemName: "checkmark") }
                                    }
                                    .padding(.horizontal, 8)
                                    .frame(height: 28)
                                }
                                .buttonStyle(StudioRowButton(selected: choice.id == selection.value))
                                .accessibilityAddTraits(choice.id == selection.value ? .isSelected : [])
                            }
                        }
                    }
                    .frame(height: CGFloat(min(matches.count, 6)) * 30)
                }
            }
        }
        .disabled(studio.loadingRunSettings)
    }

    private func effortPicker(_ selection: HermesRunSettings.Selection) -> some View {
        HStack {
            Text("推理强度").foregroundStyle(StudioPalette.muted)
            Spacer()
            Menu {
                ForEach(selection.choices) { choice in
                    Button {
                        choose(.effort, choice.id, current: selection.value)
                    } label: {
                        if choice.id == selection.value {
                            Label(effortLabel(choice.id), systemImage: "checkmark")
                        } else {
                            Text(effortLabel(choice.id))
                        }
                    }
                }
            } label: {
                Text(effortLabel(selection.value))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("选择推理强度")
            .accessibilityValue(effortLabel(selection.value))
        }
        .disabled(studio.loadingRunSettings)
    }

    private func choose(_ field: HermesRunSettings.Field, _ value: String, current: String) {
        guard current != value else { return }
        Task { await studio.updateRunSettings(field: field, value: value) }
    }
}

private func approvalTitle(_ value: String, fallback: String) -> String {
    switch value {
    case "ask", "default": "手动"
    case "workspace_session", "accept_edits": "自动"
    case "session", "dont_ask": "编辑免审批"
    default: fallback
    }
}

private func approvalDescription(_ value: String) -> String? {
    switch value {
    case "ask", "default": "每次文件编辑都询问"
    case "workspace_session", "accept_edits": "自动允许工作区和临时目录的普通编辑"
    case "session", "dont_ask": "自动允许本对话的普通编辑，敏感路径仍会询问"
    default: nil
    }
}

private func effortLabel(_ value: String) -> String {
    switch value {
    case "default": "默认"
    case "none": "关闭"
    case "minimal": "极低"
    case "low": "低"
    case "medium": "中"
    case "high": "高"
    case "xhigh": "很高"
    case "max": "最高"
    default: value
    }
}
