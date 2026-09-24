import { resolveTaskResponsibility } from './github-data.mjs';

const OPEN_STATUSES = new Set(['todo', 'doing', 'review']);

/** Count normalized tasks once; cancelled work never enters the completion ratio. */
export function summarizeTasks(tasks) {
  const summary = { todo: 0, doing: 0, review: 0, done: 0, cancelled: 0 };
  for (const task of tasks) {
    if (!Object.hasOwn(summary, task.status)) {
      throw new Error(`任务 #${task.number} 的状态无效：${task.status}`);
    }
    summary[task.status] += 1;
  }
  summary.open = summary.todo + summary.doing + summary.review;
  summary.total = summary.open + summary.done;
  summary.percent = summary.total ? Math.round(summary.done / summary.total * 100) : null;
  return summary;
}

/**
 * Summarize responsibility across one whole phase. Pass the unfiltered task list:
 * task-search and status tabs must not hide a member's remaining work.
 * A task with multiple assignees belongs to each member; the overall summary
 * still counts it once. Role membership is a fallback only when assignees are empty.
 */
export function summarizeTeam(tasks, roles, { phase = 'all' } = {}) {
  if (!['all', 'preparation', 'production'].includes(phase)) {
    throw new Error(`无效的任务阶段：${phase}`);
  }
  const scoped = phase === 'all' ? tasks : tasks.filter(task => task.phase === phase);
  const people = new Map();
  const unregisteredRoles = [];
  const unassignedTasks = [];

  for (const role of roles) {
    const login = typeof role.member === 'string' ? role.member.trim() : '';
    if (!login) {
      const roleTasks = scoped.filter(task => task.roles.includes(role.id));
      unregisteredRoles.push({ ...role, tasks: roleTasks, summary: summarizeTasks(roleTasks) });
      continue;
    }
    const key = login.toLowerCase();
    if (!people.has(key)) people.set(key, { login, known: true, roles: [], tasks: [] });
    people.get(key).roles.push(role);
  }

  for (const task of scoped) {
    const { logins } = resolveTaskResponsibility(task, roles);
    if (!logins.length && OPEN_STATUSES.has(task.status)) unassignedTasks.push(task);
    for (const login of logins) {
      const key = login.toLowerCase();
      if (!people.has(key)) people.set(key, { login, known: false, roles: [], tasks: [] });
      people.get(key).tasks.push(task);
    }
  }

  const members = [...people.values()].map(person => {
    const summary = summarizeTasks(person.tasks);
    const status = summary.open ? 'pending' : person.tasks.length ? 'clear' : 'unassigned';
    return { ...person, status, summary };
  });

  return { phase, members, unregisteredRoles, unassignedTasks, summary: summarizeTasks(scoped) };
}
