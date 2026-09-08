# 联通资费专区 · 加装包 5G 上网服务方案监控

监控中国联通资费专区（<https://img.client.10010.com/zifeizhuanquwt/index.html>）中
**河北-沧州 · 加装包** 下的资费方案，筛出「其他服务内容」里含
**5G上网服务 / 5G-A上网服务（下行峰值 xGbps / xxxMbps）** 的方案，
再二次筛出**智慧沃家共享版用户可订购**的方案。

每 12 小时自动跑一次，每次产出两组数据。

---

## 一、运行环境

| 项目 | 要求 |
|---|---|
| 操作系统 | Windows 10 / 11 |
| 运行时 | 系统自带的 **Windows PowerShell 5.1** |
| 第三方依赖 | **无**。不需要安装 Node.js、Python、Chrome，也不下载浏览器内核 |

> 本机实测：Node.js 与 Python 均未安装，因此脚本用 PowerShell 直接调接口实现，
> 不依赖任何需要额外安装的东西。

---

## 二、快速开始

### 1. 先自检（确认接口通、地区对）

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File D:\3_ai\unicom-monitor\monitor.ps1 -SelfTest
```

### 2. 手动跑一次

```bash
D:\3_ai\unicom-monitor\run-monitor.cmd
```

跑完后看 `output\latest\summary.txt`，这就是本次的两组结果。

### 3. 注册每 12 小时自动运行

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File D:\3_ai\unicom-monitor\setup-task.ps1
```

默认注册计划任务 `UnicomPlanMonitor`，每天 **08:00 和 20:00** 各跑一次。

注册完想立刻验证一次：

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File D:\3_ai\unicom-monitor\setup-task.ps1 -RunNow
```

查看任务状态：

```bash
powershell -NoProfile -Command "Get-ScheduledTask -TaskName UnicomPlanMonitor | Get-ScheduledTaskInfo"
```

卸载任务：

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File D:\3_ai\unicom-monitor\setup-task.ps1 -Remove
```

---

## 三、目录结构

```
unicom-monitor\
├── monitor.ps1            主脚本
├── config.json            配置（地区、分类、关键词、筛选规则）
├── run-monitor.cmd        运行入口（双击即可，也是计划任务的调用目标）
├── setup-task.ps1         注册/卸载每 12 小时的计划任务
├── README.md              本文件
├── output\
│   ├── latest\            最近一次结果（每次覆盖）
│   │   ├── groupA_all_matches.json       第一组：5G 内容命中的全部方案
│   │   ├── groupB_wojia_eligible.json    第二组：其中智慧沃家共享版可订购的
│   │   ├── new_since_last_run.json       相比上次新增的方案编号
│   │   └── summary.txt                   人看的汇总报告（推荐先看这个）
│   ├── history\           按时间戳归档的历次结果
│   │   └── 2026-09-09_021836\...
│   └── logs\              运行日志（按月份一个文件）
├── tools\                 当初用来逆向接口/验证数据的探索脚本，可删
└── _obsolete-nodejs\      早期 Node.js/Puppeteer 方案的残留文件，可删
```

---

## 四、两组数据分别是什么

### 第一组 `groupA_all_matches.json`
所有**「其他服务内容」命中 5G 上网服务**的方案（`config.json` 里
`keywords.contentPattern` 的正则）。

### 第二组 `groupB_wojia_eligible.json`
第一组里，**智慧沃家共享版用户可订购**的方案。筛选规则见下一节。

### 汇总报告 `summary.txt`
除了上面两组编号，还逐条列出每个命中方案的「其他服务内容」「适用范围」
「智慧沃家判定」「订购限制」，方便人工核对。

---

## 五、筛选规则（重点）

### 1. 第一组怎么判「命中 5G 上网服务」

接口返回的每个方案有个字段 `serviceContent`，页面上就是**「其他服务内容」**。
联通把 5G 上网服务按速率分档，实际文案有三种写法：

| 实际文案 | 含义 |
|---|---|
| `包含5G基础服务（下行峰值速率最高300Mbps）。` | 5G 基础档 |
| `包含5G优享服务（下行峰值速率最高500Mbps）。` | 5G 优享档 |
| `并享有5G上网服务（下行峰值1Gbps，该速率仅主卡使用，主副卡不可共享）` | 5G 上网服务 |
| `包含5G极速服务（下行峰值速率最高1Gbps）` | 5G 极速档 |

所以默认正则是：

```
5G-A?上网服务|5G-A?基础服务|5G-A?优享服务|5G-A?极速服务|5G-A?尝鲜网速|下行峰值|下行速率最高
```

要收窄/放宽，改 `config.json` 的 `keywords.contentPattern` 即可。

### 2. 第二组怎么判「智慧沃家共享版可订购」

判据来自方案字段 `useScope`（页面上是**「适用范围」**），
再叠上「其他事项」和「方案名称」。规则：

