import Cocoa
import SwiftUI
import Foundation

// MARK: - Debug Logging（追加写入，超 1MB 自动轮转，位于 Application Support）
var logFileURL: URL {
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("双色球推演器", isDirectory: true)
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/双色球推演器")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("ssq_debug.log")
}

func debugLog(_ message: String) {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
    let timestamp = formatter.string(from: Date())
    let line = "[\(timestamp)] \(message)\n"
    let url = logFileURL
    if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
       let size = attrs[.size] as? Int, size > 1_000_000 {
        try? FileManager.default.removeItem(at: url)
    }
    guard let data = line.data(using: .utf8) else { return }
    if let handle = try? FileHandle(forWritingTo: url) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    } else {
        try? data.write(to: url, options: .atomic)
    }
    NSLog("%@", message)
}

// MARK: - Data Models
struct Record: Codable {
    let issue: String
    let date: String
    let red: [Int]
    let blue: Int
}

struct Prediction: Codable, Identifiable {
    var id: Int
    var issue: String
    var method: String
    var predictedRed: [Int]
    var predictedBlue: Int
    var actualRed: [Int]?
    var actualBlue: Int?
    var matchedRed: Int
    var matchedBlue: Int
    var prize: String
    var autoCompared: Bool
    var recordTime: String
    var note: String

    enum CodingKeys: String, CodingKey {
        case id, issue, method, predictedRed, predictedBlue, actualRed, actualBlue,
             matchedRed, matchedBlue, prize, autoCompared, recordTime, note
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        issue = try container.decode(String.self, forKey: .issue)
        method = try container.decode(String.self, forKey: .method)
        predictedRed = try container.decode([Int].self, forKey: .predictedRed)
        predictedBlue = try container.decode(Int.self, forKey: .predictedBlue)
        actualRed = try container.decodeIfPresent([Int].self, forKey: .actualRed)
        actualBlue = try container.decodeIfPresent(Int.self, forKey: .actualBlue)
        matchedRed = try container.decodeIfPresent(Int.self, forKey: .matchedRed) ?? 0
        matchedBlue = try container.decodeIfPresent(Int.self, forKey: .matchedBlue) ?? 0
        prize = try container.decodeIfPresent(String.self, forKey: .prize) ?? "待开奖"
        autoCompared = try container.decodeIfPresent(Bool.self, forKey: .autoCompared) ?? false
        recordTime = try container.decodeIfPresent(String.self, forKey: .recordTime) ?? ""
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
    }

    init(id: Int, issue: String, method: String, predictedRed: [Int], predictedBlue: Int,
         actualRed: [Int]? = nil, actualBlue: Int? = nil, matchedRed: Int = 0, matchedBlue: Int = 0,
         prize: String = "待开奖", autoCompared: Bool = false, recordTime: String = "", note: String = "") {
        self.id = id
        self.issue = issue
        self.method = method
        self.predictedRed = predictedRed
        self.predictedBlue = predictedBlue
        self.actualRed = actualRed
        self.actualBlue = actualBlue
        self.matchedRed = matchedRed
        self.matchedBlue = matchedBlue
        self.prize = prize
        self.autoCompared = autoCompared
        self.recordTime = recordTime
        self.note = note
    }
}

struct MethodStat: Codable, Identifiable {
    let id: String
    var method: String
    var hitCount: Int
    var totalCount: Int
    var hitRate: Double
    var weight: Double
}

// MARK: - Rolling Backtest（滚动回测）
struct MethodBacktestResult: Codable {
    let method: String
    var periods: Int        // 实际回测期数
    var redHits: Int        // 红球总命中数
    var blueHits: Int       // 蓝球命中次数
    var avgRedHit: Double   // 平均每期命中红球数（0-6）
    var blueHitRate: Double // 蓝球命中率（0-1）
    var prizeCounts: [String: Int] // 中奖等级 -> 次数
    var score: Double       // 综合得分
}

extension MethodBacktestResult: Identifiable {
    var id: String { method }
}

/// 滚动回测引擎：对最近 N 期逐期复盘，每期只用该期之前的历史数据推演，
/// 再与实际开奖比对，累计各方法（含综合推演）的真实命中表现。
struct BacktestEngine {
    static let minTrainingDraws = 30
    static let prizeWeights: [String: Double] = ["一等奖": 100, "二等奖": 50, "三等奖": 20, "四等奖": 5, "五等奖": 2, "六等奖": 1]

    static func availablePeriods(records: [Record]) -> Int {
        max(0, records.count - minTrainingDraws)
    }

    /// - Parameters:
    ///   - records: 按期号降序的开奖记录（records[0] 最新）
    ///   - requested: 要回测的期数，<=0 表示全部可用期数
    ///   - weights: 当前方法权重（回测同时反映权重设置的效果）
    ///   - progress: (已完成, 总数)，在后台线程回调
    static func run(records: [Record],
                    periods requested: Int,
                    weights: [String: MethodStat],
                    progress: ((Int, Int) -> Void)? = nil) -> [MethodBacktestResult] {
        let available = availablePeriods(records: records)
        guard available > 0 else { return [] }
        let periods = requested <= 0 ? available : min(requested, available)

        let predictor = Predictor()
        predictor.loadWeights(from: weights)

        struct Acc {
            var redHits = 0
            var blueHits = 0
            var prizes: [String: Int] = [:]
        }
        var acc: [String: Acc] = [:]
        var testedPeriods = 0

        for i in 0..<periods {
            let actual = records[i]
            let train = Array(records[(i + 1)...])
            guard train.count >= minTrainingDraws else { break }

            let result = predictor.predictForBacktest(records: train)

            func accumulate(method: String, red: [Int], blue: Int) {
                var a = acc[method] ?? Acc()
                let redMatch = Set(red).intersection(Set(actual.red)).count
                let blueMatch = blue == actual.blue ? 1 : 0
                a.redHits += redMatch
                a.blueHits += blueMatch
                let prize = DataStore.prizeLevel(redMatch: redMatch, blueMatch: blueMatch)
                if prize != "未中奖" {
                    a.prizes[prize, default: 0] += 1
                }
                acc[method] = a
            }

            for m in result.methodResults {
                accumulate(method: m.method, red: m.red, blue: m.blue)
            }
            accumulate(method: DataStore.comprehensiveMethod, red: result.red, blue: result.blue)

            testedPeriods += 1
            if (i + 1) == periods || (i + 1) % 25 == 0 {
                progress?(i + 1, periods)
            }
        }

        guard testedPeriods > 0 else { return [] }

        var results: [MethodBacktestResult] = []
        for (method, a) in acc {
            let avgRed = Double(a.redHits) / Double(testedPeriods)
            let blueRate = Double(a.blueHits) / Double(testedPeriods)
            let prizeScore = a.prizes.reduce(0.0) { $0 + Double($1.value) * (prizeWeights[$1.key] ?? 0) } / Double(testedPeriods)
            // 得分 = 平均红球命中 + 蓝球命中率×3 + 加权中奖率
            let score = avgRed + blueRate * 3.0 + prizeScore
            results.append(MethodBacktestResult(
                method: method,
                periods: testedPeriods,
                redHits: a.redHits,
                blueHits: a.blueHits,
                avgRedHit: avgRed,
                blueHitRate: blueRate,
                prizeCounts: a.prizes,
                score: score
            ))
        }
        return results.sorted { $0.score > $1.score }
    }
}

