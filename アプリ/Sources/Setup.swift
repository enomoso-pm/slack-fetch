// はじめの準備（① Slack をつなぐ → ② 取るチャンネルを選ぶ → ③ 取得を始める）
//
// - 2026-10-09: 準備が済んだあとも、チャンネルを足す・外す・呼び名や取り始める日を変えられるようにした（「Slack とチャンネル」の窓）
// - 初めて開いたとき（データ/チャンネル.json が無いとき）に、状況ページの上に出す。設定とメニューからも開ける。
//   準備が済んでいれば、題は「Slack とチャンネル」で、チャンネルの画面から始まる
// - 「つながったか確かめる」「Slack で探す」「取り始める日の推定」は、このアプリが チャンネル探し.sh を動かす
//   （取得係と同じく、裏で Claude Code を動かす）。結果は データ/チャンネル候補.json に書かれ、ここで読む
// - claude.ai のリンクは、build.sh がアプリに入れた links.json（もとは アプリ/リンク.json）から読む。
//   リンクは変わることがあるので、変わったら リンク.json を直して組み立て直す

import AppKit
import SwiftUI

// MARK: - リンク

struct Links {
    var slackConnector: URL
    var myConnectors: URL
    var orgConnectors: URL
    var slackAdmin: URL
    var help: URL
    var checked: String

    /// アプリに入っている links.json。読めなければ、どれも claude.ai のコネクタの一覧にする
    static let shared: Links = {
        let fallback = URL(string: "https://claude.ai/customize/connectors")!
        var d: [String: Any] = [:]
        if let url = Bundle.main.url(forResource: "links", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            d = obj
        }
        func u(_ key: String) -> URL { (d[key] as? String).flatMap(URL.init(string:)) ?? fallback }
        return Links(slackConnector: u("slack_connector"), myConnectors: u("my_connectors"),
                     orgConnectors: u("org_connectors"), slackAdmin: u("slack_admin"), help: u("help"),
                     checked: d["checked"] as? String ?? "")
    }()
}

// MARK: - データ（データ/チャンネル候補.json・データ/チャンネル.json）

struct OldestInfo: Codable {
    var from: String?
    var basis: String?
    var error: String?
    var at: String?
}

struct Candidate: Codable, Identifiable {
    var id: String
    var name: String
    var isPrivate: Bool?
    var archived: Bool?
    var members: Int?
    var created: String?
    var purpose: String?
    var oldest: OldestInfo?
    enum CodingKeys: String, CodingKey {
        case id, name, archived, members, created, purpose, oldest
        case isPrivate = "private"
    }
}

/// チャンネル探し.sh の最後の結果
struct FinderStatus: Codable {
    var mode: String?
    var query: String?
    var at: String?
    var ok: Bool?
    var connected: Bool?
    var found: Int?
    var dropped: Int?
    var more: Bool?
    var error: String?
}

struct CandidateFile: Codable {
    var updated: String?
    var connected_at: String?
    var last: FinderStatus?
    var channels: [Candidate]?
}

/// チャンネル.json の1行
struct ChannelConfig: Codable {
    var id: String
    var tag: String
    var name: String
    var from: String
}

/// データ/外したチャンネル.json の1行。一覧から外したチャンネルの呼び名と取り始める日を覚えておき、付け直したときに戻す
/// （取ったデータは消さない。付け直せば、前に取った分を使い回して続きから取る）
struct ShelvedChannel: Codable {
    var id: String
    var tag: String
    var name: String
    var from: String
    var removed_at: String?
}

/// 選んだチャンネル（保存する前）
struct Picked: Identifiable {
    enum Source: Equatable { case slack, estimated(String), manual, saved, previous }
    var id: String
    var name: String   // 「#」付き
    var isPrivate: Bool
    var tag: String
    var from: Date?
    var source: Source
}

// MARK: - 状態と操作

@MainActor
final class Setup: ObservableObject {
    enum Conn: Equatable { case unknown, checking, ok, failed(String) }

    @Published var show = false
    @Published var step = 1
    @Published var conn: Conn = .unknown
    @Published var openedConnector = false   // 「Slack のページを開く」を押したか（押したら「確かめる」を目立たせる）
    /// 初めての準備か（開いたときに、保存してあるチャンネルが無かった）。準備済みなら「Slack とチャンネル」の窓として出す
    @Published var firstTime = true
    @Published var confirmClose = false   // 保存していない変更があるのに閉じようとした（聞く）
    @Published var helpOpen = false       // ①の「うまくいかないとき」を開いているか
    /// 設定の窓から開いたか（閉じたら設定の窓に戻す）
    var backToSettings = false
    @Published var query = ""
    @Published var listOpen = true
    @Published var searchingFor: String?
    @Published var searched: String?   // 最後に Slack で探し終えた言葉（候補の欄の案内に使う）
    @Published var note: String?
    @Published var noteIsError = false
    @Published var candidates: [Candidate] = []
    @Published var picked: [Picked] = []
    @Published var estimating = false
    @Published var problem: String?
    /// 保存したときに、前の一覧から足した・外したチャンネル（「#」付きの名前。③で伝える）
    @Published var added: [String] = []
    @Published var removed: [String] = []
    /// 窓を開いたときに保存してあった一覧（✗ で外したものを戻す・変更を捨てるのに使う）
    @Published var savedAtOpen: [ChannelConfig] = []
    /// 前に取っていたチャンネル（データ/外したチャンネル.json）と、保存したときに付け直したもの（③で伝える）
    @Published var shelved: [ShelvedChannel] = []
    @Published var reattached: [String] = []
    /// 保存したあとに呼ぶ（状況ページを数え直す。Store が決める）
    var onSaved: (() -> Void)?
    var connectedAt: String?   // 最後に Slack とつながったのを確かめた時刻（データ/チャンネル候補.json）
    private var lastStatus: FinderStatus?
    private var process: Process?

    var busy: Bool { conn == .checking || searchingFor != nil || estimating }

    /// 入れた言葉（前後の空白と、頭の # は除く）
    var queryText: String {
        var q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.hasPrefix("#") { q.removeFirst() }
        return q
    }

    /// 候補を、入れた言葉で絞り込む（名前か説明に含むもの）。アーカイブ済みは後ろへ
    var filtered: [Candidate] {
        let q = queryText
        return candidates
            .filter { q.isEmpty || $0.name.localizedCaseInsensitiveContains(q) || ($0.purpose ?? "").localizedCaseInsensitiveContains(q) }
            .sorted { ($0.archived == true ? 1 : 0, $0.name) < ($1.archived == true ? 1 : 0, $1.name) }
    }

    /// 開く。すでに保存してあるチャンネルは、選んだ状態から始める
    func open() {
        loadCandidates()
        shelved = Setup.shelvedChannels()
        let saved = Setup.savedChannels()
        // 開くたびに、保存してある一覧から始める（保存していない変更は持ち越さない。✗ で外しても、保存しなければ元のまま）。
        // まだ何も保存していない（はじめの準備の途中）ときだけ、選びかけの一覧を残す
        if !show && (!saved.isEmpty || picked.isEmpty) {
            savedAtOpen = saved
            picked = saved.map(asPicked)
        }
        if conn == .unknown && connectedAt != nil { conn = .ok }
        if !show {
            firstTime = saved.isEmpty
            step = saved.isEmpty && conn != .ok ? 1 : 2
            confirmClose = false
        }
        problem = nil
        show = true
    }

    func go(_ n: Int) {
        guard !busy, n == 1 || n == 2 else { return }   // ③ へは「保存して次へ」からだけ進む
        step = n
    }

    func loadCandidates() {
        guard let data = try? Data(contentsOf: Paths.candidates),
              let f = try? JSONDecoder().decode(CandidateFile.self, from: data) else { return }
        candidates = f.channels ?? []
        lastStatus = f.last
        connectedAt = f.connected_at
    }

    static func savedChannels() -> [ChannelConfig] {
        guard let data = try? Data(contentsOf: Paths.channels) else { return [] }
        return (try? JSONDecoder().decode([ChannelConfig].self, from: data)) ?? []
    }

    static func shelvedChannels() -> [ShelvedChannel] {
        guard let data = try? Data(contentsOf: Paths.shelved) else { return [] }
        return (try? JSONDecoder().decode([ShelvedChannel].self, from: data)) ?? []
    }

    // ---- チャンネル探し.sh を動かす ----

    private enum Outcome { case finished(FinderStatus?), cannotRun(String) }

