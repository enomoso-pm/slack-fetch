#!/bin/bash
# Slack 取得（メニューバーのアプリ）を組み立てる。できたものは build/Slack取得.app
# 組み立てたときの「取得の仕組みのフォルダ」（このフォルダの1つ上）をアプリに書き込む。あとから設定で変えられる
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BASE="$(cd "$HERE/.." && pwd)"
APP="$HERE/build/Slack取得.app"
# claude.ai のリンク（はじめの準備の窓で使う）。リンクは変わることがあるので、初期セットアップのときに
# Claude が調べ直して リンク.json に書く（CLAUDE.md）。ここでは、そのままアプリに入れる。
# 読めないときは、今のアプリを消す前に止める
/usr/bin/python3 -c 'import json, sys; json.load(open(sys.argv[1]))' "$HERE/リンク.json" \
  || { echo "アプリ/リンク.json が読めません（JSON の形を確かめてください）"; exit 1; }
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# ZIP で取ってきたファイルには隔離の印（com.apple.quarantine）が付いている。アプリの中に持ち込むと、
# 開くときに Mac に止められることがある。cp は -X を付けても印まで写す（macOS 26 で確認）ので、中身だけを書き写す
cat "$HERE/Info.plist" > "$APP/Contents/Info.plist"
plutil -insert SlackFetchBaseDir -string "$BASE" "$APP/Contents/Info.plist"
cat "$HERE/リンク.json" > "$APP/Contents/Resources/links.json"
xcrun swiftc -parse-as-library -swift-version 5 -O \
  -target "$(uname -m)-apple-macos14.0" -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
  -o "$APP/Contents/MacOS/SlackFetch" "$HERE"/Sources/*.swift

# アイコン: アプリ自身に 1024×1024 で描かせて、いろいろな大きさに縮めてから、アイコンのファイルにまとめる
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
BIG="$ICONSET/icon_512x512@2x.png"
if "$APP/Contents/MacOS/SlackFetch" --icon "$BIG" >/dev/null 2>&1 && [ -s "$BIG" ]; then
  for s in 16 32 128 256 512; do
    sips -z "$s" "$s" "$BIG" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    if [ "$s" -lt 512 ]; then
      sips -z $((s * 2)) $((s * 2)) "$BIG" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
    fi
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" \
    || echo "（アイコンは作れませんでした。アプリはそのまま使えます）"
else
  echo "（アイコンは作れませんでした。アプリはそのまま使えます）"
fi
rm -rf "$(dirname "$ICONSET")"

codesign --force --sign - "$APP"
echo "できました: $APP"
