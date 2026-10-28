import MoireKit
import SwiftUI

/// Rules for differences that do not matter, per kind of file, kept in UserDefaults.
@Observable
final class RulesStore {
    static let shared = RulesStore()

    /// The key for rules that apply to every file without rules of its own.
    static let everyFile = "*"

    private(set) var rules: [String: TextRules]
    private let key = "textRules"

    init() {
        if let data = UserDefaults.standard.data(forKey: key), let stored = try? JSONDecoder().decode([String: TextRules].self, from: data) {
            rules = stored
        } else {
            rules = [:]
        }
    }

    /// The rules for a file: its extension's own rules, otherwise the rules for every file.
    func rules(forFileNamed name: String?) -> TextRules {
        let ext = name.map { ($0 as NSString).pathExtension.lowercased() } ?? ""
        return rules[ext] ?? rules[Self.everyFile] ?? TextRules()
    }

    func set(_ value: TextRules?, for fileType: String) {
        let key = fileType.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        guard !key.isEmpty else { return }
        rules[key] = value
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(rules) else { return }
        UserDefaults.standard.set(data, forKey: key)
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// Posted after the rules changed, so open comparisons compare again.
    static let didChange = Notification.Name("io.github.sherinbloemendaal.moire.rulesChanged")
}

struct RulesSettingsView: View {
    @State private var store = RulesStore.shared
    @State private var selection: String? = RulesStore.everyFile
    @State private var newType = ""

    private var types: [String] {
        let custom = store.rules.keys.filter { $0 != RulesStore.everyFile }.sorted()
        return [RulesStore.everyFile] + custom
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(types, id: \.self) { type in
                        Text(type == RulesStore.everyFile ? "Every file" : ".\(type)").tag(type)
                    }
                }
                HStack(spacing: 6) {
                    TextField("Extension, e.g. swift", text: $newType)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(add)
                    Button(action: add) { Image(systemName: "plus") }
                        .disabled(newType.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button {
                        if let selection, selection != RulesStore.everyFile {
                            store.set(nil, for: selection)
                            self.selection = RulesStore.everyFile
                        }
                    } label: { Image(systemName: "minus") }
                        .disabled(selection == nil || selection == RulesStore.everyFile)
                }
                .padding(8)
            }
            .frame(width: 200)
            Divider()
            if let selection {
                RuleEditor(type: selection, store: store)
                    .id(selection)
            } else {
                Text("Choose a kind of file").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 640, height: 400)
    }

    private func add() {
        let type = newType.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        guard !type.isEmpty else { return }
        if store.rules[type] == nil { store.set(TextRules(), for: type) }
        selection = type
        newType = ""
    }
}

private struct RuleEditor: View {
    let type: String
    let store: RulesStore
    @State private var rules = TextRules()
    @State private var patterns = ""

    var body: some View {
        Form {
            Section {
                Toggle("Ignore comments", isOn: $rules.ignoreComments)
                if type != RulesStore.everyFile, CommentSyntax.forFile(named: "file.\(type)") == nil, rules.ignoreComments {
                    Label("Moire does not know the comment syntax of .\(type) files.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                Toggle("Ignore blank lines", isOn: $rules.ignoreBlankLines)
            } footer: {
                Text("Comment-only lines and lines left blank do not count as changes; changes inside comments are not marked.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Ignore text matching (one regular expression per line)") {
                TextEditor(text: $patterns)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 110)
                ForEach(rules.invalidPatterns, id: \.pattern) { invalid in
                    Label("\(invalid.pattern): \(invalid.reason)", systemImage: "xmark.octagon")
                        .foregroundStyle(Theme.removed)
                        .font(.caption)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            rules = store.rules[type] ?? TextRules()
            patterns = rules.ignorePatterns.joined(separator: "\n")
        }
        .onChange(of: patterns) { _, text in
            rules.ignorePatterns = text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
        }
        .onChange(of: rules) { _, value in
            store.set(value, for: type)
        }
    }
}
