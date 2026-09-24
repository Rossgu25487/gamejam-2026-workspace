// Shared by Node and the browser. This module has no filesystem or environment access.
import { resolveTaskDeadline } from './task-deadline.mjs';
export const DEFAULT_REPOSITORY = 'Rossgu25487/gamejam-2026-workspace';
const API_ROOT = 'https://api.github.com';
const API_VERSION = '2026-03-10';

function object(value, label) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error(label + ' 应为对象。');
  }
  return value;
}

function text(value, label, allowEmpty = false) {
  if (typeof value !== 'string' || (!allowEmpty && !value.trim())) {
    throw new Error(label + ' 缺少有效文本。');
  }
  return value;
}

function isoTime(value, label) {
  text(value, label);
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/i.test(value)) {
    throw new Error(label + ' 需要包含时区的 ISO 时间。');
  }
  const date = new Date(value);
  if (!Number.isFinite(date.getTime())) throw new Error(label + ' 时间无效。');
  return date.toISOString();
}

function boolean(value, label) {
  if (typeof value !== 'boolean') throw new Error(label + ' 应为布尔值。');
  return value;
}

function normalizeRoles(manifest) {
  object(manifest, '岗位清单');
  if (!Array.isArray(manifest.roles) || manifest.roles.length === 0) {
    throw new Error('岗位清单需要非空 roles 数组。');
  }
  const seen = new Set();
  return manifest.roles.map((role) => {
    object(role, '岗位');
    const id = text(role.id, '岗位 id');
    if (seen.has(id)) throw new Error('岗位 id 重复：' + id);
    seen.add(id);
    const normalized = { id, name: text(role.name, '岗位名称') };
    if (role.member != null) {
      const member = text(role.member, '岗位负责人', true).trim();
      if (member) normalized.member = member;
    }
    if (role.workflow) normalized.workflow = text(role.workflow, '岗位工作流');
    return normalized;
  });
}

export function resolveTaskResponsibility(task, roles = []) {
  function uniqueLogins(values) {
    const seen = new Set();
    return values.filter((value) => typeof value === 'string' && value.trim())
      .map((value) => value.trim()).filter((login) => {
        const key = login.toLowerCase();
        if (seen.has(key)) return false;
        seen.add(key);
        return true;
      });
  }
  const assigned = uniqueLogins(task.assignees.map((assignee) => assignee.login));
  if (assigned.length) return { source: 'assignees', logins: assigned };
  const members = new Map(roles.map((role) => [role.id, role.member]));
  const known = uniqueLogins(task.roles.map((roleId) => members.get(roleId)));
  return { source: known.length ? 'role_members' : 'unassigned', logins: known };
}

// The overview and list share this scope; status tabs are applied afterwards.
export function filterTasks(tasks, filters, roles = []) {
  const roleNames = new Map(roles.map(role => [role.id, role.name]));
  const words = (filters.query || '').trim().toLocaleLowerCase().split(/\s+/).filter(Boolean);
  return tasks.filter(task => {
    if (filters.role !== 'all' && !task.roles.includes(filters.role)) return false;
    if (filters.phase !== 'all' && task.phase !== filters.phase) return false;
    const responsibility = resolveTaskResponsibility(task, roles);
    const haystack = [task.title, `#${task.number}`, task.milestone || '',
      ...responsibility.logins.map(login => `@${login}`),
      ...task.roles.map(id => roleNames.get(id) || id)].join(' ').toLocaleLowerCase();
    return words.every(word => word.startsWith('@')
      ? responsibility.logins.some(login => login.toLocaleLowerCase() === word.slice(1))
      : haystack.includes(word));
  });
}

export function readTaskFilters(search, { roles, defaultPhase, rememberedRole = 'all' }) {
  const params = new URLSearchParams(search);
  const roleIds = new Set(['all', ...roles.map(role => role.id)]);
  const role = params.get('role') ?? rememberedRole;
  const phase = params.get('phase') ?? defaultPhase;
  const status = params.get('status') ?? 'open';
  return {
    role: roleIds.has(role) ? role : 'all',
    phase: ['all', 'preparation', 'production'].includes(phase) ? phase : defaultPhase,
    status: ['open', 'todo', 'doing', 'review', 'done', 'all'].includes(status) ? status : 'open',
    query: (params.get('q') || '').trim(),
  };
}

