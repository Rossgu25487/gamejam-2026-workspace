import { resolveTaskResponsibility, filterTasks, readTaskFilters } from "./data/github-data.mjs?v=20260924";
export { filterTasks };

const STATUS = {
  todo: { label: "待做", order: 2 },
  doing: { label: "进行中", order: 0 },
  review: { label: "待验收", order: 1 },
  done: { label: "已完成", order: 3 },
  cancelled: { label: "已取消", order: 4 },
};
const PHASES = { preparation: "命题前准备", production: "正式制作" };
const OPEN_STATUSES = new Set(["todo", "doing", "review"]);
const PAGE_SIZE = 12;
const state = { snapshot: null, status: "open", role: "all", phase: "all", query: "", visible: PAGE_SIZE, busy: false, phaseInitialized: false, initialRefreshStarted: false };
const $ = (id) => document.getElementById(id);
const ROLE_KEY = "gamejam.preferred-role";
function rememberedRole() { try { return localStorage.getItem(ROLE_KEY) || "all"; } catch { return "all"; } }
function rememberRole(value) { try { if (value === null) localStorage.removeItem(ROLE_KEY); else localStorage.setItem(ROLE_KEY, value); } catch { /* URL still keeps the current view. */ } }
function defaultPhase() { return state.snapshot?.phase.id in PHASES ? state.snapshot.phase.id : "all"; }
function viewURL() {
  const url = new URL(location.href);
  for (const key of ["role", "phase", "status"]) url.searchParams.set(key, state[key]);
  if (state.query.trim()) url.searchParams.set("q", state.query.trim()); else url.searchParams.delete("q");
  return url;
}
function updateFilters({ keepSearchInput = false } = {}) {
  state.visible = PAGE_SIZE;
  if (!keepSearchInput) controls.search.value = state.query;
  controls.role.value = state.role; controls.phase.value = state.phase;
  history.replaceState(null, "", viewURL());
  $("copy-feedback").textContent = "";
  renderTasks();
}
const controls = {
  refresh: $("refresh-button"), search: $("task-search"), role: $("role-filter"),
  phase: $("phase-filter"), statusButtons: [...document.querySelectorAll("[data-status]")],
};
const beijingTime = new Intl.DateTimeFormat("zh-CN", {
  timeZone: "Asia/Shanghai", year: "numeric", month: "2-digit", day: "2-digit",
  hour: "2-digit", minute: "2-digit", hourCycle: "h23",
});
const beijingDay = new Intl.DateTimeFormat("en-CA", {
  timeZone: "Asia/Shanghai", year: "numeric", month: "2-digit", day: "2-digit",
});

function element(tag, className = "", text = "") {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== "") node.textContent = text;
  return node;
}

function validDate(value) {
  if (!value) return null;
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? null : date;
}

function timestamp(value) {
  const date = validDate(value);
  return date ? beijingTime.format(date) : "时间未提供";
}

function calendarDay(value) {
  const date = validDate(value);
  if (!date) return "";
  const parts = Object.fromEntries(beijingDay.formatToParts(date).map((part) => [part.type, part.value]));
  return `${parts.year}-${parts.month}-${parts.day}`;
}

function httpUrl(value) {
  try {
    const url = new URL(value);
    return ["https:", "http:"].includes(url.protocol) ? url.href : "";
  } catch { return ""; }
}

function setLink(node, url) {
  const safe = httpUrl(url);
  if (safe) {
    node.href = safe;
    node.removeAttribute("aria-disabled");
    node.removeAttribute("tabindex");
  } else {
    node.removeAttribute("href");
    node.setAttribute("aria-disabled", "true");
    node.setAttribute("tabindex", "-1");
  }
  return !!safe;
}

function externalLink(url, className, text) {
  const link = element("a", className, text);
  link.target = "_blank";
  link.rel = "noopener noreferrer";
  setLink(link, url);
  return link;
}

