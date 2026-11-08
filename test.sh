#!/bin/bash
# CLT 不带 XCTest，改用 CLT 自带的 Swift Testing 框架跑测试。
# 用法：./test.sh [--filter 测试名]
FW="$(xcode-select -p)/Library/Developer/Frameworks"
# CLT 26+ 的 Testing.framework 依赖 @rpath/lib_TestingInterop.dylib，它放在 usr/lib 下。
LIB="$(xcode-select -p)/Library/Developer/usr/lib"
# -disable-cross-import-overlays：CLT 的 _Testing_Foundation.framework 缺 Modules 目录，
# Foundation+Testing 同时导入时会因找不到该 overlay 而编译失败。
exec swift test --disable-xctest \
    -Xswiftc -F"$FW" \
    -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
    -Xlinker -F"$FW" \
    -Xlinker -rpath -Xlinker "$FW" \
    -Xlinker -rpath -Xlinker "$LIB" \
    "$@"
