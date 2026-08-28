#!/bin/bash
set -euo pipefail
APP="$HOME/Applications/MeetingShot.app"
if [[ ! -d "$APP" ]]; then
    echo "未找到 $APP，请先运行“安装并打开MeetingShot.command”。"
    read -r
    exit 1
fi
open "$APP"