function normalizeRoadmap(roadmap) {
  object(roadmap, '排期');
  object(roadmap.phase, '当前阶段');
  if (!Array.isArray(roadmap.schedule)) throw new Error('排期需要 schedule 数组。');
  const seen = new Set();
  const schedule = roadmap.schedule.map((entry) => {
    object(entry, '排期项');
    const id = text(entry.id, '排期 id');
    if (seen.has(id)) throw new Error('排期 id 重复：' + id);
    seen.add(id);
    if (!['confirmed', 'suggested'].includes(entry.kind)) {
      throw new Error('排期 ' + id + ' 的 kind 需要 confirmed 或 suggested。');
    }
    const normalized = {
      id,
      title: text(entry.title, '排期标题'),
      at: isoTime(entry.at, '排期 ' + id),
      date_only: boolean(entry.date_only, '排期 date_only'),
      kind: entry.kind,
      note: text(entry.note ?? '', '排期说明', true),
      source_url: text(entry.source_url ?? '', '排期来源', true),
    };
    if (Object.hasOwn(entry, 'is_deadline')) {
      normalized.is_deadline = boolean(entry.is_deadline, '排期 is_deadline');
    }
    return normalized;
  });
  return {
    phase: {
      id: text(roadmap.phase.id, '阶段 id'),
      label: text(roadmap.phase.label, '阶段名称'),
      note: text(roadmap.phase.note ?? '', '阶段说明', true),
    },
    schedule,
  };
}

export function normalizeIssues(issues, roles) {
  if (!Array.isArray(issues)) throw new Error('GitHub Issues 响应需要数组。');
  const roleIds = new Set(roles.map((role) => role.id));
  const notes = [];
  const tasks = [];
  let missingPhase = 0;

  for (const issue of issues) {
    object(issue, 'GitHub Issue');
    if (Object.hasOwn(issue, 'pull_request')) continue;
    if (!Number.isInteger(issue.number) || issue.number < 1) {
      throw new Error('GitHub Issue 缺少有效编号。');
    }
    if (!['open', 'closed'].includes(issue.state)) {
      throw new Error('Issue #' + issue.number + ' 的开关状态无效。');
    }
    if (!Array.isArray(issue.labels) || !Array.isArray(issue.assignees)) {
      throw new Error('Issue #' + issue.number + ' 缺少标签或负责人数组。');
    }
    const labels = new Set(issue.labels.map((label) =>
      typeof label === 'string' ? label : text(object(label, '标签').name, '标签名')));
    const status = issue.state === 'closed'
      ? (issue.state_reason === 'not_planned' ? 'cancelled' : 'done')
      : labels.has('status:review') ? 'review'
        : labels.has('status:doing') ? 'doing' : 'todo';
    if (labels.has('status:review') && labels.has('status:doing')) {
      notes.push('Issue #' + issue.number + ' 同时带有 doing/review 标签，按 ' + status + ' 展示。');
    }
    const phase = labels.has('phase:production') ? 'production' : 'preparation';
    if (!labels.has('phase:production') && !labels.has('phase:preparation')) {
      missingPhase += 1;
    } else if (labels.has('phase:production') && labels.has('phase:preparation')) {
      notes.push('Issue #' + issue.number + ' 同时带有两个阶段标签，按 production 展示。');
    }
    const taskRoles = [];
    for (const label of labels) {
      if (!label.startsWith('role:')) continue;
      const id = label.slice(5);
      if (roleIds.has(id)) taskRoles.push(id);
      else notes.push('Issue #' + issue.number + ' 的岗位标签 ' + label + ' 不在岗位清单中。');
    }
    const task = {
      number: issue.number,
      title: text(issue.title, 'Issue 标题'),
      url: text(issue.html_url, 'Issue 地址'),
      status,
      phase,
      roles: taskRoles,
      assignees: issue.assignees.map((assignee) => ({
        login: text(object(assignee, '负责人').login, '负责人登录名'),
        url: text(assignee.html_url, '负责人地址'),
      })),
      updated_at: isoTime(issue.updated_at, 'Issue 更新时间'),
      closed_at: issue.closed_at == null ? null : isoTime(issue.closed_at, 'Issue 关闭时间'),
      milestone: issue.milestone == null
        ? null : text(object(issue.milestone, '里程碑').title, '里程碑名称'),
      deadline: resolveTaskDeadline(issue),
    };
    tasks.push(task);
  }
  if (missingPhase > 0) {
    notes.push(missingPhase + ' 个未标有效阶段的 Issue 按 preparation 展示。');
  }
  tasks.sort((left, right) => left.number - right.number);
  return { tasks, notes };
}

function normalizeRelease(release) {
  if (release === null) return null;
  object(release, 'GitHub Release');
  if (!Array.isArray(release.assets)) throw new Error('Release 缺少 assets 数组。');
  const tag = text(release.tag_name, 'Release tag');
  return {
    tag,
    name: release.name ? text(release.name, 'Release 名称') : tag,
    url: text(release.html_url, 'Release 地址'),
    published_at: isoTime(release.published_at, 'Release 发布时间'),
    assets: release.assets.map((asset) => {
      object(asset, 'Release 附件');
      if (!Number.isSafeInteger(asset.size) || asset.size < 0) {
        throw new Error('Release 附件缺少有效大小。');
      }
      return {
        name: text(asset.name, '附件名称'),
        url: text(asset.browser_download_url, '附件下载地址'),
        size: asset.size,
      };
    }),
  };
}

