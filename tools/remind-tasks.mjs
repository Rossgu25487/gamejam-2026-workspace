import { pathToFileURL } from 'node:url';
import { normalizeIssues, resolveTaskResponsibility, DEFAULT_REPOSITORY } from './dashboard-data.mjs';
import { resolveTaskDeadline } from './task-deadline.mjs';

const API_ROOT = 'https://api.github.com';
const HOUR = 60 * 60 * 1000;
const LOGIN = /^[a-z\d](?:[a-z\d-]{0,37}[a-z\d])?$/i;

export function parseIssueNumbers(value = '') {
  if (!String(value).trim()) return [];
  const parts = String(value).split(',').map(part => part.trim());
  if (parts.length > 20 || parts.some(part => !/^[1-9]\d*$/.test(part) || !Number.isSafeInteger(Number(part)))) {
    throw new Error('任务编号须为最多 20 个正整数，以英文逗号分隔。');
  }
  return [...new Set(parts.map(Number))];
}

export function selectReminderWindow(at, now = new Date()) {
  const remaining = Date.parse(at) - new Date(now).getTime();
  if (!Number.isFinite(remaining)) return null;
  if (remaining <= 0) return 'overdue';
  if (remaining <= 24 * HOUR) return '24h';
  if (remaining <= 72 * HOUR) return '72h';
  return null;
}

export function makeReminderMarker({ number, mode, deadline, window, logins, now }) {
  const recipients = [...new Set(logins.map(login => login.toLowerCase()))].sort().join(',');
  const slot = mode === 'manual' ? `manual:${new Date(now).toISOString().slice(0, 10)}` : `${deadline}:${window}`;
  return `<!-- gamejam-reminder:v1:${number}:${slot}:${recipients} -->`;
}

function localDeadline(at) {
  return new Intl.DateTimeFormat('zh-CN', {
    timeZone: 'Asia/Shanghai', year: 'numeric', month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit', hourCycle: 'h23',
  }).format(new Date(at)) + '（北京时间）';
}

export function buildReminderPlan(issue, { roles = [], mode = 'auto', now = new Date() } = {}) {
  if (!['auto', 'manual'].includes(mode)) throw new Error('提醒模式无效。');
  const base = { number: issue.number, action: 'skip' };
  if (Object.hasOwn(issue, 'pull_request')) return { ...base, reason: 'pull-request' };
  if (issue.state === 'closed') return { ...base, reason: 'closed' };
  const { tasks: [task] } = normalizeIssues([issue], roles);
  const deadline = resolveTaskDeadline(issue);
  if (deadline.error) return { ...base, reason: 'invalid-deadline', detail: deadline.error };
  const { logins, source } = resolveTaskResponsibility(task, roles);
  if (!logins.length) return { ...base, reason: 'unassigned' };
  if (logins.some(login => !LOGIN.test(login))) return { ...base, reason: 'invalid-assignee' };
  let window = 'manual';
  if (mode === 'auto') {
    if (!deadline.at) return { ...base, reason: 'no-deadline' };
    window = selectReminderWindow(deadline.at, now);
    if (window === 'overdue') return { ...base, reason: 'overdue', deadline: deadline.at };
    if (!window) return { ...base, reason: 'not-due', deadline: deadline.at };
  }
  const marker = makeReminderMarker({ number: issue.number, mode, deadline: deadline.at, window, logins, now });
  const prompt = task.status === 'review'
    ? '请确认验收进展与下一步；如需其他成员验收，请协调接手并在本任务中说明。'
    : '请更新本任务的完成情况、交付位置或当前阻碍；已经完成的内容请按验收要求更新状态。';
  const heading = mode === 'manual' ? '任务进展提醒' : window === '72h' ? '截止前 3 天提醒' : '截止前 24 小时提醒';
  const timing = deadline.at ? `任务截止：${localDeadline(deadline.at)}。` : '当前尚未设置任务截止时间。';
  return {
    number: issue.number, action: 'send', mode, window, deadline: deadline.at,
    logins, responsibility_source: source, marker,
    body: `${logins.map(login => '@' + login).join(' ')}\n\n**${heading}**\n\n${timing}\n\n${prompt}\n\n${marker}`,
  };
}

