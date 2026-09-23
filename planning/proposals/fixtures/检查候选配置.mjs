// 设计数据检验：读取候选配置，按约定推演操作；不运行或测试 Godot。
import fs from 'node:fs';
import assert from 'node:assert/strict';

const config = JSON.parse(fs.readFileSync(new URL('./修补铺候选配置.json', import.meta.url), 'utf8'));
const originalConfig = JSON.stringify(config);
const clone = value => structuredClone(value);
const text = (value, name) => assert(typeof value === 'string' && value.trim(), name + ' 缺少文字');
const index = (values, name) => {
  assert(Array.isArray(values) && values.length, name + ' 必须为非空数组');
  const result = new Map();
  for (const value of values) {
    text(value.id, name + '.id');
    assert(!result.has(value.id), name + ' ID 重复：' + value.id);
    result.set(value.id, value);
  }
  return result;
};
const amounts = (value, name) => {
  assert.deepEqual(Object.keys(value).sort(), ['module', 'work'], name + ' 需完整填写两种资源');
  for (const [key, count] of Object.entries(value)) {
    assert(Number.isInteger(count) && count >= 0, name + '.' + key + ' 需为非负整数');
  }
};

assert.equal(config.schema_version, 3);
assert.equal(config.status, 'candidate_pretheme');
assert.equal(config.settings.presentation_binding, 'unbound');
assert.equal(config.settings.resource_names.module, '外放模块');
assert.deepEqual(config.settings.resource_units, { work: '格', module: '块' });
text(config.description, 'description');
text(config.settings.module_definition, 'module_definition');
assert(!('diagnoses' in config), '本版不使用诊断选项表');
assert(!('min_checks_before_diagnosis' in config.settings));

const questions = index(config.questions, 'questions');
const trials = index(config.trials, 'trials');
const items = index(config.items, 'items');
const presentation = index(config.presentation, 'presentation');
const methods = index(config.methods, 'methods');
const cases = index(config.cases, 'cases');
const chapters = index(config.chapters, 'chapters');
const agreements = index(config.agreements, 'agreements');
assert.deepEqual([...questions.keys()], ['who', 'how']);
assert.deepEqual([...trials.keys()], ['contact_trial', 'module_trial']);
assert.equal(cases.size, 4);
assert.equal(chapters.size, 3);