// MARK: - DataStore
class DataStore: ObservableObject {
    static let comprehensiveMethod = "综合推演"

    @Published var records: [Record] = []
    @Published var predictions: [Prediction] = []
    @Published var predictionSteps: [String] = []
    @Published var latestPrediction: Prediction?
    @Published var isPredicting = false
    @Published var fetchStatus = ""
    @Published var optimizeStatus = ""
    @Published var methodStats: [String: MethodStat] = [:]
    @Published var backtestResults: [MethodBacktestResult] = []
    @Published var isBacktesting = false
    @Published var backtestProgress: Double = 0
    @Published var backtestStatus = ""

    private let historyPath: String
    private let backtestPath: String
    private let statsPath: String
    private let reportPath: String

    init() {
        let dir = Self.dataDirectory()
        historyPath = dir.appendingPathComponent("history.json").path
        backtestPath = dir.appendingPathComponent("backtest.json").path
        statsPath = dir.appendingPathComponent("method_stats.json").path
        reportPath = dir.appendingPathComponent("backtest_report.json").path
        migrateLegacyDataIfNeeded()
        loadHistory()
        loadPredictions()
        loadMethodStats()
        loadBacktestReport()
    }

    /// 数据统一存放在 Application Support，避免写入 .app bundle（会破坏签名）或硬编码用户路径
    static func dataDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("双色球推演器", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 首次运行时迁移旧数据：history 取候选中期数最多的一份，其余从 Documents 拷贝
    private func migrateLegacyDataIfNeeded() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: historyPath) {
            var candidates: [URL] = []
            if let bundled = Bundle.main.url(forResource: "history", withExtension: "json") {
                candidates.append(bundled)
            }
            candidates.append(Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/history.json"))
            candidates.append(Bundle.main.bundleURL.appendingPathComponent("history.json")) // 直接运行二进制时同目录
            candidates.append(fm.homeDirectoryForCurrentUser.appendingPathComponent("Documents/history.json"))
            var best: (url: URL, count: Int)?
            for url in candidates where fm.fileExists(atPath: url.path) {
                let count = (try? JSONDecoder().decode([Record].self, from: Data(contentsOf: url)))?.count ?? 0
                if best == nil || count > best!.count { best = (url, count) }
            }
            if let best = best {
                try? fm.copyItem(at: best.url, to: URL(fileURLWithPath: historyPath))
                debugLog("[SSQ] Migrated history (\(best.count) records) from \(best.url.path)")
            }
        }
        for (target, name) in [(backtestPath, "backtest.json"), (statsPath, "method_stats.json")] {
            if !fm.fileExists(atPath: target) {
                let legacy = fm.homeDirectoryForCurrentUser.appendingPathComponent("Documents/\(name)")
                if fm.fileExists(atPath: legacy.path) {
                    try? fm.copyItem(at: legacy, to: URL(fileURLWithPath: target))
                    debugLog("[SSQ] Migrated \(name) from Documents")
                }
            }
        }
    }

