import { readFile, writeFile, mkdir, rename, rm } from 'node:fs/promises';
import { dirname, resolve, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { parseArgs, promisify } from 'node:util';
import { execFile } from 'node:child_process';
import { DEFAULT_REPOSITORY, fetchGitHubData, createSnapshot } from './dashboard-data.mjs';

const TOOL_DIRECTORY = dirname(fileURLToPath(import.meta.url));
const REPOSITORY_ROOT = resolve(TOOL_DIRECTORY, '..');

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
  generatedAt,
  workspaceCommit,
} = {}) {
  const [manifest, roadmap] = await Promise.all([
    readJson(manifestPath, '岗位清单'),
    readJson(roadmapPath, '项目排期'),
  ]);
  const remote = await fetchGitHubData({ repository, token, fetchImpl });
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
      help: { type: 'boolean' },
    },
  });
  if (values.help) {
    console.log('node tools/build-dashboard.mjs [--repo owner/name] [--manifest path] [--roadmap path] [--output path]');
    console.log('可选认证只读取 GITHUB_TOKEN 环境变量；快照旁生成浏览器共用的 github-data.mjs。');
    return;
  }
  // checkout ref:main can differ from the event's GITHUB_SHA; inspect the actual checkout.
  let workspaceCommit;
  if (process.env.GITHUB_ACTIONS === 'true') {
    const result = await promisify(execFile)('git', ['rev-parse', 'HEAD'], { cwd: REPOSITORY_ROOT, encoding: 'utf8' });
    workspaceCommit = result.stdout.trim();
  }
  const snapshot = await buildDashboard({
    repository: values.repo ?? DEFAULT_REPOSITORY,
    manifestPath: values.manifest ? resolve(values.manifest) : undefined,
    roadmapPath: values.roadmap ? resolve(values.roadmap) : undefined,
    outputPath: values.output ? resolve(values.output) : undefined,
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
