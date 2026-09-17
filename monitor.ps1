<#
.SYNOPSIS
    中国联通"资费专区"加装包 —— 5G上网服务方案监控脚本

.DESCRIPTION
    直接调用联通资费专区后端接口，抓取指定地区、指定业务分类下的全部资费方案，
    筛选"其他服务内容"中包含 5G上网服务 / 5G-A上网服务（下行峰值 xGbps / xxxMbps）
    的方案，并二次筛选出"智慧沃家共享版"用户可订购的方案。

    每次运行输出两组数据：
      第一组：所有命中 5G上网服务 相关内容的方案编号
      第二组：第一组中，智慧沃家共享版用户可订购的方案编号

.PARAMETER ConfigPath
    配置文件路径，默认同目录 config.json

.PARAMETER NoArchive
    不写历史归档目录（只更新 output/latest）

.PARAMETER SelfTest
    只做接口连通性自检，不抓全量数据

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\monitor.ps1
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$NoArchive,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

# ---------------------------------------------------------------------------
# TLS：接口只接受 TLS 1.2+（实测 TLS 1.0/1.1 会 "Could not create SSL/TLS secure
# channel"），而 PowerShell 5.1 的默认协议取决于机器上的 .NET，旧机器会停在
# TLS 1.0。这里显式固定；万一环境不支持也不致命，继续用系统默认值尝试。
# ---------------------------------------------------------------------------
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

# ---------------------------------------------------------------------------
# 基础路径
# ---------------------------------------------------------------------------
$Root = $PSScriptRoot
if (-not $Root) { $Root = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $ConfigPath) { $ConfigPath = Join-Path $Root 'config.json' }
elseif (-not [System.IO.Path]::IsPathRooted($ConfigPath)) { $ConfigPath = Join-Path $Root $ConfigPath }

$OutputRoot = Join-Path $Root 'output'
$LatestDir  = Join-Path $OutputRoot 'latest'
$HistoryDir = Join-Path $OutputRoot 'history'
$LogDir     = Join-Path $OutputRoot 'logs'
$dirsToCreate = @($OutputRoot, $LatestDir, $LogDir)
if (-not $NoArchive) { $dirsToCreate += $HistoryDir }   # -NoArchive 时不再建空的 history 目录
foreach ($d in $dirsToCreate) {
    if (-not (Test-Path -LiteralPath $d)) { [void](New-Item -ItemType Directory -Path $d -Force) }
}

$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Write-Utf8File([string]$Path, [string]$Text) {
    # 临时文件 + 覆盖式改名 + 重试：避免"文件正被其它程序占用"时半途失败，
    # 也避免别处读到写了一半的内容（summary.txt 被记事本/OneDrive/杀软占用很常见）。
    # 注意：这里不能用 [IO.File]::Replace($tmp,$Path,$null) —— PowerShell 会把 $null
    # 绑成空字符串，抛 "The path is not of a legal form"（实测），所以用 Move-Item -Force。
    $tmp = $Path + '.tmp'
    [System.IO.File]::WriteAllText($tmp, $Text, $script:Utf8NoBom)
    for ($i = 1; $i -le 5; $i++) {
        try {
            Move-Item -LiteralPath $tmp -Destination $Path -Force -ErrorAction Stop
            return
        } catch {
            if ($i -ge 5) {
                try { [System.IO.File]::Delete($tmp) } catch { }
                throw ('写入失败（已重试 5 次）：' + $Path + ' —— ' + $_.Exception.Message)
            }
            Start-Sleep -Milliseconds 200
        }
    }
}
function Read-Utf8File([string]$Path) {
    return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
}

# ---------------------------------------------------------------------------
# 日志
# ---------------------------------------------------------------------------
$script:LogFile = Join-Path $LogDir ('monitor-' + (Get-Date -Format 'yyyy-MM') + '.log')

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '[' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '][' + $Level + '] ' + $Message
    $color = 'Gray'
    if ($Level -eq 'WARN')  { $color = 'Yellow' }
    if ($Level -eq 'ERROR') { $color = 'Red' }
    if ($Level -eq 'OK')    { $color = 'Green' }
    Write-Host $line -ForegroundColor $color
    # 日志写不进去（例如另一个实例正占着）不应该杀掉整个监控，重试几次即可
    for ($i = 1; $i -le 5; $i++) {
        try { [System.IO.File]::AppendAllText($script:LogFile, $line + [Environment]::NewLine, $script:Utf8NoBom); return }
        catch { Start-Sleep -Milliseconds 200 }
    }
    Write-Host ('（日志文件写入失败，已跳过：' + $script:LogFile + '）') -ForegroundColor DarkYellow
}

function Stop-WithLog {
    # 启动阶段的致命错误：既写日志也退出（run-monitor.cmd 提示用户去看 output\logs，
    # 所以配置类错误必须留下记录）
    param([string]$Message)
    Write-Log ('启动失败：' + $Message) 'ERROR'
    exit 1
}