    func loadHistory() {
        guard FileManager.default.fileExists(atPath: historyPath) else {
            debugLog("[SSQ] No history file found at \(historyPath)")
            return
        }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: historyPath))
            records = try JSONDecoder().decode([Record].self, from: data)
            debugLog("[SSQ] Loaded \(records.count) history records from \(historyPath)")
        } catch {
            debugLog("[SSQ] Error loading history: \(error)")
        }
    }

    func saveHistory() {
        do {
            let data = try JSONEncoder().encode(records)
            try data.write(to: URL(fileURLWithPath: historyPath))
            debugLog("[SSQ] Saved \(records.count) history records")
        } catch {
            debugLog("[SSQ] Error saving history: \(error)")
        }
    }

    func loadPredictions() {
        guard FileManager.default.fileExists(atPath: backtestPath) else {
            predictions = []
            debugLog("[SSQ] No backtest.json found, predictions = []")
            return
        }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: backtestPath))
            predictions = try JSONDecoder().decode([Prediction].self, from: data)
            debugLog("[SSQ] Loaded \(predictions.count) predictions from \(backtestPath)")
        } catch {
            predictions = []
            debugLog("[SSQ] Error loading predictions: \(error)")
        }
    }

    func savePredictions() {
        do {
            let data = try JSONEncoder().encode(predictions)
            try data.write(to: URL(fileURLWithPath: backtestPath))
            debugLog("[SSQ] Saved \(predictions.count) predictions to \(backtestPath)")
        } catch {
            debugLog("[SSQ] Error saving predictions: \(error)")
        }
    }

    func loadMethodStats() {
        guard FileManager.default.fileExists(atPath: statsPath) else {
            methodStats = [:]
            return
        }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: statsPath))
            methodStats = try JSONDecoder().decode([String: MethodStat].self, from: data)
            debugLog("[SSQ] Loaded method stats for \(methodStats.count) methods")
        } catch {
            methodStats = [:]
            debugLog("[SSQ] Error loading method stats: \(error)")
        }
    }

    func saveMethodStats() {
        do {
            let data = try JSONEncoder().encode(methodStats)
            try data.write(to: URL(fileURLWithPath: statsPath))
            debugLog("[SSQ] Saved method stats")
        } catch {
            debugLog("[SSQ] Error saving method stats: \(error)")
        }
    }

    func deletePredictionById(_ id: Int) {
        predictions.removeAll { $0.id == id }
        savePredictions()
    }

    func clearAllPredictions() {
        predictions = []
        savePredictions()
        methodStats = [:]
        saveMethodStats()
        debugLog("[SSQ] Cleared all predictions and stats")
    }

    func calculateMethodStats() {
        guard !predictions.isEmpty else { return }
        let compared = predictions.filter { $0.autoCompared }
        guard !compared.isEmpty else { return }

        let predictor = Predictor()
        let methods = predictor.methodNames
        var stats: [String: (hits: Int, total: Int)] = [:]
        for m in methods {
            stats[m] = (0, 0)
        }

        for pred in compared {
            let method = pred.method
            if stats[method] != nil {
                let total = stats[method]!.total + 1
                let hits = stats[method]!.hits + (pred.matchedRed > 0 || pred.matchedBlue > 0 ? 1 : 0)
                stats[method] = (hits, total)
            }
        }

        var newStats: [String: MethodStat] = [:]
        for (method, data) in stats {
            let rate = data.total > 0 ? Double(data.hits) / Double(data.total) : 0
            let currentWeight = methodStats[method]?.weight ?? predictor.defaultWeight
            newStats[method] = MethodStat(
                id: method,
                method: method,
                hitCount: data.hits,
                totalCount: data.total,
                hitRate: rate,
                weight: currentWeight
            )
        }
        methodStats = newStats
        saveMethodStats()
    }

    func optimizeWeights() {
        calculateMethodStats()
        let total = methodStats.values.reduce(0) { $0 + $1.weight }
        guard total > 0 else { return }

        for (key, stat) in methodStats {
            if stat.totalCount > 0 {
                let baseWeight = 1.0
                let adjusted = baseWeight + stat.hitRate * 2.0
                methodStats[key]?.weight = min(max(adjusted, 0.5), 3.0)
            }
        }
        saveMethodStats()
        debugLog("[SSQ] Weights optimized for \(methodStats.count) methods")
        optimizeStatus = "✅ 权重已优化，命中率高的方法权重更高"
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            self.optimizeStatus = ""
        }
    }

    func updateMethodWeight(_ method: String, weight: Double) {
        methodStats[method]?.weight = weight
        saveMethodStats()
        debugLog("[SSQ] Updated weight for \(method): \(weight)")
    }

    func fetchLatestDraws() {
        fetchStatus = "正在获取最新数据..."

        fetchFrom17500 { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let newRecords):
                    debugLog("[SSQ] e.17500.cn: fetched \(newRecords.count) records, latest=\(newRecords.first?.issue ?? "nil")")
                    guard !newRecords.isEmpty else {
                        self.fetchStatus = "❌ 数据源返回为空，使用本地数据"
                        return
                    }
                    let existingIssues = Set(self.records.map { $0.issue })
                    var addedCount = 0
                    for record in newRecords where !existingIssues.contains(record.issue) {
                        self.records.append(record)
                        addedCount += 1
                        debugLog("[SSQ] Added record: issue=\(record.issue)")
                    }
                    self.records.sort { $0.issue > $1.issue }
                    self.saveHistory()
                    if addedCount > 0 {
                        self.fetchStatus = "✅ 更新成功！新增 \(addedCount) 期数据"
                        self.autoCompareWithLatestDraws() // 新开奖到达后立即比对历史预测
                    } else {
                        self.fetchStatus = "✅ 数据已是最新（\(self.records.count) 期）"
                    }
                case .failure(let error):
                    self.fetchStatus = "❌ 网络获取失败（\(error.localizedDescription)），使用本地数据"
                    debugLog("[SSQ] Fetch failed: \(error)")
                }
            }
        }
    }

    func fetchFrom17500(completion: @escaping (Result<[Record], Error>) -> Void) {
        guard let url = URL(string: "https://e.17500.cn/getData/ssq.TXT") else {
            completion(.failure(NSError(domain: "URL", code: -1, userInfo: nil)))
            return
        }

        URLSession.shared.dataTask(with: url) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }

            guard let data = data else {
                completion(.failure(NSError(domain: "No data", code: -1, userInfo: nil)))
                return
            }

            let text = String(data: data, encoding: .utf8) ?? ""
            var records: [Record] = []

            for line in text.components(separatedBy: .newlines) {
                let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ")
                guard parts.count >= 9 else { continue }

                let issue = String(parts[0])
                let date = String(parts[1])

                var red: [Int] = []
                for i in 2..<8 {
                    if let num = Int(parts[i]) { red.append(num) }
                }

                guard red.count == 6 else { continue }

                let blue = Int(parts[8]) ?? 0

                // 基本合法性校验，防止反爬页面被误解析成脏数据
                guard issue.count == 7,
                      red.allSatisfy({ (1...33).contains($0) }),
                      (1...16).contains(blue) else { continue }

                records.append(Record(issue: issue, date: date, red: red, blue: blue))
            }

            records.sort { $0.issue > $1.issue }
            completion(.success(records))
        }.resume()
    }

    static func prizeLevel(redMatch: Int, blueMatch: Int) -> String {
        switch (redMatch, blueMatch) {
        case (6, 1): return "一等奖"
        case (6, 0): return "二等奖"
        case (5, 1): return "三等奖"
        case (5, 0), (4, 1): return "四等奖"
        case (4, 0), (3, 1): return "五等奖"
        case (_, 1): return "六等奖"
        default: return "未中奖"
        }
    }

    /// 与全部已有开奖比对（而不仅是最新一期），补齐所有「待开奖」预测
    func autoCompareWithLatestDraws() {
        guard !records.isEmpty, !predictions.isEmpty else { return }
        let drawByIssue = Dictionary(records.map { ($0.issue, $0) }, uniquingKeysWith: { first, _ in first })
        var changed = false
        for i in 0..<predictions.count where !predictions[i].autoCompared {
            guard let draw = drawByIssue[predictions[i].issue] else { continue }
            let redMatch = Set(predictions[i].predictedRed).intersection(Set(draw.red)).count
            let blueMatch = predictions[i].predictedBlue == draw.blue ? 1 : 0

            predictions[i].actualRed = draw.red
            predictions[i].actualBlue = draw.blue
            predictions[i].matchedRed = redMatch
            predictions[i].matchedBlue = blueMatch
            predictions[i].prize = Self.prizeLevel(redMatch: redMatch, blueMatch: blueMatch)
            predictions[i].autoCompared = true
            changed = true
            debugLog("[SSQ] Compared \(predictions[i].issue)/\(predictions[i].method): \(redMatch)红\(blueMatch)蓝 -> \(predictions[i].prize)")
        }
        if changed { savePredictions() }
    }

    func calculateNextIssue(from latestIssue: String) -> String {
        let year = Int(latestIssue.prefix(4)) ?? Calendar.current.component(.year, from: Date())
        let num = Int(latestIssue.suffix(3)) ?? 0
        let nextNum = num + 1

        // 双色球每年约 150 期（每周 3 期），跨年边界为近似值
        if nextNum > 150 {
            return String(format: "%04d001", year + 1)
        }
        return String(format: "%04d%03d", year, nextNum)
    }

    // MARK: - Rolling Backtest（滚动回测）
    func availableBacktestPeriods() -> Int {
        BacktestEngine.availablePeriods(records: records)
    }

    func runRollingBacktest(periods requested: Int) {
        guard !isBacktesting, records.count > BacktestEngine.minTrainingDraws else { return }
        isBacktesting = true
        backtestProgress = 0
        backtestStatus = "准备回测..."
        backtestResults = []

        // 主线程快照，避免后台读取期间数据被修改
        let recordsSnapshot = records
        let weightsSnapshot = methodStats

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let results = BacktestEngine.run(records: recordsSnapshot, periods: requested, weights: weightsSnapshot) { done, total in
                DispatchQueue.main.async {
                    guard let self = self, self.isBacktesting else { return }
                    self.backtestProgress = total > 0 ? Double(done) / Double(total) : 0
                    self.backtestStatus = "回测进度 \(done)/\(total)"
                }
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.backtestResults = results
                self.saveBacktestReport()
                let periods = results.first?.periods ?? 0
                self.backtestStatus = "✅ 回测完成：\(results.count) 个方法 × \(periods) 期（点击「得分→权重」可应用结果）"
                self.backtestProgress = 1
                self.isBacktesting = false
            }
        }
    }

    /// 将回测得分归一化后写入方法权重（0.5 ~ 3.0），下次推演生效
    func applyBacktestWeights() {
        let methodResults = backtestResults.filter { $0.method != DataStore.comprehensiveMethod }
        guard !methodResults.isEmpty else { return }
        let maxScore = methodResults.map { $0.score }.max() ?? 0
        for r in methodResults {
            let normalized = maxScore > 0 ? r.score / maxScore : 0
            let weight = 0.5 + normalized * 2.5
            if methodStats[r.method] != nil {
                methodStats[r.method]?.weight = weight
            } else {
                methodStats[r.method] = MethodStat(
                    id: r.method,
                    method: r.method,
                    hitCount: r.blueHits,
                    totalCount: r.periods,
                    hitRate: r.blueHitRate,
                    weight: weight
                )
            }
        }
        saveMethodStats()
        debugLog("[SSQ] Applied backtest scores as weights for \(methodResults.count) methods")
        optimizeStatus = "✅ 回测得分已写入方法权重（下次推演生效）"
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            self.optimizeStatus = ""
        }
    }

    func saveBacktestReport() {
        do {
            let data = try JSONEncoder().encode(backtestResults)
            try data.write(to: URL(fileURLWithPath: reportPath))
            debugLog("[SSQ] Saved backtest report (\(backtestResults.count) methods)")
        } catch {
            debugLog("[SSQ] Error saving backtest report: \(error)")
        }
    }

    func loadBacktestReport() {
        guard FileManager.default.fileExists(atPath: reportPath) else { return }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: reportPath))
            backtestResults = try JSONDecoder().decode([MethodBacktestResult].self, from: data)
            if let first = backtestResults.first {
                backtestStatus = "上次回测：\(backtestResults.count) 个方法 × \(first.periods) 期"
                debugLog("[SSQ] Loaded backtest report (\(backtestResults.count) methods)")
            }
        } catch {
            debugLog("[SSQ] Error loading backtest report: \(error)")
        }
    }
}

