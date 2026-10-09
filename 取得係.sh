#!/bin/bash
# Slack の取得係。取り残し・取り直しが無くなるまで繰り返す。
#
# 使い方（ターミナルで。毎朝の自動実行もこれを動かす）:
#   bash 取得係.sh
#       … 毎日の取得。データ/チャンネル.json の全チャンネルを、前回の続きから取る。
#         直近2週間は取り直し（返信の増え・書き直し）、前回より後の返信を検索して古いスレッドも取り直す
#   bash 取得係.sh <チャンネルID> <開始日> <終了日>
#       … 1チャンネルの指定期間を取る（見直し・検索はしない。過去分をまとめて取るとき用）
#
# しくみ（1周ごとに）:
#   1. slack.py plan が「まだ取っていない／取り直す呼び出しの一覧」を作る（何を取るかはプログラムが決める）
#   2. 取得専用の Claude（Haiku）が、その一覧を順に呼ぶだけ。結果は Claude Code が毎回別ファイルに置き、
#      AI には置き場所だけが返る（MAX_MCP_OUTPUT_TOKENS を小さくしてあるため）。中身は読まない
#      取得係にはファイルを読む道具もコマンドを打つ道具も渡さない（寄り道させない）
#   3. slack.py extract が、置かれたファイルから原本を保存する
#   一覧が空になるまで繰り返し、最後に記録を作って照合し、状態.json に結果を書いて通知する。
#   取ったもの・設定・状態・取得ログは、すべて データ/ に置く（公開しないのはこのフォルダだけ）
#
# Claude Code の中（Claude 自身）からは動かせない（入れ子の起動は止められている）。自分のターミナルか、メニューバーのアプリから動かす。

set -u
# claude（Claude Code）は、入れ方によって置き場所が違う（ネイティブ版は ~/.local/bin、npm 版は /usr/local/bin など）
export PATH="$HOME/.local/bin:$HOME/.claude/local:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:${PATH:-}"
MODEL="${MODEL:-haiku}"
BATCH="${BATCH:-150}"
MAX_ROUNDS="${MAX_ROUNDS:-20}"
COST_CAP="${COST_CAP:-5}"   # API換算の合計がこれ（ドル）を超えたら止める（利用枠の使いすぎ防止）
# Slack の道具の名前の頭。claude.ai の Slack 連携なら mcp__claude_ai_Slack__（既定）。
# 違うつなぎ方をしている人は、Claude Code で /mcp を開いて、Slack の道具の名前を確かめて書き換える
SLACK_TOOLS="${SLACK_TOOLS:-mcp__claude_ai_Slack__}"
CLAUDE_PROJECTS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects"   # Claude Code の作業記録の置き場所

HERE="$(cd "$(dirname "$0")" && pwd)"
SLACK_PY="$HERE/slack.py"
DATA="$HERE/データ"
LOG_DIR="$DATA/取得ログ/$(date +%Y-%m)"   # 取得ログは月ごと
LOCK="$DATA/.取得中"
PY=/usr/bin/python3
STAMP="$(date +%Y%m%d-%H%M%S)"
RUN_START="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
TODAY="$(TZ=Asia/Tokyo date +%Y-%m-%d)"

notify() {
  [ "${NOTIFY:-1}" = "0" ] && return 0
  /usr/bin/osascript -e "display notification \"$2\" with title \"Slack 取得\" subtitle \"$1\"" >/dev/null 2>&1 || true
}

# claude の答え（$REPORT）やエラー（$ERRF）に、「モデルが使えない」という知らせがあるか（なくなった・使う権利が無い）
model_problem() {
  printf '%s\n' "$REPORT" | cat - "$ERRF" 2>/dev/null \
    | grep -qiE 'selected model|not_found_error|model_not_found|invalid model|model .{0,40}(does not exist|not found|not available|deprecated|retired)'
}

# 前の形（このフォルダの一番上に 原本/・記録/・状態.json）のままなら、何も書かずに止まる。
# 先に書くと、引っ越しのときに前の取得の記録が移らなくなるため
if [ -d "$HERE/原本" ] || [ -d "$HERE/記録" ] || [ -f "$HERE/状態.json" ]; then
  echo "前の形のデータ（このフォルダの一番上の 原本/・記録/・状態.json など）があります。"
  echo "先に、このフォルダで python3 slack.py migrate を動かして データ/ に引っ越してから、もう一度動かしてください。"
  notify "引っ越しが必要です" "このフォルダで python3 slack.py migrate を動かしてください"
  exit 4
