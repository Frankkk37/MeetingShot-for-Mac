#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
TARGET="$HOME/Applications/MeetingShot.app"

"$ROOT/build_app.sh"
mkdir -p "$HOME/Applications"

# 先退出旧版本，避免替换后仍运行旧进程。
osascript -e 'tell application "MeetingShot" to quit' >/dev/null 2>&1 || true
sleep 1
rm -rf "$TARGET"
cp -R "$ROOT/dist/MeetingShot.app" "$TARGET"

xattr -dr com.apple.quarantine "$TARGET" >/dev/null 2>&1 || true
open "$TARGET"

echo
echo "安装成功：$TARGET"
echo "当前版本：v0.3 方案二 MVP（画面变化监测 + 30 秒兜底）"
