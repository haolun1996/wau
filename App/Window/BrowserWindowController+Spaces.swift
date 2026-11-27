import AppKit
import Core
import SwiftUI

/// Creating, editing, deleting and switching Spaces.
extension BrowserWindowController {
    @objc func newSpace(_ sender: Any?) {
        presentSpaceEditor(for: nil)
    }

    @objc func editSpace(_ sender: Any?) {
        presentSpaceEditor(for: model.currentSpace)
    }

    @objc func deleteSpace(_ sender: Any?) {
        confirmDelete(model.currentSpace)
    }

    /// Menu: Spaces ▸ <name>, with ⌃1…⌃9; the item's tag is the Space's number.
    @objc func switchToSpaceNumber(_ sender: Any?) {
        guard let tag = (sender as? NSMenuItem)?.tag, model.spaces.indices.contains(tag - 1) else { return }
        model.switchToSpace(model.spaces[tag - 1])
    }

    @objc func nextSpace(_ sender: Any?) {
        model.switchSpace(by: 1)
    }

    @objc func previousSpace(_ sender: Any?) {
        model.switchSpace(by: -1)
    }

    /// Shows the Space editor as a sheet: for `space`, or a new Space when nil.
    func presentSpaceEditor(for space: Space?) {
        guard let window, kind == .main else { return }
        let sheet = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        let draft = SpaceDraft(
            name: space?.name ?? "",
            icon: space?.icon ?? SpaceDraft.iconChoices.randomElement()!,
            themeID: space?.themeID ?? SpaceTheme.all.randomElement()!.id,
            separateProfile: false,
            archiveInterval: space?.archiveInterval ?? .default
        )
        let editor = SpaceEditorView(draft: draft, isNew: space == nil) { [weak self, weak window, weak sheet] result in
            if let sheet { window?.endSheet(sheet) }
            guard let self, let result else { return }
            let name = result.name.trimmingCharacters(in: .whitespaces)
            if let space {
                model.updateSpace(space, name: name, icon: result.icon, themeID: result.themeID, archiveInterval: result.archiveInterval)
            } else {
                let created = model.createSpace(name: name, icon: result.icon, themeID: result.themeID, separateProfile: result.separateProfile)
                model.updateSpace(created, name: name, icon: result.icon, themeID: result.themeID, archiveInterval: result.archiveInterval)
                model.open(url: Self.homeURL)
            }
        }
        let host = NSHostingController(rootView: editor)
        host.sizingOptions = .preferredContentSize
        sheet.contentViewController = host
        window.beginSheet(sheet)
    }

    func confirmDelete(_ space: Space) {
        guard let window, kind == .main, model.spaces.count > 1 else { NSSound.beep(); return }
        let alert = NSAlert()
        alert.messageText = "Delete “\(space.name)”?"
        let tabCount = space.pinned.count + space.tabs.count
        let easelCount = easels.easels(in: space.id).count
        var details = "Its \(tabCount) tab\(tabCount == 1 ? "" : "s") will be closed"
        details += easelCount > 0 ? " and its \(easelCount) Easel\(easelCount == 1 ? "" : "s") deleted." : "."
        if space.profileID != nil {
            details += " Its separate logins, cookies and site data will be erased."
        }
        alert.informativeText = details
        alert.addButton(withTitle: "Delete Space")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            easels.deleteEasels(inSpace: space.id)
            if let profile = model.deleteSpace(space) {
                Task { await Profiles.erase(profile) }
            }
        }
    }

    // MARK: Two-finger swipe on the sidebar switches Spaces

    func installSpaceSwipe() {
        swipeMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.consumeSwipe(event) ?? false }
            return consumed ? nil : event
        }
    }

    func removeSpaceSwipe() {
        if let swipeMonitor { NSEvent.removeMonitor(swipeMonitor) }
        swipeMonitor = nil
    }

    /// Accumulates a horizontal trackpad swipe over the sidebar and switches
    /// Space once it has travelled far enough. Returns true when the event
    /// was used up; other scrolls pass through.
    private func consumeSwipe(_ event: NSEvent) -> Bool {
        guard event.window === window, isSidebarVisible, event.hasPreciseScrollingDeltas,
              sidebar.view.bounds.contains(sidebar.view.convert(event.locationInWindow, from: nil))
        else { return false }

        switch event.phase {
        case .began:
            swipeDistance = 0
        case .changed:
            // After switching, the rest of the gesture is ignored so one
            // swipe moves one Space (marked by an infinite distance).
            if swipeDistance.isInfinite { return true }
            // Only mostly-horizontal movement counts, so list scrolling still works.
            guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else { return false }
            swipeDistance += event.scrollingDeltaX
            if abs(swipeDistance) > 90 {
                model.switchSpace(by: swipeDistance > 0 ? -1 : 1)
                swipeDistance = .infinity
            }
            return true
        case .ended, .cancelled:
            swipeDistance = 0
        default:
            break
        }
        return false
    }
}