# ---------------------------------------------------------------------------
# 互斥：计划任务与手动运行同时跑会互相覆盖 output\latest 与日志
#（计划任务的 -MultipleInstances IgnoreNew 只防"任务 vs 任务"）
# ---------------------------------------------------------------------------
try { $script:RunMutex = New-Object System.Threading.Mutex($false, 'Global\UnicomPlanMonitor') }
catch { $script:RunMutex = New-Object System.Threading.Mutex($false, 'Local\UnicomPlanMonitor') }
$script:GotLock = $false
try { $script:GotLock = $script:RunMutex.WaitOne(0) }
catch [System.Threading.AbandonedMutexException] { $script:GotLock = $true }   # 上次被强杀，锁被放弃，本次视为拿到
catch { $script:GotLock = $true }                                            # 锁本身出问题时不阻塞运行
if (-not $script:GotLock) {
    Write-Log '已有一次运行正在进行，本次跳过（互斥锁被占用）' 'WARN'
    exit 3
}

# ---------------------------------------------------------------------------
# 配置：读取 + 体检
#   注意 config.json 必须是 UTF-8。存成 ANSI/GBK 时中文会解成 U+FFFD，
#   所有中文正则随之失效，而脚本会"正常"跑出「第一组 0 个」——必须拦下来。
# ---------------------------------------------------------------------------
try {
if (-not (Test-Path -LiteralPath $ConfigPath)) { throw ('配置文件不存在：' + $ConfigPath) }
$cfgText = Read-Utf8File $ConfigPath
if ($cfgText -match "\uFFFD") {
    throw 'config.json 不是有效的 UTF-8（很可能被保存成了 ANSI/GBK），请用记事本 / VS Code 另存为 UTF-8 后重试'
}
try { $cfg = $cfgText | ConvertFrom-Json }
catch { throw ('config.json 不是合法 JSON：' + $_.Exception.Message) }

# 空正则在 .NET 里会匹配任意字符串，缺键又会静默变成空串，这里逐项校验
$patternKeys = [ordered]@{
    'keywords.contentPattern'  = $cfg.keywords.contentPattern
    'wojia.negativePattern'    = $cfg.wojia.negativePattern
    'wojia.positivePattern'    = $cfg.wojia.positivePattern
    'wojia.restrictionPattern' = $cfg.wojia.restrictionPattern
}
foreach ($k in $patternKeys.Keys) {
    $v = [string]$patternKeys[$k]
    if ([string]::IsNullOrWhiteSpace($v)) { throw ('config.json 缺少必要的正则：' + $k) }
    try { [void](New-Object System.Text.RegularExpressions.Regex($v)) }
    catch { throw ('config.json 的 ' + $k + ' 不是合法正则：' + $_.Exception.Message) }
}
if ([string]::IsNullOrWhiteSpace([string]$cfg.api.baseUrl)) { throw 'config.json 缺少 api.baseUrl' }
if (-not $cfg.region.provinceId -or -not $cfg.region.cityId) { throw 'config.json 缺少 region.provinceId / region.cityId' }

$firstNamesCfg  = @($cfg.scan.firstLevelNames)
$secondNamesCfg = @($cfg.scan.secondLevelNames)
if ($firstNamesCfg.Count -eq 0 -or $secondNamesCfg.Count -eq 0) { throw 'config.json 的 scan.firstLevelNames / scan.secondLevelNames 不能为空' }
foreach ($ta in @($cfg.scan.tariffAttributes)) {
    if (@(1, 2) -notcontains [int]$ta) { throw ('config.json 的 scan.tariffAttributes 只能是 1（全国资费）或 2（本省资费），收到：' + $ta) }
}

$wojiaModeCfg = [string]$cfg.wojia.mode
if ([string]::IsNullOrWhiteSpace($wojiaModeCfg)) { $wojiaModeCfg = 'explicit' }
if ($wojiaModeCfg -notin @('explicit', 'strict')) { throw ('config.json 的 wojia.mode 只能是 explicit 或 strict（当前：' + $wojiaModeCfg + '）') }

$script:UA         = 'Mozilla/5.0 (iPhone; CPU iPhone OS 15_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.0 Mobile/15E148 Safari/604.1'
$script:BatchLimit = 100   # 接口硬上限：一次请求携带的 ID 数（实测 100 正常，101 返回 code=0001「查询超过数量限制」）
$script:Retry      = [int]$cfg.http.retry
$script:DelayMs    = [int]$cfg.http.delayMs
$script:Batch      = [int]$cfg.http.batchSize

if ($script:Retry -lt 1) { $script:Retry = 1 }
if ($script:DelayMs -lt 0) { $script:DelayMs = 0 }
if ($script:Batch -lt 1) {
    throw ('config.json 的 http.batchSize 必须 >= 1（当前：' + $cfg.http.batchSize + '）；为 0 会让取明细的循环永远不前进')
}
if ($script:Batch -gt $script:BatchLimit) {
    Write-Log ('http.batchSize=' + $script:Batch + ' 超过接口上限 ' + $script:BatchLimit + '，本次按 ' + $script:BatchLimit + ' 处理') 'WARN'
    $script:Batch = $script:BatchLimit
}
} catch {
    # 配置类错误也要落到日志里：run-monitor.cmd 提示用户「See output\logs for details」，
    # 而配置错误原先发生在 try 之外，日志里一个字都没有。
    Stop-WithLog $_.Exception.Message
}