    /// 終わったら done を呼ぶ。finished には、今回書かれた結果だけを渡す（前の回の結果は渡さない）
    private func runFinder(_ args: [String], done: @escaping (Outcome) -> Void) {
        if Store.launchedFromClaudeCode {
            done(.cannotRun(Store.reopenMessage))
            return
        }
        guard FileManager.default.fileExists(atPath: Paths.finder.path) else {
            done(.cannotRun("取得の仕組みのフォルダに チャンネル探し.sh が見つかりません。設定（歯車）でフォルダを選び直してください。"))
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [Paths.finder.path] + args
        p.environment = Store.scriptEnvironment()
        if let h = Store.appLog("チャンネル探し " + args.joined(separator: " ")) {
            p.standardOutput = h
            p.standardError = h
        }
        let started = Date().addingTimeInterval(-1)   // 書かれる時刻は秒までなので、1秒ゆとりを見る
        p.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.process = nil
                self.loadCandidates()
                let fresh = (Fmt.parseISO(self.lastStatus?.at) ?? .distantPast) >= started
                done(.finished(fresh ? self.lastStatus : nil))
            }
        }
        do {
            try p.run()
            process = p
        } catch {
            done(.cannotRun("チャンネル探し係を動かせませんでした: \(error.localizedDescription)"))
        }
    }

    /// 「つながったか確かめる」: 本当に Slack を読めるかを確かめる（ついでに候補を少し探す）
    func checkConnection() {
        guard !busy else { return }
        conn = .checking
        note = nil
        runFinder(["--check"]) { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .cannotRun(let why):
                self.conn = .failed(why)
                self.helpOpen = true
            case .finished(nil):
                self.conn = .failed("うまく確かめられませんでした。取得ログの「アプリから動かした記録」を見てください。")
                self.helpOpen = true
            case .finished(let st?):
                guard st.connected == true else {
                    self.conn = .failed(st.error ?? "うまく確かめられませんでした。")
                    self.helpOpen = true
                    return
                }
                self.conn = .ok
                let n = st.found ?? 0
                self.setNote(st.error ?? (n > 0 ? "つながりました。候補を \(n)件 見つけました。ほかのチャンネルは、名前の一部を入れて探せます。"
                                                : "つながりました。チャンネル名の一部を入れて探してください。"),
                             error: st.error != nil)
                self.step = 2
            }
        }
    }

    /// 「Slack で探す」（Enter）
    func search() {
        let q = queryText
        guard !q.isEmpty, !busy else { return }
        searchingFor = q
        note = nil
        listOpen = true
        runFinder(["--search", q]) { [weak self] outcome in
            guard let self else { return }
            self.searchingFor = nil
            self.searched = q
            switch outcome {
            case .cannotRun(let why):
                self.setNote(why, error: true)
            case .finished(nil):
                self.setNote("うまく探せませんでした。取得ログの「アプリから動かした記録」を見てください。", error: true)
            case .finished(let st?):
                if st.connected != true {
                    self.conn = .failed(st.error ?? "Slack を読めませんでした。")
                    self.setNote((st.error ?? "Slack を読めませんでした。") + "（①に戻って確かめてください）", error: true)
                } else if let e = st.error {
                    self.setNote(e, error: true)
                } else if (st.found ?? 0) == 0 {
                    self.setNote(Setup.notFoundText(q), error: false)
                } else {
                    self.setNote("「\(q)」で \(st.found ?? 0)件 見つかりました。"
                                 + (st.more == true ? "ほかにもあります（言葉を足すと絞り込めます）。" : ""), error: false)
                }
            }
        }
    }

    /// Slack で探して見つからなかったときの案内（検索は、名前か説明にその言葉をすべて含むチャンネルだけを返す）
    static func notFoundText(_ q: String) -> String {
        "「\(q)」に合うチャンネルは見つかりませんでした。名前や説明に入っている言葉で探します。"
            + "日本語の名前は日本語で（例: notice ではなく お知らせ）。言葉を短くすると見つかりやすくなります。"
    }

    private func setNote(_ text: String, error: Bool) {
        note = text
        noteIsError = error
    }

    // ---- 選ぶ ----

    func isPicked(_ id: String) -> Bool { picked.contains { $0.id == id } }

    func toggle(_ c: Candidate) {
        if let i = picked.firstIndex(where: { $0.id == c.id }) {
            picked.remove(at: i)
            return
        }
        // 前に取っていたチャンネルなら、前の呼び名と取り始める日に戻す（Slack で探し直してチェックを付けたときも）
        if let s = shelved.first(where: { $0.id == c.id }) {
            picked.append(fromShelf(s))
            problem = nil
            return
        }
        var p = Picked(id: c.id, name: "#" + c.name, isPrivate: c.isPrivate ?? false,
                       tag: Setup.suggestTag(c.name, taken: Set(picked.map(\.tag))), from: nil, source: .manual)
        if let d = Setup.day(c.created) {
            p.from = d
            p.source = .slack
        } else if let d = Setup.day(c.oldest?.from) {
            p.from = d
            p.source = .estimated(c.oldest?.basis ?? "")
        }
        picked.append(p)
        problem = nil
    }

    func remove(_ id: String) { picked.removeAll { $0.id == id } }

    /// 前に取っていたチャンネルのうち、いま選んでいないもの（「付け直す」の欄に出す）
    var shelvedNow: [ShelvedChannel] { shelved.filter { s in !isPicked(s.id) } }

    /// 前に取っていたチャンネルを付け直す。前の呼び名と取り始める日に戻す（取ったデータは使い回し、取っていない期間だけを取る）
    func reattach(_ id: String) {
        guard let s = shelved.first(where: { $0.id == id }), !isPicked(id) else { return }
        picked.append(fromShelf(s))
        problem = nil
    }

    private func fromShelf(_ s: ShelvedChannel) -> Picked {
        let taken = Set(picked.map { $0.tag.trimmingCharacters(in: .whitespaces) })
        let bare = s.name.hasPrefix("#") ? String(s.name.dropFirst()) : s.name
        return Picked(id: s.id, name: s.name, isPrivate: candidates.first { $0.id == s.id }?.isPrivate ?? false,
                      tag: taken.contains(s.tag) ? Setup.suggestTag(bare, taken: taken) : s.tag,   // 呼び名が重なるときだけ変える
                      from: Setup.day(s.from), source: .previous)
    }

    /// 保存してある1行を、選んだ一覧の形にする
    func asPicked(_ s: ChannelConfig) -> Picked {
        Picked(id: s.id, name: s.name, isPrivate: candidates.first { $0.id == s.id }?.isPrivate ?? false,
               tag: s.tag, from: Setup.day(s.from), source: .saved)
    }

    /// 保存してあるのに、いま外している（保存すると外れる）チャンネル
    var removedSaved: [ChannelConfig] { savedAtOpen.filter { s in !picked.contains { $0.id == s.id } } }

    /// ✗ で外した、保存してあるチャンネルを戻す（保存してある一覧での順番に戻す）
    func restore(_ id: String) {
        guard let s = savedAtOpen.first(where: { $0.id == id }), !isPicked(id) else { return }
        let order = savedAtOpen.map(\.id)
        let at = picked.firstIndex { p in (order.firstIndex(of: p.id) ?? Int.max) > (order.firstIndex(of: id) ?? 0) } ?? picked.count
        picked.insert(asPicked(s), at: at)
    }

    /// 保存してある一覧から変えたか（足した・外した・呼び名・できた日）
    var changed: Bool {
        picked.map { "\($0.id)|\($0.tag.trimmingCharacters(in: .whitespaces))|\($0.from.map(Setup.dayString) ?? "")" }
            != savedAtOpen.map { "\($0.id)|\($0.tag)|\($0.from)" }
    }

    /// 保存していない変更があるか（準備済みなら保存してある一覧から変えたか、初めてなら何か選んだか）
    var hasUnsaved: Bool { savedAtOpen.isEmpty ? !picked.isEmpty : changed }

    /// 右上の「閉じる」と Esc。保存していない変更があれば、捨ててよいかを聞く
    func close() {
        if hasUnsaved { confirmClose = true } else { closeNow() }
    }

    /// 閉じる（選び直した分は捨てる。次に開くと、保存してある一覧から始まる）。
    /// Slack を探している途中でも閉じられる（探した結果は、次に開いたときに候補に出る）
    func closeNow() {
        picked = savedAtOpen.map(asPicked)
        problem = nil
        confirmClose = false
        show = false
    }

    /// できた日の推定に失敗していれば、その理由
    func estimateError(_ id: String) -> String? {
        candidates.first { $0.id == id }?.oldest.flatMap { $0.from == nil ? $0.error : nil }
    }

    /// 呼び名の案: チャンネル名を - _ . で切り、よくある頭（project・pj など）を除いた最後のまとまりの頭から、
    /// 英数字なら4文字・日本語なら3文字（メニューの呼び名の枠に収まる長さ）
    static func suggestTag(_ name: String, taken: Set<String>) -> String {
        let generic: Set<String> = ["project", "proj", "prj", "pj", "team", "times", "ext", "x", "tmp"]
        let parts = name.split(whereSeparator: { "-_. ".contains($0) }).map(String.init)
        let core = parts.last(where: { !generic.contains($0.lowercased()) }) ?? parts.last ?? name
        let base = String(core.prefix(core.unicodeScalars.allSatisfy(\.isASCII) ? 4 : 3))
        var tag = base
        var i = 2
        while taken.contains(tag) {
            tag = String(base.prefix(3)) + "\(i)"
            i += 1
        }
        return tag
    }

    // ---- 次へ（できた日が分からないものは推定してから保存） ----

    var invalidReason: String? {
        if picked.isEmpty { return "チャンネルを1つ以上選んでください。" }
        if let p = picked.first(where: { $0.tag.trimmingCharacters(in: .whitespaces).isEmpty }) {
            return "\(p.name) の呼び名を入れてください。"
        }
        let tags = picked.map { $0.tag.trimmingCharacters(in: .whitespaces) }
        if Set(tags).count < tags.count { return "呼び名が重なっています。チャンネルごとに違う呼び名にしてください。" }
        return nil
    }

    func next() {
        guard !busy else { return }
        if let why = invalidReason {
            problem = why
            return
        }
        problem = nil
        let missing = picked.filter { $0.from == nil }.map(\.id)
        if missing.isEmpty {
            save()
            return
        }
        estimating = true
        let started = Date().addingTimeInterval(-1)
        runFinder(["--oldest"] + missing) { [weak self] outcome in
            guard let self else { return }
            self.estimating = false
            guard self.show else { return }   // 推定の途中で窓を閉じたら、保存しない（推定した日は候補に残る）
            if case .cannotRun(let why) = outcome {
                self.problem = why
                return
            }
            var failed: [String] = []
            for i in self.picked.indices where self.picked[i].from == nil {
                let o = self.candidates.first { $0.id == self.picked[i].id }?.oldest
                let fresh = (Fmt.parseISO(o?.at) ?? .distantPast) >= started
                if fresh, let d = Setup.day(o?.from) {
                    self.picked[i].from = d
                    self.picked[i].source = .estimated(o?.basis ?? "")
                } else {
                    failed.append("\(self.picked[i].name)（\(fresh ? (o?.error ?? "推定できなかった") : "推定できなかった")）")
                }
            }
            if failed.isEmpty {
                self.save()
            } else {
                self.problem = "取り始める日を推定できなかったチャンネルがあります: " + failed.joined(separator: "・")
                    + "。「日付を入れる」から入れてください（Slack でチャンネル名を押した「チャンネル詳細」に作成日があります）。"
            }
        }
    }

    func save() {
        if let why = invalidReason {
            problem = why
            return
        }
        let before = Setup.savedChannels()
        let shelf = Setup.shelvedChannels()
        do {
            try Setup.write(picked)
            let new = picked.filter { p in !before.contains { $0.id == p.id } }
            added = new.filter { p in !shelf.contains { $0.id == p.id } }.map(\.name)
            reattached = new.filter { p in shelf.contains { $0.id == p.id } }.map(\.name)
            let gone = before.filter { s in !picked.contains { $0.id == s.id } }
            removed = gone.map(\.name)
            // 外したチャンネルを覚える（付け直したものは消す）。書けなくても、取るチャンネルの一覧は保存できている
            let now = Fmt.iso.string(from: Date())
            let next = shelf.filter { s in !picked.contains { $0.id == s.id } && !gone.contains { $0.id == s.id } }
                + gone.map { ShelvedChannel(id: $0.id, tag: $0.tag, name: $0.name, from: $0.from, removed_at: now) }
            try? Setup.writeShelved(next)
            shelved = next
            savedAtOpen = Setup.savedChannels()
            problem = nil
            step = 3
            onSaved?()
        } catch {
            problem = "チャンネル.json に書けませんでした: \(error.localizedDescription)"
        }
    }

    /// 文字を JSON の文字列にする（日本語はそのまま）
    static func js(_ s: String) -> String {
        let d = (try? JSONSerialization.data(withJSONObject: s, options: [.fragmentsAllowed, .withoutEscapingSlashes]))
            ?? Data("\"\"".utf8)
        return String(decoding: d, as: UTF8.self)
    }

    /// データ/外したチャンネル.json に、1チャンネル1行で書く
    static func writeShelved(_ list: [ShelvedChannel]) throws {
        let rows = list.map { s in
            "{\"id\": \(js(s.id)), \"tag\": \(js(s.tag)), \"name\": \(js(s.name)), \"from\": \(js(s.from)), "
                + "\"removed_at\": \(js(s.removed_at ?? ""))}"
        }
        let text = rows.isEmpty ? "[]\n" : "[\n " + rows.joined(separator: ",\n ") + "\n]\n"
        try text.write(to: Paths.shelved, atomically: true, encoding: .utf8)
    }

    /// データ/チャンネル.json に、1チャンネル1行で書く（今の チャンネル.json と同じ形）
    static func write(_ list: [Picked]) throws {
        let rows = list.map { p in
            "{\"id\": \(js(p.id)), \"tag\": \(js(p.tag.trimmingCharacters(in: .whitespaces))), "
                + "\"name\": \(js(p.name)), \"from\": \(js(dayString(p.from ?? Date())))}"
        }
        try ("[\n " + rows.joined(separator: ",\n ") + "\n]\n").write(to: Paths.channels, atomically: true, encoding: .utf8)
    }

    // ---- 日付（日本時間の日で扱う） ----

    static let jst = TimeZone(identifier: "Asia/Tokyo")!

    /// "2025-01-15" → その日の正午（日本時間）
    static func day(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        return Fmt.parseJST(s + " 12:00:00")
    }

    static func dayString(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = jst
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    /// 推定の根拠（"2023-04" や "~2013"）を読める形に
    static func basisText(_ basis: String) -> String {
        if basis.hasPrefix("~") { return "2014年より前" }
        let p = basis.split(separator: "-")
        guard p.count == 2, let y = Int(p[0]), let m = Int(p[1]) else { return basis }
        return "\(y)年\(m)月"
    }
}

