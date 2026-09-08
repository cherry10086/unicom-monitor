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
# 基础路径
# ---------------------------------------------------------------------------
$Root = $PSScriptRoot
if (-not $Root) { $Root = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $ConfigPath) { $ConfigPath = Join-Path $Root 'config.json' }

$OutputRoot = Join-Path $Root 'output'
$LatestDir  = Join-Path $OutputRoot 'latest'
$HistoryDir = Join-Path $OutputRoot 'history'
$LogDir     = Join-Path $OutputRoot 'logs'
foreach ($d in @($OutputRoot, $LatestDir, $HistoryDir, $LogDir)) {
    if (-not (Test-Path $d)) { [void](New-Item -ItemType Directory -Path $d -Force) }
}

$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Write-Utf8File([string]$Path, [string]$Text) {
    [System.IO.File]::WriteAllText($Path, $Text, $script:Utf8NoBom)
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
    [System.IO.File]::AppendAllText($script:LogFile, $line + [Environment]::NewLine, $script:Utf8NoBom)
}

# ---------------------------------------------------------------------------
# 配置
# ---------------------------------------------------------------------------
if (-not (Test-Path $ConfigPath)) { throw ('配置文件不存在：' + $ConfigPath) }
$cfg = (Read-Utf8File $ConfigPath) | ConvertFrom-Json

