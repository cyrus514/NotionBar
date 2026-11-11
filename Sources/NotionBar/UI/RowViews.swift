import SwiftUI

/// One task or step: an icon, the title, and the `└` detail line.
///
/// Hovering swaps the icon for a checkbox; clicking the checkbox marks the row done.
/// Clicking anywhere else runs `onTap` (open in Notion by default). Holding ⌥ turns the whole
/// row into `[x] name`, and then a click anywhere marks it done.
struct ItemRow<Extras: View>: View {
    @EnvironmentObject private var store: TaskStore
    @EnvironmentObject private var model: PanelModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.theme) private var theme
    @Environment(\.metrics) private var metrics
    @Environment(\.motion) private var motion

    var id: String
    var item: Item
    var state: RowState
    /// The pieces of the `└` line.
    var parts: [String]
    /// `2h late`, `in 45m`…
    var badge: String?
    var indent: CGFloat = 0
    /// nil = no arrow; otherwise an arrow that points down when true.
    var disclosure: Bool?
    var onTap: (() -> Void)?
    /// Drawn after the detail text (the step progress blocks on a task).
    @ViewBuilder var extras: () -> Extras

    @ViewState private var hovering = false
    @ViewState private var hoveringBox = false

    var body: some View {
        let completing = store.completing.contains(item.id)
        let armed = model.optionHeld && !completing
        let selected = model.selection == id

        HStack(alignment: .top, spacing: 8) {
            checkbox(completing: completing, armed: armed, active: hovering || selected)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .top, spacing: 6) {
                    Text(title(armed: armed))
                        .font(metrics.title)
                        .strikethrough(completing, color: theme.success)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if item.kind == .task, item.priority == "High" {
                        Spacer(minLength: 0)
                        Text("!high")
                            .font(metrics.small)
                            .foregroundStyle(theme.overdue)
                            .fixedSize()
                            .frame(height: 16 * metrics.scale)
                            .help("high priority")
                    }
                }
                HStack(spacing: 7) {
                    Text(detailLine)
                        .font(metrics.detail)
                        .foregroundStyle(theme.color(for: state))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let badge {
                        Text(badge)
                            .font(metrics.small)
                            .foregroundStyle(state == .normal ? theme.detail : theme.color(for: state))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 4)
                                .fill((state == .normal ? theme.faint : theme.color(for: state)).opacity(0.16)))
                            .fixedSize()
                            .contentTransition(.numericText())
                    }
                    extras()
                }
            }
            Spacer(minLength: 0)
            if let disclosure {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(theme.faint)
                    .rotationEffect(.degrees(disclosure ? 90 : 0))
                    .frame(height: 16 * metrics.scale)
            }
        }
        .padding(.leading, Metrics.rowInset + indent)
        .padding(.trailing, Metrics.rowInset)
        .padding(.vertical, 5)
        .background(RowHighlight(hovering: hovering || armed && hovering, selected: selected,
                                 tint: armed ? theme.success : nil))
        // Ticked: a green wash sweeps across the row, like an added line in a diff, before it leaves.
        .background(alignment: .leading) {
            GeometryReader { geometry in
                Rectangle()
                    .fill(LinearGradient(colors: [theme.success.opacity(0.22), theme.success.opacity(0.08)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: completing ? geometry.size.width : 0)
                    .animation(motion ? .easeOut(duration: 0.32) : nil, value: completing)
            }
        }
        .contentShape(Rectangle())
        .opacity(completing ? 0.6 : 1)
        .onHover { hovering = $0 }
        // The pointer can leave while the panel is closed, with no "mouse left" event: start clean.
        .onChange(of: model.presentCount) { _, _ in
            hovering = false
            hoveringBox = false
        }
        .onTapGesture {
            if model.optionHeld {
                store.markDone(item)
            } else if let onTap {
                onTap()
            } else {
                model.open(item)
            }
        }
        .contextMenu { menu }
        .help(item.name + "\n" + detail)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.name), \(detail)\(badge.map { ", " + $0 } ?? "")")
        .accessibilityAddTraits(.isButton)
        .clickTarget("row|" + id)
        .id(id)
    }

    private var detail: String { parts.joined(separator: " · ") }

    /// The `└` line. On a normal row the step type is tinted (prepare / do / prac), like a keyword.
    private var detailLine: AttributedString {
        var out = AttributedString("└ ")
        for (index, part) in parts.enumerated() {
            if index > 0 { out.append(AttributedString(" · ")) }
            var piece = AttributedString(part)
            if state == .normal, item.kind == .step, index == 1, part == item.stepType.lowercased() {
                piece.foregroundColor = theme.stepText(item.stepType)
            }
            out.append(piece)
        }
        return out
    }

    /// The icon column. At rest it's the type icon; under the pointer it's a checkbox.
    private func checkbox(completing: Bool, armed: Bool, active: Bool) -> some View {
        let icon = Tint.icon(for: item, state: state)
        let symbol: String
        let color: Color
        if completing || armed {
            symbol = "checkmark.square.fill"
            color = Tint.green
        } else if active {
            symbol = hoveringBox ? "checkmark.square" : "square"
            color = hoveringBox ? theme.success : theme.detail
        } else {
            symbol = icon.symbol
            color = icon.color
        }
        return Button {
            store.markDone(item)
        } label: {
            Image(systemName: symbol)
                .font(metrics.icon)
                .foregroundStyle(color)
                .contentTransition(motion ? .symbolEffect(.replace) : .identity)
                .symbolEffect(.bounce, value: completing)
                .symbolEffectsRemoved(!motion)
                .frame(width: metrics.gutter, height: 16 * metrics.scale)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hoveringBox = $0 }
        .help("mark done")
        .accessibilityLabel("mark \(item.name) done")
        .clickTarget("check|" + id)
    }

    /// The title, with `[x] ` in front while ⌥ is held and the typed filter highlighted.
    private func title(armed: Bool) -> AttributedString {
        var out = AttributedString()
        if armed {
            var mark = AttributedString("[x] ")
            mark.foregroundColor = theme.success
            out.append(mark)
        }
        var name = AttributedString(item.name)
        name.foregroundColor = theme.text
        for word in Board.words(in: model.filterText) {
            if let range = name.range(of: word, options: .caseInsensitive) {
                name[range].backgroundColor = theme.match
            }
        }
        out.append(name)
        return out
    }

    /// Right-click menu.
    @ViewBuilder private var menu: some View {
        Button("Open in Notion") { model.open(item) }
        Button("Mark Done") { store.markDone(item) }
        Divider()
        Button(item.isInProgress ? "Set Back to Not Started" : "Start (In Progress)") {
            store.setInProgress(item, !item.isInProgress)
        }
        Menu("Move To") {
            ForEach(model.snoozeOptions()) { option in
                Button(option.label.capitalized) { store.reschedule(item, to: option.day) }
            }
        }
        Button("Focus for \(settings.focusMinutes) Minutes") {
            model.focus.start(item, minutes: settings.focusMinutes)
        }
        Divider()
        Button("Copy Link") { model.copyLink(item) }
    }
}

