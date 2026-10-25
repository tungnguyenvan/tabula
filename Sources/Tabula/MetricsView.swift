import Charts
import SwiftUI
import TabulaCore

/// Polls a metrics source and keeps a short history for charts.
@MainActor @Observable
final class MetricsModel {
    struct Point: Identifiable {
        let id = UUID()
        let time: Date
        let series: String
        let value: Double
    }

    let id = UUID()
    private let source: @Sendable () async throws -> MetricsSample
    private(set) var latest: MetricsSample?
    private(set) var points: [Point] = []
    private(set) var rates: [String: Double] = [:]
    private(set) var error: String?
    var interval: Double = 3
    var paused = false
    private var previous: MetricsSample?
    private var loop: Task<Void, Never>?

    init(source: @escaping @Sendable () async throws -> MetricsSample) {
        self.source = source
    }

    /// Series names in a stable order: rates first, then gauges.
    var seriesNames: [String] {
        guard let latest else { return [] }
        return latest.counters.keys.sorted() + latest.gauges.keys.sorted()
    }

    func start() {
        guard loop == nil else { return }
        // Holds the model only while ticking, so a model whose view never sent onDisappear still goes away.
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = await self?.tick() else { return }
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    private func tick() async -> Double {
        if !paused { await refresh() }
        return interval
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    func refresh() async {
        do {
            let sample = try await source()
            if let previous {
                let elapsed = sample.time.timeIntervalSince(previous.time)
                if elapsed > 0 {
                    var current: [String: Double] = [:]
                    for (name, value) in sample.counters {
                        // Counters reset on server restart; skip negative deltas.
                        guard let old = previous.counters[name], value >= old else { continue }
                        let rate = (value - old) / elapsed
                        current[name] = rate
                        points.append(Point(time: sample.time, series: name, value: rate))
                    }
                    rates = current
                }
            }
            for (name, value) in sample.gauges { points.append(Point(time: sample.time, series: name, value: value)) }
            let cutoff = sample.time.addingTimeInterval(-600)
            points.removeAll { $0.time < cutoff }
            previous = sample
            latest = sample
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct MetricsView: View {
    @Bindable var model: MetricsModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Server metrics").font(.headline)
                if let time = model.latest?.time {
                    Text("updated \(time.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Every", selection: $model.interval) {
                    ForEach([1.0, 3, 5, 10, 30], id: \.self) { Text("\(Int($0))s").tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .help("Refresh interval")
                Button { model.paused.toggle() } label: {
                    Label(model.paused ? "Resume" : "Pause", systemImage: model.paused ? "play.fill" : "pause.fill")
                }
                Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }.help("Refresh now")
            }
            .controlSize(.small)
            .padding(.horizontal, 12)
            .frame(height: 38)
            Divider()
            if let error = model.error { ErrorBanner(message: error) {} }
            if let sample = model.latest {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        charts
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12, alignment: .top)], spacing: 12) {
                            ForEach(sample.groups) { group in card(group) }
                        }
                        if !sample.tables.isEmpty { tables(sample.tables, collections: sample.tablesAreCollections) }
                    }
                    .padding(14)
                }
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    @ViewBuilder
    private var charts: some View {
        let names = model.seriesNames
        if !names.isEmpty {
            let bySeries = Dictionary(grouping: model.points, by: \.series)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
                ForEach(names, id: \.self) { name in
                    let points = bySeries[name] ?? []
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(name).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text(format(points.last?.value)).font(.system(size: 18, weight: .semibold).monospacedDigit())
                        }
                        Chart(points) { point in
                            AreaMark(x: .value("Time", point.time), y: .value(name, point.value))
                                .foregroundStyle(Color.accentColor.opacity(0.15))
                            LineMark(x: .value("Time", point.time), y: .value(name, point.value))
                                .foregroundStyle(Color.accentColor)
                        }
                        .chartXAxis(.hidden)
                        .chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) }
                        .frame(height: 70)
                        .overlay {
                            if points.count < 2 { Text("collecting…").font(.caption2).foregroundStyle(.tertiary) }
                        }
                    }
                    .padding(10)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private func format(_ value: Double?) -> String {
        guard let value else { return "—" }
        return value >= 100 ? MetricFormat.number(value) : String(format: "%.1f", value)
    }

    private func card(_ group: MetricsSample.Group) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(group.title).font(.system(size: 12, weight: .semibold))
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                ForEach(group.items, id: \.self) { item in
                    GridRow {
                        Text(item.label).foregroundStyle(.secondary)
                        Text(item.value).textSelection(.enabled).monospacedDigit()
                    }
                }
            }
            .font(.system(size: 12))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    private func tables(_ tables: [MetricsSample.TableStat], collections: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(collections ? "Largest collections" : "Largest tables").font(.system(size: 12, weight: .semibold))
            Table(tables) {
                TableColumn(collections ? "Collection" : "Table") { Text($0.name).font(.system(size: 12, design: .monospaced)) }
                TableColumn(collections ? "Documents" : "Rows (est.)") { Text($0.rows.map { MetricFormat.number(Double($0)) } ?? "—").monospacedDigit() }.width(110)
                TableColumn("Data") { Text(MetricFormat.bytes($0.dataBytes.map(Double.init))).monospacedDigit() }.width(90)
                TableColumn("Indexes") { Text(MetricFormat.bytes($0.indexBytes.map(Double.init))).monospacedDigit() }.width(90)
                TableColumn("Total") { Text(MetricFormat.bytes($0.totalBytes.map(Double.init))).monospacedDigit() }.width(90)
            }
            .frame(height: min(CGFloat(tables.count) * 24 + 32, 420))
        }
    }
}
