import AppKit
import Common
import SwiftUI

/// The sheet that adds or changes one binding: its mode, its key, and the commands it runs.
struct ShortcutEditorView: View {
    let target: ShortcutEditorTarget
    let onDone: () -> Void

    @StateObject private var recorder = ShortcutRecorder()
    @State private var draft: ShortcutDraft
    /// `newModeTag` while the name of a new mode is being typed into `draft.mode`
    @State private var modeChoice: String
    @State private var selectedCommand = 0
    @State private var search = ""
    @State private var suggestions: [CommandSuggestion] = []
    @State private var saveError: String?
    @State private var isSaving = false
    /// Problems show once the user has tried to save, not while the first field is still empty
    @State private var showsProblems = false

    private static let newModeTag = "\u{0}new"

    init(target: ShortcutEditorTarget, onDone: @escaping () -> Void) {
        self.target = target
        self.onDone = onDone
        _draft = State(initialValue: target.draft)
        _modeChoice = State(initialValue: target.draft.mode)
    }

    private var modes: [String] { [mainModeId] + config.modes.keys.filter { $0 != mainModeId }.sorted() }
    private var problems: ShortcutDraftProblems {
        shortcutDraftProblems(draft, existingModes: Set(config.modes.keys), keyMapping: config.keyMapping.resolve())
    }

    var body: some View {
        let problems = problems
        VStack(alignment: .leading, spacing: 0) {
            Text(target.original == nil ? "New Shortcut" : "Edit Shortcut")
                .font(.headline)
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 14)
            VStack(alignment: .leading, spacing: 14) {
                field("Mode", problem: problems.mode) { modeField }
                field("Shortcut", problem: problems.binding) { bindingField }
                field("Runs", problem: nil) { commandsField(problems) }
            }
            .padding(.horizontal, 20)
            Divider().padding(.top, 14)
            suggestionList
            Divider()
            footer(problems)
        }
        .frame(width: 560, height: 620)
        .onAppear { loadSuggestions() }
        // The window closing doesn't run this. The recorder watches for that itself
        .onDisappear { recorder.stop() }
    }

    // MARK: - Fields

    private func field(_ title: String, problem: String?, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .trailing)
            VStack(alignment: .leading, spacing: 4) {
                content()
                if showsProblems, let problem { problemText(problem) }
            }
        }
    }

    private func problemText(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var modeField: some View {
        HStack(spacing: 8) {
            Picker("Mode", selection: $modeChoice) {
                ForEach(modes, id: \.self) { mode in
                    Text(mode == mainModeId ? "Global (main)" : mode).tag(mode)
                }
                Divider()
                Text("New Mode…").tag(Self.newModeTag)
            }
            .labelsHidden()
            .fixedSize()
            .onChange(of: modeChoice) { draft.mode = modeChoice == Self.newModeTag ? "" : modeChoice }
            if modeChoice == Self.newModeTag {
                TextField("Mode name", text: $draft.mode)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
            }
        }
    }

    private var bindingField: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                TextField("ctrl-option-k", text: $draft.binding)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 240)
                    .disabled(recorder.isRecording)
                Button(recorder.isRecording ? "Press the keys…" : "Record") {
                    recorder.onRecord = { draft.binding = $0 }
                    recorder.toggle()
                }
                if !draft.address.binding.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(keyTokens(fromNotation: draft.address.binding)) { token in
                            Text(token.label)
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        }
                    }
                }
            }
            if recorder.isRecording {
                Text("Airlock's shortcuts are off while it listens. Esc cancels. To bind Esc itself, type esc.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let replaced = shortcutDraftReplaces(draft, original: target.original) {
                Text("This key already runs “\(replaced)” in this mode. Saving replaces it.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func commandsField(_ problems: ShortcutDraftProblems) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(draft.commands.indices, id: \.self) { index in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        TextField("Command, such as focus left", text: $draft.commands[index], axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(1 ... 6)
                            .onTapGesture { selectedCommand = index }
                            .overlay(alignment: .leading) {
                                // Marks the row a picked suggestion goes into, when there are several
                                if draft.commands.count > 1, selectedCommand == index {
                                    Capsule().fill(Color.accentColor).frame(width: 3).padding(.vertical, 3).offset(x: -6)
                                }
                            }
                        if draft.commands.count > 1 {
                            Button {
                                draft.commands.remove(at: index)
                                selectedCommand = min(selectedCommand, draft.commands.count - 1)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("Remove this command")
                        }
                    }
                    if showsProblems || !draft.commands[index].isEmpty, let problem = problems.commands[index] { problemText(problem) }
                }
            }
            Button {
                draft.commands.append("")
                selectedCommand = draft.commands.count - 1
            } label: {
                Label("Add Another Command", systemImage: "plus")
            }
            .buttonStyle(.link)
            .font(.callout)
        }
    }

    // MARK: - Suggestions

    private var suggestionList: some View {
        let query = search.trimmingCharacters(in: .whitespaces)
        let visible = query.isEmpty ? suggestions : suggestions.filter { $0.matches(query) }
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find a command to run…", text: $search).textFieldStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 9)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(visible) { suggestion in
                        Button {
                            pick(suggestion)
                        } label: {
                            HStack(spacing: 12) {
                                Text(suggestion.title)
                                Spacer(minLength: 12)
                                Text(suggestion.command)
                                    .font(.system(.callout, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if visible.isEmpty {
                        Text("No command matches “\(query)”. Any Airlock command can be typed above.")
                            .foregroundStyle(.secondary)
                            .padding(20)
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func pick(_ suggestion: CommandSuggestion) {
        let index = draft.commands.indices.contains(selectedCommand) ? selectedCommand : draft.commands.count - 1
        draft.commands[index] = suggestion.command
    }

    private func loadSuggestions() {
        suggestions = currentCommandSuggestions(apps: [])
        Task {
            let apps = await discoverInstalledAppInfo().map(\.name).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            suggestions = currentCommandSuggestions(apps: apps)
        }
    }

    // MARK: - Saving

    private func footer(_ problems: ShortcutDraftProblems) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let saveError { problemText(saveError) }
            HStack {
                Spacer()
                Button("Cancel") { onDone() }
                    .keyboardShortcut(.cancelAction)
                    // Esc belongs to the recorder while it listens
                    .disabled(recorder.isRecording)
                Button("Save") { save(problems) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving || recorder.isRecording)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func save(_ problems: ShortcutDraftProblems) {
        showsProblems = true
        saveError = nil
        guard problems.isEmpty else { return }
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                try saveShortcutDraft(draft, original: target.original, originalDraft: target.draft)
                try await reloadSettingsConfigAfterWrite()
                onDone()
            } catch is CancellationError {
                // A newer operation superseded the reload. The file is written, so the list will follow
                onDone()
            } catch {
                logAppError(error, operation: "Saving a keyboard shortcut")
                saveError = error.localizedDescription
            }
        }
    }
}

/// Writes the draft to the config file. A draft that changes nothing writes nothing, so opening a
/// binding and pressing Save can't reformat it.
@MainActor
func saveShortcutDraft(_ draft: ShortcutDraft, original: BindingAddress?, originalDraft: ShortcutDraft) throws {
    if original != nil, draft.address == originalDraft.address, draft.writtenCommands == originalDraft.writtenCommands { return }
    try setBinding(draft.address, commands: draft.writtenCommands, replacing: original)
}