// MARK: - 部品

struct CheckBox: View {
    let on: Bool
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(on ? Color.key : Color.white)
            RoundedRectangle(cornerRadius: 4).stroke(on ? Color.key : Color.ink3, lineWidth: 1.5)
            if on {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .heavy)).foregroundStyle(.white)
            }
        }
        .frame(width: 18, height: 18)
    }
}

/// 外のページを開くボタン（ブラウザで開く印つき）
struct LinkButton: View {
    let title: String
    let url: URL
    var primary = false
    var action: () -> Void = {}
    @State private var hover = false

    var body: some View {
        Button {
            action()
            NSWorkspace.shared.open(url)
        } label: {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 13, weight: .bold))
                Image(systemName: "arrow.up.right.square").font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(primary ? Color.white : Color.key)
            .padding(.vertical, 9).padding(.horizontal, 14)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(primary ? (hover ? Color.keyHover : Color.key) : (hover ? Color.keyWash : Color.white)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(primary ? Color.clear : Color.key, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(url.absoluteString)
    }
}

/// 文の中の小さなリンク
struct LinkLine: View {
    let lead: String
    let title: String
    let url: URL
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(lead + "：").font(.system(size: 12)).foregroundStyle(Color.ink2)
            Button { NSWorkspace.shared.open(url) } label: {
                HStack(spacing: 3) {
                    Text(title).underline()
                    Image(systemName: "arrow.up.right.square").font(.system(size: 10))
                }
                .font(.system(size: 12)).foregroundStyle(Color.key)
            }
            .buttonStyle(.plain)
            .help(url.absoluteString)
        }
    }
}

struct Notice<Content: View>: View {
    enum Kind { case info, ok, error }
    let kind: Kind
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: kind == .ok ? "checkmark.circle.fill" : kind == .error ? "exclamationmark.circle.fill" : "info.circle.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(kind == .ok ? Color.okInk : kind == .error ? Color.ngInk : Color.key)
            VStack(alignment: .leading, spacing: 3) { content }
                .font(.system(size: 12)).foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(kind == .ok ? Color.okWash : kind == .error ? Color.ngWash : Color.keyWash))
    }
}

/// 番号つきの手順の1行
struct NumberedLine<Extra: View>: View {
    let n: Int
    let title: String
    var sub: String?
    @ViewBuilder var extra: Extra

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)").font(.system(size: 12, weight: .bold)).foregroundStyle(Color.key)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.keyWash))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .bold)).foregroundStyle(Color.ink)
                if let sub {
                    Text(sub).font(.system(size: 12)).foregroundStyle(Color.ink2).fixedSize(horizontal: false, vertical: true)
                }
                extra
            }
            Spacer(minLength: 0)
        }
    }
}

extension NumberedLine where Extra == EmptyView {
    init(n: Int, title: String, sub: String? = nil) {
        self.init(n: n, title: title, sub: sub, extra: { EmptyView() })
    }
}

