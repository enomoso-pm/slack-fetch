// Slack 取得（メニューバーのアプリ）
//
// - 状態は、取得の仕組みのフォルダ（取得係.sh のある場所）の データ/状態.json と データ/取得の記録.jsonl を読んで出す
//   （取得係.sh と slack.py が書く）。フォルダは build.sh が組み立てるときにアプリに書き込む。設定で変えられる
// - 「今すぐ取る」と毎朝の自動実行は、このアプリが 取得係.sh を動かす。
//   Mac は「書類」「ダウンロード」「デスクトップ」のフォルダを守っていて、予約の仕組み（launchd）から動いた台本は
//   中のファイルに触れない。このアプリに許可をもらえば、アプリから動かした台本は触れる。そのためアプリが受け持つ
// - 取得の仕組みのフォルダは、場所の文字ではなくフォルダそのもの（Mac のブックマーク）でも覚える。
//   同じディスクの中で動かしても追いかけて知らせる。見つからないときはアラートを出し、選び直してもらう
// - はじめの準備（Slack をつなぐ → チャンネルを選ぶ → 取得を始める）は Setup.swift。
//   メニューの「Slack とチャンネル…」と設定から開き、取るチャンネルを足す・外す。データ/チャンネル.json が無いときは開いたときに出す。
//   準備の窓を開いている間と、最初の取得の前は、毎朝の自動取得を動かさない
// - 取得に使うモデルは設定で選ぶ（台本に MODEL として渡す）
// - 確認用: SlackFetch --snapshot <フォルダ> で、各状態のメニューと状況ページを画像に書き出して終わる
//   （-baseDir <取得の仕組みのフォルダ> を付けると、そのフォルダのデータで書き出す）
// - 確認用: SlackFetch --test-base で、フォルダを追いかける仕組みを一時フォルダで試して終わる（本物の設定は触らない）
// - 確認用: SlackFetch --test-setup で、チャンネルを外す・保存・付け直すを一時フォルダで試して終わる（本物のデータは触らない）

import AppKit
import Charts
import ServiceManagement
import SwiftUI

// MARK: - 色（デジタル庁デザインシステムの値）

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
    static let ink = Color(hex: 0x1A1A1A)        // solid-gray-900
    static let ink2 = Color(hex: 0x4D4D4D)       // solid-gray-700
    static let ink3 = Color(hex: 0x767676)       // solid-gray-536
    static let line = Color(hex: 0xE6E6E6)       // solid-gray-100
    static let line2 = Color(hex: 0xCCCCCC)      // solid-gray-200
    static let surface2 = Color(hex: 0xF2F2F2)   // solid-gray-50
    static let key = Color(hex: 0x0031D8)        // blue-800
    static let keyHover = Color(hex: 0x0017C1)   // blue-900
    static let keyWash = Color(hex: 0xE8F1FE)    // blue-50
    static let bar = Color(hex: 0x3460FB)        // blue-600
    static let okInk = Color(hex: 0x197A4B)      // green-800
    static let okWash = Color(hex: 0xE6F5EC)     // green-50
    static let ngInk = Color(hex: 0xA90000)      // red-1000
    static let ngWash = Color(hex: 0xFDEEEE)     // red-50
    static let ngLine = Color(hex: 0xFFDADA)     // red-100
    static let warnIcon = Color(hex: 0xEBB700)   // yellow-500
    static let warnWash = Color(hex: 0xFBF5E0)   // yellow-50
    static let warnInk = Color(hex: 0x927200)    // yellow-900（注意の文字）
}

// MARK: - 置き場所

/// 置き場所を覚えておく先。ふだんは Mac の設定、確かめ用のモードではメモリの中だけ（ファイルを作らない）
protocol KeyStore: AnyObject {
    func string(forKey: String) -> String?
    func data(forKey: String) -> Data?
    func set(_ value: Any?, forKey: String)
}
extension UserDefaults: KeyStore {}
final class MemoryStore: KeyStore {
    private var values: [String: Any] = [:]
    func string(forKey k: String) -> String? { values[k] as? String }
    func data(forKey k: String) -> Data? { values[k] as? Data }
    func set(_ value: Any?, forKey k: String) { values[k] = value }
}

enum Paths {
    static let required = ["取得係.sh", "slack.py"]
    /// いま使っている場所（起動したとき・取得の前に resolve で決め直す）
    static var current: URL?
    /// 確かめ用のモードでは、本物の設定を触らないようメモリの中だけのものに差し替える
    static var defaults: KeyStore = UserDefaults.standard
    /// 組み立てたときの場所（build.sh が Info.plist に書く）
    static var builtDir: URL? {
        guard let s = Bundle.main.object(forInfoDictionaryKey: "SlackFetchBaseDir") as? String, !s.isEmpty else { return nil }
        return URL(fileURLWithPath: s)
    }
    /// 組み立てた場所（アプリ/build/Slack取得.app）から3つ上
    static var nearApp: URL {
        Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// 取得の仕組みのフォルダ
    static var base: URL { current ?? builtDir ?? nearApp }
    /// そのフォルダに 取得係.sh と slack.py があるか（無ければ、アラートか設定でフォルダを選んでもらう）
    static var baseIsReady: Bool { looksRight(base) }
    static var channels: URL { data.appendingPathComponent("チャンネル.json") }
    static var candidates: URL { data.appendingPathComponent("チャンネル候補.json") }   // チャンネル探し.sh が書く
    static var finder: URL { base.appendingPathComponent("チャンネル探し.sh") }
    /// 一覧から外したチャンネル（呼び名と取り始める日を覚えておき、付け直したときに戻す。取ったデータは消さない）
    static var shelved: URL { data.appendingPathComponent("外したチャンネル.json") }
    /// 既知の例外（Slack 側の食い違いで取りようがないもの。照合で NG にせず、毎回「既知の例外」として出す）
    static var exceptions: URL { data.appendingPathComponent("例外.json") }

    static func looksRight(_ url: URL) -> Bool {
        if url.path.contains("/.Trash/") { return false }   // ゴミ箱に入ったものは使わない
        return required.allSatisfy { FileManager.default.fileExists(atPath: url.appendingPathComponent($0).path) }
    }

    enum Outcome: Equatable {
        case same(URL), moved(from: String, to: URL), missing(last: String)
        var url: URL? {
            switch self {
            case .same(let u), .moved(_, let u): return u
            case .missing: return nil
            }
        }
    }

    /// フォルダを探す。1. 覚えておいたフォルダ（ブックマーク。同じディスクの中なら、動かしても名前を変えても追いかけられる）
    /// 2. 設定で選んだ場所 3. 組み立てたときの場所 4. アプリの置き場所から3つ上
    static func resolve(save: Bool = true, builtIn: Bool = true) -> Outcome {
        let last = defaults.string(forKey: "baseDir")
        var found: URL?
        if let data = defaults.data(forKey: "baseBookmark") {
            var stale = false
            if let u = try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting],
                                relativeTo: nil, bookmarkDataIsStale: &stale), looksRight(u) {
                found = u
            }
        }
        if found == nil, let last, !last.isEmpty, looksRight(URL(fileURLWithPath: last)) { found = URL(fileURLWithPath: last) }
        if found == nil, builtIn, let u = builtDir, looksRight(u) { found = u }
        if found == nil, builtIn, looksRight(nearApp) { found = nearApp }
        guard let u = found else { return .missing(last: last ?? builtDir?.path ?? nearApp.path) }
        if save { remember(u) }
        if let last, !last.isEmpty,
           URL(fileURLWithPath: last).resolvingSymlinksInPath().path != u.resolvingSymlinksInPath().path {
            return .moved(from: last, to: u)
        }
        return .same(u)
    }

    /// 場所を覚える（場所の文字と、フォルダそのもの〈ブックマーク〉の両方）
    static func remember(_ url: URL) {
        defaults.set(url.path, forKey: "baseDir")
        if let data = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            defaults.set(data, forKey: "baseBookmark")
        }
    }

    /// 選ばれたフォルダの中から探す（1つ上のフォルダを選んだときなど。3段下まで）
    static func findInside(_ url: URL) -> URL? {
        if looksRight(url) { return url }
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey],
                                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return nil }
        for case let u as URL in e {
            if e.level > 3 { e.skipDescendants(); continue }
            if (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true, looksRight(u) { return u }
        }
        return nil
    }

    static func short(_ p: String) -> String { (p as NSString).abbreviatingWithTildeInPath }
    /// 取ったもの・設定・状態の置き場所（公開しないのはこのフォルダだけ）
    static var data: URL { base.appendingPathComponent("データ") }
    static var state: URL { data.appendingPathComponent("状態.json") }
    static var history: URL { data.appendingPathComponent("取得の記録.jsonl") }
    static var script: URL { base.appendingPathComponent("取得係.sh") }
    static var lock: URL { data.appendingPathComponent(".取得中") }
    static var logs: URL { data.appendingPathComponent("取得ログ") }   // 中は月ごとのフォルダ
}

// MARK: - データ（状態.json・取得の記録.jsonl）

struct RunInfo: Codable {
    var start: String?
    var end: String?
    var result: String?
    var rounds: Int?
    var turns: Int?
    var cost_usd: Double?
    var note: String?
    var new: Int?
    var round: Int?
    var todo: Int?
    var since: String?
}

struct ChannelInfo: Codable, Identifiable {
    var id: String
    var tag: String
    var name: String
    var total: Int
    var parents: Int
    var replies: Int
    var external: Int?
    var last_post: String
    var delta: Int?
    var created: String?
    var first_post: String?
    var threads: Int?
    var last7: Int?
    var last30: Int?
    var people: Int?
    var people30: Int?
    var spark: [Int]?
    var week: [WeekDay]?
    var prev7: Int?
    var people7: Int?
}

struct UserCount: Codable {
    var name: String
    var count: Int
}

struct WeekDay: Codable, Identifiable {
    var date: String
    var total: Int
    var users: [UserCount]
    var id: String { date }
}

struct CheckItem: Codable, Identifiable {
    var name: String
    var ok: Bool
    var detail: String
    var id: String { name }
}

struct CheckInfo: Codable {
    var threads: Int
    var ng: [String]
    var notes: [String]?
    var exceptions: [String]?
    var items: [CheckItem]?
}

struct DailyEntry: Codable, Identifiable {
    var date: String
    var counts: [String: Int]
    var id: String { date }
    var total: Int { counts.values.reduce(0, +) }
}

struct StateFile: Codable {
    var updated: String?
    var state: String?
    var run: RunInfo?
    var channels: [ChannelInfo]?
    var check: CheckInfo?
    var last_success: String?
    var daily: [DailyEntry]?
}

struct HistoryEntry: Codable, Identifiable {
    var start: String?
    var end: String?
    var result: String?
    var rounds: Int?
    var cost_usd: Double?
    var note: String?
    var new: Int?
    var ng: Int?
    var id: String { (start ?? "") + "|" + (end ?? "") }
}

// MARK: - 日付の書き方

enum Fmt {
    static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    static func parseISO(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        return isoFrac.date(from: s) ?? iso.date(from: s)
    }
    static func parseJST(_ s: String) -> Date? {  // "2026-10-08 16:12:34"（日本時間）
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Asia/Tokyo")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.date(from: s)
    }
    static func string(_ d: Date, _ format: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = format
        return f.string(from: d)
    }
    /// 「今日 9:00」「昨日 23:11」「10/6（火）9:00」
    static func relative(_ d: Date?, now: Date = Date()) -> String {
        guard let d else { return "—" }
        let cal = Calendar.current
        if cal.isDate(d, inSameDayAs: now) { return "今日 " + string(d, "H:mm") }
        if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(d, inSameDayAs: y) {
            return "昨日 " + string(d, "H:mm")
        }
        if let t = cal.date(byAdding: .day, value: 1, to: now), cal.isDate(d, inSameDayAs: t) {
            return "明日 " + string(d, "M/d（E）H:mm")
        }
        return string(d, "M/d（E）H:mm")
    }
    static func number(_ n: Int) -> String { n.formatted(.number.grouping(.automatic)) }
}

// MARK: - 状態と操作

enum DisplayState { case ok, running, ng, failed, stale, fresh }  // fresh: まだ一度も取っていない

@MainActor
final class Store: ObservableObject {
    @Published var file = StateFile()
    @Published var history: [HistoryEntry] = []
    @Published var running = false
    @Published var now = Date()
    @Published var message: String?
    @Published var autoEnabled: Bool { didSet { UserDefaults.standard.set(autoEnabled, forKey: "autoEnabled") } }
    @Published var hour: Int { didSet { UserDefaults.standard.set(hour, forKey: "hour") } }
    @Published var minute: Int { didSet { UserDefaults.standard.set(minute, forKey: "minute") } }
    @Published var costCap: Int { didSet { UserDefaults.standard.set(costCap, forKey: "costCap") } }
    @Published var notify: Bool { didSet { UserDefaults.standard.set(notify, forKey: "notify") } }
    /// 取得に使うモデル（台本に MODEL として渡す）。名前（haiku など）なら、その系列のいちばん新しい版
    @Published var model: String { didSet { UserDefaults.standard.set(model, forKey: "model") } }
    @Published var loginItem = false
    @Published var showInDock: Bool {
        didSet {
            UserDefaults.standard.set(showInDock, forKey: "showInDock")
            AppDelegate.shared?.applyDockSetting()
        }
    }

