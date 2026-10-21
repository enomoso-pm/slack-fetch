#!/usr/bin/env python3
"""Slack の取得結果を、Claude Code の作業記録から取り出して保存する道具。

Claude（または手伝い役）が Slack の読み取りツールを呼ぶと、返ってきた中身が
Claude Code の作業記録（~/.claude/projects/.../*.jsonl）にそのまま残る。
この道具はそこから中身を取り出して、チャンネルごとのフォルダの 原本/ に保存する。AI は中身を書き写さない。

取ったもの・設定・状態は、すべてホームの直下の Slack取得データ/ に置く（この取得の仕組みのフォルダの外）:
  Slack取得データ/チャンネル.json                        取るチャンネルの一覧（自分で書く）
  Slack取得データ/状態.json・取得の記録.jsonl・例外.json  状態（メニューバーのアプリが読む）
  Slack取得データ/チャンネル/<名前>__<ID>/記録.jsonl      1投稿1行の記録
  Slack取得データ/チャンネル/<名前>__<ID>/原本/<年-月>/   Slack から返ってきたそのまま（投稿の月ごと）
  Slack取得データ/取得ログ/<年-月>/                       取得の周ごとの一覧・結果・まとめ
  Slack取得データ/よけた原本/<名前>__<ID>/<年-月>/        空で返ってきたが、あとで取り直せた原本（消さずによける）

使い方:
  python3 slack.py plan    <チャンネルID> <開始日> <終了日> [...]  まだ取っていない／取り直す呼び出しの一覧を出す
  python3 slack.py extract [作業記録.jsonl ...]   原本を保存する（指定が無ければ最近の作業記録を全部見る）
  python3 slack.py usage   作業記録.jsonl ...     その作業記録で使ったトークン量を数える
  python3 slack.py build                          原本から事実の記録（チャンネルごとの 記録.jsonl、1件1行）を作る
  python3 slack.py check                          照合（スレッドの返信数と、実際に取れた数が合うか）
  python3 slack.py set-aside                      空で返ってきたが、あとで取り直せた原本を Slack取得データ/よけた原本/ に移す（消さない）
  python3 slack.py status  running|done|refresh   状態.json を書く（メニューバーのアプリが読む）
  python3 slack.py where                          データの場所を出す
  python3 slack.py migrate [前のフォルダ]         前の場所（取得の仕組みのフォルダの中の データ/ や、一番上の 原本/ など）から
                                                  Slack取得データ/ に引っ越す（前のフォルダを省くと、このフォルダ）
  python3 slack.py channels 作業記録.jsonl --answer 出力.json   チャンネル探しの結果を照らして チャンネル候補.json に書く
  python3 slack.py oldest  plan|read|done ...     できた日が分からないチャンネルの、いちばん古い投稿の月を探す
"""
import base64
import collections
import glob
import time
import hashlib
import json
import os
import re
import shutil
import sys
import unicodedata

HERE = os.path.dirname(os.path.abspath(__file__))
# 取ったもの・設定・状態は、取得の仕組みのフォルダ（このフォルダ）の外の、ホームの直下の Slack取得データ/ に置く。
# このフォルダは GitHub から取ってきて入れ替えたり、公開したりする。中にデータを置くと、入れ替えで消えたり、
# 公開リポジトリに入ったりするため。場所は SLACK_FETCH_DATA で変えられる（試しのとき用。アプリと台本も同じ決まりで決める）
DATA_NAME = "Slack取得データ"
DATA = os.path.abspath(os.path.expanduser(os.environ.get("SLACK_FETCH_DATA") or os.path.join("~", DATA_NAME)))
CH_ROOT = os.path.join(DATA, "チャンネル")          # 1チャンネル1フォルダ（<名前>__<ID>）。中に 記録.jsonl と 原本/<年-月>/
OTHER_RAW = os.path.join(DATA, "その他", "原本")     # どのチャンネルの呼び出しか分からないもの
# 空で返ってきたが、あとで同じものを取り直せた原本（Mac のスリープなどで）。消さずにここへよける。中は <チャンネルのフォルダ名>/<年-月>/
ASIDE_ROOT = os.path.join(DATA, "よけた原本")
LOG_ROOT = os.path.join(DATA, "取得ログ")           # 取得の周ごとの一覧・結果・まとめ（月ごと）
# Claude Code の作業記録の置き場所（CLAUDE_CONFIG_DIR で設定の場所を変えている人は、そちらを見る）
PROJECTS = os.path.join(os.path.expanduser(os.environ.get("CLAUDE_CONFIG_DIR") or "~/.claude"), "projects")
READ_TOOLS = ("slack_read_channel", "slack_read_thread", "slack_search_public_and_private")
# 大きすぎて別ファイルに逃がされた結果の置き場所（Claude Code の版によって .txt か .json）
SPILL_RE = re.compile(r"Output has been saved to (/\S+?\.(?:txt|json))")
# 投稿が入っている印（チャンネル・スレッド・検索の結果の、投稿ごとの見出しの行）
VISIBLE_RE = re.compile(r"^(=== Message from |Message TS:|From: |Message_ts: )", re.M)


def iter_lines(path):
    with open(path, encoding="utf-8") as f:
        for line in f:
            try:
                yield json.loads(line)
            except ValueError:
                continue


def unwrap(text):
    """別ファイルに逃げた結果は、置かれ方によって [{"type":"text","text":"<元のJSON>"}] と包まれている。
    包みがあれば外して、元の JSON の文字列を返す。包みが無ければそのまま返す。"""
    try:
        v = json.loads(text)
    except ValueError:
        return text
    if isinstance(v, list) and v and all(isinstance(x, dict) and "text" in x for x in v):
        return "".join(x["text"] for x in v)
    return text


