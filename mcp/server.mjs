// dsh-desktop-clone —— MCP stdio 服务
//
// 零依赖：手写 JSON-RPC（换行分隔），避免为几个方法引入 SDK。
//
// 职责：
//   desktop_clone_start     拉起 PS 宿主（可见窗口）→ 等子会话 → 注入 agent → 接 TCP
//   desktop_clone_status    连接状态 / 会话号 / 桌面尺寸 / agent 端口
//   desktop_clone_screenshot 分身整屏 PNG（MCP image 内容）
//   desktop_clone_click     分身内坐标点击（真实指针，只影响分身）
//   desktop_clone_type_text 向分身当前焦点输入
//   desktop_clone_cursor    分身内光标位置
//   desktop_clone_stop      关宿主 + 注销子会话
//
// 所有 PowerShell 调用都用 -EncodedCommand，避免引号、中文路径和代码页问题。

import { spawn, execFile } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import fs from 'node:fs';
import os from 'node:os';
import net from 'node:net';

const here = path.dirname(fileURLToPath(import.meta.url));
const packageRoot = path.resolve(here, '..');
const hostScript = path.join(packageRoot, 'host', 'clone-host.ps1');
const agentScript = path.join(packageRoot, 'host', 'clone-agent.ps1');
const stateRoot = path.join(process.env.LOCALAPPDATA || os.tmpdir(), 'dsh-desktop-clone');
const stateFile = path.join(stateRoot, 'agent-state.json');
const shotDir = path.join(os.tmpdir(), 'dsh-clone');

const SERVER_INFO = { name: 'dsh-desktop-clone', version: '0.1.0' };

const state = {
  host: null,
  sessionId: null,
  agent: null,
  socket: null,
  buffer: '',
  seq: 0,
  pending: new Map()
};

function log(message) {
  process.stderr.write(`[desktop-clone] ${message}\n`);
}

// ---------------------------------------------------------------- PowerShell
function runPowerShell(script, timeoutMs = 60000) {
  // 不要用 -EncodedCommand：Windows PowerShell 5.1 在这条路上调用
  // `RunEx(params, flags, sessionId, user)` 会抛 ArgumentException，任务根本没起来；
  // 同一段脚本用 -File 跑就正常（实测对照）。
  //
  // 所以统一落到临时 .ps1（UTF-8 BOM，否则中文乱码）再 -File 执行，
  // 这样 5.1 和 7 两条运行时都能用，不强制用户装 PowerShell 7。
  const shell = process.env.DSH_CLONE_PWSH || 'powershell.exe';
  const dir = path.join(os.tmpdir(), 'dsh-clone');
  fs.mkdirSync(dir, { recursive: true });
  const file = path.join(dir, `ps-${process.pid}-${Date.now()}-${Math.random().toString(16).slice(2, 8)}.ps1`);
  fs.writeFileSync(file, `\ufeff${script}`, 'utf8');

  return new Promise((resolve, reject) => {
    execFile(
      shell,
      ['-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', file],
      { windowsHide: true, timeout: timeoutMs, maxBuffer: 8 * 1024 * 1024 },
      (error, stdout, stderr) => {
        try {
          fs.rmSync(file, { force: true });
        } catch {
          // 清理失败不影响结果
        }
        if (error) {
          reject(new Error((stderr || error.message || 'powershell failed').trim()));
          return;
        }
        resolve(stdout.trim());
      }
    );
  });
}

const READ_SESSION = `
Add-Type -TypeDefinition 'using System;using System.Runtime.InteropServices;public static class DshCs{[DllImport("wtsapi32.dll")]public static extern bool WTSGetChildSessionId(out uint id);[DllImport("wtsapi32.dll")]public static extern bool WTSLogoffSession(IntPtr s,uint id,bool w);}' -Language CSharp
$sid=[uint32]0
if(-not [DshCs]::WTSGetChildSessionId([ref]$sid) -or $sid -eq [uint32]::MaxValue){ 'none'; exit }
# WTSGetChildSessionId 会返回「陈旧的」会话号：子会话注销之后它仍然回最后一个值。
# 直接拿去 RunEx 会得到 0x80070002（系统找不到指定的文件）。
# 所以用会话里是否还有进程来交叉校验 —— 活着的会话至少有 csrss/winlogon。
$alive = @(Get-CimInstance Win32_Process -Filter "SessionId=$sid" -ErrorAction SilentlyContinue).Count
if($alive -gt 0){ $sid } else { 'stale:' + $sid }
`;