# ---------------------------------------------------------------------------
# HTTP：PowerShell 5.1 的 Invoke-RestMethod 会把无 charset 的响应按 Latin-1
# 解码导致中文乱码，因此这里用 WebClient 并显式指定 UTF-8。
# ---------------------------------------------------------------------------
function Invoke-UnicomPost {
    param([string]$Url, [hashtable]$Form)

    $pairs = @()
    foreach ($k in $Form.Keys) {
        $pairs += ([uri]::EscapeDataString([string]$k) + '=' + [uri]::EscapeDataString([string]$Form[$k]))
    }
    $body = $pairs -join '&'

    $attempt = 0
    while ($true) {
        $attempt++
        $wc = New-Object System.Net.WebClient
        try {
            $wc.Headers.Add('Content-Type', 'application/x-www-form-urlencoded')
            $wc.Headers.Add('User-Agent', $script:UA)
            $wc.Headers.Add('Origin', 'https://img.client.10010.com')
            $wc.Headers.Add('Referer', 'https://img.client.10010.com/')
            $wc.Encoding = [System.Text.Encoding]::UTF8
            return $wc.UploadString($Url, 'POST', $body)
        }
        catch {
            if ($attempt -ge $script:Retry) { throw }
            Write-Log ('请求失败（第 ' + $attempt + ' 次），2 秒后重试：' + $_.Exception.Message) 'WARN'
            Start-Sleep -Seconds 2
        }
        finally { $wc.Dispose() }
    }
}

function New-CommonForm {
    param([hashtable]$Extra)
    $b = @{
        provinceId      = [string]$cfg.region.provinceId
        cityId          = [string]$cfg.region.cityId
        behaviorId      = ''
        version         = 'WT'
        duanlianjieabc  = ''
        channelCode     = ''
        serviceType     = ''
        saleChannel     = ''
        externalSources = ''
        contactCode     = ''
    }
    if ($Extra) { foreach ($k in $Extra.Keys) { $b[$k] = $Extra[$k] } }
    return $b
}

function Invoke-Api {
    param([string]$Path, [hashtable]$Extra)
    $url  = ([string]$cfg.api.baseUrl).TrimEnd('/') + $Path
    $form = New-CommonForm $Extra
    # 传输层异常（连接被断等）由 Invoke-UnicomPost 重试；这里覆盖另外两种情况：
    # HTTP 200 但返回的不是 JSON（被代理/网关拦截），以及 code != '0000'。
    # 线上实测出现过「中间设备返回非 JSON 内容，导致一个分类整类丢失」，重试一次即可。
    for ($attempt = 1; $attempt -le $script:Retry; $attempt++) {
        $txt = Invoke-UnicomPost -Url $url -Form $form
        $obj = $null
        $why = ''
        try { $obj = $txt | ConvertFrom-Json }
        catch { $why = '返回内容不是 JSON：' + $_.Exception.Message }
        if ($null -ne $obj) {
            if ([string]$obj.code -eq '0000') { return $obj }
            $why = 'code=' + $obj.code + ' msg=' + $obj.msg
        }
        if ($attempt -ge $script:Retry) { throw ('接口返回异常：Path=' + $Path + ' ' + $why) }
        Write-Log ('接口返回异常（第 ' + $attempt + ' 次），2 秒后重试：' + $why) 'WARN'
        Start-Sleep -Seconds 2
    }
}

# ---------------------------------------------------------------------------
# 数据抓取
# ---------------------------------------------------------------------------
function Get-IndexData {
    Write-Log '读取资费专区目录结构（indexData）...'
    return (Invoke-Api '/queryTariffNew/indexData' @{})
}

function Get-ThirdLevelOptions {
    param([int]$TariffAttributes, [string]$FirstLevel, [string]$SecondLevel)
    $r = Invoke-Api '/queryTariffNew/threeLevelName' @{
        tariffAttributes = $TariffAttributes
        firstLevel       = $FirstLevel
        secondLevel      = $SecondLevel
    }
    if ($null -eq $r.data -or $null -eq $r.data.dataList) { return @() }
    return @($r.data.dataList)
}

