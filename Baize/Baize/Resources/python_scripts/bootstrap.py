#!/usr/bin/env python3
"""
Baize Python Bootstrap Script
白泽 Python 运行时 HTTP Server 启动脚本

在 CPython 嵌入模式下启动 HTTP server，监听 127.0.0.1:<port>
Swift 侧通过 HTTP POST /execute 发送脚本，server 执行并返回结果

端点：
    GET  /health   — 健康检查，返回 {status, pythonVersion, uptime}
    POST /execute  — 执行脚本，body: {script, workingDir, timeout}
                     返回: {stdout, stderr, exitCode, error}
"""

import http.server
import json
import sys
import io
import os
import time
import traceback

# 注意：不导入 signal 模块 — signal.alarm 与 Node.js V8 的信号处理冲突
# 超时控制依赖 Swift 侧 URLSession timeout

# ============================================
# 配置
# ============================================

PORT = 48214  # 与 BaizePython.enginePort 一致
HOST = "127.0.0.1"

# 记录启动时间（用于 uptime 计算）
START_TIME = time.time()

# 获取 Python 版本字符串
PYTHON_VERSION = "{}.{}.{}".format(
    sys.version_info.major,
    sys.version_info.minor,
    sys.version_info.micro
)


# ============================================
# HTTP 请求处理器
# ============================================

class BaizeHandler(http.server.BaseHTTPRequestHandler):
    """白泽 Python 执行 HTTP 请求处理器"""

    def do_GET(self):
        """处理 GET 请求"""
        if self.path == "/health":
            self._handle_health()
        else:
            self.send_error(404, "Not Found")

    def do_POST(self):
        """处理 POST 请求"""
        if self.path == "/execute":
            self._handle_execute()
        else:
            self.send_error(404, "Not Found")

    def _handle_health(self):
        """健康检查端点"""
        response = {
            "status": "ok",
            "pythonVersion": PYTHON_VERSION,
            "uptime": round(time.time() - START_TIME, 2)
        }
        self._send_json(200, response)

    def _handle_execute(self):
        """脚本执行端点"""
        try:
            # 读取请求体
            content_length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(content_length)
            request = json.loads(body.decode("utf-8"))

            script = request.get("script", "")
            working_dir = request.get("workingDir", "")

        except (json.JSONDecodeError, UnicodeDecodeError) as e:
            self._send_json(400, {
                "stdout": "",
                "stderr": "请求解析错误: {}".format(str(e)),
                "exitCode": 1,
                "error": str(e)
            })
            return

        # 重定向 stdout/stderr
        old_stdout, old_stderr = sys.stdout, sys.stderr
        old_cwd = os.getcwd()
        sys.stdout = stdout_buf = io.StringIO()
        sys.stderr = stderr_buf = io.StringIO()

        exit_code = 0
        error = None

        # 注意：不使用 signal.alarm — 与 Node.js V8 信号处理冲突
        # 超时控制完全依赖 Swift 侧 URLSession timeout

        try:
            # 切换工作目录
            if working_dir and os.path.isdir(working_dir):
                os.chdir(working_dir)

            # 执行脚本 — 每次创建独立命名空间
            exec_globals = {
                "__name__": "__main__",
                "__builtins__": __builtins__,
            }
            exec(script, exec_globals)

        except SystemExit as e:
            # 脚本调用 sys.exit()
            exit_code = e.code if isinstance(e.code, int) else 1
        except Exception:
            exit_code = 1
            error = traceback.format_exc()
        finally:
            # 恢复 stdout/stderr 和工作目录
            sys.stdout = old_stdout
            sys.stderr = old_stderr
            os.chdir(old_cwd)

        # 构建响应
        response = {
            "stdout": stdout_buf.getvalue(),
            "stderr": stderr_buf.getvalue(),
            "exitCode": exit_code,
            "error": error
        }
        self._send_json(200, response)

    def _send_json(self, status_code, data):
        """发送 JSON 响应"""
        body = json.dumps(data).encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        """静默 HTTP 日志（不输出到 stderr）"""
        pass


# ============================================
# 启动 HTTP Server
# ============================================

def main():
    """启动 HTTP server，阻塞运行"""
    try:
        server = http.server.HTTPServer((HOST, PORT), BaizeHandler)
    except OSError as e:
        sys.stderr.write("Failed to start HTTP server on {}:{}: {}\n".format(HOST, PORT, e))
        return

    # 注意：使用单线程 HTTPServer（非 ThreadingHTTPServer）
    # 原因：
    # 1. 白泽的 Agent 模式下，每次 run_python 是独立执行，无需并发
    # 2. 单线程避免了 GIL 竞争和命名空间隔离问题
    # 3. serve_forever() 在 Python 主线程（调用 Py_Initialize 的线程）运行
    #    select() 期间释放 GIL，允许其他 Python 线程执行
    # 4. signal.alarm 只在主线程有效，单线程模式确保超时控制可用

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