async function readChildSessionId() {
  const out = await runPowerShell(READ_SESSION, 20000);
  if (out === 'none') return null;
  if (out.startsWith('stale:')) {
    log(`child session ${out.slice(6)} is stale (logged off); treating as none`);
    return null;
  }
  return Number(out);
}

// 宿主的启动方式踩过三次坑，结论是必须由「用户 shell」拉起：
//   - spawn：进程落在 DSH 的 job object 里，窗口一创建就被连带回收（CLONE_TIMEOUT）；
//   - 计划任务（Run / RunEx）：脱离了 job，但实测 RDP ActiveX 始终连不上
//     —— 宿主显示「RDP：未连接」，子会话里 0 个进程；
//   - explorer.exe 打开 .vbs 启动器：进程挂在 explorer 下，既脱离我们的进程树，
//     又保持正常的交互式用户上下文。实测 9 秒连上并完成登录。
function hostLauncherVbs(options = {}) {
  const hostArgs = [
    '-NoLogo', '-NoProfile', '-Sta', '-ExecutionPolicy', 'Bypass',
    '-File', `"${hostScript}"`,
    '-DesktopWidth', String(options.desktopWidth ?? 1920),
    '-DesktopHeight', String(options.desktopHeight ?? 1080),
    '-WindowWidth', String(options.windowWidth ?? 1280),
    '-WindowHeight', String(options.windowHeight ?? 720)
  ].join(' ');

  return [
    'Set sh = CreateObject("WScript.Shell")',
    `sh.Run "powershell.exe ${hostArgs.replace(/"/g, '""')}", 0, False`,
    ''
  ].join('\r\n');
}

// wscript 要求 UTF-16LE + BOM，纯 UTF-8 会让 VBS 里的中文路径变成乱码。
function writeHostLauncher(options = {}) {
  fs.mkdirSync(shotDir, { recursive: true });
  const vbsPath = path.join(shotDir, 'start-host.vbs');
  const body = hostLauncherVbs(options);
  fs.writeFileSync(vbsPath, Buffer.concat([Buffer.from([0xff, 0xfe]), Buffer.from(body, 'utf16le')]));
  return vbsPath;
}

function launchHostScript(vbsPath) {
  return `Start-Process -FilePath "$env:SystemRoot\\explorer.exe" -ArgumentList '"${vbsPath}"'; 'launch=explorer'`;
}

function injectAgentScript(sessionId, port, token) {
  return `
$ErrorActionPreference='Stop'
$user="$env:USERDOMAIN\\$env:USERNAME"
$svc=New-Object -ComObject Schedule.Service
$svc.Connect()
$folder=$svc.GetFolder('\\')
$name='DSHCloneAgent'
$def=$svc.NewTask(0)
$def.Settings.Hidden=$true
$def.Settings.AllowDemandStart=$true
$def.Settings.ExecutionTimeLimit='PT0S'
$def.Settings.DisallowStartIfOnBatteries=$false
$def.Settings.StopIfGoingOnBatteries=$false
$def.Principal.UserId=$user
$def.Principal.LogonType=3
$def.Principal.RunLevel=0
$a=$def.Actions.Create(0)
$a.Path="$env:SystemRoot\\System32\\WindowsPowerShell\\v1.0\\powershell.exe"
$a.Arguments='-NoProfile -ExecutionPolicy Bypass -File "${agentScript}" -Port ${port} -Token ${token} -StateFile "${stateFile}"'
$reg=$folder.RegisterTaskDefinition($name,$def,2,$user,$null,3,$null)
# RunEx 在部分环境返回 IRunningTask 时会抛 ArgumentException，但任务其实已经起来。
# 这里降级为警告，真正的成功判据是后面 agent 的握手文件。
try { $reg.RunEx($null,4,${sessionId},$null) | Out-Null; 'runex=ok' }
catch { 'runex=warn ' + $_.Exception.GetBaseException().Message }
finally { try { $folder.DeleteTask($name,0) } catch { } }
`;
}

// ---------------------------------------------------------------- agent TCP
function connectAgent(port, token) {
  return new Promise((resolve, reject) => {
    const socket = net.createConnection({ host: '127.0.0.1', port }, () => {
      state.socket = socket;
      state.agent = { port, token };
      socket.setEncoding('utf8');
      socket.on('data', chunk => {
        state.buffer += chunk;
        let index;
        while ((index = state.buffer.indexOf('\n')) >= 0) {
          const line = state.buffer.slice(0, index).trim();
          state.buffer = state.buffer.slice(index + 1);
          if (!line) continue;
          let message;
          try {
            message = JSON.parse(line);
          } catch {
            continue;
          }
          const waiter = state.pending.get(message.id);
          if (waiter) {
            state.pending.delete(message.id);
            waiter(message);
          }
        }
      });
      socket.on('error', error => log(`agent socket error: ${error.message}`));
      resolve();
    });
    socket.once('error', reject);
  });
}

