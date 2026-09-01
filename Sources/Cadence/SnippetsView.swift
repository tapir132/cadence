import SwiftUI

struct SnippetsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var query = ""
    @State private var editor: SnippetEditorPresentation?
    @State private var deleteCandidate: TextSnippet?

    private var filteredSnippets: [TextSnippet] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return model.snippets }
        return model.snippets.filter {
            $0.trigger.localizedCaseInsensitiveContains(trimmedQuery)
                || $0.replacement.localizedCaseInsensitiveContains(trimmedQuery)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("SHORTCUTS")
                .font(.system(size: 10, weight: .bold))
                .tracking(1.8)
                .foregroundStyle(CadenceTheme.muted)

            HStack(alignment: .bottom, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Snippets")
                        .font(.system(size: 40, weight: .medium, design: .serif))
                        .tracking(-1.4)
                    Text("Say a saved trigger while dictating, and Cadence inserts its replacement before any trigger words reach your editor.")
                        .font(.system(size: 13))
                        .foregroundStyle(CadenceTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 24)
                Button {
                    editor = SnippetEditorPresentation(snippet: nil)
                } label: {
                    Label("New snippet", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .tint(CadenceTheme.ink)
                .controlSize(.large)
            }
            .padding(.top, 28)

            if model.snippets.isEmpty {
                emptyState
                    .padding(.top, 32)
            } else {
                snippetLibrary
                    .padding(.top, 32)
            }
        }
        .padding(42)
        .frame(maxWidth: 860, maxHeight: .infinity, alignment: .topLeading)
        .disabled(model.isListening)
        .sheet(item: $editor) { presentation in
            SnippetEditorSheet(snippet: presentation.snippet)
                .environmentObject(model)
        }
        .alert(
            "Delete snippet?",
            isPresented: Binding(
                get: { deleteCandidate != nil },
                set: { if !$0 { deleteCandidate = nil } }
            ),
            presenting: deleteCandidate
        ) { snippet in
            Button("Delete snippet", role: .destructive) {
                model.deleteSnippet(snippet)
                deleteCandidate = nil
            }
            Button("Keep snippet", role: .cancel) {
                deleteCandidate = nil
            }
        } message: { snippet in
            Text("Cadence will stop expanding “\(snippet.trigger)”. This can’t be undone.")
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 12) {
                Image(systemName: "text.badge.plus")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(CadenceTheme.lime)
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(Color.white.opacity(0.08)))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Create your first snippet")
                        .font(.system(size: 17, weight: .semibold))
                    Text("Useful for links, signatures, prompts, and text you repeat often.")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.white.opacity(0.58))
                }
            }

            HStack(spacing: 12) {
                Text("“my email”")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .italic()
                    .padding(.horizontal, 14)
                    .frame(height: 38)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.12)))
                Image(systemName: "arrow.right")
                    .foregroundStyle(Color.white.opacity(0.42))
                Text("you@example.com")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .padding(.horizontal, 14)
                    .frame(height: 38)
                    .background(RoundedRectangle(cornerRadius: 9).fill(CadenceTheme.cream.opacity(0.9)))
                    .foregroundStyle(CadenceTheme.ink)
            }

            Button("Create first snippet") {
                editor = SnippetEditorPresentation(snippet: nil)
            }
            .buttonStyle(.borderedProminent)
            .tint(CadenceTheme.cream)
            .foregroundStyle(CadenceTheme.ink)
        }
        .foregroundStyle(CadenceTheme.cream)
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(CadenceTheme.ink)
        )
    }

    private var snippetLibrary: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(CadenceTheme.muted)
                    TextField("Search snippets", text: $query)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 12)
                .frame(width: 220, height: 36)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.58)))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(CadenceTheme.line))

                Spacer()
                Text("\(model.snippets.count) \(model.snippets.count == 1 ? "SNIPPET" : "SNIPPETS")")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(CadenceTheme.muted)
                Text("STORED ON THIS MAC")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(CadenceTheme.muted)
            }

            if filteredSnippets.isEmpty {
                VStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 20))
                        .foregroundStyle(CadenceTheme.muted)
                    Text("No snippets match “\(query)”.")
                        .font(.system(size: 13, weight: .semibold))
                    Button("Clear search") { query = "" }
                        .buttonStyle(.link)
                }
                .frame(maxWidth: .infinity, minHeight: 150)
                .background(RoundedRectangle(cornerRadius: 13).fill(Color.white.opacity(0.45)))
                .overlay(RoundedRectangle(cornerRadius: 13).stroke(CadenceTheme.line))
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(filteredSnippets.enumerated()), id: \.element.id) { index, snippet in
                            SnippetRow(
                                snippet: snippet,
                                edit: { editor = SnippetEditorPresentation(snippet: snippet) },
                                delete: { deleteCandidate = snippet }
                            )
                            if index < filteredSnippets.count - 1 {
                                Rectangle()
                                    .fill(CadenceTheme.line)
                                    .frame(height: 1)
                                    .padding(.leading, 16)
                            }
                        }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 13).fill(Color.white.opacity(0.48)))
                .overlay(RoundedRectangle(cornerRadius: 13).stroke(CadenceTheme.line))
                .clipShape(RoundedRectangle(cornerRadius: 13))
            }

            Text("Snippet changes apply when the next dictation session starts.")
                .font(.system(size: 11))
                .foregroundStyle(CadenceTheme.muted)
            Text("Stored locally as plain text. Don’t save passwords or other secrets as snippets.")
                .font(.system(size: 11))
                .foregroundStyle(CadenceTheme.muted)
        }
    }
}