def result_text(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "".join(x.get("text", "") for x in content if isinstance(x, dict))
    return ""


def find_calls(path, tools=READ_TOOLS):
    """作業記録1本から、Slack の道具（既定は読み取りの3つ）の呼び出しと結果の組を取り出す。"""
    uses = {}
    for d in iter_lines(path):
        msg = d.get("message") or {}
        content = msg.get("content")
        if not isinstance(content, list):
            continue
        for b in content:
            if not isinstance(b, dict):
                continue
            if b.get("type") == "tool_use":
                short = b.get("name", "").split("__")[-1]
                if short in tools:
                    uses[b["id"]] = (short, b.get("input") or {})
            elif b.get("type") == "tool_result" and b.get("tool_use_id") in uses:
                tool, inp = uses[b["tool_use_id"]]
                text = result_text(b.get("content"))
                call = {
                    "tool": tool,
                    "input": inp,
                    "tool_use_id": b["tool_use_id"],
                    "is_error": bool(b.get("is_error")),
                    "fetched_at": d.get("timestamp"),
                    "source": os.path.relpath(path, PROJECTS),
                    "spilled_to": None,
                    "response_text": text,
                }
                # 大きすぎる結果は Claude Code が別ファイルに逃がし、AI にはその場所だけを返す。
                # そのファイルが原本そのものなので、そちらを読む
                m = SPILL_RE.search(text)
                if m and os.path.exists(m.group(1)):
                    with open(m.group(1), encoding="utf-8") as f:
                        call["response_text"] = unwrap(f.read())
                    call["spilled_to"] = os.path.relpath(m.group(1), PROJECTS)
                    call["is_error"] = False
                yield call


def recent_logs():
    pats = [os.path.join(PROJECTS, "*", "*.jsonl"),
            os.path.join(PROJECTS, "*", "*", "subagents", "*.jsonl")]
    # チャンネル探し（/tmp/slack-fetch-channels で動く）の作業記録は外す。
    # できた日の推定で検索した結果まで、原本に入らないように
    return sorted(p for pat in pats for p in glob.glob(pat)
                  if not os.path.relpath(p, PROJECTS).split(os.sep)[0].endswith("slack-fetch-channels"))


# ---- データの置き場所 ----

_CH_DIRS = {}


def safe_name(name):
    """チャンネルの名前を、フォルダの名前に使える形にする（使えない文字は _ にする）"""
    n = re.sub(r"[/:\\\x00-\x1f]", "_", (name or "").lstrip("#").strip()).strip(". ")
    return n[:60]


def channel_name(ch):
    """チャンネル.json の名前（無ければ空）"""
    for c in read_json(CHANNELS_PATH, []):
        if c.get("id") == ch:
            return safe_name(c.get("name"))
    return ""


def channel_dir(ch, create=False):
    """チャンネルのフォルダ（Slack取得データ/チャンネル/<名前>__<ID>）。名前があとで変わっても、ID で見つける"""
    if ch not in _CH_DIRS and os.path.isdir(CH_ROOT):
        for e in os.listdir(CH_ROOT):
            if e == ch or e.endswith("__" + ch):
                _CH_DIRS[ch] = os.path.join(CH_ROOT, e)
                break
    if ch not in _CH_DIRS:
        name = channel_name(ch)
        _CH_DIRS[ch] = os.path.join(CH_ROOT, "%s__%s" % (name, ch) if name else ch)
    if create:
        os.makedirs(_CH_DIRS[ch], exist_ok=True)
    return _CH_DIRS[ch]


def call_channel(call):
    """呼び出しがどのチャンネルのものか（検索は filters の in:<#ID> から）"""
    i = call.get("input") or {}
    if i.get("channel_id"):
        return i["channel_id"]
    m = re.search(r"in:<#([A-Z0-9]+)", (i.get("filters") or "") + " " + (i.get("query") or ""))
    return m.group(1) if m else None


def call_month(call):
    """原本を置く月。投稿の月（スレッドは親の投稿の月）。検索などは取った月"""
    i = call.get("input") or {}
    try:
        t = float(i.get("message_ts") or i.get("oldest") or 0)
    except (TypeError, ValueError):
        t = 0
    if t > 0:
        return time.strftime("%Y-%m", time.gmtime(t + JST_OFFSET))
    return (call.get("fetched_at") or time.strftime("%Y-%m"))[:7]


def raw_path(call):
    ch = call_channel(call)
    base = os.path.join(channel_dir(ch), "原本") if ch else OTHER_RAW
    return os.path.join(base, call_month(call), call["tool_use_id"] + ".json")


def raw_files(ch=None):
    """原本のファイルの一覧。ch を渡すと、そのチャンネルのフォルダの分だけ（チャンネルが多くても速い）"""
    if ch:
        roots = [os.path.join(channel_dir(ch), "原本")]
    else:
        roots = [os.path.join(CH_ROOT, e, "原本") for e in (sorted(os.listdir(CH_ROOT)) if os.path.isdir(CH_ROOT) else [])]
        roots.append(OTHER_RAW)
    out = []
    for r in roots:
        for dp, _, fn in os.walk(r):
            out += [os.path.join(dp, f) for f in fn if f.endswith(".json")]
    return sorted(out)


def aside_files():
    """よけた原本（空で返ってきたが、あとで取り直せたもの）のファイルの一覧。記録・照合・計画には使わない"""
    out = []
    for dp, _, fn in os.walk(ASIDE_ROOT):
        out += [os.path.join(dp, f) for f in fn if f.endswith(".json")]
    return sorted(out)


def plain_text(text):
    """Slack の結果は JSON で、改行は \\n、日本語は \\uXXXX の文字になっている。ほどいて、ふつうの文にする"""
    try:
        v = json.loads(text)
        if isinstance(v, dict):
            return "\n".join(x for x in v.values() if isinstance(x, str))
    except ValueError:
        pass
    return text


def visible_to_ai(call):
    """その結果は、ファイルに置かれずその場で AI に返り、しかも投稿が入っていたか（取得係に投稿が見えたか）。
    投稿の無い短い返事（チャンネル名と「もう無い」だけ）は、その場で返っても見えたことにしない"""
    if call["spilled_to"] is not None or call["is_error"]:
        return False
    return bool(VISIBLE_RE.search(plain_text(call["response_text"])))   # ほどいてから、行の頭の見出しを探す


def cmd_extract(paths):
    # 保存済み（どのチャンネルのフォルダにあっても）。よけた原本も、もう一度保存し直さない
    have = {os.path.basename(p) for p in raw_files() + aside_files()}
    saved = skipped = errors = seen = 0
    for path in paths or recent_logs():
        for call in find_calls(path):
            seen += visible_to_ai(call)
            name = call["tool_use_id"] + ".json"
            if name in have:
                skipped += 1
                continue
            have.add(name)
            out = raw_path(call)
            os.makedirs(os.path.dirname(out), exist_ok=True)
            text = call["response_text"]
            call["sha256"] = hashlib.sha256(text.encode("utf-8")).hexdigest()
            try:
                json.loads(text)
                call["parse_ok"] = True
            except ValueError:
                # 大きすぎて切られた・エラー文だった、など。中身はそのまま残して印を付ける
                call["parse_ok"] = False
            if call["is_error"] or not call["parse_ok"]:
                errors += 1
            with open(out, "w", encoding="utf-8") as f:
                json.dump(call, f, ensure_ascii=False, indent=1)
                f.write("\n")
            saved += 1
    # 取得係.sh は「保存 N 件」と「投稿が見えた結果 N 件」を読む
    print("保存 %d 件 / 保存済みで飛ばした %d 件 / うちエラーや形の崩れ %d 件 / 投稿が見えた結果 %d 件"
          % (saved, skipped, errors, seen))
    return 1 if errors else 0


def cmd_usage(paths):
    seen = {}
    for path in paths:
        for d in iter_lines(path):
            msg = d.get("message") or {}
            u = msg.get("usage")
            if msg.get("role") == "assistant" and u and msg.get("id"):
                seen[msg["id"]] = u  # 同じ返事が何行かに分かれて記録されるので、id ごとに1回だけ数える
    keys = ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens")
    total = {k: sum(int(u.get(k) or 0) for u in seen.values()) for k in keys}
    print("返事の数: %d" % len(seen))
    for k in keys:
        print("  %-30s %12d" % (k, total[k]))
    print("  %-30s %12d" % ("合計（読み込み＋書き出し）", sum(total.values())))
    return 0


# ---- 原本 → 事実の記録（1件1行） ----

# 社外の人（Slack コネクトで共有したチャンネル）は「(W0123ABCDE, external: 相手の組織名)」のように、ID の後ろに所属が付く。
# 名前の後ろの <…> は、ボットの印を決めるのに読む（中身は記録に入れない。設計書 5 章）
CH_HEAD_RE = re.compile(r"^=== Message from (.*?) (?:<([^>]*)> )?\((\w+)(?:, external: (.*?))?\) at (\d{4}-\d\d-\d\d \d\d:\d\d:\d\d) JST ===\s*$")
CHANNEL_RE = re.compile(r"^Channel: .*\((\w+)\)\s*$")
THREAD_RE = re.compile(r"^Thread: (\d+) repl(?:y|ies)")
REPLIES_HEAD_RE = re.compile(r"^=== THREAD REPLIES \((\d+) total\) ===")
FROM_RE = re.compile(r"^From: (.*?) (?:<([^>]*)> )?\((\w+)(?:, external: (.*))?\)\s*$")
# スレッドの結果では、返信と返信の間に「--- Reply 2 of 8 ---」の区切りの行が入る。本文に混ぜない
THREAD_LINE_RE = re.compile(r"(^|\n)Thread: \d+ repl")
REPLY_SEP_RE = re.compile(r"^--- Reply \d+ of \d+ ---\s*$")
META_PREFIXES = ("Thread:", "Reactions:", "Files:")
FORWARD_PREFIX = "Forwarded message from"


# 本文のあとには「Thread:」「Reactions:」「Files:」の行が付き、さらにその後ろに、
# 転送（Forwarded message from …: と、そのあとに続く転送された本文）、
# リンクのプレビュー（App notification from …）、添付（Attachment: …）のまとまりが続くことがある
ATTACH_RE = re.compile(r"^(App notification from |Attachment: )")


def bot_mark(user_id, angle):
    """ボットの印（設計書 5 章）。推測（名前など）では付けない。見出しの ID の頭が B なら True（Slack の公式の道具
    Bolt for Python の説明に、ボットの ID は B で始まるとある）。見出しの <…> にメールアドレスがあれば False。
    どちらでもなければ None（見出しだけでは決められない。ボットのユーザーの ID は U か W で始まることもある）"""
    if user_id and user_id.startswith("B"):
        return True
    if angle and "@" in angle:
        return False
    return None


# GitHub の PR・issue・discussion の URL（設計書 4 章）。後ろに /files や #issuecomment-… が付いてもよい
GH_URL_RE = re.compile(r"https?://(?:www\.)?github\.com/([A-Za-z0-9][\w.-]*/[\w.-]+)/(pull|issues|discussions)/([0-9]+)")
GH_KIND = {"pull": "pr", "issues": "issue", "discussions": "discussion"}
FENCE_LINE_RE = re.compile(r"^\s*```")


def without_fences(text):
    """コードの囲み（```）の中を外す（ログやコードの中の URL は、話のつながりとは限らない）"""
    out, inside = [], False
    for line in (text or "").split("\n"):
        if FENCE_LINE_RE.match(line):
            if line.count("```") % 2 == 1:   # 開く行・閉じる行（同じ行で開いて閉じるものは、行ごと見ない）
                inside = not inside
            continue
        if not inside:
            out.append(re.sub(r"```.*?```", " ", line))   # 行の途中の ```…``` も見ない
    return "\n".join(out)


def gh_links(rec):
    """本文・リンクのプレビュー・転送から、GitHub の URL を拾う。「書いてあった」つながり（設計書 4 章）"""
    out, seen = [], set()
    for where, field in (("text", "text"), ("attachments", "attachments"), ("forwarded", "forwarded_from")):
        for m in GH_URL_RE.finditer(without_fences(rec.get(field))):
            n = int(m.group(3))
            key = (m.group(1).lower(), m.group(2), n, where)
            if n <= 0 or key in seen:
                continue
            seen.add(key)
            out.append({"to": {"repo": m.group(1), "kind": GH_KIND[m.group(2)], "number": n},
                        "strength": "written", "form": "url", "where": where})
    return out


def split_tail_meta(lines):
    """本文と、後ろに付くもの（返信数・リアクション・添付ファイル・転送・リンクのプレビュー）を切り分ける。"""
    meta = {}
    lines = list(lines)
    # 転送・リンクのプレビュー・添付のまとまりは、最初に出てきた見出しの行から後ろ全部
    a = next((i for i, l in enumerate(lines) if l.startswith(FORWARD_PREFIX) or ATTACH_RE.match(l)), len(lines))
    blocks, lines = lines[a:], lines[:a]
    fwd, att, cur = [], [], None
    for l in blocks:
        if l.startswith(FORWARD_PREFIX):
            cur = fwd
            l = l[len(FORWARD_PREFIX):].strip()
        elif ATTACH_RE.match(l):
            cur = att
        cur.append(l)
    while lines and not lines[-1].strip():
        lines.pop()
    while lines and lines[-1].startswith(META_PREFIXES):
        key, _, val = lines.pop().partition(":")
        meta[key] = val.strip()
    while lines and not lines[-1].strip():
        lines.pop()
    if fwd:
        meta["Forwarded"] = "\n".join(fwd).strip()
    if att:
        meta["Attachments"] = "\n".join(att).strip()
    return "\n".join(lines), meta


def parse_channel(text):
    """slack_read_channel の messages を、投稿ごとに分ける。"""
    out, cur, channel = [], None, None
    for line in text.split("\n"):
        m = CHANNEL_RE.match(line)
        if m and cur is None:
            channel = m.group(1)
            continue
        m = CH_HEAD_RE.match(line)
        if m:
            if cur:
                out.append(cur)
            cur = {"user_name": m.group(1), "user_id": m.group(3), "external_org": m.group(4),
                   "time": m.group(5), "ts": None, "bot": bot_mark(m.group(3), m.group(2)), "lines": []}
            continue
        if cur is None:
            continue
        if cur["ts"] is None and line.startswith("Message TS:"):
            cur["ts"] = line.split(":", 1)[1].strip()
            continue
        cur["lines"].append(line)
    if cur:
        out.append(cur)
    for msg in out:
        msg["text"], meta = split_tail_meta(msg.pop("lines"))
        m = THREAD_RE.match("Thread: " + meta["Thread"]) if "Thread" in meta else None
        msg["reply_count"] = int(m.group(1)) if m else 0
        msg["reactions"] = meta.get("Reactions")
        msg["files"] = meta.get("Files")
        msg["forwarded_from"] = meta.get("Forwarded")
        msg["attachments"] = meta.get("Attachments")
    return channel, out


def parse_thread(text):
    """slack_read_thread の messages を、親と返信に分ける。"""
    blocks, cur, declared, part = [], None, None, "parent"
    for line in text.split("\n"):
        if REPLY_SEP_RE.match(line):
            continue
        if line.startswith("=== THREAD PARENT MESSAGE ==="):
            part = "parent"
            continue
        m = REPLIES_HEAD_RE.match(line)
        if m:
            if cur:
                blocks.append(cur)
                cur = None
            declared, part = int(m.group(1)), "reply"
            continue
        m = FROM_RE.match(line)
        if m:
            if cur:
                blocks.append(cur)
            cur = {"part": part, "user_name": m.group(1), "user_id": m.group(3), "external_org": m.group(4),
                   "time": None, "ts": None, "bot": bot_mark(m.group(3), m.group(2)), "lines": []}
            continue
        if cur is None:
            continue
        if cur["time"] is None and line.startswith("Time:"):
            cur["time"] = line.split(":", 1)[1].strip().replace(" JST", "")
            continue
        if cur["ts"] is None and line.startswith("Message TS:"):
            cur["ts"] = line.split(":", 1)[1].strip()
            continue
        cur["lines"].append(line)
    if cur:
        blocks.append(cur)
    for b in blocks:
        b["text"], meta = split_tail_meta(b.pop("lines"))
        b["reactions"] = meta.get("Reactions")
        b["files"] = meta.get("Files")
        b["forwarded_from"] = meta.get("Forwarded")
        b["attachments"] = meta.get("Attachments")
    parent = next((b for b in blocks if b["part"] == "parent"), None)
    replies = [b for b in blocks if b["part"] == "reply"]
    return parent, replies, declared


def load_raw(ch=None):
    """原本を読む。ch を渡すと、そのチャンネルの分だけ"""
    calls = []
    for p in raw_files(ch):
        with open(p, encoding="utf-8") as f:
            d = json.load(f)
        d["raw_file"] = os.path.basename(p)
        calls.append(d)
    calls.sort(key=lambda d: d.get("fetched_at") or "")
    return calls


def load_aside():
    """よけた原本を読む（検査の道具が、頼んだ一覧と突き合わせるときに使う）"""
    calls = []
    for p in aside_files():
        with open(p, encoding="utf-8") as f:
            d = json.load(f)
        d["raw_file"] = os.path.basename(p)
        calls.append(d)
    calls.sort(key=lambda d: d.get("fetched_at") or "")
    return calls


def call_key(call):
    """同じものを取りに行った呼び出しかを見分ける鍵（ページの続き＝cursor も含む）。
    スレッドは、呼び方（oldest の付け方）によらず、親の投稿で見る"""
    i = call.get("input") or {}
    s = lambda v: None if v in (None, "") else str(v)
    if call["tool"] == "slack_read_thread":
        return (call["tool"], s(i.get("channel_id")), s(i.get("message_ts")), s(i.get("cursor")))
    if call["tool"] == "slack_read_channel":
        return (call["tool"], s(i.get("channel_id")), s(i.get("oldest")), s(i.get("latest")), s(i.get("cursor")))
    return (call["tool"], s(i.get("filters")), s(i.get("query")), s(i.get("cursor")))


def retried_broken(calls):
    """形の崩れた原本のうち、あとで同じものを形どおりに取り直せたもの。
    Mac のスリープや一時的なエラー（502 など）で、途中の呼び出しが空で返ることがある（2026-10-12 に、スリープ中の Mac で2件。次の周で取り直せていた）。
    取り直せていれば、取れていない分は無い。スレッドは、頼んだスレッドそのものが返ったときだけ取り直せたとみなす"""
    broken = [c for c in calls if not c.get("parse_ok")]
    if not broken:
        return []
    want = {call_key(c) for c in broken}
    good = {}   # 鍵 -> 形どおりに取れた、いちばん新しい時刻
    for c in calls:
        if not c.get("parse_ok") or c.get("is_error") or call_key(c) not in want:
            continue
        if c["tool"] == "slack_read_thread":
            try:
                parent, _, _ = parse_thread(json.loads(c["response_text"]).get("messages", ""))
            except (ValueError, AttributeError):
                continue
            if parent and parent.get("ts") and parent["ts"] != c["input"].get("message_ts"):
                continue   # 別のスレッドが返ったものは、取り直せたことにしない
        k = call_key(c)
        good[k] = max(good.get(k, ""), c.get("fetched_at") or "")
    return [c for c in broken if good.get(call_key(c), "") > (c.get("fetched_at") or "")]


SEARCH_TOOL = "slack_search_public_and_private"
SEARCH_MSG_RE = re.compile(r"^Message_ts: (\S+)", re.M)
THREAD_PARAM_RE = re.compile(r"thread_ts=([0-9.]+)")

# 取り直しても別のスレッドが返った呼び出し（頼んだ親の ts ごと）。build_records が埋める
WRONG_THREAD_CALLS = {}
# 形は崩れていたが、あとで同じものを取り直せた原本（チャンネル, ファイル名）。NG にはしない。build_records が埋める
RETRIED_RAW = []


# スレッドの呼び方。頼んだのと別のスレッドが返ったら、次の取得で次の呼び方を試す（同じ呼び方は二度と頼まない）。
# 3通りとも別のスレッドが返ったら諦める（照合で「取りに行くと別のスレッドが返る」と出し、アプリから既知の例外にできる）。
# どの呼び方を試して当たったか・外れたかは、原本（頼んだ引数と返ってきた中身）から分かるので、別に覚え書きは作らない
#   1: oldest に親の投稿の時刻（2026-10-08 に、別のスレッドが返る不具合を避けられると確かめた。ふだんはこれ）
#   2: oldest を、その秒のちょうど頭に（親の時刻の小数の扱いで、親がぎりぎり外れているのかもしれない。推測）
#   3: oldest を付けない（10/8 より前の呼び方）
def thread_forms(pts):
    return [{"oldest": pts}, {"oldest": pts.split(".")[0]}, {}]


def form_index(pts, call):
    """その呼び出しは、何番目の呼び方か（0 から。どれでもなければ None）"""
    oldest = (call.get("input") or {}).get("oldest")
    for i, f in enumerate(thread_forms(pts)):
        if f.get("oldest") == oldest:
            return i
    return None


def thread_failed_forms(ch, pts):
    """そのスレッドを頼んで、別のスレッドが返った呼び方（build_records のあとに使う）"""
    return {i for i in (form_index(pts, c) for c in WRONG_THREAD_CALLS.get((ch, pts), [])) if i is not None}


def build_records(ch=None):
    """原本を全部読んで、(チャンネル, ts) ごとに1件にまとめる。新しく取ったものが勝つ。
    ch を渡すと、そのチャンネルの分だけ（計画を立てるときに、ほかのチャンネルを読まずに済む）。

    threads[(ch, 親ts)] には、そのスレッドを「いちばん新しく取った回（世代）」の数を入れる:
      declared … 見出しの件数（100件を超えてページに分かれていれば足す）
      got      … その世代で取れた返信の数
      gen_at   … その世代の1ページ目を取った時刻
    返信があとから増えたスレッドは取り直すので、比べるのはいちばん新しい世代どうし。
    """
    calls = [c for c in load_raw(ch) if c["tool"] in ("slack_read_channel", "slack_read_thread")]
    records, problems = {}, []
    WRONG_THREAD_CALLS.clear()
    del RETRIED_RAW[:]
    retried = {id(c) for c in retried_broken(calls)}

    # 1) スレッドの呼び出しを、実際に返ってきた親の投稿ごとに分ける
    #    （Slack の道具は oldest なしで開くと、ときどき別の投稿のスレッドを返すため）
    tcalls, reply_parent = {}, {}
    for call in calls:
        if not call.get("parse_ok"):
            # Mac のスリープや一時的なエラー（502 など）で形が崩れても、あとで同じものを取り直せていれば問題にしない（取れていなければ NG）
            if id(call) in retried:
                RETRIED_RAW.append((call_channel(call), call["raw_file"]))
            else:
                problems.append("形の崩れた原本: %s" % call["raw_file"])
            continue
        if call["tool"] != "slack_read_thread":
            continue
        ch = call["input"].get("channel_id")
        parent, replies, declared = parse_thread(json.loads(call["response_text"]).get("messages", ""))
        asked = call["input"].get("message_ts")
        pts = parent["ts"] if parent and parent.get("ts") else asked
        if pts != asked:
            WRONG_THREAD_CALLS.setdefault((ch, asked), []).append(call)
        call["_parsed"] = (parent, replies, declared or 0, pts)
        tcalls.setdefault((ch, pts), []).append(call)
        for r in replies:
            reply_parent[(ch, r["ts"])] = pts

    # 2) 記録を作る。返信だと分かっているものは、チャンネル側に出ていても返信として扱う。
    #    初めて知った時刻は、形どおりに読めた原本のうち、その投稿が入っているものの、いちばん早い取った時刻（設計書 3 章）
    in_channel, first_seen = set(), {}

    def seen(ch, ts, at):
        if ts and at and (first_seen.get((ch, ts)) is None or at < first_seen[(ch, ts)]):
            first_seen[(ch, ts)] = at
    for call in calls:
        if not call.get("parse_ok"):
            continue
        if call["tool"] == "slack_read_channel":
            ch, msgs = parse_channel(json.loads(call["response_text"]).get("messages", ""))
            ch = ch or call["input"].get("channel_id")
            for m in msgs:
                in_channel.add((ch, m["ts"]))
                seen(ch, m["ts"], call["fetched_at"])
                tp = reply_parent.get((ch, m["ts"]))
                m.update(channel=ch, thread_ts=tp, raw_file=call["raw_file"], fetched_at=call["fetched_at"])
                if tp:
                    m["reply_count"] = 0
                records[(ch, m["ts"])] = m
        else:
            ch = call["input"].get("channel_id")
            parent, replies, declared, pts = call["_parsed"]
            if parent:
                seen(ch, parent.get("ts"), call["fetched_at"])
            for r in replies:
                seen(ch, r.get("ts"), call["fetched_at"])
                r = dict(r)
                r.pop("part", None)
                r.update(channel=ch, thread_ts=pts, reply_count=0, raw_file=call["raw_file"],
                         fetched_at=call["fetched_at"])
                records[(ch, r["ts"])] = r
            if parent and (ch, parent["ts"]) not in records:
                parent = dict(parent)
                parent.pop("part", None)
                parent.update(channel=ch, thread_ts=None, reply_count=declared,
                              raw_file=call["raw_file"], fetched_at=call["fetched_at"])
                records[(ch, parent["ts"])] = parent
    for key, rec in records.items():
        rec["also_in_channel"] = bool(rec.get("thread_ts")) and key in in_channel
        rec["known_at"] = first_seen.get(key) or rec.get("fetched_at")
        rec["links"] = gh_links(rec)

    # 3) スレッドごとに、いちばん新しい世代の数を出す
    threads = {}
    for key, cs in tcalls.items():
        firsts = [c for c in cs if c["input"].get("cursor") is None]
        gen_at = max(c["fetched_at"] or "" for c in firsts) if firsts else ""
        gen = [c for c in cs if (c["fetched_at"] or "") >= gen_at]
        pages, got = {}, set()
        for c in sorted(gen, key=lambda c: c["fetched_at"] or ""):
            pages[c["input"].get("cursor")] = c["_parsed"][2]
            got.update(r["ts"] for r in c["_parsed"][1])
        threads[key] = {"declared": sum(pages.values()), "got": len(got), "gen_at": gen_at,
                        "gen_calls": gen, "all_calls": cs}
        # スレッドを取ったのが一覧より新しければ、返信数はスレッドの見出しのほうが新しい
        p = records.get(key)
        if p and not p["thread_ts"] and gen_at > (p.get("fetched_at") or ""):
            p["reply_count"] = threads[key]["declared"]
    return records, threads, problems


FIELDS = ("channel", "ts", "thread_ts", "time", "user_id", "user_name", "external_org", "text",
          "reply_count", "also_in_channel", "reactions", "files", "forwarded_from", "attachments", "raw_file", "fetched_at",
          "known_at", "links", "bot")


def cmd_build(_args):
    records, threads, problems = build_records()
    by_ch = {}
    for rec in records.values():
        by_ch.setdefault(rec["channel"], []).append(rec)
    for ch, recs in sorted(by_ch.items()):
        recs.sort(key=lambda r: float(r["ts"]))
        path = os.path.join(channel_dir(ch, create=True), "記録.jsonl")
        with open(path, "w", encoding="utf-8") as f:
            for r in recs:
                row = {"source": "slack"}
                row.update((k, r.get(k)) for k in FIELDS)
                f.write(json.dumps(row, ensure_ascii=False) + "\n")
        tops = sum(1 for r in recs if not r["thread_ts"])
        print("%s: %d 件（親の投稿 %d・返信 %d）→ %s" % (ch, len(recs), tops, len(recs) - tops,
                                                    os.path.relpath(path, DATA)))
    for p in problems:
        print("注意:", p)
    for _, name in RETRIED_RAW:
        print("注意: 空で返ってきたが、あとで取り直せた原本（NG にはしない）:", name)
    return 0


def listed_channels():
    """表示と照合に使うチャンネルの ID（チャンネル.json にあるもの）。一覧が無ければ None（取ったものを全部使う）。
    一覧から外したチャンネルの取ったデータは消さずに残し、表示と照合には使わない（付け直せば続きから取る）"""
    ids = {c["id"] for c in read_json(CHANNELS_PATH, []) if c.get("id")}
    return ids or None


def run_check():
    """照合。戻り値: (表示する行, NG の数, 確かめたスレッドの数, 知らせ, 項目ごとの結果)。
    照合するのは一覧（チャンネル.json）にあるチャンネルだけ"""
    records, threads, problems = build_records()
    raw_all = load_raw()
    use = listed_channels()
    shelved = set()
    shelved_files = set()
    retried = list(RETRIED_RAW)
    aside = [p for p in aside_files() if os.path.relpath(p, ASIDE_ROOT).split(os.sep)[0] != "その他"]
    if use is not None:
        shelved = {call_channel(c) for c in raw_all} - use - {None}
        records = {k: r for k, r in records.items() if r["channel"] in use}
        threads = {k: t for k, t in threads.items() if k[0] in use}
        # 形の崩れた原本の知らせは「形の崩れた原本: <原本のファイル名>」。外したチャンネルの原本のものは外す
        shelved_files = {c["raw_file"] for c in raw_all if call_channel(c) in shelved}
        problems = [p for p in problems if p.split(": ", 1)[-1] not in shelved_files]
        raw_all = [c for c in raw_all if call_channel(c) is None or call_channel(c) in use]
        retried = [(c, n) for c, n in retried if c is None or c in use]
        aside = [p for p in aside if os.path.relpath(p, ASIDE_ROOT).split(os.sep)[0].rsplit("__", 1)[-1] in use]
    lines, notes = [], []
    if shelved:
        notes.append("一覧から外したチャンネル %d 本の取ったデータは、表示と照合に使っていません"
                     "（消してはいません。付け直せば続きから取ります）" % len(shelved))
    # Slack 側の食い違いで取りようがないと分かったものは 例外.json に理由付きで書く。
    # 黙って飛ばさず、照合のたびに「既知の例外」として表示する
    exc_path = EXC_PATH
    exceptions = {}
    if os.path.exists(exc_path):
        with open(exc_path, encoding="utf-8") as f:
            exceptions = {(e["channel"], e["ts"]): e for e in json.load(f)}
    parents = [r for r in records.values() if not r["thread_ts"] and r["reply_count"]]
    thread_ng = gone = exc_n = gave_up = 0
    for p in sorted(parents, key=lambda r: float(r["ts"])):
        e = exceptions.get((p["channel"], p["ts"]))
        if e:
            lines.append("既知の例外: %s %s … %s" % (p["channel"], p["ts"], e["reason"]))
            exc_n += 1
            continue
        t = threads.get((p["channel"], p["ts"]))
        if t is None:
            failed = thread_failed_forms(p["channel"], p["ts"])
            if len(failed) >= len(thread_forms(p["ts"])):
                lines.append("NG 取りに行くと別のスレッドが返る（Slack 側の食い違い・3通りの呼び方で試した）: %s %s（返信 %d）"
                             % (p["channel"], p["ts"], p["reply_count"]))
                gave_up += 1
            elif failed:
                lines.append("NG 返信を取っていないスレッド（別のスレッドが返ったので、次の取得で別の呼び方を試す・%d/%d）: %s %s（返信 %d）"
                             % (len(failed), len(thread_forms(p["ts"])), p["channel"], p["ts"], p["reply_count"]))
            else:
                lines.append("NG 返信を取っていないスレッド: %s %s（返信 %d）" % (p["channel"], p["ts"], p["reply_count"]))
            thread_ng += 1
            continue
        if not (p["reply_count"] == t["declared"] == t["got"]):
            lines.append("NG 数が合わない: %s %s 表示 %d / スレッドの見出し %s / 取れた %d"
                         % (p["channel"], p["ts"], p["reply_count"], t["declared"], t["got"]))
            thread_ng += 1
        in_rec = sum(1 for r in records.values() if r["channel"] == p["channel"] and r["thread_ts"] == p["ts"])
        gone += max(0, in_rec - t["got"])
    if gone:
        notes.append("前に取ったが、いまのスレッドには無い返信: %d 件（消されたか見えなくなった。記録には残してある）" % gone)
    # 逆向き: スレッドを取ってあるのに、親の投稿から返信数が読めていないもの（読み取りの取りこぼし）
    # （返信0件のスレッドを取っただけなら食い違いではない。返信があるのに親から読めていないときだけ NG）
    reverse_ng = 0
    for (ch, pts), t in sorted(threads.items()):
        p = records.get((ch, pts))
        if (p is None or not p["reply_count"]) and (t["declared"] or t["got"]):
            lines.append("NG 親の投稿で返信数が読めていない: %s %s（スレッドの見出し %s）" % (ch, pts, t["declared"]))
            reverse_ng += 1
    # 期間の抜け: チャンネルができた日から、最後に取った区切りの終わりまで、1秒のすき間もなく取れているか
    chans = read_json(CHANNELS_PATH, [])
    gap_parts = []
    for c in chans:
        cs = [x for x in raw_all if x["input"].get("channel_id") == c["id"]]
        ends = [float(x["input"]["latest"]) for x in cs if x["tool"] == "slack_read_channel" and x["input"].get("latest")]
        if not ends:
            continue
        g = coverage_gaps(cs, day_to_ts(c["from"]), max(ends) - 1)
        if g:
            lines.append("NG 期間の抜け: %s に %d か所（合計 %.0f 秒）。いちばん古い抜け: %s"
                         % (c["tag"], len(g), sum(b - a for a, b in g),
                            time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(g[0][0]))))
            gap_parts.append("%s %dか所" % (c["tag"], len(g)))
    # 見出しの形が知らないものだと、その発言は前の発言にくっついて消える。読めなかった見出しの行を数える
    unread = 0
    for call in raw_all:
        if not call.get("parse_ok") or call["tool"] not in ("slack_read_channel", "slack_read_thread"):
            continue
        body = json.loads(call["response_text"]).get("messages", "")
        for line in body.split("\n"):
            if line.startswith("=== Message from ") and not CH_HEAD_RE.match(line):
                unread += 1
            elif call["tool"] == "slack_read_thread" and line.startswith("From: ") and not FROM_RE.match(line):
                unread += 1
    if unread:
        lines.append("NG 形が読めなかった見出しの行: %d（読み分けの規則を足す必要あり）" % unread)
    hidden = [r for r in records.values() if THREAD_LINE_RE.search(r.get("text") or "")]
    if hidden:
        lines.append("NG 返信数の行が本文に残っている投稿: %d 件（読み分けの漏れ。そのスレッドは取れていないかもしれない）" % len(hidden))
    no_ts = [r for r in records.values() if not r.get("ts")]
    if no_ts:
        lines.append("NG ID の無い投稿: %d 件" % len(no_ts))
    for p in problems:
        lines.append("NG " + p)
    if retried:
        notes.append("空で返ってきたが、あとで取り直せた原本: %d 件（Mac のスリープや一時的なエラーなどで。NG にはしない。"
                     "取得の終わりに「よけた原本」のフォルダへ移す）" % len(retried))
    shape = "形の崩れた原本 %d・ID の無い投稿 %d" % (len(problems), len(no_ts))
    if retried:
        shape += "\n空で返ってきたが、あとで取り直せた原本 %d件は NG にしません（取得の終わりに「よけた原本」のフォルダへ移します）" % len(retried)
    if aside:
        shape += "\n空で返ってきたが、あとで取り直せた原本 %d件は「よけた原本」のフォルダに移しました（NG にはしません）" % len(aside)
    bad = (thread_ng + reverse_ng + len(gap_parts) + (1 if unread else 0) + (1 if hidden else 0)
           + (1 if no_ts else 0) + len(problems))
    items = [
        {"name": "スレッドの返信数", "ok": thread_ng + reverse_ng == 0,
         "detail": ("Slack に出ている返信数どおりに、全部取れている（%s本）" % format(len(parents), ",")) if thread_ng + reverse_ng == 0
         else "合わないスレッド %d本" % (thread_ng + reverse_ng)
         + ("（うち、取りに行くと別のスレッドが返るもの %d本）" % gave_up if gave_up else "")},
        {"name": "期間の抜け", "ok": not gap_parts,
         "detail": ("チャンネルができた日から最後の取得まで、1秒のすき間もない（%dチャンネル）" % len(chans)) if not gap_parts
         else "抜けあり: " + "・".join(gap_parts)},
        {"name": "読み分け", "ok": not unread and not hidden,
         "detail": "読めなかった見出しの行 %d・本文に残った返信数の行 %d" % (unread, len(hidden))},
        {"name": "原本の形", "ok": not problems and not no_ts, "detail": shape},
        {"name": "既知の例外", "ok": True, "detail": "%d件（Slack 側の食い違いで取りようがないもの）" % exc_n},
    ]
    return lines, bad, len(parents), notes, items