export function hasReminder(comments, marker, senderLogin) {
  return comments.some(comment => comment.user?.login?.toLowerCase() === senderLogin.toLowerCase()
    && String(comment.body ?? '').split(/\r?\n/).some(line => line.trim() === marker));
}

export function createGitHubClient({ repository = DEFAULT_REPOSITORY, token = '', fetchImpl = globalThis.fetch } = {}) {
  if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(repository)) throw new Error('仓库需要 owner/name 格式。');
  const base = '/repos/' + repository;
  const headers = { Accept: 'application/vnd.github+json', 'X-GitHub-Api-Version': '2026-03-10' };
  if (token) headers.Authorization = 'Bearer ' + token;

  async function request(path, { method = 'GET', body, accept } = {}) {
    const url = new URL(path, API_ROOT);
    if (url.origin !== API_ROOT) throw new Error('API 地址必须属于 GitHub。');
    let response;
    try {
      response = await fetchImpl(url, {
        method, headers: { ...headers, ...(accept ? { Accept: accept } : {}), ...(body ? { 'Content-Type': 'application/json' } : {}) },
        ...(body ? { body: JSON.stringify(body) } : {}), signal: AbortSignal.timeout(20000),
      });
    } catch {
      throw new Error(method === 'POST' ? '评论创建结果不确定；请先查看 Issue 评论，不要自动重试。' : 'GitHub 请求失败或超时。');
    }
    if (!response.ok) throw new Error(`GitHub HTTP ${response.status}。` + (method === 'POST' ? '未确认创建成功，请先查看 Issue 评论。' : '请检查权限和 API 限额。'));
    try { return await response.json(); }
    catch { throw new Error(method === 'POST' ? '评论响应无法读取，创建结果待核实；请先查看 Issue 评论。' : 'GitHub 返回了无效 JSON。'); }
  }

  async function list(path) {
    const output = [];
    for (let page = 1; ; page++) {
      const data = await request(`${path}${path.includes('?') ? '&' : '?'}per_page=100&page=${page}`);
      if (!Array.isArray(data)) throw new Error('GitHub 列表响应无效。');
      output.push(...data);
      if (data.length < 100) return output;
    }
  }
  return {
    listIssues: () => list(base + '/issues?state=open'),
    getIssue: number => request(`${base}/issues/${number}`),
    listComments: number => list(`${base}/issues/${number}/comments`),
    createComment: (number, body) => request(`${base}/issues/${number}/comments`, { method: 'POST', body: { body } }),
    getUser: () => request('/user'),
    getRoles: async () => {
      const manifest = await request(base + '/contents/workspace/manifest.json', { accept: 'application/vnd.github.raw+json' });
      if (!Array.isArray(manifest?.roles)) throw new Error('岗位清单无效。');
      return manifest.roles;
    },
  };
}

function stoppedRun({ mode, send, results, number = null, stage, pending = [], uncertain = false }) {
  const target = number == null ? '提醒运行' : `任务 #${number}`;
  const error = new Error(uncertain
    ? `${target} 的评论创建结果待核实；本次运行已停止，请先查看该 Issue 评论，不要自动重试。`
    : `${target} 在 ${stage} 阶段失败；本次运行已停止，失败任务尚未尝试发送。`);
  // Keep useful recovery evidence without including request bodies or raw API errors.
  const summaries = results.map(({ body, marker, ...summary }) => summary);
  error.report = {
    mode, send, stopped: true, failed_issue: number, failure_stage: stage,
    results: [
      ...summaries,
      { number, action: uncertain ? 'uncertain' : 'failed', stage },
      ...pending.map(issue => ({ number: issue.number, action: 'not-attempted', reason: 'run-stopped' })),
    ],
  };
  return error;
}