function validateSnapshot(data) {
  if (!data || data.schema_version !== 1) throw new Error("项目数据版本不匹配，请等待页面更新。");
  if (!data.repository?.full_name || !httpUrl(data.repository.url) || !data.version?.sha) {
    throw new Error("项目数据缺少仓库或工程版本，暂不能展示进度。");
  }
  if (!data.phase || !validDate(data.generated_at)) throw new Error("项目阶段或同步时间缺失。");
  for (const field of ["tasks", "schedule", "roles"]) {
    if (!Array.isArray(data[field])) throw new Error(`项目数据缺少 ${field} 列表。`);
  }
  if (data.tasks.some((task) => !task || !(task.status in STATUS) || !Array.isArray(task.roles) || !Array.isArray(task.assignees))) {
    throw new Error("任务数据格式不完整，保留此前数据。");
  }
  if (data.schedule.some((item) => !validDate(item.at) || !["confirmed", "suggested"].includes(item.kind))) {
    throw new Error("排期日期或节点类型不完整，保留此前数据。");
  }
  return data;
}

function setBusy(busy, message) {
  state.busy = busy;
  controls.refresh.disabled = busy;
  controls.refresh.textContent = busy ? "更新中…" : "刷新 ↻";
  $("dashboard").setAttribute("aria-busy", String(busy));
  $("sync-bar").classList.toggle("is-loading", busy);
  if (message) $("sync-title").textContent = message;
}

function showSource(snapshot) {
  $("sync-bar").classList.remove("is-error");
  const live = snapshot.source?.mode === "live";
  $("sync-title").textContent = live ? "已同步" : "已载入快照";
  $("sync-detail").textContent = `${live ? "读取时间" : "生成时间"}：${timestamp(snapshot.generated_at)}（北京）`;
  $("source-note").textContent = "任务来自 GitHub Issues；共同版本取自 main。刷新失败时保留上次读取的内容。" + (snapshot.source?.note ? ` ${snapshot.source.note}` : "");
}

function showFailure(error) {
  $("sync-bar").classList.add("is-error");
  $("sync-title").textContent = "刷新失败";
  if (state.snapshot) {
    const kind = state.snapshot.source?.mode === "live" ? "上次读取数据" : "页面快照";
    $("sync-detail").textContent = `继续显示${kind} · ${timestamp(state.snapshot.generated_at)}（北京）`;
    $("source-note").textContent = `未能取得更新：${error.message || "网络连接失败"}。现有任务与版本未被更改。`;
  } else {
    $("sync-detail").textContent = "暂无可显示的快照，请重试或前往 GitHub。";
    $("load-error").hidden = false;
    $("load-error-message").textContent = error.message || "网络连接失败，请稍后重试。";
    $("phase-label").textContent = "数据暂不可用";
  }
}

async function loadSnapshot() {
  if (state.busy) return;
  setBusy(true, "正在读取页面快照");
  let loaded = false;
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 15000);
  try {
    const response = await fetch(`./data/snapshot.json?t=${Date.now()}`, { cache: "no-store", signal: controller.signal });
    if (!response.ok) throw new Error(`快照读取失败（HTTP ${response.status}），请重试或到 GitHub 查看。`);
    applySnapshot(await response.json());
    loaded = true;
  } catch (error) {
    showFailure(error.name === "AbortError" ? new Error("读取页面快照超时。") : error);
  } finally {
    clearTimeout(timeout);
    setBusy(false);
  }
  if (loaded && !state.initialRefreshStarted) {
    state.initialRefreshStarted = true;
    await refreshProject();
  }
}

async function refreshProject() {
  if (state.busy) return;
  if (!state.snapshot) { await loadSnapshot(); return; }
  setBusy(true, "正在读取 GitHub 当前状态");
  try {
    const { fetchGitHubData, createSnapshot } = await import("./data/github-data.mjs?v=20260924");
    const previous = state.snapshot;
    const latest = await fetchGitHubData({ repository: previous.repository.full_name, includeWorkspace: true, timeoutMs: 15000 });
    const next = createSnapshot({
      ...latest,
      generatedAt: new Date().toISOString(),
    });
    const mappingNote = next.source?.note || "";
    next.source = { ...next.source, mode: "live", note: mappingNote };
    applySnapshot(next);
  } catch (error) {
    showFailure(error);
  } finally { setBusy(false); }
}

