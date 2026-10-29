import AppKit
import SwiftUI
import TabulaFoundation
import TabulaMongo
import TabulaSQL
import TabulaTransfer

/// Column / operator / value rows, or a raw SQL condition.
struct FilterBarView: View {
    @Bindable var model: TableTabModel
    @FocusState private var focusedRule: UUID?
    @FocusState private var rawFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.useRawFilter {
                HStack(spacing: 6) {
                    Text(filterKeyword).font(Layout.Font.smallBold.monospaced()).foregroundStyle(.secondary)
                    TextField(
                        isDocument ? "{ age: { $gt: 30 }, status: \"active\" }" : "id > 10 AND status = 'active'",
                        text: $model.filterText
                    )
                    .focused($rawFocused)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .onSubmit { Task { await model.applyFilter() } }
                    controls
                }
            } else {
                ForEach($model.filterRules) { $rule in
                    HStack(spacing: 6) {
                        Toggle("Use condition", isOn: $rule.isEnabled)
                            .toggleStyle(.checkbox)
                            .labelsHidden()
                            .help("Use this condition. Unticked ones stay here but are left out when you apply.")
                        if rule.id == leadingRuleID {
                            Text(filterKeyword).font(Layout.Font.smallBold.monospaced()).foregroundStyle(.secondary)
                                .frame(width: Layout.Filter.conjunctionWidth, alignment: .leading)
                        } else {
                            Picker("Join", selection: $rule.conjunction) {
                                ForEach(FilterRule.Conjunction.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .labelsHidden()
                            .frame(width: Layout.Filter.conjunctionWidth)
                            .help("AND binds tighter than OR: a AND b OR c means (a AND b) OR c")
                        }
                        Picker("Column", selection: $rule.column) {
                            ForEach(model.resultColumns, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: Layout.Filter.columnWidth)
                        Picker("Operator", selection: $rule.op) {
                            ForEach(FilterRule.Operator.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: Layout.Filter.operatorWidth)
                        TextField(rule.op == .inList ? "a, b, c" : "Value", text: $rule.value)
                            .focused($focusedRule, equals: rule.id)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                            .disabled(!rule.op.needsValue)
                            .onSubmit { Task { await model.applyFilter() } }
                        BarButton(symbol: "minus.circle", help: "Remove condition") {
                            model.filterRules.removeAll { $0.id == rule.id }
                        }
                        BarButton(symbol: "plus.circle", help: "Add condition") { model.addFilterRule() }
                        if rule.id == model.filterRules.first?.id {
                            controls
                        }
                    }
                }
                if model.filterRules.isEmpty {
                    HStack {
                        Button("Add Condition") { model.addFilterRule() }
                        Spacer()
                        controls
                    }
                }
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color(nsColor: .controlBackgroundColor))
        .onAppear(perform: focusValue)
        .onChange(of: model.filterFocusRequest) { _, _ in focusValue() }
        .onExitCommand { model.showFilterBar = false }  // Esc closes the bar; the applied filter stays.
    }

    /// The rule that opens the condition: the first ticked one, whose AND/OR would join nothing.
    private var leadingRuleID: UUID? {
        model.filterRules.first(where: \.isEnabled)?.id ?? model.filterRules.first?.id
    }

    private var isDocument: Bool { model.driver.kind.isDocument }
    private var filterKeyword: String { isDocument ? "FIND" : "WHERE" }

    private func focusValue() {
        DispatchQueue.main.async {
            if model.useRawFilter {
                rawFocused = true
            } else {
                focusedRule = model.filterRules.last?.id
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 6) {
            Toggle(isDocument ? "{ }" : "SQL", isOn: $model.useRawFilter)
                .toggleStyle(.button)
                .help(isDocument ? "Write the query document by hand" : "Write the WHERE condition by hand")
            Button("Apply") { Task { await model.applyFilter() } }
                .keyboardShortcut(.defaultAction)
            if model.isFiltered {
                Button("Clear") { Task { await model.clearFilter() } }
            }
        }
    }
}
