import AppKit
import StudioCore
import SwiftUI
import UniformTypeIdentifiers

struct RoleEditor: View {
    private enum Mode: String, CaseIterable {
        case smart = "智能创建"
        case manual = "手动填写"
    }

    @ObservedObject var studio: StudioModel
    let role: Role?
    @Environment(\.dismiss) private var dismiss
    @State private var mode = Mode.smart
    @State private var template: RoleTemplate
    @State private var name: String
    @State private var summary: String
    @State private var instructions = ""
    @State private var originalInstructions: String?
    @State private var showInstructions = false
    @State private var libraryGroup: String
    @State private var inheritSkills: Bool
    @State private var selectedSkills: Set<String>
    @State private var avatar: RoleAvatar?
    @State private var pendingAvatar: ImagePayload?
    @State private var choosingImage = false
    @State private var loadingImage = false
    @State private var showSkillList = false
    @State private var showAIUpdate = false
    @State private var showAnimalPortraits = false
    @State private var matchAvatar: Bool
    @State private var referenceLibrary = true
    @State private var selectedReferences: Set<UUID> = []
    @State private var showReferences = false
    @State private var requirement = ""
    @State private var generating = false
    @State private var generated = false
    @State private var designNotes: [String] = []
    @State private var generation: Task<Void, Never>?
    @State private var error: String?

