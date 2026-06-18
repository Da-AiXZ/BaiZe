/**
 * Baize Node.js Bootstrap Script
 *
 * 在 nodejs-mobile 进程内启动 HTTP server，监听 127.0.0.1:<port>
 * Swift 侧通过 HTTP POST /execute 发送脚本，server 执行并返回结果
 *
 * 端点：
 *   GET  /health   — 健康检查，返回 {status, versions, uptime}
 *   POST /execute  — 执行脚本，body: {script, workingDir, timeout}
 *                    返回 {stdout, stderr, exitCode, error}
 */

const http = require('http');
const vm = require('vm');

// 解析端口参数（--port=48213）
const portArg = process.argv.find(function(a) { return a.startsWith('--port='); });
const PORT = portArg ? parseInt(portArg.split('=')[1], 10) : 48213;

/**
 * HTTP 请求处理器
 */
const server = http.createServer(function(req, res) {
    // 所有响应均为 JSON
    res.setHeader('Content-Type', 'application/json');

    // ============================================
    // GET /health — 健康检查
    // ============================================
    if (req.method === 'GET' && req.url === '/health') {
        res.writeHead(200);
        res.end(JSON.stringify({
            status: 'ok',
            versions: process.versions,
            uptime: process.uptime()
        }));
        return;
    }

    // ============================================
    // POST /execute — 执行脚本
    // ============================================
    if (req.method === 'POST' && req.url === '/execute') {
        var body = '';
        req.on('data', function(chunk) { body += chunk; });
        req.on('end', function() {
            try {
                var parsed = JSON.parse(body);
                var script = parsed.script;
                var workingDir = parsed.workingDir;
                var timeout = parsed.timeout;
                var timeoutMs = (timeout || 30) * 1000;

                // 切换工作目录
                if (workingDir) {
                    try {
                        process.chdir(workingDir);
                    } catch (e) {
                        // 工作目录不存在时忽略，使用默认目录
                    }
                }

                // 拦截 stdout/stderr — 收集脚本输出
                var stdout = '';
                var stderr = '';
                var origStdoutWrite = process.stdout.write.bind(process.stdout);
                var origStderrWrite = process.stderr.write.bind(process.stderr);

                process.stdout.write = function(chunk) {
                    var str = typeof chunk === 'string' ? chunk : chunk.toString();
                    stdout += str;
                    return true;
                };
                process.stderr.write = function(chunk) {
                    var str = typeof chunk === 'string' ? chunk : chunk.toString();
                    stderr += str;
                    return true;
                };

                var exitCode = 0;
                var errorMsg = null;

                try {
                    // 使用 vm.runInThisContext 执行脚本
                    // 优点：在当前全局上下文执行，require/process/console 可用
                    // 超时：V8 同步超时，仅对同步代码有效
                    var scriptObj = new vm.Script(script, {
                        filename: 'baize_script.js',
                        timeout: timeoutMs
                    });
                    scriptObj.runInThisContext({
                        filename: 'baize_script.js',
                        timeout: timeoutMs
                    });
                } catch (e) {
                    exitCode = 1;
                    if (e.code === 'ERR_SCRIPT_EXECUTION_TIMEOUT') {
                        errorMsg = 'Script execution timed out';
                        stderr += '\n' + e.stack;
                    } else if (e instanceof SyntaxError) {
                        errorMsg = 'SyntaxError: ' + e.message;
                        stderr += '\n' + e.stack;
                    } else {
                        errorMsg = e.message;
                        stderr += '\n' + (e.stack || e.toString());
                    }
                }

                // 恢复 stdout/stderr
                process.stdout.write = origStdoutWrite;
                process.stderr.write = origStderrWrite;

                res.writeHead(200);
                res.end(JSON.stringify({
                    stdout: stdout,
                    stderr: stderr,
                    exitCode: exitCode,
                    error: errorMsg
                }));
            } catch (e) {
                // JSON 解析错误等
                res.writeHead(400);
                res.end(JSON.stringify({
                    stdout: '',
                    stderr: 'Request parsing error: ' + e.message,
                    exitCode: 1,
                    error: e.message
                }));
            }
        });
        return;
    }

    // ============================================
    // 未知路由
    // ============================================
    res.writeHead(404);
    res.end(JSON.stringify({ error: 'Not found' }));
});

// 启动 HTTP server
server.listen(PORT, '127.0.0.1', function() {
    // Server 已就绪 — Swift 侧通过 /health 健康检查确认
    // 不依赖此回调输出（此时 stdout 可能尚未被拦截）
});

// 错误处理（端口被占用等）
server.on('error', function(e) {
    // 输出到 stderr（未被拦截时为 Node 线程的 thread_stderr）
    process.stderr.write('HTTP server error: ' + e.message + '\n');
});

// 防止未捕获异常导致进程崩溃
process.on('uncaughtException', function(e) {
    process.stderr.write('Uncaught exception: ' + (e.stack || e.toString()) + '\n');
});