// MARK: - Predictor
class Predictor {
    let defaultWeight = 1.0
    private var weights: [String: Double] = [:]

    var methodNames: [String] {
        return [
            "热号追踪", "冷号回补", "区间分布", "奇偶平衡", "质数筛选",
            "和值分析", "跨度分析", "AC值分析", "连号分析", "重号分析",
            "尾数分布", "遗漏分析", "号码关联", "蓝球热号", "蓝球冷号",
            "蓝球奇偶"
        ]
    }

    init() {
        for m in methodNames {
            weights[m] = defaultWeight
        }
    }

    func loadWeights(from stats: [String: MethodStat]) {
        for (key, stat) in stats {
            weights[key] = stat.weight
        }
    }

    /// 每个方法独立推算出一注完整号码
    func getMethodPredictions(records: [Record], steps: inout [String]) -> [(method: String, red: [Int], blue: Int, detail: String)] {
        var results: [(method: String, red: [Int], blue: Int, detail: String)] = []
        let recent = Array(records.prefix(50))
        let recentRed = recent.flatMap { $0.red }
        let recentBlue = recent.map { $0.blue }
        let latestDraw = records.first
        let latestRed = Set(latestDraw?.red ?? [])
        let latestBlue = latestDraw?.blue ?? 0

        for (index, methodName) in methodNames.enumerated() {
            var redVotes: [Int: Double] = [:]
            var blueVotes: [Int: Double] = [:]
            for i in 1...33 { redVotes[i] = 0 }
            for i in 1...16 { blueVotes[i] = 0 }

            let weight = weights[methodName] ?? defaultWeight
            var detail: [String] = []

            switch methodName {
            case "热号追踪":
                let freq = Dictionary(grouping: recentRed, by: { $0 }).mapValues { $0.count }
                let hotNums = freq.filter { $0.value >= 2 }.sorted { $0.value > $1.value }.prefix(8).map { $0.key }
                for num in hotNums {
                    redVotes[num] = Double(freq[num]!) * 0.5 * weight
                }
                let blueFreq = Dictionary(grouping: recentBlue, by: { $0 }).mapValues { $0.count }
                let hotBlue = blueFreq.filter { $0.value >= 2 }.map { $0.key }
                for num in hotBlue {
                    blueVotes[num] = Double(blueFreq[num]!) * 0.5 * weight
                }
                let hotStr = hotNums.prefix(6).map { "\($0)" }.joined(separator: ",")
                let blueStr = hotBlue.prefix(3).map { "\($0)" }.joined(separator: ",")
                detail = ["热号: \(hotStr)", "蓝球热号: \(blueStr)"]

            case "冷号回补":
                let coldNums = (1...33).filter { !Set(recentRed).contains($0) }
                for num in coldNums {
                    redVotes[num] = weight * 0.4
                }
                let coldBlues = (1...16).filter { !Set(recentBlue).contains($0) }
                for num in coldBlues {
                    blueVotes[num] = weight * 0.3
                }
                let coldStr = coldNums.prefix(10).map { "\($0)" }.joined(separator: ",")
                detail = ["冷号: \(coldStr)"]

            case "区间分布":
                let zone1 = recentRed.filter { $0 <= 11 }.count
                let zone2 = recentRed.filter { $0 >= 12 && $0 <= 22 }.count
                let zone3 = recentRed.filter { $0 >= 23 }.count
                detail = ["区间: 一区\(zone1)个 二区\(zone2)个 三区\(zone3)个"]
                if zone1 < 2 { for i in 1...11 { redVotes[i]! += 0.3 * weight } }
                if zone2 < 2 { for i in 12...22 { redVotes[i]! += 0.3 * weight } }
                if zone3 < 2 { for i in 23...33 { redVotes[i]! += 0.3 * weight } }

            case "奇偶平衡":
                let odd = recentRed.prefix(6).filter { $0 % 2 == 1 }.count
                let even = 6 - odd
                detail = ["上期奇偶: \(odd)奇:\(even)偶"]
                if odd > even { for i in stride(from: 2, to: 34, by: 2) { redVotes[i]! += 0.25 * weight } }
                else { for i in stride(from: 1, to: 34, by: 2) { redVotes[i]! += 0.25 * weight } }

            case "质数筛选":
                let primes = [2,3,5,7,11,13,17,19,23,29,31]
                let lastPrimes = recentRed.prefix(6).filter { primes.contains($0) }
                detail = ["上期质数: \(lastPrimes.map { "\($0)" }.joined(separator: ",")) (\(lastPrimes.count)个)"]
                if lastPrimes.count < 2 { for p in primes { redVotes[p]! += 0.2 * weight } }

            case "和值分析":
                let sums = records.prefix(30).map { $0.red.reduce(0, +) }
                let avgSum = sums.isEmpty ? 100 : sums.reduce(0, +) / sums.count
                let lastSum = latestDraw?.red.reduce(0, +) ?? 102
                detail = ["和值: 平均\(avgSum) 上期\(lastSum)"]
                if lastSum > avgSum + 20 { for i in 1...20 { redVotes[i]! += 0.15 * weight } }
                else if lastSum < avgSum - 20 { for i in 15...33 { redVotes[i]! += 0.15 * weight } }

            case "跨度分析":
                if let last = latestDraw {
                    let span = (last.red.last ?? 33) - (last.red.first ?? 1)
                    detail = ["跨度: \(span)"]
                    if span > 25 { for i in 1...10 { redVotes[i]! += 0.2 * weight } }
                    else if span < 15 { for i in 20...33 { redVotes[i]! += 0.2 * weight } }
                }

            case "AC值分析":
                detail = ["AC值: 复杂度均衡"]
                for i in 1...33 { redVotes[i]! += 0.05 * weight }

            case "连号分析":
                if let lastDraw = latestDraw {
                    let sorted = lastDraw.red.sorted()
                    var pairs: [String] = []
                    for i in 0..<(sorted.count - 1) {
                        if sorted[i+1] - sorted[i] == 1 { pairs.append("\(sorted[i])\(sorted[i+1])") }
                    }
                    let pairsStr = pairs.isEmpty ? "无" : pairs.joined(separator: ",")
                    detail = ["连号: \(pairsStr)"]
                    for i in 0..<(sorted.count - 1) {
                        if sorted[i+1] - sorted[i] == 1 {
                            redVotes[sorted[i]]! += 0.25 * weight
                            redVotes[sorted[i+1]]! += 0.25 * weight
                        }
                    }
                }

            case "重号分析":
                detail = ["重号: 上期号码加权"]
                for num in latestRed {
                    redVotes[num] = (redVotes[num] ?? 0) + 0.3 * weight
                }
                blueVotes[latestBlue] = (blueVotes[latestBlue] ?? 0) + 0.3 * weight

            case "尾数分布":
                let tails = recentRed.map { $0 % 10 }
                let tailFreq = Dictionary(grouping: tails, by: { $0 }).mapValues { $0.count }
                let hotTails = tailFreq.filter { $0.value >= 3 }.sorted { $0.value > $1.value }.map { $0.key }
                let tailStr = hotTails.isEmpty ? "无" : hotTails.map { "\($0)" }.joined(separator: ",")
                detail = ["热尾: \(tailStr)"]
                for tail in hotTails {
                    for i in 1...33 where i % 10 == tail { redVotes[i]! += 0.15 * weight }
                }

            case "遗漏分析":
                let missing = (1...33).filter { !Set(recentRed).contains($0) }
                let missingStr = missing.prefix(12).map { "\($0)" }.joined(separator: ",")
                detail = ["遗漏: \(missingStr)"]
                for num in missing { redVotes[num]! += 0.1 * weight }

            case "号码关联":
                detail = ["关联: 邻号分析"]
                if let lastDraw = latestDraw {
                    for num in lastDraw.red {
                        for offset in [-1, 1, 2, -2] {
                            let neighbor = num + offset
                            if neighbor >= 1 && neighbor <= 33 { redVotes[neighbor]! += 0.08 * weight }
                        }
                    }
                }

            case "蓝球热号":
                let blueFreq = Dictionary(grouping: recentBlue, by: { $0 }).mapValues { $0.count }
                let hot = blueFreq.filter { $0.value >= 2 }.sorted { $0.value > $1.value }
                let hotStr = hot.prefix(4).map { "\($0.key)(\($0.value)次)" }.joined(separator: ",")
                detail = ["蓝球热号: \(hotStr)"]
                for (num, freq) in hot.prefix(4) { blueVotes[num] = Double(freq) * 0.5 * weight }

            case "蓝球冷号":
                let cold = (1...16).filter { !Set(recentBlue).contains($0) }
                let coldStr = cold.prefix(5).map { "\($0)" }.joined(separator: ",")
                detail = ["蓝球冷号: \(coldStr)"]
                for num in cold { blueVotes[num]! += 0.3 * weight }

            case "蓝球奇偶":
                let last5 = recentBlue.prefix(5)
                let odd = last5.filter { $0 % 2 == 1 }.count
                let even = last5.count - odd
                detail = ["蓝球奇偶: 近\(last5.count)期 \(odd)奇:\(even)偶"]
                if odd >= 4 { for i in stride(from: 2, to: 17, by: 2) { blueVotes[i]! += 0.25 * weight } }
                else if even >= 4 { for i in stride(from: 1, to: 17, by: 2) { blueVotes[i]! += 0.25 * weight } }

            default:
                detail = ["默认: 均匀分布"]
                for i in 1...33 { redVotes[i]! += 0.05 * weight }
            }

            // 选号：取得分最高的6红1蓝
            let sortedRed = redVotes.sorted { $0.value > $1.value }
            let sortedBlue = blueVotes.sorted { $0.value > $1.value }

            var selectedRed = Array(sortedRed.prefix(6).map { $0.key })
            selectedRed = Array(Set(selectedRed)).sorted()
            while selectedRed.count < 6 {
                for r in sortedRed where !selectedRed.contains(r.key) {
                    selectedRed.append(r.key)
                    break
                }
                if selectedRed.count >= 6 { break }
            }
            selectedRed = Array(selectedRed.prefix(6)).sorted()

            let selectedBlue = sortedBlue.first?.key ?? 8

            steps.append("方法\(index+1)/\(methodNames.count): \(methodName)...")
            for d in detail { steps.append("  → \(d)") }
            steps.append("  → 推荐: \(selectedRed.map { String(format: "%02d", $0) }.joined(separator: " ")) + \(String(format: "%02d", selectedBlue))")

            results.append((methodName, selectedRed, selectedBlue, detail.joined(separator: "; ")))
        }

        return results
    }