1. 文案里**出现「智慧沃家」且命中排除条款** → 判定 `excluded`，剔除。
   排除条款示例（都来自真实数据）：
   - `智慧沃家共享版用户不可互联网渠道订购`
   - `智慧沃家共享版用户不支持线上订购`
   - `主卡、智慧沃家共享版成员用户不可办理`
   - `除2I、达量限速、智慧沃家共享版用户外，其余河北联通移网用户均可订购`
   - `智慧沃家5G极享“三千兆”融合套餐用户与联通PLUS会员互斥，不能订购`
2. 文案里出现「智慧沃家」且命中允许条款 → 判定 `allowed`，保留。
   例如：`河北联通移网手机用户及智慧沃家共享版成员可订购。`
3. 出现「智慧沃家」但两条都不匹配 → 判定 `unclear`，**保守按不可订购处理**。
4. 文案里**没提「智慧沃家」** → 判定 `unmentioned`，保留。

### 3. 两种筛选模式（`config.json` → `wojia.mode`）

| 模式 | 行为 | 适用场景 |
|---|---|---|
| `explicit`（默认） | 只剔除**文案中明确写了智慧沃家不能订购**的方案 | 严格按你原话「将智慧沃家共享版用户不能订购的方案去除」 |
| `strict` | 再额外剔除**适用范围限定为其他主套餐用户**的方案（如「仅限腾讯王卡套餐用户办理」「适用于订购5G畅越冰激凌升级版39元」） | 想只看真正能下单的 |

> **重要提醒**：截至 2026-09-09 的实测数据，第一组命中的 27 个方案里，
> **没有一个**在适用范围中排除智慧沃家共享版，所以默认 `explicit` 模式下
> 第二组和第一组完全相同。但其中 **26 个都限定了别的主套餐**
> （王卡系列、畅越冰激凌升级版），普通智慧沃家共享版用户实际是订不了的。
> 报告里的「【参考】」小节会把这类方案的编号单独列出来（本次为 0 个）。
> 如果你想要的就是「真正能下单的」，把 `wojia.mode` 改成 `strict`。

---

## 六、配置说明（`config.json`）

| 配置项 | 说明 |
|---|---|
| `region.provinceId / cityId` | 地区编码。河北=018，沧州=180。换地区时同时改 `provinceName / cityName` |
| `scan.firstLevelNames` | 一级选项卡，默认 `["加装包"]` |
| `scan.secondLevelNames` | 二级选项卡，默认六个全扫。页面同一时间只能选一个，脚本会自动逐个扫 |
| `scan.tariffAttributes` | `2`=本省资费，`1`=全国资费。默认两个都扫 |
| `keywords.contentPattern` | 第一组的内容匹配正则 |
| `wojia.mode` | `explicit` / `strict`，见上 |
| `wojia.negativePattern` / `positivePattern` | 智慧沃家的排除 / 允许条款正则 |
| `wojia.restrictionPattern` | 判断适用范围是否限定其他主套餐的正则 |
| `http.batchSize` | 每次接口请求携带的方案 ID 数，默认 80 |
| `http.delayMs` | 请求间隔毫秒，默认 150 |

### 只扫「权益包」和「其他」

把 `scan.secondLevelNames` 改成：

```json
"secondLevelNames": ["权益包", "其他"]
```

### 想连主套餐一起扫

把 `scan.firstLevelNames` 改成 `["加装包", "套餐"]`。
（腾讯王卡5G版 99/129/159/199/239/299/399 元套餐的「其他服务内容」里
也写着「包含5G优享服务（下行峰值速率最高500Mbps）」这类内容。）

---

## 七、常见问题

**Q：脚本是怎么拿到数据的？会不会因为页面改版失效？**
A：脚本直接调用资费专区的后端接口，不走浏览器：

| 用途 | 接口 |
|---|---|
| 读取目录（一级/二级选项卡） | `POST /servicequerybusiness/queryTariffNew/indexData` |
| 读取三级选项（页面上的「全选」那一层） | `POST /servicequerybusiness/queryTariffNew/threeLevelName` |
| 读取方案明细 | `POST /servicequerybusiness/queryTariffNew/operateData/{方案ID以下划线连接}` |

页面改版如果改了接口路径或参数，脚本会在日志里报
`接口返回异常：Path=... code=...`，不会静默给出错误结果。

**Q：为什么输出里有的字段是 `unmentioned`？**
A：表示该方案的适用范围文案里没提「智慧沃家」，即**没有明确排除**它。
这不等于一定能办——还要看适用范围有没有限定别的主套餐。

**Q：报告里中文乱码？**
A：`output\latest\summary.txt` 和 JSON 都是 UTF-8。用 VS Code / 记事本
（Win10 1903 以上）打开即可。PowerShell 控制台里如果乱码，先执行
`chcp 65001`。

**Q：跑一次多久？**
A：实测约 27 秒（扫 6 个二级分类 × 本省+全国，共 2162 条方案）。

**Q：历史归档会不会越积越多？**
A：每次运行会在 `output\history\` 下建一个时间戳目录，每个目录约 50 KB。
按每 12 小时一次算，一年约 1.8 MB，可以忽略。想关掉就用
`-NoArchive` 参数运行。
