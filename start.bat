@echo off
chcp 65001 >nul
title TrafficAgent 启动器

echo ============================================
echo    TrafficAgent - 交通标志智能检测平台
echo ============================================
echo.

:: 获取脚本所在目录作为项目根目录
cd /d "%~dp0"

echo [1/4] 检查 Python 环境...
if not exist "backend\.venv\Scripts\python.exe" (
    echo [错误] 未找到 backend\.venv\Scripts\python.exe
    echo        请先运行 bootstrap-windows.ps1 引导脚本
    pause
    exit /b 1
)
echo         虚拟环境已就绪

echo [2/4] 检查 Node.js 环境...
if not exist ".runtime\node\node.exe" (
    echo [错误] 未找到 .runtime\node\node.exe
    echo        请先运行 bootstrap-windows.ps1 引导脚本
    pause
    exit /b 1
)
echo         Node.js 已就绪

echo [3/4] 启动后端服务 (FastAPI :8000)...
start "TrafficAgent-Backend" cmd /k "cd /d "%~dp0backend" && ".\.venv\Scripts\python.exe" -m uvicorn main:app --host 127.0.0.1 --port 8000 --reload"

echo [4/4] 启动前端服务 (Vite :5173)...
start "TrafficAgent-Frontend" cmd /k "cd /d "%~dp0frontend" && "..\.runtime\node\npm.cmd" run dev -- --host 127.0.0.1"

echo.
echo ============================================
echo    启动完成! 等待服务就绪...
echo.
echo    前端: http://127.0.0.1:5173
echo    API文档: http://127.0.0.1:8000/docs
echo    健康检查: http://127.0.0.1:8000/api/health
echo ============================================
echo.
echo 按任意键关闭此窗口 (不会停止服务)
pause >nul