$script:UA      = 'Mozilla/5.0 (iPhone; CPU iPhone OS 15_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.0 Mobile/15E148 Safari/604.1'
$script:Retry   = [int]$cfg.http.retry
$script:Batch   = [int]$cfg.http.batchSize
$script:DelayMs = [int]$cfg.http.delayMs

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
    $url = ([string]$cfg.api.baseUrl).TrimEnd('/') + $Path
    $txt = Invoke-UnicomPost -Url $url -Form (New-CommonForm $Extra)
    $obj = $txt | ConvertFrom-Json
    if ($obj.code -ne '0000') {
        throw ('接口返回异常：Path=' + $Path + ' code=' + $obj.code + ' msg=' + $obj.msg)
    }
    return $obj
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
    for ($i = 0; $i -lt $total; $i += $script:Batch) {
        $end = [Math]::Min($i + $script:Batch - 1, $total - 1)
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
    $verdictText = @(
        [string]$Item.useScope,
        [string]$Item.otherDesc,
        [string]$Item.name
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

    if ($SelfTest) {
        Write-Log '自检模式：接口连通正常，目录读取成功。' 'OK'
        exit 0
    }

    $rawRecords = New-Object System.Collections.ArrayList
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
                Write-Log ('  ' + $t.SecondLevelName + ' / ' + $scopeNm + '：选项 ' + $ids.Count + ' 个 → 方案 ' + $details.Count + ' 条')
                foreach ($d in $details) {
                    [void]$rawRecords.Add((ConvertTo-PlanRecord -Item $d -CategoryName $t.SecondLevelName -ScopeName $scopeNm -TariffAttributes $taInt))
                }
            }
            catch {
                Write-Log ('  ' + $t.SecondLevelName + ' / ' + $scopeNm + ' 抓取失败：' + $_.Exception.Message) 'ERROR'
            }
        }
    }
    Write-Log ('共抓取方案 ' + $rawRecords.Count + ' 条') 'OK'

    $groupA = @($rawRecords | Where-Object { Test-ContentPattern $_.serviceContent } | Sort-Object reportNo, scope -Unique)

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
    if (Test-Path $prevFile) {
        try {
            $prev = (Read-Utf8File $prevFile) | ConvertFrom-Json
            $prevNos = @($prev | ForEach-Object { [string]$_.reportNo })
        } catch { Write-Log '上次结果读取失败，跳过对比' 'WARN' }
    }
    $nowNos   = @($groupA | ForEach-Object { [string]$_.reportNo })
    $newOnes  = @($nowNos | Where-Object { $prevNos -notcontains $_ })
    $goneOnes = @($prevNos | Where-Object { $nowNos -notcontains $_ })

    $stamp = $startTime.ToString('yyyy-MM-dd_HHmmss')
    $groupAJson = '[]'
    $groupBJson = '[]'
    if ($groupA.Count -eq 1) { $groupAJson = '[' + ($groupA | ConvertTo-Json -Depth 6) + ']' }
    elseif ($groupA.Count -gt 1) { $groupAJson = ($groupA | ConvertTo-Json -Depth 6) }
    if ($groupB.Count -eq 1) { $groupBJson = '[' + ($groupB | ConvertTo-Json -Depth 6) + ']' }
    elseif ($groupB.Count -gt 1) { $groupBJson = ($groupB | ConvertTo-Json -Depth 6) }

    Write-Utf8File (Join-Path $LatestDir 'groupA_all_matches.json') $groupAJson
    Write-Utf8File (Join-Path $LatestDir 'groupB_wojia_eligible.json') $groupBJson
    $newJson = '[]'
    if ($newOnes.Count -eq 1) { $newJson = '[' + ($newOnes | ConvertTo-Json) + ']' }
    elseif ($newOnes.Count -gt 1) { $newJson = ($newOnes | ConvertTo-Json) }
    Write-Utf8File (Join-Path $LatestDir 'new_since_last_run.json') $newJson

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('============================================================')
    [void]$sb.AppendLine('联通加装包 5G 上网服务方案监控报告')
    [void]$sb.AppendLine('生成时间：' + $startTime.ToString('yyyy-MM-dd HH:mm:ss'))
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
    [void]$sb.AppendLine('筛选模式：' + $wojiaMode + '（explicit=仅剔除文案中明确排除智慧沃家共享版的；strict=再剔除限定其他主套餐的）')
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
    if ($newOnes.Count) { [void]$sb.AppendLine('新增方案：' + ($newOnes -join ', ')) } else { [void]$sb.AppendLine('新增方案：无') }
    if ($goneOnes.Count) { [void]$sb.AppendLine('下线方案：' + ($goneOnes -join ', ')) } else { [void]$sb.AppendLine('下线方案：无') }
    $summary = $sb.ToString()

    Write-Utf8File (Join-Path $LatestDir 'summary.txt') $summary

    if (-not $NoArchive) {
        $archiveDir = Join-Path $HistoryDir $stamp
        if (-not (Test-Path $archiveDir)) { [void](New-Item -ItemType Directory -Path $archiveDir -Force) }
        Write-Utf8File (Join-Path $archiveDir 'groupA_all_matches.json') $groupAJson
        Write-Utf8File (Join-Path $archiveDir 'groupB_wojia_eligible.json') $groupBJson
        Write-Utf8File (Join-Path $archiveDir 'summary.txt') $summary
        Write-Log ('历史归档：' + $archiveDir)
    }

    Write-Log '----------- 汇总 -----------'
    $aNos = '无'; if ($groupA.Count) { $aNos = ($groupA | ForEach-Object { $_.reportNo }) -join ', ' }
    $bNos = '无'; if ($groupB.Count) { $bNos = ($groupB | ForEach-Object { $_.reportNo }) -join ', ' }
    Write-Log ('第一组方案编号：' + $aNos)
    Write-Log ('第二组方案编号：' + $bNos)
    if ($newOnes.Count) { Write-Log ('新增：' + ($newOnes -join ', ')) } else { Write-Log '新增：无' }
    if ($goneOnes.Count) { Write-Log ('下线：' + ($goneOnes -join ', ')) } else { Write-Log '下线：无' }
    Write-Log ('结果目录：' + $LatestDir)
    Write-Log ('耗时 ' + [int]((Get-Date) - $startTime).TotalSeconds + ' 秒') 'OK'
    exit 0
}
catch {
    Write-Log ('运行失败：' + $_.Exception.Message) 'ERROR'
    Write-Log ($_.ScriptStackTrace) 'ERROR'
    exit 1
}
