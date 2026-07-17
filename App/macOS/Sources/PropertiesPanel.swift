import SwiftUI
import QuoinCore
import QuoinRender

/// The Properties inspector (#70/#79): front matter as an editable
/// key/value panel, the trailing inspector's third mode. The panel is the
/// EDITOR — the in-document field grid stays the projection. One row per
/// top-level field, with a TYPE-APPROPRIATE editor per value
/// (`FrontMatterEditing.inferredType`): date picker, bool toggle, number
/// field, CSV list field, plain text for everything else. Complex fields
/// (nested lists/maps, block scalars) show a read-only raw preview —
/// they're edited in the document via the block's source reveal. Every
/// write goes through the session's in-actor front-matter writers;
/// refusals surface as the action-failure banner.
struct PropertiesPanel: View {
    let fields: [FrontMatterEditing.Field]
    /// Plain-string commit: the scalar writer escapes/quotes as needed.
    let onSet: (String, String) -> Void
    /// Typed commit: the raw value (bool/number/date/flow list) is written
    /// VERBATIM — quoting a datetime's `:`s would change its YAML type.
    let onSetTyped: (String, String) -> Void
    let onRemove: (String) -> Void

    /// The keys the "+ Add Property" menu pre-offers (already-present
    /// keys drop out); "Custom…" takes any editable key.
    private static let commonKeys = [
        "title", "tags", "date", "author", "status", "description", "aliases", "draft",
    ]

    @State private var isCustomKeyVisible = false
    @State private var customKey = ""

    private var availableCommonKeys: [String] {
        let taken = Set(fields.map(\.key))
        return Self.commonKeys.filter { !taken.contains($0) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(fields, id: \.byteRange.offset) { field in
                    PropertyRow(
                        field: field, onSet: onSet, onSetTyped: onSetTyped, onRemove: onRemove)
                }
                if fields.isEmpty {
                    Text("No properties yet")
                        .quoinScaledFont(size: 11.5)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                addPropertyMenu
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
            .padding(.top, 6)
        }
    }

    private var addPropertyMenu: some View {
        Menu {
            ForEach(availableCommonKeys, id: \.self) { key in
                Button(key) { onSet(key, "") }
            }
            if !availableCommonKeys.isEmpty {
                Divider()
            }
            Button("Custom…") {
                customKey = ""
                isCustomKeyVisible = true
            }
        } label: {
            Label("Add Property", systemImage: "plus")
                .quoinScaledFont(size: 11, weight: .medium)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Add a front-matter property")
        .popover(isPresented: $isCustomKeyVisible, arrowEdge: .bottom) {
            customKeyEntry
        }
    }

    private var customKeyEntry: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Property name")
                .quoinScaledFont(size: 11, weight: .semibold)
            TextField("key", text: $customKey)
                .textFieldStyle(.roundedBorder)
                .quoinScaledFont(size: 12)
                .frame(width: 160)
                .onSubmit { addCustomKey() }
            HStack {
                Spacer()
                Button("Add") { addCustomKey() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!FrontMatterEditing.isEditableKey(
                        customKey.trimmingCharacters(in: .whitespaces)))
            }
        }
        .padding(12)
    }

    private func addCustomKey() {
        let key = customKey.trimmingCharacters(in: .whitespaces)
        guard FrontMatterEditing.isEditableKey(key) else { return }
        isCustomKeyVisible = false
        onSet(key, "")
    }
}

/// One field row: small-caps key (the in-document grid's grammar), a
/// type-appropriate value editor, hover ✕ to remove. Draft-backed editors
/// commit only when the draft actually differs — focus wandering must not
/// spam no-op edits. Toggle/date editors commit per change (one edit, one
/// undo). Every typed row keeps an escape hatch to raw text editing
/// ("Edit as Text" in the context menu, or double-click the key).
private struct PropertyRow: View {
    let field: FrontMatterEditing.Field
    let onSet: (String, String) -> Void
    let onSetTyped: (String, String) -> Void
    let onRemove: (String) -> Void

    @State private var draft = ""
    @State private var isHovering = false
    @State private var editAsText = false
    @FocusState private var isFocused: Bool

    private enum Editor: Equatable {
        case readOnly
        case toggle
        case datePicker(FrontMatterEditing.ParsedDate)
        case number
        case list
        case text
    }

    private var inferredEditor: Editor {
        switch FrontMatterEditing.inferredType(key: field.key, rawValue: field.rawPreview) {
        case .bool:
            return .toggle
        case .date:
            guard let parsed = FrontMatterEditing.parseDate(
                field.rawPreview.trimmingCharacters(in: .whitespaces)) else { return .text }
            return .datePicker(parsed)
        case .number:
            return .number
        case .list:
            return .list
        case .string:
            return field.isComplex ? .readOnly : .text
        }
    }

