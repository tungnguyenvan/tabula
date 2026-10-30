import AppKit
import Foundation
import Observation
import TabulaFoundation
import TabulaRedis

/// The key shown in the detail pane.
@MainActor @Observable
final class RedisKeyModel {
    private(set) var key: RedisBytes
    let driver: RedisDriver
    private weak var workspace: RedisWorkspaceModel?

    private(set) var info: RedisKeyInfo?
    private(set) var loading = false
    var error: String?

    // Strings
    private(set) var stringValue: RedisBytes?
    private(set) var stringTruncated = false
    var draft = ""

    // Collections
    private(set) var columns: [String] = []
    private(set) var rows: [[RedisBytes]] = []
    private(set) var next: String?
    private(set) var version = 0

    init(key: RedisBytes, driver: RedisDriver, workspace: RedisWorkspaceModel) {
        self.key = key
        self.driver = driver
        self.workspace = workspace
    }

    var type: RedisKeyType { info?.type ?? .unknown }
    var canEditString: Bool { stringValue?.isText == true && !stringTruncated }
    var hasStringChanges: Bool { canEditString && draft != stringValue?.text }
    var canEditCells: Bool { [.hash, .list, .set, .zset].contains(type) }

    func reload() async {
        loading = true
        defer {
            loading = false
            version += 1
        }
        do {
            let info = try await driver.info(key)
            self.info = info
            if info.type == .unknown {
                error = "This key no longer exists."
                return
            }
            if info.type == .string {
                let value = try await driver.string(key)
                stringValue = value.value
                stringTruncated = value.truncated
                draft = value.value.text ?? value.value.display
            } else {
                let page = try await driver.page(key, type: info.type, after: nil)
                columns = page.columns
                rows = page.rows
                next = page.next
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func loadMore() async {
        guard let next, !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let page = try await driver.page(key, type: type, after: next)
            if page.columns.count > columns.count {
                columns = page.columns
            }
            rows += page.rows.map { row in
                row + Array(repeating: RedisBytes(""), count: max(0, columns.count - row.count))
            }
            self.next = page.next
            version += 1
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func perform(_ action: () async throws -> Void) async {
        do {
            try await action()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        await reload()
        await workspace?.refreshSummary(key)
    }

    func keyWasRenamed(to newKey: RedisBytes) {
        key = newKey
    }

    func saveString() async {
        guard hasStringChanges else { return }
        await perform { try await driver.setString(key, to: RedisBytes(draft)) }
    }

    func formatJSON() {
        guard let data = draft.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data),
            let pretty = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            ),
            let text = String(data: pretty, encoding: .utf8)
        else {
            NSSound.beep()
            return
        }
        draft = text
    }

    func setTTL(seconds: Int?) async {
        await perform { try await driver.setTTL(key, seconds: seconds) }
    }

    func rename(to newName: String) async {
        let newKey = RedisBytes(newName)
        guard !newName.isEmpty, newKey != key else { return }
        do {
            try await driver.rename(key, to: newKey)
            let old = key
            key = newKey
            workspace?.renamed(old, to: newKey)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func isEditable(row: Int, column: Int) -> Bool {
        guard canEditCells, rows.indices.contains(row), rows[row].indices.contains(column), rows[row][column].isText
        else { return false }
        return !(type == .list && column == 0)
    }

    func update(row: Int, column: Int, to value: String?) async {
        guard rows.indices.contains(row) else { return }
        guard isEditable(row: row, column: column) else {
            error =
                type == .list && column == 0
                ? "List indexes can't be edited." : "Binary values can't be edited here; use the console."
            return
        }
        let current = rows[row]
        await perform {
            try await driver.update(
                key,
                type: type,
                element: current[0],
                column: column,
                to: RedisBytes(value ?? ""),
                row: current
            )
        }
    }

    func remove(rows indices: IndexSet) async {
        let elements = indices.filter { rows.indices.contains($0) }.map { rows[$0][0] }
        guard !elements.isEmpty else { return }
        await perform { try await driver.remove(key, type: type, elements: elements) }
    }

    func add(_ values: [String]) async {
        await perform { try await driver.add(key, type: type, values: values.map(RedisBytes.init)) }
    }

    func copyRows(_ indices: IndexSet) -> [[String]] {
        indices.filter { rows.indices.contains($0) }.map { rows[$0].map(\.display) }
    }
}
