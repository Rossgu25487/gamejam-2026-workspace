// Browser smoke tests: all GitHub traffic is intercepted; no comments or workflows run.
import assert from 'node:assert/strict';
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { resolve } from 'node:path';
import { createRequire } from 'node:module';
import { parseArgs } from 'node:util';

const { values } = parseArgs({ options: {
  url: { type: 'string', default: 'http://127.0.0.1:4179/' },
  playwright: { type: 'string' }, browser: { type: 'string' },
  output: { type: 'string', default: '.local/dashboard-review' },
} });
const require = createRequire(import.meta.url);
const { chromium } = require(values.playwright || 'playwright');
const baseURL = new URL(values.url);
if (!['localhost', '127.0.0.1', '[::1]'].includes(baseURL.hostname)) throw new Error('冒烟测试仅访问本机预览。');
const original = JSON.parse(await readFile(new URL('../site/data/snapshot.json', import.meta.url), 'utf8'));
// Fixed scenarios keep a teammate closing or adding real Issues from breaking the tests.
// Repository/version/resources still come from the built snapshot, without a network write.
original.phase = { id: 'preparation', label: '命题前准备', note: '冒烟测试固定场景' };
original.release = null;
const fixtureMembers = { planner: 'Rossgu25487', lead: 'follerdf', gameplay: 'bcynuaa', integration: 'wangruijie21', ui_art: 'Aprilwwwang', visual_art: 'stephaniez1' };
original.roles = original.roles.map(role => ({ ...role, member: fixtureMembers[role.id] || '' }));
const fixtureTasks = [
  ['done', ['lead']], ['done', ['planner']], ['done', ['lead', 'qa']],
  ['todo', ['planner']], ['todo', ['lead']], ['todo', ['gameplay']], ['todo', ['integration']],
  ['todo', ['ui_art']], ['todo', ['visual_art']], ['todo', ['qa']], ['todo', ['ops']],
  ['done', ['planner', 'lead']], ['todo', ['planner'], 'production'],
  ['todo', ['planner'], 'production'], ['todo', ['planner'], 'production'],
];
original.tasks = fixtureTasks.map(([status, roles, phase = 'preparation'], index) => ({
  number: index + 1, title: `冒烟测试任务 ${index + 1}${index === 13 ? ' 剧情' : ''}`,
  url: `${original.repository.url}/issues/${index + 1}`, status, roles, phase,
  assignees: index === 3 || index >= 12 ? [{ login: 'Rossgu25487', url: 'https://github.com/Rossgu25487' }] : [],
  updated_at: original.generated_at, closed_at: status === 'done' ? original.generated_at : null,
  milestone: null, deadline: { at: null, source: null, error: null },
}));
const output = resolve(values.output);
await mkdir(output, { recursive: true });
const browser = await chromium.launch({ headless: true, ...(values.browser ? { executablePath: values.browser } : {}) });
const results = [];
const openStatuses = ['todo', 'doing', 'review'];

function rawIssue(task) {
  return { number: task.number, title: task.title, html_url: task.url,
    state: openStatuses.includes(task.status) ? 'open' : 'closed',
    state_reason: task.status === 'cancelled' ? 'not_planned' : 'completed',
    labels: [`phase:${task.phase}`, ...task.roles.map(role => `role:${role}`), `status:${task.status}`],
    assignees: task.assignees.map(person => ({ login: person.login, html_url: person.url })),
    updated_at: task.updated_at, closed_at: task.closed_at, milestone: task.milestone ? { title: task.milestone } : null,
    body: task.deadline?.at ? `截止时间: ${task.deadline.at}` : '',
  };
}