/// 初めての準備の手順（見るだけ。画面は下の「戻る」「次へ」で移る）
struct StepBar: View {
    let step: Int
    let connected: Bool   // ①は、確かめてつながったときだけチェックを付ける
    private let titles = ["Slack をつなぐ", "チャンネルを選ぶ", "取得を始める"]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Array(titles.enumerated()), id: \.offset) { i, title in
                let n = i + 1
                let done = n < step && (n != 1 || connected)
                if i > 0 { Rectangle().fill(Color.line2).frame(width: 24, height: 1) }
                HStack(spacing: 6) {
                    ZStack {
                        Circle().fill(n == step ? Color.key : done ? Color.okInk : Color.surface2)
                        if done {
                            Image(systemName: "checkmark").font(.system(size: 10, weight: .heavy)).foregroundStyle(.white)
                        } else {
                            Text("\(n)").font(.system(size: 11, weight: .bold)).foregroundStyle(n == step ? Color.white : Color.ink2)
                        }
                    }
                    .frame(width: 22, height: 22)
                    Text(title).font(.system(size: 12, weight: n == step ? .bold : .regular))
                        .foregroundStyle(n == step ? Color.ink : Color.ink2)
                }
            }
        }
    }
}

/// 準備済みのときに、チャンネルの画面の上に出す Slack とのつながり（1行）
struct ConnectionLine: View {
    @EnvironmentObject var setup: Setup

    var body: some View {
        HStack(spacing: 8) {
            switch setup.conn {
            case .checking:
                ProgressView().controlSize(.small)
                Text("Slack を読めるか確かめています（20〜60秒）…").foregroundStyle(Color.ink2)
            case .failed(let why):
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Color.ngInk)
                Text("Slack: まだ読めません。\(why)").foregroundStyle(Color.ngInk).lineLimit(2)
            case .ok:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.okInk)
                Text("Slack: つながっています" + (checkedText.map { "（\($0) に確かめた）" } ?? "")).foregroundStyle(Color.ink2)
            case .unknown:
                Image(systemName: "questionmark.circle").foregroundStyle(Color.ink3)
                Text("Slack: まだ確かめていません").foregroundStyle(Color.ink2)
            }
            Spacer(minLength: 8)
            Button("確かめる") { setup.checkConnection() }
                .buttonStyle(.link).disabled(setup.busy)
            Button("つなぎ方を見る") { setup.go(1) }
                .buttonStyle(.link).disabled(setup.busy)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.surface2))
    }

    private var checkedText: String? {
        Fmt.parseISO(setup.connectedAt).map { Fmt.string($0, "M/d H:mm") }
    }
}

// MARK: - ① Slack をつなぐ

struct ConnectStep: View {
    @EnvironmentObject var setup: Setup

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(setup.firstTime ? "claude.ai で Slack をつなぐ" : "Slack のつなぎ方").font(.system(size: 16, weight: .bold)).foregroundStyle(Color.ink)
                Text(setup.firstTime
                     ? "このアプリは、claude.ai の Slack 連携（コネクタ）を通して Slack を読みます。はじめに1回だけ、ブラウザで Slack をつないでください。"
                     : "このアプリは、claude.ai の Slack 連携（コネクタ）を通して Slack を読みます。つながりが切れたときは、ここからつなぎ直してください。")
                    .font(.system(size: 13)).foregroundStyle(Color.ink2).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 14) {
                NumberedLine(n: 1, title: "下のボタンで、claude.ai の Slack のページを開く",
                             sub: "ブラウザで開きます。claude.ai にログインしていなければ、先にログインします") {
                    LinkButton(title: "claude.ai の Slack のページを開く", url: Links.shared.slackConnector, primary: true) {
                        setup.openedConnector = true
                    }
                    .padding(.top, 6)
                }
                NumberedLine(n: 2, title: "ページの「Connect to Claude」を押す",
                             sub: "日本語の画面では、同じ場所のボタンが日本語で出ます。「Request」と出るときは、下の「Team・Enterprise プランのとき」を見てください")
                NumberedLine(n: 3, title: "Slack の画面で、ワークスペースを確かめて「許可する」を押す",
                             sub: "終わると claude.ai に戻り、Slack が「Connected」（接続済み）になります")
                NumberedLine(n: 4, title: "このアプリに戻って「つながったか確かめる」を押す",
                             sub: "アプリが、本当に Slack を読めるかを確かめます（20〜60秒）")
            }
            status
            // うまくいかないときのリンク（ふだんは閉じておく。確かめて失敗したら開く）
            VStack(alignment: .leading, spacing: 7) {
                Button { setup.helpOpen.toggle() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: setup.helpOpen ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .bold))
                        Text("うまくいかないとき").font(.system(size: 11, weight: .bold))
                    }
                    .foregroundStyle(Color.ink2).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if setup.helpOpen {
                    LinkLine(lead: "つながったかを見る", title: "自分のコネクタの一覧", url: Links.shared.myConnectors)
                    LinkLine(lead: "Team・Enterprise プランのとき", title: "組織のコネクタ設定（組織の Owner が先に Slack を有効にする）",
                             url: Links.shared.orgConnectors)
                    LinkLine(lead: "Slack 側で管理者の承認が要るとき", title: "Slack 管理者向けの設定ガイド", url: Links.shared.slackAdmin)
                    LinkLine(lead: "くわしい説明", title: "Slack 連携の説明（claude.com）", url: Links.shared.help)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.surface2))
        }
    }

    @ViewBuilder private var status: some View {
        switch setup.conn {
        case .checking:
            Notice(kind: .info) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Slack を読めるか確かめています（20〜60秒）…")
                }
            }
        case .failed(let why):
            Notice(kind: .error) {
                Text("まだ Slack を読めません").bold()
                Text(why)
            }
        case .ok:
            Notice(kind: .ok) { Text(setup.firstTime ? "Slack とつながっています。「次へ」でチャンネルを選びます。" : "Slack とつながっています。") }
        case .unknown:
            EmptyView()
        }
    }
}

// MARK: - ② チャンネルを選ぶ

struct PickStep: View {
    @EnvironmentObject var setup: Setup

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !setup.firstTime { ConnectionLine() }
            VStack(alignment: .leading, spacing: 6) {
                Text(setup.firstTime ? "取るチャンネルを選ぶ" : "チャンネルを探して足す").font(.system(size: 16, weight: .bold)).foregroundStyle(Color.ink)
                Text(setup.firstTime
                     ? "名前の一部を入れて Enter を押すと、Slack から探します（20〜60秒）。取りたいチャンネルにチェックを付けてください。"
                     : "名前の一部を入れて Enter を押すと、Slack から探します（20〜60秒）。チェックを付けると、下の「取るチャンネル」に入ります。")
                    .font(.system(size: 13)).foregroundStyle(Color.ink2).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 5) {
                ChannelCombo()
                Text("名前や説明に入っている言葉で探します（日本語の名前は日本語で）。入れた言葉で、下の候補もその場で絞り込みます。"
                     + "Slack で探すたびに、Claude を1回動かします")
                    .font(.system(size: 11)).foregroundStyle(Color.ink3).fixedSize(horizontal: false, vertical: true)
            }
            if let note = setup.note {
                Text(note).font(.system(size: 12)).foregroundStyle(setup.noteIsError ? Color.ngInk : Color.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            PickedList()
            if !setup.shelvedNow.isEmpty { ShelvedList() }
            if let p = setup.problem {
                Notice(kind: .error) { Text(p) }
            }
        }
    }
}

/// 検索できるコンボボックス（打つと候補を絞り込み、Enter で Slack を探す。チェックで複数選べる）
struct ChannelCombo: View {
    @EnvironmentObject var setup: Setup
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(Color.ink3)
                TextField("チャンネル名の一部（例: project、お知らせ）", text: $setup.query)
                    .textFieldStyle(.plain).font(.system(size: 14))
                    .focused($focused)
                    .onSubmit { setup.search() }
                    .onChange(of: setup.query) { _, _ in setup.listOpen = true }
                if setup.searchingFor != nil {
                    ProgressView().controlSize(.small)
                } else if !setup.query.isEmpty {
                    Button { setup.query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Color(hex: 0xB3B3B3))
                    }
                    .buttonStyle(.plain).help("消す")
                }
                Button { setup.search() } label: {
                    Text("Slack で探す").font(.system(size: 12, weight: .bold))
                        .foregroundStyle(setup.queryText.isEmpty || setup.busy ? Color(hex: 0x949494) : Color.key)
                        .padding(.horizontal, 6).padding(.vertical, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(setup.queryText.isEmpty || setup.busy)
                Rectangle().fill(Color.line2).frame(width: 1, height: 18)
                Button { setup.listOpen.toggle() } label: {
                    Image(systemName: setup.listOpen ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .bold)).foregroundStyle(Color.ink2)
                        .frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(setup.listOpen ? "候補を閉じる" : "候補を開く")
            }
            .padding(.horizontal, 12).frame(height: 42)
            if setup.listOpen {
                Rectangle().fill(Color.line).frame(height: 1)
                list
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(focused ? Color.key : Color.line2, lineWidth: focused ? 2 : 1))
    }

    private var list: some View {
        let rows = setup.filtered
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let q = setup.searchingFor {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Slack で「\(q)」を探しています（20〜60秒）…").font(.system(size: 12)).foregroundStyle(Color.ink2)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                }
                ForEach(rows) { c in
                    CandidateRow(c: c, on: setup.isPicked(c.id)) { setup.toggle(c) }
                    Rectangle().fill(Color.line).frame(height: 1).padding(.leading, 40)
                }
                if rows.isEmpty && setup.searchingFor == nil {
                    Text(!setup.queryText.isEmpty && setup.searched == setup.queryText
                         ? "「\(setup.queryText)」は Slack でも見つかりませんでした。下の案内を見てください。"
                         : setup.candidates.isEmpty
                         ? "まだ候補がありません。チャンネル名の一部を入れて Enter を押すと、Slack で探します。"
                         : "「\(setup.queryText)」に合う候補はまだありません。Enter を押すと、Slack で探します。")
                        .font(.system(size: 12)).foregroundStyle(Color.ink3)
                        .padding(12)
                }
            }
        }
        .frame(height: 200)
    }
}

