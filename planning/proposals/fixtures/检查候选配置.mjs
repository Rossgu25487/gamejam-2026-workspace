// 验证候选数据和两条分配算式，不运行或测试 Godot 游戏。
import fs from 'node:fs';
import assert from 'node:assert/strict';
const config = JSON.parse(fs.readFileSync(new URL('./修补铺候选配置.json', import.meta.url), 'utf8'));
assert.equal(config.schema_version, 2);
const index = values => {
  const map = new Map(values.map(value => [value.id, value]));
  assert.equal(map.size, values.length, 'ID 重复');
  return map;
};
const tools = index(config.tools);
const diagnoses = index(config.diagnoses);
const methods = index(config.methods);
const cases = index(config.cases);
const chapters = index(config.chapters);
const agreements = index(config.agreements);
const resourceKeys = Object.keys(config.settings.resource_units);
const checkAmounts = amounts => {
  for (const [key, value] of Object.entries(amounts)) {
    assert(resourceKeys.includes(key), `未知资源 ${key}`);
    assert(Number.isInteger(value) && value >= 0, `资源值非法 ${key}`);
  }
};
for (const method of methods.values()) {
  assert(diagnoses.has(method.diagnosis));
  checkAmounts(method.cost);
}
const used = new Set();
for (const chapter of chapters.values()) {
  checkAmounts(chapter.resources);
  for (const id of chapter.case_ids) {
    assert(cases.has(id));
    assert(!used.has(id), `委托跨段重复 ${id}`);
    used.add(id);
  }
}
assert.equal(used.size, cases.size);
for (const task of cases.values()) {
  assert(config.settings.characters[task.owner_id]);
  assert(diagnoses.has(task.diagnosis));
  assert(Object.keys(task.observations).length >= config.settings.min_checks_before_diagnosis);
  for (const key of Object.keys(task.observations)) assert(tools.has(key));
  assert(task.plans.some(plan => plan.accepted), `${task.id} 无可接受方案`);
  for (const plan of task.plans) {
    assert(methods.has(plan.method_id));
    assert.equal(methods.get(plan.method_id).diagnosis, task.diagnosis);
    if (plan.requires_agreement) assert(agreements.has(plan.requires_agreement));
    if (!plan.accepted) assert(plan.reason.trim());
  }
}
assert(cases.has(config.transfer.source_case_id));
assert(chapters.has(config.transfer.chapter_id));
assert(agreements.has(config.transfer.agreement_id));
assert.equal(config.transfer.limit, 1);
checkAmounts(config.transfer.cost);checkAmounts(config.transfer.gain);
const final = chapters.get(config.transfer.chapter_id);
const planA = ['replace', 'headphones'].map(id => methods.get(id).cost);
const planB = [config.transfer.cost, methods.get('replace').cost, methods.get('replace').cost];
for (const key of resourceKeys) {
  assert.equal(planA.reduce((sum, c) => sum + (c[key] ?? 0), 0), final.resources[key]);
  assert.equal(planB.reduce((sum, c) => sum + (c[key] ?? 0), 0), final.resources[key] + (config.transfer.gain[key] ?? 0));
}
const alarm = cases.get('c03_alarm');
assert.equal(alarm.plans.find(p => p.method_id === 'headphones').accepted, false);
assert.equal(cases.get('c04_public_radio').plans.find(p => p.method_id === 'headphones').requires_agreement, 'public_manual_notice');
console.log('字段引用、四件委托、三段供给与两条最终分配算式通过；未运行 Godot。');
