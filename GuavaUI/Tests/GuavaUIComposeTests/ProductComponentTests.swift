import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Product component contracts", .serialized)
@MainActor
struct ProductComponentTests: GuavaUIComposeSerializedSuite {
    private func nodes(_ root: Node) -> [Node] { [root] + root.children.flatMap(nodes) }
    private func key(_ code: UInt32) -> KeyEvent { KeyEvent(scancode: code, keycode: 0, modifiers: [], isRepeat: false) }
    private func withScene(_ body: (ViewGraph, InteractionRegistry, FocusChain, PointerCapture, PortalStore) -> Void) {
        GlobalTestLock.locked {
            let oldInteractions = InteractionRegistryHolder.current, oldFocus = FocusChainHolder.current
            let oldCapture = PointerCaptureHolder.current, oldPortal = PortalStoreHolder.current
            let oldText = TextEnvironmentHolder.current
            let interactions = InteractionRegistry(), focus = FocusChain(), capture = PointerCapture(), portal = PortalStore()
            InteractionRegistryHolder.current = interactions; FocusChainHolder.current = focus
            PointerCaptureHolder.current = capture; PortalStoreHolder.current = portal
            TextEnvironmentHolder.current = TextEnvironment.bootstrapped(atlasTextureID: 1, primaryFontName: SystemFontDefaults.primaryFontName)
            defer {
                InteractionRegistryHolder.current = oldInteractions; FocusChainHolder.current = oldFocus
                PointerCaptureHolder.current = oldCapture; PortalStoreHolder.current = oldPortal; TextEnvironmentHolder.current = oldText
            }
            AnimatorScheduler.$current.withValue(AnimatorScheduler()) {
                let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
                body(graph, interactions, focus, capture, portal)
                graph.install(root: EmptyView())
                AnimatorScheduler.current.tick(deltaTime: 1)
            }
        }
    }

    @Test("Radio has one Tab stop; arrows skip disabled options and move actual focus")
    func radioNavigation() {
        withScene { graph, registry, focus, capture, _ in
            var selection: String? = "a"
            graph.install(root: RadioGroup(selection: Binding(get: { selection }, set: { selection = $0 }), options: [
                RadioOption("a", "First"), RadioOption("disabled", "Unavailable") { $0.isEnabled = false }, RadioOption("b", "Last")
            ]))
            graph.computeLayout(width: 400, height: 160)
            let buttons = nodes(graph.tree.root!).filter { $0.attachments[ButtonHost.markerKey] as? Bool == true }
            #expect(buttons.filter { $0.isFocusable && $0.isTabStop }.count == 1)
            focus.focusNext(in: graph.tree.root!)
            #expect(focus.focused === buttons[0])
            let dispatcher = EventDispatcher(tree: graph.tree, interactions: registry, capture: capture, focusChain: focus)
            dispatcher.dispatch(.keyDown(key(Scancode.arrowRight)))
            #expect(selection == "b" && focus.focused === buttons[2])
            graph.recomposer.commitAll()
            #expect(buttons[2].isTabStop && !buttons[0].isTabStop)
            dispatcher.dispatch(.keyDown(key(Scancode.arrowRight)))
            #expect(selection == "a" && focus.focused === buttons[0])
            graph.install(root: RadioGroup<String>(selection: .constant(nil), options: []))
            graph.computeLayout(width: 400, height: 100)
        }
    }

    @Test("A nested button handles activation without activating its containing button")
    func nestedButtons() {
        withScene { graph, registry, focus, capture, _ in
            var outer = 0, inner = 0
            graph.install(root: Button(action: { outer += 1 }) {
                Row { Text("Parent"); Button("Clear") { inner += 1 }.debugName("nested-action") }
            })
            graph.computeLayout(width: 400, height: 60)
            let frame = graph.layoutSnapshot().first { $0.debugName == "nested-action" }!.absoluteFrame
            let event = MouseButtonEvent(button: .left, x: Float(frame.midX), y: Float(frame.midY), clicks: 1)
            let dispatcher = EventDispatcher(tree: graph.tree, interactions: registry, capture: capture, focusChain: focus)
            dispatcher.dispatch(.mouseButtonDown(event)); graph.recomposer.commitAll()
            dispatcher.dispatch(.mouseButtonUp(event))
            #expect(inner == 1 && outer == 0)
        }
    }