    @Published var showSettings = false
    @Published var configured = false   // データ/チャンネル.json に取るチャンネルがあるか（はじめの準備が済んだか）
    let setup = Setup()
    /// 状況ページの数え直し（slack.py status refresh）をしている間
    @Published var refreshing = false
    @Published var baseMissing = false
    @Published var basePath = ""
    private var lastMissingAlert: String?
    var forced: DisplayState?   // 確認用の画像を作るときだけ使う
    var previewTip: String?
    var previewBar: String?
    var previewExpanded = false
    var previewWeekBar: String?
    private var process: Process?
    private var refreshProcess: Process?
    private var refreshAgain = false   // 数え直しの途中で、もう一度保存された
    private var timer: Timer?

    init(live: Bool = true) {
        let d = UserDefaults.standard
        autoEnabled = d.object(forKey: "autoEnabled") as? Bool ?? true
        hour = d.object(forKey: "hour") as? Int ?? 9
        minute = d.object(forKey: "minute") as? Int ?? 0
        costCap = d.object(forKey: "costCap") as? Int ?? 5
        notify = d.object(forKey: "notify") as? Bool ?? true
        model = Store.currentModel
        showInDock = d.object(forKey: "showInDock") as? Bool ?? true
        loginItem = SMAppService.mainApp.status == .enabled
        if live {
            checkBase()
        } else if let s = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)["baseDir"] as? String,
                  !s.isEmpty {
            Paths.current = URL(fileURLWithPath: s)   // 確認用の画像: -baseDir で渡されたフォルダのデータで書き出す
        } else {
            Paths.current = Paths.resolve(save: false).url
        }
        basePath = Paths.base.path
        load()
        guard live else { return }
        // チャンネルを足した・外したら、次の取得を待たずに状況ページを数え直す
        setup.onSaved = { [weak self] in self?.refreshStatus() }
        if launchedFromClaudeCode {
            message = Store.reopenMessage
        }
        if !baseMissing && !configured && !Store.needsMigrate { setup.open() }   // 取るチャンネルが無いときは、はじめの準備から
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // 起動したとき・Mac が起きたときにも確かめる（9時に寝ていた日も、起きたら取る）
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.tick() }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 20_000_000_000)  // 起きてすぐは通信がつながっていないことがある
                self?.tick()
            }
        }
    }

    func tick() {
        now = Date()
        if baseMissing || !Paths.looksRight(Paths.base) { checkBase() }
        load()
        checkSchedule()
    }

    static let noPermissionMessage = "取得の仕組みのフォルダを読む許可がありません。システム設定 → プライバシーとセキュリティ → "
        + "ファイルとフォルダ で「Slack 取得」をオンにしてください。"
    static let noScriptMessage = "取得の仕組みのフォルダに 取得係.sh が見つかりません。設定（歯車）でフォルダを選んでください。"
    /// まだ一度も取っていないときの案内（はじめの準備が済んだかで変わる）
    var freshText: String {
        if Store.needsMigrate { return "前の形のデータがあります。先に データ/ に引っ越してください（やり方は下の赤い文）" }
        return configured
            ? "準備ができました。「今すぐ取る」を押すと、取り始める日からの分をまとめて取ります（多いときは何回かに分けて）"
            : "はじめの準備（Slack をつなぐ・取るチャンネルを選ぶ）をしてください。終わったら、取り始める日からの分をまとめて取ります"
    }

    static let migrateMessage = "前の形のデータ（このフォルダの一番上の 原本/・状態.json など）があります。"
        + "ターミナルでこのフォルダに入り、python3 slack.py migrate を動かして データ/ に引っ越してください。"

    /// 前の形のまま（状態.json がフォルダの一番上にあり、データ/ には無い）。引っ越すまでは、はじめの準備を勝手に開かず、
    /// 数え直しもしない（先に データ/状態.json ができると、引っ越しで前の 状態.json が移らず、取得係.sh が止まったままになる）
    static var needsMigrate: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: Paths.base.appendingPathComponent("状態.json").path) && !fm.fileExists(atPath: Paths.state.path)
    }

    func load() {
        // 前の形のまま（状態.json がフォルダの一番上にある）なら、引っ越しを案内する
        if Store.needsMigrate {
            message = Store.migrateMessage
        } else if message == Store.migrateMessage {
            message = nil
        }
        do {
            let data = try Data(contentsOf: Paths.state)
            if let f = try? JSONDecoder().decode(StateFile.self, from: data) { file = f }
            if message == Store.noPermissionMessage { message = nil }
        } catch let e as NSError where e.domain == NSCocoaErrorDomain && e.code == NSFileReadNoPermissionError {
            message = Store.noPermissionMessage
        } catch {
            file = StateFile()  // まだ一度も取っていない（または、フォルダを選び直した）
        }
        if let text = try? String(contentsOf: Paths.history, encoding: .utf8) {
            history = text.split(separator: "\n")
                .compactMap { try? JSONDecoder().decode(HistoryEntry.self, from: Data($0.utf8)) }
                .reversed()
        } else {
            history = []
        }
        running = (process?.isRunning ?? false) || lockIsAlive()
        configured = !Setup.savedChannels().isEmpty
    }

    // ---- 取得の仕組みのフォルダ ----

    enum BaseAlert { case moved(from: String, to: String), missing(last: String) }

    /// フォルダを確かめる。動いていたら追いかけて知らせ、見つからなければアラートで選び直してもらう
    func checkBase() {
        switch Paths.resolve() {
        case .same(let u):
            Paths.current = u
            baseMissing = false
        case .moved(let from, let to):
            Paths.current = to
            baseMissing = false
            present(.moved(from: from, to: to.path))
        case .missing(let last):
            baseMissing = true
            message = Store.noScriptMessage
            if lastMissingAlert != last {
                lastMissingAlert = last
                present(.missing(last: last))
            }
        }
        if !baseMissing {
            lastMissingAlert = nil
            if message == Store.noScriptMessage { message = nil }
        }
        basePath = Paths.base.path
    }

    private func present(_ a: BaseAlert) {
        // 起動の途中でも出せるよう、少し待ってから出す
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.runAlert(a) }
    }

    private func runAlert(_ a: BaseAlert) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        switch a {
        case .moved(let from, let to):
            alert.messageText = "取得の仕組みのフォルダが移動していました"
            alert.informativeText = "新しい場所に切り替えました。\n前: \(Paths.short(from))\n今: \(Paths.short(to))"
            alert.addButton(withTitle: "OK")
            alert.runModal()
        case .missing(let last):
            alert.alertStyle = .warning
            alert.messageText = "取得の仕組みのフォルダが見つかりません"
            alert.informativeText = "取得係.sh があるフォルダが、前の場所にありません。\n前の場所: \(Paths.short(last))\n\n"
                + "フォルダを動かした場合は「場所を選ぶ」で選び直してください。見つかるまで、取得はしません。"
            alert.addButton(withTitle: "場所を選ぶ")
            alert.addButton(withTitle: "あとで")
            if alert.runModal() == .alertFirstButtonReturn { chooseBase() }
        }
    }

    /// 取得の仕組みのフォルダを選び直す（設定の「変更…」と、見つからないときのアラートから）
    func chooseBase() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = Paths.baseIsReady ? Paths.base : FileManager.default.homeDirectoryForCurrentUser
        panel.message = "取得係.sh のあるフォルダを選んでください（1つ上のフォルダを選んでもかまいません）"
        panel.prompt = "このフォルダにする"
        guard panel.runModal() == .OK, let picked = panel.url else { return }
        guard let u = Paths.findInside(picked) else {
            let a = NSAlert()
            a.alertStyle = .warning
            a.messageText = "このフォルダではありません"
            a.informativeText = "選んだフォルダ（\(Paths.short(picked.path))）の中に、取得係.sh と slack.py が見つかりませんでした。"
            a.addButton(withTitle: "もう一度選ぶ")
            a.addButton(withTitle: "あとで")
            if a.runModal() == .alertFirstButtonReturn { chooseBase() }
            return
        }
        Paths.remember(u)
        Paths.current = u
        baseMissing = false
        lastMissingAlert = nil
        if message == Store.noScriptMessage { message = nil }
        basePath = u.path
        load()
    }

    private func lockIsAlive() -> Bool {
        guard let s = try? String(contentsOf: Paths.lock.appendingPathComponent("pid"), encoding: .utf8),
              let pid = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return kill(pid, 0) == 0
    }

    // ---- 表示に使う値 ----

    var lastSuccess: Date? { Fmt.parseISO(file.last_success) }
    var lastRunEnd: Date? { Fmt.parseISO(file.run?.end) }
    var lastRunStart: Date? { Fmt.parseISO(file.run?.start) ?? history.first.flatMap { Fmt.parseISO($0.start) } }

    var display: DisplayState {
        if let forced { return forced }
        if running { return .running }
        if file.state == nil && file.run == nil && history.isEmpty { return .fresh }
        switch file.state {
        case "ng": return .ng
        case "error", "stopped": return .failed
        default: break
        }
        if autoEnabled, let ls = lastSuccess, now.timeIntervalSince(ls) > 26 * 3600 { return .stale }
        return .ok
    }

    var timeText: String { String(format: "%d:%02d", hour, minute) }
    var staleDays: Int { max(1, Int(now.timeIntervalSince(lastSuccess ?? now) / 86400)) }
    /// 「前回の取得から増えた」の前回（いま出している増え方は、この取得からのもの）
    var prevRunEnd: Date? {
        Fmt.parseISO(file.run?.since) ?? (history.count >= 2 ? Fmt.parseISO(history[1].end) : nil)
    }
    var monthRuns: [HistoryEntry] {
        history.filter { e in
            guard let d = Fmt.parseISO(e.start) else { return false }
            return Calendar.current.isDate(d, equalTo: now, toGranularity: .month)
        }
    }
    var last30Runs: [HistoryEntry] {
        history.filter { e in (Fmt.parseISO(e.start) ?? .distantPast) >= now.addingTimeInterval(-30 * 86400) }
    }
    var todaySchedule: Date {
        Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: now) ?? now
    }
    var nextRunText: String {
        if !configured || history.isEmpty { return "最初の取得のあとから" }   // checkSchedule と同じ決まり
        let t = todaySchedule
        if now < t { return Fmt.relative(t, now: now) }
        if let s = lastRunStart, s >= t {
            return Fmt.relative(Calendar.current.date(byAdding: .day, value: 1, to: t), now: now)
        }
        return "このあとすぐ"
    }
    var channels: [ChannelInfo] { file.channels ?? [] }
    var totalPosts: Int { channels.reduce(0) { $0 + $1.total } }
    var totalParents: Int { channels.reduce(0) { $0 + $1.parents } }
    var newSinceLast: Int { file.run?.new ?? 0 }
    var threadsChecked: Int { file.check?.threads ?? 0 }
    var ngLines: [String] { file.check?.ng ?? [] }
    /// 3通りの呼び方で取りに行っても別のスレッドが返り、取得の仕組みが諦めたもの（もう一度取っても直らない）
    var gaveUpLines: [String] { ngLines.filter { $0.hasPrefix("NG 取りに行くと別のスレッドが返る") } }
    /// NG がすべて「諦めたもの」か（「もう一度取る」ではなく「既知の例外にする」を出す）
    var onlyGaveUp: Bool { !ngLines.isEmpty && gaveUpLines.count == ngLines.count }
    var exceptionLines: [String] { file.check?.exceptions ?? [] }
    var monthCost: Double { monthRuns.reduce(0) { $0 + ($1.cost_usd ?? 0) } }

    /// NG の行を読みやすくする（チャンネル ID → 呼び名、投稿の ID → 日時）
    func readable(_ line: String) -> String {
        var s = line.hasPrefix("NG ") ? String(line.dropFirst(3)) : line
        for c in channels { s = s.replacingOccurrences(of: c.id, with: c.tag + "チャンネル") }
        if let re = try? NSRegularExpression(pattern: "\\b(\\d{10})\\.\\d{6}\\b") {
            for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
                guard let r = Range(m.range, in: s), let r1 = Range(m.range(at: 1), in: s),
                      let secs = Double(s[r1]) else { continue }
                s.replaceSubrange(r, with: Fmt.string(Date(timeIntervalSince1970: secs), "M/d H:mm") + " の投稿")
            }
        }
        return s
    }

    // ---- 毎朝の自動実行 ----

    func checkSchedule() {
        // はじめの準備が済み、最初の取得を自分で始めてから動く。準備の窓を開いている間も待つ（チャンネルを選び直している途中に始めない）
        guard autoEnabled, !running, !baseMissing, forced == nil, configured, !history.isEmpty, !setup.show else { return }
        let t = todaySchedule
        guard now >= t else { return }
        if let s = lastRunStart, s >= t { return }
        runNow()
    }

    // ---- 操作 ----

    /// Claude Code の中から開かれたアプリは「入れ子」の印を受け継いでいて、取得係（claude）を動かせない
    static var launchedFromClaudeCode: Bool { ProcessInfo.processInfo.environment["CLAUDECODE"] != nil }
    var launchedFromClaudeCode: Bool { Store.launchedFromClaudeCode }
    static let reopenMessage = "このアプリは Claude Code から開かれたため、取得を動かせません。"
        + "一度終了して（Dock のアイコンを右クリック →「終了」）、Finder か Spotlight から開き直してください。"

    /// 台本（取得係.sh・チャンネル探し.sh）に渡す環境。claude（Claude Code）は入れ方によって置き場所が違う（ネイティブ版は ~/.local/bin）
    static func scriptEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = "\(home)/.local/bin:\(home)/.claude/local:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"
        env["MODEL"] = currentModel
        return env
    }

    // ---- 取得に使うモデル ----

    static let modelAliases = ["haiku", "sonnet", "opus"]
    /// 設定で選んだモデル（空なら haiku）
    static var currentModel: String {
        let m = (UserDefaults.standard.string(forKey: "model") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return m.isEmpty ? "haiku" : m
    }

    /// いちばん新しい取得の結果に書かれた、実際に使ったモデルの名前（名前が版に変わったあとのもの）。
    /// 取得ログは月ごとのフォルダに分かれているので、中まで見る
    static func lastUsedModel() -> String? {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let files = (FileManager.default.enumerator(at: Paths.logs, includingPropertiesForKeys: keys)?
            .compactMap { $0 as? URL }) ?? []
        let date = { (u: URL) in (try? u.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast }
        for url in files.filter({ $0.lastPathComponent.hasSuffix("_結果.json") }).sorted(by: { date($0) > date($1) }).prefix(20) {
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let usage = obj["modelUsage"] as? [String: Any], !usage.isEmpty else { continue }
            return usage.keys.sorted().joined(separator: "・")
        }
        return nil
    }

    /// 台本の出力を書き足す 取得ログ/アプリから動かした記録.log（見出しを1行書いてから渡す）。
    /// 「必ず後ろに足す」形（O_APPEND）で開く。取得と数え直し・チャンネル探しなど2つが同時に書いても、
    /// 開いたときの場所に書いて相手を上書きすることがない（2026-10-09 16:28 に、数え直しが取得の見出しを上書きした）
    static func appLog(_ title: String) -> FileHandle? {
        let logURL = Paths.logs.appendingPathComponent("アプリから動かした記録.log")
        try? FileManager.default.createDirectory(at: Paths.logs, withIntermediateDirectories: true)
        let fd = open(logURL.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return nil }
        let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        h.write(Data("\n==== \(Fmt.string(Date(), "yyyy-MM-dd HH:mm:ss")) に開始（\(title)） ====\n".utf8))
        return h
    }

    func runNow() {
        guard !running else { return }
        if launchedFromClaudeCode {
            message = Store.reopenMessage
            return
        }
        checkBase()
        guard !baseMissing else {
            message = Store.noScriptMessage
            return
        }
        if Store.needsMigrate {   // 前の形のデータのままなら、はじめの準備ではなく引っ越しを案内する（取得係.sh も動かない）
            message = Store.migrateMessage
            return
        }
        configured = !Setup.savedChannels().isEmpty   // はじめの準備で保存した直後でも、ここで読み直す
        guard configured else {   // 取るチャンネルが無ければ、はじめの準備を開く
            AppDelegate.shared?.openSetup()
            return
        }
        // 状況ページの数え直しの途中なら止める。取得の終わりに必ず数え直すので要らず、
        // 2つが同じ状態のファイルを書くと、取得の途中の印が古い中身に戻ることがある
        if let r = refreshProcess, r.isRunning {
            refreshAgain = false
            r.terminate()
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        p.arguments = ["-i", "/bin/bash", Paths.script.path]
        var env = Store.scriptEnvironment()
        env["COST_CAP"] = String(costCap)
        env["NOTIFY"] = notify ? "1" : "0"
        p.environment = env
        if let h = Store.appLog("取得係") {
            p.standardOutput = h
            p.standardError = h
        }
        p.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.process = nil
                self?.load()
            }
        }
        do {
            try p.run()
            process = p
            running = true
            message = nil
        } catch {
            message = "取得係を動かせませんでした: \(error.localizedDescription)"
        }
    }

    /// 状況ページの数字を数え直す（slack.py status refresh。取得の記録は増えない・Claude は動かさない。20秒ほど）。
    /// 数えるのは一覧（データ/チャンネル.json）にあるチャンネルだけ。取得中は数え直さない（取得の終わりに、新しい一覧で数え直される）
    func refreshStatus() {
        guard !running, !baseMissing, !Store.needsMigrate else { return }
        if refreshProcess != nil {   // 数え直しの途中なら、終わってからもう一度
            refreshAgain = true
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = [Paths.base.appendingPathComponent("slack.py").path, "status", "refresh"]
        p.currentDirectoryURL = Paths.base
        var env = Store.scriptEnvironment()
        env["PYTHONDONTWRITEBYTECODE"] = "1"   // 取得の仕組みのフォルダに __pycache__ を作らない
        p.environment = env
        if let h = Store.appLog("状況の数え直し") {
            p.standardOutput = h
            p.standardError = h
        }
        p.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.refreshProcess = nil
                self.refreshing = false
                self.load()
                if self.refreshAgain {
                    self.refreshAgain = false
                    self.refreshStatus()
                }
            }
        }
        do {
            try p.run()
            refreshProcess = p
            refreshing = true
        } catch {
            message = "状況ページを数え直せませんでした: \(error.localizedDescription)"
        }
    }

    // ---- 既知の例外（データ/例外.json） ----

    static let threadRefRE = try! NSRegularExpression(pattern: "([CG][A-Z0-9]{6,20}) (\\d{10}\\.\\d{6})")
    /// 照合の行から、チャンネルの ID と投稿の時刻を取り出す
    static func threadRef(_ line: String) -> (ch: String, ts: String)? {
        guard let m = threadRefRE.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let a = Range(m.range(at: 1), in: line), let b = Range(m.range(at: 2), in: line) else { return nil }
        return (String(line[a]), String(line[b]))
    }

    nonisolated static let gaveUpReason = "取りに行くと別のスレッドが返る（Slack 側の食い違い。3通りの呼び方で試した）"

    /// 例外.json に足す・外す（ほかの行はそのまま残す）。足した数・外した数を返す
    @discardableResult
    static func editExceptions(add: [(ch: String, ts: String)] = [], remove: [(ch: String, ts: String)] = [],
                               reason: String = gaveUpReason) throws -> Int {
        var list = ((try? Data(contentsOf: Paths.exceptions))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] }) ?? []
        let before = list.count
        let same = { (e: [String: Any], r: (ch: String, ts: String)) in (e["channel"] as? String) == r.ch && (e["ts"] as? String) == r.ts }
        list.removeAll { e in remove.contains { same(e, $0) } }
        for r in add where !list.contains(where: { same($0, r) }) {
            list.append(["channel": r.ch, "ts": r.ts, "reason": reason, "added": Fmt.iso.string(from: Date())])
        }
        let data = try JSONSerialization.data(withJSONObject: list, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try (String(decoding: data, as: UTF8.self) + "\n").write(to: Paths.exceptions, atomically: true, encoding: .utf8)
        return abs(list.count - before)
    }

    /// 諦めたスレッドを既知の例外にする（確かめてから）。照合では NG ではなく「既知の例外」として毎回出る
    func addGaveUpToExceptions() {
        let refs = gaveUpLines.compactMap(Store.threadRef)
        guard !refs.isEmpty else { return }
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "\(refs.count)本のスレッドを既知の例外にしますか？"
        a.informativeText = "3通りの呼び方で取りに行っても、Slack が別のスレッドを返しました（Slack 側の食い違い）。\n"
            + "既知の例外にすると、照合では NG ではなく「既知の例外」として毎回出します。取ったデータは消しません。あとで戻せます。"
        a.addButton(withTitle: "既知の例外にする")
        a.addButton(withTitle: "やめる")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        do {
            try Store.editExceptions(add: refs)
            refreshStatus()
        } catch {
            message = "例外.json に書けませんでした: \(error.localizedDescription)"
        }
    }

    /// 既知の例外から戻す（確かめてから）。次の照合から、また NG として出る（取得の仕組みは、もう一度は取りに行かない）
    func removeException(_ line: String) {
        guard let r = Store.threadRef(line) else { return }
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "既知の例外から戻しますか？"
        a.informativeText = readable(line) + "\n\n戻すと、照合でまた NG として出ます。"
        a.addButton(withTitle: "戻す")
        a.addButton(withTitle: "やめる")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        do {
            try Store.editExceptions(remove: [r])
            refreshStatus()
        } catch {
            message = "例外.json に書けませんでした: \(error.localizedDescription)"
        }
    }

    func stop() {
        FileManager.default.createFile(atPath: Paths.lock.appendingPathComponent("stop").path, contents: nil)
        let k = Process()
        k.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        k.arguments = ["-TERM", "-f", "You are a mechanical Slack fetcher"]
        try? k.run()
    }

    func openLatestLog() {
        let fm = FileManager.default
        // 取得ログは月ごとのフォルダに分かれているので、中まで見る
        let files = (fm.enumerator(at: Paths.logs, includingPropertiesForKeys: [.contentModificationDateKey])?
            .compactMap { $0 as? URL }) ?? []
        let latest = files.filter { $0.lastPathComponent.hasSuffix("まとめ.txt") }
            .max { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da < db
            }
        NSWorkspace.shared.open(latest ?? Paths.logs)
    }

    func openFolder() { NSWorkspace.shared.open(FileManager.default.fileExists(atPath: Paths.data.path) ? Paths.data : Paths.base) }

    func setLoginItem(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            message = nil
        } catch {
            message = "Mac の起動時に開く設定ができませんでした（\(error.localizedDescription)）。"
                + "システム設定 → 一般 → ログイン項目 で、このアプリを足してください。"
        }
        loginItem = SMAppService.mainApp.status == .enabled
    }
}