export function applySnapshot(data) {
  const snapshot = validateSnapshot(data);
  state.snapshot = snapshot;
  if (!state.phaseInitialized) {
    Object.assign(state, readTaskFilters(location.search, { roles: snapshot.roles, defaultPhase: defaultPhase(), rememberedRole: rememberedRole() }));
    state.phaseInitialized = true;
  }
  $("dashboard").hidden = false;
  $("load-error").hidden = true;
  $("phase-label").textContent = snapshot.phase.label || PHASES[snapshot.phase.id] || snapshot.phase.id;
  $("phase-note").textContent = snapshot.phase.id === "preparation" ? "先完成工具与交接准备，命题后确定制作任务。" : "按岗位查看任务，交付后提交验收。";
  $("project-note").textContent = snapshot.phase.note || "";
  setLink($("repository-link"), snapshot.repository.url);
  setLink($("new-task-link"), `${snapshot.repository.url.replace(/\/$/, "")}/issues/new/choose`);
  renderVersion(snapshot);
  renderRoleOptions(snapshot.roles);
  controls.phase.value = state.phase; controls.search.value = state.query;
  renderTasks();
  renderSchedule(snapshot.schedule);
  renderResources(snapshot);
  const currentTasks = snapshot.tasks.filter(task => task.phase === snapshot.phase.id && OPEN_STATUSES.has(task.status));
  $("summary-task-label").textContent = `全队 · ${snapshot.phase.label || "当前阶段"}`;
  $("summary-open").textContent = `${currentTasks.length} 项待处理`;
  showSource(snapshot);
}

function renderVersion(snapshot) {
  const { version, repository, release } = snapshot;
  $("branch-label").textContent = repository.default_branch || "默认分支";
  $("commit-sha").textContent = version.short_sha || version.sha.slice(0, 8);
  $("commit-sha").title = version.sha;
  $("summary-version").textContent = `${repository.default_branch} · ${version.short_sha || version.sha.slice(0, 7)}`;
  $("summary-release").textContent = release ? `试玩版 ${release.tag}` : "试玩包尚未发布";
  $("commit-message").textContent = (version.message || "该提交未提供说明").split("\n")[0];
  $("commit-message").title = version.message || "";
  $("commit-time").textContent = `提交时间：${timestamp(version.committed_at)}（北京）`;
  setLink($("commit-link"), version.url);
  setLink($("source-download"), version.download_url);
  $("release-assets").replaceChildren();
  $("release-link").hidden = true;
  if (!release) {
    $("release-status").textContent = "未发布";
    $("release-status").className = "badge badge-neutral";
    $("release-note").textContent = "源码需用开发环境运行。";
    return;
  }
  $("release-status").textContent = release.tag || "已有发布";
  $("release-status").className = "badge badge-done";
  $("release-note").textContent = `${release.name || release.tag || "发布版本"} · ${timestamp(release.published_at)}（北京）`;
  for (const asset of release.assets || []) {
    if (!httpUrl(asset.url)) continue;
    const link = externalLink(asset.url, "asset-link", "");
    link.append(element("span", "", asset.name || "下载文件"), element("small", "", `${formatSize(asset.size)} ↓`));
    $("release-assets").append(link);
  }
  if (!$("release-assets").children.length) {
    $("release-assets").append(element("p", "supporting-text", "此发布尚未提供下载附件。"));
  }
  $("release-link").hidden = !setLink($("release-link"), release.url);
}

function formatSize(value) {
  if (!Number.isFinite(value) || value < 0) return "大小未提供";
  if (value < 1024) return `${value} B`;
  if (value < 1024 * 1024) return `${(value / 1024).toFixed(0)} KB`;
  return `${(value / 1024 / 1024).toFixed(1)} MB`;
}