def cmd_check(_args):
    """照合: 親の投稿に出ている返信数と、実際に取れた返信の数が合うか。"""
    lines, bad, n, notes, _ = run_check()
    for line in lines + notes:
        print(line)
    print("照合: スレッド %d 本を確認、合わないもの %d" % (n, bad))
    return 1 if bad else 0


def cmd_set_aside(_args):
    """空で返ってきたが、あとで同じものを取り直せた原本を、Slack取得データ/よけた原本/<チャンネルのフォルダ名>/<年-月>/ に移す（消さない）。
    取得係.sh が、取り残しが無くなったあと（記録を作る前）に動かす。移したものは、もう一度保存し直さない（extract が よけた原本 も見る）。
    移したものがあるときだけ1行出す（取得係.sh がまとめに書き、件数を 状態.json に残す）"""
    paths = {os.path.basename(p): p for p in raw_files()}
    moved = 0
    for call in retried_broken(load_raw()):
        src = paths.get(call["raw_file"])
        if not src:
            continue
        # Slack取得データ/チャンネル/<名前>__<ID>/原本/<年-月>/x.json → Slack取得データ/よけた原本/<名前>__<ID>/<年-月>/x.json
        # Slack取得データ/その他/原本/<年-月>/x.json                → Slack取得データ/よけた原本/その他/<年-月>/x.json
        parts = os.path.relpath(os.path.dirname(src), DATA).split(os.sep)
        sub = os.path.join(parts[1] if parts[0] == "チャンネル" else parts[0], parts[-1])
        dst = os.path.join(ASIDE_ROOT, sub, call["raw_file"])
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        os.replace(src, dst)
        moved += 1
    if moved:
        print("よけた原本: %d 件（空で返ってきたが、あとで同じものを取り直せたもの。「よけた原本」のフォルダに移した）" % moved)
    return 0