// MARK: - 部品

struct SwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule().fill(configuration.isOn ? Color.okInk : Color(hex: 0xB3B3B3))
                Circle().fill(.white).shadow(color: .black.opacity(0.3), radius: 1, y: 1).padding(3)
            }
            .frame(width: 42, height: 24)
            .animation(.easeOut(duration: 0.15), value: configuration.isOn)
        }
        .buttonStyle(.plain)
    }
}

struct DadsButton: View {
    enum Kind { case primary, secondary, quiet }
    let title: String
    var kind: Kind = .primary
    var small = false
    var enabled = true
    var shortcut: KeyboardShortcut? = nil   // 例: .cancelAction（Esc で押したことにする）
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: small ? 12 : 13, weight: .bold))
                .foregroundStyle(fg)
                .padding(.vertical, small ? 6 : 9)
                .padding(.horizontal, small ? 10 : 14)
                .frame(maxWidth: small ? nil : .infinity)
                .background(RoundedRectangle(cornerRadius: 8).fill(bg))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(border, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(shortcut)
        .disabled(!enabled)
        .onHover { hover = $0 }
    }
    private var fg: Color {
        if !enabled { return Color(hex: 0x949494) }
        switch kind { case .primary: return .white; case .secondary: return .key; case .quiet: return .ink }
    }
    private var bg: Color {
        if !enabled { return .line }
        switch kind {
        case .primary: return hover ? .keyHover : .key
        case .secondary: return hover ? .keyWash : .white
        case .quiet: return hover ? .surface2 : .white
        }
    }
    private var border: Color {
        if !enabled { return .clear }
        switch kind { case .primary: return .clear; case .secondary: return .key; case .quiet: return .line2 }
    }
}