    /// 加权投票：汇总各方法推荐，返回综合红蓝及得票明细
    private func vote(_ methodResults: [(method: String, red: [Int], blue: Int, detail: String)]) -> (red: [Int], blue: Int, redVotes: [(key: Int, value: Int)], blueVotes: [(key: Int, value: Int)]) {
        var finalRedVotes: [Int: Int] = [:]
        var finalBlueVotes: [Int: Int] = [:]

        for result in methodResults {
            let weight = weights[result.method] ?? defaultWeight
            for num in result.red {
                finalRedVotes[num] = (finalRedVotes[num] ?? 0) + Int(weight * 10)
            }
            finalBlueVotes[result.blue] = (finalBlueVotes[result.blue] ?? 0) + Int(weight * 10)
        }

        let sortedReds = finalRedVotes.sorted { $0.value > $1.value }
        var selectedRed = Array(Set(sortedReds.prefix(6).map { $0.key })).sorted()
        if selectedRed.count < 6 {
            let remaining = Set(1...33).subtracting(selectedRed)
            let sorted = finalRedVotes.filter { remaining.contains($0.key) }.sorted { $0.value > $1.value }
            for i in 0..<min(6 - selectedRed.count, sorted.count) {
                selectedRed.append(sorted[i].key)
            }
            selectedRed = Array(Set(selectedRed)).sorted()
        }
        selectedRed = Array(selectedRed.prefix(6))

        let sortedBlues = finalBlueVotes.sorted { $0.value > $1.value }
        let selectedBlue = sortedBlues.first?.key ?? 8

        return (
            selectedRed,
            selectedBlue,
            sortedReds.map { (key: $0.key, value: $0.value) },
            sortedBlues.map { (key: $0.key, value: $0.value) }
        )
    }