# ---- Mac のスリープ（取得の途中で眠っていた間） ----

# 種類の欄は空白で幅をそろえたあとにタブが来る。「Wake Requests」（起こす予約）の行は拾わない
PMSET_RE = re.compile(r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d [+-]\d{4}) (Sleep|Wake|DarkWake) +\t")


def iso_to_epoch(s):
    """ISO の時刻（2026-10-13T00:00:01.000Z や 2026-10-13T09:01:42+09:00）を UNIX 秒に。読めなければ None"""
    import datetime
    try:
        return datetime.datetime.fromisoformat((s or "").replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def mac_sleeps(t0, t1):
    """t0〜t1（UNIX 秒）のあいだに Mac が眠っていた区切りを [(眠った, 起きた), ...] で返す。Mac の電源の記録（pmset -g log）から読む。
    眠っている間にも、点検のために数十秒だけ起きる（DarkWake）ことがある。その間は取得も動くが、2分以内に眠り直したものは、
    続けて眠っていたことにする（2026-10-12 は、1時間おきに一瞬起きながら 9:02〜22:09 眠っていた → 1回）。
    点検で起きている間に取得が始まって終わったとき（2026-10-11 9:08〜9:11）は、眠っていたことにしない。Mac でない・記録が読めないときは空"""
    import datetime
    import subprocess
    try:
        out = subprocess.run(["/usr/bin/pmset", "-g", "log"], capture_output=True, text=True, timeout=120).stdout
    except (OSError, subprocess.SubprocessError):
        return []
    spans, since = [], None
    for line in out.splitlines():
        m = PMSET_RE.match(line)
        if not m:
            continue
        try:
            t = datetime.datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S %z").timestamp()
        except ValueError:
            continue
        if t > t1:
            break
        if m.group(2) == "Sleep":
            if since is None:
                since = t
        elif since is not None:   # Wake（本当に起きた）・DarkWake（点検で一瞬起きた）
            spans.append((since, t))
            since = None
    if since is not None:
        spans.append((since, t1))
    merged = []
    for a, b in spans:
        a, b = max(a, t0), min(b, t1)
        if b <= a:
            continue
        if merged and a - merged[-1][1] <= 120:   # 一瞬起きて、すぐ眠り直した
            merged[-1] = (merged[-1][0], b)
        else:
            merged.append((a, b))
    return merged


def span_text(seconds):
    """39分・13時間8分・1分未満"""
    m = int(seconds // 60)
    if m < 1:
        return "1分未満"
    return "%d時間%d分" % (m // 60, m % 60) if m >= 60 else "%d分" % m


def sleep_info(spans):
    """状態.json・取得の記録に残す形（アプリが読む）。眠っていなければ None"""
    if not spans:
        return None
    import datetime
    iso = lambda t: datetime.datetime.fromtimestamp(t).astimezone().isoformat(timespec="seconds")
    return {"count": len(spans), "seconds": int(sum(b - a for a, b in spans)),
            "spans": [[iso(a), iso(b)] for a, b in spans[:20]]}


def sleep_when(spans):
    """「9:01〜9:40（39分）」「2回・合わせて 52分（9:01〜9:40・10:02〜10:15）」。日をまたぐときは日付も付ける"""
    def hm(t, ref):
        lt, lr = time.localtime(t), time.localtime(ref)
        same = lt.tm_yday == lr.tm_yday and lt.tm_year == lr.tm_year
        return ("%d:%02d" if same else "%d/%d %%d:%%02d" % (lt.tm_mon, lt.tm_mday)) % (lt.tm_hour, lt.tm_min)
    total = span_text(sum(b - a for a, b in spans))
    parts = ["%s〜%s" % (hm(a, a), hm(b, a)) for a, b in spans[:3]]
    if len(spans) == 1:
        return "%s（%s）" % (parts[0], total)
    return "%d回・合わせて %s（%s）" % (len(spans), total, "・".join(parts) + ("ほか" if len(spans) > 3 else ""))


CURSOR_RE = re.compile(r"cursor:? `([^`]+)`")
JST_OFFSET = 9 * 3600


def next_cursor_of(call):
    try:
        info = json.loads(call["response_text"]).get("pagination_info", "")
    except ValueError:
        return None
    m = CURSOR_RE.search(info)
    return m.group(1) if m else None


def day_to_ts(day, end=False):
    import calendar
    import time
    t = calendar.timegm(time.strptime(day, "%Y-%m-%d")) - JST_OFFSET
    return t + 86400 - 1 if end else t


def missing_pages(calls):
    """同じ取り方（同じ範囲）の呼び出し群から、まだ取っていないページの cursor を返す。
    1ページ目が無ければ [None]。続きの目印のうち、まだ使っていないものがあればそれら。"""
    if not calls:
        return [None]
    used = set(c["input"].get("cursor") for c in calls if c.get("parse_ok"))
    if None not in used:
        return [None]
    nexts = set(n for n in (next_cursor_of(c) for c in calls if c.get("parse_ok")) if n)
    return sorted(nexts - used)


SEARCH_AHEAD = 10


def search_page_of(cursor):
    """検索の続きの目印は「CURRENT_PAGE:<何ページ目>」を base64 にしたもの。ページ番号を返す（読めなければ None）"""
    if not cursor:
        return 1
    try:
        m = re.match(r"CURRENT_PAGE:(\d+)$", base64.b64decode(cursor).decode())
    except Exception:
        return None
    return int(m.group(1)) if m else None


def search_cursor(page):
    return base64.b64encode(("CURRENT_PAGE:%d" % page).encode()).decode()


def search_pages_to_fetch(calls):
    """検索は1ページ20件で、次の目印は前のページを取るまで分からない。1周に1ページだと周が増えるので、
    目印が「CURRENT_PAGE:n」の形だと確かめられたときだけ、次の SEARCH_AHEAD ページを先回りして頼む。
    形が違えば、今までどおり1ページずつ（missing_pages）に戻る。"""
    ok = [c for c in calls if c.get("parse_ok")]
    if not ok:
        return [None]
    pages = {}
    for c in ok:
        n = search_page_of(c["input"].get("cursor"))
        if n is None:
            return missing_pages(calls)
        pages[n] = c
    todo = []
    for k in range(2, max(pages) + 1):  # 先回りで失敗して抜けたページ
        if k not in pages and (k - 1) in pages and next_cursor_of(pages[k - 1]):
            todo.append(search_cursor(k))
    last = max(pages)
    nxt = next_cursor_of(pages[last])
    if nxt:
        if search_page_of(nxt) == last + 1:
            todo += [search_cursor(k) for k in range(last + 1, last + 1 + SEARCH_AHEAD)]
        else:
            todo.append(nxt)
    return todo


def week_starts(t_from, t_to):
    """チャンネルを1週間ごとに区切ったときの、各区切りの始まりの時刻"""
    out, s0 = [], t_from
    while s0 <= t_to:
        out.append(s0)
        s0 += 7 * 86400
    return out


def complete_spans(calls):
    """ページを取り終えたチャンネルの区切り（oldest〜latest。両端は含まない）を、始めの順に並べて返す"""
    groups = {}
    for c in calls:
        if c["tool"] == "slack_read_channel" and c.get("parse_ok") and c["input"].get("oldest") and c["input"].get("latest"):
            groups.setdefault((c["input"]["oldest"], c["input"]["latest"]), []).append(c)
    return sorted((float(o), float(l)) for (o, l), cs in groups.items() if not missing_pages(cs))


def done_spans(calls):
    """取ってある期間 [[始め, 終わり], ...]（両端は含まない）。取り終えた区切りを、区切り方によらずつなげたもの。
    つなげるのは、次の区切りの始めが前の終わりより前のときだけ（ちょうど同じ時刻なら、その1点が抜けている）。
    coverage_gaps と同じ決まり"""
    merged = []
    for lo, hi in complete_spans(calls):
        if merged and lo < merged[-1][1]:
            merged[-1][1] = max(merged[-1][1], hi)
        else:
            merged.append([lo, hi])
    return merged


def is_done(spans, lo, hi):
    """区切り（lo〜hi。両端は含まない）の中が、取ってある期間に丸ごと入っているか"""
    return any(a <= lo and hi <= b for a, b in spans)


def coverage_gaps(calls, t_from, t_end):
    """取り終えたチャンネルの区切り（oldest〜latest。両端は含まない）をつなげて、抜けている時間を返す。"""
    spans = complete_spans(calls)
    gaps, reach = [], float(t_from) - 1e-9  # reach: ここまでは取れている（この時刻ちょうどは含まない）
    for lo, hi in spans:
        if hi <= reach:
            continue
        if lo >= reach and reach < t_end:   # lo と reach の間（両端を含む）が抜け
            gaps.append((reach, min(lo, t_end)))
        reach = max(reach, hi)
        if reach > t_end:
            break
    if reach <= t_end:   # いちばん後ろの抜け（最後の区切りが途中までしか取れていないとき）
        gaps.append((reach, t_end))
    return [(a, b) for a, b in gaps if b >= a]


def opt(args, name, default=None):
    return args[args.index(name) + 1] if name in args else default


def cmd_plan(args):
    """まだ取っていないもの・取り直すものを、取得係に渡す呼び出しの一覧（1行1件の JSON）として出す。

    - チャンネルは1週間ごとに区切って取り、100件を超えた週は続きのページを足す
    - --refresh-since <時刻> があれば、直近 --recent-days 日（既定14）にかかる週は、その時刻より後に
      取り直す（返信の増え・書き直しを拾うため）
    - --search-after <日付> があれば、その日より後のスレッドの投稿を Slack の検索で探し、
      記録に無い返信が付いたスレッドを取り直す（古いスレッドへの後からの返信を拾うため）
    - スレッドは、返信のある親の投稿を全部取る。チャンネル一覧の返信数がスレッドより新しくて数が違えば取り直す
    - 取ってある期間は、週の区切り方によらず取り直さない（取り始める日をずらした・一覧から外していたチャンネルを
      付け直したときも、取っていない期間だけを取る）。直近の取り直しの週は除く
    - 検索は、そのチャンネルを前に取った日の前の日からも探す（付け直したとき、外していた間に古いスレッドに付いた返信を拾う）
    何を取るかはここ（プログラム）が決める。取得係の AI は一覧を順に呼ぶだけ。
    """
    if len(args) < 3:
        print("使い方: python3 slack.py plan <チャンネルID> <開始日> <終了日> [--max N] "
              "[--refresh-since 時刻] [--recent-days 14] [--search-after 日付]")
        return 2
    import time
    ch, day_from, day_to = args[0], args[1], args[2]
    limit = int(opt(args, "--max", 150))
    since = opt(args, "--refresh-since")
    recent_days = int(opt(args, "--recent-days", 14))
    search_after = opt(args, "--search-after")
    t_from, t_to = day_to_ts(day_from), day_to_ts(day_to, end=True)
    raw = [c for c in load_raw(ch) if call_channel(c) == ch]   # このチャンネルの原本だけ読む（チャンネルが多くても速い）
    fresh = lambda c: since is None or (c.get("fetched_at") or "") >= since
    todo = []
    # 取ってある期間（区切り方によらない）。週の区切りが前と違っても（取り始める日をずらした・付け直した）、
    # この中に丸ごと入る区切りは取り直さない。直近の取り直しの週（--refresh-since）は、これまでどおり取り直す
    done = done_spans(raw)

    # チャンネル: 1週間ごとの区切り
    recent_from = time.time() - recent_days * 86400
    start = t_from
    while start <= t_to:
        end = min(start + 7 * 86400 - 1, t_to)
        same = [c for c in raw if c["tool"] == "slack_read_channel"
                and c["input"].get("oldest") == str(start) and c["input"].get("latest") == str(end)]
        if since and end >= recent_from:
            same = [c for c in same if fresh(c)]
        elif is_done(done, start, end):
            start = end + 1
            continue
        for cur in missing_pages(same):
            a = {"channel_id": ch, "oldest": str(start), "latest": str(end), "limit": 100,
                 "response_format": "detailed"}
            if cur:
                a["cursor"] = cur
            todo.append({"tool": "slack_read_channel", "args": a})
        start = end + 1

    # 境目: Slack の oldest / latest は「その時刻ちょうど」を含まない（2026-10-09 に確認）。
    # 週の区切りの境目の1秒（例 23:59:59〜0:00:00）は、どちらの週にも入らないので、
    # 境目ごとに前後の数秒だけを取る小さな区切りを足す（check の「期間の抜け」で確かめる）
    for s0 in week_starts(t_from, t_to):
        lo, hi = s0 - 2, s0 + 1
        same = [c for c in raw if c["tool"] == "slack_read_channel"
                and c["input"].get("oldest") == str(lo) and c["input"].get("latest") == str(hi)]
        if since and hi >= recent_from:
            same = [c for c in same if fresh(c)]
        elif is_done(done, lo, hi):
            continue
        for cur in missing_pages(same):
            a = {"channel_id": ch, "oldest": str(lo), "latest": str(hi), "limit": 100, "response_format": "detailed"}
            if cur:
                a["cursor"] = cur
            todo.append({"tool": "slack_read_channel", "args": a})

    # 検索: 前回より後のスレッドの投稿（古いスレッドに後から付いた返信を見つけるため）
    found = {}  # 親ts -> 検索で見つけた時刻
    records, threads, _ = build_records(ch)
    if search_after:
        # このチャンネルを前に取った最後の時刻（今回の取得の分は除く。周をまたいでも同じ日になるように）。
        # 一覧から外していたチャンネルを付け直したときは、外していた間に古いスレッドに付いた返信も拾えるよう、
        # その日の前の日から探す。ふだんは前回の取得の日なので、全体の日付（最後にうまくいった日の前の日）と同じかそれより後
        last = max((c.get("fetched_at") or "" for c in raw if not since or (c.get("fetched_at") or "") < since), default="")
        if last:
            import calendar
            try:
                t = calendar.timegm(time.strptime(last[:19], "%Y-%m-%dT%H:%M:%S")) + JST_OFFSET - 86400
                search_after = min(search_after, time.strftime("%Y-%m-%d", time.gmtime(t)))
            except ValueError:
                pass   # 時刻の形が読めなければ、全体の日付のまま
        filt = "in:<#%s> after:%s is:thread" % (ch, search_after)
        same = [c for c in raw if c["tool"] == SEARCH_TOOL and c["input"].get("filters") == filt and fresh(c)]
        for cur in search_pages_to_fetch(same):
            a = {"filters": filt, "natural_language_query": "", "limit": 20, "include_context": False,
                 "include_bots": True, "response_format": "detailed", "sort": "timestamp"}
            if cur:
                a["cursor"] = cur
            todo.append({"tool": SEARCH_TOOL, "args": a})
        for c in same:
            if not c.get("parse_ok"):
                continue
            text = json.loads(c["response_text"]).get("results", "")
            for block in text.split("\n### Result ")[1:]:
                m, tp = SEARCH_MSG_RE.search(block), THREAD_PARAM_RE.search(block)
                if m and tp and tp.group(1) != m.group(1) and (ch, m.group(1)) not in records:
                    found[tp.group(1)] = max(found.get(tp.group(1), ""), c["fetched_at"] or "")

    # スレッド
    parents = {r["ts"]: r for r in records.values()
               if r["channel"] == ch and not r["thread_ts"] and r["reply_count"]
               and t_from <= float(r["ts"]) <= t_to}
    for pts in found:
        parents.setdefault(pts, {"ts": pts, "reply_count": 0, "fetched_at": ""})
    for p in sorted(parents.values(), key=lambda r: float(r["ts"])):
        t = threads.get((ch, p["ts"]))
        forms = thread_forms(p["ts"])
        form = forms[0]
        failed = thread_failed_forms(ch, p["ts"])
        if 0 in failed:
            # ふだんの呼び方で別のスレッドが返ったスレッド。当たった呼び方があればそれをまね（取り直しでまた外れないように）、
            # 無ければ、まだ外れていない呼び方で頼む。歯止め: 3通りとも外れたら、もう一覧に入れない
            # （同じ呼び出しを何周も繰り返して利用枠を無駄にしないため）。check には NG として残る
            hits = sorted((c for c in (t["all_calls"] if t else []) if c["input"].get("message_ts") == p["ts"]),
                          key=lambda c: c.get("fetched_at") or "")
            use = form_index(p["ts"], hits[-1]) if hits else None
            if use is None:
                left = [i for i in range(len(forms)) if i not in failed]
                use = left[0] if left else None
            if use is None:
                print("3通りの呼び方で頼んでも別のスレッドが返る: %s %s（返信 %d）→ 一覧に入れない"
                      % (ch, p["ts"], p["reply_count"]), file=sys.stderr)
                continue
            form = forms[use]
        if t is None:
            pages = [None]
        else:
            # 取り直しの合図: チャンネル一覧のほうが新しくて返信数が違う / 検索で記録に無い返信が見つかった
            evidence = ""
            if (p.get("fetched_at") or "") > t["gen_at"] and p["reply_count"] != t["declared"]:
                evidence = p["fetched_at"]
            if found.get(p["ts"], "") > t["gen_at"]:
                evidence = max(evidence, found[p["ts"]])
            pages = [None] if evidence else missing_pages(t["gen_calls"])
        for cur in pages:
            # ふだんは oldest を親の投稿の時刻にする（別のスレッドが返る不具合を避けられる。2026-10-08 確認）
            a = {"channel_id": ch, "message_ts": p["ts"]}
            a.update(form)
            a.update({"limit": 1000, "response_format": "detailed"})
            if cur:
                a["cursor"] = cur
            todo.append({"tool": "slack_read_thread", "args": a})

    for item in todo[:limit]:
        print(json.dumps(item, ensure_ascii=False))
    print("残り %d 件（今回 %d 件）" % (len(todo), min(len(todo), limit)), file=sys.stderr)
    return 0


# ---- 状態ファイル（メニューバーのアプリが読む） ----

STATE_PATH = os.path.join(DATA, "状態.json")
HISTORY_PATH = os.path.join(DATA, "取得の記録.jsonl")
CHANNELS_PATH = os.path.join(DATA, "チャンネル.json")
EXC_PATH = os.path.join(DATA, "例外.json")


def now_iso():
    import datetime
    return datetime.datetime.now().astimezone().isoformat(timespec="seconds")


def read_json(path, default):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def write_json(path, data):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=1)
        f.write("\n")
    os.replace(tmp, path)


def channel_stats(st):
    """記録から、チャンネルごとの数字と、直近14日の日ごとの件数を数える。"""
    import datetime
    chans = read_json(CHANNELS_PATH, [])
    prev = {c["id"]: c.get("total", 0) for c in st.get("channels", [])}
    today = datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=9))).date()
    days14 = [(today - datetime.timedelta(days=i)).isoformat() for i in range(13, -1, -1)]
    days30 = [(today - datetime.timedelta(days=i)).isoformat() for i in range(29, -1, -1)]
    prev7set = {(today - datetime.timedelta(days=i)).isoformat() for i in range(13, 6, -1)}
    d7, d30 = days30[-7], days30[0]
    daily = {d: {} for d in days14}
    out = []
    for c in chans:
        path = os.path.join(channel_dir(c["id"]), "記録.jsonl")
        total = parents = threads = ext = last7 = last30 = 0
        last, first = "", ""
        spark = dict.fromkeys(days30, 0)
        people, people30 = set(), set()
        week = {d: {} for d in days30[-7:]}
        latest_name = {}
        prev7 = 0
        if os.path.exists(path):
            with open(path, encoding="utf-8") as f:
                for line in f:
                    r = json.loads(line)
                    t = r["time"] or ""
                    d = t[:10]
                    total += 1
                    if not r["thread_ts"]:
                        parents += 1
                        threads += 1 if r.get("reply_count") else 0
                    ext += 1 if r.get("external_org") else 0
                    last = max(last, t)
                    first = min(first, t) if first else t
                    people.add(r.get("user_id"))
                    if d >= d7:
                        last7 += 1
                    if d >= d30:
                        last30 += 1
                        people30.add(r.get("user_id"))
                    if d in spark:
                        spark[d] += 1
                    uid = r.get("user_id") or "?"
                    if r.get("user_name") is not None and t >= latest_name.get(uid, ("", ""))[0]:
                        latest_name[uid] = (t, r.get("user_name") or "")
                    if d in week:
                        week[d][uid] = week[d].get(uid, 0) + 1
                    if d in prev7set:
                        prev7 += 1
                    if d in daily:
                        daily[d][c["tag"]] = daily[d].get(c["tag"], 0) + 1
        out.append({"id": c["id"], "tag": c["tag"], "name": c["name"], "created": c.get("from"),
                    "total": total, "parents": parents, "replies": total - parents, "threads": threads,
                    "external": ext, "last_post": last, "first_post": first,
                    "last7": last7, "last30": last30, "people": len(people - {None}), "people30": len(people30 - {None}),
                    "spark": [spark[d] for d in days30],
                    "week": [{"date": d, "total": sum(week[d].values()),
                              "users": [{"name": (latest_name.get(u, ("", ""))[1] or "（名前なし・%s）" % u), "count": n}
                                        for u, n in sorted(week[d].items(), key=lambda x: -x[1])]}
                             for d in days30[-7:]],
                    "prev7": prev7,
                    "people7": len({u for d in week for u in week[d]}),
                    "delta": total - prev[c["id"]] if c["id"] in prev else None})
    daily_list = [{"date": d, "counts": {c["tag"]: daily[d].get(c["tag"], 0) for c in chans}} for d in days14]
    return out, daily_list