function agentCall(cmd, args = {}, timeoutMs = 60000) {
  return new Promise((resolve, reject) => {
    if (!state.socket) {
      reject(new Error('CLONE_NOT_STARTED: call desktop_clone_start first'));
      return;
    }
    const id = ++state.seq;
    const timer = setTimeout(() => {
      state.pending.delete(id);
      reject(new Error(`AGENT_TIMEOUT: ${cmd} exceeded ${timeoutMs}ms`));
    }, timeoutMs);

    state.pending.set(id, message => {
      clearTimeout(timer);
      if (message.ok === false) {
        reject(new Error(message.error || 'agent error'));
        return;
      }
      resolve(message);
    });

    state.socket.write(`${JSON.stringify({ id, cmd, token: state.agent.token, args })}\n`);
  });
}

// ---------------------------------------------------------------- lifecycle
async function start(options = {}) {
  if (state.socket) {
    return status();
  }

  fs.mkdirSync(stateRoot, { recursive: true });
  fs.mkdirSync(shotDir, { recursive: true });
  if (fs.existsSync(stateFile)) fs.rmSync(stateFile, { force: true });

  const existing = await readChildSessionId();
  log(`existing child session: ${existing ?? 'none'}`);

  // 有会话就附着（宿主内部会复用），没有就新建。
  // 宿主必须脱离本进程的 job object，否则 `spawn` 出来的 PowerShell 一创建窗口
  // 就被连带回收（实测：手工启动同一脚本能建出会话，spawn 启动就 CLONE_TIMEOUT）。
  // 和 agent 一样走临时计划任务投放，Run() 跑在当前登录用户的会话里。
  if (!options.attachOnly || existing) {
    const vbsPath = writeHostLauncher(options);
    await runPowerShell(launchHostScript(vbsPath), 30000);
    log(`host launch dispatched via explorer (${vbsPath})`);

    // 宿主的 pid 不在本进程树里，只能按窗口标题找。抓不到就留 null，
    // 但 BitBlt 依赖「会话有活跃 RDP 客户端在合成」，所以这个值要如实暴露出去。
    for (let attempt = 0; attempt < 6 && !state.hostPid; attempt += 1) {
      const pidText = await runPowerShell(
        `$p = Get-Process powershell -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle -eq 'DSH 桌面分身' } | Select-Object -First 1; if ($p) { $p.Id }`,
        15000
      ).catch(() => '');
      const pid = Number(pidText);
      if (Number.isFinite(pid) && pid > 0) state.hostPid = pid;
      else await delay(700);
    }
    log(`host window pid: ${state.hostPid ?? 'not found'}`);
  }

  const sessionId = await waitForSession(options.timeoutMs ?? 60000);
  state.sessionId = sessionId;

  const port = options.port ?? 47000 + Math.floor(Math.random() * 900);
  const token = options.token ?? `${Date.now().toString(16)}${Math.random().toString(16).slice(2)}`;

  // 注入这一步过去把输出丢掉了，失败时只剩 AGENT_TIMEOUT，无从定位。
  // 把注入脚本的 stdout/stderr 落盘，同时把实际使用的 session/port/stateFile 记下来。
  // 注入重试：会话刚就绪的瞬间仍可能被 RunEx 拒绝一次，
  // 这里把 `runex=warn` 视为可重试，而不是直接判失败（真正的判据是 agent 握手）。
  let injectResult = '';
  for (let attempt = 1; attempt <= 4; attempt += 1) {
    injectResult = await runPowerShell(injectAgentScript(sessionId, port, token), 60000);
    log(`inject attempt ${attempt}: ${injectResult}`);
    if (!injectResult.includes('runex=warn')) break;
    await delay(2500);
  }
  try {
    fs.writeFileSync(
      path.join(shotDir, 'inject.log'),
      `${new Date().toISOString()}\nsessionId=${sessionId}\nport=${port}\nstateFile=${stateFile}\nagentScript=${agentScript}\nresult=${injectResult}\n`,
      'utf8'
    );
  } catch {
    // 日志写不了不影响主流程
  }
  log(`inject result: ${injectResult}`);
  await waitForStateFile(options.agentTimeoutMs ?? 30000);
  await connectAgent(port, token);

  const pong = await agentCall('ping', {}, 15000);
  log(`agent ready session=${sessionId} screen=${pong.screen}`);
  return status();
}

