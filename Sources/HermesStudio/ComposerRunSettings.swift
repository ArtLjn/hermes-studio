import StudioCore
import SwiftUI

struct ComposerRunSettingsButton: View {
    @ObservedObject var studio: StudioModel
    @State private var presented = false

    var body: some View {
        Button { presented.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: studio.composerApprovalMode == .fullAccess ? "exclamationmark.shield" : "checkmark.shield")
                Text(studio.composerApprovalMode.map(approvalTitle) ?? "权限")
                    .fixedSize()
                Text("·").accessibilityHidden(true)
                Text(studio.composerModelName)
                    .lineLimit(1)
                if let effort = studio.composerEffort {
                    Text("·").accessibilityHidden(true)
                    Text(effortLabel(effort)).fixedSize()
                }
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .padding(.horizontal, 6)
            .frame(height: 27)
        }
        .buttonStyle(StudioRowButton(selected: presented))
        .accessibilityLabel("运行设置")
        .accessibilityValue([
            studio.composerApprovalMode.map(approvalTitle),
            studio.composerModelName,
            studio.composerEffort.map(effortLabel)
        ].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "，"))
        .help(studio.isGeneratingHere ? "回复结束后可调整运行设置" : "设置当前对话的权限、模型与推理强度")
        .disabled(!studio.available || studio.isGeneratingHere)
        .popover(isPresented: $presented, arrowEdge: .bottom) {
            ComposerRunSettings(studio: studio)
        }
        .onChange(of: studio.runSettingsContext) { _, _ in presented = false }
    }
}

private struct ComposerRunSettings: View {
    @ObservedObject var studio: StudioModel
    @State private var choosingModel = false
    @State private var confirmingFullAccess = false
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("运行设置").font(.system(size: 14, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if studio.loadingRunSettings { ProgressView().controlSize(.small) }
            }
            Text("记住权限、模型和推理强度。模型和推理强度作为新对话默认值。")
                .font(.system(size: 11))
                .foregroundStyle(StudioPalette.muted)
            StudioRule()
            if let approval = studio.runSettings?.editApproval, !approval.choices.isEmpty {
                approvalPicker(approval)
                if studio.runSettings?.model != nil || studio.runSettings?.effort != nil { StudioRule() }
            } else if studio.runPreferences.managesTerminalApproval {
                approvalPicker(nil)
            }
            if studio.runPreferences.approval == .fullAccess {
                Toggle("群聊也使用完全访问", isOn: Binding(
                    get: { studio.runPreferences.enablesGroupFullAccess },
                    set: { studio.setGroupFullAccess($0) }))
                .toggleStyle(.switch).controlSize(.small)
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
                    Button("重试") { Task { await studio.updateRunSettings(includeModelChoices: choosingModel) } }
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

    private func approvalPicker(_ selection: HermesRunSettings.Selection?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("运行权限").foregroundStyle(StudioPalette.muted)
                Spacer(minLength: 6)
                Text(studio.project?.name ?? "角色工作区")
                    .font(.system(size: 11))
                    .foregroundStyle(StudioPalette.muted)
                    .lineLimit(1)
            }
            let modes = Set(selection?.choices.compactMap { HermesApprovalMode(nativeID: $0.id) } ?? [.manual, .workspace])
            ForEach(HermesApprovalMode.allCases.filter {
                modes.contains($0) || ($0 == .fullAccess &&
                    (modes.contains(.editWithoutApproval) || studio.composerApprovalMode == .fullAccess))
            }, id: \.self) { mode in
                let selected = mode == studio.composerApprovalMode
                Button {
                    if mode == .fullAccess && !selected {
                        confirmingFullAccess = true
                    } else {
                        confirmingFullAccess = false
                        Task { await studio.updateRunSettings(approval: mode) }
                    }
                } label: {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(approvalTitle(mode))
                                .fontWeight(.medium)
                            Text(approvalDescription(mode))
                                .font(.system(size: 11))
                                .foregroundStyle(StudioPalette.muted)
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
            if confirmingFullAccess {
                VStack(alignment: .leading, spacing: 8) {
                    Text("开启后，所有对话后续发送都会沿用完全访问，直到你切换权限。")
                        .font(.system(size: 11))
                        .foregroundStyle(StudioPalette.muted)
                    HStack {
                        Spacer()
                        Button("取消") { confirmingFullAccess = false }
                            .buttonStyle(QuietButton())
                        StudioPrimaryButton(title: "启用并记住", symbol: "checkmark") {
                            confirmingFullAccess = false
                            Task { await studio.updateRunSettings(approval: .fullAccess) }
                        }
                    }
                }
                .padding(8)
                .background(StudioPalette.raised, in: RoundedRectangle(cornerRadius: 6))
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
                if choosingModel { Task { await studio.updateRunSettings(includeModelChoices: true) } }
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
                if studio.loadingRunSettings {
                    Text("正在读取模型列表…").foregroundStyle(StudioPalette.muted)
                } else if matches.isEmpty && studio.runSettingsError == nil {
                    Text("没有匹配的模型").foregroundStyle(StudioPalette.muted)
                } else if !matches.isEmpty {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(matches) { choice in
                                Button {
                                    choosingModel = false
                                    choose(.model, choice.id)
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
                        choose(.effort, choice.id)
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

    private func choose(_ field: HermesRunSettings.Field, _ value: String) {
        Task { await studio.updateRunSettings(field: field, value: value) }
    }
}

private func approvalTitle(_ value: HermesApprovalMode) -> String {
    switch value {
    case .manual: "手动"
    case .workspace: "工作区自动"
    case .editWithoutApproval: "编辑免审批"
    case .fullAccess: "完全访问"
    }
}

private func approvalDescription(_ value: HermesApprovalMode) -> String {
    switch value {
    case .manual: "每次文件编辑都询问"
    case .workspace: "工作区和 Hermes 临时目录内的普通编辑自动放行"
    case .editWithoutApproval: "普通编辑自动放行，包括工作区外的文件"
    case .fullAccess: "普通编辑和终端命令免审批，敏感文件与系统权限仍受保护"
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