function renderRoleOptions(roles) {
  controls.role.replaceChildren(new Option("全部岗位", "all"));
  for (const role of roles) controls.role.add(new Option(role.member ? `${role.name} · @${role.member}` : role.name, role.id));
  if (!roles.some((role) => role.id === state.role)) state.role = "all";
  controls.role.value = state.role;
}

function renderTaskOverview(tasks) {
  const phaseTasks = tasks;
  const eligible = phaseTasks.filter((task) => task.status !== "cancelled");
  const done = eligible.filter((task) => task.status === "done").length;
  const progress = eligible.length ? Math.round(done / eligible.length * 100) : 0;
  $("progress-label").textContent = eligible.length ? `已完成 ${done} / ${eligible.length} 项` : tasks.length ? "当前范围的任务均已取消，不计入进度" : "当前筛选范围暂无任务";
  const role = state.snapshot.roles.find(role => role.id === state.role)?.name || "全部岗位";
  $("progress-note").textContent = `${role} · ${PHASES[state.phase] || "全部阶段"}${state.query.trim() ? " · 搜索结果" : ""}`;
  $("progress-bar").hidden = state.phase === "all";
  if (state.phase === "all") {
    $("progress-label").textContent = Object.entries(PHASES).map(([id]) => {
      const phase = tasks.filter((task) => task.phase === id && task.status !== "cancelled");
      return `${id === "preparation" ? "准备" : "制作"} ${phase.filter((task) => task.status === "done").length}/${phase.length}`;
    }).join(" · ");
  }
  $("progress-fill").style.width = `${progress}%`;
  $("progress-bar").setAttribute("aria-valuenow", String(progress));
  $("progress-bar").setAttribute("aria-valuetext", eligible.length ? `${done} 项已完成，共 ${eligible.length} 项` : "尚无任务");
}

function renderTasks() {
  if (!state.snapshot) return;
  const snapshot = state.snapshot;
  const matching = filterTasks(snapshot.tasks, state, snapshot.roles);
  renderTaskOverview(matching);
  for (const node of document.querySelectorAll("[data-count]")) {
    node.textContent = matching.filter(task => node.dataset.count === "all" || (node.dataset.count === "open" ? OPEN_STATUSES.has(task.status) : task.status === node.dataset.count)).length;
  }
  const visibleTasks = matching.filter((task) => state.status === "all" || (state.status === "open" ? OPEN_STATUSES.has(task.status) : task.status === state.status));
  visibleTasks.sort((a, b) => STATUS[a.status].order - STATUS[b.status].order || (validDate(b.updated_at)?.getTime() || 0) - (validDate(a.updated_at)?.getTime() || 0));
  const page = visibleTasks.slice(0, state.visible);
  const roleNames = new Map(snapshot.roles.map((role) => [role.id, role.name]));
  $("task-list").replaceChildren(...page.map((task) => renderTask(task, roleNames, snapshot.roles)));
  $("results-summary").textContent = visibleTasks.length ? `共 ${visibleTasks.length} 项${page.length < visibleTasks.length ? `，当前显示 ${page.length} 项` : ""}` : "";
  $("show-more").hidden = page.length >= visibleTasks.length;
  $("show-more").textContent = `再显示 ${Math.min(PAGE_SIZE, visibleTasks.length - page.length)} 项任务`;
  $("clear-filters").hidden = state.role === "all" && state.phase === defaultPhase() && state.query === "" && state.status === "open";
  $("tasks-empty").hidden = visibleTasks.length > 0;
  if (!visibleTasks.length) {
    const noTasks = snapshot.tasks.length === 0;
    const noOpen = state.status === "open" && matching.length > 0;
    $("tasks-empty-title").textContent = noTasks ? "还没有发布任务" : noOpen ? "当前筛选下没有未完成任务" : "没有匹配的任务";
    $("tasks-empty-note").textContent = noTasks ? "团队任务发布后会出现在这里；需要建立任务时，点击上方“新建任务”。" : noOpen ? "可切换到“已完成”或“全部”查看其他记录。" : "调整岗位、阶段或搜索内容后再看。";
  }
  for (const button of controls.statusButtons) button.setAttribute("aria-pressed", String(button.dataset.status === state.status));
  for (const button of document.querySelectorAll("[data-team-role]")) button.setAttribute("aria-pressed", String(button.dataset.teamRole === state.role));
}