    /// 综合推演：加权投票汇总各方法推荐，同时返回方法级明细（只计算一次）
    func predict(records: [Record], steps: inout [String]) -> (red: [Int], blue: Int, methodResults: [(method: String, red: [Int], blue: Int, detail: String)]) {
        let methodResults = getMethodPredictions(records: records, steps: &steps)

        steps.append("")
        steps.append("📊 综合投票阶段...")
        let voted = vote(methodResults)
        steps.append("  → 汇总\(methodResults.count)种方法推荐（含权重）")
        steps.append("  → 红球得票: \(voted.redVotes.prefix(10).map { "\($0.key)(\($0.value)分)" }.joined(separator: ","))")
        steps.append("  → 蓝球得票: \(voted.blueVotes.prefix(5).map { "\($0.key)(\($0.value)分)" }.joined(separator: ","))")

        return (voted.red, voted.blue, methodResults)
    }

    /// 回测专用：不产生步骤日志的轻量推演（性能优先）
    func predictForBacktest(records: [Record]) -> (red: [Int], blue: Int, methodResults: [(method: String, red: [Int], blue: Int, detail: String)]) {
        var discarded: [String] = []
        let methodResults = getMethodPredictions(records: records, steps: &discarded)
        let voted = vote(methodResults)
        return (voted.red, voted.blue, methodResults)
    }
}

// MARK: - SwiftUI Views

struct BallView: View {
    let number: Int
    var isBlue: Bool = false

    var body: some View {
        Text(String(format: "%02d", number))
            .font(.system(size: 14, weight: .bold))
            .foregroundColor(.white)
            .frame(width: 32, height: 32)
            .background(isBlue ? Color.blue : Color.red)
            .clipShape(Circle())
            .overlay(Circle().stroke(Color.white, lineWidth: 1))
            .shadow(color: isBlue ? Color.blue.opacity(0.3) : Color.red.opacity(0.3), radius: 2)
    }
}

struct ResultCard: View {
    let red: [Int]
    let blue: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(red.sorted(), id: \.self) { num in
                BallView(number: num, isBlue: false)
            }
            Text("+")
                .font(.title2)
                .foregroundColor(.secondary)
            BallView(number: blue, isBlue: true)
        }
        .padding()
        .background(Color(.windowBackgroundColor).opacity(0.5))
        .cornerRadius(12)
    }
}

struct StepRow: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("🎯") || trimmed.hasPrefix("💡") {
                Image(systemName: "arrow.right.circle.fill")
                    .foregroundColor(.orange)
                    .font(.system(size: 14))
            } else if trimmed.hasPrefix("方法") {
                Image(systemName: "gearshape.fill")
                    .foregroundColor(.blue)
                    .font(.system(size: 12))
            } else if trimmed.hasPrefix("📊") || trimmed.hasPrefix("📥") || trimmed.hasPrefix("📅") {
                Image(systemName: "clock.fill")
                    .foregroundColor(.gray)
                    .font(.system(size: 12))
            } else if trimmed.hasPrefix("→") {
                Image(systemName: "circle.fill")
                    .foregroundColor(.secondary)
                    .font(.system(size: 6))
                    .padding(.top, 4)
            } else {
                Image(systemName: "circle.fill")
                    .foregroundColor(.secondary)
                    .font(.system(size: 6))
                    .padding(.top, 4)
            }
            Text(text)
                .font(trimmed.hasPrefix("🎯") ? .headline : .subheadline)
                .foregroundColor(trimmed.hasPrefix("🎯") ? .primary : .secondary)
        }
        .padding(.vertical, 2)
    }
}

struct PredictionRow: View {
    let prediction: Prediction
    var onDelete: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("期号: \(prediction.issue)")
                    .font(.headline)
                Spacer()
                if prediction.autoCompared {
                    Text(prediction.prize)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(prediction.prize == "一等奖" || prediction.prize == "二等奖" ? Color.green.opacity(0.2) : Color.gray.opacity(0.2))
                        .cornerRadius(4)
                } else {
                    Text("待开奖")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Text(prediction.method)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                if let onDelete = onDelete {
                    Button(action: { onDelete() }) {
                        Image(systemName: "trash")
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(spacing: 4) {
                ForEach(prediction.predictedRed.sorted(), id: \.self) { num in
                    BallView(number: num, isBlue: false)
                }
                Text("+")
                    .foregroundColor(.secondary)
                BallView(number: prediction.predictedBlue, isBlue: true)
            }
            if prediction.autoCompared, let actualRed = prediction.actualRed, let actualBlue = prediction.actualBlue {
                HStack(spacing: 4) {
                    ForEach(actualRed.sorted(), id: \.self) { num in
                        BallView(number: num, isBlue: false)
                    }
                    Text("+")
                        .foregroundColor(.secondary)
                    BallView(number: actualBlue, isBlue: true)
                }
                Text("命中: \(prediction.matchedRed)红 + \(prediction.matchedBlue)蓝")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color(.windowBackgroundColor).opacity(0.3))
        .cornerRadius(8)
    }
}

struct StatBox: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title)
                .fontWeight(.bold)
                .foregroundColor(color)
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(color.opacity(0.1))
        .cornerRadius(8)
    }
}

struct BacktestView: View {
    @ObservedObject var dataStore: DataStore
    @Environment(\.dismiss) private var dismiss
    @State private var selectedPeriods = 100

    var body: some View {
        VStack(spacing: 0) {
            // Header with close button
            HStack {
                Text("📊 回测分析")
                    .font(.title2)
                    .fontWeight(.bold)
                Spacer()
                Button(action: { dismiss.callAsFunction() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Stats overview
                    HStack {
                        StatBox(title: "预测记录", value: "\(dataStore.predictions.count)", color: .blue)
                        StatBox(title: "已比对", value: "\(dataStore.predictions.filter { $0.autoCompared }.count)", color: .green)
                        StatBox(title: "命中>0", value: "\(dataStore.predictions.filter { $0.autoCompared && ($0.matchedRed > 0 || $0.matchedBlue > 0) }.count)", color: .orange)
                    }

                    // Rolling backtest engine
                    rollingBacktestSection

                    // Method weights
                    if !dataStore.methodStats.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("⚖️ 方法权重（命中率基于已比对记录）")
                                .font(.headline)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(dataStore.methodStats.values.sorted { $0.id < $1.id }) { stat in
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(stat.method)
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                                .lineLimit(1)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                            Text(String(format: "%.0f%%", stat.hitRate * 100))
                                                .font(.title3)
                                                .fontWeight(.bold)
                                                .foregroundColor(stat.hitRate > 0.3 ? .green : (stat.hitRate > 0.1 ? .orange : .red))
                                            Text("\(stat.totalCount)次")
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                            Slider(value: Binding(
                                                get: { stat.weight },
                                                set: { dataStore.updateMethodWeight(stat.method, weight: $0) }
                                            ), in: 0.5...3.0)
                                            Text(String(format: "权重 %.1f", stat.weight))
                                                .font(.caption2)
                                                .foregroundColor(.blue)
                                        }
                                        .padding(8)
                                        .background(Color(.controlBackgroundColor))
                                        .cornerRadius(8)
                                        .frame(width: 120)
                                    }
                                }
                            }
                        }
                    }