async function waitForSession(timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  let lastId = null;

  while (Date.now() < deadline) {
    const id = await readChildSessionId();
    if (id) {
      lastId = id;
      // 会话号出现不等于登录完成。登录未完成时 RunEx(sessionId) 会抛
      // ArgumentException（"值不在预期的范围内"），注入必然失败。
      // 以 shell 就绪或进程数达标作为「可注入」的判据。
      if (await sessionReady(id)) return id;
    }
    await delay(800);
  }

  if (lastId) {
    throw new Error(`CLONE_TIMEOUT: child session ${lastId} appeared but never finished logging on.`);
  }
  throw new Error('CLONE_TIMEOUT: child session did not appear. Is Remote Desktop enabled (fDenyTSConnections=0)?');
}

async function sessionReady(sessionId) {
  const script = `
$n = @(Get-CimInstance Win32_Process -Filter "SessionId=${sessionId}" -ErrorAction SilentlyContinue).Count
$e = @(Get-CimInstance Win32_Process -Filter "SessionId=${sessionId} AND Name='explorer.exe'" -ErrorAction SilentlyContinue).Count
if ($e -gt 0 -or $n -ge 20) { 'ready' } else { 'waiting' }
`;
  const out = await runPowerShell(script, 20000).catch(() => 'waiting');
  return out.trim() === 'ready';
}

async function waitForStateFile(timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (fs.existsSync(stateFile)) {
      try {
        // Windows PowerShell 5.1 的 `Set-Content -Encoding UTF8` 会写出 BOM。
        // JSON.parse 遇到开头的 \uFEFF 直接抛错，被下面的 catch 吞掉，
        // 于是「文件明明已经写了」却一直轮询到超时 —— 必须剥掉 BOM。
        const raw = fs.readFileSync(stateFile, 'utf8').replace(/^\uFEFF/, '');
        const parsed = JSON.parse(raw);
        if (parsed.port) return parsed;
      } catch {
        // 文件正在写入，重试
      }
    }
    await delay(250);
  }
  throw new Error('AGENT_TIMEOUT: in-session agent never reported back');
}

async function status() {
  const sessionId = await readChildSessionId().catch(() => null);
  let screen = null;
  if (state.socket) {
    try {
      screen = (await agentCall('ping', {}, 5000)).screen;
    } catch {
      screen = null;
    }
  }
  return {
    running: Boolean(state.socket),
    sessionId,
    hostPid: state.hostPid ?? null,
    agentPort: state.agent ? state.agent.port : null,
    screen
  };
}

async function stop() {
  if (state.socket) {
    try {
      await agentCall('shutdown', {}, 5000);
    } catch {
      // 忽略：agent 可能已退出
    }
    state.socket.destroy();
    state.socket = null;
    state.agent = null;
  }

  // 宿主和 agent 都不在本进程的树里。按窗口标题找宿主不够可靠（窗口可能已销毁、
  // 或曾有多次启动），这里连命令行一起匹配，把残留的宿主与 agent 一并清掉。
  await runPowerShell(
    `Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.CommandLine -like '*clone-host*' -or $_.CommandLine -like '*clone-agent*' } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
'ok'`,
    20000
  ).catch(() => {});
  state.host = null;
  state.hostPid = null;

  const sessionId = await readChildSessionId().catch(() => null);
  if (sessionId) {
    await runPowerShell(
      `Add-Type -TypeDefinition 'using System;using System.Runtime.InteropServices;public static class DshLg{[DllImport("wtsapi32.dll")]public static extern bool WTSLogoffSession(IntPtr s,uint id,bool w);}' -Language CSharp; [void][DshLg]::WTSLogoffSession([IntPtr]::Zero,${sessionId},$true); 'ok'`,
      30000
    ).catch(() => {});
  }

  state.sessionId = null;
  return { stopped: true };
}