for (const question of questions.values()) text(question.name, question.id);
for (const trial of trials.values()) {
  text(trial.name, trial.id);
  text(trial.instruction, trial.id);
}
for (const item of items.values()) {
  for (const key of ['name', 'visual_key', 'shape_key']) text(item[key], item.id + '.' + key);
  assert.equal(typeof item.has_headphone_port, 'boolean');
}
for (const feedback of presentation.values()) {
  // visual_state/audio_key 是待制作资源的语义键；当前只检查文字与引用，不声称文件已存在。
  for (const key of ['visual_state', 'audio_key', 'text']) text(feedback[key], feedback.id + '.' + key);
}
for (const method of methods.values()) {
  assert(['contact_fault', 'speaker_fault'].includes(method.fault_kind));
  amounts(method.cost, method.id);
  assert(presentation.has(method.feedback_id), method.id + ' 表现引用不存在');
  assert(['reconnected', 'original', 'headphones'].includes(method.result_state));
  for (const key of ['name', 'keeps', 'loses']) text(method[key], method.id + '.' + key);
}
const included = new Set();
for (const chapter of chapters.values()) {
  amounts(chapter.resources, chapter.id);
  assert.equal(typeof chapter.must_complete, 'boolean');
  assert.equal(typeof chapter.allow_replan, 'boolean');
  for (const id of chapter.case_ids) {
    assert(cases.has(id), '未知委托：' + id);
    assert(!included.has(id), '委托跨段重复：' + id);
    included.add(id);
  }
}
assert.equal(included.size, cases.size);
for (const task of cases.values()) {
  assert(items.has(task.item_key), task.id + ' 物件引用不存在');
  text(config.settings.characters[task.owner_id], task.id + ' 主人');
  assert(['contact_fault', 'speaker_fault'].includes(task.fault_kind));
  assert.equal(typeof task.fault_confirmed, 'boolean');
  assert(presentation.has(task.initial_feedback_id));
  for (const key of ['title', 'entry_text', 'symptom']) text(task[key], task.id + '.' + key);
  assert(!('diagnosis' in task), task.id + ' 不应保留答题字段');
  assert.deepEqual(Object.keys(task.questions).sort(), [...questions.keys()].sort());
  for (const question of questions.keys()) {
    text(task.questions[question].reply, task.id + '.' + question + '.reply');
    text(task.questions[question].record, task.id + '.' + question + '.record');
  }
  assert.equal(task.hints.length, 2, task.id + ' 需有两层主动求助提示');
  task.hints.forEach((hint, i) => text(hint, task.id + '.hints[' + i + ']'));
  const results = Object.entries(task.trial_results);
  if (task.fault_confirmed) {
    assert.equal(results.length, 0, task.id + ' 已确认故障无需重复配置试修');
  } else {
    assert.deepEqual(results.map(([id]) => id).sort(), [...trials.keys()].sort());
    assert(results.some(([, result]) => result.improves), task.id + ' 没有可改善现象的试修');
  }
  for (const [id, result] of results) {
    assert(trials.has(id));
    assert.equal(typeof result.improves, 'boolean');
    assert(presentation.has(result.feedback_id));
  }
  assert(task.plans.some(plan => plan.accepted), task.id + ' 缺少可接受方案');
  assert.equal(new Set(task.plans.map(plan => plan.method_id)).size, task.plans.length);
  for (const plan of task.plans) {
    assert(methods.has(plan.method_id));
    assert.equal(methods.get(plan.method_id).fault_kind, task.fault_kind);
    assert.equal(typeof plan.accepted, 'boolean');
    if (plan.accepted) text(plan.response, task.id + ' 施工回应');
    else text(plan.reason, task.id + ' 拒绝原因');
    assert(plan.requires_agreement === null || agreements.has(plan.requires_agreement));
    if (plan.requires_agreement) {
      assert.equal(agreements.get(plan.requires_agreement).case_id, task.id);
    }
  }
}
for (const agreement of agreements.values()) {
  assert(cases.has(agreement.case_id));
  assert.equal(agreement.owner_id, cases.get(agreement.case_id).owner_id);
  for (const key of ['request', 'reply', 'refused_reply']) text(agreement[key], agreement.id + '.' + key);
}
const transfer = config.transfer;
assert(chapters.has(transfer.chapter_id));
assert(cases.has(transfer.source_case_id));
assert(agreements.has(transfer.agreement_id));
assert.equal(agreements.get(transfer.agreement_id).case_id, transfer.source_case_id);
assert.equal(items.get(cases.get(transfer.source_case_id).item_key).has_headphone_port, true);
assert(presentation.has(transfer.headphone_test_feedback_id));
assert(presentation.has(transfer.feedback_id));
assert.equal(transfer.result_state, 'headphones');
assert.equal(transfer.limit, 1);
text(transfer.offer_text, 'transfer.offer_text');
amounts(transfer.cost, 'transfer.cost');
amounts(transfer.gain, 'transfer.gain');
for (const key of ['donor_preserved', 'donor_transferred', 'manual_notice', 'public_broadcast', 'unresolved']) {
  text(config.followup[key], 'followup.' + key);
}