struct MenuRow: View {
    let title: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack { Text(title).font(.system(size: 13)); Spacer() }
                .foregroundStyle(hover ? .white : .ink)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(hover ? Color.key : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct Pill: View {
    let result: String?
    let ng: Int?
    var body: some View {
        let (text, fg, bg): (String, Color, Color) = {
            switch result {
            case "ok": return ("照合 OK", .okInk, .okWash)
            case "ng": return ("照合 NG \(ng ?? 0)件", .ngInk, .ngWash)
            case "stopped": return ("途中で止めた", Color(hex: 0x927200), .warnWash)
            case "interrupted": return ("途中で終わった", Color(hex: 0x927200), .warnWash)
            default: return ("失敗", .ngInk, .ngWash)
            }
        }()
        Text(text).font(.system(size: 11, weight: .bold)).foregroundStyle(fg)
            .padding(.horizontal, 8).padding(.vertical, 1)
            .background(Capsule().fill(bg))
    }
}

// MARK: - メニュー（メニューバーのアイコンを押すと出る）

struct MenuIcon: View {
    let state: DisplayState
    var body: some View {
        switch state {
        case .ok: Image(systemName: "checkmark.circle")
        case .running: Image(systemName: "arrow.triangle.2.circlepath")
        case .ng: Image(systemName: "exclamationmark.triangle.fill")
        case .failed: Image(systemName: "exclamationmark.circle.fill")
        case .stale: Image(systemName: "clock.badge.exclamationmark")
        case .fresh: Image(systemName: "tray")
        }
    }
}

struct StatusCard: View {
    @EnvironmentObject var store: Store
    var openStatus: () -> Void

    var body: some View {
        let s = store.display
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle().fill(iconBG(s))
                Image(systemName: iconName(s)).font(.system(size: 15, weight: .heavy)).foregroundStyle(s == .stale ? Color.ink : .white)
            }
            .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text(title(s)).font(.system(size: 15, weight: .bold)).foregroundStyle(Color.ink)
                Text(desc(s)).font(.system(size: 12)).foregroundStyle(Color.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                extras(s)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(wash(s)))
    }

    private func iconName(_ s: DisplayState) -> String {
        switch s {
        case .ok: return "checkmark"
        case .running: return "arrow.clockwise"
        case .ng, .failed: return "exclamationmark"
        case .stale: return "clock"
        case .fresh: return "arrow.down"
        }
    }
    private func iconBG(_ s: DisplayState) -> Color {
        switch s {
        case .ok: return .okInk; case .running, .fresh: return .key; case .ng, .failed: return .ngInk; case .stale: return .warnIcon
        }
    }
    private func wash(_ s: DisplayState) -> Color {
        switch s {
        case .ok: return .okWash; case .running, .fresh: return .keyWash; case .ng, .failed: return .ngWash; case .stale: return .warnWash
        }
    }
    private func title(_ s: DisplayState) -> String {
        switch s {
        case .ok: return "最新です"
        case .running: return "取得中…"
        case .ng: return "照合で合わないものが \(store.ngLines.count)件あります"
        case .failed: return store.file.state == "stopped" ? "途中で止まりました" : "取得に失敗しました"
        case .stale:
            let days = max(1, Int(store.now.timeIntervalSince(store.lastSuccess ?? store.now) / 86400))
            return "\(days)日間 取れていません"
        case .fresh: return "まだ一度も取っていません"
        }
    }
    private func desc(_ s: DisplayState) -> String {
        let last = Fmt.relative(store.lastRunEnd, now: store.now)
        switch s {
        case .ok:
            return "\(last) に取得・照合 OK（スレッド \(Fmt.number(store.threadsChecked))本すべて一致）"
        case .running:
            let r = store.file.run
            if store.file.state == "running", let round = r?.round, round > 0 {
                return "\(round)周目：\(r?.todo ?? 0)件を取っています"
            }
            return "取得係を動かしています"
        case .ng:
            return "\(last) の取得。ほかは全部 OK です"
        case .failed:
            return "\(last)・\(store.file.run?.note ?? "くわしくは取得ログを見てください")。もう一度動かせば、続きから取ります"
        case .stale:
            return "最後に取れたのは \(Fmt.relative(store.lastSuccess, now: store.now))。Mac が止まっていたか、このアプリが閉じていたかもしれません。次に取れば、その間の分もまとめて取ります（抜けません）"
        case .fresh:
            return store.freshText
        }
    }
    @ViewBuilder private func extras(_ s: DisplayState) -> some View {
        switch s {
        case .running:
            ProgressView().progressViewStyle(.linear).tint(.key).padding(.top, 4)
            if let st = Fmt.parseISO(store.file.run?.start), store.file.state == "running" {
                let secs = Int(store.now.timeIntervalSince(st))
                Text("\(Fmt.relative(st, now: store.now)) に開始・経過 \(secs / 60)分\(secs % 60)秒")
                    .font(.system(size: 11)).foregroundStyle(Color.ink2)
            }
        case .ng:
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(store.ngLines.prefix(2).enumerated()), id: \.offset) { _, line in
                    Text(store.readable(line)).font(.system(size: 12)).foregroundStyle(Color.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if store.ngLines.count > 2 {
                    Text("ほか \(store.ngLines.count - 2)件").font(.system(size: 11)).foregroundStyle(Color.ink3)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(.white))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.ngLine, lineWidth: 1))
            .padding(.top, 4)
            HStack(spacing: 8) {
                // 諦めたスレッドだけなら、もう一度取っても直らない（状況ページで既知の例外にできる）
                if !store.onlyGaveUp {
                    DadsButton(title: "もう一度取る", small: true) { store.runNow() }
                }
                DadsButton(title: "詳しく見る", kind: store.onlyGaveUp ? .primary : .quiet, small: true, action: openStatus)
            }
            .padding(.top, 6)
        case .failed:
            HStack(spacing: 8) {
                DadsButton(title: "今すぐ取る", small: true) { store.runNow() }
                DadsButton(title: "取得ログを開く", kind: .quiet, small: true) { store.openLatestLog() }
            }
            .padding(.top, 6)
        case .fresh where !store.configured && !Store.needsMigrate:
            DadsButton(title: "はじめの準備を開く", small: true) { AppDelegate.shared?.openSetup() }.padding(.top, 6)
        case .stale, .fresh:
            DadsButton(title: "今すぐ取る", small: true) { store.runNow() }.padding(.top, 6)
        case .ok:
            EmptyView()
        }
    }
}

struct ChannelList: View {
    @EnvironmentObject var store: Store
    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(store.channels.enumerated()), id: \.element.id) { i, c in
                if i > 0 { Divider().overlay(Color.line) }
                HStack(spacing: 10) {
                    Text(c.tag).font(.system(size: 11, weight: .bold)).foregroundStyle(Color.ink2)
                        .frame(width: 40).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.surface2))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(c.name).font(.system(size: 12)).foregroundStyle(Color.ink)
                            .lineLimit(1).truncationMode(.tail)
                        Text("最後の投稿 " + Fmt.relative(Fmt.parseJST(c.last_post), now: store.now))
                            .font(.system(size: 11)).foregroundStyle(Color.ink3)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(Fmt.number(c.total)).font(.system(size: 13, weight: .bold)).monospacedDigit()
                            .foregroundStyle(Color.ink)
                        if let d = c.delta {
                            Text("+\(d)").font(.system(size: 11)).monospacedDigit().foregroundStyle(Color.okInk)
                        }
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
            }
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(.white))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.line, lineWidth: 1))
    }
}

struct PopoverView: View {
    @EnvironmentObject var store: Store

    private func openStatus() { AppDelegate.shared?.showStatus() }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Slack 取得").font(.system(size: 15, weight: .bold)).foregroundStyle(Color.ink)
                    Text("\(store.channels.count)チャンネル").font(.system(size: 11)).foregroundStyle(Color.ink3)
                }
                Spacer()
                Button(action: openStatus) {
                    Image(systemName: "gearshape").font(.system(size: 15)).foregroundStyle(Color.ink2)
                }
                .buttonStyle(.plain)
                .help("状況ページと設定を開く")
            }

            StatusCard(openStatus: openStatus)

            if !store.channels.isEmpty {   // まだ一度も取っていなければ、見出しの下が空になるので出さない
                VStack(alignment: .leading, spacing: 6) {
                    Text(store.display == .stale
                         ? "チャンネル（\(Fmt.relative(store.lastSuccess, now: store.now)) に取った時点）"
                         : "チャンネル（前回の取得からの増え方）")
                        .font(.system(size: 11, weight: .bold)).foregroundStyle(Color.ink3)
                    ChannelList()
                }
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("毎朝 \(store.timeText) に自動で取る").font(.system(size: 13, weight: .bold)).foregroundStyle(Color.ink)
                    Text(store.autoEnabled ? "次は \(store.nextRunText)・土日も動く" : "自動の取得は止まっています")
                        .font(.system(size: 11)).foregroundStyle(Color.ink3)
                }
                Spacer()
                Toggle("", isOn: $store.autoEnabled).toggleStyle(SwitchStyle())
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 12).fill(.white))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.line, lineWidth: 1))

            HStack(spacing: 8) {
                switch store.display {
                case .running:
                    DadsButton(title: "今すぐ取る", enabled: false) {}
                    DadsButton(title: "止める", kind: .quiet) { store.stop() }
                case .ok:
                    DadsButton(title: "今すぐ取る") { store.runNow() }
                    DadsButton(title: "状況ページを開く", kind: .secondary, action: openStatus)
                case .fresh where !store.configured && !Store.needsMigrate:
                    DadsButton(title: "はじめの準備を開く", kind: .quiet) { AppDelegate.shared?.openSetup() }
                    DadsButton(title: "状況ページを開く", kind: .secondary, action: openStatus)
                default:
                    DadsButton(title: "今すぐ取る", kind: .quiet) { store.runNow() }
                    DadsButton(title: "状況ページを開く", kind: .secondary, action: openStatus)
                }
            }

            if let m = store.message {
                Text(m).font(.system(size: 11)).foregroundStyle(Color.ngInk).fixedSize(horizontal: false, vertical: true)
            }

            Divider().overlay(Color.line)
            VStack(spacing: 0) {
                MenuRow(title: "Slack とチャンネル…") { AppDelegate.shared?.openSetup() }
                MenuRow(title: "取得ログを開く") { store.openLatestLog() }
                MenuRow(title: "記録のフォルダを開く") { store.openFolder() }
                MenuRow(title: "設定…") { openStatus(); store.showSettings = true }
                MenuRow(title: "終了") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 380)
        .background(Color.white)
        .environment(\.colorScheme, .light)
    }
}

// MARK: - 状況ページ（ウィンドウ）

/// マウスを乗せると、下に説明の札を出す（まわりの大きさは変えない）
struct HoverTip<Tip: View>: ViewModifier {
    var alignTrailing = false
    var forced = false
    @ViewBuilder var tip: () -> Tip
    @State private var hovering = false
    @State private var height: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .onHover { hovering = $0 }
            .background(GeometryReader { g in
                Color.clear.onAppear { height = g.size.height }.onChange(of: g.size.height) { _, h in height = h }
            })
            // 札は枠のすぐ下に重ねる（offset なので、まわりの並びは動かない）
            .overlay(alignment: alignTrailing ? .topTrailing : .topLeading) {
                if hovering || forced {
                    tip()
                        .font(.system(size: 12))
                        .foregroundStyle(Color.ink)
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.line2, lineWidth: 1))
                        .shadow(color: .black.opacity(0.14), radius: 14, y: 6)
                        .fixedSize()
                        .offset(y: (height > 0 ? height : 92) + 8)
                        .allowsHitTesting(false)
                }
            }
            .zIndex(hovering || forced ? 10 : 0)
    }
}

extension View {
    func hoverTip<Tip: View>(alignTrailing: Bool = false, forced: Bool = false,
                             @ViewBuilder _ tip: @escaping () -> Tip) -> some View {
        modifier(HoverTip(alignTrailing: alignTrailing, forced: forced, tip: tip))
    }
}

struct Card<Content: View>: View {
    let title: String
    let note: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 15, weight: .bold)).foregroundStyle(Color.ink)
            Text(note).font(.system(size: 11)).foregroundStyle(Color.ink3).padding(.bottom, 10)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(.white))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.line, lineWidth: 1))
    }
}

struct Tile: View {
    let label: String
    let value: String
    let note: String
    var valueColor: Color = .ink
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(label).font(.system(size: 11)).foregroundStyle(Color.ink3)
                Spacer(minLength: 4)
                Image(systemName: "info.circle").font(.system(size: 11)).foregroundStyle(Color(hex: 0xB3B3B3))
            }
            Text(value).font(.system(size: 22, weight: .bold)).monospacedDigit().foregroundStyle(valueColor)
            Text(note).font(.system(size: 11)).foregroundStyle(Color.ink2).lineLimit(2)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(.white))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.line, lineWidth: 1))
        .contentShape(Rectangle())
    }
}

/// 説明の札の中の見出し
struct TipTitle: View {
    let text: String
    var body: some View { Text(text).font(.system(size: 12, weight: .bold)).foregroundStyle(Color.ink) }
}

/// くるくる回るアイコン（取得中の印）
struct SpinningIcon: View {
    let name: String
    @State private var spin = false
    var body: some View {
        Image(systemName: name)
            .rotationEffect(.degrees(spin ? 360 : 0))
            .animation(.linear(duration: 1.2).repeatForever(autoreverses: false), value: spin)
            .onAppear { spin = true }
    }
}

