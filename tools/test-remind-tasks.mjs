import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { resolveTaskDeadline } from './task-deadline.mjs';
import { parseIssueNumbers, selectReminderWindow, makeReminderMarker, buildReminderPlan, hasReminder, createGitHubClient, runReminders } from './remind-tasks.mjs';

const now = new Date('2026-10-15T12:00:00Z');
const roles = [{ id: 'lead', member: 'follerdf', name: '主程序' }];
const issue = (overrides = {}) => ({
  number: 5, title: '工程任务', state: 'open', state_reason: null,
  html_url: 'https://github.com/example/repo/issues/5',
  labels: [{ name: 'role:lead' }, { name: 'phase:production' }], assignees: [],
  updated_at: '2026-10-15T10:00:00Z', closed_at: null,
  body: '截止时间: 2026-10-17T20:00:00+08:00', milestone: null,
  ...overrides,
});
const plan = (overrides, options) => buildReminderPlan(issue(overrides), { roles, now, ...options });

test('截止字段优先，统一为 UTC，支持分钟精度', () => {
  assert.deepEqual(resolveTaskDeadline(issue({ body: '截止时间：2026-10-17T20:00+08:00', milestone: { due_on: '2026-10-19T00:00:00Z' } })), {
    at: '2026-10-17T12:00:00.000Z', source: 'body', error: null,
  });
});
test('无正文字段时使用里程碑，缺失时保持未设置', () => {
  assert.equal(resolveTaskDeadline(issue({ body: '', milestone: { due_on: '2026-10-17T20:00:00Z' } })).source, 'milestone');
  assert.deepEqual(resolveTaskDeadline(issue({ body: null })), { at: null, source: null, error: null });
});
test('重复与空截止字段明确报错，不回退里程碑', () => {
  for (const body of ['截止时间: \n', '截止时间: 2026-10-17T20:00:00Z\n截止时间: 2026-10-17T20:00:00Z']) {
    const result = resolveTaskDeadline(issue({ body, milestone: { due_on: '2026-10-18T00:00:00Z' } }));
    assert.equal(result.at, null); assert.equal(result.source, 'body'); assert.ok(result.error);
  }
});
test('校验真实日历、时区、小时及秒，合法闰日通过', () => {
  for (const value of ['2026-02-29T20:00:00Z', '2026-04-31T20:00:00Z', '2026-10-17T20:00:00', '2026-10-17', '2026-10-17T24:00:00Z', '2026-10-17T20:00:60Z', '2026-10-17T20:00:00+24:00']) {
    assert.ok(resolveTaskDeadline(issue({ body: '截止时间: ' + value })).error, value);
  }
  assert.equal(resolveTaskDeadline(issue({ body: '截止时间: 2028-02-29T20:00:00Z' })).error, null);
  assert.ok(resolveTaskDeadline(issue({ body: '', milestone: { due_on: 'not-a-date' } })).error);
});
test('任务输入为空则自动，明确编号去重，最多 20 个', () => {
  assert.deepEqual(parseIssueNumbers(''), []);
  assert.deepEqual(parseIssueNumbers('5, 7,5'), [5, 7]);
  for (const value of ['0', '-1', '1.1', '4,,5', '4;process.exit()', '9007199254740993', Array.from({ length: 21 }, (_, i) => i + 1).join(',')]) {
    assert.throws(() => parseIssueNumbers(value));
  }
});
test('72h 与 24h 窗口边界准确，晚到只选最近一档', () => {
  const at = '2026-10-18T12:00:00Z';
  assert.equal(selectReminderWindow(at, now), '72h');
  assert.equal(selectReminderWindow(at, new Date('2026-10-15T11:59:59Z')), null);
  assert.equal(selectReminderWindow(at, new Date('2026-10-17T12:00:00Z')), '24h');
  assert.equal(selectReminderWindow(at, new Date('2026-10-18T11:59:59Z')), '24h');
  assert.equal(selectReminderWindow(at, new Date(at)), 'overdue');
  assert.equal(selectReminderWindow(at, new Date('2026-10-19T00:00:00Z')), 'overdue');
});
test('原生指派优先；为空时复用岗位成员；未知岗位不提醒', () => {
  assert.deepEqual(plan({ assignees: [{ login: 'new-owner', html_url: 'https://github.com/new-owner' }] }).logins, ['new-owner']);
  assert.deepEqual(plan().logins, ['follerdf']);
  assert.equal(plan({ labels: [{ name: 'role:qa' }] }).reason, 'unassigned');
});
test('自动任务无截止、无效、逾期、未到期分别跳过', () => {
  assert.equal(plan({ body: '' }).reason, 'no-deadline');
  assert.equal(plan({ body: '截止时间: tomorrow' }).reason, 'invalid-deadline');
  assert.equal(plan({ body: '截止时间: 2026-10-15T12:00:00Z' }).reason, 'overdue');
  assert.equal(plan({ body: '截止时间: 2026-10-25T12:00:00Z' }).reason, 'not-due');
});
test('已完成、已取消、PR 都跳过，手动也不能催已关闭任务', () => {
  assert.equal(plan({ state: 'closed', state_reason: 'completed' }).reason, 'closed');
  assert.equal(plan({ state: 'closed', state_reason: 'not_planned' }, { mode: 'manual' }).reason, 'closed');
  assert.equal(plan({ pull_request: {} }).reason, 'pull-request');
});
test('待验收用协调验收文案；只生成已验证负责人 mentions', () => {
  const review = plan({ labels: ['role:lead', 'status:review'] });
  assert.match(review.body, /请确认验收进展与下一步/);
  assert.doesNotMatch(review.body, /请更新本任务的完成情况/);
  assert.equal(plan({ assignees: [{ login: 'name @other', html_url: 'https://github.com/name' }] }).reason, 'invalid-assignee');
});
test('手动可以提醒未设截止任务，同 UTC 日同成员保持相同标记', () => {
  const first = plan({ body: '' }, { mode: 'manual' });
  const second = plan({}, { mode: 'manual', now: new Date('2026-10-15T23:59:59Z') });
  assert.equal(first.action, 'send'); assert.equal(first.marker, second.marker);
  assert.notEqual(first.marker, plan({}, { mode: 'manual', now: new Date('2026-10-16T00:00:00Z') }).marker);
});
test('自动标记绑定截止档位及负责人集合，成员顺序不影响标记', () => {
  const options = { number: 5, mode: 'auto', deadline: '2026-10-17T12:00:00Z', window: '72h', logins: ['b', 'A'], now };
  const original = makeReminderMarker(options);
  assert.equal(original, makeReminderMarker({ ...options, logins: ['a', 'B'] }));
  for (const change of [{ deadline: '2026-10-18T12:00:00Z' }, { window: '24h' }, { logins: ['a'] }]) {
    assert.notEqual(original, makeReminderMarker({ ...options, ...change }));
  }
});
test('防重只接受当前授权发信人的独立 marker 行', () => {
  const marker = plan().marker;
  assert.equal(hasReminder([{ user: { login: 'stranger' }, body: marker }], marker, 'github-actions[bot]'), false);
  assert.equal(hasReminder([{ user: { login: 'github-actions[bot]' }, body: 'text ' + marker }], marker, 'github-actions[bot]'), false);
  assert.equal(hasReminder([{ user: { login: 'GitHub-Actions[bot]' }, body: 'text\n' + marker }], marker, 'github-actions[bot]'), true);
});