                    // Prediction records
                    if dataStore.predictions.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "tray")
                                .font(.system(size: 40))
                                .foregroundColor(.secondary)
                            Text("暂无预测记录")
                                .foregroundColor(.secondary)
                            Text("点击「一键推演」生成预测")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("预测记录（含方法明细共 \(dataStore.predictions.count) 条，显示最近 60 条）")
                                .font(.headline)
                            LazyVStack(spacing: 8) {
                                ForEach(dataStore.predictions.sorted(by: { $0.id > $1.id }).prefix(60)) { pred in
                                    PredictionRow(prediction: pred) {
                                        dataStore.deletePredictionById(pred.id)
                                    }
                                }
                            }
                        }
                    }

                    // Action buttons
                    HStack {
                        if !dataStore.predictions.isEmpty {
                            Button(action: {
                                dataStore.autoCompareWithLatestDraws()
                            }) {
                                Label("比对开奖", systemImage: "arrow.triangle.2.circlepath")
                            }
                            .buttonStyle(.bordered)

                            Button(action: {
                                dataStore.calculateMethodStats()
                                dataStore.optimizeStatus = "✅ 已统计各方法命中率"
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                    self.dataStore.optimizeStatus = ""
                                }
                            }) {
                                Label("统计命中", systemImage: "chart.bar")
                            }
                            .buttonStyle(.bordered)

                            Button(action: {
                                dataStore.optimizeWeights()
                            }) {
                                Label("优化权重", systemImage: "wand.and.stars")
                            }
                            .buttonStyle(.bordered)

                            Spacer()

                            Button(action: {
                                dataStore.clearAllPredictions()
                            }) {
                                Label("清空全部", systemImage: "trash")
                                    .foregroundColor(.red)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
                .padding()
            }
        }
        .frame(minWidth: 860, minHeight: 680)
    }

    // MARK: - 滚动回测区块
    private var rollingBacktestSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("🔄 滚动回测引擎")
                .font(.headline)
            Text("对最近 N 期逐期复盘：每期仅用该期之前的历史数据推演，再与实际开奖比对，得到各方法真实命中率（综合推演一行用于评估当前权重组合的整体表现）。")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack {
                Picker("回测期数", selection: $selectedPeriods) {
                    Text("50期").tag(50)
                    Text("100期").tag(100)
                    Text("200期").tag(200)
                    Text("500期").tag(500)
                    Text("全部").tag(0)
                }
                .pickerStyle(.menu)
                .fixedSize()

                if dataStore.isBacktesting {
                    ProgressView(value: dataStore.backtestProgress)
                        .frame(maxWidth: .infinity)
                } else {
                    Button {
                        dataStore.runRollingBacktest(periods: selectedPeriods)
                    } label: {
                        Label("开始回测", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(dataStore.records.count <= 31)

                    if !dataStore.backtestResults.isEmpty {
                        Button {
                            dataStore.applyBacktestWeights()
                        } label: {
                            Label("得分→权重", systemImage: "wand.and.stars")
                        }
                        .buttonStyle(.bordered)
                    }
                }
                Spacer()
            }

            if dataStore.isBacktesting {
                Text(dataStore.backtestStatus)
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if !dataStore.backtestStatus.isEmpty {
                Text(dataStore.backtestStatus)
                    .font(.caption)
                    .foregroundColor(dataStore.backtestStatus.hasPrefix("✅") ? .green : .secondary)
            }

            if !dataStore.backtestResults.isEmpty {
                VStack(spacing: 4) {
                    HStack {
                        Text("方法").frame(width: 92, alignment: .leading)
                        Text("均红").frame(width: 42)
                        Text("蓝率").frame(width: 50)
                        Text("中奖记录").frame(maxWidth: .infinity, alignment: .leading)
                        Text("得分").frame(width: 44, alignment: .trailing)
                    }
                    .font(.caption2)
                    .foregroundColor(.secondary)

                    ForEach(dataStore.backtestResults) { r in
                        HStack {
                            Text(r.method)
                                .frame(width: 92, alignment: .leading)
                                .lineLimit(1)
                                .foregroundColor(r.method == DataStore.comprehensiveMethod ? .purple : .primary)
                            Text(String(format: "%.2f", r.avgRedHit)).frame(width: 42)
                            Text(String(format: "%.1f%%", r.blueHitRate * 100)).frame(width: 50)
                            Text(prizeSummary(r))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .lineLimit(1)
                            Text(String(format: "%.2f", r.score))
                                .frame(width: 44, alignment: .trailing)
                                .foregroundColor(.blue)
                        }
                        .font(.caption)
                        .padding(.vertical, 2)
                        .padding(.horizontal, 2)
                        .background(r.method == DataStore.comprehensiveMethod ? Color.purple.opacity(0.1) : Color.clear)
                        .cornerRadius(4)
                    }

                    Text("得分 = 平均红球命中 + 蓝球命中率×3 + 加权中奖率（一等×100 … 六等×1）。共回测 \(dataStore.backtestResults.first?.periods ?? 0) 期。")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .padding(.top, 4)
                }
                .padding(8)
                .background(Color(.controlBackgroundColor))
                .cornerRadius(8)
            }
        }
        .padding(12)
        .background(Color(.windowBackgroundColor).opacity(0.5))
        .cornerRadius(12)
    }

    private func prizeSummary(_ r: MethodBacktestResult) -> String {
        let order = ["一等奖", "二等奖", "三等奖", "四等奖", "五等奖", "六等奖"]
        let parts = order.compactMap { name -> String? in
            guard let c = r.prizeCounts[name], c > 0 else { return nil }
            return "\(name)×\(c)"
        }
        return parts.isEmpty ? "无" : parts.joined(separator: " ")
    }
}

struct ContentView: View {
    @StateObject private var dataStore = DataStore()
    @State private var showBacktest = false
    @State private var showSteps = false