struct StatePill: View {
    @EnvironmentObject var store: Store
    var body: some View {
        let s = spec
        HStack(spacing: 5) {
            if store.display == .running {
                SpinningIcon(name: s.0).font(.system(size: 12, weight: .bold))
            } else {
                Image(systemName: s.0).font(.system(size: 12, weight: .bold))
            }
            Text(s.1).font(.system(size: 12, weight: .bold))
        }
        .foregroundStyle(s.2)
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(Capsule().fill(s.3))
    }
    private var spec: (String, String, Color, Color) {
        switch store.display {
        case .ok: return ("checkmark.circle.fill", "最新・照合 OK", .okInk, .okWash)
        case .running:
            let round = store.file.state == "running" ? (store.file.run?.round ?? 0) : 0
            return ("arrow.triangle.2.circlepath", round > 0 ? "取得中・\(round)周目" : "取得中", .key, .keyWash)
        case .ng: return ("exclamationmark.triangle.fill", "照合 NG \(store.ngLines.count)件", .ngInk, .ngWash)
        case .failed:
            return ("exclamationmark.circle.fill", store.file.state == "stopped" ? "途中で止まった" : "取得に失敗", .ngInk, .ngWash)
        case .stale: return ("clock.badge.exclamationmark", "\(store.staleDays)日間 取れていない", Color(hex: 0x927200), .warnWash)
        case .fresh: return ("tray", "まだ取っていない", .key, .keyWash)
        }
    }
}

struct DailyChart: View {
    @EnvironmentObject var store: Store
    @State private var hovered: String?

    private func label(_ e: DailyEntry) -> String {
        guard let d = Fmt.parseJST(e.date + " 12:00:00") else { return e.date }
        return Fmt.string(d, "M/d")
    }
    private func weekday(_ e: DailyEntry) -> String {
        guard let d = Fmt.parseJST(e.date + " 12:00:00") else { return "" }
        return Fmt.string(d, "E")
    }
    private func niceTop(_ m: Int) -> Int {
        let raw = max(10.0, Double(m) * 1.2)
        let step: Double = raw > 400 ? 100 : raw > 200 ? 50 : raw > 100 ? 25 : 10
        return Int((raw / step).rounded(.up) * step)
    }

    var body: some View {
        let data = store.file.daily ?? []
        let maxTotal = data.map(\.total).max() ?? 0
        let sel = store.previewBar ?? hovered
        Chart(data) { e in
            BarMark(x: .value("日", label(e)), y: .value("件数", e.total), width: .fixed(28))
                .foregroundStyle(sel == label(e) ? Color.keyHover : Color.bar)
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4))
                .annotation(position: .top, spacing: 4) {
                    if e.total == maxTotal && maxTotal > 0 && sel != label(e) {
                        Text("\(e.total)").font(.system(size: 11, weight: .bold)).foregroundStyle(Color.ink)
                    }
                }
        }
        .chartYScale(domain: 0...niceTop(maxTotal))
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine().foregroundStyle(Color.line)
                AxisValueLabel().foregroundStyle(Color.ink3)
            }
        }
        .chartXAxis {
            AxisMarks { v in
                AxisValueLabel {
                    if let s = v.as(String.self) {
                        VStack(spacing: 0) {
                            Text(s).font(.system(size: 11)).foregroundStyle(Color.ink3)
                            Text(data.first { label($0) == s }.map(weekday) ?? "").font(.system(size: 10))
                                .foregroundStyle(Color(hex: 0x949494))
                        }
                    }
                }
            }
        }
        // 吹き出しはグラフの上に重ねる（グラフの大きさは変えない）。半透明で、下の棒が透けて見える
        .chartOverlay { proxy in
            GeometryReader { geo in
                let plot = proxy.plotFrame.map { geo[$0] } ?? CGRect(origin: .zero, size: geo.size)
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let p): hovered = proxy.value(atX: p.x - plot.minX, as: String.self)
                        case .ended: hovered = nil
                        }
                    }
                if let sel, let e = data.first(where: { label($0) == sel }),
                   let x = proxy.position(forX: sel), let y = proxy.position(forY: e.total) {
                    let w: CGFloat = 210
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(label(e))（\(weekday(e))） \(e.total)件").font(.system(size: 12, weight: .bold))
                        Text(store.channels.map { "\($0.tag) \(e.counts[$0.tag] ?? 0)" }.joined(separator: "・"))
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .frame(width: w, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.55)))
                    .position(x: min(max(plot.minX + x, w / 2), geo.size.width - w / 2),
                              y: max(plot.minY + y - 34, 24))
                    .allowsHitTesting(false)
                }
            }
        }
        .frame(height: 230)
    }
}

struct HistoryCard: View {
    @EnvironmentObject var store: Store
    @State private var expanded = false

    var body: some View {
        let recent = store.last30Runs
        let open = expanded || store.previewExpanded
        let rows = open ? recent : Array(store.history.prefix(5))
        Card(title: "取得の記録", note: "毎回の取得の結果（新しい順）。使った量は請求ではなく、プランの枠の目安") {
            HStack(spacing: 18) {
                summary("今月", store.monthRuns)
                summary("過去30日", recent)
                Spacer()
            }
            .padding(.bottom, 10)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    ForEach(["日時", "結果", "新しい投稿・返信", "周", "使った量", "メモ"], id: \.self) {
                        Text($0).font(.system(size: 11, weight: .bold)).foregroundStyle(Color.ink3)
                    }
                }
                Divider().overlay(Color.line)
                ForEach(rows) { e in
                    GridRow {
                        Text(Fmt.relative(Fmt.parseISO(e.start), now: store.now)).font(.system(size: 12))
                        Pill(result: e.result, ng: e.ng)
                        Text("+\(Fmt.number(e.new ?? 0))").font(.system(size: 12)).monospacedDigit()
                            .gridColumnAlignment(.trailing)
                        Text("\(e.rounds ?? 0)").font(.system(size: 12)).monospacedDigit().gridColumnAlignment(.trailing)
                        Text(String(format: "%.2f ドル", e.cost_usd ?? 0)).font(.system(size: 12)).monospacedDigit()
                            .gridColumnAlignment(.trailing)
                        Text(e.note ?? "").font(.system(size: 11)).foregroundStyle(Color.ink3).lineLimit(1)
                            .frame(maxWidth: 300, alignment: .leading)
                    }
                }
            }
            .foregroundStyle(Color.ink)
            if recent.count > 5 || open {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: open ? "chevron.up" : "chevron.down").font(.system(size: 10, weight: .bold))
                        Text(open ? "閉じる" : "過去30日をすべて見る（\(recent.count)回）").font(.system(size: 12, weight: .bold))
                    }
                    .foregroundStyle(Color.key)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 10)
            }
        }
    }

    private func summary(_ label: String, _ runs: [HistoryEntry]) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 11, weight: .bold)).foregroundStyle(Color.ink3)
            Text("\(runs.count)回").font(.system(size: 12)).foregroundStyle(Color.ink)
            Text(String(format: "API換算 約 %.2f ドル", runs.reduce(0) { $0 + ($1.cost_usd ?? 0) }))
                .font(.system(size: 12, weight: .bold)).foregroundStyle(Color.ink)
        }
    }
}

struct WeekChart: View {
    let days: [WeekDay]
    var forcedLabel: String?
    @State private var hovered: String?

    private func label(_ d: WeekDay) -> String {
        guard let t = Fmt.parseJST(d.date + " 12:00:00") else { return d.date }
        return Fmt.string(t, "M/d")
    }
    private func weekday(_ d: WeekDay) -> String {
        guard let t = Fmt.parseJST(d.date + " 12:00:00") else { return "" }
        return Fmt.string(t, "E")
    }

    var body: some View {
        let sel = forcedLabel ?? hovered
        let maxV = days.map(\.total).max() ?? 0
        Chart(days) { d in
            BarMark(x: .value("日", label(d)), y: .value("件数", d.total), width: .ratio(0.6))
                .foregroundStyle(sel == label(d) ? Color.keyHover : Color.bar)
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 3, topTrailingRadius: 3))
                .annotation(position: .top, spacing: 2) {
                    if d.total > 0 && sel != label(d) {
                        Text("\(d.total)").font(.system(size: 10)).foregroundStyle(Color.ink3)
                    }
                }
        }
        .chartYScale(domain: 0...max(1, Double(maxV) * 1.25))
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks { v in
                AxisValueLabel {
                    if let s = v.as(String.self) {
                        VStack(spacing: 0) {
                            Text(s).font(.system(size: 10)).foregroundStyle(Color.ink3)
                            Text(days.first { label($0) == s }.map(weekday) ?? "").font(.system(size: 9))
                                .foregroundStyle(Color(hex: 0x949494))
                        }
                    }
                }
            }
        }
        // 吹き出しはグラフの上に重ねる（大きさは変えない）。半透明で、下の棒が透けて見える
        .chartOverlay { proxy in
            GeometryReader { geo in
                let plot = proxy.plotFrame.map { geo[$0] } ?? CGRect(origin: .zero, size: geo.size)
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let p): hovered = proxy.value(atX: p.x - plot.minX, as: String.self)
                        case .ended: hovered = nil
                        }
                    }
                if let sel, let d = days.first(where: { label($0) == sel }),
                   let x = proxy.position(forX: sel), let y = proxy.position(forY: d.total) {
                    let w: CGFloat = 230
                    let room = max(plot.minY + y - 6, 30)
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        tip(d)
                    }
                    .frame(width: w, height: room, alignment: .bottom)
                    .position(x: min(max(plot.minX + x, w / 2), geo.size.width - w / 2), y: room / 2)
                    .allowsHitTesting(false)
                }
            }
        }
    }

    private func tip(_ d: WeekDay) -> some View {
        let top = d.users.prefix(6)
        let rest = d.users.dropFirst(6)
        return VStack(alignment: .leading, spacing: 3) {
            Text("\(label(d))（\(weekday(d))） \(d.total)件").font(.system(size: 12, weight: .bold))
            if d.users.isEmpty {
                Text("投稿なし").font(.system(size: 11))
            }
            ForEach(Array(top.enumerated()), id: \.offset) { _, u in
                HStack(spacing: 8) {
                    Text(u.name).lineLimit(1)
                    Spacer(minLength: 4)
                    Text("\(u.count)件").monospacedDigit()
                }
                .font(.system(size: 11))
            }
            if !rest.isEmpty {
                Text("ほか \(rest.count)人・\(rest.reduce(0) { $0 + $1.count })件").font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(width: 230, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.68)))
    }
}

struct ChannelPanel: View {
    let c: ChannelInfo
    let now: Date
    var forcedLabel: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(c.tag).font(.system(size: 12, weight: .bold)).foregroundStyle(Color.ink2)
                    .padding(.horizontal, 10).padding(.vertical, 2)
                    .background(Capsule().fill(Color.surface2))
                if (c.external ?? 0) > 0 {  // 社外の人の発言があるチャンネル（Slack コネクト）
                    Text("社外と共有").font(.system(size: 11, weight: .bold)).foregroundStyle(Color.key)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Capsule().fill(Color.keyWash))
                }
                Spacer()
                if let d = c.delta {
                    Text("前回から +\(Fmt.number(d))").font(.system(size: 11)).monospacedDigit().foregroundStyle(Color.okInk)
                }
            }
            Text(c.name).font(.system(size: 12)).foregroundStyle(Color.ink2)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)

            // 主役: 直近7日
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("この7日").font(.system(size: 11)).foregroundStyle(Color.ink3)
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(Fmt.number(c.last7 ?? 0)).font(.system(size: 26, weight: .bold)).monospacedDigit()
                            .foregroundStyle(Color.ink)
                        Text("件").font(.system(size: 12)).foregroundStyle(Color.ink3)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(trend).font(.system(size: 11)).foregroundStyle(Color.ink2)
                    Text("発言した人 \(c.people7 ?? 0)人").font(.system(size: 11)).foregroundStyle(Color.ink3)
                }
            }
            WeekChart(days: c.week ?? [], forcedLabel: forcedLabel).frame(height: 120)
            Text("棒にマウスを乗せると、その日の件数と、誰が何件投稿したかが出ます")
                .font(.system(size: 10)).foregroundStyle(Color.ink3)

            Rectangle().fill(Color.line).frame(height: 1)
            Text("合計（チャンネルができた日から）").font(.system(size: 10, weight: .bold)).foregroundStyle(Color.ink3)
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                      alignment: .leading, spacing: 9) {
                stat("件数", Fmt.number(c.total) + "件")
                stat("親の投稿・返信", "\(Fmt.number(c.parents))・\(Fmt.number(c.replies))")
                stat("返信のあるスレッド", c.threads.map(Fmt.number) ?? "—")
                stat("社外の人の発言", Fmt.number(c.external ?? 0))
                stat("この30日", c.last30.map { Fmt.number($0) + "件" } ?? "—")
                stat("発言した人（全期間）", c.people.map { "\($0)人" } ?? "—")
                stat("できた日", created)
                stat("最後の投稿", Fmt.relative(Fmt.parseJST(c.last_post), now: now))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(.white))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.line, lineWidth: 1))
    }

    /// 前の7日と比べて
    private var trend: String {
        let now7 = c.last7 ?? 0, before = c.prev7 ?? 0
        guard before > 0 else { return "前の7日 \(Fmt.number(before))件" }
        if now7 >= before * 2 {
            return String(format: "前の7日 %@件の 約%.1f倍", Fmt.number(before), Double(now7) / Double(before))
        }
        let pct = Int((Double(now7 - before) / Double(before) * 100).rounded())
        let word = pct > 0 ? "\(pct)% 多い" : pct < 0 ? "\(-pct)% 少ない" : "同じ"
        return "前の7日 \(Fmt.number(before))件より \(word)"
    }

    private var created: String {
        guard let s = c.created, let d = Fmt.parseJST(s + " 12:00:00") else { return "—" }
        return Fmt.string(d, "yyyy/M/d")
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 10)).foregroundStyle(Color.ink3)
            Text(value).font(.system(size: 13, weight: .bold)).monospacedDigit().foregroundStyle(Color.ink)
        }
    }
}