    @Test("Validation reads current values; invalid and duplicate submits are blocked; reset preserves authored values")
    func formSession() {
        var name = "", email = "invalid"
        let form = FormController()
        let rules = [FormRule.required("name", label: "Name", value: { name }),
                     FormRule("email", label: "Email") { email.contains("@") ? nil : "Enter a valid email." }]
        #expect(!form.beginSubmit(rules))
        #expect(form.issues.map(\.fieldID) == ["name", "email"])
        name = "Guava"; email = "hello@example.com"
        #expect(form.beginSubmit(rules) && form.isSubmitting)
        #expect(!form.beginSubmit(rules))
        form.finishSubmit(error: "Connection interrupted")
        #expect(form.submission == .failed("Connection interrupted"))
        #expect(form.beginSubmit(rules))
        form.finishSubmit()
        #expect(form.submission == .succeeded)
        form.reset()
        #expect(form.submitCount == 0 && form.issues.isEmpty && form.submission == .editing)
        #expect(name == "Guava" && email == "hello@example.com")
    }

    @Test("Toast replacement, queue timing and hover pause are deterministic")
    func notificationQueue() {
        let center = ToastController(maxVisible: 1)
        center.post(ToastNotification("First", id: "a") { $0.duration = 2 })
        center.post(ToastNotification("Queued", id: "b") { $0.duration = 2 })
        center.post(ToastNotification("Replaced", id: "a") { $0.duration = 3 })
        #expect(center.notifications.map(\.title) == ["Replaced"] && center.queuedCount == 1)
        center.setPaused(true, id: "a"); center.advance(by: 100)
        #expect(center.notifications.first?.id == "a")
        center.setPaused(false, id: "a"); center.advance(by: 3)
        #expect(center.notifications.first?.id == "b")
        center.advance(by: 1)
        #expect(center.notifications.first?.id == "b")
        center.advance(by: 1)
        #expect(center.notifications.isEmpty)
    }

    @Test("Notification clocks and tooltip portals leave with their owning subtree")
    func transientResourceLifecycle() {
        withScene { graph, registry, _, _, portal in
            let center = ToastController()
            center.post(ToastNotification("Saved") { $0.duration = 2 })
            graph.install(root: LayerRoot { NotificationHost(center) })
            graph.recomposer.commitAll(); graph.computeLayout(width: 800, height: 600)
            #expect(portal.entries.count == 1)
            graph.install(root: EmptyView())
            AnimatorScheduler.current.tick(deltaTime: 3)
            #expect(portal.entries.isEmpty && center.notifications.count == 1)
            graph.install(root: LayerRoot { Text("Target").tooltip("Description") { $0.delay = 0.2 } })
            graph.computeLayout(width: 800, height: 600)
            let host = nodes(graph.tree.root!).first { $0.attachments["tooltip.host"] as? Bool == true }!
            registry.handlers(for: host).hover?(.enter)
            AnimatorScheduler.current.tick(deltaTime: 0.1)
            #expect(portal.entries.isEmpty)
            AnimatorScheduler.current.tick(deltaTime: 0.11)
            #expect(portal.entries.count == 1)
            graph.install(root: EmptyView())
            #expect(portal.entries.isEmpty)
        }
    }

    @Test("Combobox filters by every term, including Unicode labels")
    func comboboxSearch() {
        let options = [SelectOption(value: 1, label: "北京 Camera"), SelectOption(value: 2, label: "上海 Camera"), SelectOption(value: 3, label: "北京 Light")]
        #expect(Combobox.matching(options, query: "北京 camera").map(\.value) == [1])
        #expect(Combobox.matching(options, query: "missing").isEmpty)
        #expect(Combobox.matching(options, query: "").count == 3)
    }
    @Test("Semantic controls expose actions, suppress decorative labels and mask secure values")
    func accessibilityContracts() {
        withScene { graph, _, _, _, _ in
            var checked = false
            var password: TextBuffer = "secret"
            var clicks = 0
            graph.install(root: Column {
                Button("Save") { clicks += 1 }
                Checkbox(isOn: Binding(get: { checked }, set: { checked = $0 })).accessibilityLabel("Enable logging")
                TextField("Password", text: Binding(get: { password }, set: { password = $0 })) { $0.behavior.secure = true }
                Button("Disabled", isEnabled: false) { clicks += 100 }
            })
            graph.computeLayout(width: 400, height: 300)
            func flatten(_ elements: [AccessibilityElement]) -> [AccessibilityElement] { elements.flatMap { [$0] + flatten($0.children) } }
            let elements = flatten(AccessibilityTree.snapshot(root: graph.tree.root!))
            let button = elements.first { $0.semantics.role == .button && $0.semantics.label == "Save" }!
            let decorativeDuplicates = elements.filter { $0.semantics.role == .staticText && $0.semantics.label == "Save" }
            #expect(decorativeDuplicates.isEmpty)
            button.node.accessibilityActions.activate?(); #expect(clicks == 1)
            guard let checkbox = elements.first(where: { $0.semantics.role == .checkbox }) else { Issue.record("Missing checkbox role"); return }
            #expect(checkbox.semantics.label == "Enable logging")
            checkbox.node.accessibilityActions.activate?(); #expect(checked)
            guard let field = elements.first(where: { $0.semantics.role == .textField }) else { Issue.record("Missing text-field semantics"); return }
            #expect(field.semantics.value == "••••••")
            field.node.accessibilityActions.setValue?("changed"); #expect(password.stringValue == "changed")
            #expect(elements.first { $0.semantics.label == "Disabled" }?.node.accessibilityActions.activate == nil)
        }
    }

