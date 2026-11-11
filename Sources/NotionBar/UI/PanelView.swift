import SwiftUI

/// What the panel window hosts. The window itself is see-through and a little larger than the
/// card, so the card can grow, shrink and cast a shadow without the window ever resizing.
struct PanelRoot: View {
    @EnvironmentObject private var model: PanelModel
    @EnvironmentObject private var settings: AppSettings

    /// See-through space around the card, for its shadow.
    static let margin: CGFloat = 26

    var body: some View {
        Themed {
            PanelCard()
                .scaleEffect(model.isPresented ? 1 : 0.965, anchor: .top)
                .offset(y: model.isPresented ? 0 : -10)
                .animation(settings.motion ? .spring(response: 0.3, dampingFraction: 0.78) : nil, value: model.isPresented)
                .padding(PanelRoot.margin)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .ignoresSafeArea()
    }
}

/// The panel: prompt on top, the list in the middle, commands at the bottom.
struct PanelCard: View {
    @EnvironmentObject private var store: TaskStore
    @EnvironmentObject private var model: PanelModel
    @Environment(\.theme) private var theme
    @Environment(\.motion) private var motion
    @ViewState private var contentHeight: CGFloat = 0
    /// Height of everything that isn't the list: header, footer, toast.
    @ViewState private var headerHeight: CGFloat = 0
    @ViewState private var footerHeight: CGFloat = 0

    /// The list is as tall as its rows, until the card would pass its limit. Then it scrolls.
    private var listHeight: CGFloat {
        min(contentHeight, max(120, model.maxHeight - headerHeight - footerHeight - 2))
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.cornerRadius)
        VStack(spacing: 0) {
            HeaderView().readHeight { headerHeight = $0 }
            SyncLine(active: store.isLoading)
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    PanelContent()
                        .background(GeometryReader { geometry in
                            Color.clear.preference(key: ContentHeightKey.self, value: geometry.size.height)
                        })
                }
                .scrollBounceBehavior(.basedOnSize)
                .onPreferenceChange(ContentHeightKey.self) { height in
                    // The list hugs its rows, up to the tallest the card may be.
                    if abs(height - contentHeight) > 0.5 {
                        animate(motion && contentHeight > 0, .snappy(duration: 0.28)) { contentHeight = height }
                    }
                }
                .frame(height: listHeight)
                .onChange(of: model.selection) { _, id in
                    guard let id else { return }
                    animate(motion, .easeOut(duration: 0.15)) { proxy.scrollTo(id) }
                }
            }
            VStack(spacing: 0) {
                if let toast = store.toast {
                    ToastView(toast: toast)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                Hairline()
                FooterView()
            }
            .readHeight { footerHeight = $0 }
        }
        .frame(width: Metrics.panelWidth)
        .readHeight { model.cardHeight = $0 }
        .overlay { ConfettiView(trigger: model.celebration) }
        .clipShape(shape)
        .background {
            ZStack {
                if !model.solidBackground { VisualEffect(cornerRadius: Metrics.cornerRadius) }
                shape.fill(theme.background.opacity(model.solidBackground ? 1 : (theme.dark ? 0.86 : 0.9)))
            }
            .shadow(color: .black.opacity(theme.dark ? 0.5 : 0.22), radius: 18, x: 0, y: 9)
        }
        .overlay(shape.strokeBorder(
            // Pinned: the border takes the accent colour, so it's clear why the panel isn't going away.
            model.isPinned ? theme.accent.opacity(0.75) : (theme.dark ? Color.white.opacity(0.14) : Color.black.opacity(0.14)),
            lineWidth: 1))
    }
}

// MARK: - Header