def cmd_status(args):
    """状態.json を書く。
      status running --run-start 時刻 --round N --todo M      取得中
      status done --run-start 時刻 --result ok|ng|stopped|error --cost X --rounds N --turns T [--note 文]
                  [--delayed 9:00（予定の時刻に Mac がスリープしていたので、起きてから始めた）] [--set-aside よけた原本の数]
                  （取得の途中で Mac が眠っていた間は、Mac の電源の記録から調べて残す）
      status refresh                                          件数・照合だけ数え直す（取得の記録は増やさない）
      status interrupted --run-start 時刻 [--stamp 印]          途中で終わった取得を、取得の記録に残す
    done のときは記録から件数を数え、照合をして、取得の記録.jsonl にも1行足す。
    """
    os.makedirs(DATA, exist_ok=True)
    if args and args[0] == "interrupted":
        # 前の取得が、アプリの終了や Mac の電源などで途中で終わった跡を、取得の記録に1行残す
        stamp = opt(args, "--stamp")
        cost = 0.0
        if stamp:
            for f in glob.glob(os.path.join(LOG_ROOT, "*", stamp + "_round*_結果.json")):
                cost += (read_json(f, {}) or {}).get("total_cost_usd") or 0
        entry = {"start": opt(args, "--run-start"), "end": now_iso(), "result": "interrupted", "rounds": 0,
                 "turns": 0, "cost_usd": round(cost, 4), "new": 0, "channels": {}, "ng": 0,
                 "note": "途中で終わった（アプリの終了や Mac の電源などで）。次の取得で続きから取った"}
        with open(HISTORY_PATH, "a", encoding="utf-8") as f:
            f.write(json.dumps(entry, ensure_ascii=False) + "\n")
        print("途中で終わった取得を記録しました")
        return 0
    if not args or args[0] not in ("running", "done", "refresh"):
        print(cmd_status.__doc__)
        return 2
    st = read_json(STATE_PATH, {})
    st["updated"] = now_iso()
    if args[0] == "running":
        st["state"] = "running"
        st["run"] = {"start": opt(args, "--run-start"), "round": int(opt(args, "--round", 0)),
                     "todo": int(opt(args, "--todo", 0)), "channel": opt(args, "--channel")}
        write_json(STATE_PATH, st)
        return 0

    if args[0] == "refresh":
        keep = {c["id"]: c.get("delta") for c in st.get("channels", [])}
        out, daily = channel_stats({})
        for c in out:
            c["delta"] = keep.get(c["id"])
        lines, bad, n, notes, items = run_check()
        if st.get("state") in ("ok", "ng"):
            # 取得のあとの印は、数え直した照合に合わせる（既知の例外にした・チャンネルを外した、などで NG が無くなったとき）。
            # 途中で止まった・失敗・取得中の印はそのまま（取得の結果なので、数え直しでは変えない）
            st["state"] = "ng" if bad else "ok"
        st.update(channels=out, daily=daily,
                  check={"threads": n, "ng": [l for l in lines if l.startswith("NG")], "notes": notes, "items": items,
                         "exceptions": [l for l in lines if l.startswith("既知の例外")]})
        write_json(STATE_PATH, st)
        print("数え直しました（照合 NG %d）" % bad)
        return 0

    out, daily = channel_stats(st)
    lines, bad, n, notes, items = run_check()
    result = opt(args, "--result", "ok")
    if result == "ok" and bad:
        result = "ng"
    run = {"start": opt(args, "--run-start"), "end": now_iso(), "result": result,
           "rounds": int(opt(args, "--rounds", 0)), "turns": int(opt(args, "--turns", 0)),
           "cost_usd": float(opt(args, "--cost", 0)), "note": opt(args, "--note"),
           "new": sum(c["delta"] or 0 for c in out),
           "since": (st.get("run") or {}).get("end")}
    # 取得の途中で Mac が眠っていた間（眠っている間は取得が止まる。アプリと取得の記録に出す）
    t0 = iso_to_epoch(run["start"])
    spans = mac_sleeps(t0, time.time()) if t0 else []
    if spans:
        run["sleep"] = sleep_info(spans)
    # スリープで取れなかった: 途中で眠っていて、うまく終わらなかった（失敗・照合 NG・上限で止まった。止めるボタンは除く）。
    # アプリが「もう一度取る」を促す（2026-10-13 本人の希望。スリープ中でも取得は始め、取れなかったら知らせる）
    missed = bool(spans) and (result in ("ng", "error")
                              or (result == "stopped" and not (run["note"] or "").startswith("止めるボタン")))
    if missed:
        run["sleep_missed"] = True
    if opt(args, "--delayed"):   # 予定の時刻（9:00 など）に Mac がスリープしていたので、起きてから始めた
        run["delayed_from"] = opt(args, "--delayed")
    if int(opt(args, "--set-aside", 0) or 0):   # この取得でよけた原本の数
        run["set_aside"] = int(opt(args, "--set-aside"))
    st.update(state=result, run=run, channels=out, daily=daily,
              check={"threads": n, "ng": [l for l in lines if l.startswith("NG")], "notes": notes, "items": items,
                     "exceptions": [l for l in lines if l.startswith("既知の例外")]})
    if result == "ok":
        st["last_success"] = run["end"]
    write_json(STATE_PATH, st)
    with open(HISTORY_PATH, "a", encoding="utf-8") as f:
        f.write(json.dumps(dict(run, channels={c["tag"]: c["delta"] for c in out}, ng=len(st["check"]["ng"])),
                           ensure_ascii=False) + "\n")
    # 取得係.sh は最後の行（状態: …）を通知に使う。スリープの行はその前に出す
    if spans:
        print("途中で Mac がスリープしていました: %s。スリープの間、取得は止まっていました" % sleep_when(spans))
    if missed:   # 取得係.sh はこの行を見て、通知を「スリープで取れなかった」にする
        print("スリープで取れなかった分があります。Mac が起きているときに、もう一度取ってください（アプリの「もう一度取る」）")
    print("状態: %s（新しく %d 件・照合 NG %d%s）" % (result, run["new"], len(st["check"]["ng"]),
          "・途中で Mac がスリープ " + span_text(run["sleep"]["seconds"]) if spans else ""))
    return 0


