// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI
import TersoCore
import TersoDocument

enum WritingStatsTab: String, CaseIterable, Identifiable {
    case overview = "Overview", stories = "Stories", awards = "Awards"
    var id: String { rawValue }
}

@MainActor private var accent: Color { Color(nsColor: Preferences.shared.theme.accent) }

/// Today's typed words in the header, as a ring filling towards the daily goal.
struct TodayButton: View {
    let density: HeaderDensity
    let action: () -> Void

    var body: some View {
        let log = WritingStats.shared.log
        let today = log.words(on: .now)
        Button(action: action) {
            HStack(spacing: 6) {
                GoalRing(fraction: Double(today) / Double(log.dailyGoal), lineWidth: 2.2)
                    .frame(width: 13, height: 13)
                if density != .minimal { Text(today.formatted()).monospacedDigit() }
                if density == .full { Text("today").foregroundStyle(.secondary) }
            }
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 9)
            .frame(minHeight: 22)
            .background(Color.secondary.opacity(0.08), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("\(today.formatted()) of \(log.dailyGoal.formatted()) words typed today. Open writing stats.")
        .accessibilityLabel("Writing stats, \(today) of \(log.dailyGoal) words typed today")
    }
}

/// The latest awards beside today's words, as overlapping badges. Hidden
/// until the first award is earned.
struct AwardStack: View {
    let density: HeaderDensity
    let action: () -> Void

    var body: some View {
        let earned = WritingStats.shared.shown.earned
        let recent = Award.all.filter { earned[$0.id] != nil }
            .sorted { earned[$0.id]! > earned[$1.id]! }
        let shown = recent.prefix(density == .minimal ? 1 : 3)
        if !recent.isEmpty {
            Button(action: action) {
                HStack(spacing: 4) {
                    HStack(spacing: -7) {
                        // Newest on top, leftmost.
                        ForEach(Array(shown.enumerated()), id: \.element.id) { index, award in
                            // Each badge cuts a thin gap out of the one behind it,
                            // so the stack reads on any header theme or material.
                            AwardBadge(symbol: award.symbol, earned: true, size: 18)
                                .background(Circle().padding(-1.5).blendMode(.destinationOut))
                                .zIndex(Double(shown.count - index))
                        }
                    }
                    .compositingGroup()
                    if density == .full, recent.count > shown.count {
                        Text("+\(recent.count - shown.count)").monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 4)
                .frame(minHeight: 22)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("\(recent.count) of \(Award.all.count) awards earned. Latest: \(recent[0].title). Open awards.")
            .accessibilityLabel("Awards, \(recent.count) earned, latest \(recent[0].title)")
        }
    }
}

struct GoalRing: View {
    let fraction: Double
    var lineWidth: CGFloat = 6

    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.22), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(1, max(0, fraction)))
                .stroke(accent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .animation(.easeOut(duration: 0.3), value: fraction)
    }
}

/// The writer's stats, story targets and awards.
struct WritingStatsView: View {
    @State var tab: WritingStatsTab
    @State private var exerciseModel: WorkspaceModel?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Writing").font(.title2.weight(.semibold))
                if Preferences.shared.sampleWritingStats {
                    Text("Sample numbers").font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                        .help("Turn off in Settings › Analysis › Writing stats to see your real record.")
                }
                Spacer()
                Picker("Section", selection: $tab) {
                    ForEach(WritingStatsTab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 280)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24).padding(.vertical, 16)
            Divider()
            Group {
                switch tab {
                case .overview: ScrollView {
                    VStack(spacing: 24) {
                        OverviewTab()
                        if let exerciseModel { ExerciseReportCard(model: exerciseModel) }
                    }.padding(24)
                }
                case .stories: StoriesTab()
                case .awards: ScrollView { AwardsTab().padding(24) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 780, height: 600)
        .background(ExerciseReportContext { exerciseModel = $0 }.frame(width: 0, height: 0).accessibilityHidden(true))
    }
}

// MARK: Overview

private struct OverviewTab: View {
    var body: some View {
        let stats = WritingStats.shared
        let log = stats.shown
        let now = Date.now
        let today = log.words(on: now)
        let streak = log.currentStreak(at: now)
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top, spacing: 12) {
                TodayTile(today: today, goal: log.dailyGoal)
                FeaturedStat(value: "\(streak)", label: streak == 1 ? "day in a row" : "days in a row",
                             detail: "Longest: \(log.longestStreak)")
                    .help("Days with at least \(WritingLog.streakMinimum) words typed")
                FeaturedStat(value: log.week(ending: now).formatted(), label: "words this week",
                             detail: "Best day: \(log.bestDay.formatted())")
                FeaturedStat(value: log.lifetime.formatted(), label: "words typed in Terso",
                             detail: "Best sitting: \(log.bestSitting.formatted())")
            }
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Recent weeks")
                GeometryReader { geo in
                    CalendarHeatmap(log: log, weeks: max(8, Int((geo.size.width + 3) / 16)), now: now)
                }
                .frame(height: 7 * 16 + 20)
            }