/// The prompt (`~/tasks ❯ `), the refresh and settings buttons, and today's progress.
struct HeaderView: View {
    @EnvironmentObject private var store: TaskStore
    @EnvironmentObject private var model: PanelModel
    @Environment(\.theme) private var theme
    @Environment(\.metrics) private var metrics
    @FocusState private var promptFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text("~/tasks").foregroundStyle(theme.accent)
                Text("❯").foregroundStyle(theme.success)
                TextField("", text: $model.query,
                          prompt: Text("filter · + to add").foregroundStyle(theme.faint))
                    .textFieldStyle(.plain)
                    .foregroundStyle(theme.text)
                    .tint(theme.success)
                    .focused($promptFocused)
                    .onSubmit { model.submitDraft() }
                    .accessibilityLabel("filter tasks, or type plus to add one")
                IconButton(symbol: model.isPinned ? "pin.fill" : "pin",
                           help: model.isPinned ? "unpin (⌘P)" : "keep the panel open while you work (⌘P)",
                           active: model.isPinned) { model.togglePin() }
                IconButton(symbol: "arrow.clockwise", help: "refresh (⌘R)", spinning: store.isLoading) {
                    Task { await store.refresh() }
                }
                IconButton(symbol: "gearshape", help: "settings (⌘,)") { model.openSettings() }
            }
            .font(metrics.title)

            HStack(spacing: 8) {
                progress
                Spacer(minLength: 4)
                sync
            }
            .font(metrics.small)

            if store.failure == nil && store.hasData {
                WeekStrip().padding(.horizontal, -3)
            }
        }
        .padding(.horizontal, Metrics.rowInset)
        .padding(.top, 10)
        .padding(.bottom, 7)
        .background(theme.chrome.opacity(0.55))
        .onAppear { promptFocused = true }
        .onChange(of: model.presentCount) { _, _ in promptFocused = true }
    }

    /// `■■□□□□□ 2/7 today`: finished today, out of everything that was due by today.
    @ViewBuilder private var progress: some View {
        let done = store.finished.count
        let total = done + store.board.count
        if store.failure != nil || !store.hasData {
            Text("// " + (store.isLoading ? "loading…" : "not connected")).foregroundStyle(theme.faint)
        } else if total == 0 {
            Text("// all clear").foregroundStyle(theme.comment)
        } else {
            SegmentBar(done: done, total: total)
            HStack(spacing: 0) {
                Text("\(done)").contentTransition(.numericText(value: Double(done)))
                Text("/\(total) done today")
            }
            .foregroundStyle(theme.detail)
        }
    }

    @ViewBuilder private var sync: some View {
        if store.isLoading {
            Text("syncing…").foregroundStyle(theme.faint)
        } else if store.isOffline {
            Text("offline").foregroundStyle(theme.late)
        } else if let updated = store.lastUpdated {
            Text("synced " + Schedule.clock(updated)).foregroundStyle(theme.faint)
        }
    }
}

// MARK: - The list

struct PanelContent: View {
    @EnvironmentObject private var store: TaskStore
    @EnvironmentObject private var model: PanelModel
    @EnvironmentObject private var focus: FocusTimer
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let draft = model.draft {
                AddPreview(draft: draft)
                Hairline(inset: Metrics.rowInset).padding(.vertical, 4)
            }
            if focus.session != nil || focus.completed != nil {
                FocusBanner()
                Hairline(inset: Metrics.rowInset).padding(.vertical, 4)
            }