// 以下只实现本样例的有限动作，检查数据能否产生正文中的业务结果。
const createState = () => ({
  chapter_id: null, phase: 'working', resources: { work: 0, module: 0 },
  cases: Object.fromEntries([...cases].map(([id, task]) => [id, {
    done: false, known_questions: [], trial_draft: null, trial_results: {},
    trial_succeeded: false, item_state: 'unrepaired', feedback_id: task.initial_feedback_id
  }])),
  agreements: Object.fromEntries([...agreements.keys()].map(id => [id, false])),
  donor_headphones_tested: false, transfer_count: 0
});
const current = (state, id) => chapters.get(state.chapter_id).case_ids.includes(id);
const needsKnown = (state, id) => [...questions.keys()].every(key => state.cases[id].known_questions.includes(key));
const canSpend = (state, cost) => ['work', 'module'].every(key => state.resources[key] >= cost[key]);
const spend = (state, cost) => {
  for (const key of ['work', 'module']) state.resources[key] -= cost[key];
};
const enter = (state, id) => {
  if (state.chapter_id) {
    const previous = chapters.get(state.chapter_id);
    assert(!previous.must_complete || previous.case_ids.every(key => state.cases[key].done));
  }
  state.chapter_id = id;
  state.phase = 'working';
  state.resources = clone(chapters.get(id).resources);
};
const ask = (state, id, question) => {
  assert(current(state, id) && questions.has(question));
  const known = state.cases[id].known_questions;
  if (!known.includes(question)) known.push(question);
  return cases.get(id).questions[question].record;
};
const askBoth = (state, id) => { for (const key of questions.keys()) ask(state, id, key); };
const prepareTrial = (state, id, trialId) => {
  assert(current(state, id) && !state.cases[id].done);
  assert(cases.get(id).trial_results[trialId], '该委托没有这项临时处理');
  state.cases[id].trial_draft = trialId;
};
const listen = (state, id) => {
  const runtime = state.cases[id];
  const result = cases.get(id).trial_results[runtime.trial_draft];
  assert(result, '先选择临时处理，再试听复测');
  runtime.trial_results[runtime.trial_draft] = result.improves;
  runtime.trial_succeeded ||= result.improves;
  runtime.feedback_id = result.feedback_id;
};
const preview = (state, id, methodId) => {
  if (!current(state, id) || state.phase !== 'working') return '当前不能处理这件委托';
  const runtime = state.cases[id];
  const task = cases.get(id);
  const plan = task.plans.find(value => value.method_id === methodId);
  if (!plan) return '该委托没有这项方案';
  if (runtime.done) return '委托已经完成';
  if (!needsKnown(state, id)) return '先问清谁来用、怎样用';
  if (!task.fault_confirmed && !runtime.trial_succeeded) return '先试听验证至少一项临时处理';
  if (!plan.accepted) return plan.reason;
  if (plan.requires_agreement && !state.agreements[plan.requires_agreement]) return '尚未取得顾客同意';
  if (!canSpend(state, methods.get(methodId).cost)) return '工作格或外放模块不足';
  return null;
};
const construct = (state, id, methodId) => {
  const reason = preview(state, id, methodId);
  if (reason) return reason;
  const method = methods.get(methodId);
  spend(state, method.cost);
  Object.assign(state.cases[id], {
    done: true, item_state: method.result_state, feedback_id: method.feedback_id, trial_draft: null
  });
  return null;
};
const testDonorHeadphones = state => {
  assert.equal(state.chapter_id, transfer.chapter_id);
  assert(state.cases[transfer.source_case_id].done);
  state.donor_headphones_tested = true;
  return transfer.headphone_test_feedback_id;
};
const agree = (state, id, accepted) => {
  const agreement = agreements.get(id);
  assert.equal(typeof accepted, 'boolean');
  if (!needsKnown(state, agreement.case_id)) return '先问清物件的用途';
  if (id === transfer.agreement_id) {
    if (state.transfer_count > 0) return '已经转用，需要重新安排才能更改同意';
    if (state.chapter_id !== transfer.chapter_id || !state.donor_headphones_tested) return '先试私人收音机的耳机口';
  } else {
    if (state.cases[agreement.case_id].done) return '已经施工，需要重新安排才能更改同意';
    if (!current(state, agreement.case_id)) return '当前不能讨论这件委托';
  }
  state.agreements[id] = accepted;
  return null;
};
const transferModule = state => {
  if (state.chapter_id !== transfer.chapter_id || state.phase !== 'working') return '当前不能转用';
  if (state.transfer_count >= transfer.limit) return '本段已经转用过';
  if (!state.donor_headphones_tested) return '先试私人收音机的耳机口';
  if (!state.agreements[transfer.agreement_id]) return '尚未取得主人同意';
  if (!canSpend(state, transfer.cost)) return '工作格不足';
  spend(state, transfer.cost);
  for (const key of ['work', 'module']) state.resources[key] += transfer.gain[key];
  state.transfer_count += 1;
  Object.assign(state.cases[transfer.source_case_id], {
    item_state: transfer.result_state, feedback_id: transfer.feedback_id
  });
  return null;
};
const finish = state => {
  const chapter = chapters.get(state.chapter_id);
  const unresolved = chapter.case_ids.filter(id => !state.cases[id].done);
  if (chapter.must_complete && unresolved.length) return { allowed: false, unresolved };
  state.phase = 'complete';
  return { allowed: true, unresolved };
};
const replan = (state, snapshot) => {
  assert(chapters.get(state.chapter_id).allow_replan);
  assert.equal(state.chapter_id, snapshot.chapter_id);
  return clone(snapshot);
};
const expectRejectedWithoutChange = (state, action) => {
  const before = clone(state);
  assert(action(), '此步应该被拒绝');
  assert.deepEqual(state, before, '被拒绝的操作改变了状态');
};

let state = createState();
enter(state, 's01');
assert.equal(finish(state).allowed, false);
askBoth(state, 'c01_private_radio');
const firstResources = clone(state.resources);
prepareTrial(state, 'c01_private_radio', 'module_trial');
listen(state, 'c01_private_radio');
assert.equal(state.cases.c01_private_radio.trial_succeeded, false);
expectRejectedWithoutChange(state, () => construct(state, 'c01_private_radio', 'reconnect'));
prepareTrial(state, 'c01_private_radio', 'contact_trial');
expectRejectedWithoutChange(state, () => construct(state, 'c01_private_radio', 'reconnect'));
listen(state, 'c01_private_radio');
listen(state, 'c01_private_radio');
assert.deepEqual(state.resources, firstResources, '临时处理或重复试听扣除了资源');
const firstPreview = clone(state);
assert.equal(preview(state, 'c01_private_radio', 'reconnect'), null);
assert.deepEqual(state, firstPreview, '方案预览改变了状态');
assert.equal(construct(state, 'c01_private_radio', 'reconnect'), null);
assert.deepEqual(state.resources, { work: 0, module: 0 });
expectRejectedWithoutChange(state, () => construct(state, 'c01_private_radio', 'reconnect'));