    private var editor: Editor {
        let inferred = inferredEditor
        if editAsText, inferred != .readOnly { return .text }
        return inferred
    }

    /// True when the row has a typed editor to escape FROM / return to.
    private var hasTypedEditor: Bool {
        switch inferredEditor {
        case .readOnly, .text: return false
        default: return true
        }
    }

    /// What the draft-backed editors project the CURRENT value as.
    private var displayValue: String {
        switch editor {
        case .list:
            return FrontMatterEditing.csv(
                fromItems: FrontMatterEditing.flowListItems(field.rawPreview) ?? [])
        case .text where field.isComplex:
            // The raw-text escape hatch on a flow list edits the flow form
            // itself — the scalar writer refuses complex fields.
            return field.rawPreview
        default:
            return field.value
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(field.key.uppercased())
                        .quoinScaledFont(size: 10, weight: .semibold)
                        .kerning(0.5)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .onTapGesture(count: 2) {
                            if hasTypedEditor { editAsText.toggle() }
                        }
                    Spacer(minLength: 0)
                    if isHovering {
                        Button {
                            onRemove(field.key)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .quoinScaledFont(size: 10)
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .help("Remove “\(field.key)”")
                    }
                }
                valueEditor
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)
                .padding(.leading, 12)
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .contextMenu {
            if hasTypedEditor {
                Button(editAsText ? "Use Typed Editor" : "Edit as Text") {
                    editAsText.toggle()
                }
            }
            Button("Remove Property", role: .destructive) { onRemove(field.key) }
        }
        .onAppear { draft = displayValue }
        // A projection change (this or another window's edit) or an editor
        // switch refreshes the row — but never while the user is mid-type.
        .onChange(of: displayValue) { _, newValue in
            if !isFocused { draft = newValue }
        }
        .onChange(of: isFocused) { _, focused in
            if !focused { commit() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(field.key): \(field.isComplex ? field.rawPreview : field.value)")
    }

    @ViewBuilder private var valueEditor: some View {
        switch editor {
        case .readOnly:
            Text(field.rawPreview)
                .quoinScaledFont(size: 11, design: .monospaced)
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .help("Nested values are edited in the document — click the front-matter block")
        case .toggle:
            Toggle("", isOn: Binding(
                get: { field.value == "true" },
                set: { onSetTyped(field.key, $0 ? "true" : "false") }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        case .datePicker(let parsed):
            DatePicker(
                "",
                selection: Binding(
                    get: { parsed.dateValue ?? Date(timeIntervalSince1970: 0) },
                    set: { onSetTyped(field.key, parsed.replacingWallClock($0).serialized) }),
                displayedComponents: parsed.precision.hasTime ? [.date, .hourAndMinute] : [.date])
                .labelsHidden()
                .datePickerStyle(.compact)
                .fixedSize()
                // The file's digits are WALL-CLOCK: render them verbatim
                // (UTC = identity), never shifted into the viewer's zone.
                .environment(\.timeZone, TimeZone(identifier: "UTC")!)
        case .number:
            TextField("number", text: $draft)
                .textFieldStyle(.plain)
                .quoinScaledFont(size: 12)
                .monospacedDigit()
                .focused($isFocused)
                .onSubmit { commit() }
        case .list:
            TextField("comma, separated", text: $draft)
                .textFieldStyle(.plain)
                .quoinScaledFont(size: 12)
                .focused($isFocused)
                .onSubmit { commit() }
        case .text:
            TextField("empty", text: $draft)
                .textFieldStyle(.plain)
                .quoinScaledFont(size: 12)
                .focused($isFocused)
                .onSubmit { commit() }
        }
    }

    private func commit() {
        guard draft != displayValue else { return }
        switch editor {
        case .list:
            onSetTyped(field.key, FrontMatterEditing.flowList(
                fromItems: FrontMatterEditing.csvItems(draft)))
        case .number, .text:
            let trimmed = draft.trimmingCharacters(in: .whitespaces)
            if FrontMatterEditing.isTypedRawValue(trimmed) {
                // A clean typed form goes through the verbatim writer: the
                // scalar writer would quote a datetime's `:`s or refuse a
                // flow list — either changes the value's YAML type.
                onSetTyped(field.key, trimmed)
            } else {
                onSet(field.key, draft)
            }
        case .readOnly, .toggle, .datePicker:
            break
        }
    }
}
