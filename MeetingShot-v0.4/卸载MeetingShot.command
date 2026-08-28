#!/bin/bash
set -euo pipefail
osascript -e 'tell application "MeetingShot" to quit' >/dev/null 2>&1 || true
rm -rf "$HOME/Applications/MeetingShot.app"
echo "已删除：$HOME/Applications/MeetingShot.app"
echo "截图文件不会被删除。按回车关闭。"
read -r