export function createSnapshot({
  repository, commit, issues, release, manifest, roadmap,
  generatedAt = new Date().toISOString(),
  workspaceCommit,
}) {
  object(repository, 'GitHub 仓库');
  object(commit, 'GitHub Commit');
  object(commit.commit, 'Commit 内容');
  object(commit.commit.committer, 'Commit 提交时间');
  const roles = normalizeRoles(manifest);
  const { phase, schedule } = normalizeRoadmap(roadmap);
  const { tasks, notes } = normalizeIssues(issues, roles);
  const sha = text(commit.sha, 'Commit SHA');
  const repositoryUrl = text(repository.html_url, '仓库地址').replace(/\/$/, '');
  const snapshot = {
    schema_version: 1,
    generated_at: isoTime(generatedAt, '快照生成时间'),
    repository: {
      full_name: text(repository.full_name, '仓库名称'),
      url: repositoryUrl,
      default_branch: text(repository.default_branch, '默认分支'),
    },
    phase,
    version: {
      sha,
      short_sha: sha.slice(0, 7),
      committed_at: isoTime(commit.commit.committer.date, 'Commit 提交时间'),
      message: text(commit.commit.message, 'Commit 信息'),
      url: text(commit.html_url, 'Commit 地址'),
      download_url: repositoryUrl + '/archive/' + encodeURIComponent(sha) + '.zip',
    },
    release: normalizeRelease(release),
    tasks,
    schedule,
    roles,
    source: { mode: 'snapshot' },
  };
  if (workspaceCommit) snapshot.source.workspace_commit = text(workspaceCommit, '排期与岗位来源提交');
  if (notes.length > 0) snapshot.source.note = notes.join(' ');
  return snapshot;
}

function nextPage(linkHeader) {
  if (!linkHeader) return null;
  for (const part of linkHeader.split(',')) {
    const match = part.match(/<([^>]+)>\s*;\s*rel="([^"]+)"/);
    if (match && match[2].split(/\s+/).includes('next')) return match[1];
  }
  return null;
}

export async function fetchGitHubData({
  repository = DEFAULT_REPOSITORY,
  token = '',
  fetchImpl = globalThis.fetch,
  timeoutMs = 15000,
  includeWorkspace = false,
} = {}) {
  if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(repository)) {
    throw new Error('仓库需要 owner/name 格式。');
  }
  const base = '/repos/' + repository.split('/').map(encodeURIComponent).join('/');
  const headers = {
    Accept: 'application/vnd.github+json',
    'X-GitHub-Api-Version': API_VERSION,
  };
  // Only server-side callers should supply a token. It is never returned or logged.
  if (token) headers.Authorization = 'Bearer ' + token;

  async function request(url, allowMissing = false, accept = headers.Accept) {
    const target = new URL(url, API_ROOT);
    if (target.origin !== API_ROOT) throw new Error('分页地址不属于 GitHub API。');
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);
    try {
      let response;
      try {
        response = await fetchImpl(target.href, { headers: { ...headers, Accept: accept }, signal: controller.signal });
      } catch {
        throw new Error('GitHub 请求失败或超时：' + target.pathname + '。未生成新的快照。');
      }
      if (allowMissing && response.status === 404) return { data: null, next: null };
      if (!response.ok) {
        throw new Error('GitHub HTTP ' + response.status + '：' + target.pathname +
          '。请检查仓库访问和 API 限额；未生成新的快照。');
      }
      let data;
      try {
        data = await response.json();
      } catch {
        throw new Error('GitHub 响应读取失败或 JSON 无效：' + target.pathname + '。未生成新的快照。');
      }
      return { data, next: nextPage(response.headers.get('link')) };
    } finally {
      clearTimeout(timer);
    }
  }

  // Verify repository access before treating a release 404 as "no published release".
  const repositoryData = (await request(base)).data;
  async function allIssues() {
    let next = API_ROOT + base + '/issues?state=all&per_page=100&sort=created&direction=asc';
    const visited = new Set();
    const issues = [];
    while (next) {
      if (visited.has(next)) throw new Error('GitHub Issues 分页重复，已停止构建。');
      visited.add(next);
      const page = await request(next);
      if (!Array.isArray(page.data)) throw new Error('GitHub Issues 分页响应需要数组。');
      issues.push(...page.data);
      next = page.next;
    }
    return issues;
  }
  const [commitResult, issues, releaseResult] = await Promise.all([
    request(base + '/commits/main'),
    allIssues(),
    request(base + '/releases/latest', true),
  ]);
  const result = {
    repository: repositoryData,
    commit: commitResult.data,
    issues,
    release: releaseResult.data,
  };
  if (includeWorkspace) {
    // Both files must match the already-read main commit, even if main moves meanwhile.
    const ref = text(object(commitResult.data, 'GitHub Commit').sha, 'Commit SHA');
    const accept = 'application/vnd.github.raw+json';
    const suffix = '?ref=' + encodeURIComponent(ref);
    const [manifestResult, roadmapResult] = await Promise.all([
      request(base + '/contents/workspace/manifest.json' + suffix, false, accept),
      request(base + '/contents/workspace/roadmap.json' + suffix, false, accept),
    ]);
    result.manifest = manifestResult.data;
    result.roadmap = roadmapResult.data;
    result.workspaceCommit = ref;
  }
  return result;
}