/// 設定の行の上下の余白（設定の窓では詰める）
private struct SettingRowPadKey: EnvironmentKey { static let defaultValue: CGFloat = 11 }
extension EnvironmentValues {
    var settingRowPad: CGFloat {
        get { self[SettingRowPadKey.self] }
        set { self[SettingRowPadKey.self] = newValue }
    }
}

struct SettingRow<C: View>: View {
    let title: String
    let sub: String
    var last = false
    @ViewBuilder var control: C
    @Environment(\.settingRowPad) private var pad
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13)).foregroundStyle(Color.ink)
                Text(sub).font(.system(size: 11)).foregroundStyle(Color.ink3).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            control
        }
        .padding(.vertical, pad)
        .overlay(alignment: .bottom) { if !last { Rectangle().fill(Color.line).frame(height: 1) } }
    }
}

/// 取得に使うモデル（設定の窓）。Haiku・Sonnet・Opus は名前（haiku など）で渡し、Claude Code がその系列の
/// いちばん新しい版を使う。名前が使えなくなったときのために、モデルの名前を直接入れることもできる
struct ModelPicker: View {
    @EnvironmentObject var store: Store
    @State private var custom = false
    @State private var text = ""

    var body: some View {
        HStack(spacing: 8) {
            if custom {
                TextField("例: claude-haiku-4-5", text: $text)
                    .textFieldStyle(.roundedBorder).font(.system(size: 12)).frame(width: 170)
                    .onSubmit(apply)
            }
            Picker("", selection: Binding(
                get: { custom ? "custom" : store.model },
                set: { v in
                    if v == "custom" {
                        if !custom { text = store.model }
                        custom = true
                    } else {
                        custom = false
                        store.model = v
                    }
                })) {
                Text("Haiku（既定）").tag("haiku")
                Text("Sonnet").tag("sonnet")
                Text("Opus").tag("opus")
                Text("名前を入れる…").tag("custom")
            }
            .labelsHidden().frame(width: 150, alignment: .trailing)   // 右端をほかの行の部品とそろえる
        }
        .onAppear {
            custom = !Store.modelAliases.contains(store.model)
            text = custom ? store.model : ""
        }
        .onDisappear(perform: apply)   // 名前を入れて Enter を押さずに閉じたときも、入れた名前にする
    }

    /// 入れた名前をモデルにする（空なら前のまま）
    private func apply() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if custom && !t.isEmpty { store.model = t }
    }
}

/// 設定の窓の見出し（取得・Slack とチャンネル・このアプリ・保存先）
/// 設定の窓の区切り（囲みごとに、見出し・何が決められるか・行）
enum SettingsGroup: String, CaseIterable, Identifiable {
    case fetch, slack, app, base
    var id: String { rawValue }
    var title: String {
        switch self {
        case .fetch: return "取得"
        case .slack: return "Slack とチャンネル"
        case .app: return "このアプリ"
        case .base: return "保存先"
        }
    }
    /// その区切りで何が決められるか（見出しの下に出す。見出しがあるわけが、その場で分かるように）
    var note: String {
        switch self {
        case .fetch: return "いつ取るか・1回にどこまで使うか・どのモデルで取るか"
        case .slack: return "どのチャンネルを取るか・Claude のログイン"
        case .app: return "終わったときの知らせと、アプリの開き方・出し方"
        case .base: return "取ったデータと、取得の仕組みを置くフォルダ"
        }
    }
    var icon: String {
        switch self {
        case .fetch: return "arrow.down.circle"
        case .slack: return "number"
        case .app: return "macwindow"
        case .base: return "folder"
        }
    }
}

/// 中身が画面に収まらないときだけ、スクロールにする（画面の小さい Mac で、窓の下が切れないように）
struct ScrollIfTaller<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder var content: Content
    @State private var height: CGFloat = 0

    var body: some View {
        if height > maxHeight {
            ScrollView { content }.frame(height: maxHeight)
        } else {
            content.background(GeometryReader { g in Color.clear.preference(key: ContentHeightKey.self, value: g.size.height) })
                .onPreferenceChange(ContentHeightKey.self) { height = $0 }
        }
    }
}

private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct SettingsSheet: View {
    /// 囲みを並べた部分の高さの上限（画面の使える高さから、窓の題・設定の見出し・余白を引いたもの）。確認用の画像では使わない
    static var maxGroupsHeight: CGFloat? = (NSScreen.main?.visibleFrame.height).map { $0 - 150 }
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var lastUsedModel: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("設定").font(.system(size: 18, weight: .bold)).foregroundStyle(Color.ink)
                    Text("変えるとすぐに反映されます（保存ボタンはありません）").font(.system(size: 11)).foregroundStyle(Color.ink3)
                }
                Spacer()
                DadsButton(title: "閉じる", kind: .quiet, small: true, shortcut: .cancelAction) { dismiss(); store.showSettings = false }
            }
            .padding(.bottom, 2)
            if let maxH = SettingsSheet.maxGroupsHeight {
                ScrollIfTaller(maxHeight: maxH) { groups }
            } else {
                groups
            }
            if let m = store.message {
                Text(m).font(.system(size: 11)).foregroundStyle(Color.ngInk).padding(.top, 8)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(24)
        .frame(width: 620)
        .background(Color.white)
        .environment(\.colorScheme, .light)
        .environment(\.settingRowPad, 8)
        .onAppear {
            // 開いたときに、どの欄にもキーボードの的を当てない（誤って数字を触っても変わらないように）
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { NSApp.keyWindow?.makeFirstResponder(nil) }
            lastUsedModel = Store.lastUsedModel()
        }
    }

    private var groups: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(SettingsGroup.allCases) { g in group(g) }
        }
    }

    /// 区切りごとに囲む（状況ページのカードと同じ見せ方）。見出しは囲みの中に太字で、何が決められるかを1行そえる
    private func group(_ g: SettingsGroup) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: g.icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.key)
                Text(g.title).font(.system(size: 14, weight: .bold)).foregroundStyle(Color.ink)
            }
            Text(g.note).font(.system(size: 11)).foregroundStyle(Color.ink2).padding(.top, 3)
            rows(g)
        }
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 2)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.line, lineWidth: 1))
        .padding(.top, 10)
    }

    @ViewBuilder private func rows(_ g: SettingsGroup) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            switch g {
            case .fetch:
                SettingRow(title: "毎朝 自動で取る", sub: "このアプリが開いている間、毎日この時刻に動きます（土日も）。Mac が寝ていた日は、起きたときに動きます") {
                    Picker("", selection: $store.hour) {
                        ForEach(0..<24, id: \.self) { Text("\($0)時").tag($0) }
                    }
                    .labelsHidden().frame(width: 78)
                    Picker("", selection: $store.minute) {
                        ForEach(Array(stride(from: 0, to: 60, by: 5)), id: \.self) { Text(String(format: "%02d分", $0)).tag($0) }
                    }
                    .labelsHidden().frame(width: 78)
                    Toggle("", isOn: $store.autoEnabled).toggleStyle(SwitchStyle())
                }
                SettingRow(title: "1回の取得で使ってよい量（API換算）",
                           sub: "1回の取得の合計がこれを超えたら、その回を止めます。月の合計ではありません。請求ではなく、プランの枠の目安です") {
                    Picker("", selection: $store.costCap) {
                        Text("3 ドル").tag(3); Text("5 ドル").tag(5); Text("10 ドル").tag(10)
                    }
                    .labelsHidden().frame(width: 90)
                }
                SettingRow(title: "取得に使うモデル",
                           sub: "どれも、その系列のいちばん新しい版を使います。Sonnet・Opus は使う量（API換算）が Haiku の数倍です。"
                               + "使えなくなったら、ここで変えるか名前を入れてください（チャンネル探しにも効きます）"
                               + (lastUsedModel.map { "\n前回実際に使ったモデル: \($0)" } ?? ""), last: true) {
                    ModelPicker()
                }
            case .slack:
                SettingRow(title: "取るチャンネル",
                           sub: "\(store.channels.count)チャンネル。足す・外す、呼び名や取り始める日を変えるときに（閉じると設定に戻ります）") {
                    DadsButton(title: "開く…", kind: .quiet, small: true) {
                        dismiss()
                        store.showSettings = false
                        // 設定の窓が閉じてから開く（窓の上に窓は重ねられない）
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { AppDelegate.shared?.openSetup(backToSettings: true) }
                    }
                }
                // ログインは、ここでは確かめない（確かめるには Claude を動かすことになる）。最後にうまく取れた時刻で目安を出す
                SettingRow(title: "Claude のログイン",
                           sub: "Claude Code にログインしているアカウントで取ります。最後にうまく取れたのは \(Fmt.relative(store.lastSuccess, now: store.now))。"
                               + "ログインが切れると取得が失敗し、状況ページに出ます", last: true) {
                    EmptyView()
                }
            case .app:
                SettingRow(title: "終わったら通知する", sub: "NG や失敗のときも通知します") {
                    Toggle("", isOn: $store.notify).toggleStyle(SwitchStyle())
                }
                SettingRow(title: "Mac の起動時にこのアプリを開く", sub: "自動の取得には、このアプリが開いている必要があります") {
                    Toggle("", isOn: Binding(get: { store.loginItem }, set: { store.setLoginItem($0) })).toggleStyle(SwitchStyle())
                }
                SettingRow(title: "Dock にアイコンを出す", sub: "メニューバーがいっぱいでアイコンが見えないとき用。Dock のアイコンを押すと、状況ページが開きます", last: true) {
                    Toggle("", isOn: $store.showInDock).toggleStyle(SwitchStyle())
                }
            case .base:
                SettingRow(title: "取得の仕組みのフォルダ",
                           sub: Paths.short(store.basePath) + (store.baseMissing ? "（取得係.sh が見つかりません）" : "")
                               + "。フォルダを動かしても、同じ Mac の中なら自動で追いかけます", last: true) {
                    DadsButton(title: "変更…", kind: .quiet, small: true) { store.chooseBase() }
                }
            }
        }
    }
}