function Get-PlanDetails {
    param([string[]]$Ids)
    $all = New-Object System.Collections.ArrayList
    $total = $Ids.Count
    # 双保险：即使配置被改坏也不会死循环（step=0）或超过接口上限
    $step = [Math]::Max(1, [Math]::Min($script:Batch, $script:BatchLimit))
    for ($i = 0; $i -lt $total; $i += $step) {
        $end = [Math]::Min($i + $step - 1, $total - 1)
        $chunk = $Ids[$i..$end]
        $path = '/queryTariffNew/operateData/' + ($chunk -join '_')
        $r = Invoke-Api $path @{ page = 1; size = 200 }
        if ($null -ne $r.data -and $null -ne $r.data.detailList) {
            foreach ($it in $r.data.detailList) { [void]$all.Add($it) }
        }
        if ($script:DelayMs -gt 0) { Start-Sleep -Milliseconds $script:DelayMs }
    }
    return $all
}

# ---------------------------------------------------------------------------
# 筛选逻辑
# ---------------------------------------------------------------------------
function Test-ContentPattern {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $false }
    return ($Text -match [string]$cfg.keywords.contentPattern)
}

# 返回：allowed / excluded / unclear / unmentioned
function Get-WoJiaVerdict {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return 'unmentioned' }
    if (-not ($Text -match '智慧沃家')) { return 'unmentioned' }
    # 排除条款优先于"其余用户可办理"这类表述
    if ($Text -match [string]$cfg.wojia.negativePattern) { return 'excluded' }
    if ($Text -match [string]$cfg.wojia.positivePattern) { return 'allowed' }
    return 'unclear'
}

function Get-WoJiaClause {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $m = [regex]::Matches($Text, '[^。；;]*智慧沃家[^。；;]*')
    if ($m.Count -eq 0) { return '' }
    return (($m | ForEach-Object { $_.Value.Trim() }) -join ' | ')
}

# 判断"适用范围"是否把可办理人群限定到别的主套餐/用户群
function Get-RestrictionInfo {
    param([string]$UseScope)
    if ([string]::IsNullOrEmpty($UseScope)) { return [pscustomobject]@{ Restricted = $false; Note = '' } }
    $m = [regex]::Match($UseScope, [string]$cfg.wojia.restrictionPattern)
    if ($m.Success) { return [pscustomobject]@{ Restricted = $true; Note = $m.Value } }
    return [pscustomobject]@{ Restricted = $false; Note = '' }
}

