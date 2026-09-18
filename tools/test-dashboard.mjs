import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, readFile, rm, access } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, dirname, resolve, basename } from 'node:path';
import { DEFAULT_REPOSITORY, normalizeIssues, createSnapshot, fetchGitHubData } from './dashboard-data.mjs';
import { buildDashboard } from './build-dashboard.mjs';

const API = 'https://api.github.com/repos/' + DEFAULT_REPOSITORY;
const WEB = 'https://github.com/' + DEFAULT_REPOSITORY;
const NOW = '2026-09-18T08:00:00Z';
const roles = [{ id: 'planner', name: '策划' }, { id: 'gameplay', name: '逻辑' }];
const manifest = { roles };
const roadmap = {
  phase: { id: 'preparation', label: '赛前准备', note: '正式方案待命题' },
  schedule: [{
    id: 'first-submission', title: '队内首次提交', at: '2026-10-19T00:00:00+08:00',
    date_only: false, kind: 'confirmed', note: '18 日结束前',
    source_url: '', is_deadline: true,
  }],
};
const repository = { full_name: DEFAULT_REPOSITORY, html_url: WEB, default_branch: 'main' };
const commit = {
  sha: 'a'.repeat(40), html_url: WEB + '/commit/' + 'a'.repeat(40),
  commit: { message: 'Prepare workspace\n\nDocument current baseline.', committer: { date: NOW } },
};

function issue(number, changes = {}) {
  return {
    number, title: '任务 ' + number, html_url: WEB + '/issues/' + number,
    state: 'open', state_reason: null, labels: [{ name: 'phase:preparation' }],
    assignees: [], updated_at: NOW, closed_at: null, milestone: null,
    ...changes,
  };
}
function response(data, status = 200, headers = {}) {
  return new Response(JSON.stringify(data), {
    status, headers: { 'Content-Type': 'application/json', ...headers },
  });
}
function fakeApi({ issues = [], release = null, issueFailure = 0, releaseFailure = 0 } = {}) {
  return async (url) => {
    const parsed = new URL(url);
    if (parsed.href === API) return response(repository);
    if (parsed.pathname.endsWith('/commits/main')) return response(commit);
    if (parsed.pathname.endsWith('/issues')) return response(issues, issueFailure || 200);
    if (parsed.pathname.endsWith('/releases/latest')) {
      return response(release, releaseFailure || (release === null ? 404 : 200));
    }
    throw new Error('Unexpected fixture request: ' + parsed.pathname);
  };
}
async function temporaryFixture(t) {
  const directory = await mkdtemp(join(tmpdir(), 'gamejam-dashboard-test-'));
  t.after(async () => {
    // Only remove this test-created directory directly under the known OS temp directory.
    assert.equal(dirname(resolve(directory)), resolve(tmpdir()));
    assert.ok(basename(directory).startsWith('gamejam-dashboard-test-'));
    await rm(directory, { recursive: true, force: true });
  });
  const manifestPath = join(directory, 'manifest.json');
  const roadmapPath = join(directory, 'roadmap.json');
  const outputPath = join(directory, 'snapshot.json');
  await writeFile(manifestPath, JSON.stringify(manifest));
  await writeFile(roadmapPath, JSON.stringify(roadmap));
  return { directory, manifestPath, roadmapPath, outputPath };
}

test('PR filtering preserves real issues, roles, people and milestone identity', () => {
  const result = normalizeIssues([
    issue(3, { pull_request: { url: API + '/pulls/3' } }),
    issue(2, {
      labels: [{ name: 'phase:production' }, { name: 'role:gameplay' }, { name: 'role:planner' }, { name: 'status:doing' }],
      assignees: [{ login: 'member-a', html_url: 'https://github.com/member-a' }],
      milestone: { title: '首个可运行版本', number: 4 },
    }),
    issue(1),
  ], roles);
  assert.deepEqual(result.tasks.map((task) => task.number), [1, 2]);
  assert.equal(result.tasks[0].status, 'todo');
  assert.equal(result.tasks[0].milestone, null);
  assert.equal(result.tasks[1].status, 'doing');
  assert.equal(result.tasks[1].phase, 'production');
  assert.deepEqual(result.tasks[1].roles, ['gameplay', 'planner']);
  assert.deepEqual(result.tasks[1].assignees, [{ login: 'member-a', url: 'https://github.com/member-a' }]);
  assert.equal(result.tasks[1].milestone, '首个可运行版本');
});