    @Test("Table sorting is stable; virtualized rows and header geometry share column widths")
    func tableContracts() {
        struct Record { let id: Int; let score: Int }
        let records = [Record(id: 0, score: 2), Record(id: 1, score: 1), Record(id: 2, score: 2)]
        let column = TableColumn<Record>("score", "Score", configure: {
            $0.layout.width = 180
            $0.compare = { $0.score == $1.score ? .orderedSame : $0.score < $1.score ? .orderedAscending : .orderedDescending }
        }) { Text(String($0.score)) }
        #expect(Table<Record, Int>.sorted(records, columns: [column], sort: TableSort("score")).map(\.id) == [1, 0, 2])
        #expect(Table<Record, Int>.sorted(records, columns: [column], sort: TableSort("score", direction: .descending)).map(\.id) == [0, 2, 1])
        #expect(column.layout.constrained(-20) == 60 && column.layout.constrained(5000) == 800)
        withScene { graph, _, _, _, _ in
            graph.install(root: Table((0..<10_000).map { Record(id: $0, score: $0) }, id: \.id, columns: [column]).frame(height: 300))
            for _ in 0..<4 { graph.recomposer.commitAll(); graph.computeLayout(width: 700, height: 300) }
            let rows = nodes(graph.tree.root!).filter { $0.accessibility?.role == .listItem }
            #expect(rows.count > 3 && rows.count < 30)
            #expect(rows.allSatisfy { abs($0.frame.height - 36) < 0.1 })
            let identity = rows.map(\.id)
            for _ in 0..<30 { graph.recomposer.commitAll(); graph.computeLayout(width: 700, height: 300) }
            #expect(nodes(graph.tree.root!).filter { $0.accessibility?.role == .listItem }.map(\.id) == identity)
        }
    }

    @Test("Default table sorting and selection work without externally supplied bindings")
    func tableUncontrolledInteractions() {
        struct Record { let id: Int; let score: Int }
        let column = TableColumn<Record>("score", "Score", configure: { $0.compare = { $0.score < $1.score ? .orderedAscending : $0.score > $1.score ? .orderedDescending : .orderedSame } }) { Text(String($0.score)) }
        withScene { graph, _, _, _, _ in
            graph.install(root: Table([Record(id: 0, score: 2), Record(id: 1, score: 1)], id: \.id, columns: [column]).frame(height: 240))
            for _ in 0..<4 { graph.recomposer.commitAll(); graph.computeLayout(width: 600, height: 240) }
            let header = nodes(graph.tree.root!).first { $0.accessibility?.label == "Sort by Score" }!
            header.accessibilityActions.activate?()
            for _ in 0..<4 { graph.recomposer.commitAll(); graph.computeLayout(width: 600, height: 240) }
            let rows = nodes(graph.tree.root!).filter { $0.accessibility?.role == .listItem }
            func elements(_ values: [AccessibilityElement]) -> [AccessibilityElement] { values.flatMap { [$0] + elements($0.children) } }
            let cells = elements(AccessibilityTree.snapshot(root: graph.tree.root!)).filter { $0.semantics.role == .cell }
            #expect(cells.map { $0.semantics.value } == ["1", "2"])
            #expect(header.accessibility?.help == "Sorted ascending. Activate to sort descending.")
            rows[0].accessibilityActions.activate?(); graph.recomposer.commitAll()
            #expect(nodes(graph.tree.root!).filter { $0.accessibility?.role == .listItem && $0.accessibility?.state.isSelected == true }.count == 1)
        }
    }

    @Test("Month grids handle leap years, week origins, DST and unavailable dates")
    func calendarArithmetic() throws {
        var calendar = Foundation.Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!; calendar.firstWeekday = 2
        let leap = calendar.date(from: DateComponents(year: 2024, month: 2, day: 1))!
        let days = CalendarGrid.days(in: leap, calendar: calendar)
        #expect(days.count == 42 && calendar.component(.weekday, from: days[0]) == 2)
        #expect(days.filter { calendar.component(.month, from: $0) == 2 }.count == 29)
        let beforeDST = calendar.date(from: DateComponents(year: 2024, month: 3, day: 10))!
        let next = CalendarGrid.move(beforeDST, days: 1, calendar: calendar, availability: DateAvailability())!
        #expect(calendar.component(.day, from: next) == 11 && next.timeIntervalSince(beforeDST) == 23 * 3600)
        var weekdays = DateAvailability(); weekdays.isEnabled = { !calendar.isDateInWeekend($0) }
        let friday = calendar.date(from: DateComponents(year: 2024, month: 3, day: 8))!
        #expect(CalendarGrid.move(friday, days: 1, calendar: calendar, availability: weekdays) == next)
        weekdays.maximum = friday
        #expect(CalendarGrid.move(friday, days: 1, calendar: calendar, availability: weekdays) == nil)
    }