function delay(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

// ---------------------------------------------------------------- tools
const TOOLS = [
  {
    name: 'desktop_clone_start',
    description: 'Create or attach the isolated Windows child session, show its window, and start the in-session agent. Safe to call twice.',
    inputSchema: {
      type: 'object',
      additionalProperties: false,
      properties: {
        desktopWidth: { type: 'integer', minimum: 200, maximum: 8192, default: 1920 },
        desktopHeight: { type: 'integer', minimum: 200, maximum: 8192, default: 1080 },
        windowWidth: { type: 'integer', minimum: 200, default: 1280 },
        windowHeight: { type: 'integer', minimum: 200, default: 720 }
      }
    }
  },
  {
    name: 'desktop_clone_status',
    description: 'Report whether the clone is running, its session id, host pid, agent port and desktop size.',
    inputSchema: { type: 'object', additionalProperties: false, properties: {} }
  },
  {
    name: 'desktop_clone_screenshot',
    description: 'Capture the whole clone desktop as a PNG image. Coordinates in later clicks are in this image space.',
    inputSchema: { type: 'object', additionalProperties: false, properties: {} }
  },
  {
    name: 'desktop_clone_click',
    description: 'Click at clone-desktop coordinates. Uses the clone\'s own pointer, so the user\'s mouse never moves.',
    inputSchema: {
      type: 'object',
      additionalProperties: false,
      required: ['x', 'y'],
      properties: {
        x: { type: 'integer' },
        y: { type: 'integer' },
        doubleClick: { type: 'boolean', default: false }
      }
    }
  },
  {
    name: 'desktop_clone_type_text',
    description: 'Type text into whatever has focus inside the clone. This affects the clone only.',
    inputSchema: {
      type: 'object',
      additionalProperties: false,
      required: ['text'],
      properties: { text: { type: 'string' } }
    }
  },
  {
    name: 'desktop_clone_cursor',
    description: 'Report the pointer position inside the clone.',
    inputSchema: { type: 'object', additionalProperties: false, properties: {} }
  },
  {
    name: 'desktop_clone_stop',
    description: 'Close the clone window, stop the agent and log the child session off. Do this before the user shuts down or reboots.',
    inputSchema: { type: 'object', additionalProperties: false, properties: {} }
  }
];

async function callTool(name, args = {}) {
  switch (name) {
    case 'desktop_clone_start':
      return text(await start(args));
    case 'desktop_clone_status':
      return text(await status());
    case 'desktop_clone_screenshot': {
      const target = path.join(shotDir, `clone-${Date.now()}.png`);
      const result = await agentCall('screenshot', { path: target }, 60000);
      const data = fs.readFileSync(target).toString('base64');
      return {
        content: [
          {
            type: 'text',
            text: JSON.stringify({ screen: result.screen, bytes: result.fileBytes, path: target, mode: result.mode })
          },
          { type: 'image', data, mimeType: 'image/png' }
        ]
      };
    }
    case 'desktop_clone_click':
      return text(await agentCall('click', { x: args.x, y: args.y, doubleClick: Boolean(args.doubleClick) }));
    case 'desktop_clone_type_text':
      return text(await agentCall('type', { text: args.text }));
    case 'desktop_clone_cursor':
      return text(await agentCall('cursor', {}));
    case 'desktop_clone_stop':
      return text(await stop());
    default:
      throw new Error(`UNKNOWN_TOOL: ${name}`);
  }
}

function text(payload) {
  return { content: [{ type: 'text', text: JSON.stringify(payload) }] };
}

// ---------------------------------------------------------------- JSON-RPC
function send(message) {
  process.stdout.write(`${JSON.stringify(message)}\n`);
}

function reply(id, result) {
  send({ jsonrpc: '2.0', id, result });
}

function replyError(id, code, message) {
  send({ jsonrpc: '2.0', id, error: { code, message } });
}

async function handle(message) {
  const { id, method, params } = message;

  if (method === 'initialize') {
    reply(id, {
      protocolVersion: params?.protocolVersion ?? '2024-11-05',
      capabilities: { tools: {} },
      serverInfo: SERVER_INFO
    });
    return;
  }

  if (method === 'notifications/initialized' || method === 'initialized') {
    return;
  }

  if (method === 'tools/list') {
    reply(id, { tools: TOOLS });
    return;
  }

  if (method === 'tools/call') {
    const name = params?.name;
    try {
      reply(id, await callTool(name, params?.arguments ?? {}));
    } catch (error) {
      replyError(id, -32000, error.message);
    }
    return;
  }

  if (method === 'ping') {
    reply(id, {});
    return;
  }

  if (id !== undefined) {
    replyError(id, -32601, `METHOD_NOT_FOUND: ${method}`);
  }
}

let inputBuffer = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', chunk => {
  inputBuffer += chunk;
  let index;
  while ((index = inputBuffer.indexOf('\n')) >= 0) {
    const line = inputBuffer.slice(0, index).trim();
    inputBuffer = inputBuffer.slice(index + 1);
    if (!line) continue;
    let message;
    try {
      message = JSON.parse(line);
    } catch (error) {
      log(`bad json: ${error.message}`);
      continue;
    }
    handle(message).catch(error => {
      log(`handler error: ${error.message}`);
      if (message.id !== undefined) replyError(message.id, -32603, error.message);
    });
  }
});

process.stdin.on('end', () => {
  stop().finally(() => process.exit(0));
});

process.on('SIGTERM', () => {
  stop().finally(() => process.exit(0));
});

log('ready');
