import { readFile, writeFile, mkdir, rename, rm } from 'node:fs/promises';
import { dirname, resolve, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { parseArgs, promisify } from 'node:util';
import { execFile } from 'node:child_process';
import { DEFAULT_REPOSITORY, fetchGitHubData, createSnapshot } from './dashboard-data.mjs';

const TOOL_DIRECTORY = dirname(fileURLToPath(import.meta.url));
const REPOSITORY_ROOT = resolve(TOOL_DIRECTORY, '..');
const executeFile = promisify(execFile);

function cliResponse(output) {
  const separator = /\r?\n\r?\n/.exec(output);
  if (!separator) throw new Error('GitHub CLI 未返回完整的 HTTP 响应。');
  const lines = output.slice(0, separator.index).split(/\r?\n/);
  const statusLine = /^HTTP\/\S+\s+(\d{3})(?:\s+.*)?$/.exec(lines.shift());
  const status = statusLine ? Number(statusLine[1]) : 0;
  if (status < 200 || status > 599) throw new Error('GitHub CLI 返回的 HTTP 状态无效。');
  const headers = new Headers();
  for (const line of lines) {
    const colon = line.indexOf(':');
    if (colon < 1) throw new Error('GitHub CLI 返回的 HTTP 响应头无效。');
    headers.append(line.slice(0, colon).trim(), line.slice(colon + 1).trim());
  }
  const body = output.slice(separator.index + separator[0].length);
  return new Response([204, 205, 304].includes(status) ? null : body, { status, headers });
}

// Keep authentication inside the already-signed-in gh process; never extract its token.
export function createGhFetch(ghPath, { execute = executeFile } = {}) {
  if (typeof ghPath !== 'string' || !ghPath.trim()) throw new Error('--gh 需要 GitHub CLI 可执行文件。');
  return async (url, options = {}) => {
    const target = new URL(url);
    if (target.origin !== 'https://api.github.com' || (options.method && options.method !== 'GET')) {
      throw new Error('GitHub CLI 构建通道仅接受 github.com 的只读 API 请求。');
    }
    if (options.signal?.aborted) throw new DOMException('请求已取消。', 'AbortError');
    const headers = new Headers(options.headers);
    if (headers.has('authorization')) throw new Error('gh 模式使用现有登录，不接受额外的认证请求头。');
    const args = ['api', '--hostname', 'github.com', '--include', '--method', 'GET'];
    for (const name of ['accept', 'x-github-api-version']) {
      if (headers.has(name)) args.push('--header', name + ': ' + headers.get(name));
    }
    args.push(target.pathname + target.search);
    let output;
    let failed = false;
    try {
      const result = await execute(ghPath, args, {
        encoding: 'utf8', maxBuffer: 32 * 1024 * 1024, windowsHide: true,
        signal: options.signal,
        env: { ...process.env, GH_PROMPT_DISABLED: '1', NO_COLOR: '1' },
      });
      output = result.stdout;
    } catch (error) {
      if (options.signal?.aborted || error.name === 'AbortError') {
        throw new DOMException('请求已取消。', 'AbortError');
      }
      // gh exits nonzero for HTTP errors, including the expected release-not-found 404.
      if (typeof error.code !== 'number' || !error.stdout) {
        throw new Error('GitHub CLI 请求失败，请检查可执行文件、现有登录和网络连接。');
      }
      output = error.stdout;
      failed = true;
    }
    const response = cliResponse(output);
    if (failed && response.status < 400) throw new Error('GitHub CLI 未成功完成请求。');
    return response;
  };
}

async function readJson(path, label) {
  try {
    return JSON.parse(await readFile(path, 'utf8'));
  } catch {
    throw new Error('无法读取有效的 ' + label + '：' + path);
  }
}

async function replaceFile(path, content) {
  const temporary = path + '.tmp-' + process.pid + '-' + Date.now();
  try {
    await writeFile(temporary, content, 'utf8');
    await rename(temporary, path);
  } finally {
    await rm(temporary, { force: true });
  }
}

export async function buildDashboard({
  repository = DEFAULT_REPOSITORY,
  manifestPath = join(REPOSITORY_ROOT, 'workspace', 'manifest.json'),
  roadmapPath = join(REPOSITORY_ROOT, 'workspace', 'roadmap.json'),
  outputPath = join(REPOSITORY_ROOT, 'site', 'data', 'snapshot.json'),
  token = process.env.GITHUB_TOKEN ?? '',
  fetchImpl = globalThis.fetch,
  ghPath,
  generatedAt,
  workspaceCommit,
} = {}) {
  const [manifest, roadmap] = await Promise.all([
    readJson(manifestPath, '岗位清单'),
    readJson(roadmapPath, '项目排期'),
  ]);
  const remote = await fetchGitHubData({
    repository,
    token: ghPath ? '' : token,
    fetchImpl: ghPath ? createGhFetch(ghPath) : fetchImpl,
  });
  if (workspaceCommit && remote.commit.sha !== workspaceCommit) {
    throw new Error('main 已变化，与本次检出的排期和岗位版本不一致；请重新构建。旧快照未替换。');
  }
  const snapshot = createSnapshot({ ...remote, manifest, roadmap, generatedAt, workspaceCommit });
  const sharedModule = await readFile(join(TOOL_DIRECTORY, 'dashboard-data.mjs'), 'utf8');
  const output = resolve(outputPath);
  // No output is touched until every remote request and normalization succeeds.
  await mkdir(dirname(output), { recursive: true });
  await replaceFile(join(dirname(output), 'github-data.mjs'), sharedModule);
  await replaceFile(output, JSON.stringify(snapshot, null, 2) + '\n');
  return snapshot;
}

export async function main(args = process.argv.slice(2)) {
  const { values } = parseArgs({
    args,
    options: {
      repo: { type: 'string' },
      manifest: { type: 'string' },
      roadmap: { type: 'string' },
      output: { type: 'string' },
      gh: { type: 'string' },
      help: { type: 'boolean' },
    },
  });
  if (values.help) {
    console.log('node tools/build-dashboard.mjs [--repo owner/name] [--manifest path] [--roadmap path] [--output path] [--gh executable]');
    console.log('--gh 复用已登录的 GitHub CLI，不读取或显示凭据；默认使用匿名请求或既有 GITHUB_TOKEN。');
    console.log('快照旁生成浏览器共用的 github-data.mjs，浏览器仍使用匿名公共 API。');
    return;
  }
  // checkout ref:main can differ from the event's GITHUB_SHA; inspect the actual checkout.
  let workspaceCommit;
  if (process.env.GITHUB_ACTIONS === 'true') {
    const result = await executeFile('git', ['rev-parse', 'HEAD'], { cwd: REPOSITORY_ROOT, encoding: 'utf8', windowsHide: true });
    workspaceCommit = result.stdout.trim();
  }
  const snapshot = await buildDashboard({
    repository: values.repo ?? DEFAULT_REPOSITORY,
    manifestPath: values.manifest ? resolve(values.manifest) : undefined,
    roadmapPath: values.roadmap ? resolve(values.roadmap) : undefined,
    outputPath: values.output ? resolve(values.output) : undefined,
    ghPath: values.gh,
    workspaceCommit,
  });
  console.log('Dashboard snapshot: ' + snapshot.tasks.length + ' issues, main ' +
    snapshot.version.short_sha + ', generated ' + snapshot.generated_at + '.');
  if (snapshot.source.note) console.log(snapshot.source.note);
}

if (process.argv[1] && pathToFileURL(resolve(process.argv[1])).href === import.meta.url) {
  main().catch((error) => {
    // Do not print fetch options, environment values, request headers, or raw response bodies.
    console.error(error.message);
    process.exitCode = 1;
  });
}