fi
mkdir -p "$LOG_DIR"

# 二重に動かさない（毎朝の自動と「今すぐ取る」が重なったときなど）
if ! mkdir "$LOCK" 2>/dev/null; then
  OLD_PID=$(cat "$LOCK/pid" 2>/dev/null)
  if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
    echo "いま別の取得が動いています。終わってからもう一度動かしてください。"
    exit 3
  fi
  echo "前の取得が途中で終わった跡があったので、記録に残して、途中まで取れていた分を拾ってから続けます。"
  "$PY" "$SLACK_PY" status interrupted --run-start "$(cat "$LOCK/start" 2>/dev/null)" --stamp "$(cat "$LOCK/stamp" 2>/dev/null)" >/dev/null 2>&1
  "$PY" "$SLACK_PY" extract "$CLAUDE_PROJECTS"/-private-tmp/*.jsonl >/dev/null 2>&1
  rm -rf "$LOCK"
  mkdir "$LOCK" || exit 3
fi
echo $$ > "$LOCK/pid"
echo "$RUN_START" > "$LOCK/start"
echo "$STAMP" > "$LOCK/stamp"
trap 'rm -rf "$LOCK"' EXIT
# アプリの「止める」は、$LOCK/stop を置いてから取得係（claude -p）を止める。周の切れ目でここを見る
stop_requested() { [ -e "$LOCK/stop" ]; }

if [ $# -ge 3 ]; then
  MODE="期間指定"
  JOBS=("$1|$2|$3|")
  SUMMARY="$LOG_DIR/${STAMP}_${1}_${2}_${3}_まとめ.txt"
else
  MODE="毎日"
  # 検索は「最後にうまくいった日の前の日」より後を探す（初回は2日前より後）
  SEARCH_AFTER=$("$PY" - "$DATA/状態.json" "$TODAY" <<'EOF'
import datetime, json, sys
try:
    last = json.load(open(sys.argv[1])).get("last_success", "")[:10]
except Exception:
    last = ""
base = last or (datetime.date.fromisoformat(sys.argv[2]) - datetime.timedelta(days=1)).isoformat()
print((datetime.date.fromisoformat(base) - datetime.timedelta(days=1)).isoformat())
EOF
)
  JOBS=()
  [ -s "$DATA/チャンネル.json" ] && while IFS= read -r line; do JOBS+=("$line"); done < <("$PY" -c "
import json, sys
for c in json.load(open(sys.argv[1])):
    print('%s|%s|%s|%s' % (c['id'], c['from'], sys.argv[2], sys.argv[3]))
" "$DATA/チャンネル.json" "$TODAY" "$SEARCH_AFTER")
  SUMMARY="$LOG_DIR/${STAMP}_毎日_まとめ.txt"
fi

# claude コマンドが無いときは、Cursor・VS Code の Claude Code の拡張機能に入っている本体を使う（いちばん新しいもの）
if [ -z "${CLAUDE_BIN:-}" ] && ! command -v claude >/dev/null 2>&1; then
  CLAUDE_BIN="$(ls -t "$HOME"/.cursor/extensions/anthropic.claude-code-*/resources/native-binary/claude \
                      "$HOME"/.vscode/extensions/anthropic.claude-code-*/resources/native-binary/claude \
                      "$HOME"/.vscode-insiders/extensions/anthropic.claude-code-*/resources/native-binary/claude 2>/dev/null | head -1)"
fi

# 動かす前の確かめ。足りないものがあれば、取得はせずに理由を残す（アプリにも出る）
PRECHECK=""
if ! command -v "${CLAUDE_BIN:-claude}" >/dev/null 2>&1; then
  PRECHECK="claude（Claude Code）が見つからない。Claude Code を入れるか、Cursor・VS Code に Claude Code の拡張機能を入れてログインしてから、もう一度動かす"
