#!/bin/zsh
# 端到端测试（会影响屏幕约 1 分钟，结束自动还原）。需先退出其他虚拟显示器工具，避免同一虚拟屏标识冲突。
set -e
cd "${0:A:h}"
mkdir -p build
swiftc -O -swift-version 5 -import-objc-header Sources/Private.h \
  -framework AppKit -framework CoreGraphics -framework IOKit \
  Sources/Config.swift Sources/VirtualScreen.swift Sources/DDC.swift Tests/main.swift -o build/vdtest
build/vdtest