# ---- 前の場所からの引っ越し ----
#
# 2026-10 までは、取ったものを取得の仕組みのフォルダの中の データ/ に置いていた（もっと前は、フォルダの一番上に
# 原本/・記録/・状態.json など）。どちらも、新しい場所（DATA）へ「写す → 1つずつ同じか確かめる → 切り替える」で引っ越す。
# 途中で失敗したら写しかけを捨てるだけで、前のデータには触らない（もう一度動かせば、初めからやり直す）。
# うまくいったら、前のデータは「データ（引っ越し済み 日付）」に名前を変えて、同じフォルダに残す（見張りはこの名前を見ない。
# .gitignore でも外してある）。消すのは、新しい場所で取れたのを確かめてから、別の手順で（アプリの設定か Finder で）

OLD_TOP = ("原本", "記録", "取得ログ", "チャンネル.json", "外したチャンネル.json", "チャンネル候補.json",
           "状態.json", "取得の記録.jsonl", "例外.json")   # もっと前の形で、フォルダの一番上にあったもの
MOVED_PREFIX = "データ（引っ越し済み"
MIGRATE_NOTE = ".引っ越しの記録.json"   # 新しい場所に書く（どこから・何ファイル・何バイト）


def short(p):
    home = os.path.expanduser("~")
    return "~" + p[len(home):] if p == home or p.startswith(home + os.sep) else p


def same_place(a, b):
    """同じフォルダか（日本語の名前は、濁点の持ち方〈NFC・NFD〉が違っても同じとみなす）"""
    try:
        return os.path.samefile(a, b)
    except OSError:
        norm = lambda p: unicodedata.normalize("NFC", os.path.realpath(p))
        return norm(a) == norm(b)


def old_data_kinds(folder):
    """取得の仕組みのフォルダに残っている前のデータ。"データ"（中の データ/）と "一番上"（もっと前の形）のうち、あるもの"""
    if same_place(folder, DATA):   # データの場所を、わざとこのフォルダにしている
        return []
    kinds = []
    inner = os.path.join(folder, "データ")
    if os.path.isdir(inner) and not same_place(inner, DATA) and any(e != ".DS_Store" for e in os.listdir(inner)):
        kinds.append("データ")
    if any(os.path.lexists(os.path.join(folder, n)) for n in OLD_TOP):
        kinds.append("一番上")
    return kinds


OLD_DATA_MESSAGE = ("前の場所にデータがあります（%s）。先に、新しい場所（%s）へ引っ越してください: "
                    "アプリの「引っ越す」を押すか、このフォルダで python3 slack.py migrate を動かす（前のデータは消しません）")


