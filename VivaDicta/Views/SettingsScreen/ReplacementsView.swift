//
//  ReplacementsView.swift
//  VivaDicta
//
//  Created by Anton Novoselov on 2025.12.10
//

import SwiftUI
import AppGroup
import SwiftData

/// Settings → 词库.
///
/// One entry = one word the user wants, optionally plus the forms the pipeline
/// used to produce instead (常见错法). The wanted word alone is enough: adding
/// `muse` and leaving 常见错法 blank makes every recognition layer prefer `muse`
/// without installing a rigid find-and-replace rule - the same behaviour the
/// desktop app has. Filling 常见错法 adds the deterministic rewrite on top.
struct ReplacementsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \WordReplacement.dateAdded, order: .reverse) private var replacements: [WordReplacement]
    @State private var preferredText: String = ""
    @State private var misrecognitionText: String = ""
    @State private var replacementToEdit: WordReplacement?

    @State private var editMode = false
    @State private var selectedReplacements: Set<PersistentIdentifier> = []
    @State private var showDeleteAlert = false

    @AppStorage(UserDefaultsStorage.Keys.isReplacementsEnabled)
    private var isReplacementsEnabled: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            enableToggle

            if replacements.isEmpty {
                emptyStateView
            } else {
                if editMode {
                    editModeToolbar
                }
                replacementsList
            }

            if !editMode {
                addReplacementBar
            }
        }
        .toolbar {
            if editMode {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        HapticManager.lightImpact()
                        selectedReplacements.removeAll()
                        editMode = false
                    }
                }
            } else {
                ToolbarItem(placement: .primaryAction) {
                    Button("编辑") {
                        HapticManager.lightImpact()
                        editMode = true
                    }
                    .disabled(replacements.isEmpty)
                }
            }
        }
        .navigationTitle("个人词库")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $replacementToEdit) { item in
            EditReplacementSheet(
                preferredText: item.replacementText,
                misrecognitionText: item.originalText
            ) { newPreferred, newMisrecognitions in
                var trimmedPreferred = newPreferred.trimmingCharacters(in: .whitespacesAndNewlines)
                var trimmedMisrecognitions = newMisrecognitions.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmedPreferred.count > ReplacementsService.maxTextLength {
                    trimmedPreferred = String(trimmedPreferred.prefix(ReplacementsService.maxTextLength))
                }
                if trimmedMisrecognitions.count > ReplacementsService.maxTextLength {
                    trimmedMisrecognitions = String(trimmedMisrecognitions.prefix(ReplacementsService.maxTextLength))
                }
                guard !trimmedPreferred.isEmpty else { return }
                item.replacementText = trimmedPreferred
                item.originalText = trimmedMisrecognitions
                replacementToEdit = nil
            }
            .presentationDetents(.sizeToFit)
        }
        .alert("从词库删除", isPresented: $showDeleteAlert) {
            Button("删除", role: .destructive) {
                deleteSelectedReplacements()
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("确定要删除这 \(selectedReplacements.count) 个词吗？此操作无法撤销。")
        }
    }

    private var enableToggle: some View {
        Toggle("启用词库", isOn: $isReplacementsEnabled)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .onChange(of: isReplacementsEnabled) { _, _ in
                HapticManager.selectionChanged()
            }
    }

    private var emptyStateView: some View {
        ContentUnavailableView {
            Label("词库是空的", systemImage: "text.book.closed")
        } description: {
            VStack(alignment: .leading, spacing: 8) {
                Text("只写正确写法就能加词：听到像是这个词的语音，就会优先识别成它。")
                Text("""
                    常见错法可以不填，例如：
                        muse
                        缪斯 → muse
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.leading)
        }
        .frame(maxHeight: .infinity)
    }

    private var editModeToolbar: some View {
        HStack {
            Button(allReplacementsSelected ? "取消全选" : "全选") {
                if allReplacementsSelected {
                    HapticManager.selectionChanged()
                    selectedReplacements.removeAll()
                } else {
                    HapticManager.selectionChanged()
                    selectedReplacements = Set(replacements.map(\.persistentModelID))
                }
            }

            Spacer()

            if !selectedReplacements.isEmpty {
                Button("删除", role: .destructive) {
                    HapticManager.warning()
                    showDeleteAlert = true
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var allReplacementsSelected: Bool {
        !replacements.isEmpty &&
        selectedReplacements.count == replacements.count
    }

    private var replacementsList: some View {
        List {
            ForEach(replacements) { replacement in
                Button {
                    if editMode {
                        toggleSelection(replacement)
                    } else {
                        replacementToEdit = replacement
                    }
                } label: {
                    HStack {
                        if editMode {
                            Image(systemName: selectedReplacements.contains(replacement.persistentModelID) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selectedReplacements.contains(replacement.persistentModelID) ? .blue : .secondary)
                                .font(.title2)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text(replacement.preferredSpelling)
                                .font(.body)

                            if replacement.isRecognitionOnly {
                                Label("只优先识别", systemImage: "ear")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.left.arrow.right")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(replacement.misrecognitions.joined(separator: "、"))
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        Spacer()
                    }
                    .contentShape(.rect)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if !editMode {
                        Button(role: .destructive) {
                            HapticManager.mediumImpact()
                            modelContext.delete(replacement)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }

                        Button {
                            HapticManager.lightImpact()
                            replacementToEdit = replacement
                        } label: {
                            Label("编辑", systemImage: "pencil")
                        }
                        .tint(.blue)
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    private func toggleSelection(_ replacement: WordReplacement) {
        HapticManager.selectionChanged()
        if selectedReplacements.contains(replacement.persistentModelID) {
            selectedReplacements.remove(replacement.persistentModelID)
        } else {
            selectedReplacements.insert(replacement.persistentModelID)
        }
    }

    private func deleteSelectedReplacements() {
        HapticManager.heavyImpact()
        for replacement in replacements where selectedReplacements.contains(replacement.persistentModelID) {
            modelContext.delete(replacement)
        }
        selectedReplacements.removeAll()

        if replacements.isEmpty {
            editMode = false
        }
    }

    private var addReplacementBar: some View {
        VStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                TextField("正确写法", text: $preferredText)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .padding(8)
                    .background {
                        Capsule()
                            .stroke(.gray, lineWidth: 0.5)
                    }
                    .onChange(of: preferredText) { _, newValue in
                        if newValue.count > ReplacementsService.maxTextLength {
                            preferredText = String(newValue.prefix(ReplacementsService.maxTextLength))
                        }
                    }
                    .onSubmit {
                        addReplacement()
                    }

                Text("想说成这样，就写这个，比如 muse。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                TextField("常见错法（可不填）", text: $misrecognitionText)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .padding(8)
                    .background {
                        Capsule()
                            .stroke(.gray, lineWidth: 0.5)
                    }
                    .onChange(of: misrecognitionText) { _, newValue in
                        if newValue.count > ReplacementsService.maxTextLength {
                            misrecognitionText = String(newValue.prefix(ReplacementsService.maxTextLength))
                        }
                    }
                    .onSubmit {
                        addReplacement()
                    }

                Text("以前被识别成的写法，用顿号或逗号隔开，比如 缪斯、缪斯get。不填就只做优先识别。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Button("添加到词库", action: addReplacement)
                .buttonStyle(.borderedProminent)
                .disabled(!canAddReplacement)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var canAddReplacement: Bool {
        !preferredText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func addReplacement() {
        var trimmedPreferred = preferredText.trimmingCharacters(in: .whitespacesAndNewlines)
        var trimmedMisrecognitions = misrecognitionText.trimmingCharacters(in: .whitespacesAndNewlines)

        // Only 正确写法 is required - an entry without 常见错法 is the normal case.
        guard !trimmedPreferred.isEmpty else { return }

        if trimmedPreferred.count > ReplacementsService.maxTextLength {
            trimmedPreferred = String(trimmedPreferred.prefix(ReplacementsService.maxTextLength))
        }
        if trimmedMisrecognitions.count > ReplacementsService.maxTextLength {
            trimmedMisrecognitions = String(trimmedMisrecognitions.prefix(ReplacementsService.maxTextLength))
        }

        // Check for duplicate word (case-insensitive)
        let isDuplicate = replacements.contains {
            $0.preferredSpelling.lowercased() == trimmedPreferred.lowercased()
        }
        guard !isDuplicate else { return }

        HapticManager.mediumImpact()
        let wordReplacement = WordReplacement(
            originalText: trimmedMisrecognitions,
            replacementText: trimmedPreferred
        )
        modelContext.insert(wordReplacement)
        preferredText = ""
        misrecognitionText = ""
    }
}

// MARK: - Edit Lexicon Sheet

private struct EditReplacementSheet: View {
    let preferredText: String
    let misrecognitionText: String
    let onSave: (String, String) -> Void

    @State private var editedPreferred: String
    @State private var editedMisrecognitions: String
    @FocusState private var focusedField: Field?

    enum Field {
        case preferred, misrecognition
    }

    init(preferredText: String, misrecognitionText: String, onSave: @escaping (String, String) -> Void) {
        self.preferredText = preferredText
        self.misrecognitionText = misrecognitionText
        self.onSave = onSave
        self._editedPreferred = State(initialValue: preferredText)
        self._editedMisrecognitions = State(initialValue: misrecognitionText)
    }

    private var hasChanges: Bool {
        let trimmedPreferred = editedPreferred.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMisrecognitions = editedMisrecognitions.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmedPreferred.isEmpty &&
               (trimmedPreferred != preferredText || trimmedMisrecognitions != misrecognitionText)
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("编辑词条")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                TextField("正确写法", text: $editedPreferred)
                    .focused($focusedField, equals: .preferred)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .padding(12)
                    .background(Color(.systemGray5), in: .rect(cornerRadius: 10))
                    .onChange(of: editedPreferred) { _, newValue in
                        if newValue.count > ReplacementsService.maxTextLength {
                            editedPreferred = String(newValue.prefix(ReplacementsService.maxTextLength))
                        }
                    }

                Text("想说成这样，就写这个。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                TextField("常见错法（可不填）", text: $editedMisrecognitions)
                    .focused($focusedField, equals: .misrecognition)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .padding(12)
                    .background(Color(.systemGray5))
                    .clipShape(.rect(cornerRadius: 10))
                    .onChange(of: editedMisrecognitions) { _, newValue in
                        if newValue.count > ReplacementsService.maxTextLength {
                            editedMisrecognitions = String(newValue.prefix(ReplacementsService.maxTextLength))
                        }
                    }

                Text("以前被识别成的写法，顿号或逗号隔开；不填就只做优先识别。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Button("保存修改") {
                HapticManager.mediumImpact()
                onSave(editedPreferred, editedMisrecognitions)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(hasChanges ? Color.blue : Color(.systemGray4))
            .foregroundStyle(hasChanges ? .white : .secondary)
            .clipShape(.rect(cornerRadius: 10))
            .disabled(!hasChanges)
        }
        .padding()
        .presentationDragIndicator(.hidden)
        .onAppear {
            focusedField = .preferred
        }
    }
}

#Preview {
    NavigationStack {
        ReplacementsView()
    }
}