    init(studio: StudioModel, role: Role?) {
        self.studio = studio
        self.role = role
        _template = State(initialValue: role?.template ?? .blank)
        _name = State(initialValue: role?.name ?? "")
        _summary = State(initialValue: role?.summary ?? "")
        _libraryGroup = State(initialValue: role?.libraryGroup ?? "")
        _inheritSkills = State(initialValue: role?.skillIDs == nil)
        _selectedSkills = State(initialValue: role?.skillIDs ?? [])
        _avatar = State(initialValue: role?.avatar)
        switch role?.avatar {
        case .custom, .symbol: _matchAvatar = State(initialValue: false)
        default: _matchAvatar = State(initialValue: true)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(role == nil ? "创建角色" : "编辑角色")
                    .font(.system(size: 21, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if role == nil {
                    Picker("创建方式", selection: $mode) {
                        ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 196)
                    .disabled(generating)
                } else {
                    Button(showAIUpdate ? "收起 AI 更新" : "AI 更新资料", systemImage: "sparkles") {
                        showAIUpdate.toggle()
                    }
                    .buttonStyle(QuietButton())
                    .disabled(generating)
                }
            }
            .padding(.horizontal, 22)
            .frame(height: 61)
            Divider().overlay(StudioPalette.line)
            HStack(spacing: 0) {
                avatarColumn
                    .frame(width: 187)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .background(StudioPalette.sidebar)
                    .disabled(generating)
                Rectangle().fill(StudioPalette.line).frame(width: 1)
                ScrollViewReader { scroll in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 15) {
                            if role == nil ? mode == .smart : showAIUpdate {
                                smartDraft {
                                    showInstructions = true
                                    scroll.scrollTo("role-instructions", anchor: .center)
                                }
                            }
                            Group {
                                FormField("角色名称", placeholder: "例如：会议整理助手", text: $name)
                                FormField("角色简介", placeholder: "用一句话介绍这个角色（选填）", text: $summary, multiline: true)
                                libraryGroupField
                                if role == nil { instructionsField.id("role-instructions") }
                                else if originalInstructions != nil {
                                    DisclosureGroup("角色指令", isExpanded: $showInstructions) {
                                        instructionsField.padding(.top, 8)
                                    }
                                    .font(.system(size: 12, weight: .semibold))
                                    .id("role-instructions")
                                }
                                skillPicker
                            }
                            .disabled(generating)
                        }
                        .padding(18)
                    }
                }
            }
            Divider().overlay(StudioPalette.line)
            VStack(alignment: .leading, spacing: 6) {
                if let error { Text(error).font(.system(size: 12)).foregroundStyle(StudioPalette.accent) }
                EditActions(primary: role == nil ? "创建角色" : "保存",
                    disabled: generating || loadingImage || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    onSave: save)
            }
            .padding(.horizontal, 22).padding(.vertical, 13)
        }
        .frame(width: 710, height: 565)
        .foregroundStyle(StudioPalette.ink)
        .background(.regularMaterial)
        .fileImporter(isPresented: $choosingImage, allowedContentTypes: [.image], onCompletion: loadPortrait)
        .onAppear(perform: loadInstructions)
        .onDisappear { generation?.cancel() }
    }

    private var effectiveAvatar: RoleAvatar? {
        avatar ?? RoleIllustration(template: template).map(RoleAvatar.illustration)
    }

    private var instructionsField: some View {
        VStack(alignment: .leading, spacing: 6) {
            if role == nil { Text("角色指令").font(.system(size: 12, weight: .semibold)) }
            TextEditor(text: $instructions)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(7)
                .frame(height: 170)
                .background(StudioPalette.sidebar, in: RoundedRectangle(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(StudioPalette.line).allowsHitTesting(false) }
                .accessibilityLabel("角色指令")
        }
    }

    private var libraryGroupField: some View {
        let groups = studio.libraryGroups
        return VStack(alignment: .leading, spacing: 6) {
            Text("角色分组").font(.system(size: 12, weight: .semibold))
            HStack(spacing: 7) {
                TextField("输入分组名称，留空为未分组", text: $libraryGroup)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("角色分组")
                if !groups.isEmpty {
                    Menu("选择分组") {
                        Button("未分组") { libraryGroup = "" }
                        Divider()
                        ForEach(groups, id: \.self) { group in Button(group) { libraryGroup = group } }
                    }
                    .fixedSize()
                }
            }
        }
    }

    private var portraitImage: NSImage? {
        if let pendingAvatar { return NSImage(data: pendingAvatar.data) }
        switch effectiveAvatar {
        case .illustration(let item): return RolePortrait.illustration(item)
        case .custom(let file):
            return role.flatMap { NSImage(contentsOf: studio.store.imageURL(file, for: $0.id)) }
        case .symbol, nil: return nil
        }
    }

    private var avatarColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 13) {
                VStack(alignment: .center, spacing: 8) {
                    RolePortrait(image: portraitImage, symbol: role.map(roleSymbol) ?? template.symbol, size: 68)
                    Text(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "角色头像" : name)
                        .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                peoplePortraitPicker
                DisclosureGroup("动物插画", isExpanded: $showAnimalPortraits) {
                    portraitRow(RoleIllustration.animals)
                        .padding(.top, 6)
                }
                .font(.system(size: 11))
                .foregroundStyle(StudioPalette.muted)
                HStack(spacing: 7) {
                    Button(loadingImage ? "读取中" : "上传图片", systemImage: "photo") { choosingImage = true }
                        .buttonStyle(QuietButton()).disabled(loadingImage)
                    Button("使用系统图标", systemImage: "sparkle") { chooseAvatar(.symbol) }
                        .labelStyle(.iconOnly).buttonStyle(QuietButton())
                        .help("使用系统图标")
                }
                if role == nil && mode == .manual {
                    Divider().overlay(StudioPalette.line)
                    Text("从模板开始").font(.system(size: 11, weight: .semibold)).foregroundStyle(StudioPalette.muted)
                    ForEach(RoleTemplate.allCases) { choice in
                        Button {
                            choose(choice)
                        } label: {
                            Label(choice.name, systemImage: choice.symbol)
                                .font(.system(size: 12, weight: .medium))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8)
                                .frame(height: 27)
                                .background(template == choice ? StudioPalette.selected : .clear, in: RoundedRectangle(cornerRadius: 5))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(template == choice ? .isSelected : [])
                    }
                }
            }
            .padding(15)
        }
    }

    private var peoplePortraitPicker: some View {
        ScrollViewReader { scroll in
            ScrollView(.horizontal) {
                portraitRow(RoleIllustration.people)
                    .padding(.bottom, 8)
            }
            .scrollIndicators(.visible)
            .scrollIndicatorsFlash(onAppear: true)
            .accessibilityLabel("人物头像")
            .onChange(of: effectiveAvatar, initial: true) { _, selection in
                if case .illustration(let item) = selection,
                    RoleIllustration.people.contains(item) {
                    scroll.scrollTo(item)
                }
            }
        }
    }

    private func portraitRow(_ items: [RoleIllustration]) -> some View {
        HStack(spacing: 4) {
            ForEach(items) { item in
                let selected = pendingAvatar == nil && effectiveAvatar == .illustration(item)
                Button { chooseAvatar(.illustration(item)) } label: {
                    RolePortrait(image: RolePortrait.illustration(item), symbol: "person", size: 32)
                        .padding(2)
                        .background(selected ? StudioPalette.accent : .clear, in: RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
                .id(item)
                .help(item.label)
                .accessibilityLabel("\(item.label)插画头像")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func smartDraft(reviewInstructions: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(role == nil ? "描述你需要的角色" : "你想怎么更新？", systemImage: "sparkles")
                .font(.system(size: 13, weight: .semibold))
            TextField(role == nil ? "例如：做一个善于陪我复盘的助手，和现有角色有明显区别" : "例如：更关心我，但少用甜腻称呼。保留原来的工作职责",
                text: $requirement, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.plain)
                .padding(8)
                .background(StudioPalette.background.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
                .accessibilityLabel(role == nil ? "角色用途" : "资料更新要求")
                .disabled(generating)
            HStack(spacing: 8) {
                Toggle("自动匹配头像", isOn: $matchAvatar)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                    .disabled(generating)
                Spacer()
                if generated {
                    Label("草稿已填入，可继续编辑", systemImage: "checkmark.circle")
                        .font(.system(size: 11)).foregroundStyle(StudioPalette.accent)
                }
                if generating {
                    ProgressView().controlSize(.small).accessibilityLabel("正在生成")
                }
                Button(role == nil ? "生成草稿" : "生成更新草稿", action: generate)
                    .buttonStyle(QuietButton())
                    .disabled(generating || loadingImage || requirement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if !referenceCandidates.isEmpty { referenceControls }
            if !designNotes.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("设定分析").fontWeight(.semibold)
                    ForEach(Array(designNotes.enumerated()), id: \.offset) { _, note in
                        Text(note).foregroundStyle(StudioPalette.muted).textSelection(.enabled)
                    }
                }
                .font(.system(size: 11))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if generated && (role == nil || instructions != originalInstructions) {
                Button("查看角色指令", action: reviewInstructions).buttonStyle(QuietButton())
            }
        }
        .padding(11)
        .background(StudioPalette.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
    }

    private var referenceCandidates: [Role] { studio.roles.filter { $0.id != role?.id } }

    private var referenceControls: some View {
        HStack(spacing: 8) {
            Toggle("参考角色库", isOn: $referenceLibrary)
                .toggleStyle(.checkbox)
                .help("使用现有助手的名称、简介和分组，分析定位与分工")
            Spacer()
            Button(selectedReferences.isEmpty ? "选择深入参考" : "深入参考（\(selectedReferences.count)）") { showReferences.toggle() }
                .buttonStyle(QuietButton())
                .disabled(!referenceLibrary)
                .popover(isPresented: $showReferences, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("最多选 3 位，额外参考各自的角色指令片段。")
                            .foregroundStyle(StudioPalette.muted)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(referenceCandidates) { candidate in
                                    Toggle(candidate.name, isOn: Binding(get: { selectedReferences.contains(candidate.id) },
                                        set: { selected in
                                            if selected { selectedReferences.insert(candidate.id) }
                                            else { selectedReferences.remove(candidate.id) }
                                        }))
                                        .toggleStyle(.checkbox)
                                        .disabled(selectedReferences.count >= 3 && !selectedReferences.contains(candidate.id))
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: CGFloat(min(referenceCandidates.count, 7)) * 24)
                        Button("完成") { showReferences = false }.buttonStyle(QuietButton())
                    }
                    .padding(12).frame(width: 300)
                }
        }
        .font(.system(size: 11))
        .disabled(generating)
    }

    private var skillPicker: some View {
        HStack(spacing: 8) {
            Text("角色技能").font(.system(size: 12, weight: .semibold))
            Spacer()
            Picker("角色技能", selection: $inheritSkills) {
                Text("继承本机技能").tag(true)
                Text("仅启用所选").tag(false)
            }
            .labelsHidden()
            .fixedSize()
            if !inheritSkills {
                Button("选择技能（\(selectedSkills.count)）") { showSkillList = true }
                    .buttonStyle(QuietButton())
                    .popover(isPresented: $showSkillList, arrowEdge: .bottom) {
                        RoleSkillChecklist(skills: studio.skills, selected: $selectedSkills)
                    }
            }
        }
    }

    private func chooseAvatar(_ selection: RoleAvatar) {
        pendingAvatar = nil
        avatar = selection
        matchAvatar = false
    }

    private func loadPortrait(_ selection: Result<URL, Error>) {
        switch selection {
        case .failure(let error): self.error = error.localizedDescription
        case .success(let url):
            loadingImage = true
            error = nil
            Task {
                defer { loadingImage = false }
                let result = await Task.detached { Result { try ImagePayload.load(url) } }.value
                do {
                    pendingAvatar = try result.get()
                    matchAvatar = false
                }
                catch { self.error = error.localizedDescription }
            }
        }
    }

    private func generate() {
        let request = requirement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !generating, !loadingImage, !request.isEmpty else { return }
        let shouldMatchAvatar = matchAvatar
        let usesLibrary = referenceLibrary
        let references = selectedReferences
        let group = try? studio.libraryGroup(named: libraryGroup)
        if role != nil && originalInstructions == nil {
            loadInstructions()
            guard originalInstructions != nil else { return }
        }
        generating = true
        generated = false
        designNotes = []
        error = nil
        generation = Task {
            defer { generating = false }
            do {
                if var profile = role {
                    profile.name = name
                    profile.summary = summary
                    profile.skillIDs = inheritSkills ? nil : selectedSkills
                    profile.avatar = pendingAvatar.map { .custom($0.image) } ?? effectiveAvatar
                    profile.libraryGroup = group
                    let update = try await studio.suggestRoleUpdate(request, for: profile, matchAvatar: shouldMatchAvatar,
                        currentInstructions: instructions, referenceLibrary: usesLibrary, selectedReferences: references)
                    try Task.checkCancellation()
                    if let suggestedName = update.name { name = suggestedName }
                    if let suggestedSummary = update.summary { summary = suggestedSummary }
                    if let suggestedInstructions = update.instructions {
                        instructions = suggestedInstructions
                        showInstructions = true
                    }
                    designNotes = update.designNotes ?? []
                    if update.inheritSkills == true {
                        inheritSkills = true
                    } else if let skillIDs = update.skillIDs {
                        selectedSkills = skillIDs
                        inheritSkills = false
                    }
                    applySuggestedAvatar(update.avatar)
                } else {
                    let draft = try await studio.suggestRole(request, matchAvatar: shouldMatchAvatar, referenceLibrary: usesLibrary,
                        group: group, selectedReferences: references)
                    try Task.checkCancellation()
                    if avatar == nil, draft.avatar == nil { avatar = effectiveAvatar }
                    template = .blank
                    name = draft.name
                    summary = draft.summary
                    instructions = draft.instructions
                    designNotes = draft.designNotes ?? []
                    selectedSkills = draft.skillIDs
                    inheritSkills = false
                    applySuggestedAvatar(draft.avatar)
                }
                generated = true
            } catch is CancellationError {
                return
            } catch { self.error = error.localizedDescription }
        }
    }

    private func loadInstructions() {
        guard let role, originalInstructions == nil else { return }
        do {
            let contents = try studio.store.file(.soul, for: role.id)
            originalInstructions = contents
            instructions = contents
        } catch { self.error = error.localizedDescription }
    }

    private func applySuggestedAvatar(_ suggestion: RoleIllustration?) {
        guard let suggestion else { return }
        pendingAvatar = nil
        avatar = .illustration(suggestion)
        if RoleIllustration.animals.contains(suggestion) { showAnimalPortraits = true }
    }

    private func choose(_ choice: RoleTemplate) {
        template = choice
        if choice != .blank {
            name = choice.name
            summary = choice.description
            instructions = choice.instructions
        }
    }

    private func save() {
        let displayName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !displayName.isEmpty, displayName.count <= 40, detail.count <= 120 else {
            error = "名称最多 40 字，简介最多 120 字。"
            return
        }
        do {
            let group = try studio.libraryGroup(named: libraryGroup)
            if var role {
                let changedLibraryGroup = role.libraryGroup != group
                let editedInstructions = originalInstructions.flatMap { instructions == $0 ? nil : instructions }
                if editedInstructions != nil, try studio.store.file(.soul, for: role.id) != originalInstructions {
                    throw StudioError.message("角色指令已在其他地方更新。请重新打开编辑页面后再应用草稿。")
                }
                role.name = displayName
                role.summary = detail
                role.libraryGroup = group
                role.skillIDs = inheritSkills ? nil : selectedSkills
                if let pendingAvatar {
                    role.avatar = .custom(try studio.store.saveImage(pendingAvatar, for: role.id))
                } else {
                    role.avatar = avatar
                }
                try studio.updateRole(role, instructions: editedInstructions, changeLibraryGroup: changedLibraryGroup)
            } else {
                try studio.createRole(name: displayName, summary: detail, instructions: instructions, template: template,
                    skillIDs: inheritSkills ? nil : selectedSkills, avatar: avatar, avatarImage: pendingAvatar, libraryGroup: group)
            }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct RoleSkillChecklist: View {
    let skills: [HermesSkill]
    @Binding var selected: Set<String>
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("角色技能").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("完成") { dismiss() }.buttonStyle(QuietButton())
            }
            TextField("搜索技能", text: $query)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("搜索可选角色技能")
            let filtered = HermesSkill.matching(query, in: skills)
            if filtered.isEmpty {
                Text(skills.isEmpty ? "未找到本机技能。" : "没有匹配的技能。")
                    .font(.system(size: 12)).foregroundStyle(StudioPalette.muted)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(filtered) { skill in
                        Toggle(isOn: Binding(get: { selected.contains(skill.id) }, set: { enabled in
                            if enabled { selected.insert(skill.id) } else { selected.remove(skill.id) }
                        })) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(skill.name).font(.system(size: 12))
                                if !skill.summary.isEmpty {
                                    Text(skill.summary).font(.system(size: 11)).lineLimit(1)
                                        .foregroundStyle(StudioPalette.muted)
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 355, height: 335)
    }
}

struct MemoryEditor: View {
    @ObservedObject var studio: StudioModel
    let role: Role
    let file: RoleFile
    @Environment(\.dismiss) private var dismiss
    @State private var contents: String
    @State private var original: String
    @State private var error: String?

    init(studio: StudioModel, role: Role, file: RoleFile) {
        self.studio = studio
        self.role = role
        self.file = file
        let text = (try? studio.store.file(file, for: role.id)) ?? ""
        _contents = State(initialValue: text)
        _original = State(initialValue: text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("\(role.name) · \(file.label)")
                .font(.system(size: 20, weight: .semibold))
            Text(file.hint)
                .font(.system(size: 12))
                .foregroundStyle(StudioPalette.muted)
            TextEditor(text: $contents)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(height: 260)
                .background(StudioPalette.raised, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel(file.label)
            if let error {
                Text(error).font(.system(size: 12)).foregroundStyle(StudioPalette.accent)
            }
            EditActions(primary: "保存", disabled: contents == original) {
                do {
                    let current = try studio.store.file(file, for: role.id)
                    guard current == original else {
                        error = "文件已有新内容。请重新打开编辑器查看最新版本。"
                        return
                    }
                    try studio.save(file, text: contents, role: role)
                    dismiss()
                } catch {
                    self.error = error.localizedDescription
                }
            }
        }
        .padding(24)
        .frame(width: 560)
        .foregroundStyle(StudioPalette.ink)
        .background(.regularMaterial)
    }
}

private struct FormField: View {
    let title: String
    let placeholder: String
    let multiline: Bool
    @Binding var text: String

    init(_ title: String, placeholder: String, text: Binding<String>, multiline: Bool = false) {
        self.title = title
        self.placeholder = placeholder
        self.multiline = multiline
        _text = text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 12, weight: .semibold))
            TextField(placeholder, text: $text, axis: multiline ? .vertical : .horizontal)
                .lineLimit(multiline ? 2...3 : 1...1)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(10)
                .background(StudioPalette.sidebar, in: RoundedRectangle(cornerRadius: 7))
                .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(StudioPalette.line).allowsHitTesting(false) }
                .accessibilityLabel(title)
        }
    }
}

private struct EditActions: View {
    let primary: String
    let disabled: Bool
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack {
            Spacer()
            Button("取消") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(QuietButton())
            Button(action: onSave) {
                Text(primary)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(StudioPalette.background)
                    .padding(.horizontal, 14)
                    .frame(height: 30)
                    .background(StudioPalette.ink, in: RoundedRectangle(cornerRadius: 7))
                    .opacity(disabled ? 0.42 : 1)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .disabled(disabled)
        }
    }
}