function renderResources(snapshot) {
  const base = snapshot.repository.url.replace(/\/$/, "");
  const fileURL = (path, tree = false) => `${base}/${tree ? "tree" : "blob"}/${snapshot.version.sha}/${path.split("/").map(encodeURIComponent).join("/")}`;
  setLink($("member-admin"), `${base}/settings/access`);
  $("team-list").replaceChildren(...snapshot.roles.map(role => {
    const card = element("div", "team-card");
    const button = element("button", "team-role", role.name);
    button.type = "button"; button.dataset.teamRole = role.id;
    button.setAttribute("aria-label", `筛选${role.name}的任务`);
    button.setAttribute("aria-pressed", String(state.role === role.id));
    button.addEventListener("click", () => {
      Object.assign(state, { role: role.id, phase: defaultPhase(), query: "", status: "open" });
      updateFilters(); $("tasks").scrollIntoView({ block: "start" }); controls.role.focus({ preventScroll: true });
    });
    card.append(button, role.member ? externalLink(`https://github.com/${encodeURIComponent(role.member)}`, "team-member", `@${role.member}`) : element("span", "metadata", "成员待登记"));
    if (role.workflow) card.append(externalLink(fileURL(role.workflow), "team-workflow", "岗位工作流 ↗"));
    return card;
  }));
  const links = [["docs/协作空间使用指南.md", "使用指南", false], ["docs/加入与同步.md", "加入与版本同步", false], ["planning", "已公开策划资料", true], ["docs/接口与交接.md", "接口与交接", false]];
  $("resource-links").replaceChildren(...links.map(([path, label, tree]) => externalLink(fileURL(path, tree), "resource-link", `${label} ↗`)));
}

function renderTask(task, roleNames, roles) {
  const item = element("li", "task-item");
  const link = externalLink(task.url, "task-card", "");
  const heading = element("div", "task-title-row");
  heading.append(element("span", "task-title", task.title), element("span", `badge badge-${task.status}`, STATUS[task.status].label));
  const details = element("div", "task-details");
  details.append(element("span", "task-number", `#${task.number}`));
  for (const role of task.roles) details.append(element("span", "task-role", roleNames.get(role) || role));
  details.append(element("span", "", PHASES[task.phase] || task.phase || "阶段未标注"));
  const responsibility = resolveTaskResponsibility(task, roles);
  const people = responsibility.logins.map((login) => `@${login}`).join("、");
  const responsibilityLabel = people
    ? `${responsibility.source === "assignees" ? "任务指派" : "岗位负责人"} ${people}`
    : "负责人待分配";
  details.append(element("span", "", responsibilityLabel));
  if (task.milestone) details.append(element("span", "", `里程碑：${task.milestone}`));
  const day = calendarDay(task.updated_at);
  details.append(element("span", "task-update", day ? `${day.slice(5).replace("-", "/")} 更新` : "更新时间未提供"));
  details.append(element("span", "external-mark", "↗"));
  link.append(heading, details);
  link.setAttribute("aria-label", `任务 ${task.number}：${task.title}，${STATUS[task.status].label}，前往 GitHub`);
  item.append(link);
  return item;
}

export function nodeHasArrived(node, now = new Date()) {
  if (node.date_only) return calendarDay(node.at) <= calendarDay(now);
  return validDate(node.at).getTime() <= now.getTime();
}