struct CandidateRow: View {
    let c: Candidate
    let on: Bool
    let toggle: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: toggle) {
            HStack(alignment: .top, spacing: 10) {
                CheckBox(on: on).padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("#" + c.name).font(.system(size: 13, weight: .bold)).foregroundStyle(Color.ink).lineLimit(1)
                        if c.isPrivate == true {
                            Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(Color.ink3).help("非公開のチャンネル")
                        }
                        if c.archived == true {
                            Text("アーカイブ済み").font(.system(size: 10, weight: .bold)).foregroundStyle(Color.ink2)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Capsule().fill(Color.surface2))
                        }
                        Spacer(minLength: 8)
                        Text(meta).font(.system(size: 11)).foregroundStyle(Color.ink3).monospacedDigit()
                    }
                    if let p = c.purpose, !p.isEmpty {
                        Text(p).font(.system(size: 11)).foregroundStyle(Color.ink2).lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(hover ? Color.surface2 : on ? Color.keyWash.opacity(0.6) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }

    private var meta: String {
        var parts: [String] = []
        if let m = c.members { parts.append("\(m)人") }
        if let d = Setup.day(c.created) { parts.append(Fmt.string(d, "yyyy/M/d") + " 作成") }
        return parts.joined(separator: "・")
    }
}

struct PickedList: View {
    @EnvironmentObject var setup: Setup

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text((setup.firstTime ? "選んだチャンネル" : "取るチャンネル") + "（\(setup.picked.count)）")
                    .font(.system(size: 12, weight: .bold)).foregroundStyle(Color.ink)
                Spacer()
                Text("呼び名は、アプリの表示に使う短い名前（2〜4文字）")
                    .font(.system(size: 11)).foregroundStyle(Color.ink3)
            }
            if setup.picked.isEmpty {
                Text("まだ選んでいません。上の候補にチェックを付けてください。")
                    .font(.system(size: 12)).foregroundStyle(Color.ink3)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.line2, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            } else {
                // 4行を超えたら、この中でスクロールする（窓が画面からはみ出さないように）
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach($setup.picked) { $p in
                            PickedRow(p: $p)
                            if p.id != setup.picked.last?.id { Rectangle().fill(Color.line).frame(height: 1) }
                        }
                    }
                }
                .frame(height: CGFloat(min(setup.picked.count, 4)) * PickedRow.height)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.line, lineWidth: 1))
                if setup.picked.count > 4 {
                    Text("ほか \(setup.picked.count - 4) つは、一覧の中を下へスクロールすると見られます")
                        .font(.system(size: 11)).foregroundStyle(Color.ink2)
                }
            }
            // ✗ で外した、保存してあるチャンネル。保存するまでは外れないので、ここから戻せる
            if !setup.removedSaved.isEmpty {
                VStack(spacing: 0) {
                    ForEach(setup.removedSaved, id: \.id) { c in
                        HStack(spacing: 10) {
                            Text(c.name).strikethrough().font(.system(size: 13, weight: .bold)).foregroundStyle(Color.ink3)
                                .lineLimit(1).truncationMode(.middle)
                            Text("保存すると外れます（取ったデータは残り、あとで付け直せます）").font(.system(size: 11)).foregroundStyle(Color.warnInk)
                            Spacer(minLength: 8)
                            Button("戻す") { setup.restore(c.id) }
                                .buttonStyle(.link).font(.system(size: 12, weight: .bold))
                                .disabled(setup.busy)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 9)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.warnWash))
            }
            if !setup.picked.isEmpty {
                Text(setup.firstTime
                     ? "取り始める日から今日までの分を、最初の取得でまとめて取ります。チャンネルができた日が分かれば、その日にします。"
                     : "取り始める日を前にずらすと、その前の分だけを足して取ります（取ってあるところは取り直しません）。後ろにずらしても、取ったデータは消えません。")
                    .font(.system(size: 11)).foregroundStyle(Color.ink3).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// 前に取っていたチャンネル（今は取っていない）。付け直すと、前の呼び名と取り始める日に戻し、続きから取る
struct ShelvedList: View {
    @EnvironmentObject var setup: Setup

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("前に取っていたチャンネル（今は取っていない・取ったデータは残っています）")
                .font(.system(size: 12, weight: .bold)).foregroundStyle(Color.ink)
            VStack(spacing: 0) {
                ForEach(setup.shelvedNow, id: \.id) { c in
                    HStack(spacing: 10) {
                        Text(c.name).font(.system(size: 13, weight: .bold)).foregroundStyle(Color.ink2)
                            .lineLimit(1).truncationMode(.middle)
                        Text(detail(c)).font(.system(size: 11)).foregroundStyle(Color.ink3).lineLimit(1)
                        Spacer(minLength: 8)
                        Button("付け直す") { setup.reattach(c.id) }
                            .buttonStyle(.link).font(.system(size: 12, weight: .bold))
                            .disabled(setup.busy)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    if c.id != setup.shelvedNow.last?.id { Rectangle().fill(Color.line).frame(height: 1) }
                }
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.surface2))
            Text("付け直すと、前の呼び名と取り始める日に戻します。前に取った分は使い回して、取っていない期間（外していた間）と最近の分だけを取ります。")
                .font(.system(size: 11)).foregroundStyle(Color.ink3).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }

    private func detail(_ c: ShelvedChannel) -> String {
        let from = Setup.day(c.from).map { Fmt.string($0, "yyyy/M/d") } ?? c.from
        let gone = Fmt.parseISO(c.removed_at).map { "・" + Fmt.string($0, "M/d") + " に外した" } ?? ""
        return "呼び名 \(c.tag)・\(from) から" + gone
    }
}

struct PickedRow: View {
    static let height: CGFloat = 43   // 1行の高さ（区切りの線を含む）
    @Binding var p: Picked
    @EnvironmentObject var setup: Setup

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 5) {
                Text(p.name).font(.system(size: 13, weight: .bold)).foregroundStyle(Color.ink)
                    .lineLimit(1).truncationMode(.middle)
                if p.isPrivate {
                    Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(Color.ink3)
                }
            }
            .frame(width: 176, alignment: .leading)
            HStack(spacing: 6) {
                Text("呼び名").font(.system(size: 11)).foregroundStyle(Color.ink3)
                TextField("", text: $p.tag).textFieldStyle(.roundedBorder).font(.system(size: 12)).frame(width: 60)
            }
            HStack(spacing: 6) {
                Text("取り始める日").font(.system(size: 11)).foregroundStyle(Color.ink3)
                if let d = p.from {
                    DatePicker("", selection: Binding(get: { d }, set: { p.from = $0; p.source = .manual }), displayedComponents: .date)
                        .labelsHidden().datePickerStyle(.field).frame(width: 104)
                        .environment(\.locale, Locale(identifier: "ja_JP"))
                        .environment(\.timeZone, Setup.jst)
                    Text(sourceText).font(.system(size: 10)).foregroundStyle(Color.ink3)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        .frame(width: 116, alignment: .leading)
                } else {
                    Text(pendingText).font(.system(size: 12))
                        .foregroundStyle(setup.estimateError(p.id) == nil ? Color.ink3 : Color.ngInk)
                    Button("日付を入れる") {
                        p.from = Calendar.current.date(byAdding: .year, value: -1, to: Date())
                        p.source = .manual
                    }
                    .buttonStyle(.link).font(.system(size: 11))
                    .disabled(setup.estimating)
                }
            }
            Spacer(minLength: 0)
            Button { setup.remove(p.id) } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Color.ink3)
                    .frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("外す")
            .disabled(setup.estimating)
        }
        .padding(.horizontal, 12)
        .frame(height: PickedRow.height - 1)
    }

    /// 取り始める日がまだ無いときの表示
    private var pendingText: String {
        if setup.estimating { return "推定しています…" }
        return setup.estimateError(p.id) == nil ? "（保存のときに推定）" : "推定できず"
    }

    private var sourceText: String {
        switch p.source {
        case .slack: return "Slack の作成日"
        case .estimated(let basis): return "推定（いちばん古い投稿 \(Setup.basisText(basis))）"
        case .manual: return "入力した日"
        case .saved: return "今の設定"
        case .previous: return "前に取っていた日"
        }
    }
}

// MARK: - ③ 取得を始める