            if let failure = store.failure {
                ErrorBlock(failure: failure)
            } else if !store.hasData {
                NoteLine(text: "// loading…", color: theme.comment, small: true)
            } else {
                if store.isOffline {
                    OfflineNote()
                }
                sections
                    // The last list that loaded, greyed out while Notion can't be reached.
                    .saturation(store.isOffline ? 0 : 1)
                    .opacity(store.isOffline ? 0.55 : 1)
            }
        }
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var sections: some View {
        let board = model.visibleBoard
        let finished = model.visibleFinished
        let filtering = model.isFiltering
        let nothingMatches = filtering && board.isEmpty && finished.isEmpty

        if let label = model.dayFilterLabel {
            HStack(spacing: 4) {
                Text("// only what's due \(label)")
                Spacer(minLength: 0)
                CommandButton(name: "clear", help: "show every day again (esc)") {
                    if let day = model.dayFilter { model.toggleDay(day) }
                }
            }
            .font(Mono.font(12))
            .foregroundStyle(theme.accent)
            .padding(.leading, Metrics.rowInset)
            .padding(.trailing, Metrics.rowInset - 5)
            .padding(.top, 2)
            .transition(.opacity)
        }

        if nothingMatches {
            NoteLine(text: model.isSearching
                        ? "// no matches for \"\(model.query.trimmingCharacters(in: .whitespaces))\""
                        : "✓ nothing due \(model.dayFilterLabel ?? "then")",
                     color: model.isSearching ? theme.comment : theme.success, small: model.isSearching)
        } else {
            if !board.overdue.isEmpty {
                SectionHeader(text: "overdue", count: board.overdue.count).reveal(0)
                ForEach(Array(board.overdue.enumerated()), id: \.element.id) { index, row in
                    ItemRow(row).reveal(1 + index).transition(.rowRemoval)
                }
                Hairline(inset: Metrics.rowInset).padding(.vertical, 4)
            }

            if !filtering || !board.dueToday.isEmpty {
                let base = board.overdue.count + 1
                SectionHeader(text: board.header).reveal(base)
                if board.dueToday.isEmpty {
                    NoteLine(text: "✓ nothing due today", color: theme.success)
                        .reveal(base + 1)
                        .transition(.opacity)
                } else {
                    ForEach(Array(board.dueToday.enumerated()), id: \.element.id) { index, row in
                        ItemRow(row).reveal(base + 1 + index).transition(.rowRemoval)
                    }
                }
                Hairline(inset: Metrics.rowInset).padding(.vertical, 4)
            }

            if !board.upcoming.isEmpty {
                let base = board.overdue.count + board.dueToday.count + 3
                SectionHeader(text: "upcoming").reveal(base)
                ForEach(Array(board.upcoming.enumerated()), id: \.element.id) { index, row in
                    ItemRow(row).reveal(base + 1 + index).transition(.rowRemoval)
                }
                if board.upcomingHidden > 0 {
                    NoteLine(text: "   … \(board.upcomingHidden) more", color: theme.detail, small: true)
                }
                Hairline(inset: Metrics.rowInset).padding(.vertical, 4)
            }

            if !filtering || !board.tasks.isEmpty {
                FolderRow(id: PanelModel.tasksFolderID, name: "tasks/", count: board.tasks.count,
                          open: model.tasksOpen) { model.toggleTasks() }
                    .reveal(board.count + board.upcoming.count + 5)
                if board.tasks.isEmpty {
                    // Nothing left at all: say so without making you open an empty folder.
                    NoteLine(text: "✓ everything's done", color: theme.success).transition(.opacity)
                }
                if model.tasksOpen {
                    ForEach(board.tasks) { group in
                        TaskGroupView(group: group).transition(.rowRemoval)
                    }
                }
            }

            if !finished.isEmpty {
                Hairline(inset: Metrics.rowInset).padding(.vertical, 4)
                FolderRow(id: PanelModel.doneFolderID, name: "done/", count: finished.count,
                          open: model.doneOpen) { model.toggleDone() }
                    .reveal(board.count + board.upcoming.count + 6)
                if model.doneOpen {
                    ForEach(finished) { item in
                        DoneRow(item: item).transition(.opacity)
                    }
                }
            }
        }
    }
}

/// `// offline · last updated 2:41 pm`
struct OfflineNote: View {
    @EnvironmentObject private var store: TaskStore
    @Environment(\.theme) private var theme
    @Environment(\.metrics) private var metrics

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 11, weight: .semibold))
                .symbolEffect(.pulse)
            Text("offline · last updated " + (store.lastUpdated.map(Schedule.clock) ?? "never"))
            Spacer(minLength: 0)
            CommandButton(name: "retry", help: "try notion again") {
                Task { await store.refresh() }
            }
        }
        .font(metrics.detail)
        .foregroundStyle(theme.late)
        .padding(.leading, Metrics.rowInset)
        .padding(.trailing, Metrics.rowInset - 5)
        .padding(.vertical, 4)
    }
}