function ConvertTo-PlanRecord {
    param($Item, [string]$CategoryName, [string]$ScopeName, [string]$TariffAttributes)
    # 判定文本只用「适用范围 + 其他事项」。
    # 方案名称不参与判定：名字里带「（智慧沃家共享版）」是产品归属标记，不是订购限制，
    # 把它算进来会把专门面向智慧沃家共享版用户的产品判成"不能订购"。
    $verdictText = @(
        [string]$Item.useScope,
        [string]$Item.otherDesc
    ) -join '。'

    $ri = Get-RestrictionInfo ([string]$Item.useScope)

    return [pscustomobject][ordered]@{
        reportNo         = [string]$Item.reportNo
        name             = [string]$Item.name
        category         = $CategoryName
        scope            = $ScopeName
        tariffAttr       = $TariffAttributes
        codeType         = [string]$Item.codeType
        feesStandard     = ([string]$Item.feesStandard) + ([string]$Item.feeUnit)
        serviceContent   = [string]$Item.serviceContent
        useScope         = [string]$Item.useScope
        saleChnl         = [string]$Item.saleChnl
        wojiaStatus      = (Get-WoJiaVerdict $verdictText)
        wojiaClause      = (Get-WoJiaClause $verdictText)
        scopeRestricted  = $ri.Restricted
        restrictionNote  = $ri.Note
    }
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
$startTime = Get-Date
Write-Log '============================================================'
Write-Log ('联通加装包 5G 上网服务方案监控 —— 开始运行  ' + $startTime.ToString('yyyy-MM-dd HH:mm:ss'))
Write-Log ('地区：' + $cfg.region.provinceName + '-' + $cfg.region.cityName + ' (provinceId=' + $cfg.region.provinceId + ', cityId=' + $cfg.region.cityId + ')')
Write-Log '============================================================'

try {
    $index = Get-IndexData

    $firstNames  = @($cfg.scan.firstLevelNames)
    $secondNames = @($cfg.scan.secondLevelNames)

    $targets = New-Object System.Collections.ArrayList
    foreach ($fl in $index.data.levelList) {
        if ($firstNames -notcontains [string]$fl.firstLevelName) { continue }
        foreach ($sl in $fl.secondLevels) {
            if ($secondNames -notcontains [string]$sl.secondLevelName) { continue }
            [void]$targets.Add([pscustomobject]@{
                FirstLevel      = [string]$fl.firstLevel
                FirstLevelName  = [string]$fl.firstLevelName
                SecondLevel     = [string]$sl.secondLevel
                SecondLevelName = [string]$sl.secondLevelName
            })
        }
    }
    if ($targets.Count -eq 0) { throw '未匹配到任何分类，请检查 config.json 的 scan.firstLevelNames / secondLevelNames' }
    Write-Log ('待扫描分类：' + (($targets | ForEach-Object { $_.FirstLevelName + '>' + $_.SecondLevelName }) -join '、'))

    # 差集检查：config.json 里写了、但页面上已经找不到的分类名。
    # 上游改名 / 配置打错字会让扫描范围静默缩水，而报告里的「扫描范围」还写着原名，
    # 于是没扫到的那部分方案会被误报成「下线」——这里把这种运行判定为"结果不完整"。
    $apiFirstAll  = @($index.data.levelList | ForEach-Object { [string]$_.firstLevelName } | Select-Object -Unique)
    $apiSecondAll = @($index.data.levelList | Where-Object { $firstNames -contains [string]$_.firstLevelName } |
                      ForEach-Object { $_.secondLevels } | ForEach-Object { [string]$_.secondLevelName } | Select-Object -Unique)
    $missingFirst  = @($firstNames  | Where-Object { $apiFirstAll  -notcontains $_ })
    $missingSecond = @($secondNames | Where-Object { $apiSecondAll -notcontains $_ })
    $scopeChanged  = ($missingFirst.Count -gt 0 -or $missingSecond.Count -gt 0)
    if ($scopeChanged) {
        Write-Log ('配置里的分类在页面上不存在：一级=[' + ($missingFirst -join '、') + '] 二级=[' + ($missingSecond -join '、') +
                   ']；页面现有二级分类=[' + ($apiSecondAll -join '、') + ']') 'WARN'
    }

    if ($SelfTest) {
        # 自检不能只看目录：真的走一遍 threeLevelName + operateData，确认数据链路可用。
        # （batchSize 配错、接口路径变更、被网关拦成非 JSON 这类问题，原来在自检里看不出来。）
        $probe = $targets[0]
        $probeTa = [int](@($cfg.scan.tariffAttributes)[0])
        $probeScope = '全国资费'
        if ($probeTa -eq 2) { $probeScope = '本省资费' }
        $opts = @(Get-ThirdLevelOptions -TariffAttributes $probeTa -FirstLevel $probe.FirstLevel -SecondLevel $probe.SecondLevel)
        Write-Log ('自检：目录读取成功；抽查 ' + $probe.FirstLevelName + '>' + $probe.SecondLevelName + '（' + $probeScope + '）选项 ' + $opts.Count + ' 个') 'OK'
        if ($opts.Count -eq 0) {
            Write-Log '自检：抽查分类没有可选项，无法验证明细接口（可能是该分类暂时为空）' 'WARN'
        } else {
            $probeIds = @($opts | Select-Object -First ([Math]::Min(3, $opts.Count)) | ForEach-Object { [string]$_.id })
            $probePlans = @(Get-PlanDetails -Ids $probeIds)
            Write-Log ('自检：明细接口返回 ' + $probePlans.Count + ' 条 / 请求 ' + $probeIds.Count + ' 个 ID') 'OK'
            if ($probePlans.Count -ne $probeIds.Count) {
                Write-Log '自检失败：明细条数与请求的 ID 数不一致（接口变更或 batchSize 超限？）' 'ERROR'
                exit 1
            }
        }
        Write-Log '自检模式：接口连通正常，目录与明细接口均可用。' 'OK'
        exit 0
    }

    $rawRecords = New-Object System.Collections.ArrayList
    $failedScans = New-Object System.Collections.ArrayList
    foreach ($t in $targets) {
        foreach ($ta in @($cfg.scan.tariffAttributes)) {
            $taInt   = [int]$ta
            $scopeNm = '全国资费'
            if ($taInt -eq 2) { $scopeNm = '本省资费' }
            try {
                $opts = Get-ThirdLevelOptions -TariffAttributes $taInt -FirstLevel $t.FirstLevel -SecondLevel $t.SecondLevel
                if ($opts.Count -eq 0) {
                    Write-Log ('  ' + $t.SecondLevelName + ' / ' + $scopeNm + '：无可选项，跳过')
                    continue
                }
                $ids = @($opts | ForEach-Object { [string]$_.id })
                $details = Get-PlanDetails -Ids $ids
                # 注意：$details 只有一条时是单个对象，5.1 里标量 .Count 为空，会打出"方案  条"
                $planCount = @($details).Count
                Write-Log ('  ' + $t.SecondLevelName + ' / ' + $scopeNm + '：选项 ' + $ids.Count + ' 个 → 方案 ' + $planCount + ' 条')
                foreach ($d in $details) {
                    [void]$rawRecords.Add((ConvertTo-PlanRecord -Item $d -CategoryName $t.SecondLevelName -ScopeName $scopeNm -TariffAttributes $taInt))
                }
            }
            catch {
                [void]$failedScans.Add($t.SecondLevelName + ' / ' + $scopeNm)
                Write-Log ('  ' + $t.SecondLevelName + ' / ' + $scopeNm + ' 抓取失败：' + $_.Exception.Message) 'ERROR'
            }
        }
    }
    Write-Log ('共抓取方案 ' + $rawRecords.Count + ' 条') 'OK'

    # -----------------------------------------------------------------------
    # 抓取失败处理：绝不能把"没抓到"当成"没有了"
    #   - 全部失败：抛错退出，保留上次结果，不覆盖 output\latest
    #   - 部分失败：结果写到 partial_*.json，跳过新增/下线对比，以退出码 2 结束
    # -----------------------------------------------------------------------
    $failedCount = $failedScans.Count
    $isPartial   = ($failedCount -gt 0 -or $scopeChanged)
    if ($failedCount -gt 0) {
        Write-Log ('本次有 ' + $failedCount + ' 个分类抓取失败：' + ($failedScans -join '、')) 'WARN'
        if ($rawRecords.Count -eq 0) {
            throw ('全部 ' + $failedCount + ' 个分类抓取失败，未抓到任何方案；保留上次结果，不覆盖 output\latest')
        }
    }
    if ($scopeChanged) {
        Write-Log '扫描范围与配置不一致（见上面的 WARN），本次按"结果不完整"处理' 'WARN'
    }

    # 按方案编号去重：同一个方案号可能同时挂在本省资费与全国资费下，
    # 用 (reportNo, scope) 做键会把它算成两条（计数翻倍、编号重复、重复报"新增"）。
    $groupA = @($rawRecords | Where-Object { Test-ContentPattern $_.serviceContent } |
        Group-Object reportNo | ForEach-Object {
            $first = $_.Group[0]
            $first.scope = (($_.Group | Select-Object -ExpandProperty scope -Unique) -join ',')
            $first
        } | Sort-Object reportNo)

    # 二次筛选：智慧沃家共享版
    #   explicit 模式（默认）：只剔除"适用范围里明确写了智慧沃家共享版不能订购"的方案
    #   strict 模式：额外剔除"适用范围限定为其他主套餐用户"的方案
    $wojiaMode  = [string]$cfg.wojia.mode
    if ([string]::IsNullOrEmpty($wojiaMode)) { $wojiaMode = 'explicit' }

    $passWoJia = @($groupA | Where-Object { $_.wojiaStatus -ne 'excluded' -and $_.wojiaStatus -ne 'unclear' })
    if ($wojiaMode -eq 'strict') {
        $groupB = @($passWoJia | Where-Object { -not $_.scopeRestricted })
    } else {
        $groupB = $passWoJia
    }
    $removed = @($groupA | Where-Object {
        $_.wojiaStatus -eq 'excluded' -or $_.wojiaStatus -eq 'unclear' -or
        ($wojiaMode -eq 'strict' -and $_.scopeRestricted)
    })
    $openScope = @($passWoJia | Where-Object { -not $_.scopeRestricted })

    Write-Log ('第一组（5G内容命中）：' + $groupA.Count + ' 个方案') 'OK'
    Write-Log ('第二组（智慧沃家共享版可订购，模式=' + $wojiaMode + '）：' + $groupB.Count + ' 个方案') 'OK'
    Write-Log ('  其中适用范围未限定其他主套餐的：' + $openScope.Count + ' 个') 'OK'
    if ($removed.Count -gt 0) { Write-Log ('  被剔除：' + $removed.Count + ' 个') 'WARN' }

    $prevFile = Join-Path $LatestDir 'groupA_all_matches.json'
    $prevNos = @()
    if (Test-Path -LiteralPath $prevFile) {
        try {
            $prev = (Read-Utf8File $prevFile) | ConvertFrom-Json
            $prevNos = @($prev | ForEach-Object { [string]$_.reportNo })
        } catch { Write-Log '上次结果读取失败，跳过对比' 'WARN' }
    }
    $nowNos   = @($groupA | ForEach-Object { [string]$_.reportNo })
    if ($isPartial) {
        # 结果不完整，本次不做对比：否则会把没抓到的方案误报成"下线"
        $newOnes  = @()
        $goneOnes = @()
        Write-Log '结果不完整，本次跳过「新增/下线」对比' 'WARN'
    } else {
        $newOnes  = @($nowNos | Where-Object { $prevNos -notcontains $_ })
        $goneOnes = @($prevNos | Where-Object { $nowNos -notcontains $_ })
    }

    $stamp = $startTime.ToString('yyyy-MM-dd_HHmmss')
    $groupAJson = '[]'
    $groupBJson = '[]'
    if ($groupA.Count -eq 1) { $groupAJson = '[' + ($groupA | ConvertTo-Json -Depth 6) + ']' }
    elseif ($groupA.Count -gt 1) { $groupAJson = ($groupA | ConvertTo-Json -Depth 6) }
    if ($groupB.Count -eq 1) { $groupBJson = '[' + ($groupB | ConvertTo-Json -Depth 6) + ']' }
    elseif ($groupB.Count -gt 1) { $groupBJson = ($groupB | ConvertTo-Json -Depth 6) }

    # 结果不完整 / 扫描范围与配置不一致时：本次结果只写 partial_* 文件，绝不碰
    # 用作"上次结果基线"的正式文件。完整运行则等到 summary 与归档都写成功之后，
    # 才在最后统一更新正式文件（基线最后写，避免"基线前进但报告没写完"）。
    $filePrefix = ''
    if ($isPartial) {
        $filePrefix = 'partial_'
        Write-Utf8File (Join-Path $LatestDir ($filePrefix + 'groupA_all_matches.json')) $groupAJson
        Write-Utf8File (Join-Path $LatestDir ($filePrefix + 'groupB_wojia_eligible.json')) $groupBJson
    }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('============================================================')
    [void]$sb.AppendLine('联通加装包 5G 上网服务方案监控报告')
    [void]$sb.AppendLine('生成时间：' + $startTime.ToString('yyyy-MM-dd HH:mm:ss'))
    if ($isPartial) {
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('！！本次运行结果不完整，未更新正式结果文件！！')
        if ($failedCount -gt 0) {
            [void]$sb.AppendLine('有 ' + $failedCount + ' 个分类抓取失败：')
            foreach ($f in $failedScans) { [void]$sb.AppendLine('  - ' + $f) }
        }
        if ($scopeChanged) {
            [void]$sb.AppendLine('配置里的分类在页面上不存在（可能被上游改名）：')
            if ($missingFirst.Count)  { [void]$sb.AppendLine('  - 一级分类：' + ($missingFirst -join '、')) }
            if ($missingSecond.Count) { [void]$sb.AppendLine('  - 二级分类：' + ($missingSecond -join '、')) }
        }
        [void]$sb.AppendLine('以下内容只反映本次实际抓到的部分，见 partial_*.json 与 partial_summary.txt。')
    }
    [void]$sb.AppendLine('地区：' + $cfg.region.provinceName + '-' + $cfg.region.cityName)
    [void]$sb.AppendLine('扫描范围：' + (($targets | ForEach-Object { $_.FirstLevelName + '>' + $_.SecondLevelName }) -join '、'))
    $scopeNames = @($cfg.scan.tariffAttributes | ForEach-Object { if ([int]$_ -eq 2) { '本省资费' } else { '全国资费' } })
    [void]$sb.AppendLine('扫描口径：' + ($scopeNames -join ' + '))
    [void]$sb.AppendLine('匹配规则：其他服务内容 =~ /' + $cfg.keywords.contentPattern + '/')
    [void]$sb.AppendLine('============================================================')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('【第一组】"其他服务内容"含 5G上网服务/5G-A上网服务（下行峰值…）的方案')
    [void]$sb.AppendLine('共 ' + $groupA.Count + ' 个')
    [void]$sb.AppendLine('------------------------------------------------------------')
    $idx = 0
    foreach ($p in $groupA) {
        $idx++
        [void]$sb.AppendLine(('{0,3}. {1}  {2}  [{3}/{4}]' -f $idx, $p.reportNo, $p.name, $p.category, $p.scope))
        [void]$sb.AppendLine('     其他服务内容：' + $p.serviceContent)
        [void]$sb.AppendLine('     适用范围：' + $p.useScope)
        $extra = ''
        if ($p.wojiaClause) { $extra = ' —— ' + $p.wojiaClause }
        [void]$sb.AppendLine('     智慧沃家共享版：' + $p.wojiaStatus + $extra)
        if ($p.scopeRestricted) {
            [void]$sb.AppendLine('     订购限制：适用范围限定了其他主套餐（命中“' + $p.restrictionNote + '”）')
        } else {
            [void]$sb.AppendLine('     订购限制：无主套餐限定')
        }
        [void]$sb.AppendLine('')
    }
    [void]$sb.AppendLine('【第二组】其中，智慧沃家共享版用户可订购的方案')
    [void]$sb.AppendLine('筛选模式：' + $wojiaMode + '（explicit=剔除文案中明确排除智慧沃家共享版的方案，以及提到「智慧沃家」但排除/允许规则都没命中的 unclear；strict=再额外剔除适用范围限定其他主套餐的）')
    [void]$sb.AppendLine('共 ' + $groupB.Count + ' 个')
    [void]$sb.AppendLine('------------------------------------------------------------')
    [void]$sb.AppendLine((($groupB | ForEach-Object { $_.reportNo }) -join ', '))
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('【参考】第二组中，适用范围未限定其他主套餐的方案（智慧沃家共享版用户最可能可直接订购）')
    [void]$sb.AppendLine('共 ' + $openScope.Count + ' 个')
    [void]$sb.AppendLine('------------------------------------------------------------')
    if ($openScope.Count -eq 0) {
        [void]$sb.AppendLine('（无。本次命中的方案，适用范围都限定了其他主套餐或其他用户群，详见上面每个方案的“订购限制”。）')
    } else {
        [void]$sb.AppendLine((($openScope | ForEach-Object { $_.reportNo }) -join ', '))
    }
    [void]$sb.AppendLine('')
    if ($removed.Count -gt 0) {
        [void]$sb.AppendLine('【被剔除】因智慧沃家共享版限制剔除的方案')
        [void]$sb.AppendLine('------------------------------------------------------------')
        foreach ($p in $removed) {
            [void]$sb.AppendLine($p.reportNo + '  ' + $p.name + '  [' + $p.wojiaStatus + '] ' + $p.wojiaClause)
        }
        [void]$sb.AppendLine('')
    }
    [void]$sb.AppendLine('【与上次运行对比】')
    if ($isPartial) {
        [void]$sb.AppendLine('本次抓取不完整，未做对比（避免把没抓到的方案误报成“下线”）。')
    } else {
        if ($newOnes.Count) { [void]$sb.AppendLine('新增方案：' + ($newOnes -join ', ')) } else { [void]$sb.AppendLine('新增方案：无') }
        if ($goneOnes.Count) { [void]$sb.AppendLine('下线方案：' + ($goneOnes -join ', ')) } else { [void]$sb.AppendLine('下线方案：无') }
    }
    $summary = $sb.ToString()

    Write-Utf8File (Join-Path $LatestDir ($filePrefix + 'summary.txt')) $summary

    if ($isPartial) {
        Write-Log '结果不完整，跳过历史归档' 'WARN'
    } elseif (-not $NoArchive) {
        $archiveDir = Join-Path $HistoryDir $stamp
        if (-not (Test-Path -LiteralPath $archiveDir)) { [void](New-Item -ItemType Directory -Path $archiveDir -Force) }
        Write-Utf8File (Join-Path $archiveDir 'groupA_all_matches.json') $groupAJson
        Write-Utf8File (Join-Path $archiveDir 'groupB_wojia_eligible.json') $groupBJson
        Write-Utf8File (Join-Path $archiveDir 'summary.txt') $summary
        Write-Log ('历史归档：' + $archiveDir)
    }

    # 最后才更新「上次结果基线」：summary 与归档都写成功之后，才让基线前进。
    # 否则一旦中途失败，基线已经变了而报告还是旧的，本次的"新增"事件会永久丢失。
    if (-not $isPartial) {
        $newJson = '[]'
        if ($newOnes.Count -eq 1) { $newJson = '[' + ($newOnes | ConvertTo-Json) + ']' }
        elseif ($newOnes.Count -gt 1) { $newJson = ($newOnes | ConvertTo-Json) }
        Write-Utf8File (Join-Path $LatestDir 'new_since_last_run.json') $newJson
        Write-Utf8File (Join-Path $LatestDir 'groupB_wojia_eligible.json') $groupBJson
        Write-Utf8File (Join-Path $LatestDir 'groupA_all_matches.json') $groupAJson
    }

    Write-Log '----------- 汇总 -----------'
    $aNos = '无'; if ($groupA.Count) { $aNos = ($groupA | ForEach-Object { $_.reportNo }) -join ', ' }
    $bNos = '无'; if ($groupB.Count) { $bNos = ($groupB | ForEach-Object { $_.reportNo }) -join ', ' }
    Write-Log ('第一组方案编号：' + $aNos)
    Write-Log ('第二组方案编号：' + $bNos)
    if ($isPartial) {
        $why = @()
        if ($failedCount -gt 0) { $why += ($failedCount.ToString() + ' 个分类抓取失败') }
        if ($scopeChanged)      { $why += '扫描范围与配置不一致' }
        Write-Log ('新增：未对比（结果不完整：' + ($why -join '；') + '）') 'WARN'
        Write-Log '下线：未对比（结果不完整）' 'WARN'
    } else {
        if ($newOnes.Count) { Write-Log ('新增：' + ($newOnes -join ', ')) } else { Write-Log '新增：无' }
        if ($goneOnes.Count) { Write-Log ('下线：' + ($goneOnes -join ', ')) } else { Write-Log '下线：无' }
    }
    Write-Log ('结果目录：' + $LatestDir)
    Write-Log ('耗时 ' + [int]((Get-Date) - $startTime).TotalSeconds + ' 秒') 'OK'
    if ($isPartial) {
        Write-Log '结果不完整，以退出码 2 结束' 'WARN'
        exit 2
    }
    exit 0
}
catch {
    Write-Log ('运行失败：' + $_.Exception.Message) 'ERROR'
    Write-Log ($_.ScriptStackTrace) 'ERROR'
    exit 1
}