export async function runReminders({ api, issueNumbers = [], send = false, enabled = false, senderLogin = '', now = () => new Date() }) {
  if (send && !enabled) throw new Error('发送尚未启用。需要 TASK_REMINDERS_ENABLED=true 和 --send 同时生效。');
  if (issueNumbers.length > 20 || issueNumbers.some(number => !Number.isSafeInteger(number) || number < 1)) throw new Error('任务编号无效或超过 20 个。');
  const mode = issueNumbers.length ? 'manual' : 'auto';
  const results = [];
  let roles, sender;
  let issues = [...new Set(issueNumbers)].map(number => ({ number }));
  let stage = 'read-roles';
  try {
    roles = await api.getRoles();
    stage = 'list-issues';
    if (!issueNumbers.length) issues = await api.listIssues();
    stage = 'confirm-sender';
    sender = send ? senderLogin || (await api.getUser()).login : '';
    if (send && (!sender || typeof sender !== 'string')) throw new Error('无法确认当前发信身份。');
  } catch {
    throw stoppedRun({ mode, send, results, stage, pending: issues });
  }
  for (const [index, selectedIssue] of issues.entries()) {
    const number = selectedIssue.number;
    let attemptedPost = false;
    try {
      stage = 'read-issue';
      const issue = mode === 'manual' ? await api.getIssue(number) : selectedIssue;
      stage = 'plan';
      let plan = buildReminderPlan(issue, { roles, mode, now: now() });
      if (plan.action === 'skip') { results.push(plan); continue; }
      if (!send) { results.push({ ...plan, action: 'preview' }); continue; }
      stage = 'read-comments';
      const comments = await api.listComments(number);
      // Read the issue after comment pagination, immediately before deciding whether to write.
      // Never send from a saved dashboard snapshot.
      stage = 'recheck-roles';
      const freshRoles = await api.getRoles();
      stage = 'recheck-issue';
      const freshIssue = await api.getIssue(number);
      stage = 'recheck-plan';
      plan = buildReminderPlan(freshIssue, { roles: freshRoles, mode, now: now() });
      if (plan.action === 'skip') { results.push(plan); continue; }
      stage = 'check-duplicate';
      if (hasReminder(comments, plan.marker, sender)) {
        results.push({ ...plan, action: 'skip', reason: 'already-reminded' });
        continue;
      }
      stage = 'create-comment';
      attemptedPost = true;
      const comment = await api.createComment(number, plan.body);
      stage = 'confirm-comment';
      if (!comment?.id || comment.user?.login?.toLowerCase() !== sender.toLowerCase()) {
        throw new Error('评论返回身份或编号未通过核对。');
      }
      results.push({ ...plan, action: 'sent', comment_url: comment.html_url });
    } catch {
      throw stoppedRun({ mode, send, results, number, stage, pending: issues.slice(index + 1), uncertain: attemptedPost });
    }
  }
  return { mode, send, results };
}

function cliOptions(args, env) {
  const options = { repository: env.GITHUB_REPOSITORY || DEFAULT_REPOSITORY, issueNumbers: parseIssueNumbers(env.REMINDER_ISSUE_NUMBERS || ''), send: false };
  for (let index = 0; index < args.length; index++) {
    const argument = args[index];
    if (argument === '--send') options.send = true;
    else if (argument === '--issues' || argument === '--repository') {
      const value = args[++index];
      if (value == null || value.startsWith('--')) throw new Error(argument + ' 缺少参数值。');
      if (argument === '--issues') options.issueNumbers = parseIssueNumbers(value);
      else options.repository = value;
    }
    else throw new Error('未知参数。可用 --issues 4,7、--repository owner/name、--send。');
  }
  return options;
}

async function main() {
  const options = cliOptions(process.argv.slice(2), process.env);
  const token = process.env.GH_TOKEN || process.env.GITHUB_TOKEN || '';
  if (options.send && !token) throw new Error('发送需要环境变量 GH_TOKEN 或 GITHUB_TOKEN。');
  const senderLogin = process.env.GITHUB_ACTIONS === 'true' ? process.env.REMINDER_SENDER_LOGIN || '' : '';
  const report = await runReminders({
    ...options, api: createGitHubClient({ repository: options.repository, token }),
    enabled: process.env.TASK_REMINDERS_ENABLED === 'true', senderLogin,
  });
  process.stdout.write(JSON.stringify(report, null, 2) + '\n');
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch(error => {
    if (error.report) process.stdout.write(JSON.stringify(error.report, null, 2) + '\n');
    process.stderr.write(error.message + '\n');
    process.exitCode = 1;
  });
}
