import Foundation

public struct HermesRunSettings: Equatable, Sendable {
    public enum Field: String, Sendable {
        case model
        case effort = "reasoning_effort"
        case editApproval = "edit_approval_policy"
    }

    public struct Choice: Identifiable, Equatable, Sendable {
        public let id: String
        public let name: String
    }

    public struct Selection: Equatable, Sendable {
        public let value: String
        public let choices: [Choice]

        public var name: String { choices.first { $0.id == value }?.name ?? value }
    }

    public let model: Selection?
    public let effort: Selection?
    public let editApproval: Selection?
    let modelUsesLegacyMethod: Bool
    let editApprovalUsesLegacyMethod: Bool

    public subscript(_ field: Field) -> Selection? {
        switch field {
        case .model: model
        case .effort: effort
        case .editApproval: editApproval
        }
    }

    init?(response: [String: Any], previous: Self? = nil) {
        let selectors = response["configOptions"] as? [[String: Any]] ?? []
        let nativeModel = Self.selection(.model, from: selectors)
        let legacyModel: Selection? = (response["models"] as? [String: Any]).flatMap { models in
            guard let current = models["currentModelId"] as? String,
                let available = models["availableModels"] as? [[String: Any]] else { return nil }
            return Selection(value: current, choices: Self.choices(available, key: "modelId"))
        }
        let effort = Self.selection(.effort, from: selectors)
        let nativeApproval = Self.selection(.editApproval, from: selectors)
        let legacyApproval: Selection? = (response["modes"] as? [String: Any]).flatMap { modes in
            guard let current = modes["currentModeId"] as? String,
                let available = modes["availableModes"] as? [[String: Any]] else { return nil }
            return Selection(value: current, choices: Self.choices(available, key: "id"))
        }
        guard nativeModel != nil || legacyModel != nil || effort != nil || nativeApproval != nil || legacyApproval != nil else {
            return nil
        }
        model = nativeModel ?? legacyModel ?? previous?.model
        if let effort, !effort.choices.contains(where: { $0.id == "default" }),
            let defaultChoice = previous?.effort?.choices.first(where: { $0.id == "default" }) {
            self.effort = Selection(value: effort.value, choices: [defaultChoice] + effort.choices)
        } else {
            self.effort = effort ?? previous?.effort
        }
        modelUsesLegacyMethod = nativeModel == nil && (legacyModel != nil || previous?.modelUsesLegacyMethod == true)
        editApproval = nativeApproval ?? legacyApproval ?? previous?.editApproval
        editApprovalUsesLegacyMethod = nativeApproval == nil
            && (legacyApproval != nil || previous?.editApprovalUsesLegacyMethod == true)
    }

    private init(model: Selection?, effort: Selection?, editApproval: Selection?,
        modelUsesLegacyMethod: Bool, editApprovalUsesLegacyMethod: Bool) {
        self.model = model
        self.effort = effort
        self.editApproval = editApproval
        self.modelUsesLegacyMethod = modelUsesLegacyMethod
        self.editApprovalUsesLegacyMethod = editApprovalUsesLegacyMethod
    }

    func settingLegacyModel(_ id: String) -> Self {
        Self(model: model.map { Selection(value: id, choices: $0.choices) }, effort: effort, editApproval: editApproval,
            modelUsesLegacyMethod: true, editApprovalUsesLegacyMethod: editApprovalUsesLegacyMethod)
    }

    func settingLegacyEditApproval(_ id: String) -> Self {
        Self(model: model, effort: effort, editApproval: editApproval.map { Selection(value: id, choices: $0.choices) },
            modelUsesLegacyMethod: modelUsesLegacyMethod, editApprovalUsesLegacyMethod: true)
    }

    private static func selection(_ field: Field, from selectors: [[String: Any]]) -> Selection? {
        guard let selector = selectors.first(where: { $0["id"] as? String == field.rawValue }),
            let value = selector["currentValue"] as? String,
            let options = selector["options"] as? [[String: Any]] else { return nil }
        return Selection(value: value, choices: choices(options, key: "value"))
    }

    private static func choices(_ options: [[String: Any]], key: String) -> [Choice] {
        var seen = Set<String>()
        return options.flatMap { $0["options"] as? [[String: Any]] ?? [$0] }.compactMap { option in
            guard let id = option[key] as? String, !id.isEmpty, seen.insert(id).inserted else { return nil }
            return Choice(id: id, name: option["name"] as? String ?? id)
        }
    }
}

public struct HermesRunSession: Sendable {
    public let id: String
    public let settings: HermesRunSettings?
}