struct StartStep: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var setup: Setup

    /// まだ一度も取っていないか（取ったことがあれば、チャンネルの変更として伝える）
    private var first: Bool { store.history.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(first ? "取得を始める" : "保存しました").font(.system(size: 16, weight: .bold)).foregroundStyle(Color.ink)
                Text("\(setup.picked.count)チャンネルを データ/チャンネル.json に保存しました。")
                    .font(.system(size: 13)).foregroundStyle(Color.ink2)
            }
            VStack(spacing: 0) {
                ForEach(setup.picked) { p in
                    HStack(spacing: 10) {
                        Text(p.tag).font(.system(size: 11, weight: .bold)).foregroundStyle(Color.ink2)
                            .frame(minWidth: 40).padding(.vertical, 2).padding(.horizontal, 4)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.surface2))
                        Text(p.name).font(.system(size: 13, weight: .bold)).foregroundStyle(Color.ink).lineLimit(1)
                        Spacer()
                        Text(fromText(p)).font(.system(size: 12)).foregroundStyle(Color.ink2)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    if p.id != setup.picked.last?.id { Rectangle().fill(Color.line).frame(height: 1) }
                }
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.line, lineWidth: 1))
            Notice(kind: .info) {
                if first {
                    Text("最初の取得では、取り始める日からの分をまとめて取ります。量が多いと数十分かかります。\(resumeText)")
                } else {
                    if !setup.added.isEmpty {
                        Text("足したチャンネル（\(setup.added.joined(separator: "・"))）は、\(nextFetch)で、取り始める日からの分をまとめて取ります。量が多いと数十分かかります。\(resumeText)")
                    }
                    if !setup.reattached.isEmpty {
                        Text("付け直したチャンネル（\(setup.reattached.joined(separator: "・"))）は、前に取った分を使い回して、\(nextFetch)で、外していた間と最近の分だけを取ります。外していた間が長いと、量が多めになります。")
                    }
                    if !setup.removed.isEmpty {
                        Text("外したチャンネル（\(setup.removed.joined(separator: "・"))）の取ったデータは消えずに、データ/チャンネル/ に残ります。これからは取らず、状況ページの数にも入れません。あとで付け直せます。")
                    }
                    if setup.added.isEmpty && setup.reattached.isEmpty && setup.removed.isEmpty {
                        Text("取るチャンネルは変わっていません。呼び名や取り始める日を変えたときは、次の取得から効きます。")
                    }
                    Text(store.running ? "取得中なので、状況ページとメニューは、この取得が終わったときに新しくなります。"
                         : store.refreshing ? "状況ページとメニューを数え直しています（20秒ほど）…"
                         : "状況ページとメニューにも反映しました。")
                }
                Text("取得に使うモデル: \(store.model)（歯車の設定の「取得に使うモデル」で変えられます）")
                    .foregroundStyle(Color.ink2)
            }
            if setup.firstTime {
            VStack(spacing: 0) {
                SettingRow(title: "毎朝 \(store.timeText) に自動で取る",
                           sub: (first ? "最初の取得のあと、" : "") + "このアプリが開いている間、毎日この時刻に動きます（土日も）") {
                    Toggle("", isOn: $store.autoEnabled).toggleStyle(SwitchStyle())
                }
                SettingRow(title: "Mac の起動時にこのアプリを開く", sub: "自動の取得には、このアプリが開いている必要があります", last: true) {
                    Toggle("", isOn: Binding(get: { store.loginItem }, set: { store.setLoginItem($0) })).toggleStyle(SwitchStyle())
                }
            }
            }
            if let m = store.message {
                Text(m).font(.system(size: 11)).foregroundStyle(Color.ngInk).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 次の取得（毎朝の自動取得が入っていれば、それも）
    private var nextFetch: String {
        store.autoEnabled ? "次の取得（「今すぐ取る」か、毎朝 \(store.timeText) の自動取得）" : "次に「今すぐ取る」を押したとき"
    }

    private var resumeText: String {
        "使いすぎ防止の上限（1回 \(store.costCap) ドル・API 換算）か、周の上限で止まったら、もう一度「今すぐ取る」を押せば続きから取ります。"
    }

    private func fromText(_ p: Picked) -> String {
        guard let d = p.from else { return "—" }
        let day = Fmt.string(d, "yyyy/M/d") + " から"
        switch p.source {
        case .slack: return day + "（Slack の作成日）"
        case .estimated(let basis): return day + "（推定・いちばん古い投稿 \(Setup.basisText(basis))）"
        default: return day
        }
    }
}

// MARK: - 窓

struct SetupSheet: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var setup: Setup

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(setup.firstTime ? "はじめの準備" : "Slack とチャンネル")
                        .font(.system(size: 18, weight: .bold)).foregroundStyle(Color.ink)
                    if setup.firstTime { StepBar(step: setup.step, connected: setup.conn == .ok) }
                }
                Spacer()
                // 閉じるのは、どの画面でもここ（Esc でも）。保存していない変更があれば聞く
                DadsButton(title: "閉じる", kind: .quiet, small: true, shortcut: .cancelAction) { setup.close() }
            }
            .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 16)
            Rectangle().fill(Color.line).frame(height: 1)
            Group {
                switch setup.step {
                case 1: ConnectStep()
                case 2: PickStep()
                default: StartStep()
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            Rectangle().fill(Color.line).frame(height: 1)
            footer.padding(.horizontal, 24).padding(.vertical, 14)
        }
        .frame(width: 720)
        .background(Color.white)
        .environment(\.colorScheme, .light)
        .alert("保存せずに閉じますか？", isPresented: $setup.confirmClose) {
            Button("保存せずに閉じる", role: .destructive) { setup.closeNow() }
            Button("続ける", role: .cancel) {}
        } message: {
            Text(setup.savedAtOpen.isEmpty
                 ? "選んだチャンネルは保存されません。"
                 : "選び直した分は捨てて、保存してある一覧（\(setup.savedAtOpen.count)チャンネル）のままにします。")
        }
    }

    /// 下のボタン。左は「前の画面へ」だけ、右はその画面でいちばん大事な1つだけ（閉じるのは右上）
    @ViewBuilder private var footer: some View {
        HStack(spacing: 10) {
            switch setup.step {
            case 1:
                if !setup.firstTime {
                    DadsButton(title: "チャンネルの画面に戻る", kind: .quiet, small: true, enabled: !setup.busy) { setup.go(2) }
                }
                Spacer()
                if setup.conn == .ok {
                    DadsButton(title: "もう一度確かめる", kind: setup.firstTime ? .quiet : .secondary, enabled: !setup.busy) {
                        setup.checkConnection()
                    }
                    .frame(width: 180)
                    if setup.firstTime { DadsButton(title: "次へ") { setup.step = 2 }.frame(width: 180) }
                } else {
                    DadsButton(title: checkTitle,
                               kind: setup.openedConnector || setup.conn != .unknown || !setup.firstTime ? .primary : .secondary,
                               enabled: !setup.busy) { setup.checkConnection() }
                        .frame(width: 240)
                }
            case 2:
                if setup.firstTime {
                    DadsButton(title: "戻る", kind: .quiet, small: true, enabled: !setup.busy) { setup.go(1) }
                } else {
                    Text(setup.changed ? "変えた分は、保存するまで反映されません" : "直したいところを変えると、保存できるようになります")
                        .font(.system(size: 12)).foregroundStyle(setup.changed ? Color.warnInk : Color.ink3)
                }
                Spacer()
                DadsButton(title: saveTitle, enabled: !setup.busy && !setup.picked.isEmpty && (setup.firstTime || setup.changed)) {
                    setup.next()
                }
                .frame(width: 260)
            default:
                DadsButton(title: "チャンネルを選び直す", kind: .quiet, small: true, enabled: !store.running) { setup.go(2) }
                Spacer()
                if setup.firstTime || !setup.added.isEmpty || !setup.reattached.isEmpty {
                    // 初めて・チャンネルを足したときは、取るのがいちばん大事
                    DadsButton(title: store.running ? "取得中です" : store.history.isEmpty ? "最初の取得を始める" : "今すぐ取る",
                               enabled: !store.running) {
                        setup.backToSettings = false
                        setup.closeNow()
                        store.runNow()
                    }
                    .frame(width: 220)
                } else {
                    // 呼び名や取り始める日を変えた・外しただけなら、取らずに閉じるのがふつう（今すぐ取るは状況ページから）
                    DadsButton(title: "閉じる") { setup.closeNow() }.frame(width: 220)
                }
            }
        }
    }

    private var checkTitle: String {
        switch setup.conn {
        case .checking: return "確かめています…"
        case .failed: return "もう一度確かめる"
        default: return "つながったか確かめる"
        }
    }

    private var saveTitle: String {
        if setup.estimating { return "取り始める日を推定しています…" }
        let missing = setup.picked.contains { $0.from == nil }
        if setup.firstTime { return missing ? "取り始める日を推定して次へ" : "保存して次へ" }
        return missing ? "取り始める日を推定して保存" : "保存する"
    }
}

