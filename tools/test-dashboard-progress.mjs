import test from 'node:test';
import assert from 'node:assert/strict';
import { summarizeTasks, summarizeTeam } from './dashboard-progress.mjs';

const roles = [
  { id: 'planner', name: '策划', member: 'Captain' },
  { id: 'lead', name: '主程序', member: 'Programmer' },
  { id: 'gameplay', name: '副程序 A', member: 'programmer' },
  { id: 'ui_art', name: '美术 A', member: 'Artist' },
  { id: 'visual_art', name: '美术 B', member: 'OtherArtist' },
  { id: 'qa', name: '测试' },
];

function task(number, overrides = {}) {
  return {
    number, title: `任务 ${number}`, status: 'todo', phase: 'preparation',
    roles: [], assignees: [], ...overrides,
  };
}

function member(result, login) {
  return result.members.find(item => item.login.toLowerCase() === login.toLowerCase());
}

test('completion separates open states, excludes cancellation and does not invent zero-task progress', () => {
  assert.deepEqual(summarizeTasks([
    task(1), task(2, { status: 'doing' }), task(3, { status: 'review' }),
    task(4, { status: 'done' }), task(5, { status: 'cancelled' }),
  ]), { todo: 1, doing: 1, review: 1, done: 1, cancelled: 1, open: 3, total: 4, percent: 25 });
  assert.equal(summarizeTasks([]).percent, null);
  assert.equal(summarizeTasks([task(1, { status: 'cancelled' })]).percent, null);
  assert.throws(() => summarizeTasks([task(1, { status: 'unknown' })]), /状态无效/);
});

test('native assignee owns a cross-role assignment; role member is not also charged', () => {
  const result = summarizeTeam([
    task(1, { roles: ['lead'], assignees: [{ login: 'Captain' }] }),
    task(2, { roles: ['lead'] }),
  ], roles);
  assert.deepEqual(member(result, 'Captain').tasks.map(item => item.number), [1]);
  assert.deepEqual(member(result, 'Programmer').tasks.map(item => item.number), [2]);
  assert.equal(result.summary.open, 2);
});

test('same account across roles and case variants remains one member and one task entry', () => {
  const result = summarizeTeam([
    task(1, { roles: ['lead', 'gameplay'] }),
    task(2, { assignees: [{ login: 'PROGRAMMER' }, { login: 'programmer' }] }),
  ], roles);
  assert.equal(result.members.filter(item => item.login.toLowerCase() === 'programmer').length, 1);
  assert.deepEqual(member(result, 'Programmer').roles.map(role => role.id), ['lead', 'gameplay']);
  assert.equal(member(result, 'Programmer').summary.open, 2);
});

test('multiple assignees share responsibility while overall task totals count each task once', () => {
  const result = summarizeTeam([
    task(1, { assignees: [{ login: 'Captain' }, { login: 'Artist' }, { login: 'NewMember' }] }),
    task(2, { assignees: [{ login: 'newmember' }], status: 'done' }),
  ], roles);
  assert.equal(member(result, 'Captain').summary.open, 1);
  assert.equal(member(result, 'Artist').summary.open, 1);
  assert.equal(member(result, 'NewMember').known, false);
  assert.equal(member(result, 'NewMember').roles.length, 0);
  assert.equal(member(result, 'NewMember').summary.total, 2);
  assert.equal(result.members.filter(item => !item.known).length, 1);
  assert.equal(result.summary.total, 2);
  assert.equal(result.summary.percent, 50);
});

test('pending, cleared, unassigned members and unregistered roles remain distinct', () => {
  const result = summarizeTeam([
    task(1, { roles: ['planner'], status: 'review' }),
    task(2, { roles: ['lead'], status: 'done' }),
    task(3, { roles: ['lead'], status: 'cancelled' }),
    task(4, { roles: ['ui_art'], status: 'cancelled' }),
    task(5, { roles: ['qa'] }),
    task(6),
    task(7, { roles: ['qa'], status: 'cancelled' }),
  ], roles);
  assert.equal(member(result, 'Captain').status, 'pending');
  assert.equal(member(result, 'Programmer').status, 'clear');
  assert.equal(member(result, 'Programmer').summary.percent, 100);
  assert.equal(member(result, 'Artist').status, 'clear');
  assert.equal(member(result, 'Artist').summary.percent, null);
  assert.equal(member(result, 'OtherArtist').status, 'unassigned');
  assert.deepEqual(member(result, 'OtherArtist').tasks, []);
  assert.deepEqual(result.unregisteredRoles.map(role => role.id), ['qa']);
  assert.equal(result.unregisteredRoles[0].summary.open, 1);
  assert.deepEqual(result.unassignedTasks.map(item => item.number), [5, 6]);
});

test('empty and whitespace member names are pending registration, never synthetic members', () => {
  const result = summarizeTeam([task(1, { roles: ['qa'] })], [
    { id: 'qa', name: '测试', member: '  ' },
    { id: 'ops', name: '运营', member: '' },
  ]);
  assert.equal(result.members.length, 0);
  assert.equal(result.unregisteredRoles.length, 2);
  assert.equal(result.unassignedTasks.length, 1);
});

test('preparation and production have independent denominators and member workloads', () => {
  const tasks = [
    task(1, { roles: ['planner'], status: 'done' }),
    task(2, { roles: ['planner'], status: 'doing', phase: 'production' }),
    task(3, { roles: ['ui_art'], phase: 'production' }),
  ];
  const preparation = summarizeTeam(tasks, roles, { phase: 'preparation' });
  const production = summarizeTeam(tasks, roles, { phase: 'production' });
  assert.equal(preparation.summary.percent, 100);
  assert.equal(member(preparation, 'Captain').status, 'clear');
  assert.equal(member(preparation, 'Artist').status, 'unassigned');
  assert.equal(production.summary.percent, 0);
  assert.equal(member(production, 'Captain').status, 'pending');
  assert.equal(member(production, 'Artist').status, 'pending');
  assert.equal(summarizeTeam(tasks, roles).summary.total, 3);
  assert.throws(() => summarizeTeam(tasks, roles, { phase: 'search-result' }), /无效的任务阶段/);
});

test('explicitly assigning an unregistered-role task does not create ownerless work', () => {
  const result = summarizeTeam([
    task(1, { roles: ['qa'], assignees: [{ login: 'Captain' }] }),
  ], roles);
  assert.equal(member(result, 'Captain').summary.open, 1);
  assert.equal(result.unregisteredRoles[0].summary.open, 1);
  assert.equal(result.unassignedTasks.length, 0);
});

test('summaries are pure and preserve input tasks and member records', () => {
  const tasks = [task(1, { roles: ['planner'] })];
  const before = structuredClone({ tasks, roles });
  summarizeTeam(tasks, roles);
  assert.deepEqual({ tasks, roles }, before);
});