def lock_alive(lock_dir):
    """取得中の印（.取得中/pid）の取得が、まだ動いているか"""
    try:
        with open(os.path.join(lock_dir, "pid"), encoding="utf-8") as f:
            os.kill(int(f.read().strip()), 0)
        return True
    except PermissionError:   # 動いているが、ほかの人のもの
        return True
    except (OSError, ValueError):
        return False


def file_sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def migrate_files(src, kinds):
    """前のデータのファイルと、新しい場所での置き場所（DATA からの相対）の組。
    取得中の印（.取得中/）・書きかけ（.tmp）・.DS_Store は写さない"""
    pairs = []
    if "データ" in kinds:   # 2026-10 までの形: そのままの並びで写す
        root = os.path.join(src, "データ")
        for dp, dns, fns in os.walk(root):
            dns[:] = sorted(d for d in dns if d != ".取得中")
            for f in sorted(fns):
                if f != ".DS_Store" and not f.endswith(".tmp"):
                    p = os.path.join(dp, f)
                    pairs.append((p, os.path.relpath(p, root)))
    if "一番上" in kinds:   # もっと前の形: チャンネルごと・月ごとのフォルダに分けて置く（前の migrate と同じ置き方）
        # チャンネルのフォルダの名前: 途中まで データ/ に移してあれば、そのフォルダの名前をそのまま使う。
        # 無ければ チャンネル.json の名前（データ/ の中のものが勝つ。前の migrate も、そちらを読んでいた）
        folders, names = {}, {}
        inner_ch = os.path.join(src, "データ", "チャンネル")
        for e in (os.listdir(inner_ch) if os.path.isdir(inner_ch) else []):
            folders[e.rsplit("__", 1)[-1]] = e
        for path in (os.path.join(src, "チャンネル.json"), os.path.join(src, "データ", "チャンネル.json")):
            for c in read_json(path, []):
                if isinstance(c, dict) and c.get("id") and safe_name(c.get("name")):
                    names[c["id"]] = safe_name(c["name"])

        def ch_folder(ch):
            if ch in folders:
                return os.path.join("チャンネル", folders[ch])
            return os.path.join("チャンネル", "%s__%s" % (names[ch], ch) if names.get(ch) else ch)

        for n in OLD_TOP:
            if os.path.isfile(os.path.join(src, n)):
                pairs.append((os.path.join(src, n), n))
        for dp, dns, fns in os.walk(os.path.join(src, "原本")):
            dns.sort()
            for f in sorted(fns):
                if not f.endswith(".json"):
                    continue
                p = os.path.join(dp, f)
                call = read_json(p, None)
                ch = call_channel(call) if isinstance(call, dict) else None
                month = call_month(call) if isinstance(call, dict) else time.strftime("%Y-%m", time.localtime(os.path.getmtime(p)))
                pairs.append((p, os.path.join(ch_folder(ch) if ch else "その他", "原本", month, f)))
        for dp, dns, fns in os.walk(os.path.join(src, "記録")):
            for f in sorted(fns):
                if f.endswith(".jsonl"):
                    pairs.append((os.path.join(dp, f), os.path.join(ch_folder(f[:-len(".jsonl")]), "記録.jsonl")))
        logs = os.path.join(src, "取得ログ")
        for dp, dns, fns in os.walk(logs):
            dns.sort()
            for f in sorted(fns):
                if f == ".DS_Store":
                    continue
                p = os.path.join(dp, f)
                rel = os.path.relpath(p, logs)
                if os.sep not in rel:   # 一番上に並んでいた取得ログは、月ごとのフォルダへ
                    m = re.match(r"(\d{4})(\d{2})\d{2}-", f)
                    rel = os.path.join("%s-%s" % m.groups(), f) if m else f
                pairs.append((p, os.path.join("取得ログ", rel)))
    # 同じ置き場所に2つ来たら: 中身が同じなら1つにする。違えば、どちらかを失うので引っ越さない
    out, seen = [], {}
    for p, rel in pairs:
        if rel in seen:
            if file_sha(p) != file_sha(seen[rel]):
                raise ValueError("同じ置き場所（%s）に、中身の違う2つのファイルがあります: %s と %s" % (rel, seen[rel], p))
            continue
        seen[rel] = p
        out.append((p, rel))
    return out


def cmd_where(_args):
    """データの場所を出す（前の場所にデータが残っていれば、それも言う）"""
    print(DATA)
    if old_data_kinds(HERE):
        print(OLD_DATA_MESSAGE % (short(HERE), short(DATA)))
    return 0


def cmd_guard(_args):
    """前の場所にデータが残っていなければ 0（残っていれば main が 4 で止める）。台本が最初に呼んで確かめる"""
    return 0


def cmd_migrate(args):
    """前の場所（取得の仕組みのフォルダの中）のデータを、新しい場所（Slack取得データ/）へ引っ越す。
      python3 slack.py migrate [前のフォルダ]   … 前のフォルダを省くと、このフォルダ
    写す → 1つずつ同じか確かめる → 新しい場所に切り替える、の順。途中で失敗しても前のデータには触らない
    （もう一度動かせばやり直す）。うまくいったら、前のデータは「データ（引っ越し済み 日付）」に名前を変えて残す"""
    src = os.path.abspath(os.path.expanduser(args[0])) if args else HERE
    if not os.path.isdir(src):
        print("前のフォルダが見つかりません: %s" % src)
        return 2
    kinds = old_data_kinds(src)
    if not kinds:
        print("引っ越すものはありません（%s に前のデータはありません）。データの場所: %s" % (short(src), short(DATA)))
        return 0
    for lock in (os.path.join(src, "データ", ".取得中"), os.path.join(src, ".取得中"), os.path.join(DATA, ".取得中")):
        if os.path.isdir(lock) and lock_alive(lock):
            print("取得中なので引っ越しません。取得が終わってから、もう一度動かしてください。")
            return 3
    try:
        pairs = migrate_files(src, kinds)
    except (OSError, ValueError) as e:
        print("引っ越しをやめました（前のデータはそのまま）: %s" % e)
        return 1
    total = sum(os.path.getsize(p) for p, _ in pairs)
    # 写して切り替えたあと、前のデータに名前を付ける前に止まっていたら、名前を付けるところから続ける
    note = read_json(os.path.join(DATA, MIGRATE_NOTE), None)
    if (isinstance(note, dict) and same_place(note.get("from") or "", src)
            and note.get("files") == len(pairs) and note.get("bytes") == total):
        return finish_migrate(src, kinds, len(pairs), total)
    if os.path.lexists(DATA) and (not os.path.isdir(DATA) or any(e != ".DS_Store" for e in os.listdir(DATA))):
        print("新しい場所（%s）には、すでにデータがあります。混ぜないように、引っ越さずに止めます。" % short(DATA))
        print("どちらを使うか決めて、使わないほうを別の場所へ移してから、もう一度動かしてください（前のデータはそのまま）。")
        return 5
    # 写しかけは新しい場所の隣に作る（最後の切り替えが、同じディスクの中での名前の付け替えで済むように）
    tmp = os.path.join(os.path.dirname(DATA), "." + os.path.basename(DATA) + "（引っ越し中）")
    try:
        if os.path.lexists(tmp):
            shutil.rmtree(tmp)   # 前に失敗したときの写しかけ（前のデータではない）
        os.makedirs(tmp)
        for p, rel in pairs:
            d = os.path.join(tmp, rel)
            os.makedirs(os.path.dirname(d), exist_ok=True)
            shutil.copy2(p, d)
        # 確かめる: ファイルの数・大きさ・中身（sha256）が、前のデータと1つずつ同じか
        copied = sum(len(fns) for _, _, fns in os.walk(tmp))
        bad = [rel for p, rel in pairs
               if os.path.getsize(p) != os.path.getsize(os.path.join(tmp, rel)) or file_sha(p) != file_sha(os.path.join(tmp, rel))]
        if copied != len(pairs) or bad:
            raise OSError("写したものが前のデータと合いません（数 %d / %d・違うもの %d）" % (copied, len(pairs), len(bad)))
        write_json(os.path.join(tmp, MIGRATE_NOTE), {"from": src, "kinds": kinds, "files": len(pairs), "bytes": total,
                                                      "at": now_iso()})
        if os.path.isdir(DATA):   # 空のフォルダ（.DS_Store だけ）なら片付けてから切り替える
            if os.path.exists(os.path.join(DATA, ".DS_Store")):
                os.remove(os.path.join(DATA, ".DS_Store"))
            os.rmdir(DATA)
        os.makedirs(os.path.dirname(DATA), exist_ok=True)
        os.rename(tmp, DATA)
    except OSError as e:
        shutil.rmtree(tmp, ignore_errors=True)
        print("引っ越しの途中でうまくいかなかったので、やめました（前のデータはそのまま）: %s" % e)
        print("原因を直してから、もう一度動かしてください（初めからやり直します）。")
        return 1
    return finish_migrate(src, kinds, len(pairs), total)


def finish_migrate(src, kinds, files, total):
    """切り替えのあと: 前のデータに「データ（引っ越し済み 日付）」と名前を付けて残す（同じフォルダの中での名前の付け替え）"""
    stamp = time.strftime("%Y-%m-%d")
    moved = os.path.join(src, "%s %s）" % (MOVED_PREFIX, stamp))
    i = 2
    while os.path.lexists(moved):
        moved = os.path.join(src, "%s %s-%d）" % (MOVED_PREFIX, stamp, i))
        i += 1
    if kinds == ["データ"]:
        os.rename(os.path.join(src, "データ"), moved)
    else:
        os.makedirs(moved)
        for n in ("データ",) + OLD_TOP + (".取得中",):
            if (n != "データ" or "データ" in kinds) and os.path.lexists(os.path.join(src, n)):
                os.rename(os.path.join(src, n), os.path.join(moved, n))
    print("引っ越しました: %d ファイル（%.1f MB）を写して、1つずつ同じことを確かめました。" % (files, total / 1e6))
    print("新しい場所: %s" % short(DATA))
    print("前のデータは %s に残してあります。新しい場所で取得できたのを確かめてから消してください"
          "（アプリの設定の「ゴミ箱に入れる」か、Finder で）。" % short(moved))
    return 0


# ---- チャンネル探し（アプリの「はじめの準備」から。チャンネル探し.sh が呼ぶ） ----
#
# チャンネルの名前・説明は、AI が読んで一覧（JSON）にまとめる（Slack のチャンネル検索が返す形は決まっていないため）。
# AI が書き写した ID と名前は、Slack が返したそのままの結果（作業記録）にあるものだけを使う。投稿の中身は読ませない

CHANNEL_TOOL = "slack_search_channels"
CANDIDATES_PATH = os.path.join(DATA, "チャンネル候補.json")   # アプリが読む（取得の仕組みのフォルダの外の Slack取得データ/ の中）
CHANNEL_ID_RE = re.compile(r"^[CG][A-Z0-9]{6,20}$")
NO_TOOL_RE = re.compile(r"No such tool", re.I)
MONTH_NAMES = "jan feb mar apr may jun jul aug sep oct nov dec".split()
NEAR_CHARS = 600   # 名前は、その ID からこの文字数のうちに出ていること（ほかのチャンネルの名前との取り違えを防ぐ）


def dates_in(text):
    """文の中の日付らしいもの（2025-01-15・2025/1/15・2025年1月15日・Jan 15, 2025・Unix 時刻）を、日付の集まりで返す"""
    import datetime
    out = set()

    def add(y, m, d):
        try:
            out.add(datetime.date(int(y), int(m), int(d)))
        except ValueError:
            pass
    for y, m, d in re.findall(r"(\d{4})[-/.年](\d{1,2})[-/.月](\d{1,2})", text):
        add(y, m, d)
    for mon, d, y in re.findall(r"\b([A-Za-z]{3})[a-z]*\.? (\d{1,2}),? (\d{4})", text):
        if mon.lower() in MONTH_NAMES:
            add(y, MONTH_NAMES.index(mon.lower()) + 1, d)
    for t in re.findall(r"\b(1\d{9})(?:\.\d+)?\b", text):
        for off in (0, JST_OFFSET):
            out.add(datetime.datetime.fromtimestamp(int(t) + off, datetime.timezone.utc).date())
    return out


def parse_answer(text):
    """AI の答えから、JSON のかたまりを1つ取り出す（読めなければ None）"""
    t = (text or "").strip()
    i, j = t.find("{"), t.rfind("}")
    if i < 0 or j < i:
        return None
    try:
        v = json.loads(t[i:j + 1])
    except ValueError:
        return None
    return v if isinstance(v, dict) else None


