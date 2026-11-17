import {execFile} from 'node:child_process';
import {createHash} from 'node:crypto';
import {access, mkdir, mkdtemp, rename, rm, writeFile} from 'node:fs/promises';
import {createServer} from 'node:net';
import {homedir} from 'node:os';
import path from 'node:path';
import {setTimeout as delay} from 'node:timers/promises';
import {promisify} from 'node:util';
import {gunzipSync} from 'node:zlib';

const run = promisify(execFile);
const windows = process.platform === 'win32';
const ffmpegName = windows ? 'ffmpeg.exe' : 'ffmpeg';
const ffmpegHashes = {
  'darwin-arm64': '8923876afa8db5585022d7860ec7e589af192f441c56793971276d450ed3bbfa',
  'darwin-x64': '929b375c1182d956c51f7ac25e0b2b0411fb01f6f407aa15c9758efeb4242106',
  'win32-x64': '8883a3dffbd0a16cf4ef95206ea05283f78908dbfb118f73c83f4951dcc06d77',
  'win32-ia32': 'af47ca5de7b9f859f48e4e96ea831bf551b100144b0b871762ab48fba1152f56',
};

async function usableFfmpeg(file) {
  try {
    const {stdout} = await run(file, ['-hide_banner', '-encoders'], {timeout: 4000, windowsHide: true});
    return /\blibx264\b/.test(stdout) && /\baac\b/.test(stdout);
  } catch {
    return false;
  }
}

async function downloadFfmpeg(release, platform, checksum) {
  const asset = `${release}/ffmpeg-${platform}.gz`;
  let lastError;
  for (const base of [
    'https://cdn.npmmirror.com/binaries/ffmpeg-static/',
    'https://github.com/eugeneware/ffmpeg-static/releases/download/',
  ]) {
    try {
      const response = await fetch(base + asset, {signal: AbortSignal.timeout(60_000)});
      if (!response.ok) throw new Error(`FFmpeg 下载失败（HTTP ${response.status}）`);
      const archive = Buffer.from(await response.arrayBuffer());
      if (createHash('sha256').update(archive).digest('hex') !== checksum) {
        throw new Error('FFmpeg 下载文件校验失败');
      }
      return archive;
    } catch (error) {
      lastError = error;
    }
  }
  throw lastError;
}

async function configureFfmpeg(cacheDir) {
  // Windows 11 on ARM can run the x64 FFmpeg build.
  const arch = windows && process.arch === 'arm64' ? 'x64' : process.arch;
  const platform = `${process.platform}-${arch}`;
  const release = platform === 'win32-ia32' ? 'b6.0' : 'b6.1.1';
  const ffmpegCache = path.join(cacheDir, `ffmpeg-${release}-${platform}`);
  const cachedFfmpeg = path.join(ffmpegCache, ffmpegName);
  const candidates = [
    process.env.FFMPEG,
    ...(process.env.PATH || '').split(path.delimiter).filter(Boolean)
      .map(folder => path.join(folder.replace(/^"|"$/g, ''), ffmpegName)),
    ...(!windows ? ['/opt/homebrew/bin/ffmpeg', '/usr/local/bin/ffmpeg',
      path.join(homedir(), '.local/bin/ffmpeg'), '/usr/bin/ffmpeg'] : []),
    cachedFfmpeg,
  ];
  for (const candidate of new Set(candidates.filter(Boolean))) {
    const file = path.resolve(candidate);
    if (await usableFfmpeg(file)) return file;
  }

  const checksum = ffmpegHashes[platform];
  if (!checksum) throw new Error('当前架构没有可自动配置的 FFmpeg 版本');
  console.log('正在配置 FFmpeg，以支持录屏转 MP4……');
  const archive = await downloadFfmpeg(release, platform, checksum);

  await mkdir(ffmpegCache, {recursive: true});
  const stage = await mkdtemp(path.join(ffmpegCache, 'download-'));
  try {
    const file = path.join(stage, ffmpegName);
    await writeFile(file, gunzipSync(archive), {mode: 0o755});
    if (!(await usableFfmpeg(file))) throw new Error('下载的 FFmpeg 无法在这台电脑上运行');
    try {
      await rename(file, cachedFfmpeg);
    } catch (error) {
      if (!(await usableFfmpeg(cachedFfmpeg))) throw error;
    }
  } finally {
    await rm(stage, {recursive: true, force: true});
  }
  return cachedFfmpeg;
}

async function findPort() {
  for (let port = 5190; port <= 5209; port += 1) {
    const available = await new Promise((resolve, reject) => {
      const probe = createServer();
      probe.once('error', error => {
        if (error.code === 'EADDRINUSE' || error.code === 'EACCES') resolve(false);
        else reject(error);
      });
      probe.listen(port, '0.0.0.0', () => probe.close(error => error ? reject(error) : resolve(true)));
    });
    if (available) return port;
  }
  throw new Error('5190–5209 端口均不可用，请关闭旧的夜航窗口后重试');
}

async function openGame(origin) {
  const url = origin + '/?pair=1';
  for (let attempt = 0; attempt < 30; attempt += 1) {
    let ready = false;
    try {
      const response = await fetch(origin + '/api/config', {signal: AbortSignal.timeout(500)});
      ready = response.ok && Boolean((await response.json()).token);
    } catch {}
    if (ready) {
      try {
        if (windows) await run(process.env.ComSpec || 'cmd.exe', ['/d', '/c', 'start', url], {windowsHide: true});
        else await run('/usr/bin/open', [url]);
        return;
      } catch {
        break;
      }
    }
    await delay(150);
  }
  console.error(`如浏览器未自动打开，请手动访问 ${url}`);
}

try {
  for (const file of ['server.mjs', '夜航模拟器.html', '手机手柄.html']) {
    await access(path.join(import.meta.dirname, file)).catch(() => {
      throw new Error(`夜航运行包缺少 ${file}，请重新完整解压`);
    });
  }
  try {
    process.env.FFMPEG = await configureFfmpeg(process.env.NIGHTFLIGHT_CACHE);
  } catch (error) {
    console.warn(`FFmpeg 配置未完成，游戏照常启动。录屏转码不可用时会保留 WebM。原因：${error.message}`);
  }
  const port = await findPort();
  process.env.FPV_PORT = String(port);
  await import('./server.mjs');
  await openGame(`http://127.0.0.1:${port}`);
} catch (error) {
  console.error(`夜航启动失败：${error.message}`);
  process.exitCode = 1;
}