function fakeApi({ initial = issue(), fresh = initial, comments = [], failPost = false } = {}) {
  const calls = [];
  return {
    calls,
    getRoles: async () => roles,
    listIssues: async () => [initial],
    getIssue: async number => { calls.push(['read', number]); return fresh; },
    getUser: async () => ({ login: 'test-sender' }),
    listComments: async number => { calls.push(['comments', number]); return comments; },
    createComment: async (number, body) => {
      calls.push(['post', number, body]);
      if (failPost) throw new Error('结果待核实');
      return { id: 123, user: { login: 'test-sender' }, html_url: 'https://github.com/example/repo/issues/5#issuecomment-123' };
    },
  };
}
test('默认预览只有读操作，未启用发送开关立即中止', async () => {
  const api = fakeApi();
  const result = await runReminders({ api, now: () => now });
  assert.equal(result.results[0].action, 'preview'); assert.deepEqual(api.calls, []);
  await assert.rejects(runReminders({ api, send: true }), /尚未启用/);
});
test('发送前重读：初始开放、后续关闭时不发送', async () => {
  const api = fakeApi({ fresh: issue({ state: 'closed' }) });
  const result = await runReminders({ api, send: true, enabled: true, now: () => now });
  assert.equal(result.results[0].reason, 'closed');
  assert.equal(api.calls.some(([type]) => type === 'post'), false);
});
test('发送前重读新的截止和负责人', async () => {
  const api = fakeApi({ fresh: issue({ body: '截止时间: 2026-10-16T11:00:00Z', assignees: [{ login: 'updated-owner', html_url: 'https://github.com/updated-owner' }] }) });
  const result = await runReminders({ api, send: true, enabled: true, now: () => now });
  assert.equal(result.results[0].window, '24h');
  assert.deepEqual(result.results[0].logins, ['updated-owner']);
  assert.match(api.calls.find(([type]) => type === 'post')[2], /@updated-owner/);
});
test('已有 sender marker 时不重发，外人伪造的 marker 不阻止发送', async () => {
  const marker = plan().marker;
  for (const [login, expected] of [['test-sender', 'skip'], ['stranger', 'sent']]) {
    const api = fakeApi({ comments: [{ user: { login }, body: marker }] });
    const result = await runReminders({ api, send: true, enabled: true, now: () => now });
    assert.equal(result.results[0].action, expected);
  }
});
test('POST 失败不自动重试', async () => {
  const api = fakeApi({ failPost: true });
  await assert.rejects(runReminders({ api, send: true, enabled: true, now: () => now }), /待核实/);
  assert.equal(api.calls.filter(([type]) => type === 'post').length, 1);
});
test('明确编号只读取指定任务，手动提醒不扩展到全队', async () => {
  const api = fakeApi({ initial: issue({ body: '' }) });
  api.listIssues = () => { throw new Error('不得列全队任务'); };
  const result = await runReminders({ api, issueNumbers: [5], now: () => now });
  assert.equal(result.mode, 'manual'); assert.equal(result.results.length, 1);
});
test('API 错误不暴露 token、响应正文、请求正文', async () => {
  const api = createGitHubClient({ repository: 'example/repo', token: 'super-secret-token', fetchImpl: async () => ({ ok: false, status: 403, json: () => ({ message: 'super-secret-token' }) }) });
  await assert.rejects(api.getIssue(5), error => error.message.includes('403') && !error.message.includes('super-secret-token'));
  const uncertain = createGitHubClient({ repository: 'example/repo', fetchImpl: async () => { throw new Error('super-secret-token'); } });
  await assert.rejects(uncertain.createComment(5, 'private-content'), error => /不确定/.test(error.message) && !/super-secret|private-content/.test(error.message));
});