struct StatusContent: View {
    @EnvironmentObject var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            if store.display == .running {
                ProgressView().progressViewStyle(.linear).tint(.key)
            }
            notice
            exceptionsLine
            tiles.zIndex(2)
            Card(title: "日ごとの新しい投稿（\(store.channels.count)チャンネル合計・直近14日）",
                 note: "返信も含む。棒にマウスを乗せると、チャンネルごとの内訳が出ます") {
                DailyChart()
            }
            .zIndex(1)
            Card(title: "チャンネルごとの内訳",
                 note: "主役は直近7日の動き。下に、チャンネルができた日からの合計。数字は最後の取得の時点") {
                // 横に3つまで。4つ以上は折り返す
                let cols = max(1, min(3, store.channels.count))
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .top), count: cols),
                          alignment: .leading, spacing: 14) {
                    ForEach(Array(store.channels.enumerated()), id: \.element.id) { i, c in
                        ChannelPanel(c: c, now: store.now, forcedLabel: i == 0 ? store.previewWeekBar : nil)
                    }
                }
            }
            HistoryCard()
            if let m = store.message {
                Text(m).font(.system(size: 12)).foregroundStyle(Color.ngInk)
            }
            Text("件数と日ごとの投稿は データ/チャンネル/ の記録から、取得の記録は データ/取得の記録.jsonl から出しています（フォルダ: "
                 + (Paths.base.path as NSString).abbreviatingWithTildeInPath + "）。")
                .font(.system(size: 11)).foregroundStyle(Color.ink3)
        }
        .padding(24)
        .background(Color.white)
        .environment(\.colorScheme, .light)
        .sheet(isPresented: $store.showSettings) { SettingsSheet().environmentObject(store) }
    }

    // ---- 見出し: 「状況」と、いまの状態・最後の取得・次の自動取得を1か所にまとめる ----
    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Text("状況").font(.system(size: 22, weight: .bold)).foregroundStyle(Color.ink)
                    StatePill()
                }
                Text(subtitle).font(.system(size: 12)).foregroundStyle(Color.ink3)
            }
            Spacer()
            DadsButton(title: "取得ログを開く", kind: .quiet, small: true) { store.openLatestLog() }
            if store.running {
                DadsButton(title: "止める", kind: .quiet, small: true) { store.stop() }
            }
            if !store.configured && !store.running && !Store.needsMigrate {   // 取るチャンネルが無いうちは、はじめの準備から
                DadsButton(title: "はじめの準備を開く", small: true) { AppDelegate.shared?.openSetup() }
            } else {
                DadsButton(title: store.running ? "取得中…" : "今すぐ取る", small: true, enabled: !store.running) { store.runNow() }
            }
            Button { store.showSettings = true } label: {
                Image(systemName: "gearshape").font(.system(size: 16)).foregroundStyle(Color.ink2)
                    .frame(width: 32, height: 30)
                    .background(RoundedRectangle(cornerRadius: 8).stroke(Color.line2, lineWidth: 1))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("設定")
        }
    }

    private var subtitle: String {
        let r = store.file.run
        let next = store.autoEnabled ? "次の自動取得 \(store.nextRunText)" : "自動の取得は止まっています"
        if store.display == .running {
            if let st = Fmt.parseISO(r?.start), store.file.state == "running" {
                let secs = Int(store.now.timeIntervalSince(st))
                return "\(Fmt.relative(st, now: store.now)) に開始・経過 \(secs / 60)分\(secs % 60)秒・\(r?.todo ?? 0)件を取っています"
            }
            return "取得係を動かしています"
        }
        var parts = ["最後の取得 " + Fmt.relative(store.lastRunEnd, now: store.now)]
        if let rounds = r?.rounds, rounds > 0 {
            parts.append(String(format: "（%d周・API換算 %.2f ドル）", rounds, r?.cost_usd ?? 0))
        }
        return parts.joined() + "　" + next
    }

    // ---- 問題があるときだけ、見出しの下に1行で理由と次の一手 ----
    @ViewBuilder private var notice: some View {
        switch store.display {
        case .ng:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.ngInk)
                Text(store.ngLines.prefix(2).map(store.readable).joined(separator: "／")
                     + (store.ngLines.count > 2 ? "（ほか \(store.ngLines.count - 2)件）" : ""))
                    .font(.system(size: 12)).foregroundStyle(Color.ink2).lineLimit(2)
                Spacer()
                if store.onlyGaveUp {
                    // 3通りの呼び方で取りに行っても別のスレッドが返った（もう一度取っても直らない）
                    DadsButton(title: "既知の例外にする…", small: true) { store.addGaveUpToExceptions() }
                } else {
                    DadsButton(title: "もう一度取る", small: true) { store.runNow() }
                }
            }
        case .failed:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Color.ngInk)
                Text("\(store.file.run?.note ?? "くわしくは取得ログを見てください")。もう一度動かせば、続きから取ります")
                    .font(.system(size: 12)).foregroundStyle(Color.ink2).lineLimit(2)
                Spacer()
            }
        case .stale:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "clock.badge.exclamationmark").foregroundStyle(Color(hex: 0x927200))
                Text("最後に取れたのは \(Fmt.relative(store.lastSuccess, now: store.now))。Mac が止まっていたか、このアプリが閉じていたかもしれません。次に取れば、その間の分もまとめて取ります（抜けません）")
                    .font(.system(size: 12)).foregroundStyle(Color.ink2).lineLimit(2)
                Spacer()
            }
        default:
            EmptyView()
        }
    }

    // ---- 既知の例外（あるときだけ。問題ではないので灰色で。戻せる） ----
    @ViewBuilder private var exceptionsLine: some View {
        if let first = store.exceptionLines.first {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "info.circle").foregroundStyle(Color.ink3)
                Text("既知の例外 \(store.exceptionLines.count)件（Slack 側の食い違いで取りようがないもの。照合では NG にしない）: "
                     + store.readable(first.replacingOccurrences(of: "既知の例外: ", with: ""))
                     + (store.exceptionLines.count > 1 ? "（ほか \(store.exceptionLines.count - 1)件）" : ""))
                    .font(.system(size: 11)).foregroundStyle(Color.ink3).lineLimit(2)
                Spacer()
                Button("戻す") { store.removeException(first) }
                    .buttonStyle(.link).font(.system(size: 11)).help("既知の例外から戻す（照合でまた NG として出る）")
            }
        }
    }

    // ---- 4つの数字（マウスを乗せると説明） ----
    private var tiles: some View {
        HStack(spacing: 12) {
            Tile(label: "ためた投稿（\(store.channels.count)チャンネル）", value: Fmt.number(store.totalPosts),
                 note: "親 \(Fmt.number(store.totalParents))・返信 \(Fmt.number(store.totalPosts - store.totalParents))")
                .hoverTip(forced: store.previewTip == "posts") { postsTip }
            Tile(label: "前回の取得から増えた", value: "+\(Fmt.number(store.newSinceLast))",
                 note: store.channels.map { "\($0.tag) \($0.delta ?? 0)" }.joined(separator: "・"))
                .hoverTip(forced: store.previewTip == "delta") { deltaTip }
            Tile(label: "照合", value: store.ngLines.isEmpty ? "OK" : "NG \(store.ngLines.count)件",
                 note: store.ngLines.isEmpty ? "\(Fmt.number(store.threadsChecked))本のスレッド・期間の抜けなし" : "見出しの下に理由",
                 valueColor: store.ngLines.isEmpty ? .okInk : .ngInk)
                .hoverTip(alignTrailing: true, forced: store.previewTip == "check") { checkTip }
            Tile(label: "今月使った量（API換算の目安）", value: String(format: "約 %.1f ドル", store.monthCost),
                 note: "請求ではなく、プランの枠の目安")
                .hoverTip(alignTrailing: true, forced: store.previewTip == "cost") { costTip }
        }
    }

    private var postsTip: some View {
        VStack(alignment: .leading, spacing: 8) {
            TipTitle(text: "チャンネルごとの件数（チャンネルができた日から）")
            Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 5) {
                GridRow {
                    Text("").gridColumnAlignment(.leading)
                    ForEach(["件数", "親の投稿", "返信"], id: \.self) { Text($0).font(.system(size: 11)).foregroundStyle(Color.ink3) }
                }
                ForEach(store.channels) { c in
                    GridRow {
                        Text("\(c.tag)  \(c.name)").lineLimit(1).frame(maxWidth: 300, alignment: .leading)
                        Text(Fmt.number(c.total)).bold().monospacedDigit()
                        Text(Fmt.number(c.parents)).monospacedDigit()
                        Text(Fmt.number(c.replies)).monospacedDigit()
                    }
                }
                Divider().overlay(Color.line)
                GridRow {
                    Text("合計").bold()
                    Text(Fmt.number(store.totalPosts)).bold().monospacedDigit()
                    Text(Fmt.number(store.totalParents)).monospacedDigit()
                    Text(Fmt.number(store.totalPosts - store.totalParents)).monospacedDigit()
                }
            }
        }
    }

    private var deltaTip: some View {
        VStack(alignment: .leading, spacing: 8) {
            TipTitle(text: "比べた取得")
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                GridRow { Text("前の取得").foregroundStyle(Color.ink3); Text(Fmt.relative(store.prevRunEnd, now: store.now)) }
                GridRow { Text("最後の取得").foregroundStyle(Color.ink3); Text(Fmt.relative(store.lastRunEnd, now: store.now)) }
            }
            TipTitle(text: "チャンネルごとの増え方")
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
                ForEach(store.channels) { c in
                    GridRow {
                        Text("\(c.tag)  \(c.name)").lineLimit(1).frame(maxWidth: 300, alignment: .leading)
                        Text("+\(Fmt.number(c.delta ?? 0))").bold().monospacedDigit().gridColumnAlignment(.trailing)
                    }
                }
            }
            Text("返信も含みます。取り直したスレッドで見つかった、前からあった返信もここに入ります")
                .font(.system(size: 11)).foregroundStyle(Color.ink3).frame(width: 380, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var checkTip: some View {
        VStack(alignment: .leading, spacing: 8) {
            TipTitle(text: "照合で確かめていること（\(Fmt.relative(store.lastRunEnd, now: store.now)) の取得のあと）")
            VStack(alignment: .leading, spacing: 7) {
                ForEach(store.file.check?.items ?? []) { i in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: i.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(i.ok ? Color.okInk : Color.ngInk)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(i.name).bold()
                            Text(i.detail).font(.system(size: 11)).foregroundStyle(Color.ink2)
                                .frame(width: 360, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if (store.file.check?.items ?? []).isEmpty {
                    Text("次の取得のあとに、項目ごとの結果が出ます").foregroundStyle(Color.ink3)
                }
            }
            ForEach(store.file.check?.notes ?? [], id: \.self) {
                Text($0).font(.system(size: 11)).foregroundStyle(Color.ink3).frame(width: 380, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var costTip: some View {
        let runs = store.monthRuns
        let byDay = Dictionary(grouping: runs) { e -> String in
            Fmt.parseISO(e.start).map { Fmt.string($0, "M/d（E）") } ?? "—"
        }
        let days = byDay.keys.sorted { a, b in
            (byDay[a]?.first.flatMap { Fmt.parseISO($0.start) } ?? .distantPast)
                > (byDay[b]?.first.flatMap { Fmt.parseISO($0.start) } ?? .distantPast)
        }
        return VStack(alignment: .leading, spacing: 8) {
            TipTitle(text: String(format: "今月の取得 %d回・API換算 約 %.2f ドル", runs.count, store.monthCost))
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
                ForEach(days.prefix(10), id: \.self) { d in
                    GridRow {
                        Text(d)
                        Text("\(byDay[d]?.count ?? 0)回").foregroundStyle(Color.ink3).gridColumnAlignment(.trailing)
                        Text(String(format: "%.2f ドル", byDay[d]?.reduce(0) { $0 + ($1.cost_usd ?? 0) } ?? 0))
                            .monospacedDigit().gridColumnAlignment(.trailing)
                    }
                }
            }
            Text("1回の取得で使ってよい量: \(store.costCap) ドル（設定で変えられます）。請求ではなく、プランの枠をどれだけ使ったかの目安です")
                .font(.system(size: 11)).foregroundStyle(Color.ink3).frame(width: 340, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct StatusWindowView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var setup: Setup

    var body: some View {
        ScrollView { StatusContent() }
            .frame(minWidth: 980, minHeight: 640)
            .background(Color.white)
            .sheet(isPresented: $setup.show, onDismiss: {
                // 設定の窓から開いたときは、閉じたら設定の窓に戻す
                if setup.backToSettings {
                    setup.backToSettings = false
                    DispatchQueue.main.async { store.showSettings = true }
                }
            }) { SetupSheet().environmentObject(store).environmentObject(setup) }
            .onAppear {
                // 初めて開いたときは、窓が出る前に「準備の窓を出す」と決まっている。窓が出てから出し直す
                if setup.show {
                    setup.show = false
                    DispatchQueue.main.async { setup.show = true }
                }
            }
            // 窓ごと閉じたときに「準備の窓が開いたまま」と残ると、毎朝の自動取得が止まったままになる
            .onDisappear { setup.show = false }
    }
}

// MARK: - 確認用の画像

enum Snapshot {
    @MainActor
    static func run(dir: String) {
        SettingsSheet.maxGroupsHeight = nil   // 確認用の画像では、設定の窓を画面の高さで切らない
        let states: [(String, DisplayState)] = [("ok", .ok), ("running", .running), ("ng", .ng), ("failed", .failed),
                                                ("stale", .stale), ("fresh", .fresh)]
        for (name, st) in states {
            let store = Store(live: false)
            prepare(store, st)
            render(PopoverView().environmentObject(store), to: "\(dir)/menu_\(name).png", width: 380)
            if st != .ok {
                render(StatusContent().environmentObject(store), to: "\(dir)/window_\(name).png", width: 1000)
            }
        }
        render(StatusContent().environmentObject(Store(live: false)), to: "\(dir)/window.png", width: 1000)
        // まだ準備もしていないとき（取るチャンネルが無い。はじめの準備へ案内する）
        let unset = Store(live: false)
        prepare(unset, .fresh)
        unset.configured = false
        render(PopoverView().environmentObject(unset), to: "\(dir)/menu_fresh_unset.png", width: 380)
        render(StatusContent().environmentObject(unset), to: "\(dir)/window_fresh_unset.png", width: 1000)
        // 3通りの呼び方で取りに行っても別のスレッドが返り、諦めたスレッドだけの NG（「既知の例外にする…」が出る）と、
        // 既知の例外があるとき（灰色の1行と「戻す」が出る）
        let ch0 = Store(live: false).channels.first?.id ?? "C0123456789"
        let gave = Store(live: false)
        prepare(gave, .ng)
        gave.file.check?.ng = ["NG 取りに行くと別のスレッドが返る（Slack 側の食い違い・3通りの呼び方で試した）: \(ch0) 1785000000.000100（返信 12）"]
        render(StatusContent().environmentObject(gave), to: "\(dir)/window_ng_gaveup.png", width: 1000)
        render(PopoverView().environmentObject(gave), to: "\(dir)/menu_ng_gaveup.png", width: 380)
        let trying = Store(live: false)
        prepare(trying, .ng)
        trying.file.check?.ng = ["NG 返信を取っていないスレッド（別のスレッドが返ったので、次の取得で別の呼び方を試す・1/3）: \(ch0) 1785000000.000100（返信 12）"]
        render(StatusContent().environmentObject(trying), to: "\(dir)/window_ng_trying.png", width: 1000)
        let exc = Store(live: false)
        prepare(exc, .ok)
        exc.file.check?.ng = []
        exc.file.check?.exceptions = ["既知の例外: \(ch0) 1785000000.000100 … \(Store.gaveUpReason)"]
        render(StatusContent().environmentObject(exc), to: "\(dir)/window_exception.png", width: 1000)
        for tip in ["posts", "delta", "check", "cost"] {
            let s = Store(live: false)
            s.previewTip = tip
            render(StatusContent().environmentObject(s), to: "\(dir)/window_tip_\(tip).png", width: 1000)
        }
        let s = Store(live: false)
        s.previewBar = (s.file.daily ?? []).dropLast(2).last.flatMap { Fmt.parseJST($0.date + " 12:00:00") }.map { Fmt.string($0, "M/d") }
        s.previewExpanded = true
        s.previewWeekBar = (s.channels.first?.week ?? []).dropLast(2).last.flatMap { Fmt.parseJST($0.date + " 12:00:00") }
            .map { Fmt.string($0, "M/d") }
        render(StatusContent().environmentObject(s), to: "\(dir)/window_hover_chart_history.png", width: 1000)
        render(SettingsSheet().environmentObject(Store(live: false)), to: "\(dir)/settings.png", width: 580)
        // 設定の窓は、選択の欄（時刻・上限・モデル）も写るように本物の窓として描く
        renderWindow(SettingsSheet().environmentObject(Store(live: false)), to: "\(dir)/settings_window.png")
        // 画面に収まらないときは中がスクロールになることの確かめ（囲みの部分を 480 までにしたとき）
        SettingsSheet.maxGroupsHeight = 480
        renderWindow(SettingsSheet().environmentObject(Store(live: false)), to: "\(dir)/settings_window_small_screen.png")
        SettingsSheet.maxGroupsHeight = nil
        SetupSnapshot.run(dir: dir)
    }

    @MainActor
    static func prepare(_ store: Store, _ st: DisplayState) {
        store.forced = st
        switch st {
        case .running:
            store.file.state = "running"
            store.file.run = RunInfo(start: Fmt.iso.string(from: Date().addingTimeInterval(-72)), round: 2, todo: 48)
        case .ng:
            // 見本の1行（チャンネルは読み込んだものの1つ目、投稿は2日前の時刻）
            let ch = store.channels.first?.id ?? "C0123456789"
            let ts = String(format: "%.6f", Date().addingTimeInterval(-2 * 86400).timeIntervalSince1970)
            store.file.check?.ng = ["NG 数が合わない: \(ch) \(ts) 表示 23 / スレッドの見出し 20 / 取れた 20"]
        case .failed:
            store.file.state = "stopped"
            store.file.run?.note = "使いすぎ防止の上限（5 ドル）を超えた"
        case .stale:
            store.file.last_success = Fmt.iso.string(from: Date().addingTimeInterval(-2 * 86400 - 3600))
        case .fresh:
            store.file = StateFile()
            store.history = []
        case .ok:
            break
        }
    }

    @MainActor
    static func render<V: View>(_ view: V, to path: String, width: CGFloat, scale: CGFloat = 2) {
        let r = ImageRenderer(content: view.frame(width: width))
        r.scale = scale
        r.proposedSize = ProposedViewSize(width: width, height: nil)
        guard let image = r.nsImage, let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            print("画像にできませんでした: \(path)")
            return
        }
        try? png.write(to: URL(fileURLWithPath: path))
        print("書き出し: \(path)")
    }

    /// 本物の窓として描く（render では黄色い四角になる、選択の欄や入力欄も写る）
    @MainActor
    static func renderWindow<V: View>(_ view: V, to path: String) {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        // 描いたあとに大きさが変わるもの（画面に収まらないときのスクロールなど）は、測り直して描き直す
        let size2 = host.fittingSize
        if size2 != size {
            window.setContentSize(size2)
            host.frame = NSRect(origin: .zero, size: size2)
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            print("画像にできませんでした: \(path)")
            return
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            print("画像にできませんでした: \(path)")
            return
        }
        try? png.write(to: URL(fileURLWithPath: path))
        print("書き出し: \(path)")
    }
}

// MARK: - 確かめ用: フォルダを追いかける仕組み

enum BaseTest {
    /// 一時フォルダで「覚える → 動かす・名前を変える → 追いかける」「ゴミ箱 → 見つからない」などを試す。本物の設定は触らない
    @MainActor
    static func run() -> Int32 {
        Paths.defaults = MemoryStore()   // 本物の設定（と設定のファイル）は触らない
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("slack-fetch-test-\(ProcessInfo.processInfo.processIdentifier)")
        defer { try? fm.removeItem(at: root) }
        var ng = 0
        func check(_ name: String, _ ok: Bool) { print((ok ? "OK  " : "NG  ") + name); if !ok { ng += 1 } }
        func same(_ a: URL?, _ b: URL) -> Bool { a?.resolvingSymlinksInPath().path == b.resolvingSymlinksInPath().path }
        func make(_ u: URL, _ files: [String] = Paths.required) throws {
            try fm.createDirectory(at: u, withIntermediateDirectories: true)
            for f in files { fm.createFile(atPath: u.appendingPathComponent(f).path, contents: Data()) }
        }
        let find = { Paths.resolve(builtIn: false) }
        do {
            let a = root.appendingPathComponent("A/slack-fetch")
            try make(a)
            Paths.remember(a)
            if case .same(let u) = find() { check("覚えた場所で見つかる", same(u, a)) } else { check("覚えた場所で見つかる", false) }

            let b = root.appendingPathComponent("B")
            try fm.createDirectory(at: b, withIntermediateDirectories: true)
            try fm.moveItem(at: a, to: b.appendingPathComponent("slack-fetch"))
            let a2 = b.appendingPathComponent("slack-fetch")
            if case .moved(_, let u) = find() { check("フォルダを動かしても追いかけて、知らせる", same(u, a2)) }
            else { check("フォルダを動かしても追いかけて、知らせる", false) }
            if case .same(let u) = find() { check("追いかけたあとは、新しい場所を覚えている", same(u, a2)) }
            else { check("追いかけたあとは、新しい場所を覚えている", false) }

            let a3 = b.appendingPathComponent("slack-fetch-名前を変えた")
            try fm.moveItem(at: a2, to: a3)
            if case .moved(_, let u) = find() { check("フォルダの名前を変えても追いかける", same(u, a3)) }
            else { check("フォルダの名前を変えても追いかける", false) }

            let trash = root.appendingPathComponent(".Trash")
            try fm.createDirectory(at: trash, withIntermediateDirectories: true)
            try fm.moveItem(at: a3, to: trash.appendingPathComponent("slack-fetch"))
            if case .missing = find() { check("ゴミ箱に入れたら「見つからない」になる", true) }
            else { check("ゴミ箱に入れたら「見つからない」になる", false) }

            let c = root.appendingPathComponent("C/slack-fetch")
            try make(c, ["取得係.sh"])
            check("取得係.sh しか無いフォルダは選べない", Paths.findInside(root.appendingPathComponent("C")) == nil)

            let e = root.appendingPathComponent("E/作業/slack-fetch")
            try make(e)
            check("1つ上のフォルダを選んでも、中から見つける", same(Paths.findInside(root.appendingPathComponent("E")), e))

            Paths.remember(e)
            try fm.removeItem(at: root.appendingPathComponent("E"))
            if case .missing(let last) = find() { check("消したら「見つからない」になり、前の場所を言える", last == e.path) }
            else { check("消したら「見つからない」になり、前の場所を言える", false) }
        } catch {
            print("NG  準備で失敗: \(error)")
            ng += 1
        }
        print(ng == 0 ? "すべて期待どおりです" : "\(ng) 件おかしい")
        return ng == 0 ? 0 : 1
    }
}

// MARK: - アイコン（Dock と Finder 用）

/// Apple の記号（SF Symbols）はアプリのアイコンに使えない決まりなので、図形だけで描く。
/// 吹き出し（Slack の投稿）の中に、下向きの矢印と受け皿（手元にためる）
struct AppIconView: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 186, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0x3460FB), Color(hex: 0x0017C1)], startPoint: .top, endPoint: .bottom))
                .frame(width: 824, height: 824)
            RoundedRectangle(cornerRadius: 96, style: .continuous).fill(.white)
                .frame(width: 560, height: 410).offset(y: -40)
            IconTail().fill(.white).frame(width: 140, height: 130).offset(x: -150, y: 200)
            IconArrow().fill(Color.key).frame(width: 240, height: 230).offset(y: -70)
            Capsule().fill(Color.key).frame(width: 260, height: 40).offset(y: 80)
        }
        .frame(width: 1024, height: 1024)
    }
}

