# Three.js 环境配置与调试指南

核查日期：2026-09-16。适用环境：Windows PowerShell。

本指南用于题目公布前的工具练习。熟悉时间可参考 1.5—2 小时，按个人基础调整；题前学习不计入正式比赛每人 12 小时。Three.js 与 Godot 均为备选工具，各由熟悉该方向的成员代表练习，全员无需同时学习两套工具。正式技术路线与具体任务在十月题目公布后确定，练习代码能否带入比赛以赛事规则为准。

本轮已查询官方资料、核对已有环境，并在临时目录安装本例依赖、生成锁文件和验证构建；临时目录在核验后清理，未创建正式游戏工程。下列命令供成员练习时执行，实际验证范围见文末。

## 1. 先确认环境与版本

本路线只需要 Node.js、npm、Three.js、Vite，以及现有代码编辑器和现代浏览器。Three.js 负责三维画面，Vite 负责开发服务和构建，无需额外安装前端框架或编辑器插件。官方入门也采用 npm 与构建工具的组合。[Three.js 安装说明](https://github.com/mrdoob/three.js/blob/dev/manual/pages/installation.html)

| 项目 | 本次核查结果 | 练习采用方式 |
|---|---|---|
| Node.js | 本机已有 24.15.0 | 先沿用，团队记录使用版本 |
| npm | 本机已有 11.12.1 | PowerShell 中使用 npm.cmd |
| Git | 本机已有 2.53.0.windows.3 | 获取工程时使用 |
| Three.js | 官方 npm registry 当前版本 0.186.0 | 新建练习固定为 0.186.0 |
| Vite | 官方 npm registry 当前版本 8.3.0 | 新建练习固定为 8.3.0 |

Vite 8.3.0 声明的 Node 要求为 `^20.19.0 || >=22.12.0`，本机 24.15.0 满足。Node 24 在核查日属于 LTS 系列。最低兼容版本与推荐维护版本用途不同，新装环境优先采用团队统一的受支持 LTS；已有项目继续遵循自己的版本说明。[Vite 入门](https://vite.dev/guide/)、[Vite 包信息](https://registry.npmjs.org/vite/latest)、[Node 发布状态](https://nodejs.org/en/about/previous-releases)

在自己的机器上先执行：

```powershell
node --version
npm.cmd --version
git --version
```

若找不到命令，先确认安装位置、重新打开终端，再处理缺失项。尚未安装 Node 时，从 [Node 官方下载页](https://nodejs.org/en/download) 获取 Windows LTS 安装包；安装后重新执行以上检查。版本满足要求时无需为了跟随“最新”临时升级。

以下命令逐块执行，出现错误时先停止并处理该错误。出现 npm.ps1 执行策略限制时使用 npm.cmd，不要求更改全局 PowerShell 执行策略。

## 2. 新建练习工程

仅当你需要一个全新练习目录时执行本节。已有工程直接转到第 3 节，不执行 npm init，也不覆盖其入口文件。

下面将练习放在独立的 `E:\gamejam\练习\threejs`，与其他工具练习分开。其他成员可将 `E:\gamejam` 换成自己已有的工作目录。目录已存在时停止，先确认其中内容。

```powershell
Set-Location -LiteralPath 'E:\gamejam'
$practiceDir = Join-Path (Get-Location) '练习\threejs'
if (Test-Path -LiteralPath $practiceDir) {
    throw '练习目录已经存在，请使用已有工程步骤，或选一个新的空目录。'
}
New-Item -ItemType Directory -Path $practiceDir | Out-Null
Set-Location -LiteralPath $practiceDir
npm.cmd init -y
```

成功后设置本工程命令，并安装固定版本：

```powershell
npm.cmd pkg set type=module "scripts.dev=vite" "scripts.build=vite build" "scripts.preview=vite preview"
npm.cmd install --save-exact three@0.186.0
npm.cmd install --save-dev --save-exact vite@8.3.0
npm.cmd ls three vite --depth=0
```

保留 `package.json` 与 `package-lock.json`。前者描述依赖和启动命令，后者记录完整依赖版本。上述版本来自核查日的官方包信息；以后更新依赖由工程维护者统一操作，其他人按锁文件恢复。[Three.js 包信息](https://registry.npmjs.org/three/latest)、[npm install](https://docs.npmjs.com/cli/v11/commands/npm-install/)

在练习目录新建 `.gitignore`，内容如下；已有文件只补充缺失项：

```gitignore
node_modules/
dist/
*.log
```

提交源码、入口、配置及两个 package 文件。不要提交 node_modules，也不要把它发给队友作为安装方法。

## 3. 获取已有工程与恢复依赖

已在本地的工程直接进入包含 `package.json` 的目录。需要首次获取仓库时，将变量改为队内提供的真实地址，再执行：

```powershell
Set-Location -LiteralPath 'E:\gamejam'
$repoUrl = '填写队内提供的仓库地址'
git clone $repoUrl '.\练习\threejs-team'
Set-Location -LiteralPath '.\练习\threejs-team'
```

先读该工程的 README、Node 版本要求与包管理器说明。以下步骤适用于采用 npm 且已经提交 package-lock.json 的工程：

```powershell
Get-Content -Raw -LiteralPath '.\package.json'
npm.cmd ci
npm.cmd run
```

`npm ci` 按锁文件安装，若锁文件与 package.json 不一致会报错；已有 node_modules 会被重建。遇到不一致先与工程维护者确认，保留团队锁文件。若确实是尚未建立锁文件的新工程，由维护者执行一次 npm install 并提交结果。[npm ci](https://docs.npmjs.com/cli/v11/commands/npm-ci/)

沿用已有工程的脚本、目录和依赖版本。第 4 节示例只写入第 2 节新建的空练习工程；已有工程可以另建独立练习目录，避免替换业务文件。

## 4. 做出最小可见画面

在新建练习目录中，用现有编辑器分别创建以下两个 UTF-8 文件。本例不依赖贴图或外部模型，先验证画面、按钮与窗口缩放。

`index.html`：

```html
<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Three.js 工具练习</title>
  <style>
    html, body { margin: 0; width: 100%; height: 100%; overflow: hidden; }
    canvas { display: block; }
    #toggle { position: fixed; top: 16px; left: 16px; z-index: 1; padding: 10px 16px; }
  </style>
</head>
<body>
  <button id="toggle" type="button">暂停旋转</button>
  <script type="module" src="./main.js"></script>
</body>
</html>
```

`main.js`：

```javascript
import * as THREE from 'three';

const world = new THREE.Scene();
world.background = new THREE.Color('#182132');
const view = new THREE.PerspectiveCamera(50, 1, 0.1, 50);
view.position.set(0, 0, 4);

const drawing = new THREE.WebGLRenderer({ antialias: true });
drawing.setPixelRatio(Math.min(window.devicePixelRatio, 2));
document.body.appendChild(drawing.domElement);

const shape = new THREE.Mesh(
  new THREE.BoxGeometry(1.2, 1.2, 1.2),
  new THREE.MeshNormalMaterial()
);
world.add(shape);

let spinning = true;
let previousTime;
const toggle = document.querySelector('#toggle');
toggle.addEventListener('click', () => {
  spinning = !spinning;
  toggle.textContent = spinning ? '暂停旋转' : '继续旋转';
});

function fitWindow() {
  view.aspect = window.innerWidth / window.innerHeight;
  view.updateProjectionMatrix();
  drawing.setSize(window.innerWidth, window.innerHeight);
}
window.addEventListener('resize', fitWindow);
fitWindow();

drawing.setAnimationLoop((time) => {
  const elapsed = previousTime === undefined ? 0 : (time - previousTime) / 1000;
  previousTime = time;
  if (spinning) {
    shape.rotation.y += Math.min(elapsed, 0.1) * 0.8;
    shape.rotation.x += Math.min(elapsed, 0.1) * 0.4;
  }
  drawing.render(world, view);
});
```

场景、相机、渲染器共同组成最小渲染过程；本例使用无需额外灯光的法线材质，便于先排查环境。当前 WebGLRenderer 使用 WebGL 2，浏览器与显卡环境也要满足要求。[WebGLRenderer 官方说明](https://threejs.org/docs/pages/WebGLRenderer.html)

## 5. 启动 localhost 开发服务

确认终端位于包含 package.json 的练习目录：

```powershell
npm.cmd run dev -- --host localhost --port 5173 --strictPort
```

终端保持运行，在浏览器打开 [本地开发地址](http://localhost:5173/)。看到旋转方块后点击按钮，检查暂停与继续；缩放浏览器窗口，检查画面比例。停止服务使用 Ctrl+C。固定端口被占用时，该命令会报错；确认原服务用途后，关闭自己启动的旧服务，或将端口改为 5174。

使用 HTTP 地址运行。双击 index.html 形成的 file:// 地址会绕过 Vite，依赖解析与资源请求可能失败。默认 localhost 只用于本机；另一台机器的 localhost 指向它自己。

## 6. 用浏览器定位错误

以 Chrome 为例按 F12 打开开发者工具，按以下顺序检查：

1. **Console**：刷新页面，先读第一条与本工程有关的红色错误。点击文件名与行号，定位实际代码，记录完整错误文字。
2. **Network**：保持面板打开再刷新，检查 main.js、贴图、模型等请求状态。404 先核对路径与大小写；返回 HTML 的模型请求通常说明 URL 指向了错误页面。
3. **Sources**：在按钮回调中 `spinning = !spinning` 一行设置断点，点击按钮，查看变量和调用栈，再继续运行。也可开启异常暂停寻找抛错位置。
4. 修改源文件并保存，观察开发服务是否刷新。若修改了依赖或配置，按终端提示重启服务。

完成一次主动调试练习：暂时把 index.html 中的 `./main.js` 写错，使用 Network 找到失败请求，再改回并确认恢复。只在练习文件操作。[Console](https://developer.chrome.com/docs/devtools/console)、[Network](https://developer.chrome.com/docs/devtools/network)、[断点](https://developer.chrome.com/docs/devtools/javascript/breakpoints)

## 7. 验证构建产物

先停止开发服务，再执行：

```powershell
npm.cmd run build
```

成功后应生成 dist。继续执行本地产物预览：

```powershell
npm.cmd run preview -- --host localhost --port 4173 --strictPort
```

打开 [本地产物预览](http://localhost:4173/)，重复方块、按钮、缩放与 Console／Network 检查。改了源码后要重新 build，preview 才会显示新的构建内容。

Vite preview 用于本地检查 dist。它不承担正式部署；正式发布需要将 dist 内的内容交给选定的静态托管平台，再验证实际地址。本轮先学会构建与本地检查，不创建发布站点。[Vite 构建与产物预览](https://vite.dev/guide/static-deploy.html)

## 8. 加入资源时处理路径

先跑通无外部资源的示例，再加入一份自己的小贴图或模型。URL 使用正斜杠，文件名大小写保持一致。

| 放置位置 | 推荐引用方式 | 注意 |
|---|---|---|
| main.js 同级的 assets 文件夹 | `new URL('./assets/test.png', import.meta.url).href` | 路径写成可静态分析的字符串，由 Vite 处理构建后的地址 |
| 工程根部 public 文件夹 | `import.meta.env.BASE_URL + 'models/test.glb'` | 实际文件放 public/models/test.glb，URL 不含 public |
| 其他机器磁盘 | 先复制到工程资源目录 | 浏览器资源不能引用 E:\\ 或其他人的本地绝对路径 |

当需要加载模型时，使用同一 three 包中的 `three/addons/loaders/GLTFLoader.js`，保持核心库与加载器同版本；具体加载代码在学到模型导入时再添加。[Three.js 安装与附加组件](https://github.com/mrdoob/three.js/blob/dev/manual/pages/installation.html)、[Vite 静态资源](https://vite.dev/guide/assets.html)

若未来托管地址带子目录，应按实际路径设置 base。尚未确定托管路径的独立练习，可在根目录新建 `vite.config.js`：

```javascript
import { defineConfig } from 'vite';

export default defineConfig({
  base: './'
});
```

已有配置就在原配置中调整对应字段，保留其他设置。base 修改后重新构建；相对 base 适用于本指南的简单页面，涉及前端路由、动态拼接地址时要按实际入口继续验证。它不会修复拼错的文件名，也不替代 HTTP 服务。[Vite base 路径](https://vite.dev/guide/build.html#public-base-path)

## 9. 常见故障

| 现象 | 先查什么 | 对应处理 |
|---|---|---|
| npm.ps1 无法运行 | 调用的是 npm 还是 npm.cmd | 改用 npm.cmd，不改全局执行策略 |
| 找不到 package.json | 终端当前目录 | 进入真正的工程根目录，不在上级目录重复初始化 |
| EBADENGINE | Node 实际版本、工程要求 | 对齐团队版本，重新打开终端核对 |
| npm ci 提示锁文件不同步 | 是否拉齐 package.json 与锁文件 | 由维护者处理依赖变更；不要自行删锁文件继续 |
| 依赖下载失败 | 首条错误、网络、实际 registry | 用 `npm.cmd config get registry` 核对；先定位网络问题，保留锁文件 |
| 端口占用 | 旧终端中的开发／预览服务 | 关闭自己启动的服务或换端口 |
| 页面空白、无法解析 three | Console、是否使用 HTTP、依赖是否安装 | 从 Vite 地址打开，检查 npm ci 结果 |
| WebGL 上下文创建失败 | 浏览器 WebGL 2、硬件加速与显卡环境 | 对照浏览器错误信息处理；换可用机器复测 |
| 有画布但看不到对象 | 相机位置、对象是否加入场景、是否调用 render | 与第 4 节最小例对照，先恢复基线 |
| 开发正常，构建后资源 404 | base、大小写、动态 URL、资源是否进入 dist | 按第 8 节调整后重新 build |
| preview 仍显示旧效果 | 上次 build 时间 | 修改源码后重新 build，再刷新页面 |
| build 提示部分包超过 500 kB | 命令退出状态、是否生成 dist、提示是警告还是错误 | 本例实测存在体积警告且构建成功；后续按真实需求优化，不为消除提示先修改警告阈值 |
| 模型解析失败 | Network 返回内容、Git LFS 素材是否完整 | 确认拿到真实模型文件，再检查格式和加载器 |

## 10. 练习完成条件与本次验证记录

完成条件：

- [ ] 能说明本机 Node、npm、Three.js、Vite 版本。
- [ ] 新建工程或从仓库恢复依赖成功，使用同一份锁文件。
- [ ] localhost 中画面可见，按钮有效，窗口缩放正常。
- [ ] 能通过 Console／Network 或断点找到一次错误并修复。
- [ ] build 成功，preview 中重复检查通过。
- [ ] 换一个干净目录或交给另一成员按 README 恢复，结果一致。

| 本次实际检查 | 状态 |
|---|---|
| 本机 Node／npm／Git 版本 | 已查询，见第 1 节 |
| 当前 Three.js／Vite 包版本与 Node 要求 | 已查询官方 registry 与文档 |
| 文内 8 段 PowerShell 与 2 段 JavaScript | 已通过语法检查；实际执行范围见下两项 |
| 安装依赖、生成锁文件 | 已在临时目录通过；安装结果为 three 0.186.0、vite 8.3.0 |
| 示例原文构建 | 已通过 npm run build，生成 dist；有体积警告，退出状态为成功 |
| 示例浏览器运行、按钮与缩放 | 本次未执行 |
| 产物预览、另一机器复现 | 本次未执行 |

学习时直接在练习工程 README 中补充“使用版本、启动命令、构建命令、实际结果、遗留问题”，无需另建多份过程报告。完成条件按实际运行结果勾选。

## 官方资料索引

版本链接会随发布更新，本指南上表记录的是 2026-09-16 的查询结果。

- [Three.js 官方仓库安装说明](https://github.com/mrdoob/three.js/blob/dev/manual/pages/installation.html)、[WebGLRenderer](https://threejs.org/docs/pages/WebGLRenderer.html)。
- [Three.js registry](https://registry.npmjs.org/three/latest)、[Vite registry](https://registry.npmjs.org/vite/latest)、[Node 发布状态](https://nodejs.org/en/about/previous-releases)。
- [Vite 入门](https://vite.dev/guide/)、[构建与 base](https://vite.dev/guide/build.html)、[资源路径](https://vite.dev/guide/assets.html)、[构建产物预览](https://vite.dev/guide/static-deploy.html)。
- [npm 11 install](https://docs.npmjs.com/cli/v11/commands/npm-install/)、[npm 11 ci](https://docs.npmjs.com/cli/v11/commands/npm-ci/)。
- [Chrome Console](https://developer.chrome.com/docs/devtools/console)、[Network](https://developer.chrome.com/docs/devtools/network)、[断点](https://developer.chrome.com/docs/devtools/javascript/breakpoints)。
