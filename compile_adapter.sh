#!/bin/bash
set -e

# 1. 查找交叉编译器
echo "正在查找交叉编译器..."
CC=""
if command -v arm-linux-gnueabi-gcc &> /dev/null; then
    CC="arm-linux-gnueabi-gcc"
elif command -v arm-none-linux-gnueabi-gcc &> /dev/null; then
    CC="arm-none-linux-gnueabi-gcc"
elif command -v arm-linux-gnu-gcc &> /dev/null; then
    CC="arm-linux-gnu-gcc"
else
    echo "错误：未找到 ARM 交叉编译器。"
    echo "请安装gcc-arm-linux-gnu (Debian/Ubuntu) 或 arm-none-linux-gnueabi-gcc (RHEL/Rocky)。"
    exit 1
fi
echo "使用编译器: $CC"

# 2. 设置路径
# 假设 kindlebt 源码在 ./kindlebt
# 假设 sysroot 或库文件在 ./libs (如果有)
# kindlebt 头文件在 ./kindlebt/include

INCLUDE_FLAGS="-I./kindlebt/include"
LIB_FLAGS="-L./libs -lkindlebt"

# 3. 编译
echo "正在编译 libkindlebt_adapter.so ..."
$CC -shared -fPIC -o libkindlebt_adapter.so adapter.c $INCLUDE_FLAGS $LIB_FLAGS

# 4. 检查结果
if [ -f "libkindlebt_adapter.so" ]; then
    echo "编译成功！"
    ls -lh libkindlebt_adapter.so
    file libkindlebt_adapter.so
else
    echo "编译失败。"
    exit 1
fi