async function environment(options = {}) {
  const control = { snapshot: structuredClone(original), apiStatus: 0, initialStatus: 0, workflow: 'active', ...options };
  const errors = [], writes = [], missingFiles = [];
  const context = await browser.newContext({ viewport: { width: 1440, height: 1000 },
    permissions: ['clipboard-read', 'clipboard-write'], reducedMotion: 'reduce', serviceWorkers: 'block' });
  await context.route('**/*', async route => {
    const request = route.request(), url = new URL(request.url());
    if (url.origin === baseURL.origin) {
      if (url.pathname.endsWith('/data/snapshot.json')) {
        return route.fulfill({ status: control.initialStatus || 200, json: control.snapshot });
      }
      return route.continue();
    }
    if (request.method() !== 'GET') { writes.push(request.method() + ' ' + url.href); return route.abort(); }
    // External links open a harmless local fixture response, never the real destination.
    if (url.hostname !== 'api.github.com') return route.fulfill({ contentType: 'text/html', body: '<p>Smoke test link destination</p>' });
    if (url.pathname.endsWith('/actions/workflows/task-reminders.yml')) {
      return route.fulfill(control.workflow === 'missing' ? { status: 404, json: {} }
        : control.workflow === 'failed' ? { status: 503, json: {} } : { json: { state: control.workflow } });
    }
    if (control.apiStatus) return route.fulfill({ status: control.apiStatus, json: {} });
    const data = control.snapshot;
    let value;
    if (url.pathname.endsWith('/commits/main')) value = { sha: data.version.sha, html_url: data.version.url,
      commit: { message: data.version.message, committer: { date: data.version.committed_at } } };
    else if (url.pathname.endsWith('/issues')) value = data.tasks.map(rawIssue);
    else if (url.pathname.endsWith('/releases/latest')) {
      if (!data.release) return route.fulfill({ status: 404, json: {} });
      value = { tag_name: data.release.tag, name: data.release.name, html_url: data.release.url,
        published_at: data.release.published_at, assets: data.release.assets.map(asset => ({
          name: asset.name, size: asset.size, browser_download_url: asset.url,
        })) };
    } else if (url.pathname.endsWith('/contents/workspace/manifest.json')) value = { roles: data.roles };
    else if (url.pathname.endsWith('/contents/workspace/roadmap.json')) value = { phase: data.phase, schedule: data.schedule };
    else value = { ...data.repository, html_url: data.repository.url };
    return route.fulfill({ json: value });
  });
  const page = await context.newPage();
  page.setDefaultTimeout(8000);
  page.on('pageerror', error => errors.push(error.message));
  page.on('response', response => {
    if (response.url().startsWith(baseURL.origin) && response.status() >= 400) missingFiles.push(response.url());
  });
  const go = async (query = '') => {
    await page.goto(new URL(query || './', baseURL).href);
    await page.waitForFunction(() => !document.querySelector('#refresh-button').disabled);
    if (!control.initialStatus) {
      await page.locator('#dashboard').waitFor({ state: 'visible' });
      await page.waitForFunction(() => !document.querySelector('#automation-state').textContent.includes('正在'));
    }
  };
  return { control, context, page, go, errors, writes, missingFiles };
}

async function check(name, run, options) {
  const env = await environment(options);
  try {
    await run(env);
    assert.deepEqual(env.errors, [], '浏览器脚本错误');
    assert.deepEqual(env.writes, [], '测试必须拦截且禁止外部写操作');
    results.push({ name, status: 'passed' });
  } catch (error) {
    results.push({ name, status: 'failed', error: error.message });
    await env.page.screenshot({ path: resolve(output, `smoke-failure-${results.length}.png`), fullPage: true }).catch(() => {});
  } finally { await env.context.close(); }
  console.log(`${results.at(-1).status}: ${name}`);
}

