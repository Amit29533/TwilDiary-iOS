import Charts
import SwiftUI
import TwilDiaryCore

/// Settings → Cloudflare: today's share of each free-plan allowance, then the last 7 or 30 days.
struct CloudflareUsageView: View {
    @Environment(DiaryStore.self) private var store
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @State private var loader: CloudflareUsageLoader?
    @State private var range = 7
    private static let utc = TimeZone(identifier: "UTC")!
    /// Bars group by UTC day, like the free-plan allowances; the chart's calendar decides that, not its time zone.
    private static let utcCalendar: Calendar = { var calendar = Calendar(identifier: .gregorian); calendar.timeZone = utc; return calendar }()
    private struct Point: Identifiable { let date: Date; let value: Double; var id: Date { date } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let usage = loader?.usage {
                    if let error = loader?.error { Text(error).font(.caption).foregroundStyle(.secondary) }
                    if usage.configured { today(usage); history(usage) } else { setup }
                } else if let error = loader?.error { failure(error) }
                else { ProgressView().frame(maxWidth: .infinity, minHeight: 240) }
            }.padding(16).padding(.bottom, 100)
        }.diaryScreenBackground().navigationTitle("Cloudflare").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
            .refreshable { await loader?.load(range: range) }
            .task(id: range) {
                if loader == nil { loader = CloudflareUsageLoader(store: store) }
                await loader?.load(range: range)
            }
    }

    private func today(_ usage: CloudflareUsage) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Today").font(.system(size: 20, weight: .bold))
                Spacer(minLength: 8)
                if let reset = usage.resetDate {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        let minutes = max(0, Int(reset.timeIntervalSince(context.date) / 60))
                        Label("Resets in \(minutes / 60)h \(minutes % 60)m", systemImage: "arrow.counterclockwise")
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).accessibilityIdentifier("cloudflare-reset")
                    }
                }
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                gauge("Requests", used: usage.today?.requests, limit: usage.limits.requests, key: "requests")
                gauge("D1 reads", used: usage.today?.rowsRead, limit: usage.limits.rowsRead, key: "reads")
                gauge("D1 writes", used: usage.today?.rowsWritten, limit: usage.limits.rowsWritten, key: "writes")
                gauge("Storage", used: usage.storageBytes, limit: usage.limits.storageBytes, bytes: true, key: "storage")
            }
        }
    }

    private func history(_ usage: CloudflareUsage) -> some View {
        let days = usage.days
        let busiest = days.max { $0.rowsRead < $1.rowsRead }
        return VStack(alignment: .leading, spacing: 14) {
            Picker("Range", selection: $range) { Text("7 days").tag(7); Text("30 days").tag(30) }
                .pickerStyle(.segmented).accessibilityIdentifier("cloudflare-range")
            chart("Worker requests", caption: "\(amount(days.reduce(0) { $0 + $1.requests })) total · \(days.reduce(0) { $0 + $1.errors }) errors",
                  points: days.map { Point(date: $0.start, value: Double($0.requests)) }, limit: usage.limits.requests, unavailable: usage.unavailable.contains("workers"), key: "requests")
            chart("D1 rows read", caption: busiest.map { "Peak \(amount($0.rowsRead)) on \($0.start.formatted(Date.FormatStyle(timeZone: Self.utc).month(.abbreviated).day()))" } ?? "",
                  points: days.map { Point(date: $0.start, value: Double($0.rowsRead)) }, limit: usage.limits.rowsRead, unavailable: usage.unavailable.contains("d1"), key: "reads")
            chart("D1 rows written", caption: "\(amount(days.reduce(0) { $0 + $1.rowsWritten })) total",
                  points: days.map { Point(date: $0.start, value: Double($0.rowsWritten)) }, limit: usage.limits.rowsWritten, unavailable: usage.unavailable.contains("d1"), key: "writes")
            chart("Storage", caption: usage.storageBytes.map { "\(amount($0, bytes: true)) of \(amount(usage.limits.storageBytes, bytes: true))" } ?? "",
                  points: days.compactMap { day in day.storageBytes.map { Point(date: day.start, value: Double($0)) } }, limit: usage.limits.storageBytes, bytes: true, line: true,
                  unavailable: usage.unavailable.contains("storage"), key: "storage")
            Text("Free plan allowances reset at 00:00 UTC. Updated " + (DiaryDate.parse(usage.fetchedAt) ?? .now).formatted(.relative(presentation: .named)) + ".")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func gauge(_ title: String, used: Int?, limit: Int, bytes: Bool = false, key: String) -> some View {
        let share = used.map { min(1, Double($0) / Double(max(1, limit))) }
        let tint = level(share ?? 0)
        // The ring leads on the left; the name, amount and allowance read down the right.
        return HStack(spacing: 12) {
            ZStack {
                Circle().stroke(.white.opacity(0.1), lineWidth: 6)
                Circle().trim(from: 0, to: share ?? 0).stroke(tint, style: StrokeStyle(lineWidth: 6, lineCap: .round)).rotationEffect(.degrees(-90))
                Text(share.map(percent) ?? "–").font(.system(size: 13, weight: .semibold)).monospacedDigit()
            }.frame(width: 58, height: 58)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).lineLimit(1)
                Text(used.map { amount($0, bytes: bytes) } ?? "Not yet").font(.system(size: 19, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                Text("of " + amount(limit, bytes: bytes) + (bytes ? "" : " a day")).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.field, in: RoundedRectangle(cornerRadius: 18)).overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.1)))
            .accessibilityElement(children: .combine).accessibilityIdentifier("cloudflare-today-\(key)")
    }

    private func chart(_ title: String, caption: String, points: [Point], limit: Int, bytes: Bool = false, line: Bool = false,
                       unavailable: Bool, key: String) -> some View {
        let cap = Double(limit), peak = max(points.map(\.value).max() ?? 0, 1)
        // The limit line only shows once usage is close enough for it to matter; otherwise bars would flatten.
        let showLimit = peak >= cap * 0.25
        let top = showLimit ? max(peak, cap) * 1.08 : peak * 1.2
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Spacer(minLength: 8)
                Text(unavailable ? "Not available" : caption).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            if unavailable {
                Text("Cloudflare didn't return this for the token.").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 60)
            } else {
                Chart {
                    ForEach(points) { point in
                        if line {
                            AreaMark(x: .value("Day", point.date, unit: .day), y: .value(title, point.value))
                                .foregroundStyle(LinearGradient(colors: [theme.accent.opacity(0.35), theme.accent.opacity(0)], startPoint: .top, endPoint: .bottom))
                            LineMark(x: .value("Day", point.date, unit: .day), y: .value(title, point.value)).foregroundStyle(theme.accent)
                        } else {
                            BarMark(x: .value("Day", point.date, unit: .day), y: .value(title, point.value))
                                .foregroundStyle(point.value / cap >= 0.5 ? level(point.value / cap) : theme.accent).cornerRadius(3)
                        }
                    }
                    if showLimit {
                        RuleMark(y: .value("Limit", cap)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4])).foregroundStyle(Color(webHex: "#ff6b6b").opacity(0.8))
                            .annotation(position: .top, alignment: .leading) { Text("Limit").font(.system(size: 10)).foregroundStyle(Color(webHex: "#ff6b6b")) }
                    }
                }
                .chartYScale(domain: 0...top)
                .chartYAxis {
                    AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                        AxisGridLine().foregroundStyle(.white.opacity(0.08))
                        AxisValueLabel { if let number = value.as(Double.self) { Text(amount(Int(number), bytes: bytes)).font(.system(size: 10)) } }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: range == 7 ? 1 : 7)) { _ in
                        AxisValueLabel(format: Date.FormatStyle(timeZone: Self.utc).day().month(.abbreviated), centered: true).font(.system(size: 10))
                    }
                }
                .environment(\.calendar, Self.utcCalendar).environment(\.timeZone, Self.utc)
                .frame(height: 150).accessibilityHidden(true)
            }
        }.padding(16).background(theme.field, in: RoundedRectangle(cornerRadius: 18)).overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.1)))
            .accessibilityElement(children: .combine).accessibilityLabel(title + ", " + (unavailable ? "not available" : caption))
            .accessibilityIdentifier("cloudflare-chart-\(key)")
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Connect Cloudflare").font(.system(size: 18, weight: .bold))
            Text("Add a read-only analytics token to the server to see usage here.").font(.subheadline).foregroundStyle(.secondary)
            Text("Account Analytics: Read → CF_ANALYTICS_TOKEN").font(.system(size: 13, design: .monospaced))
                .padding(10).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        }.diaryPanel().accessibilityElement(children: .contain).accessibilityIdentifier("cloudflare-setup")
    }

    private func failure(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(message).font(.subheadline).foregroundStyle(.secondary)
            Button { Task { await loader?.load(range: range) } } label: { Label("Try again", systemImage: "arrow.clockwise").frame(maxWidth: .infinity, minHeight: 44) }
                .buttonStyle(.diarySecondary)
        }.diaryPanel().accessibilityIdentifier("cloudflare-error")
    }

    private func level(_ share: Double) -> Color { share < 0.5 ? Color(webHex: "#5fe0b0") : share < 0.8 ? Color(webHex: "#fac775") : Color(webHex: "#ff6b6b") }
    private func percent(_ share: Double) -> String { share > 0 && share < 0.01 ? "<1%" : "\(Int((share * 100).rounded(.down)))%" }
    private func amount(_ value: Int, bytes: Bool = false) -> String {
        bytes ? Int64(value).formatted(.byteCount(style: .decimal)) : value.formatted(.number.notation(.compactName))
    }
}