/// 吹き出しのしっぽ（左下へ向かう三角）
struct IconTail: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX + r.width * 0.15, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

/// 下向きの矢印（軸と矢じりを1つの多角形で）
struct IconArrow: Shape {
    func path(in r: CGRect) -> Path {
        let stem = r.width * 0.36
        let headTop = r.minY + r.height * 0.45
        var p = Path()
        p.move(to: CGPoint(x: r.midX - stem / 2, y: r.minY))
        p.addLine(to: CGPoint(x: r.midX + stem / 2, y: r.minY))
        p.addLine(to: CGPoint(x: r.midX + stem / 2, y: headTop))
        p.addLine(to: CGPoint(x: r.maxX, y: headTop))
        p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: headTop))
        p.addLine(to: CGPoint(x: r.midX - stem / 2, y: headTop))
        p.closeSubpath()
        return p
    }
}

// MARK: - アプリ

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static private(set) var shared: AppDelegate?
    let store: Store
    private var statusWindow: NSWindow?
    private var launchedAtLogin = false

    override init() {
        store = Store(live: !CommandLine.arguments.contains("--snapshot") && !CommandLine.arguments.contains("--icon")
                      && !CommandLine.arguments.contains("--test-base") && !CommandLine.arguments.contains("--test-setup"))
        super.init()
        AppDelegate.shared = self
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Mac の起動時に自動で開かれたのか、自分で開いたのか（自分で開いたときだけ状況ページを出す）
        if let ev = NSAppleEventManager.shared().currentAppleEvent,
           ev.eventID == AEEventID(kAEOpenApplication),
           ev.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem) {
            launchedAtLogin = true
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .aqua)
        applyDockSetting()
        // はじめの準備が済んでいなければ、Mac の起動時に開かれたときも出す
        if !launchedAtLogin || store.setup.show { showStatus() }
    }

    // Dock のアイコンを押したとき・Finder でもう一度開いたとき
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showStatus()
        return true
    }

    func applyDockSetting() {
        NSApp.setActivationPolicy(store.showInDock ? .regular : .accessory)
    }

    /// はじめの準備（Slack とチャンネル）の窓を、状況ページの上に開く。設定から開いたときは、閉じたら設定に戻す
    func openSetup(backToSettings: Bool = false) {
        showStatus()
        store.setup.backToSettings = backToSettings
        store.setup.open()
    }

    func showStatus() {
        if statusWindow == nil {
            let host = NSHostingController(rootView: StatusWindowView().environmentObject(store).environmentObject(store.setup))
            host.sizingOptions = [.minSize]
            let w = NSWindow(contentViewController: host)
            w.title = "Slack 取得 — 状況"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 980, height: 880))
            w.center()
            statusWindow = w
        }
        statusWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct MenuIconLabel: View {
    @ObservedObject var store: Store
    var body: some View {
        if #available(macOS 15.0, *), store.display == .running {
            Image(systemName: "arrow.triangle.2.circlepath").symbolEffect(.rotate, options: .repeating)
        } else {
            MenuIcon(state: store.display)
        }
    }
}

@main
struct SlackFetchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            Snapshot.run(dir: args[i + 1])
            exit(0)
        }
        if args.contains("--test-base") {
            exit(BaseTest.run())
        }
        if args.contains("--test-setup") {
            exit(SetupTest.run())
        }
        if let i = args.firstIndex(of: "--icon"), i + 1 < args.count {
            Snapshot.render(AppIconView(), to: args[i + 1], width: 1024, scale: 1)
            exit(0)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView().environmentObject(delegate.store)
        } label: {
            MenuIconLabel(store: delegate.store)
        }
        .menuBarExtraStyle(.window)
    }
}