function renderSchedule(schedule) {
  const nodes = [...schedule].sort((a, b) => validDate(a.at) - validDate(b.at));
  const next = nodes.find((node) => !nodeHasArrived(node));
  $("summary-date").textContent = next ? `${Number(calendarDay(next.at).slice(5,7))}月${Number(calendarDay(next.at).slice(8,10))}日` : "暂无后续节点";
  $("summary-node").textContent = next ? `${next.title}${next.date_only ? "" : ` · ${timestamp(next.at).split(" ").at(-1)}`}` : "查看全部排期 ↓";
  $("schedule-list").replaceChildren();
  $("schedule-empty").hidden = nodes.length > 0;
  for (const node of nodes) {
    const item = element("li", "schedule-item");
    const top = element("div", "schedule-topline");
    const date = validDate(node.at);
    const parts = Object.fromEntries(beijingTime.formatToParts(date).map((part) => [part.type, part.value]));
    const label = element("time", "schedule-date", `${Number(parts.month)}月${Number(parts.day)}日`);
    label.dateTime = node.at;
    label.title = timestamp(node.at) + "（北京时间）";
    if (!node.date_only) label.append(element("span", "schedule-time", `${parts.hour}:${parts.minute}`));
    top.append(label);
    if (node === next) top.append(element("span", "next-node", "下一节点"));
    item.append(top, element("h3", "schedule-title", node.title));
    const meta = element("div", "schedule-meta");
    const kind = node.kind === "suggested" ? "suggested" : node.is_deadline ? "deadline" : "neutral";
    meta.append(element("span", `badge badge-${kind}`, node.kind === "suggested" ? "建议节点" : node.is_deadline ? "硬截止" : "确定节点"));
    if (nodeHasArrived(node)) meta.append(element("span", "schedule-arrived", "已到日期"));
    if (httpUrl(node.source_url)) meta.append(externalLink(node.source_url, "schedule-source", "查看依据 ↗"));
    item.append(meta);
    if (node.note) {
      const detail = element("details", "schedule-detail");
      detail.append(element("summary", "", "说明"), element("p", "schedule-note-text", node.note));
      item.append(detail);
    }
    $("schedule-list").append(item);
  }
}

controls.refresh.addEventListener("click", refreshProject);
$("task-filters").addEventListener("submit", (event) => event.preventDefault());
function updateSearch(event) {
  if (event.isComposing) return;
  state.query = controls.search.value;
  updateFilters({ keepSearchInput: true });
}
controls.search.addEventListener("input", updateSearch);
controls.search.addEventListener("compositionend", updateSearch);
controls.role.addEventListener("change", () => { state.role = controls.role.value; if ($("remember-role").checked) rememberRole(state.role); updateFilters(); });
controls.phase.addEventListener("change", () => { state.phase = controls.phase.value; updateFilters(); });
$("remember-role").addEventListener("change", () => rememberRole($("remember-role").checked ? state.role : null));
for (const button of controls.statusButtons) {
    button.addEventListener("click", () => { state.status = button.dataset.status; updateFilters(); });
}
$("clear-filters").addEventListener("click", () => {
  Object.assign(state, { status: "open", role: "all", phase: defaultPhase(), query: "" });
  updateFilters();
});
$("summary-open").closest("a").addEventListener("click", () => {
  Object.assign(state, { status: "open", role: "all", phase: defaultPhase(), query: "" }); updateFilters();
});
$("copy-view").addEventListener("click", async () => {
  const url = viewURL(); url.hash = "tasks";
  try { await navigator.clipboard.writeText(url.href); $("copy-feedback").textContent = "已复制，可打开同样的任务筛选。"; }
  catch { $("copy-feedback").textContent = "复制未成功，可直接复制浏览器地址。"; }
});
window.addEventListener("popstate", () => {
  if (!state.snapshot) return;
  Object.assign(state, readTaskFilters(location.search, { roles: state.snapshot.roles, defaultPhase: defaultPhase(), rememberedRole: rememberedRole() }));
  updateFilters();
});
$("show-more").addEventListener("click", () => { state.visible += PAGE_SIZE; renderTasks(); });
loadSnapshot();