// MARK: - 確認用の画像（本物の窓として描く。入力欄や日付の欄も写る）

enum SetupSnapshot {
    @MainActor
    static func run(dir: String) {
        let samples = [
            Candidate(id: "C0AAA1111", name: "project-main", isPrivate: false, archived: false, members: 24, created: "2025-01-15", purpose: "本番の連絡用"),
            Candidate(id: "C0BBB2222", name: "project-dev", isPrivate: true, archived: false, members: 8, created: nil, purpose: "開発の相談"),
            Candidate(id: "C0CCC3333", name: "project-design", isPrivate: false, archived: false, members: 6, created: nil, purpose: "デザインのレビュー"),
            Candidate(id: "C0DDD4444", name: "project-old", isPrivate: false, archived: true, members: 3, created: "2023-02-01", purpose: nil),
            Candidate(id: "C0EEE5555", name: "general", isPrivate: false, archived: false, members: 120, created: "2021-03-03", purpose: "全員への連絡"),
        ]
        let store = Store(live: false)   // 取ったことがある人の見え方（-baseDir のデータ）
        let fresh = Store(live: false)   // まだ一度も取っていない人の見え方
        fresh.history = []
        func shot(_ name: String, store: Store = fresh, _ prepare: (Setup) -> Void) {
            let s = Setup()
            s.candidates = samples
            prepare(s)
            Snapshot.renderWindow(SetupSheet().environmentObject(store).environmentObject(s), to: "\(dir)/setup_\(name).png")
        }
        // 準備済みの見え方: 保存してあるチャンネル・最後に確かめた時刻
        let savedSamples = [
            ChannelConfig(id: "C0AAA1111", tag: "main", name: "#project-main", from: "2025-01-15"),
            ChannelConfig(id: "C0BBB2222", tag: "dev", name: "#project-dev", from: "2023-03-25"),
            ChannelConfig(id: "C0EEE5555", tag: "全体", name: "#general", from: "2021-03-03"),
        ]
        func ready(_ s: Setup) {
            s.firstTime = false
            s.savedAtOpen = savedSamples
            s.picked = savedSamples.map(s.asPicked)
            s.connectedAt = "2026-10-09T12:15:12+09:00"
            s.conn = .ok
            s.step = 2
            s.listOpen = false
        }
        shot("c2") { s in ready(s) }   // 開いたところ（何も変えていない）
        shot("c2_changed") { s in       // 1つ外して、1つの呼び名を変えた
            ready(s)
            s.remove("C0EEE5555")
            s.picked[1].tag = "開発"
        }
        shot("c2_shelved") { s in       // 前に取っていたチャンネルがある（付け直せる）
            ready(s)
            s.shelved = [ShelvedChannel(id: "C0DDD4444", tag: "old", name: "#project-old", from: "2023-02-01",
                                        removed_at: "2026-07-01T10:00:00+09:00")]
        }
        shot("c2_reattach") { s in      // 付け直したところ（まだ保存していない）
            ready(s)
            s.shelved = [ShelvedChannel(id: "C0DDD4444", tag: "old", name: "#project-old", from: "2023-02-01",
                                        removed_at: "2026-07-01T10:00:00+09:00")]
            s.reattach("C0DDD4444")
        }
        shot("c2_checking") { s in      // つながりを確かめている途中
            ready(s)
            s.conn = .checking
        }
        shot("c1_failed") { s in        // つなぎ方の画面（確かめて失敗した）
            ready(s)
            s.step = 1
            s.conn = .failed("Slack から失敗が返った。claude.ai のコネクタで Slack を開き、「Reconnect（再接続）」が出ていれば押す")
            s.helpOpen = true
        }
        shot("1") { _ in }
        shot("1_checking") { s in
            s.openedConnector = true
            s.conn = .checking
        }
        shot("1_failed") { s in
            s.openedConnector = true
            s.helpOpen = true
            s.conn = .failed("Slack の連携が見つからなかった。claude.ai のコネクタで Slack が「Connected（接続済み）」になっているかを確かめる（つないだ直後は、反映まで数分かかることがある）")
        }
        shot("2") { s in
            s.step = 2
            s.conn = .ok
            s.query = "project"
            s.toggle(samples[0])
            s.toggle(samples[1])
            s.note = "「project」で 4件 見つかりました。"
        }
        shot("2_many") { s in   // たくさん選んだとき（選んだ一覧は4行を超えるとスクロール）
            s.step = 2
            s.listOpen = false
            for c in samples { s.toggle(c) }
            s.toggle(Candidate(id: "C0FFF6666", name: "開発-雑談", created: "2024-05-01"))
        }
        shot("2_removed") { s in   // 保存してあるチャンネルを ✗ で外したとき（保存するまでは戻せる）
            s.firstTime = false
            s.connectedAt = "2026-10-09T12:15:12+09:00"
            s.savedAtOpen = [
                ChannelConfig(id: "C0AAA1111", tag: "main", name: "#project-main", from: "2025-01-15"),
                ChannelConfig(id: "C0EEE5555", tag: "全体", name: "#general", from: "2021-03-03"),
            ]
            s.picked = s.savedAtOpen.map(s.asPicked)
            s.step = 2
            s.conn = .ok
            s.listOpen = false
            s.remove("C0EEE5555")
        }
        shot("2_notfound") { s in   // Slack で探して見つからなかったとき
            s.step = 2
            s.conn = .ok
            s.query = "office"
            s.note = Setup.notFoundText("office")
            s.searched = "office"
        }
        shot("2_searching") { s in
            s.step = 2
            s.query = "design"
            s.searchingFor = "design"
        }
        shot("2_estimated") { s in
            s.step = 2
            s.toggle(samples[0])
            s.toggle(samples[1])
            s.picked[1].from = Setup.day("2023-03-25")
            s.picked[1].source = .estimated("2023-04")
            s.toggle(samples[2])
            s.candidates[2].oldest = OldestInfo(error: "検索で投稿が1件も見つからなかった")
            s.listOpen = false
            s.problem = "取り始める日を推定できなかったチャンネルがあります: #project-design（検索で投稿が1件も見つからなかった）。「日付を入れる」から入れてください（Slack でチャンネル名を押した「チャンネル詳細」に作成日があります）。"
        }
        shot("3") { s in
            s.toggle(samples[0])
            s.toggle(samples[1])
            s.picked[1].from = Setup.day("2023-03-25")
            s.picked[1].source = .estimated("2023-04")
            s.step = 3
        }
        // 取ったことがあるとき: チャンネルを足した・外した
        shot("3_changed", store: store) { s in
            s.firstTime = false
            s.toggle(samples[0])
            s.toggle(samples[1])
            s.picked[1].from = Setup.day("2023-03-25")
            s.picked[1].source = .estimated("2023-04")
            s.added = ["#project-dev"]
            s.removed = ["#project-old"]
            s.step = 3
        }
        // 取ったことがあるとき: 前に取っていたチャンネルを付け直した
        shot("3_reattached", store: store) { s in
            s.firstTime = false
            s.toggle(samples[0])
            s.reattached = ["#project-old"]
            s.step = 3
        }
        // 取ったことがあるとき: チャンネルは変えなかった
        shot("3_same", store: store) { s in
            s.firstTime = false
            s.toggle(samples[0])
            s.step = 3
        }
    }
}

// MARK: - 確かめ用: チャンネルを外す・保存・付け直す（--test-setup）