enter(state, 's02');
askBoth(state, 'c02_doorbell');
const secondResources = clone(state.resources);
prepareTrial(state, 'c02_doorbell', 'contact_trial');
listen(state, 'c02_doorbell');
assert.equal(state.cases.c02_doorbell.trial_succeeded, false);
prepareTrial(state, 'c02_doorbell', 'module_trial');
listen(state, 'c02_doorbell');
assert.deepEqual(state.resources, secondResources);
assert.equal(construct(state, 'c02_doorbell', 'replace'), null);
assert.deepEqual(state.resources, { work: 0, module: 0 });

enter(state, 's03');
const snapshot = clone(state); // 设置本段供给后、所有本段操作之前保存。
assert.deepEqual(snapshot.resources, { work: 3, module: 1 });
expectRejectedWithoutChange(state, () => construct(state, 'c03_alarm', 'replace'));
askBoth(state, 'c03_alarm');
askBoth(state, 'c04_public_radio');
expectRejectedWithoutChange(state, () => construct(state, 'c03_alarm', 'headphones'));
expectRejectedWithoutChange(state, () => construct(state, 'c04_public_radio', 'headphones'));
assert.equal(agree(state, 'manual_notice_agreement', false), null);
expectRejectedWithoutChange(state, () => construct(state, 'c04_public_radio', 'headphones'));
assert.equal(agree(state, 'manual_notice_agreement', true), null);
assert.equal(construct(state, 'c03_alarm', 'replace'), null);
assert.equal(construct(state, 'c04_public_radio', 'headphones'), null);
expectRejectedWithoutChange(state, () => agree(state, 'manual_notice_agreement', false));
assert.deepEqual(state.resources, { work: 0, module: 0 });
assert.equal(state.cases.c01_private_radio.item_state, 'reconnected');
assert.deepEqual(finish(state), { allowed: true, unresolved: [] });
state = replan(state, snapshot);
assert.deepEqual(state, snapshot, '方案甲结束后的重新安排没有完整恢复');

askBoth(state, 'c03_alarm');
askBoth(state, 'c04_public_radio');
expectRejectedWithoutChange(state, () => agree(state, 'donor_transfer', true));
expectRejectedWithoutChange(state, () => transferModule(state));
const beforeDonorTest = clone(state.resources);
assert.equal(testDonorHeadphones(state), transfer.headphone_test_feedback_id);
assert.deepEqual(state.resources, beforeDonorTest);
assert.equal(agree(state, 'donor_transfer', false), null);
expectRejectedWithoutChange(state, () => transferModule(state));
assert.equal(agree(state, 'donor_transfer', true), null);
assert.equal(transferModule(state), null);
expectRejectedWithoutChange(state, () => agree(state, 'donor_transfer', false));
assert.deepEqual(state.resources, { work: 2, module: 2 });
expectRejectedWithoutChange(state, () => transferModule(state));
assert.equal(construct(state, 'c04_public_radio', 'replace'), null);
assert.equal(construct(state, 'c03_alarm', 'replace'), null);
assert.deepEqual(state.resources, { work: 0, module: 0 });
assert.equal(state.cases.c01_private_radio.item_state, 'headphones');
assert.deepEqual(finish(state), { allowed: true, unresolved: [] });
state = replan(state, snapshot);
assert.deepEqual(state, snapshot, '方案乙的物件、询问、同意、测试或转用记录仍有残留');

askBoth(state, 'c03_alarm');
askBoth(state, 'c04_public_radio');
assert.equal(construct(state, 'c04_public_radio', 'replace'), null);
expectRejectedWithoutChange(state, () => construct(state, 'c03_alarm', 'replace'));
assert.deepEqual(finish(state), { allowed: true, unresolved: ['c03_alarm'] });
state = replan(state, snapshot);
assert.deepEqual(state, snapshot);
assert.equal(JSON.stringify(config), originalConfig, '推演修改了只读配置');

console.log('schema 3 字段与引用通过；两项免费询问、临时处理后试听、用途拒绝与同意条件通过。');
console.log('保留私人机／授权转用两条完整安排、未处理收束、资源不足及完整重新安排通过。');
console.log('以上是候选设计数据推演，未运行 Godot；图片、声音、真实输入和玩家体验尚未实测。');