            HStack(alignment: .top, spacing: 32) {
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel("When you write")
                    HourBars(hours: log.hours).frame(height: 90)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel("Next awards")
                    ForEach(nextAwards(log)) { AwardProgressRow(award: $0, value: log.value(for: $0.measure)) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text("Terso counts words you type, dictate or compose with an input method — not text you paste, drop in or accept from a suggestion. Revising never takes words away.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func nextAwards(_ log: WritingLog) -> [Award] {
        Award.all.filter { log.earned[$0.id] == nil }
            .sorted { Double(log.value(for: $0.measure)) / Double($0.goal) > Double(log.value(for: $1.measure)) / Double($1.goal) }
            .prefix(3).map { $0 }
    }
}

private struct TodayTile: View {
    let today: Int
    let goal: Int

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                GoalRing(fraction: Double(today) / Double(goal), lineWidth: 6)
                if today >= goal { Image(systemName: "checkmark").font(.system(size: 14, weight: .bold)).foregroundStyle(accent) }
            }
            .frame(width: 46, height: 46)
            VStack(alignment: .leading, spacing: 2) {
                Text(today.formatted()).font(.title.weight(.semibold)).monospacedDigit()
                Text("words today").font(.caption).foregroundStyle(.secondary)
                Stepper(value: Binding(get: { goal }, set: { WritingStats.shared.setDailyGoal($0) }), in: 50...20_000, step: 50) {
                    Text("Goal \(goal.formatted())").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                .controlSize(.mini)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// One square per day, darker as the day nears (and passes) the daily goal.
private struct CalendarHeatmap: View {
    let log: WritingLog
    let weeks: Int
    let now: Date

    var body: some View {
        let calendar = Calendar.current
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? now
        let start = calendar.date(byAdding: .weekOfYear, value: -(weeks - 1), to: thisWeek) ?? now
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 3) {
                ForEach(0..<weeks, id: \.self) { week in
                    VStack(spacing: 3) {
                        ForEach(0..<7, id: \.self) { weekday in
                            let day = calendar.date(byAdding: .day, value: week * 7 + weekday, to: start) ?? now
                            cell(day, future: day > now)
                        }
                    }
                }
            }
            HStack(spacing: 4) {
                Text("Less")
                ForEach([0.0, 0.3, 0.6, 1.0], id: \.self) { level in
                    RoundedRectangle(cornerRadius: 2.5).fill(color(level)).frame(width: 11, height: 11)
                }
                Text("More")
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func cell(_ day: Date, future: Bool) -> some View {
        let words = log.words(on: day)
        let level = words == 0 ? 0 : max(0.2, min(1, Double(words) / Double(log.dailyGoal)))
        return RoundedRectangle(cornerRadius: 2.5)
            .fill(future ? Color.clear : color(level))
            .frame(width: 13, height: 13)
            .help("\(day.formatted(date: .abbreviated, time: .omitted)): \(words.formatted()) words")
    }

    private func color(_ level: Double) -> Color {
        level == 0 ? Color.secondary.opacity(0.12) : accent.opacity(0.25 + 0.75 * level)
    }
}

private struct HourBars: View {
    let hours: [Int]

    var body: some View {
        let peak = max(1, hours.max() ?? 1)
        VStack(spacing: 4) {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<24, id: \.self) { h in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(hours[h] == 0 ? Color.secondary.opacity(0.12) : accent.opacity(0.85))
                        .frame(maxWidth: .infinity)
                        .frame(height: max(2, CGFloat(hours[h]) / CGFloat(peak) * 70))
                        .help("\(h):00 – \(hours[h].formatted()) words")
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
            HStack {
                ForEach(["12am", "6am", "12pm", "6pm"], id: \.self) { Text($0).frame(maxWidth: .infinity, alignment: .leading) }
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

// MARK: Stories

/// A project, a document, or the group of documents in no project.
private struct StoryRow: Identifiable {
    let id: String
    let title: String
    var url: URL?
    var allowsTarget = true
    var children: [StoryRow]?
}

private struct StoriesTab: View {
    @State private var counts: [String: DocumentStatistics] = [:]
    private let stats = WritingStats.shared

    var body: some View {
        let rows = Self.rows()
        VStack(spacing: 0) {
            if rows.isEmpty {
                ContentUnavailableView("No Stories Yet", systemImage: "books.vertical",
                                       description: Text("Documents you open or link to a project appear here, ready for a target."))
            } else {
                Table(rows, children: \.children) {
                    TableColumn("Name") { row in
                        Label(row.title, systemImage: row.children == nil ? "doc.text" : "folder")
                            .fontWeight(row.children == nil ? .regular : .semibold)
                            .lineLimit(1)
                    }
                    .width(min: 180, ideal: 240)
                    TableColumn("Words") { row in number(words(row)) }.width(64)
                    TableColumn("Typed") { row in number(typed(row)).foregroundStyle(.secondary) }.width(64)
                    TableColumn("Target") { row in
                        if row.allowsTarget { TargetField(key: row.id) }
                    }
                    .width(80)
                    TableColumn("Progress") { row in
                        if let target = stats.target(for: row.id), let words = words(row) {
                            TargetProgress(fraction: Double(words) / Double(target))
                        }
                    }
                    .width(min: 100, ideal: 130)
                    TableColumn("Read time") { row in
                        Text(readTime(words(row))).foregroundStyle(.secondary)
                    }
                    .width(70)
                }
                .tableStyle(.inset(alternatesRowBackgrounds: true))
            }
            Text("Typed counts only the words you typed into each document in Terso. Targets are word counts for the whole document or project.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24).padding(.vertical, 10)
        }
        .task { counts = await Self.count(Self.rows()) }
    }

    private func words(_ row: StoryRow) -> Int? {
        if let children = row.children {
            let known = children.compactMap(words)
            return known.isEmpty ? nil : known.reduce(0, +)
        }
        return row.url.flatMap { counts[WritingStats.key($0)]?.words }
    }

    private func typed(_ row: StoryRow) -> Int? {
        if let children = row.children { return children.compactMap(typed).reduce(0, +) }
        return row.url.map(stats.typed(in:))
    }

    private func number(_ n: Int?) -> some View {
        Text(n.map { $0.formatted() } ?? "—").monospacedDigit()
    }

    private func readTime(_ words: Int?) -> String {
        guard let words else { return "" }
        var s = DocumentStatistics()
        s.words = words
        return s.readingTimeLabel
    }

    /// Projects with their documents, then any other document open or typed in.
    @MainActor static func rows() -> [StoryRow] {
        var listed = Set<String>()
        var rows: [StoryRow] = ProjectStore.shared.projects.map { project in
            let documents = project.documents.filter(\.exists).map { document in
                listed.insert(WritingStats.key(document.url))
                return StoryRow(id: WritingStats.key(document.url), title: document.title, url: document.url)
            }
            return StoryRow(id: WritingStats.key(project), title: project.name, children: documents)
        }
        let open = DocumentTabs.shared.workspaces.flatMap(\.documents).compactMap(\.fileURL)
        let typed = WritingStats.shared.log.typed.keys.map { URL(fileURLWithPath: $0) }
        var loose: [StoryRow] = []
        for url in open + typed {
            let key = WritingStats.key(url)
            guard FileManager.default.fileExists(atPath: key), listed.insert(key).inserted else { continue }
            loose.append(StoryRow(id: key, title: url.deletingPathExtension().lastPathComponent, url: url))
        }
        if !loose.isEmpty {
            let sorted = loose.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            rows.append(StoryRow(id: "group:other", title: rows.isEmpty ? "Documents" : "Other Documents", allowsTarget: false, children: sorted))
        }
        return rows
    }

    /// Words in each text document, read from the open tab when there is one.
    @MainActor static func count(_ rows: [StoryRow]) async -> [String: DocumentStatistics] {
        let urls = rows.flatMap { $0.children ?? [$0] }.compactMap(\.url)
        var live: [String: String] = [:]
        for document in DocumentTabs.shared.workspaces.flatMap(\.documents) {
            if let url = document.fileURL { live[WritingStats.key(url)] = document.contents.text }
        }
        return await Task.detached(priority: .utility) {
            var out: [String: DocumentStatistics] = [:]
            for url in urls where ["md", "markdown", "txt", "text", "tex", "terso"].contains(url.pathExtension.lowercased()) {
                let key = WritingStats.key(url)
                let saved = url.pathExtension.lowercased() == "terso"
                    ? (try? TersoPackage.decode(Data(contentsOf: url)).text)
                    : (try? String(contentsOf: url, encoding: .utf8))
                guard let text = live[key] ?? saved else { continue }
                let snapshot = DocumentSnapshot(revision: DocumentRevision(0), text: text, fileName: url.lastPathComponent)
                out[key] = DocumentStatistics(prose: ProseText(snapshot))
            }
            return out
        }.value
    }
}

private struct TargetField: View {
    let key: String
    @State private var text = ""

    var body: some View {
        TextField("", text: $text, prompt: Text("—"))
            .textFieldStyle(.plain)
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .onAppear { text = WritingStats.shared.target(for: key).map { $0.formatted() } ?? "" }
            .onChange(of: text) { _, new in
                let digits = new.filter(\.isNumber)
                WritingStats.shared.setTarget(Int(digits), for: key)
            }
            .accessibilityLabel("Word target")
    }
}

private struct TargetProgress: View {
    let fraction: Double

    var body: some View {
        HStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15))
                    Capsule().fill(fraction >= 1 ? Color.green.opacity(0.8) : accent.opacity(0.8))
                        .frame(width: geo.size.width * min(1, fraction))
                }
            }
            .frame(height: 6)
            Text("\(Int((fraction * 100).rounded()))%")
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)
        }
    }
}

// MARK: Awards

private struct AwardsTab: View {
    var body: some View {
        let log = WritingStats.shared.shown
        let earned = Award.all.filter { log.earned[$0.id] != nil }.count
        VStack(alignment: .leading, spacing: 24) {
            Text("\(earned) of \(Award.all.count) earned").foregroundStyle(.secondary)
            ForEach(Award.Group.allCases) { group in
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel(group.rawValue)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], alignment: .leading, spacing: 12) {
                        ForEach(Award.all.filter { $0.group == group }) { award in
                            AwardCard(award: award, earned: log.earned[award.id], value: log.value(for: award.measure))
                        }
                    }
                }
            }
        }
    }
}

struct AwardBadge: View {
    let symbol: String
    let earned: Bool
    var size: CGFloat = 40

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(earned ? AnyShapeStyle(.white) : AnyShapeStyle(.tertiary))
            .frame(width: size, height: size)
            .background(Circle().fill(earned ? AnyShapeStyle(accent.gradient) : AnyShapeStyle(Color.secondary.opacity(0.1))))
    }
}

private struct AwardCard: View {
    let award: Award
    let earned: Date?
    let value: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AwardBadge(symbol: award.symbol, earned: earned != nil)
            Text(award.title).font(.headline).foregroundStyle(earned == nil ? .secondary : .primary)
            Text(award.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let earned {
                Text(earned.formatted(date: .abbreviated, time: .omitted)).font(.caption2).foregroundStyle(accent)
            } else {
                ProgressView(value: min(1, Double(value) / Double(award.goal)))
                    .tint(accent).controlSize(.small)
                Text("\(min(value, award.goal).formatted()) / \(award.goal.formatted())")
                    .font(.caption2).monospacedDigit().foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
        .background(Color.secondary.opacity(earned == nil ? 0.04 : 0.08), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}

private struct AwardProgressRow: View {
    let award: Award
    let value: Int

    var body: some View {
        HStack(spacing: 10) {
            AwardBadge(symbol: award.symbol, earned: false, size: 28)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(award.title).font(.callout)
                    Spacer()
                    Text("\(value.formatted()) / \(award.goal.formatted())").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                ProgressView(value: min(1, Double(value) / Double(award.goal))).tint(accent).controlSize(.small)
            }
        }
    }
}

/// A quiet note in the corner when an award is earned. It fades on its own.
struct AwardNote: View {
    let award: Award
    let open: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            AwardBadge(symbol: award.symbol, earned: true, size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text("Award earned").font(.caption2).foregroundStyle(.secondary).textCase(.uppercase)
                Text(award.title).font(.headline)
                Text(award.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            .frame(maxWidth: 260, alignment: .leading)
            Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)) }
                .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Dismiss")
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture { open(); dismiss() }
        .task(id: award.id) {
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            dismiss()
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens your awards")
    }

    private func dismiss() {
        withAnimation(.easeOut(duration: 0.3)) { WritingStats.shared.latestAward = nil }
    }
}