extension ItemRow where Extras == EmptyView {
    /// A row straight from the board.
    init(_ row: Board.Row, indent: CGFloat = 0) {
        self.init(id: row.id, item: row.item, state: row.state, parts: row.detail, badge: row.badge,
                  indent: indent, extras: { EmptyView() })
    }
}

/// `▸ tasks/ (3)`: a folder line that opens and closes.
struct FolderRow: View {
    @EnvironmentObject private var model: PanelModel
    @Environment(\.theme) private var theme
    @Environment(\.metrics) private var metrics

    var id: String
    var name: String
    var count: Int
    var open: Bool
    var action: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(theme.detail)
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .frame(width: 10)
                Image(systemName: open ? "folder.fill" : "folder")
                    .font(metrics.icon)
                    .foregroundStyle(theme.accent)
                    .contentTransition(.symbolEffect(.replace))
                HStack(spacing: 0) {
                    Text(name).foregroundStyle(theme.text)
                    Text(" (").foregroundStyle(theme.detail)
                    Text("\(count)").foregroundStyle(theme.detail)
                        .contentTransition(.numericText(value: Double(count)))
                    Text(")").foregroundStyle(theme.detail)
                }
                .font(metrics.title)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Metrics.rowInset)
            .padding(.vertical, 6)
            .background(RowHighlight(hovering: hovering, selected: model.selection == id))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .onChange(of: model.presentCount) { _, _ in hovering = false }
        .accessibilityLabel("\(name) \(count) items, \(open ? "expanded" : "collapsed")")
        .clickTarget(id)
        .id(id)
    }
}