def name_is_near(raw, cid, name):
    """チャンネルの名前が、その ID の近く（NEAR_CHARS 文字のうち）に、名前の一部ではない形で出ているか"""
    low = raw.lower()
    ids = [m.start() for m in re.finditer(r"(?<![A-Z0-9])%s(?![A-Z0-9])" % re.escape(cid), raw)]
    names = [m.start() for m in re.finditer(r"(?<![\w\-])%s(?![\w\-])" % re.escape(name.lower()), low)]
    return any(abs(i - n) <= NEAR_CHARS for i in ids for n in names)


def cmd_channels(args):
    """チャンネル探し.sh から呼ぶ。AI がまとめたチャンネルの一覧を、Slack が返したそのままの結果と照らして、
    合うものだけを チャンネル候補.json に足す（アプリが読む）。
      channels <作業記録.jsonl> --answer <claude の出力.json> [--mode check|search] [--query 言葉]
      channels --fail <理由> [--mode ...] [--query ...]       動かせなかったことを書く
    """
    import datetime
    st = read_json(CANDIDATES_PATH, {})
    chans = {c["id"]: c for c in st.get("channels", []) if c.get("id")}
    last = {"mode": opt(args, "--mode", "search"), "query": opt(args, "--query", ""), "at": now_iso(), "ok": False,
            "connected": False, "found": 0, "dropped": 0, "more": False, "error": opt(args, "--fail")}
    log = args[0] if args and not args[0].startswith("--") else ""
    if last["error"] is None:
        calls = list(find_calls(log, (CHANNEL_TOOL,))) if os.path.exists(log) else []
        good = [c for c in calls if not c["is_error"]]
        answer = parse_answer((read_json(opt(args, "--answer", ""), {}) or {}).get("result", ""))
        if not good:
            first = (calls[0]["response_text"].strip().splitlines() or [""])[0][:200] if calls else ""
            if not calls or NO_TOOL_RE.search(first):
                last["error"] = ("Slack の連携が見つからなかった。claude.ai のコネクタで Slack が「Connected（接続済み）」に"
                                 "なっているかを確かめる（つないだ直後は、反映まで数分かかることがある）")
            else:
                last["error"] = ("Slack から失敗が返った（%s）。claude.ai のコネクタで Slack を開き、"
                                 "「Reconnect（再接続）」が出ていれば押す" % first)
        else:
            last["connected"] = True
            st["connected_at"] = last["at"]
            # 日本語の名前は \uXXXX の形で返るので、ほどいてから照らす（ほどかないと、日本語の名前のチャンネルがすべて外れる）
            raw = "\n".join(plain_text(c["response_text"]) for c in good)
            days = dates_in(raw)
            items = [x for x in (answer or {}).get("channels") or [] if isinstance(x, dict)]
            # 同じ ID に違う名前（またはその逆）が付いていたら、どちらが正しいか分からないので両方外す
            pairs = [(str(x.get("id") or "").strip(), str(x.get("name") or "").strip().lstrip("#")) for x in items]
            uses = collections.Counter(k for pair in set(pairs) for k in pair)
            twice = {k for k, v in uses.items() if v > 1}
            found = set()
            for item, (cid, name) in zip(items, pairs):
                # 照合: AI が書き写した ID と名前が、Slack の返した結果にそのまま、近くに並んで出ているか
                if (not CHANNEL_ID_RE.match(cid) or not name or cid in twice or name in twice
                        or not name_is_near(raw, cid, name)):
                    last["dropped"] += 1
                    continue
                # できた日も、結果のどこかにその日付（時間帯の違いの分、前後1日まで）が出ているときだけ使う
                try:
                    created = datetime.date.fromisoformat(str(item.get("created") or ""))
                    created = created.isoformat() if any(abs((created - d).days) <= 1 for d in days) else None
                except ValueError:
                    created = None
                c = chans.setdefault(cid, {"id": cid})
                c["name"] = name
                for k in ("private", "archived"):
                    if isinstance(item.get(k), bool):
                        c[k] = item[k]
                if isinstance(item.get("members"), int) and not isinstance(item.get("members"), bool):
                    c["members"] = item["members"]
                if isinstance(item.get("purpose"), str) and item["purpose"].strip():
                    c["purpose"] = item["purpose"].strip()[:80]
                if created:
                    c["created"] = created
                c["seen"] = last["at"]
                found.add(cid)
            last["found"] = len(found)
            last["more"] = any(next_cursor_of(c) for c in good)
            last["ok"] = answer is not None
            if answer is None:
                last["error"] = "つながったが、AI の答えが読めなかった。もう一度探す"
    st.update(updated=last["at"], last=last,
              channels=sorted(chans.values(), key=lambda c: c.get("name") or c["id"]))
    write_json(CANDIDATES_PATH, st)
    if last["connected"]:
        print("つながっています。見つけた %d 件（照らして合わず外した %d 件）%s"
              % (last["found"], last["dropped"], "・ほかにもあり" if last["more"] else ""))
    else:
        print("つながっていません: %s" % last["error"])
    return 0 if last["connected"] else 1


# ---- できた日の推定（Slack がチャンネルの作成日を返さないとき） ----
#
# Slack の検索で「その期間に投稿が1件でもあるか」を年ごとに、続けて見つかった年の月ごとに確かめ、
# いちばん古い投稿のある月の1日の、さらに1週間前を「できた日」とする（検索の並べ替えの向きには頼らない）。
# 投稿の中身は、取得係と同じく結果をファイルに置かせて AI には見せない。ここでは「あるか・ないか」だけを読む

OLDEST_FIRST_YEAR = 2014   # Slack が一般に公開された年。これより前は1つの区切りにまとめる
OLDEST_MARGIN_DAYS = 7
OLDEST_FILTER_RE = re.compile(r"^in:<#(\w+)>(?: after:(\d{4}-\d\d-\d\d))? before:(\d{4}-\d\d-\d\d)$")


def oldest_spans(year=None):
    """確かめる区切り [(呼び名, after, before)]。year が無ければ年ごと、あればその年の月ごと（after・before の日は含まない）"""
    import datetime
    today = datetime.date.today()
    day = datetime.timedelta(days=1)
    if year is None:
        out = [("~%d" % (OLDEST_FIRST_YEAR - 1), None, "%d-01-01" % OLDEST_FIRST_YEAR)]
        for y in range(OLDEST_FIRST_YEAR, today.year + 1):
            out.append((str(y), (datetime.date(y, 1, 1) - day).isoformat(), "%d-01-01" % (y + 1)))
        return out
    out = []
    for m in range(1, 13):
        first = datetime.date(year, m, 1)
        if first > today:
            break
        nxt = datetime.date(year + 1, 1, 1) if m == 12 else datetime.date(year, m + 1, 1)
        out.append(("%d-%02d" % (year, m), (first - day).isoformat(), nxt.isoformat()))
    return out


def oldest_next(seen):
    """分かったこと（区切りの呼び名 → 投稿があったか）から、(次に確かめる区切り, できた日, 根拠, 推定できない理由) を返す"""
    import datetime
    margin = datetime.timedelta(days=OLDEST_MARGIN_DAYS)
    years = oldest_spans()
    todo = [s for s in years if s[0] not in seen]
    if todo:
        return todo, None, None, None
    hit = [s[0] for s in years if seen[s[0]]]
    if not hit:
        return [], None, None, "検索で投稿が1件も見つからなかった"
    if hit[0].startswith("~"):
        return [], (datetime.date(OLDEST_FIRST_YEAR - 1, 1, 1) - margin).isoformat(), hit[0], None
    months = oldest_spans(int(hit[0]))
    todo = [s for s in months if s[0] not in seen]
    if todo:
        return todo, None, None, None
    hitm = [s[0] for s in months if seen[s[0]]]
    basis = hitm[0] if hitm else hit[0] + "-01"   # 年では見つかったのに月で見つからなければ、その年の初めから
    return [], (datetime.date.fromisoformat(basis + "-01") - margin).isoformat(), basis, None


def cmd_oldest(args):
    """できた日の推定（チャンネル探し.sh --oldest から）。
      oldest plan <チャンネルID ...>                 次に確かめる検索の一覧（1行1件の JSON）。もう無ければ何も出さない
      oldest read <作業記録.jsonl ...>               結果（その区切りに投稿があったか）を チャンネル候補.json に書く
      oldest done <チャンネルID ...> [--fail 理由]   推定の結果をまとめる（アプリが読む）
    """
    import datetime
    sub, rest = (args[0] if args else ""), args[1:]
    st = read_json(CANDIDATES_PATH, {})
    chans = {c["id"]: c for c in st.get("channels", []) if c.get("id")}
    ids = [a for a in rest if CHANNEL_ID_RE.match(a)]
    if sub == "plan":
        for cid in ids:
            seen = ((chans.get(cid) or {}).get("oldest") or {}).get("seen") or {}
            for _name, after, before in oldest_next(seen)[0]:
                f = "in:<#%s>%s before:%s" % (cid, " after:" + after if after else "", before)
                print(json.dumps({"tool": SEARCH_TOOL, "args": {
                    "filters": f, "natural_language_query": "", "limit": 1, "include_context": False,
                    "include_bots": True, "response_format": "detailed", "sort": "timestamp"}}, ensure_ascii=False))
        return 0
    if sub == "read":
        spans = oldest_spans() + [s for y in range(OLDEST_FIRST_YEAR, datetime.date.today().year + 1)
                                  for s in oldest_spans(y)]
        names = {(a, b): n for n, a, b in spans}
        n = seen_by_ai = 0
        for path in rest:
            for call in find_calls(path, (SEARCH_TOOL,)):
                seen_by_ai += visible_to_ai(call)
                m = OLDEST_FILTER_RE.match(call["input"].get("filters") or "")
                if not m or call["is_error"] or (m.group(2), m.group(3)) not in names:
                    continue
                try:
                    body = json.loads(call["response_text"]).get("results", "")
                except (ValueError, AttributeError):
                    continue   # 形の崩れた結果は「分からない」のまま（次の周で取り直す）
                c = chans.setdefault(m.group(1), {"id": m.group(1), "name": m.group(1)})
                seen = c.setdefault("oldest", {}).setdefault("seen", {})
                seen[names[(m.group(2), m.group(3))]] = bool(SEARCH_MSG_RE.search(body or ""))
                n += 1
        st["channels"] = sorted(chans.values(), key=lambda c: c.get("name") or c["id"])
        write_json(CANDIDATES_PATH, st)
        print("確かめた区切り %d / 投稿が見えた結果 %d 件" % (n, seen_by_ai))   # チャンネル探し.sh が読む
        return 0
    if sub == "done":
        fail = opt(rest, "--fail")
        for cid in ids:
            c = chans.setdefault(cid, {"id": cid, "name": cid})
            info = c.setdefault("oldest", {})
            _todo, frm, basis, why = oldest_next(info.get("seen") or {})
            info.update({"at": now_iso(), "from": frm, "basis": basis,
                         "error": None if frm else (fail or why or "確かめきれなかった（もう一度押すと続きから確かめる）")})
            print("%s: %s" % (c.get("name") or cid, ("%s から（いちばん古い投稿 %s）" % (frm, basis)) if frm else info["error"]))
        st.update(updated=now_iso(), channels=sorted(chans.values(), key=lambda c: c.get("name") or c["id"]))
        write_json(CANDIDATES_PATH, st)
        return 0
    print(cmd_oldest.__doc__)
    return 2


def main(argv):
    cmds = {"extract": cmd_extract, "usage": cmd_usage, "build": cmd_build, "check": cmd_check,
            "plan": cmd_plan, "status": cmd_status, "migrate": cmd_migrate, "where": cmd_where, "guard": cmd_guard,
            "set-aside": cmd_set_aside,
            "channels": cmd_channels, "oldest": cmd_oldest}
    if len(argv) < 2 or argv[1] not in cmds:
        print(__doc__)
        return 2
    # 前の場所にデータが残っているうちは、新しい場所に書かない（先に書くと、引っ越し先が空でなくなって引っ越せない）
    if argv[1] not in ("migrate", "where", "usage") and old_data_kinds(HERE):
        print(OLD_DATA_MESSAGE % (short(HERE), short(DATA)))
        return 4
    return cmds[argv[1]](argv[2:])


if __name__ == "__main__":
    sys.exit(main(sys.argv))