/// What the Space editor edits.
struct SpaceDraft {
    static let iconChoices = ["🪁", "🌙", "🏝️", "🍃", "🏛️", "⛰️", "🧵", "🌺", "🏮", "💼", "🎮", "📚", "🎨", "🛠️", "🍜", "☕️"]

    var name: String
    var icon: String
    var themeID: String
    var separateProfile: Bool
    var archiveInterval: ArchiveInterval
}

/// The sheet for creating or editing a Space.
struct SpaceEditorView: View {
    @State var draft: SpaceDraft
    let isNew: Bool
    /// Called with the result, or nil when cancelled.
    let onFinish: (SpaceDraft?) -> Void

    private var canSave: Bool {
        !draft.name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(isNew ? "New Space" : "Edit Space")
                .font(.title2.weight(.semibold))

            HStack(spacing: 10) {
                Text(draft.icon)
                    .font(.system(size: 30))
                    .frame(width: 44, height: 44)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                TextField("Name, e.g. Work or Kopi Time", text: $draft.name)
                    .textFieldStyle(.roundedBorder)
                    .font(.title3)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Icon").font(.headline)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(32), spacing: 6), count: 8), spacing: 6) {
                    ForEach(SpaceDraft.iconChoices, id: \.self) { icon in
                        Button { draft.icon = icon } label: {
                            Text(icon).font(.system(size: 18)).frame(width: 32, height: 32)
                                .background(draft.icon == icon ? AnyShapeStyle(.tint.opacity(0.3)) : AnyShapeStyle(.clear),
                                            in: RoundedRectangle(cornerRadius: 7))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Theme").font(.headline)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                    ForEach(SpaceTheme.all) { theme in
                        Button { draft.themeID = theme.id } label: {
                            VStack(spacing: 4) {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(LinearGradient(colors: [Color(theme.top), Color(theme.bottom)], startPoint: .top, endPoint: .bottom))
                                    .frame(height: 34)
                                    .overlay(RoundedRectangle(cornerRadius: 8)
                                        .strokeBorder(draft.themeID == theme.id ? Color.primary : .clear, lineWidth: 2))
                                Text(theme.name).font(.caption)
                            }
                        }
                        .buttonStyle(.plain)
                        .help(theme.inspiration)
                    }
                }
                if let theme = SpaceTheme.theme(withID: draft.themeID) {
                    Text(theme.inspiration).font(.caption).foregroundStyle(.secondary)
                }
            }

            Picker("Archive unused tabs after", selection: $draft.archiveInterval) {
                ForEach(ArchiveInterval.allCases) { interval in
                    Text(interval.displayName).tag(interval)
                }
            }
            .help("Ordinary tabs you haven't looked at for this long are archived. Pinned tabs and favorites never are.")

            if isNew {
                Toggle(isOn: $draft.separateProfile) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Separate logins")
                        Text("This Space gets its own cookies and sign-ins, e.g. a second Google account. It can't be changed later.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onFinish(nil) }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Create Space" : "Save") { onFinish(draft) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(22)
        .frame(width: 440)
    }
}

private extension Color {
    init(_ color: ThemeColor) {
        self.init(.sRGB, red: color.red, green: color.green, blue: color.blue)
    }
}