private struct SnippetRow: View {
    let snippet: TextSnippet
    let edit: () -> Void
    let delete: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 14) {
            Text(snippet.trigger)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .frame(width: 170, alignment: .leading)

            Image(systemName: "arrow.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(CadenceTheme.muted.opacity(0.7))

            Text(snippet.replacement.replacingOccurrences(of: "\n", with: "  "))
                .font(.system(size: 13))
                .foregroundStyle(CadenceTheme.ink.opacity(0.8))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 4) {
                rowAction("pencil", label: "Edit \(snippet.trigger)", action: edit)
                rowAction("trash", label: "Delete \(snippet.trigger)", action: delete)
            }
            .frame(width: 70, alignment: .trailing)
            .opacity(isHovering ? 1 : 0)
            .allowsHitTesting(isHovering)
            .accessibilityHidden(!isHovering)
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .frame(height: 64)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isHovering = hovering }
        }
        .contextMenu {
            Button("Edit snippet", action: edit)
            Button("Delete snippet", role: .destructive, action: delete)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Edit snippet", edit)
        .accessibilityAction(named: "Delete snippet", delete)
    }

    private func rowAction(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(icon == "trash" ? CadenceTheme.coral : CadenceTheme.ink.opacity(0.72))
        .accessibilityLabel(label)
    }
}

private struct SnippetEditorPresentation: Identifiable {
    let id = UUID()
    let snippet: TextSnippet?
}

private struct SnippetEditorSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let snippet: TextSnippet?

    @State private var trigger: String
    @State private var replacement: String
    @State private var validationError: TextSnippetValidationError?
    @FocusState private var focusedField: Field?

    private enum Field {
        case trigger
        case replacement
    }

    init(snippet: TextSnippet?) {
        self.snippet = snippet
        _trigger = State(initialValue: snippet?.trigger ?? "")
        _replacement = State(initialValue: snippet?.replacement ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(snippet == nil ? "New snippet" : "Edit snippet")
                .font(.system(size: 21, weight: .semibold))
            Text("Cadence matches the spoken trigger as whole words and inserts the saved plain text.")
                .font(.system(size: 12))
                .foregroundStyle(CadenceTheme.muted)
                .padding(.top, 6)

            fieldLabel("Spoken trigger", count: trigger.count, limit: TextSnippetValidator.triggerLimit)
                .padding(.top, 24)
            TextField("For example, my email address", text: $trigger)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 12)
                .frame(height: 40)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.78)))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(CadenceTheme.line))
                .focused($focusedField, equals: .trigger)
                .onSubmit { focusedField = .replacement }
                .onChange(of: trigger) { _, newValue in
                    if newValue.count > TextSnippetValidator.triggerLimit {
                        trigger = String(newValue.prefix(TextSnippetValidator.triggerLimit))
                    }
                    validationError = nil
                }

            fieldLabel("Text to insert", count: replacement.count, limit: TextSnippetValidator.replacementLimit)
                .padding(.top, 18)
            TextEditor(text: $replacement)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.78)))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(CadenceTheme.line))
                .focused($focusedField, equals: .replacement)
                .onChange(of: replacement) { _, newValue in
                    if newValue.count > TextSnippetValidator.replacementLimit {
                        replacement = String(newValue.prefix(TextSnippetValidator.replacementLimit))
                    }
                    validationError = nil
                }

            Group {
                if let validationError {
                    Label(validationError.localizedDescription, systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(CadenceTheme.coral)
                } else {
                    Text("Use a distinctive phrase you are unlikely to say by accident.")
                        .foregroundStyle(CadenceTheme.muted)
                }
            }
            .font(.system(size: 11))
            .frame(height: 32, alignment: .leading)

            HStack {
                Text("Changes apply to new dictation sessions.")
                    .font(.system(size: 11))
                    .foregroundStyle(CadenceTheme.muted)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(snippet == nil ? "Create snippet" : "Save changes", action: save)
                    .buttonStyle(.borderedProminent)
                    .tint(CadenceTheme.ink)
            }
            .padding(.top, 10)
        }
        .padding(28)
        .frame(width: 620, height: 480)
        .background(CadenceTheme.paper)
        .onAppear {
            GlobalHotKey.shared.isSuspended = true
            focusedField = .trigger
        }
        .onDisappear {
            GlobalHotKey.shared.isSuspended = false
        }
    }

    private func fieldLabel(_ label: String, count: Int, limit: Int) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
            Spacer()
            Text("\(count)/\(limit)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(CadenceTheme.muted)
        }
        .padding(.bottom, 7)
    }

    private func save() {
        if let error = model.saveSnippet(
            id: snippet?.id,
            trigger: trigger,
            replacement: replacement
        ) {
            validationError = error
            switch error {
            case .replacementRequired, .replacementTooLong:
                focusedField = .replacement
            default:
                focusedField = .trigger
            }
            return
        }
        dismiss()
    }
}
