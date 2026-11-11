import Foundation

/// One unfinished row from Notion: either a task (Task Tracker) or a step (Steps database).
struct Item: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        case task
        case step
    }

    let id: String
    let kind: Kind
    var name: String
    var due: Due?
    /// `Not started`, `In progress` or `Done`.
    var status: String
    /// Position in Notion's reply. Keeps ties in Notion's order when sorting.
    var order: Int = 0

    // Steps only
    /// `Prepare`, `Do` or `Prac`.
    var stepType: String = ""
    /// The first related page in "Test / Project".
    var parentID: String?
    /// The parent's name, when the parent is still unfinished.
    var parentName: String = ""

    // Tasks only
    /// `homework`, `test`, `project`, `personal`.
    var types: [String] = []
    var priority: String = ""
    /// How many steps the task has in total, finished ones included.
    var relatedStepCount: Int = 0
    /// True when `due` holds the task's Completion date: the day you plan to do it
    /// (Settings → "show tasks on their completion date").
    var isPlanned = false
    /// The task's real Due date, when `due` holds the planned day instead.
    var deadline: Due?

    var isInProgress: Bool { status == "In progress" }
}

/// Turns Notion pages into `Item`s. Port of `build` in the plugin.
enum ItemBuilder {
    /// `planByCompletionDate`: a task that has a Completion date filled in ahead of time shows up
    /// on that day instead of on its Due date.
    static func build(tasks taskPages: [NotionPage], steps stepPages: [NotionPage],
                      planByCompletionDate: Bool = false) -> (tasks: [Item], steps: [Item]) {
        var tasks: [Item] = []
        var nameByID: [String: String] = [:]
        for (index, page) in taskPages.enumerated() {
            var item = task(from: page, order: index)
            if planByCompletionDate, item.status != "Done", let planned = page.due("Completion date") {
                item.deadline = item.due
                item.due = planned
                item.isPlanned = true
            }
            // Notion can return the same page twice across pages of results; keep the first.
            guard nameByID[item.id] == nil else { continue }
            nameByID[item.id] = item.name
            tasks.append(item)
        }

        var steps: [Item] = []
        var seen = Set<String>()
        for (index, page) in stepPages.enumerated() {
            var item = step(from: page, order: index)
            guard seen.insert(item.id).inserted else { continue }
            if let parent = item.parentID, let name = nameByID[parent] {
                item.parentName = name
            }
            steps.append(item)
        }
        return (tasks, steps)
    }

    static func task(from page: NotionPage, order: Int = 0) -> Item {
        Item(
            id: page.id,
            kind: .task,
            name: page.title(preferring: "Task name"),
            due: page.due("Due date"),
            status: page.properties["Status"]?.status?.name ?? "",
            order: order,
            types: (page.properties["Task type"]?.multiSelect ?? []).map(\.name),
            priority: page.properties["Priority"]?.select?.name ?? "",
            relatedStepCount: page.properties["Steps"]?.relation?.count ?? 0
        )
    }

    static func step(from page: NotionPage, order: Int = 0) -> Item {
        Item(
            id: page.id,
            kind: .step,
            name: page.title(preferring: "Name"),
            due: page.due("Due date"),
            status: page.properties["Status"]?.status?.name ?? "",
            order: order,
            stepType: page.properties["Step type"]?.select?.name ?? "",
            parentID: page.properties["Test / Project"]?.relation?.first?.id
        )
    }

    /// Tidies a Notion title for a one-line row.
    static func clean(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return flat.isEmpty ? "Untitled" : flat
    }
}