    @Test("Time parsing rejects invalid components and preserves serialization defaults")
    func timeValues() throws {
        #expect(TimeOfDay.parse("23:59") == TimeOfDay(hour: 23, minute: 59))
        #expect(TimeOfDay.parse("24:00") == nil && TimeOfDay.parse("09:99") == nil)
        #expect(TimeOfDay.parse("09:30:45", showSeconds: true)?.second == 45)
        #expect(TimeOfDay.parse("09:30:", showSeconds: true) == nil)
        let value = TimeOfDay(hour: 17, minute: 2, second: 11)
        #expect(try JSONDecoder().decode(TimeOfDay.self, from: JSONEncoder().encode(value)) == value)
        #expect(try JSONDecoder().decode(TimeOfDay.self, from: Data("{}".utf8)) == TimeOfDay())
    }

    @Test("Pagination bounds huge values and exposes deterministic gap positions")
    func paginationBounds() {
        #expect(PaginationModel.items(current: 1, total: 0).isEmpty)
        #expect(PaginationModel.normalized(-10, total: 3) == 1)
        #expect(PaginationModel.items(current: 8, total: 25) == [.page(1), .leadingGap, .page(7), .page(8), .page(9), .trailingGap, .page(25)])
        #expect(PaginationModel.items(current: Int.max, total: Int.max).count < 10)
        #expect(PaginationModel.items(current: 2, total: 5) == (1...5).map { .page($0) })
    }
    @Test("Accordion separates authored expansion from focus; disabled entries cannot expand")
    func accordionExpansion() {
        var expanded: Set<String> = ["a"]
        let items = [AccordionItem("a", "First") { Text("A") }, AccordionItem("b", "Second") { Text("B") }, AccordionItem("c", "Disabled", isEnabled: false) { EmptyView() }]
        var accordion = Accordion(items, expanded: Binding(get: { expanded }, set: { expanded = $0 }))
        accordion.toggle("b"); #expect(expanded == ["b"])
        accordion.toggle("c"); #expect(expanded == ["b"])
        accordion.allowsMultiple = true; accordion.toggle("a"); #expect(expanded == ["a", "b"])
        accordion.toggle("b"); #expect(expanded == ["a"])
    }
    @Test("Associated labels focus only their own scene input and expose validation semantics")
    func formFieldSemantics() {
        withScene { graph, _, focus, _, _ in
            graph.install(root: Form([FormField("name", "Name", configure: { $0.isRequired = true; $0.error = "Required" }) { TextField("Enter name", text: .constant("")) }]))
            graph.computeLayout(width: 400, height: 200)
            let field = nodes(graph.tree.root!).first { $0.accessibility?.role == .textField }!
            #expect(field.accessibility?.label == "Name" && field.accessibility?.state.isRequired == true && field.accessibility?.state.isInvalid == true)
            let label = nodes(graph.tree.root!).first { $0.accessibility?.role == .button && $0.accessibility?.label == "Name" }!
            label.accessibilityActions.activate?()
            #expect(focus.focused === field)
        }
    }

    @Test("Calendar keyboard focus moves across months without selecting until Return")
    func calendarKeyboard() {
        withScene { graph, registry, focus, capture, _ in
            var calendar = Foundation.Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let last = calendar.date(from: DateComponents(year: 2024, month: 2, day: 29))!
            var selected: Date? = last
            graph.install(root: CalendarView(selection: Binding(get: { selected }, set: { selected = $0 })) { $0.calendar = calendar; $0.today = last })
            graph.computeLayout(width: 500, height: 500)
            let day = nodes(graph.tree.root!).first { $0.attachments["calendar.day"] as? Date == last && $0.isFocusable }!
            focus.focus(day)
            let dispatcher = EventDispatcher(tree: graph.tree, interactions: registry, capture: capture, focusChain: focus)
            dispatcher.dispatch(.keyDown(key(Scancode.arrowRight)))
            graph.recomposer.commitAll(); graph.computeLayout(width: 500, height: 500)
            let next = calendar.date(byAdding: .day, value: 1, to: last)!
            #expect(focus.focused?.attachments["calendar.day"] as? Date == next && selected == last)
            dispatcher.dispatch(.keyDown(key(Scancode.return)))
            #expect(selected == next)
        }
    }

}