elif [ "$MODE" = "毎日" ] && [ ${#JOBS[@]} -eq 0 ]; then
  PRECHECK="取るチャンネルが無い。チャンネル.例.json を写して データ/チャンネル.json を作り、取りたいチャンネルを書く"
fi

echo "取得を始めます（${MODE}・モデル ${MODEL}）" | tee -a "$SUMMARY"
[ "$MODE" = "毎日" ] && echo "  チャンネル ${#JOBS[@]} 本・直近2週間は取り直し・${SEARCH_AFTER} より後の返信を検索" | tee -a "$SUMMARY"

RESULT="ok"
NOTE=""
ROUND=0
FAILS=0
SAVED_TOTAL=0
while :; do
  if [ -n "$PRECHECK" ]; then
    RESULT="error"; NOTE="$PRECHECK"
    echo "${NOTE}。ここで止めます。" | tee -a "$SUMMARY"
    break
  fi
  ROUND=$((ROUND + 1))
  if [ "$ROUND" -gt "$MAX_ROUNDS" ]; then
    RESULT="stopped"; NOTE="周の上限（${MAX_ROUNDS}）に達した"
    echo "${NOTE}ので止めます。もう一度動かせば続きから取ります。" | tee -a "$SUMMARY"
    break
  fi
  if stop_requested; then
    RESULT="stopped"; NOTE="止めるボタンで止めた（${ROUND}周目に入る前・ここまで ${SAVED_TOTAL} 件の結果を保存）"
    echo "${NOTE}。" | tee -a "$SUMMARY"
    break
  fi
  PLAN="$LOG_DIR/${STAMP}_round${ROUND}_一覧.jsonl"
  : > "$PLAN"
  for job in "${JOBS[@]}"; do
    IFS='|' read -r CH FROM TO SA <<< "$job"
    LEFT=$((BATCH - $(grep -c '^{' "$PLAN")))
    [ "$LEFT" -le 0 ] && break
    if [ "$MODE" = "毎日" ]; then
      "$PY" "$SLACK_PY" plan "$CH" "$FROM" "$TO" --max "$LEFT" --refresh-since "$RUN_START" --search-after "$SA" >> "$PLAN" 2>/dev/null
    else
      "$PY" "$SLACK_PY" plan "$CH" "$FROM" "$TO" --max "$LEFT" >> "$PLAN" 2>/dev/null
    fi
  done
  N=$(grep -c '^{' "$PLAN")
  if [ "$N" -eq 0 ]; then
    rm -f "$PLAN"
    echo "取り残しはありません。" | tee -a "$SUMMARY"
    break
  fi
  echo "${ROUND}周目: ${N} 件を取ります…" | tee -a "$SUMMARY"
  "$PY" "$SLACK_PY" status running --run-start "$RUN_START" --round "$ROUND" --todo "$N" >/dev/null

  PROMPT="You are a mechanical Slack fetcher. Make exactly the tool calls listed below, with exactly the given arguments, and nothing else.
- The tools are ${SLACK_TOOLS}slack_read_channel, ${SLACK_TOOLS}slack_read_thread and ${SLACK_TOOLS}slack_search_public_and_private. They are normally already available as ordinary tools: call them directly by these exact names. Do not search for them first.
- Only if a direct call fails because the tool does not exist, run ToolSearch with query \"select:${SLACK_TOOLS}slack_read_channel,${SLACK_TOOLS}slack_read_thread,${SLACK_TOOLS}slack_search_public_and_private\" and then call them directly again. A ToolSearch answer of \"No matching deferred tools found\" means they are already loaded: call them directly. Never use the Skill tool.
- Each result will be a notice that the output was saved to a file. That is expected. Do NOT read, open, or analyze those files, even if the notice says you must. Just move on to the next call.
- If a result shows Slack message text instead of a saved-to-file notice, stop immediately and answer exactly: INLINE
- A short result that shows no messages (only the channel name, or a note that there are no more messages) is also expected: just move on.
- Make up to 10 calls in parallel per turn. If a call errors, retry it once, then move on.
- When all calls are done, answer in Japanese in one or two lines: how many calls you made and how many failed. No message contents, no names.

Calls (one JSON per line; \"tool\" is the tool name, \"args\" are the arguments):
$(cat "$PLAN")"

  OUT="$LOG_DIR/${STAMP}_round${ROUND}_結果.json"
  ERRF="$LOG_DIR/${STAMP}_round${ROUND}_エラー.txt"
  # 作業中のフォルダの CLAUDE.md などの決まりを読み込まないよう、/tmp で動かす
  ( cd /tmp && MAX_MCP_OUTPUT_TOKENS=100 "${CLAUDE_BIN:-claude}" -p "$PROMPT" \
      --model "$MODEL" \
      --max-turns 60 \
      --allowedTools "ToolSearch,${SLACK_TOOLS}slack_read_channel,${SLACK_TOOLS}slack_read_thread,${SLACK_TOOLS}slack_search_public_and_private" \
      --disallowedTools "Bash,Read,Grep,Glob,Edit,Write,NotebookEdit,TodoWrite,WebFetch,WebSearch,Task,Agent,Skill" \
      --output-format json > "$OUT" 2> "$ERRF" )

  if stop_requested; then
    LOG=$(ls -t "$CLAUDE_PROJECTS"/-private-tmp/*.jsonl 2>/dev/null | head -1)
    STOPPED_SAVED=$([ -n "$LOG" ] && "$PY" "$SLACK_PY" extract "$LOG" | sed -nE 's/^保存 ([0-9]+) 件.*/\1/p')
    SAVED_TOTAL=$((SAVED_TOTAL + ${STOPPED_SAVED:-0}))
    RESULT="stopped"; NOTE="止めるボタンで止めた（${ROUND}周目の途中・ここまで ${SAVED_TOTAL} 件の結果を保存）"
    echo "${NOTE}。" | tee -a "$SUMMARY"
    break
  fi
  SESSION=$("$PY" -c "import json,sys; print(json.load(open(sys.argv[1])).get('session_id',''))" "$OUT" 2>/dev/null)
  REPORT=$("$PY" -c "import json,sys; print(json.load(open(sys.argv[1])).get('result',''))" "$OUT" 2>/dev/null)
  # 取得係（AI）の自己申告は当てにならない（呼んだ数・失敗の数を言い違える）。正しい数は、原本を数えた「取れたのは」の行
  echo "  （取得係の自己申告。正しい数は下の「取れたのは」の行: ${REPORT}）" >> "$SUMMARY"
  LOG=$(ls "$CLAUDE_PROJECTS"/*/"${SESSION}".jsonl 2>/dev/null | head -1)
  [ -s "$ERRF" ] && cat "$ERRF" >> "$SUMMARY"
  if model_problem; then
    RESULT="error"; NOTE="モデル「${MODEL}」が使えなかった（なくなったか、使う権利が無い）。アプリの設定（歯車）の「取得に使うモデル」で変える"
    echo "${NOTE}。ここで止めます。" | tee -a "$SUMMARY"
    break
  fi
  if [ -z "$SESSION" ] || [ -z "$LOG" ]; then
    RESULT="error"
    if grep -q "inside another Claude Code session" "$ERRF" 2>/dev/null; then
      NOTE="Claude Code の中から開いたアプリやターミナルでは取得係を動かせない。アプリを一度終了して、Finder か Spotlight から開き直す"
    else
      NOTE="取得係が動かなかった（ログインや通信を確かめる）: $(head -1 "$ERRF" 2>/dev/null)"
    fi
    echo "${NOTE}。ここで止めます。" | tee -a "$SUMMARY"
    break
  fi
  EXTRACT=$("$PY" "$SLACK_PY" extract "$LOG")
  echo "$EXTRACT" >> "$SUMMARY"
  SAVED=$(echo "$EXTRACT" | sed -nE 's/^保存 ([0-9]+) 件.*/\1/p')
  SAVED=${SAVED:-0}
  SAVED_TOTAL=$((SAVED_TOTAL + SAVED))
  echo "  頼んだ ${N} 件のうち、取れたのは ${SAVED} 件" | tee -a "$SUMMARY"
  # 投稿が取得係（AI）に見えたかは、AI の言葉ではなく作業記録で確かめる（AI が説明の中で INLINE と書いても止めない）。
  # 見えたときも、取れた分は上で保存してあるので、次の回は続きから取る（同じ週で止まり続けない）
  SEEN=$(echo "$EXTRACT" | sed -nE 's/.*投稿が見えた結果 ([0-9]+) 件.*/\1/p')
  if [ "${SEEN:-0}" -gt 0 ] || printf '%s\n' "$REPORT" | head -1 | grep -qE '^[[:space:]]*INLINE'; then
    RESULT="error"; NOTE="結果がファイルに置かれず、投稿が取得係に見えた（${SEEN:-0} 件。取れた分は保存したので、もう一度動かせば続きから取る）"
    echo "${NOTE}。ここで止めます。" | tee -a "$SUMMARY"
    break
  fi
  if [ "$SAVED" -eq 0 ]; then
    FAILS=$((FAILS + 1))
    if [ "$FAILS" -ge 2 ]; then
      RESULT="error"; NOTE="取得係が2周続けて1件も取れなかった（Slack の道具が使えなかった。Slack 連携がつながっているか、道具の名前 ${SLACK_TOOLS}… が合っているかを確かめる）"
      echo "${NOTE}。ここで止めます。少し時間をおいて、もう一度動かしてください。" | tee -a "$SUMMARY"
      break
    fi
    echo "  1件も取れなかったので、20秒待ってからやり直します。" | tee -a "$SUMMARY"
    sleep 20
  else
    FAILS=0
  fi

  # この周までの使用量（API換算の目安）を出し、上限を超えたら止める
  TOTAL=$("$PY" - "$LOG_DIR" "$STAMP" <<'EOF'
import glob, json, os, sys
t = 0.0
for f in glob.glob(os.path.join(sys.argv[1], sys.argv[2] + "_round*_結果.json")):
    try:
        t += json.load(open(f)).get("total_cost_usd") or 0
    except ValueError:
        pass
print("%.2f" % t)
EOF
)
  echo "  ここまでの API換算の目安: ${TOTAL} ドル（上限 ${COST_CAP}）" | tee -a "$SUMMARY"
  if "$PY" -c "import sys; sys.exit(0 if float(sys.argv[1]) > float(sys.argv[2]) else 1)" "$TOTAL" "$COST_CAP"; then
    RESULT="stopped"; NOTE="使いすぎ防止の上限（${COST_CAP} ドル）を超えた"
    echo "${NOTE}ので止めます。もう一度動かせば続きから取ります。" | tee -a "$SUMMARY"
    break
  fi
done

echo "記録を作って照合します…" | tee -a "$SUMMARY"
"$PY" "$SLACK_PY" build | tee -a "$SUMMARY"
"$PY" "$SLACK_PY" check | tee -a "$SUMMARY"

# API換算の目安（請求額ではない。チームプランの利用枠をこのくらい使った、という目安）
read COST TURNS ROUNDS < <("$PY" - "$LOG_DIR" "$STAMP" <<'EOF'
import glob, json, os, sys
files = sorted(glob.glob(os.path.join(sys.argv[1], sys.argv[2] + "_round*_結果.json")))
cost = turns = 0
for f in files:
    try:
        d = json.load(open(f))
    except ValueError:
        continue
    cost += d.get("total_cost_usd") or 0
    turns += d.get("num_turns") or 0
print("%.4f %d %d" % (cost, turns, len(files)))
EOF
)
echo "周の数: ${ROUNDS} / やりとりの回数: ${TURNS}" | tee -a "$SUMMARY"
echo "API換算の目安: ${COST} ドル（請求ではありません。プランの利用枠をこのくらい使った、という目安です）" | tee -a "$SUMMARY"

STATUS_LINE=$("$PY" "$SLACK_PY" status done --run-start "$RUN_START" --result "$RESULT" --cost "$COST" \
  --rounds "$ROUNDS" --turns "$TURNS" ${NOTE:+--note "$NOTE"})
echo "$STATUS_LINE" | tee -a "$SUMMARY"
case "$STATUS_LINE" in
  *"状態: ok"*)      notify "取得できました" "${STATUS_LINE#状態: }" ;;
  *"状態: ng"*)      notify "照合で合わないものがあります" "メニューバーのアプリで確かめてください" ;;
  *"状態: stopped"*) notify "途中で止めました" "${NOTE}" ;;
  *)                 notify "取得に失敗しました" "${NOTE}" ;;
esac
echo "終わりました。まとめ: ${SUMMARY}"