enum SetupTest {
    /// 一時フォルダの中だけで「外す → 戻す → 外して保存 → 開き直す → 付け直して保存」などを試す。本物のデータと設定は触らない
    @MainActor
    static func run() -> Int32 {
        Paths.defaults = MemoryStore()
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("slack-fetch-setup-test-\(ProcessInfo.processInfo.processIdentifier)")
        defer { try? fm.removeItem(at: root) }
        var ng = 0
        func check(_ name: String, _ ok: Bool) { print((ok ? "OK  " : "NG  ") + name); if !ok { ng += 1 } }
        func text(_ u: URL) -> String { (try? String(contentsOf: u, encoding: .utf8)) ?? "" }
        do {
            try fm.createDirectory(at: root.appendingPathComponent("データ"), withIntermediateDirectories: true)
            for f in Paths.required { fm.createFile(atPath: root.appendingPathComponent(f).path, contents: Data()) }
            Paths.current = root
            check("一時フォルダを使っている（本物のデータではない）", Paths.channels.path.hasPrefix(root.path))
            // 前の形のデータ（フォルダの一番上に 状態.json）があるあいだは「引っ越しが要る」。データ/ に移せば要らなくなる
            check("前の形のデータが無ければ、引っ越しは要らない", !Store.needsMigrate)
            fm.createFile(atPath: root.appendingPathComponent("状態.json").path, contents: Data("{}".utf8))
            check("一番上に 状態.json があれば、引っ越しが要る（はじめの準備を勝手に開かず、数え直さない）", Store.needsMigrate)
            try fm.moveItem(at: root.appendingPathComponent("状態.json"), to: Paths.state)
            check("データ/ に移せば、引っ越しは要らない", !Store.needsMigrate)
            try fm.removeItem(at: Paths.state)
            // 今の チャンネル.json と同じ形の、架空の3チャンネル
            let original = "[\n {\"id\": \"C0TEST0001\", \"tag\": \"本\", \"name\": \"#テスト_本\", \"from\": \"2024-12-27\"},\n"
                + " {\"id\": \"C0TEST0002\", \"tag\": \"開発\", \"name\": \"#テスト_開発\", \"from\": \"2025-02-20\"},\n"
                + " {\"id\": \"C0TEST0003\", \"tag\": \"共有\", \"name\": \"#テスト_共有\", \"from\": \"2025-10-28\"}\n]\n"
            try original.write(to: Paths.channels, atomically: true, encoding: .utf8)
            var savedCount = 0
            let s = Setup()
            s.onSaved = { savedCount += 1 }

            s.open()
            check("開くと、保存してある3チャンネルが選ばれている（準備済みの窓・チャンネルの画面）",
                  s.picked.count == 3 && !s.firstTime && s.step == 2 && !s.changed)
            s.remove("C0TEST0002")
            check("✗ で外すと「変えた」になり、戻せる欄に出る", s.changed && s.removedSaved.map(\.id) == ["C0TEST0002"])
            s.restore("C0TEST0002")
            check("「戻す」で元の順番に戻り、「変えた」でなくなる", !s.changed && s.picked.map(\.id) == ["C0TEST0001", "C0TEST0002", "C0TEST0003"])
            s.remove("C0TEST0002")
            s.close()
            check("保存せずに閉じようとすると聞く（窓は開いたまま）", s.confirmClose && s.show)
            s.closeNow()
            check("「保存せずに閉じる」ならファイルは変わらない", text(Paths.channels) == original && !s.show)

            s.open()
            check("開き直すと、保存してある一覧から始まる", s.picked.count == 3 && !s.changed)
            s.remove("C0TEST0002")
            s.next()
            let after1 = Setup.savedChannels().map(\.id)
            let shelf1 = Setup.shelvedChannels()
            check("外して保存すると、取るチャンネルから消える", after1 == ["C0TEST0001", "C0TEST0003"] && s.step == 3)
            check("外したチャンネルは、呼び名と取り始める日を覚えておく",
                  shelf1.count == 1 && shelf1[0].id == "C0TEST0002" && shelf1[0].tag == "開発" && shelf1[0].from == "2025-02-20"
                  && shelf1[0].removed_at != nil)
            check("保存したら、状況ページの数え直しを呼ぶ", savedCount == 1)
            check("③で「外した」と伝える", s.removed == ["#テスト_開発"] && s.added.isEmpty && s.reattached.isEmpty)

            s.closeNow()
            s.open()
            check("開き直すと、前に取っていたチャンネルの欄に出る", s.shelvedNow.map(\.id) == ["C0TEST0002"] && s.picked.count == 2)
            s.reattach("C0TEST0002")
            let p = s.picked.first { $0.id == "C0TEST0002" }
            check("付け直すと、前の呼び名と取り始める日に戻る",
                  p?.tag == "開発" && p.flatMap { $0.from }.map(Setup.dayString) == "2025-02-20" && p?.source == .previous)
            check("付け直したものは、前に取っていたチャンネルの欄から消える", s.shelvedNow.isEmpty && s.changed)
            s.next()
            let after2 = Setup.savedChannels()
            check("付け直して保存すると、取るチャンネルに戻る（呼び名・取り始める日も同じ）",
                  Set(after2.map(\.id)) == ["C0TEST0001", "C0TEST0002", "C0TEST0003"]
                  && after2.first { $0.id == "C0TEST0002" }.map { $0.tag == "開発" && $0.from == "2025-02-20" } == true)
            check("外したチャンネルの記録から消える", Setup.shelvedChannels().isEmpty && text(Paths.shelved) == "[]\n")
            check("③で「付け直した」と伝える（足した、ではない）", s.reattached == ["#テスト_開発"] && s.added.isEmpty)

            // 最後のチャンネルを外して付け直すと、ファイルは元とまったく同じになる
            s.closeNow(); s.open()
            s.remove("C0TEST0003"); s.next()
            s.closeNow(); s.open()
            s.remove("C0TEST0002"); s.reattach("C0TEST0003")   // 2 を外し、3 を付け直す（呼び名「共有」が重ならない）
            s.restore("C0TEST0002")
            s.next()
            let order = Setup.savedChannels().map(\.id)
            check("付け直したチャンネルは一覧の最後に入る（%@）".replacingOccurrences(of: "%@", with: order.joined(separator: ",")),
                  order == ["C0TEST0001", "C0TEST0002", "C0TEST0003"])
            check("…そのため、元と同じ順なら、ファイルは元とまったく同じ", text(Paths.channels) == original)

            // Slack で探し直してチェックを付けたときも、前の呼び名と取り始める日に戻す
            s.closeNow(); s.open()
            s.remove("C0TEST0001"); s.next()
            s.closeNow(); s.open()
            s.candidates = [Candidate(id: "C0TEST0001", name: "テスト_本", created: "2020-01-01")]
            s.toggle(s.candidates[0])
            let q = s.picked.first { $0.id == "C0TEST0001" }
            check("Slack の候補からチェックしても、前の呼び名と取り始める日に戻る（Slack の作成日ではなく）",
                  q?.tag == "本" && q.flatMap { $0.from }.map(Setup.dayString) == "2024-12-27" && q?.source == .previous)
            // 呼び名が重なるときだけ、別の呼び名にする
            s.picked[0].tag = "本"
            s.picked.removeAll { $0.id == "C0TEST0001" }
            s.reattach("C0TEST0001")
            check("付け直すとき、呼び名が今のチャンネルと重なれば別の呼び名にする",
                  s.picked.first { $0.id == "C0TEST0001" }?.tag != "本")

            // 記録のファイル: 2つが同時に書いても上書きしない（16:28 に起きた順番を再現: 数え直しが開く → 取得が開いて書く
            // → 取得の台本が書く → 数え直しの台本があとから書く）
            guard let first = Store.appLog("状況の数え直し"), let second = Store.appLog("取得係") else {
                check("記録のファイルを開ける", false)
                throw CocoaError(.fileWriteUnknown)
            }
            func child(_ text: String, _ h: FileHandle) {   // 台本（別のプログラム）として書く
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/echo")
                p.arguments = [text]
                p.standardOutput = h
                try? p.run()
                p.waitUntilExit()
            }
            child("取得を始めます", second)
            child("数え直しました", first)
            child("取り残しはありません", second)
            let log = text(Paths.logs.appendingPathComponent("アプリから動かした記録.log"))
            let positions = ["に開始（状況の数え直し）", "に開始（取得係）", "取得を始めます", "数え直しました", "取り残しはありません"]
                .map { log.range(of: $0)?.lowerBound }
            // 既知の例外（例外.json）: 足す・二重にしない・ほかの行を残す・外す
            check("照合の行から、チャンネルと投稿の時刻を取り出せる",
                  Store.threadRef("NG 取りに行くと別のスレッドが返る（Slack 側の食い違い・3通りの呼び方で試した）: C0TEST0009 1785000000.000100（返信 12）")
                    .map { $0.ch == "C0TEST0009" && $0.ts == "1785000000.000100" } == true)
            try "[{\"channel\": \"C0OTHER001\", \"ts\": \"1700000000.000001\", \"reason\": \"前からある例外\"}]\n"
                .write(to: Paths.exceptions, atomically: true, encoding: .utf8)
            let ref = (ch: "C0TEST0001", ts: "1785000000.000100")
            let added = try Store.editExceptions(add: [ref])
            let again = try Store.editExceptions(add: [ref])
            func excList() -> [[String: Any]] {
                ((try? Data(contentsOf: Paths.exceptions)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] }) ?? []
            }
            let afterAdd = excList()
            check("既知の例外に足す（二重にはしない・前からある行は残す・理由を付ける）",
                  added == 1 && again == 0 && afterAdd.count == 2
                  && afterAdd.contains { ($0["ts"] as? String) == ref.ts && ($0["reason"] as? String) == Store.gaveUpReason }
                  && afterAdd.contains { ($0["reason"] as? String) == "前からある例外" })
            try Store.editExceptions(remove: [ref])
            let afterRemove = excList()
            check("既知の例外から戻す（前からある行は残す）",
                  afterRemove.count == 1 && (afterRemove.first?["reason"] as? String) == "前からある例外")

            check("記録のファイルは、2つが同時に書いても上書きせず、書いた順に後ろへ足す",
                  !positions.contains { $0 == nil } && positions.compactMap { $0 } == positions.compactMap { $0 }.sorted()
                  && String(decoding: Data(log.utf8), as: UTF8.self) == log)
        } catch {
            print("NG  準備で失敗: \(error)")
            ng += 1
        }
        print(ng == 0 ? "すべて期待どおりです" : "\(ng) 件おかしい")
        return ng == 0 ? 0 : 1
    }
}