function batchApi({ failAt = 'post', invalidReply = false } = {}) {
  const api = fakeApi();
  api.listIssues = async () => [issue({ number: 4, state: 'closed' }), ...[5, 6, 7].map(number => issue({ number }))];
  api.getIssue = async number => {
    api.calls.push(['read', number]);
    if (number === 6 && failAt === 'read') throw new Error('private-api-response');
    return issue({ number });
  };
  api.listComments = async number => {
    api.calls.push(['comments', number]);
    if (number === 6 && failAt === 'comments') throw new Error('private-api-response');
    return [];
  };
  api.createComment = async number => {
    api.calls.push(['post', number]);
    if (number === 6 && failAt === 'post') {
      if (invalidReply) return { id: 456, user: { login: 'unexpected-sender' } };
      throw new Error('super-secret-token private-request-body');
    }
    return { id: number, user: { login: 'test-sender' }, html_url: `https://github.com/example/repo/issues/${number}#issuecomment-${number}` };
  };
  return api;
}

test('批量中途 POST 不确定：保留跳过与已发送结果，后续任务不尝试', async () => {
  const api = batchApi();
  await assert.rejects(runReminders({ api, send: true, enabled: true, now: () => now }), error => {
    assert.match(error.message, /#6.*待核实/);
    assert.equal(error.report.failed_issue, 6);
    assert.equal(error.report.failure_stage, 'create-comment');
    assert.deepEqual(error.report.results.map(({ number, action }) => [number, action]), [
      [4, 'skip'], [5, 'sent'], [6, 'uncertain'], [7, 'not-attempted'],
    ]);
    assert.match(error.report.results[1].comment_url, /issues\/5#issuecomment-5$/);
    assert.doesNotMatch(JSON.stringify(error.report) + error.message, /super-secret|private-|"body"|"marker"/);
    return true;
  });
  assert.deepEqual(api.calls.filter(([type]) => type === 'post'), [['post', 5], ['post', 6]]);
  assert.equal(api.calls.some(([, number]) => number === 7), false);
});

test('读取评论失败保留此前发送结果，标为 failed，失败与后续任务不发送', async () => {
  const api = batchApi({ failAt: 'comments' });
  await assert.rejects(runReminders({ api, send: true, enabled: true, now: () => now }), error => {
    assert.match(error.message, /#6.*尚未尝试发送/);
    assert.equal(error.report.failure_stage, 'read-comments');
    assert.equal(error.report.results[1].action, 'sent');
    assert.equal(error.report.results[2].action, 'failed');
    assert.equal(error.report.results[3].action, 'not-attempted');
    assert.doesNotMatch(JSON.stringify(error.report) + error.message, /private-api-response/);
    return true;
  });
  assert.deepEqual(api.calls.filter(([type]) => type === 'post'), [['post', 5]]);
});

test('手动任务首次读取失败可定位编号，并停止读取后续任务', async () => {
  const api = batchApi({ failAt: 'read' });
  await assert.rejects(runReminders({ api, issueNumbers: [5, 6, 7], send: true, enabled: true, now: () => now }), error => {
    assert.equal(error.report.failed_issue, 6);
    assert.equal(error.report.failure_stage, 'read-issue');
    assert.deepEqual(error.report.results.map(({ number, action }) => [number, action]), [[5, 'sent'], [6, 'failed'], [7, 'not-attempted']]);
    return true;
  });
  assert.equal(api.calls.some(([, number]) => number === 7), false);
  assert.deepEqual(api.calls.filter(([type]) => type === 'post'), [['post', 5]]);
});

test('评论响应身份不符也标为 uncertain，保留前项结果且不继续', async () => {
  const api = batchApi({ invalidReply: true });
  await assert.rejects(runReminders({ api, send: true, enabled: true, now: () => now }), error => {
    assert.equal(error.report.failure_stage, 'confirm-comment');
    assert.equal(error.report.results[2].action, 'uncertain');
    return true;
  });
  assert.deepEqual(api.calls.filter(([type]) => type === 'post'), [['post', 5], ['post', 6]]);
});

test('CLI 批量失败以非零退出，stdout 保留部分 JSON，stderr 明确任务且无敏感请求信息', () => {
  const entry = fileURLToPath(new URL('./remind-tasks.mjs', import.meta.url));
  const script = `
    const baseIssue = ${JSON.stringify(issue({ body: '' }))};
    globalThis.fetch = async (url, options = {}) => {
      const path = new URL(url).pathname;
      let data;
      if (path.endsWith('/contents/workspace/manifest.json')) data = { roles: ${JSON.stringify(roles)} };
      else if (path === '/user') data = { login: 'test-sender' };
      else {
        const match = path.match(/\\/issues\\/(\\d+)(\\/comments)?$/);
        if (!match) throw new Error('unexpected URL');
        const number = Number(match[1]);
        if (!match[2]) data = { ...baseIssue, number };
        else if (options.method === 'POST') {
          if (number === 6) throw new Error('super-secret-token private-request-body');
          data = { id: number, user: { login: 'test-sender' }, html_url: 'https://github.com/example/repo/issues/' + number + '#issuecomment-' + number };
        } else data = [];
      }
      return { ok: true, json: async () => data };
    };
    process.argv = [process.execPath, ${JSON.stringify(entry)}, '--issues', '5,6,7', '--send'];
    await import(${JSON.stringify(new URL('./remind-tasks.mjs', import.meta.url).href)});
  `;
  const result = spawnSync(process.execPath, ['--input-type=module', '-e', script], {
    encoding: 'utf8', windowsHide: true, timeout: 10000,
    env: { ...process.env, GH_TOKEN: 'super-secret-token', GITHUB_ACTIONS: 'false', GITHUB_REPOSITORY: 'example/repo', TASK_REMINDERS_ENABLED: 'true', REMINDER_ISSUE_NUMBERS: '' },
  });
  assert.equal(result.error, undefined);
  assert.equal(result.status, 1);
  const report = JSON.parse(result.stdout);
  assert.equal(report.stopped, true);
  assert.deepEqual(report.results.map(({ number, action }) => [number, action]), [[5, 'sent'], [6, 'uncertain'], [7, 'not-attempted']]);
  assert.match(result.stderr, /#6.*待核实/);
  assert.doesNotMatch(result.stdout + result.stderr, /super-secret|private-request|"body"|"marker"/);
});