/// A task under `tasks/`. Click to unfold its steps and the `$ open` / `$ mark-done` actions.
struct TaskGroupView: View {
    @EnvironmentObject private var store: TaskStore
    @EnvironmentObject private var model: PanelModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.theme) private var theme
    @Environment(\.metrics) private var metrics

    var group: Board.TaskGroup
    /// How far the task sits in from the folder line.
    private let indent: CGFloat = 16

    var body: some View {
        let open = model.isTaskOpen(group)
        VStack(alignment: .leading, spacing: 0) {
            ItemRow(id: group.id, item: group.task, state: group.state, parts: group.detail,
                    badge: group.state == .overdue ? Board.badge(group.task.due, today: store.board.today, now: store.now) : nil,
                    indent: indent, disclosure: open, onTap: { model.toggle(group) }) {
                if group.totalSteps > 0 {
                    SegmentBar(done: group.doneSteps, total: group.totalSteps, maxSegments: 8, height: 7)
                    Text("\(group.doneSteps)/\(group.totalSteps)")
                        .font(metrics.small)
                        .foregroundStyle(theme.faint)
                        .fixedSize()
                }
            }

            if open {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 2) {
                        CommandButton(name: "open", help: "open this task in notion") { model.open(group.task) }
                        CommandButton(name: "mark-done", tint: theme.success,
                                      help: "finish this task and its steps") { store.markDone(group.task) }
                        CommandButton(name: "focus", help: "start a \(settings.focusMinutes)-minute countdown on this task") {
                            model.focus.start(group.task, minutes: settings.focusMinutes)
                        }
                        CommandButton(name: "add-step", help: "add a step to this task") {
                            model.beginAddStep(group.task)
                        }
                    }
                    .padding(.leading, Metrics.rowInset + indent + metrics.gutter + 3)
                    .padding(.vertical, 2)

                    if !group.steps.isEmpty {
                        Text("// steps")
                            .font(metrics.detail)
                            .foregroundStyle(theme.comment)
                            .padding(.leading, Metrics.rowInset + indent + metrics.gutter + 8)
                            .padding(.top, 4)
                            .padding(.bottom, 2)
                        ForEach(group.steps) { step in
                            ItemRow(step, indent: indent + metrics.gutter + 8)
                                .transition(.rowRemoval)
                        }
                    }
                }
                // An indent guide down the left, like a code editor draws for a nested block.
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(theme.separator)
                        .frame(width: 1)
                        .padding(.leading, Metrics.rowInset + indent + metrics.gutter / 2)
                        .padding(.vertical, 3)
                }
                .padding(.bottom, 4)
                .transition(.opacity)
            }
        }
    }
}

/// Something finished today, under `done/`. Hover for `$ reopen`.
struct DoneRow: View {
    @EnvironmentObject private var store: TaskStore
    @EnvironmentObject private var model: PanelModel
    @Environment(\.theme) private var theme
    @Environment(\.metrics) private var metrics

    var item: Item
    private let indent: CGFloat = 16
    @ViewState private var hovering = false

    private var detail: String {
        var parts: [String] = []
        switch item.kind {
        case .step:
            if !item.stepType.isEmpty { parts.append(item.stepType.lowercased()) }
            if !item.parentName.isEmpty { parts.append(item.parentName) }
        case .task:
            parts.append(item.types.isEmpty ? "task" : item.types.joined(separator: ", "))
        }
        return (["done"] + parts).joined(separator: " · ")
    }

    var body: some View {
        let id = "done|" + item.id
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.square.fill")
                .font(metrics.icon)
                .foregroundStyle(theme.success.opacity(0.75))
                .frame(width: metrics.gutter, height: 16 * metrics.scale)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(metrics.title)
                    .strikethrough(true, color: theme.faint)
                    .foregroundStyle(theme.detail)
                    .lineLimit(1)
                Text("└ " + detail)
                    .font(metrics.detail)
                    .foregroundStyle(theme.faint)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if hovering || model.selection == id {
                CommandButton(name: "reopen", help: "set it back to not started") { store.reopen(item) }
            }
        }
        .padding(.leading, Metrics.rowInset + indent)
        .padding(.trailing, Metrics.rowInset - 4)
        .padding(.vertical, 5)
        .background(RowHighlight(hovering: hovering, selected: model.selection == id))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onChange(of: model.presentCount) { _, _ in hovering = false }
        .onTapGesture { model.open(item) }
        .help(item.name)
        .clickTarget("row|" + id)
        .id(id)
    }
}

extension AnyTransition {
    /// A finished row fades and slides out to the right; new rows just fade in.
    static var rowRemoval: AnyTransition {
        .asymmetric(insertion: .opacity, removal: .move(edge: .trailing).combined(with: .opacity))
    }
}