/// `! couldn't load tasks`, with a hint and the raw message.
struct ErrorBlock: View {
    @EnvironmentObject private var store: TaskStore
    @EnvironmentObject private var model: PanelModel
    @Environment(\.theme) private var theme
    @Environment(\.metrics) private var metrics
    var failure: TaskStore.Failure

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(metrics.icon)
                    .symbolEffect(.bounce, value: failure)
                Text("! couldn't load tasks").font(metrics.titleBold)
            }
            .foregroundStyle(theme.overdue)
            if let hint = failure.hint {
                Text("// " + hint)
                    .font(metrics.detail)
                    .foregroundStyle(theme.comment)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(failure.message)
                .font(metrics.detail)
                .foregroundStyle(theme.overdue)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            HStack(spacing: 2) {
                if failure.needsSettings {
                    CommandButton(name: "open settings", help: "paste or fix the token") { model.openSettings() }
                }
                CommandButton(name: "retry", help: "try again") { Task { await store.refresh() } }
            }
            .padding(.leading, -5)
            .padding(.top, 2)
        }
        .padding(.horizontal, Metrics.rowInset)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Shown under the prompt while typing `+ …`: what Return will create.
struct AddPreview: View {
    @EnvironmentObject private var store: TaskStore
    @EnvironmentObject private var model: PanelModel
    @Environment(\.theme) private var theme
    @Environment(\.metrics) private var metrics
    var draft: QuickAddDraft