test('closed reasons win over in-progress labels; transient label conflicts remain visible', () => {
  const result = normalizeIssues([
    issue(1, { state: 'closed', state_reason: 'not_planned', closed_at: NOW, labels: ['status:doing', 'status:review'] }),
    issue(2, { state: 'closed', state_reason: 'completed', closed_at: NOW, labels: ['status:review'] }),
    issue(3, { labels: ['status:doing', 'status:review', 'phase:preparation', 'phase:production', 'role:unknown'] }),
  ], roles);
  assert.deepEqual(result.tasks.map((task) => task.status), ['cancelled', 'done', 'review']);
  assert.equal(result.tasks[2].phase, 'production');
  assert.deepEqual(result.tasks[2].roles, []);
  assert.ok(result.notes.some((note) => note.includes('cancelled')));
  assert.ok(result.notes.some((note) => note.includes('production')));
  assert.ok(result.notes.some((note) => note.includes('role:unknown')));
  assert.ok(result.notes.some((note) => note.includes('2 个未标有效阶段')));
});

test('follows the next Link even when the first page contains only a PR', async () => {
  const pageTwo = API + '/issues?state=all&per_page=100&page=2';
  const requests = [];
  const commonApi = fakeApi();
  const fetchImpl = async (url, options) => {
    requests.push(url);
    assert.equal(options.headers.Authorization, undefined);
    if (url === pageTwo) return response([issue(9)]);
    if (new URL(url).pathname.endsWith('/issues')) {
      return response([issue(8, { pull_request: {} })], 200, {
        Link: '<' + pageTwo + '>; rel="next", <' + pageTwo + '>; rel="last"',
      });
    }
    return commonApi(url);
  };
  const remote = await fetchGitHubData({ fetchImpl });
  assert.equal(remote.release, null);
  assert.ok(requests.includes(pageTwo));
  assert.deepEqual(normalizeIssues(remote.issues, roles).tasks.map((task) => task.number), [9]);
});

test('live refresh pins both workspace files to the fetched commit and preserves UTF-8 text', async () => {
  const requests = [];
  const currentRoadmap = structuredClone(roadmap);
  currentRoadmap.phase.note = '等待题目公布，再一起制作 🎮';
  const commonApi = fakeApi();
  const remote = await fetchGitHubData({
    includeWorkspace: true,
    fetchImpl: async (url, options) => {
      const parsed = new URL(url);
      if (parsed.pathname.includes('/contents/workspace/')) {
        requests.push(parsed);
        assert.equal(parsed.searchParams.get('ref'), commit.sha);
        assert.equal(options.headers.Accept, 'application/vnd.github.raw+json');
        const value = parsed.pathname.endsWith('/manifest.json') ? manifest : currentRoadmap;
        const utf8 = new TextEncoder().encode(JSON.stringify(value));
        const withBom = new Uint8Array([0xef, 0xbb, 0xbf, ...utf8]);
        return new Response(withBom, { headers: { 'Content-Type': 'application/vnd.github.raw+json; charset=utf-8' } });
      }
      return commonApi(url);
    },
  });
  assert.equal(requests.length, 2);
  assert.equal(remote.workspaceCommit, commit.sha);
  assert.deepEqual(remote.manifest, manifest);
  const snapshot = createSnapshot({ ...remote, generatedAt: NOW });
  assert.equal(snapshot.phase.note, currentRoadmap.phase.note);
  assert.equal(snapshot.roles[0].name, '策划');
  assert.equal(snapshot.source.workspace_commit, snapshot.version.sha);
});

test('missing or invalid workspace content aborts live refresh instead of using old planning data', async () => {
  const commonApi = fakeApi();
  for (const malformed of [false, true]) {
    await assert.rejects(fetchGitHubData({
      includeWorkspace: true,
      fetchImpl: async (url) => {
        const path = new URL(url).pathname;
        if (path.endsWith('/contents/workspace/manifest.json')) return response(manifest);
        if (path.endsWith('/contents/workspace/roadmap.json')) {
          return malformed ? new Response('incomplete JSON', { status: 200 }) : response({}, 404);
        }
        return commonApi(url);
      },
    }), malformed ? /JSON 无效.*roadmap\.json/ : /HTTP 404.*roadmap\.json/);
  }
});

test('HTTP failures are errors; only a missing latest release becomes null', async () => {
  await assert.rejects(
    fetchGitHubData({ fetchImpl: fakeApi({ issueFailure: 503 }) }),
    /HTTP 503/,
  );
  await assert.rejects(
    fetchGitHubData({ fetchImpl: fakeApi({ releaseFailure: 403 }) }),
    /HTTP 403/,
  );
  await assert.rejects(
    fetchGitHubData({ fetchImpl: async () => response({ message: 'not found' }, 404) }),
    /HTTP 404/,
  );
});

