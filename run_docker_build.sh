#!/bin/bash
set -e

# Windows/WSL 用户: 请在 WSL 终端中运行此脚本
# 确保已安装 Docker Desktop 并开启 WSL 集成

IMAGE_NAME="kindlebt-builder"

echo "1. 构建 Docker 镜像..."
docker build -t $IMAGE_NAME .

echo "2. 运行构建容器..."
# 挂载当前目录到 /workspace
docker run --rm -v "$(pwd):/workspace" $IMAGE_NAME bash build_in_docker.sh

echo "完成！检查 libkindlebt_adapter.so"
