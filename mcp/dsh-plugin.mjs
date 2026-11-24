// DSH 适配层：把 MCP 服务挂到官方 @deepseek-ai/dsh-mcp-client 桥上。
//
// 为什么不用裸 import：
//   本地目录安装是 `link:`，Node 会从工作区往上解析裸模块说明符，而工作区没有
//   node_modules，所以 `import '@deepseek-ai/dsh-mcp-client'` 会 ERR_MODULE_NOT_FOUND。
//   （npm 装在 profile node_modules 里的插件不受影响。）
//
// 这里用 DSH 安装目录作为解析锚点，从运行中的安装里找桥；找不到再退回裸 import，
// 这样本地 link 安装和正式安装两种布局都能工作。
//
// 同样为了避免依赖，这里不导出 Schemastery Config：尺寸参数走环境变量 + 默认值。

import { createRequire } from 'node:module';
import { pathToFileURL, fileURLToPath } from 'node:url';
import path from 'node:path';

export const name = 'desktop-clone';
export const inject = ['tools'];

const BRIDGE_PACKAGE = '@deepseek-ai/dsh-mcp-client';

async function loadBridge() {
  const anchors = [];
  if (process.env.DSH_INSTALL_DIR) {
    anchors.push(path.join(process.env.DSH_INSTALL_DIR, 'package.json'));
  }
  anchors.push(path.join(process.env.DSH_PROFILE_DIR ?? process.cwd(), 'package.json'));

  for (const anchor of anchors) {
    try {
      const requireFrom = createRequire(anchor);
      const resolved = requireFrom.resolve(BRIDGE_PACKAGE);
      return await import(pathToFileURL(resolved).href);
    } catch {
      // 换下一个锚点
    }
  }

  // 正式安装（profile node_modules）时裸 import 就能命中。
  return await import(BRIDGE_PACKAGE);
}

function readConfig(config = {}) {
  const fromEnv = (key, fallback) => {
    const raw = process.env[key];
    const parsed = raw ? Number(raw) : Number.NaN;
    return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
  };

  return {
    desktopWidth: config.desktopWidth ?? fromEnv('DSH_CLONE_DESKTOP_WIDTH', 1920),
    desktopHeight: config.desktopHeight ?? fromEnv('DSH_CLONE_DESKTOP_HEIGHT', 1080),
    windowWidth: config.windowWidth ?? fromEnv('DSH_CLONE_WINDOW_WIDTH', 1280),
    windowHeight: config.windowHeight ?? fromEnv('DSH_CLONE_WINDOW_HEIGHT', 720),
    toolCallTimeoutMs: config.toolCallTimeoutMs ?? 120000,
    failOnStartupError: config.failOnStartupError ?? false
  };
}

export function bridgeConfig(config = {}) {
  const settings = readConfig(config);
  return {
    serverName: 'dsclone',
    transport: 'stdio',
    command: process.execPath,
    args: [fileURLToPath(new URL('./server.mjs', import.meta.url))],
    // Electron 宿主需要 ELECTRON_RUN_AS_NODE 才能当普通 Node 跑；
    // 普通 Node 宿主会忽略这个变量。
    env: {
      ELECTRON_RUN_AS_NODE: '1',
      DSH_CLONE_DESKTOP_WIDTH: String(settings.desktopWidth),
      DSH_CLONE_DESKTOP_HEIGHT: String(settings.desktopHeight),
      DSH_CLONE_WINDOW_WIDTH: String(settings.windowWidth),
      DSH_CLONE_WINDOW_HEIGHT: String(settings.windowHeight)
    },
    toolCallTimeoutMs: settings.toolCallTimeoutMs,
    failOnStartupError: settings.failOnStartupError
  };
}

export async function apply(ctx, config) {
  const bridge = await loadBridge();
  const connection = ctx.plugin(bridge, bridgeConfig(config));
  await connection;
}