    var comprehensivePredictions: [Prediction] {
        dataStore.predictions
            .filter { $0.method == DataStore.comprehensiveMethod }
            .sorted(by: { $0.id > $1.id })
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("双色球推演器")
                    .font(.title2)
                    .fontWeight(.bold)
                Spacer()
                Button(action: { dataStore.fetchLatestDraws() }) {
                    Label("更新数据", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)

                Button(action: { dataStore.runPrediction() }) {
                    Label("一键推演", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)

                Button(action: { showBacktest = true }) {
                    Label("回测分析", systemImage: "chart.line.uptrend.xyaxis")
                }
                .buttonStyle(.bordered)
            }
            .padding()

            Divider()

            // Status bar
            if !dataStore.fetchStatus.isEmpty || !dataStore.optimizeStatus.isEmpty {
                HStack {
                    Text(dataStore.optimizeStatus.isEmpty ? dataStore.fetchStatus : dataStore.optimizeStatus)
                        .font(.caption)
                        .foregroundColor(statusColor)
                        .padding(.horizontal)
                    Spacer()
                }
                .padding(.vertical, 4)
                .background(Color(.controlBackgroundColor))
                Divider()
            }

            // Main content
            ScrollView {
                VStack(spacing: 16) {
                    // Latest draw info
                    if let latest = dataStore.records.first {
                        VStack(spacing: 4) {
                            HStack {
                                Text("最新开奖: 第\(latest.issue)期")
                                    .font(.headline)
                                Spacer()
                                Text(latest.date)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            ResultCard(red: latest.red, blue: latest.blue)
                        }
                        .padding()
                        .background(Color(.windowBackgroundColor).opacity(0.5))
                        .cornerRadius(12)
                    }

                    // Latest prediction
                    if let prediction = dataStore.latestPrediction {
                        VStack(spacing: 8) {
                            HStack {
                                Text("最新推演: 第\(prediction.issue)期")
                                    .font(.headline)
                                Spacer()
                                Text(prediction.method)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            ResultCard(red: prediction.predictedRed, blue: prediction.predictedBlue)
                            if prediction.autoCompared {
                                Text("\(prediction.prize) · 命中\(prediction.matchedRed)红\(prediction.matchedBlue)蓝")
                                    .font(.caption)
                                    .foregroundColor(prediction.prize != "未中奖" ? .green : .secondary)
                            }
                            Button(action: { showSteps.toggle() }) {
                                HStack {
                                    Image(systemName: showSteps ? "chevron.up" : "chevron.down")
                                    Text(showSteps ? "收起推演过程" : "查看推演过程")
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        .padding()
                        .background(Color(.windowBackgroundColor).opacity(0.3))
                        .cornerRadius(12)

                        if showSteps && !dataStore.predictionSteps.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("推演过程")
                                    .font(.headline)
                                    .padding(.top)
                                ScrollView {
                                    VStack(alignment: .leading, spacing: 2) {
                                        ForEach(dataStore.predictionSteps, id: \.self) { step in
                                            StepRow(text: step)
                                        }
                                    }
                                }
                                .frame(maxHeight: 300)
                            }
                            .padding()
                            .background(Color(.windowBackgroundColor).opacity(0.5))
                            .cornerRadius(12)
                        }
                    }

                    // Prediction records（只展示综合推演，方法明细见「回测分析」）
                    if !comprehensivePredictions.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("推演记录 (\(comprehensivePredictions.count))")
                                .font(.headline)
                            LazyVStack(spacing: 8) {
                                ForEach(comprehensivePredictions.prefix(10)) { pred in
                                    PredictionRow(prediction: pred) {
                                        dataStore.deletePredictionById(pred.id)
                                    }
                                }
                            }
                        }
                        .padding()
                    }
                }
                .padding()
            }
        }
        .frame(minWidth: 500, minHeight: 600)
        .sheet(isPresented: $showBacktest) {
            BacktestView(dataStore: dataStore)
                .frame(minWidth: 860, minHeight: 680)
        }
    }

    private var statusColor: Color {
        let text = dataStore.optimizeStatus.isEmpty ? dataStore.fetchStatus : dataStore.optimizeStatus
        if text.hasPrefix("✅") { return .green }
        if text.hasPrefix("❌") { return .red }
        return .orange
    }
}

// MARK: - App Entry Point
@main
struct SsqApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

// MARK: - DataStore Extension
extension DataStore {
    func runPrediction() {
        guard !isPredicting else { return }
        isPredicting = true
        predictionSteps = []
        latestPrediction = nil

        // 主线程快照，避免后台读取期间数据被修改
        let recordsSnapshot = records
        let methodStatsSnapshot = methodStats

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            var steps: [String] = []
            steps.append("📊 开始双色球推演分析...")
            steps.append("📥 加载历史数据: \(recordsSnapshot.count) 期")

            let latestIssue = recordsSnapshot.first?.issue ?? "2026001"
            let nextIssue = self.calculateNextIssue(from: latestIssue)
            steps.append("📅 目标期号: \(nextIssue)")

            // 推演前加载已保存/优化过的权重，使回测权重真正生效
            let predictor = Predictor()
            predictor.loadWeights(from: methodStatsSnapshot)
            if !methodStatsSnapshot.isEmpty {
                steps.append("⚖️ 已加载 \(methodStatsSnapshot.count) 个方法的优化权重")
            }
            let result = predictor.predict(records: recordsSnapshot, steps: &steps)

            // 方法级明细一并入库，作为命中率统计的真实数据源
            let baseId = Int(Date().timeIntervalSince1970 * 1000)
            let timeFormatter = DateFormatter()
            timeFormatter.dateFormat = "HH:mm:ss"
            let timeString = timeFormatter.string(from: Date())

            var newPredictions: [Prediction] = []
            for (index, methodResult) in result.methodResults.enumerated() {
                newPredictions.append(Prediction(
                    id: baseId + index,
                    issue: nextIssue,
                    method: methodResult.method,
                    predictedRed: methodResult.red.sorted(),
                    predictedBlue: methodResult.blue,
                    recordTime: timeString,
                    note: methodResult.detail
                ))
            }

            let comprehensivePrediction = Prediction(
                id: baseId + 9999,
                issue: nextIssue,
                method: DataStore.comprehensiveMethod,
                predictedRed: result.red.sorted(),
                predictedBlue: result.blue,
                recordTime: timeString,
                note: "综合推演"
            )

            steps.append("")
            steps.append("🎯 推演结果:")
            steps.append("红球: \(result.red.sorted().map { String(format: "%02d", $0) }.joined(separator: " "))")
            steps.append("蓝球: \(String(format: "%02d", result.blue))")
            steps.append("")
            steps.append("💡 提示: 点击「更新数据」获取最新开奖号码后自动比对")

            DispatchQueue.main.async {
                self.predictionSteps = steps
                self.latestPrediction = comprehensivePrediction
                self.predictions.append(contentsOf: newPredictions)
                self.predictions.append(comprehensivePrediction)
                self.savePredictions()
                self.autoCompareWithLatestDraws()
                self.calculateMethodStats()
                self.isPredicting = false
            }
        }
    }
}
