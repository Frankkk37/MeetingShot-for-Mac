#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
"$ROOT/install.sh"
echo
echo "安装与启动已完成。按回车关闭终端窗口。"
read -r