try {
  await check('启动、模块、版本、阶段进度和固定资料链接', async ({ page, go, missingFiles }) => {
    await go('?role=all&phase=preparation&status=open');
    assert.deepEqual(missingFiles, []);
    assert.equal(await page.locator('#commit-sha').getAttribute('title'), original.version.sha);
    assert.equal(await page.locator('#sync-title').textContent(), '已同步');
    assert.match(await page.locator('#project-progress').textContent(), /尚未开工/);
    const links = await page.locator('.resource-link,.team-workflow').evaluateAll(nodes => nodes.map(node => node.href));
    assert(links.length >= 4 && links.every(link => link.includes(original.version.sha)));
    assert.equal(await page.locator('#release-status').textContent(), '未发布');
  });
  await check('八岗筛选、六种状态、准确成员任务与重置', async ({ page, go }) => {
    await go('?role=all&phase=preparation&status=open');
    for (const role of original.roles) {
      await page.locator('#role-filter').selectOption(role.id);
      const count = original.tasks.filter(task => task.phase === 'preparation' && task.roles.includes(role.id) && openStatuses.includes(task.status)).length;
      assert.equal(await page.locator('#task-list > li').count(), count);
    }
    await page.locator('#clear-filters').click();
    for (const status of ['open', 'todo', 'doing', 'review', 'done', 'all']) {
      await page.locator(`[data-status="${status}"]`).click();
      assert.equal(await page.locator(`[data-status="${status}"]`).getAttribute('aria-pressed'), 'true');
      const expected = original.tasks.filter(task => task.phase === 'preparation' && (status === 'all' || (status === 'open' ? openStatuses.includes(task.status) : task.status === status))).length;
      assert.equal(await page.locator('#task-list > li').count(), Math.min(12, expected));
    }
    await page.locator('[data-member="Rossgu25487"]').getByRole('button', { name: '查看任务' }).click();
    assert.equal(await page.locator('#task-search').inputValue(), '@Rossgu25487');
    assert.equal(await page.locator('#role-filter').inputValue(), 'all');
  });
  await check('空格搜索、中文输入法、无结果与链接恢复', async ({ page, go }) => {
    await go('?role=planner&phase=production&status=open');
    await page.locator('#task-search').pressSequentially('Godot ');
    assert.equal(await page.locator('#task-search').inputValue(), 'Godot ');
    await page.locator('#task-search').fill('');
    await page.locator('#task-search').evaluate(input => {
      input.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true }));
      input.value = '剧情'; input.dispatchEvent(new InputEvent('input', { bubbles: true, isComposing: true }));
      input.dispatchEvent(new CompositionEvent('compositionend', { bubbles: true, data: '剧情' }));
    });
    assert.equal(await page.locator('#task-search').inputValue(), '剧情');
    await page.locator('#copy-view').click();
    const shared = await page.evaluate(() => navigator.clipboard.readText());
    assert.equal(new URL(shared).searchParams.get('q'), '剧情');
    await go(shared);
    assert.equal(await page.locator('#task-search').inputValue(), '剧情');
    await page.locator('#task-search').fill('no-matching-task-12345');
    assert.equal(await page.locator('#tasks-empty').isVisible(), true);
    assert.match(await page.locator('#progress-label').textContent(), /当前筛选范围暂无任务/);
  });
  await check('岗位记忆关闭后跨次打开仍保持关闭', async ({ page, go }) => {
    await go(); await page.locator('#role-filter').selectOption('planner');
    await go(); assert.equal(await page.locator('#role-filter').inputValue(), 'planner');
    await page.locator('#remember-role').uncheck(); await go();
    assert.equal(await page.locator('#remember-role').isChecked(), false);
    await page.locator('#role-filter').selectOption('lead'); await go();
    assert.equal(await page.locator('#role-filter').inputValue(), 'all');
  });
  await check('成员分组、跨阶段、无负责人和已清空待办', async ({ page, go, control }) => {
    control.snapshot.tasks.find(task => task.number === 5).status = 'done';
    await go('?role=planner&phase=preparation&status=open');
    assert.equal(await page.locator('[data-member="follerdf"].member-clear').count(), 1);
    assert.equal(await page.locator('[data-member="follerdf"] .reminder-button').count(), 0);
    assert.match(await page.locator('.member-group-unknown').textContent(), /待补负责人/);
    await page.locator('#task-search').fill('not-found');
    assert.equal(await page.locator('[data-member="follerdf"].member-clear').count(), 1);
    await page.locator('#phase-filter').selectOption('production');
    assert.equal(await page.locator('.member-unassigned').count(), 5);
  });
  await check('分页、空项目、全部取消与正式制作阶段', async ({ page, go, control }) => {
    control.snapshot.tasks = Array.from({ length: 25 }, (_, i) => ({ ...structuredClone(original.tasks.find(task => task.number === 4)), number: i + 101 }));
    await go('?role=all&phase=all&status=all');
    assert.equal(await page.locator('#task-list > li').count(), 12);
    await page.locator('#show-more').click(); assert.equal(await page.locator('#task-list > li').count(), 24);
    await page.locator('#show-more').click(); assert.equal(await page.locator('#task-list > li').count(), 25);
    assert.equal(await page.locator('#show-more').isHidden(), true);
    control.snapshot.tasks = []; control.snapshot.phase = { id: 'production', label: '正式制作', note: '' };
    await go('?phase=production'); assert.equal(await page.locator('#tasks-empty').isVisible(), true);
    assert.match(await page.locator('#project-progress').textContent(), /未建立任务/);
    control.snapshot.tasks = [{ ...original.tasks[0], status: 'cancelled', phase: 'production' }];
    await go('?phase=production&status=all'); assert.match(await page.locator('#progress-label').textContent(), /不计入进度/);
  });
  await check('提醒草稿编辑、复制、键盘关闭和外链', async ({ page, go, context }) => {
    await go('?role=planner&phase=preparation&status=open');
    await page.locator('.task-remind').click();
    await page.locator('.reminder-draft').fill('@Rossgu25487\n测试草稿，仅在测试浏览器复制。');
    await page.getByRole('button', { name: '复制评论草稿', exact: true }).click();
    assert.match(await page.evaluate(() => navigator.clipboard.readText()), /测试草稿/);
    assert.match(await page.locator('#reminder-feedback').textContent(), /尚未发送/);
    const popupEvent = context.waitForEvent('page');
    await page.getByRole('link', { name: '打开任务发表评论 ↗' }).click();
    const popup = await popupEvent; await popup.waitForLoadState();
    assert.match(popup.url(), /\/issues\/4#new_comment_field$/); await popup.close();
    await page.keyboard.press('Escape'); assert.equal(await page.locator('#reminder-dialog').isVisible(), false);
  });
  await check('批量提醒只复制任务编号并跳转，不发送', async ({ page, go, context }) => {
    await go('?role=planner&phase=production&status=open');
    await page.locator('[data-member="Rossgu25487"] .reminder-button').click();
    assert.match(await page.locator('#reminder-run-note').textContent(), /草稿修改不会带入/);
    const popupEvent = context.waitForEvent('page');
    await page.locator('#run-reminder').click();
    const popup = await popupEvent; await popup.waitForLoadState();
    assert.match(popup.url(), /\/actions\/workflows\/task-reminders.yml$/);
    assert.equal((await page.evaluate(() => navigator.clipboard.readText())).split(',').length, 3);
    assert.match(await page.locator('#reminder-feedback').textContent(), /尚未发送/);
    await popup.close();
  });
  await check('超过 20 项的批量提醒分组完整且无重复', async ({ page, go, context, control }) => {
    control.snapshot.tasks = Array.from({ length: 25 }, (_, i) => ({ ...structuredClone(original.tasks.find(task => task.number === 4)), number: i + 101 }));
    await go('?role=planner&phase=preparation&status=open');
    await page.locator('[data-member="Rossgu25487"] .reminder-button').click();
    assert.equal(await page.locator('#reminder-batch-picker').isVisible(), true);
    const numbers = [];
    for (const [batch, size] of [['0', 20], ['1', 5]]) {
      await page.locator('#reminder-batch').selectOption(batch);
      const popupEvent = context.waitForEvent('page'); await page.locator('#run-reminder').click();
      const popup = await popupEvent; await popup.waitForLoadState(); await popup.close();
      const copied = (await page.evaluate(() => navigator.clipboard.readText())).split(',');
      assert.equal(copied.length, size); numbers.push(...copied);
    }
    assert.equal(new Set(numbers).size, 25);
  });
  await check('进行中、待验收任务与提醒文案、缺失工作流', async ({ page, go, control }) => {
    control.snapshot.tasks.find(task => task.number === 6).status = 'doing';
    control.snapshot.tasks.find(task => task.number === 7).status = 'review';
    control.snapshot.tasks.find(task => task.number === 7).deadline = { at: '2026-10-18T16:00:00Z', source: 'body', error: null };
    control.workflow = 'missing';
    await go('?role=all&phase=preparation&status=doing');
    assert.equal(await page.locator('#task-list .task-doing').count(), 1);
    await page.locator('[data-status="review"]').click();
    assert.equal(await page.locator('#task-list .task-review').count(), 1);
    assert.match(await page.locator('#task-list').textContent(), /2026\/10\/19 00:00/);
    await page.locator('.task-remind').click();
    assert.match(await page.locator('.reminder-draft').inputValue(), /请确认验收进展/);
    assert.equal(await page.locator('#run-reminder').isHidden(), true);
    await page.keyboard.press('Escape');
    assert.equal(await page.locator('.task-remind').evaluate(node => document.activeElement === node), true);
  });
  await check('复制权限失败有明确回退', async ({ page, go }) => {
    await go('?role=planner&phase=preparation&status=open');
    await page.evaluate(() => Object.defineProperty(navigator.clipboard, 'writeText', { value: () => Promise.reject(new Error('denied')) }));
    await page.locator('#copy-view').click(); assert.match(await page.locator('#copy-feedback').textContent(), /复制未成功/);
    await page.locator('.task-remind').click(); await page.getByRole('button', { name: '复制评论草稿', exact: true }).click();
    assert.match(await page.locator('#reminder-feedback').textContent(), /手动复制/);
  });
  await check('刷新失败保留数据，恢复后同步，工作流状态独立核验', async ({ page, go, control }) => {
    await go(); const previous = await page.locator('#task-list').textContent();
    control.apiStatus = 503; control.workflow = 'failed';
    await page.locator('#refresh-button').click(); await page.waitForFunction(() => !document.querySelector('#refresh-button').disabled);
    assert.equal(await page.locator('#task-list').textContent(), previous);
    assert.equal(await page.locator('#sync-title').textContent(), '刷新失败');
    await page.waitForFunction(() => !document.querySelector('#automation-state').textContent.includes('正在'));
    assert.doesNotMatch(await page.locator('#automation-state').textContent(), /工作流已部署/);
    control.apiStatus = 0; control.workflow = 'disabled_manually';
    await page.locator('#refresh-button').click(); await page.waitForFunction(() => !document.querySelector('#refresh-button').disabled);
    await page.waitForFunction(() => !document.querySelector('#automation-state').textContent.includes('正在'));
    assert.equal(await page.locator('#sync-title').textContent(), '已同步');
    assert.match(await page.locator('#automation-state').textContent(), /已停用/);
  });
  await check('首次快照缺失可重试恢复', async ({ page, go, control }) => {
    control.initialStatus = 404; await go(); assert.equal(await page.locator('#load-error').isVisible(), true);
    assert.equal(await page.locator('#dashboard').isHidden(), true);
    control.initialStatus = 0; await page.locator('#refresh-button').click();
    await page.locator('#dashboard').waitFor({ state: 'visible' });
    assert.equal(await page.locator('#load-error').isHidden(), true);
  });
  await check('试玩包附件、排期时区及手机布局', async ({ page, go, control }) => {
    control.snapshot.release = { tag: 'smoke-test', name: '模拟试玩包', published_at: original.generated_at,
      url: `${original.repository.url}/releases/tag/smoke-test`, assets: [{ name: 'game.zip', size: 2048, url: `${original.repository.url}/releases/download/smoke-test/game.zip` }] };
    await go('?role=planner&phase=preparation&status=open');
    assert.match(await page.locator('#release-assets').textContent(), /game.zip/);
    assert.match(await page.locator('.schedule-item').filter({ hasText: '10月19日' }).textContent(), /00:00/);
    await page.locator('.schedule-detail summary').first().click();
    assert.equal(await page.locator('.schedule-detail').first().getAttribute('open'), '');
    for (const width of [1440, 768, 390, 320]) {
      await page.setViewportSize({ width, height: 900 });
      assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), `横向溢出：${width}`);
      await page.locator('.task-remind').click();
      assert(await page.locator('#reminder-dialog').evaluate(node => node.scrollWidth <= node.clientWidth));
      await page.keyboard.press('Escape');
    }
    await page.screenshot({ path: resolve(output, 'smoke-mobile-fixture.png'), fullPage: true });
  });
  await check('导航跳转与预览服务文件边界', async ({ page, go, context }) => {
    await go('?role=all&phase=preparation&status=open');
    for (const link of await page.locator('.section-nav a').all()) {
      const target = await link.getAttribute('href'); await link.click();
      assert.equal(new URL(page.url()).hash, target);
    }
    for (const path of ['AGENTS.md', '%2e%2e%2fAGENTS.md', '.git/config']) {
      assert.equal((await context.request.get(new URL(path, baseURL).href)).status(), 404);
    }
    assert.equal((await context.request.post(baseURL.href, { data: 'smoke' })).status(), 405);
  });
} finally {
  await browser.close();
  const report = { generated_at: new Date().toISOString(), scope: '本地 Chromium；模拟 GitHub 数据与外链；不进行任何真实发送或发布', results };
  await writeFile(resolve(output, 'smoke-results.json'), JSON.stringify(report, null, 2) + '\n');
}
const failed = results.filter(result => result.status === 'failed');
console.log(JSON.stringify({ passed: results.length - failed.length, failed }, null, 2));
if (failed.length) process.exitCode = 1;