    var body: some View {
        let parent = model.addStepParent
        VStack(alignment: .leading, spacing: 3) {
            Text(parent.map { "// new step for \($0.name)" } ?? "// new task")
                .font(metrics.detail).foregroundStyle(theme.comment).lineLimit(1)
            if draft.isValid {
                HStack(alignment: .top, spacing: 8) {
                    let icon: (symbol: String, color: Color) = parent == nil
                        ? Tint.task(draft.types)
                        : (symbol: "chevron.right", color: Tint.step(draft.stepType ?? ""))
                    Image(systemName: icon.symbol)
                        .font(metrics.icon)
                        .foregroundStyle(icon.color)
                        .frame(width: metrics.gutter, height: 16 * metrics.scale)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(draft.title).font(metrics.title).foregroundStyle(theme.text).lineLimit(2)
                        Text("└ " + draft.summary(today: store.board.today, asStep: parent != nil))
                            .font(metrics.detail).foregroundStyle(theme.detail).lineLimit(1)
                    }
                }
                Text(parent == nil
                     ? "// ⏎ to create · words like \"tomorrow 5pm\", #homework #test #project, !high"
                     : "// ⏎ to add · words like \"tomorrow 5pm\", #prepare #do #prac")
                    .font(metrics.small).foregroundStyle(theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(parent == nil ? "+ read chapter 4 friday 7pm #homework" : "+ make cue cards tomorrow 7pm #prepare")
                    .font(metrics.title).foregroundStyle(theme.faint)
                Text(parent == nil
                     ? "// type a title · add a date, #type or !priority if you like"
                     : "// type the step · add a date and #prepare, #do or #prac if you like")
                    .font(metrics.small).foregroundStyle(theme.faint)
            }
        }
        .padding(.horizontal, Metrics.rowInset)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The focus countdown, pinned above the list while it runs and when it ends.
struct FocusBanner: View {
    @EnvironmentObject private var store: TaskStore
    @EnvironmentObject private var model: PanelModel
    @EnvironmentObject private var focus: FocusTimer
    @Environment(\.theme) private var theme
    @Environment(\.metrics) private var metrics

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let session = focus.session {
                HStack(spacing: 7) {
                    Image(systemName: "timer").font(metrics.icon).symbolEffect(.pulse)
                    Text("focus " + focus.label).font(metrics.titleBold)
                        .contentTransition(.numericText(countsDown: true))
                    Spacer(minLength: 0)
                    CommandButton(name: "stop", help: "end the countdown") { focus.stop() }
                }
                .foregroundStyle(theme.accent)
                Text("└ " + session.item.name).font(metrics.detail).foregroundStyle(theme.detail).lineLimit(1)
            } else if let session = focus.completed {
                HStack(spacing: 7) {
                    Image(systemName: "checkmark.seal.fill").font(metrics.icon)
                    Text("\(session.minutes) min of focus done").font(metrics.titleBold)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(theme.success)
                Text("└ " + session.item.name).font(metrics.detail).foregroundStyle(theme.detail).lineLimit(1)
                HStack(spacing: 2) {
                    CommandButton(name: "mark-done", tint: theme.success, help: "mark it done in notion") {
                        store.markDone(session.item)
                        focus.dismissCompleted()
                    }
                    CommandButton(name: "dismiss", help: "not finished yet") { focus.dismissCompleted() }
                }
                .padding(.leading, -5)
            }
        }
        .padding(.leading, Metrics.rowInset)
        .padding(.trailing, Metrics.rowInset - 5)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Footer

/// `$ open task-tracker   $ open steps   $ refresh` and a one-line hint.
struct FooterView: View {
    @EnvironmentObject private var store: TaskStore
    @EnvironmentObject private var model: PanelModel
    @Environment(\.theme) private var theme
    @Environment(\.metrics) private var metrics

    private var hint: String {
        if model.optionHeld { return "// ⌥ held · click any row to mark it done" }
        if model.isAdding { return "// ⏎ create · esc cancel" }
        if model.selection != nil { return "// ⏎ open · ⌘⏎ done · → unfold · esc close" }
        if model.isPinned { return "// pinned · stays open · esc or ⌘P to unpin" }
        if model.isFiltering { return "// ⏎ open first match · ↑↓ pick · esc clear" }
        return "// click an icon to mark done · hold ⌥ for any row"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                CommandButton(name: "open task-tracker", help: "open the task tracker in notion") {
                    model.openPage(model.config().tasksDatabase)
                }
                CommandButton(name: "open steps", help: "open the steps database in notion") {
                    model.openPage(model.config().stepsDatabase)
                }
                CommandButton(name: "refresh", help: "fetch from notion now (⌘R)") {
                    Task { await store.refresh() }
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, -5)
            Text(hint)
                .font(metrics.small)
                .foregroundStyle(theme.comment)
                .lineLimit(1)
                .contentTransition(.opacity)
        }
        .padding(.horizontal, Metrics.rowInset)
        .padding(.top, 6)
        .padding(.bottom, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.chrome.opacity(0.55))
    }
}

/// The message that slides up above the footer: `✓ done · study guide   $ undo`.
struct ToastView: View {
    @EnvironmentObject private var store: TaskStore
    @Environment(\.theme) private var theme
    @Environment(\.metrics) private var metrics
    var toast: TaskStore.Toast

    private var color: Color {
        switch toast.kind {
        case .done: return theme.success
        case .info: return theme.accent
        case .error: return theme.overdue
        }
    }

    private var symbol: String {
        switch toast.kind {
        case .done: return "checkmark.circle.fill"
        case .info: return "info.circle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(color)
                .symbolEffect(.bounce, value: toast.id)
            Text(toast.text)
                .font(metrics.detail)
                .foregroundStyle(theme.text)
                .lineLimit(2)
            Spacer(minLength: 0)
            if toast.canUndo && store.canUndo {
                CommandButton(name: "undo", help: "take it back (⌘Z)") { store.undoLast() }
            }
        }
        .padding(.leading, Metrics.rowInset)
        .padding(.trailing, Metrics.rowInset - 5)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(theme.dark ? 0.16 : 0.10))
        .overlay(alignment: .leading) { Rectangle().fill(color).frame(width: 3) }
        .contentShape(Rectangle())
        .onTapGesture { store.dismissToast() }
    }
}