test('network failure diagnostics do not expose the supplied token or transport error body', async () => {
  const token = 'fixture-token-not-a-real-credential';
  await assert.rejects(
    fetchGitHubData({
      token,
      fetchImpl: async (_url, options) => {
        assert.equal(options.headers.Authorization, 'Bearer ' + token);
        throw new Error('transport echoed ' + token);
      },
    }),
    (error) => error.message.includes('请求失败') && !error.message.includes(token),
  );
});

test('request deadline also covers a response body that stalls after headers', async () => {
  await assert.rejects(fetchGitHubData({
    timeoutMs: 10,
    fetchImpl: async (_url, options) => ({
      ok: true, status: 200, headers: new Headers(),
      json: () => new Promise((_resolve, reject) => {
        options.signal.addEventListener('abort', () => reject(new Error('body aborted')), { once: true });
      }),
    }),
  }), /响应读取失败/);
});

test('a repeated pagination link fails rather than polling forever', async () => {
  const next = API + '/issues?state=all&per_page=100&page=2';
  const commonApi = fakeApi();
  await assert.rejects(
    fetchGitHubData({
      fetchImpl: async (url) => new URL(url).pathname.endsWith('/issues')
        ? response([issue(1)], 200, { Link: '<' + next + '>; rel="next"' })
        : commonApi(url),
    }),
    /分页重复/,
  );
});

test('snapshot keeps release downloads and deadline timezone semantics', () => {
  const snapshot = createSnapshot({
    repository, commit, issues: [], manifest, roadmap, generatedAt: NOW,
    release: {
      tag_name: 'prep-v1', name: '', html_url: WEB + '/releases/tag/prep-v1',
      published_at: NOW,
      assets: [{ name: 'windows.zip', browser_download_url: WEB + '/releases/download/prep-v1/windows.zip', size: 1024 }],
    },
  });
  assert.equal(snapshot.schema_version, 1);
  assert.equal(snapshot.schedule[0].at, '2026-10-18T16:00:00.000Z');
  assert.equal(snapshot.schedule[0].is_deadline, true);
  assert.equal(snapshot.schedule[0].date_only, false);
  assert.equal(snapshot.release.name, 'prep-v1');
  assert.equal(snapshot.release.assets[0].size, 1024);
  assert.equal(snapshot.version.download_url, WEB + '/archive/' + commit.sha + '.zip');
  assert.deepEqual(snapshot.roles, roles);
  assert.equal(snapshot.source.mode, 'snapshot');
});

test('failed build preserves an existing snapshot and does not publish a fake empty result', async (t) => {
  const fixture = await temporaryFixture(t);
  const original = '{"previous":"known snapshot"}\n';
  await writeFile(fixture.outputPath, original);
  await assert.rejects(buildDashboard({
    ...fixture, token: '', fetchImpl: fakeApi({ issueFailure: 502 }), generatedAt: NOW,
  }), /HTTP 502/);
  assert.equal(await readFile(fixture.outputPath, 'utf8'), original);
  await assert.rejects(access(join(fixture.directory, 'github-data.mjs')));
});

test('a moved main does not attach a newer code version to the checked-out planning snapshot', async (t) => {
  const fixture = await temporaryFixture(t);
  const original = '{"previous":"known snapshot"}\n';
  await writeFile(fixture.outputPath, original);
  await assert.rejects(buildDashboard({
    ...fixture, token: '', fetchImpl: fakeApi(), workspaceCommit: 'b'.repeat(40), generatedAt: NOW,
  }), /main 已变化/);
  assert.equal(await readFile(fixture.outputPath, 'utf8'), original);
  await assert.rejects(access(join(fixture.directory, 'github-data.mjs')));
});

test('successful build produces a usable snapshot and a browser module without credentials', async (t) => {
  const fixture = await temporaryFixture(t);
  const token = 'fixture-token-not-a-real-credential';
  const result = await buildDashboard({
    ...fixture, token, fetchImpl: fakeApi({ issues: [issue(1)] }), generatedAt: NOW, workspaceCommit: commit.sha,
  });
  const snapshotText = await readFile(fixture.outputPath, 'utf8');
  const moduleText = await readFile(join(fixture.directory, 'github-data.mjs'), 'utf8');
  assert.equal(JSON.parse(snapshotText).tasks[0].number, 1);
  assert.equal(result.generated_at, '2026-09-18T08:00:00.000Z');
  assert.equal(result.source.workspace_commit, commit.sha);
  assert.equal(snapshotText.includes(token), false);
  assert.equal(moduleText.includes(token), false);
  assert.equal(moduleText.includes("from 'node:"), false);
  assert.equal(moduleText.includes('process.env'), false);
});
