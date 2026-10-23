# form-edit v1.7 — Edit 1C managed form elements
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
# Local: DynamicList attributes require settings.mainTable or settings.query
# and emit <Settings xsi:type="DynamicList">. An attribute without a source
# loads into the designer but the form fails to open
# ("не задан ни текст запроса, ни основная таблица").
# Local: Button and Command children are written in the platform order, and a
# command's picture-and-text Representation is TextPicture - the upstream order
# and value were refused with an XDTO exception on load.
# Local (v1.7): elements and attributes are compiled by form-compile (the same DSL
# keys, the same output) and imported with fresh ids and the target's indent - the
# reduced emitters of v1.6 dropped textEdit, maxWidth, chooseType, minValue / maxValue,
# choiceParameters, choiceParameterLinks, choiceList, format, save and the
# AdditionSource of table additions with «unknown key ... ignored». Commands,
# formEvents and elementEvents keep their own emitters.
# Local (v1.7): `before` places the new elements ahead of a named element; `into`
# also takes a command bar, context menu, popup or button group (a table's, an
# element's, the form's own AutoCommandBar). A button in the ChildItems of a Table
# is refused - its columns live there, the buttons go to the table's command bar.
param(
	[Parameter(Mandatory)]
	[Alias('Path')]
	[string]$FormPath,

	[Parameter(Mandatory)]
	[string]$JsonPath
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# --- Support guard (Ext/ParentConfigurations.bin) ---
# Canon: docs/support-manage.md. Blocks edits of vendor objects "на замке" /
# read-only configs unless allowed. Trigger = bin present; reaction from
# .dev.env SUPPORT_GUARD (deny|warn|off, default deny; .v8-project.json
# editingAllowedCheck stays as the upstream fallback). Fail-closed on an
# unreadable support state (bin exists but cannot be parsed — same reaction);
# other guard errors degrade to allow with a stderr notice.
function Get-RootUuid([string]$xmlPath) {
	if (-not (Test-Path $xmlPath)) { return $null }
	try {
		[xml]$mx = Get-Content -Path $xmlPath -Encoding UTF8
		$el = $mx.DocumentElement.FirstChild
		while ($el -and $el.NodeType -ne 'Element') { $el = $el.NextSibling }
		if ($el) { $u = $el.GetAttribute("uuid"); if ($u) { return $u } }
	} catch {}
	return $null
}
function Test-ExternalObjectRoot([string]$xmlPath) {
	if (-not (Test-Path $xmlPath)) { return $false }
	try {
		[xml]$mx = Get-Content -Path $xmlPath -Encoding UTF8
		$el = $mx.DocumentElement.FirstChild
		while ($el -and $el.NodeType -ne 'Element') { $el = $el.NextSibling }
		if ($el) { return @('ExternalDataProcessor','ExternalReport') -contains $el.LocalName }
	} catch {}
	return $false
}
function Find-V8Project([string]$startDir) {
	$d = $startDir
	for ($i = 0; $i -lt 20 -and $d; $i++) {
		$pj = Join-Path $d ".v8-project.json"
		if (Test-Path $pj) { return $pj }
		$parent = [System.IO.Path]::GetDirectoryName($d)
		if ($parent -eq $d) { break }
		$d = $parent
	}
	return $null
}
function Get-EditMode([string]$cfgDir) {
	try {
		# 1c-rules: .dev.env SUPPORT_GUARD wins over .v8-project.json editingAllowedCheck.
		$__devEnvHelper = Join-Path $PSScriptRoot '../../_common/DevEnv.ps1'
		if (Test-Path $__devEnvHelper) {
		    . $__devEnvHelper
		    $__devEnvMode = (Get-1CDevEnvValue 'SUPPORT_GUARD').ToLower()
		    if (@('deny', 'warn', 'off') -contains $__devEnvMode) { return $__devEnvMode }
		}
		$pj = Find-V8Project (Get-Location).Path
		if (-not $pj) { $pj = Find-V8Project $cfgDir }
		if (-not $pj) { return 'deny' }
		$proj = Get-Content -Raw $pj | ConvertFrom-Json
		$cfgFull = [System.IO.Path]::GetFullPath($cfgDir).TrimEnd('\', '/')
		if ($proj.databases) {
			foreach ($db in $proj.databases) {
				if ($db.configSrc) {
					$src = [System.IO.Path]::GetFullPath($db.configSrc).TrimEnd('\', '/')
					if ($cfgFull -eq $src -or $cfgFull.StartsWith($src + [System.IO.Path]::DirectorySeparatorChar)) {
						if ($db.editingAllowedCheck) { return $db.editingAllowedCheck }
					}
				}
			}
		}
		if ($proj.editingAllowedCheck) { return $proj.editingAllowedCheck }
		return 'deny'
	} catch { return 'deny' }
}
function Assert-EditAllowed([string]$targetPath, [string]$require) {
	try {
		$rp = $targetPath
		try { $rp = (Resolve-Path $targetPath -ErrorAction Stop).Path } catch {}
		# Autonomous external object (EPF/ERF): never part of a config on support (issue #39).
		if (Test-ExternalObjectRoot $rp) { return }
		$elemUuid = Get-RootUuid $rp
		$cfgDir = $null; $binPath = $null
		$d = if (Test-Path $rp -PathType Container) { $rp } else { [System.IO.Path]::GetDirectoryName($rp) }
		for ($i = 0; $i -lt 12 -and $d; $i++) {
			if (Test-ExternalObjectRoot "$d.xml") { return }
			if (-not $elemUuid) { $elemUuid = Get-RootUuid "$d.xml" }
			if (-not $cfgDir) {
				$cand = Join-Path (Join-Path $d "Ext") "ParentConfigurations.bin"
				if ((Test-Path $cand) -or (Test-Path (Join-Path $d "Configuration.xml"))) { $cfgDir = $d; $binPath = $cand }
			}
			if ($elemUuid -and $cfgDir) { break }
			$parent = [System.IO.Path]::GetDirectoryName($d)
			if ($parent -eq $d) { break }
			$d = $parent
		}
		# New object (no element file): fall back to config root uuid.
		if (-not $elemUuid -and $cfgDir) { $elemUuid = Get-RootUuid (Join-Path $cfgDir "Configuration.xml") }
		if (-not $binPath -or -not (Test-Path $binPath)) { return }
		# Bin present: an unreadable / unparseable support state must not silently
		# degrade to allow — fail closed via the SUPPORT_GUARD reaction instead.
		$G = 0; $K = 0; $text = $null; $parseOk = $false
		try {
			$bytes = [System.IO.File]::ReadAllBytes($binPath)
			if ($bytes.Length -gt 32) {
				$start = 0
				if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $start = 3 }
				$text = [System.Text.Encoding]::UTF8.GetString($bytes, $start, $bytes.Length - $start)
				$hm = [regex]::Match($text, '^\{6,(\d+),(\d+),')
				if ($hm.Success) {
					$G = [int]$hm.Groups[1].Value
					$K = [int]$hm.Groups[2].Value
					$parseOk = $true
				}
			}
		} catch {}
		if (-not $parseOk) {
			$mode = Get-EditMode $cfgDir
			if ($mode -eq 'off') { return }
			$msg = "[support-guard] Файл состояния поддержки «$binPath» существует, но не читается или не разбирается — состояние объекта неизвестно, он может быть на замке."
			if ($mode -eq 'warn') { [Console]::Error.WriteLine("$msg Продолжаю по SUPPORT_GUARD=warn."); return }
			[Console]::Error.WriteLine("$msg`nРедактирование остановлено (fail-closed). Проверьте целостность выгрузки, либо задайте SUPPORT_GUARD = warn|off в .dev.env (канон — docs/support-manage.md).")
			exit 1
		}
		if ($K -eq 0) { return }
		$best = $null
		if ($elemUuid) {
			$u = [regex]::Escape($elemUuid.ToLower())
			foreach ($m in [regex]::Matches($text, "([0-2]),0,$u")) {
				$f1 = [int]$m.Groups[1].Value
				if ($null -eq $best -or $f1 -lt $best) { $best = $f1 }
			}
		}
		$blocked = $false; $code = ""; $reason = ""
		if ($G -eq 1) { $blocked = $true; $code = "capability-off"; $reason = "возможность изменения конфигурации выключена (вся конфигурация read-only)" }
		elseif ($require -eq 'removed') {
			if ($null -ne $best -and $best -ne 2) { $blocked = $true; $code = "not-removed"; $reason = "объект не снят с поддержки — удаление сломает обновления" }
		}
		else {
			if ($null -ne $best -and $best -eq 0) { $blocked = $true; $code = "locked"; $reason = "объект на замке — редактирование сломает обновления" }
		}
		if (-not $blocked) { return }
		$mode = Get-EditMode $cfgDir
		if ($mode -eq 'off') { return }
		# Use Console.Error (not Write-Error) — under ErrorActionPreference=Stop the
		# latter throws and would be swallowed by this function's own catch.
		if ($mode -eq 'warn') { [Console]::Error.WriteLine("[support-guard] ПРЕДУПРЕЖДЕНИЕ: $reason. Цель: $rp"); return }
		$head = "[support-guard] Редактирование отклонено: это объект типовой конфигурации на поддержке поставщика, прямое редактирование молча сломает будущие обновления."
		$cfe = "Рекомендуемый путь: внести доработку в расширение (навыки cfe-borrow / cfe-patch-method) — состояние поддержки менять не нужно, обновления вендора сохраняются."
		$offNote = "Снять проверку: SUPPORT_GUARD = warn|off в .dev.env (канон — docs/support-manage.md)."
		if ($code -eq "capability-off") {
			$state = "Состояние: у всей конфигурации выключена возможность изменения (режим read-only «из коробки») — поэтому объект «$rp» редактировать нельзя."
			$fix = "Либо снять защиту явно (навык support-edit, два шага):`n  1. support-edit -Path ""$cfgDir"" -Capability on — включить возможность изменения (объекты пока остаются на замке);`n  2. support-edit -Path ""$rp"" -Set editable — открыть этот объект для редактирования.`n  Изменение применяется в базу полной загрузкой выгрузки и обходит механизм обновлений вендора."
		} elseif ($code -eq "not-removed") {
			$state = "Состояние: объект «$rp» на поддержке (не снят с поддержки) — его удаление разорвёт обновления вендора."
			$fix = "Либо сначала снять объект с поддержки, затем удалять:`n  support-edit -Path ""$rp"" -Set off-support — объект уходит из-под обновлений, после этого удаление безопасно."
		} else {
			$state = "Состояние: объект «$rp» на замке (возможность изменения конфигурации включена, но сам объект не редактируется)."
			$fix = "Либо разрешить редактирование этого объекта (навык support-edit, выбрать одно):`n  support-edit -Path ""$rp"" -Set editable — редактировать и дальше получать обновления вендора (возможны конфликты слияния);`n  support-edit -Path ""$rp"" -Set off-support — снять с поддержки: обновления по объекту больше не приходят."
		}
		[Console]::Error.WriteLine("$head`n$state`n$cfe`n$fix`n$offNote")
		exit 1
	} catch {
		[Console]::Error.WriteLine("[support-guard] Проверка состояния поддержки не выполнена ($($_.Exception.Message)) — продолжаю без блокировки.")
		return
	}
}

# === 1. Load Form.xml ===

if (-not (Test-Path $FormPath)) {
	Write-Error "File not found: $FormPath"
	exit 1
}
if (-not (Test-Path $JsonPath)) {
	Write-Error "File not found: $JsonPath"
	exit 1
}

$resolvedFormPath = (Resolve-Path $FormPath).Path
Assert-EditAllowed $resolvedFormPath 'editable'
$xmlDoc = New-Object System.Xml.XmlDocument
$xmlDoc.PreserveWhitespace = $true
try {
	$xmlDoc.Load($resolvedFormPath)
} catch {
	Write-Host "[ERROR] XML parse error: $($_.Exception.Message)"
	exit 1
}

$formNs = "http://v8.1c.ru/8.3/xcf/logform"
$v8Ns = "http://v8.1c.ru/8.1/data/core"
$nsMgr = New-Object System.Xml.XmlNamespaceManager($xmlDoc.NameTable)
$nsMgr.AddNamespace("f", $formNs)
$nsMgr.AddNamespace("v8", $v8Ns)

$root = $xmlDoc.DocumentElement

# === 2. Load JSON ===

$def = Get-Content -Raw -Encoding UTF8 $JsonPath | ConvertFrom-Json

# === 3. Form name + header ===

$formName = [System.IO.Path]::GetFileNameWithoutExtension($FormPath)
$parentDir = [System.IO.Path]::GetDirectoryName($resolvedFormPath)
if ($parentDir) {
	$extDir = [System.IO.Path]::GetFileName($parentDir)
	if ($extDir -eq "Ext") {
		$formDir = [System.IO.Path]::GetDirectoryName($parentDir)
		if ($formDir) { $formName = [System.IO.Path]::GetFileName($formDir) }
	}
}

Write-Host "=== form-edit: $formName ==="
Write-Host ""

# === 4. Scan max IDs per pool ===

$script:nextElemId = 0
$script:nextAttrId = 0
$script:nextCmdId = 0

# Scan ALL element IDs via XPath (includes companions like ExtendedTooltip, ContextMenu)
$rootCI = $root.SelectSingleNode("f:ChildItems", $nsMgr)
if ($rootCI) {
	foreach ($elem in $rootCI.SelectNodes(".//*[@id]")) {
		$id = $elem.GetAttribute("id")
		if ($id -and $id -ne "-1") {
			try { $intId = [int]$id; if ($intId -gt $script:nextElemId) { $script:nextElemId = $intId } } catch {}
		}
	}
}
# The form's own AutoCommandBar (id -1) and the buttons inside it
$acb = $root.SelectSingleNode("f:AutoCommandBar", $nsMgr)
if ($acb) {
	foreach ($elem in $acb.SelectNodes("descendant-or-self::*[@id]")) {
		$id = $elem.GetAttribute("id")
		if ($id -and $id -ne "-1") {
			try { $intId = [int]$id; if ($intId -gt $script:nextElemId) { $script:nextElemId = $intId } } catch {}
		}
	}
}

# Scan attribute IDs (including column IDs — same pool)
foreach ($attr in $root.SelectNodes("f:Attributes/f:Attribute", $nsMgr)) {
	$id = $attr.GetAttribute("id")
	if ($id) {
		try { $intId = [int]$id; if ($intId -gt $script:nextAttrId) { $script:nextAttrId = $intId } } catch {}
	}
	# Column IDs are in the same pool as attribute IDs
	foreach ($col in $attr.SelectNodes("f:Columns/f:Column", $nsMgr)) {
		$colId = $col.GetAttribute("id")
		if ($colId) {
			try { $intColId = [int]$colId; if ($intColId -gt $script:nextAttrId) { $script:nextAttrId = $intColId } } catch {}
		}
	}
}

# Scan command IDs
foreach ($cmd in $root.SelectNodes("f:Commands/f:Command", $nsMgr)) {
	$id = $cmd.GetAttribute("id")
	if ($id) {
		try { $intId = [int]$id; if ($intId -gt $script:nextCmdId) { $script:nextCmdId = $intId } } catch {}
	}
}

$script:nextElemId++
$script:nextAttrId++
$script:nextCmdId++

# --- 4b. Auto-detect extension mode (BaseForm present) ---
$script:isExtension = $false
$baseForm = $root.SelectSingleNode("f:BaseForm", $nsMgr)
if ($baseForm) {
	$script:isExtension = $true
	if ($script:nextAttrId -lt 1000000) { $script:nextAttrId = 1000000 }
	if ($script:nextCmdId -lt 1000000) { $script:nextCmdId = 1000000 }
	if ($script:nextElemId -lt 1000000) { $script:nextElemId = 1000000 }
}

function New-ElemId { $id = $script:nextElemId; $script:nextElemId++; return $id }
function New-AttrId { $id = $script:nextAttrId; $script:nextAttrId++; return $id }
function New-CmdId { $id = $script:nextCmdId; $script:nextCmdId++; return $id }

# === 5. Fragment helpers (StringBuilder) for commands and events ===
# Elements and attributes do not come from here: they are compiled by form-compile
# (section 9). Only the emitters of commands, formEvents and elementEvents stay local.

$script:xml = New-Object System.Text.StringBuilder 4096

function X {
	param([string]$text)
	$script:xml.AppendLine($text) | Out-Null
}

function Esc-Xml {
	param([string]$s)
	return $s.Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;').Replace('"','&quot;')
}

function Emit-MLText {
	param([string]$tag, [string]$text, [string]$indent)
	X "$indent<$tag>"
	X "$indent`t<v8:item>"
	X "$indent`t`t<v8:lang>ru</v8:lang>"
	X "$indent`t`t<v8:content>$(Esc-Xml $text)</v8:content>"
	X "$indent`t</v8:item>"
	X "$indent</$tag>"
}

function Test-IsDynamicListType {
	param([string]$typeStr)
	return ($typeStr -eq "DynamicList" -or $typeStr -eq "cfg:DynamicList")
}

function Test-DynamicListSource {
	param($settings)
	if (-not $settings) { return $false }
	$main = "$($settings.mainTable)".Trim()
	$query = "$($settings.query)".Trim()
	return ($main -ne "" -or $query -ne "")
}

# Уникальность имён внутри JSON-определения (1С: своя коллекция — свой неймспейс).
function Assert-EditUnique {
	param([string]$name, [hashtable]$seen, [string]$ctx)
	if ($seen.ContainsKey($name)) {
		Write-Host "[ERROR] Duplicate $ctx '$name' in JSON definition — names must be unique in 1C form"
		exit 1
	}
	$seen[$name] = $true
}

# === 6. Find elements by name ===

# Element tree only (ChildItems, recursively): the lookup of elementEvents.
function Find-Element($startNode, [string]$targetName) {
	foreach ($child in $startNode.ChildNodes) {
		if ($child.NodeType -ne 'Element') { continue }
		$childName = $child.GetAttribute("name")
		if ($childName -eq $targetName) { return $child }
		$ci = $child.SelectSingleNode("f:ChildItems", $nsMgr)
		if ($ci) {
			$found = Find-Element $ci $targetName
			if ($found) { return $found }
		}
	}
	return $null
}

# Every named node of the form's element tree: the form's own AutoCommandBar and
# ChildItems with all descendants, companions (ExtendedTooltip, ContextMenu, a table's
# AutoCommandBar, the table additions) included. <Event name=".."> is not an element.
function Get-NamedNodes {
	$list = New-Object System.Collections.ArrayList
	foreach ($top in @($root.SelectNodes('f:AutoCommandBar | f:ChildItems', $nsMgr))) {
		if ($top.GetAttribute("name")) { [void]$list.Add($top) }
		foreach ($n in $top.SelectNodes('.//*[@name]')) {
			if ($n.NamespaceURI -eq $formNs -and $n.LocalName -ne 'Event') { [void]$list.Add($n) }
		}
	}
	return $list
}

function Find-Target([string]$targetName) {
	foreach ($n in @(Get-NamedNodes)) {
		if ($n.GetAttribute("name") -eq $targetName) { return $n }
	}
	return $null
}

# === 7. Detect indent level of a container's children ===

# Indent of the line a node starts on (the whitespace before it); by depth when it has none.
function Get-NodeIndent($node) {
	$prev = $node.PreviousSibling
	if ($prev -and ($prev.NodeType -eq 'Whitespace' -or $prev.NodeType -eq 'SignificantWhitespace')) {
		$i = $prev.Value.LastIndexOf("`n")
		if ($i -ge 0) { return $prev.Value.Substring($i + 1) }
	}
	$depth = 0
	$current = $node.ParentNode
	while ($current -and $current.NodeType -eq 'Element') { $depth++; $current = $current.ParentNode }
	return "`t" * $depth
}

function Get-ChildIndent($container) {
	foreach ($child in $container.ChildNodes) {
		if ($child.NodeType -eq 'Whitespace' -or $child.NodeType -eq 'SignificantWhitespace') {
			$text = $child.Value
			if ($text -match '^\r?\n(\t+)$') { return $Matches[1] }
			if ($text -match '^\r?\n(\t+)') { return $Matches[1] }
		}
	}
	# No children yet: one tab deeper than the container itself
	return (Get-NodeIndent $container) + "`t"
}

# ChildItems of an element, created when absent. It is the last child of every element
# that has one (after HorizontalAlign / Autofill of a command bar, after the companions
# and events of the others), on its own lines whether the owner was a self-closing tag or not.
function Ensure-ChildItems($owner) {
	$ci = $owner.SelectSingleNode("f:ChildItems", $nsMgr)
	if ($ci) { return $ci }
	$ownerIndent = Get-NodeIndent $owner
	$ci = $xmlDoc.CreateElement("ChildItems", $formNs)
	$last = $owner.LastChild
	if ($last -and ($last.NodeType -eq 'Whitespace' -or $last.NodeType -eq 'SignificantWhitespace')) {
		$owner.InsertBefore($xmlDoc.CreateWhitespace("`r`n$ownerIndent`t"), $last) | Out-Null
		$owner.InsertBefore($ci, $last) | Out-Null
	} else {
		$owner.AppendChild($xmlDoc.CreateWhitespace("`r`n$ownerIndent`t")) | Out-Null
		$owner.AppendChild($ci) | Out-Null
		$owner.AppendChild($xmlDoc.CreateWhitespace("`r`n$ownerIndent")) | Out-Null
	}
	return $ci
}

# === 8. Insert node into container ===

function Insert-IntoContainer($container, $newNode, $afterName, $childIndent, $beforeName = $null) {
	$refNode = $null
	$beforeAnchor = $false

	if ($beforeName) {
		# Insert before the named element
		foreach ($child in $container.ChildNodes) {
			if ($child.NodeType -eq 'Element' -and $child.GetAttribute("name") -eq $beforeName) {
				$refNode = $child
				$beforeAnchor = $true
				break
			}
		}
		if (-not $refNode) {
			Write-Host "[WARN] before='$beforeName' not found in target container, appending at end"
		}
	} elseif ($afterName) {
		# Find the after-element, then insert after it
		$afterElem = $null
		foreach ($child in $container.ChildNodes) {
			if ($child.NodeType -eq 'Element' -and $child.GetAttribute("name") -eq $afterName) {
				$afterElem = $child
				break
			}
		}
		if ($afterElem) {
			$refNode = $afterElem.NextSibling
		} else {
			Write-Host "[WARN] after='$afterName' not found in target container, appending at end"
		}
	}

	if (-not $refNode) {
		# Append at end: insert before trailing whitespace
		$trailing = $container.LastChild
		if ($trailing -and ($trailing.NodeType -eq 'Whitespace' -or $trailing.NodeType -eq 'SignificantWhitespace')) {
			$refNode = $trailing
		}
	}

	$ws = $xmlDoc.CreateWhitespace("`r`n$childIndent")
	if ($refNode -and $beforeAnchor) {
		# The anchor keeps the whitespace in front of it: node, line break, anchor
		$container.InsertBefore($newNode, $refNode) | Out-Null
		$container.InsertBefore($ws, $refNode) | Out-Null
	} elseif ($refNode) {
		$container.InsertBefore($ws, $refNode) | Out-Null
		$container.InsertBefore($newNode, $refNode) | Out-Null
	} else {
		# Container is empty (self-closing) — add framing whitespace
		$container.AppendChild($ws) | Out-Null
		$container.AppendChild($newNode) | Out-Null
		$parentIndent = if ($childIndent.Length -gt 1) { $childIndent.Substring(0, $childIndent.Length - 1) } else { "" }
		$closeWs = $xmlDoc.CreateWhitespace("`r`n$parentIndent")
		$container.AppendChild($closeWs) | Out-Null
	}
}

# === 9. Generate fragment, parse, import nodes ===

$allNsDecl = 'xmlns="http://v8.1c.ru/8.3/xcf/logform" xmlns:v8="http://v8.1c.ru/8.1/data/core" xmlns:v8ui="http://v8.1c.ru/8.1/data/ui" xmlns:xr="http://v8.1c.ru/8.3/xcf/readable" xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:cfg="http://v8.1c.ru/8.1/data/enterprise/current-config" xmlns:dcsset="http://v8.1c.ru/8.1/data-composition-system/settings" xmlns:dcscor="http://v8.1c.ru/8.1/data-composition-system/core" xmlns:dcssch="http://v8.1c.ru/8.1/data-composition-system/schema"'

function Parse-Fragment([string]$xmlText) {
	$fragDoc = New-Object System.Xml.XmlDocument
	$fragDoc.PreserveWhitespace = $true
	$fragDoc.LoadXml($xmlText)
	return $fragDoc
}

function Import-ElementNodes($fragDoc) {
	$nodes = @()
	foreach ($child in $fragDoc.DocumentElement.ChildNodes) {
		if ($child.NodeType -eq 'Element') {
			$nodes += $xmlDoc.ImportNode($child, $true)
		}
	}
	return $nodes
}

# --- 9b. Compile bridge: elements and attributes are written by form-compile ---
# A second copy of the emitters drifted from the compiler (textEdit, maxWidth,
# choiceParameters, save, AdditionSource of the table additions, ... were dropped
# with «unknown key ... ignored»). The new items go into a temporary DSL, form-compile
# compiles it into a temporary Form.xml (outside Forms\<Name>\Ext, so no parent object
# is touched), and the compiled nodes are renumbered, re-indented and imported below.
# Commands stay with the emitters above: the compiler writes their children in an
# order the platform refused (CHANGELOG 2026-10-01).

$script:compileScript = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../1c-form-compile/scripts/form-compile.ps1'))

function Invoke-FormCompileFragment($dsl) {
	if (-not (Test-Path -LiteralPath $script:compileScript)) {
		Write-Host "[ERROR] form-compile not found: $script:compileScript"
		exit 1
	}
	$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("form-edit-" + [guid]::NewGuid().ToString('N'))
	try {
		New-Item -ItemType Directory -Path $tmp -Force | Out-Null
		$dslPath = Join-Path $tmp 'fragment.json'
		$outPath = Join-Path $tmp 'Form.xml'
		[System.IO.File]::WriteAllText($dslPath, ($dsl | ConvertTo-Json -Depth 50), (New-Object System.Text.UTF8Encoding($true)))

		# form-compile ends with exit: a child process of the same PowerShell edition.
		$psi = New-Object System.Diagnostics.ProcessStartInfo
		$psi.FileName = (Get-Process -Id $PID).Path
		# -Command, not -File: a refusal of the compiler (Write-Error under Stop) arrives as its plain
		# message instead of the host's decorated error record.
		$q = { param([string]$s) "'" + $s.Replace("'", "''") + "'" }
		$cmd = "try { & " + (& $q $script:compileScript) + " -JsonPath " + (& $q $dslPath) + " -OutputPath " + (& $q $outPath) + "; exit `$LASTEXITCODE } catch { [Console]::Error.WriteLine(`$_.Exception.Message); exit 1 }"
		$psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -Command "' + $cmd + '"'
		$psi.UseShellExecute = $false
		$psi.CreateNoWindow = $true
		$psi.RedirectStandardOutput = $true
		$psi.RedirectStandardError = $true
		$psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
		$psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
		$proc = [System.Diagnostics.Process]::Start($psi)
		$errTask = $proc.StandardError.ReadToEndAsync()
		$outText = $proc.StandardOutput.ReadToEnd()
		$proc.WaitForExit()
		$errText = $errTask.Result
		$lines = @((($outText + "`n" + $errText) -split "\r?\n") | Where-Object { $_.Trim() -ne '' })

		if ($proc.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $outPath)) {
			foreach ($l in $lines) {
				if ($l -match 'Configuration\.xml not found above') { continue }
				Write-Host $l
			}
			Write-Host "[ERROR] form-compile refused the definition — nothing was written"
			exit 1
		}

		# The compiler's warnings (the host localizes the «WARNING:» prefix) replace form-edit's own
		# «unknown key» ones; its summary and the note about the temporary path do not.
		foreach ($l in $lines) {
			if ($l -match 'Configuration\.xml not found above') { continue }
			if ($l -match '^\[OK\] Compiled' -or $l -match '^\s+(Elements\+IDs|Attributes|Commands|Parameters|Registered):') { continue }
			Write-Host $l.Trim()
		}

		$compiled = New-Object System.Xml.XmlDocument
		$compiled.PreserveWhitespace = $true
		$compiled.Load($outPath)
		return $compiled
	} finally {
		Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
	}
}

# Leading whitespace of every line inside an imported subtree: srcIndent -> dstIndent.
# Only whitespace-only nodes are touched, so a multi-line text of an element stays as written.
function Set-NodeIndent($node, [string]$srcIndent, [string]$dstIndent) {
	if ($srcIndent -eq $dstIndent) { return }
	$pattern = "(?<=\n)" + [regex]::Escape($srcIndent)
	foreach ($child in @($node.ChildNodes)) {
		if ($child.NodeType -eq 'Whitespace' -or $child.NodeType -eq 'SignificantWhitespace') {
			if ($child.Value.IndexOf("`n") -ge 0) { $child.Value = [regex]::Replace($child.Value, $pattern, $dstIndent) }
		} elseif ($child.NodeType -eq 'Element') {
			Set-NodeIndent $child $srcIndent $dstIndent
		}
	}
}

# Fresh element ids, in document order, for the subtree (the form's own bar, id -1, never
# occurs inside it). References inside Form.xml are by name, so nothing else changes.
function Set-ElementIds($node) {
	foreach ($n in @($node.SelectNodes('descendant-or-self::*[@id]'))) {
		if ($n.GetAttribute("id") -eq "-1") { continue }
		$n.SetAttribute("id", [string](New-ElemId))
	}
}

# Prefixes the imported nodes use (as element or attribute names, and in xsi:type / type
# texts such as cfg:CatalogObject.X) must be declared on the target's <Form>; a form that
# lacks one gets the compiler's declaration there instead of a copy on every node.
function Ensure-Namespaces($srcDoc, $nodes) {
	$text = (@($nodes | ForEach-Object { $_.OuterXml }) -join "`n")
	# get_Attributes(): a child element <Attributes> shadows the property in PowerShell's XML adapter
	foreach ($a in $srcDoc.DocumentElement.get_Attributes()) {
		if ($a.Prefix -ne 'xmlns') { continue }
		$prefix = $a.LocalName
		if ($text -notmatch ('(?<![\w.:/-])' + [regex]::Escape($prefix) + ':(?=[A-Za-z_])')) { continue }
		$have = $root.GetNamespaceOfPrefix($prefix)
		if ($have -and $have -ne $a.Value) {
			Write-Host "[ERROR] Prefix '$prefix' is bound to '$have' in this form, the compiled items need '$($a.Value)'"
			exit 1
		}
		if (-not $have) {
			$decl = $xmlDoc.CreateAttribute("xmlns", $prefix, "http://www.w3.org/2000/xmlns/")
			$decl.Value = $a.Value
			$first = $null
			$rootAttrs = $root.get_Attributes()
			foreach ($ra in $rootAttrs) { if ($ra.Prefix -ne 'xmlns' -and $ra.Name -ne 'xmlns') { $first = $ra; break } }
			if ($first) { $rootAttrs.InsertBefore($decl, $first) | Out-Null } else { $rootAttrs.Append($decl) | Out-Null }
		}
	}
}

function Get-TablePaths($els, [hashtable]$acc) {
	foreach ($e in @($els)) {
		if ($null -eq $e) { continue }
		if ($null -ne $e.PSObject.Properties["table"] -and $null -ne $e.table -and $e.path) { $acc["$($e.path)"] = $true }
		if ($e.PSObject.Properties["children"] -and $e.children) { Get-TablePaths $e.children $acc }
	}
}

# === 10. Add elements and attributes ===

$addedElems = @()
$addedAttrs = @()
$companionCount = 0

$hasElems = [bool]($def.elements -and $def.elements.Count -gt 0)
$hasAttrs = [bool]($def.attributes -and $def.attributes.Count -gt 0)

if ($hasElems -or $hasAttrs) {
	$intoName = if ($def.into) { "$($def.into)" } else { $null }
	$afterName = if ($def.after) { "$($def.after)" } else { $null }
	$beforeName = if ($def.before) { "$($def.before)" } else { $null }
	if ($hasElems -and $afterName -and $beforeName) {
		Write-Host "[ERROR] 'after' and 'before' exclude each other — give one anchor"
		exit 1
	}

	# --- Target container (nothing is changed in the form yet) ---
	$owner = $null
	$targetCI = $null
	$mode = 'plain'   # plain | cmd (command bar, context menu, popup, button group) | table
	if ($hasElems) {
		$holderTags = @('UsualGroup','ColumnGroup','Pages','Page','Table','AutoCommandBar','ContextMenu','CommandBar','ButtonGroup','Popup')
		if ($intoName) {
			$owner = Find-Target $intoName
			if (-not $owner) {
				Write-Host "[ERROR] Target '$intoName' not found"
				exit 1
			}
			if ($holderTags -notcontains $owner.LocalName) {
				Write-Host "[ERROR] Target '$intoName' is <$($owner.LocalName)> and holds no elements. Possible: group, pages, page, table, command bar, context menu, popup, button group"
				exit 1
			}
			$targetCI = $owner.SelectSingleNode("f:ChildItems", $nsMgr)
		} elseif ($afterName -or $beforeName) {
			# Find the anchor globally and use its parent as target
			$anchorName = if ($beforeName) { $beforeName } else { $afterName }
			$anchor = Find-Target $anchorName
			if (-not $anchor) {
				Write-Host "[ERROR] Element '$anchorName' not found"
				exit 1
			}
			if ($anchor.ParentNode.LocalName -ne 'ChildItems') {
				Write-Host "[ERROR] '$anchorName' is <$($anchor.LocalName)>, a part of its element, not an item of a container — name the container with into"
				exit 1
			}
			$targetCI = $anchor.ParentNode
			$owner = $targetCI.ParentNode
		} else {
			$owner = $root
			$targetCI = $rootCI
		}
		if (-not [object]::ReferenceEquals($owner, $root)) {
			if (@('AutoCommandBar','ContextMenu','CommandBar','ButtonGroup','Popup') -contains $owner.LocalName) { $mode = 'cmd' }
			elseif ($owner.LocalName -eq 'Table') { $mode = 'table' }
		}
	}

	# --- Attributes: refusals first, they are cheap ---
	$existingAttrs = @{}
	foreach ($ea in $root.SelectNodes("f:Attributes/f:Attribute", $nsMgr)) { $existingAttrs[$ea.GetAttribute("name")] = $ea }
	$dslAttrNames = @{}
	if ($hasAttrs) {
		# Уникальность имён реквизитов: внутри JSON-определения (+ колонки в пределах реквизита) и
		# против уже существующих реквизитов формы.
		foreach ($attr in $def.attributes) {
			Assert-EditUnique -name "$($attr.name)" -seen $dslAttrNames -ctx 'attribute name'
			if ($attr.columns) {
				$dslColNames = @{}
				foreach ($col in $attr.columns) { Assert-EditUnique -name "$($col.name)" -seen $dslColNames -ctx "column name of '$($attr.name)'" }
			}
			if ($existingAttrs.ContainsKey("$($attr.name)")) {
				Write-Host "[ERROR] Attribute '$($attr.name)' already exists in form — attribute names must be unique"
				exit 1
			}
			if ((Test-IsDynamicListType "$($attr.type)") -and -not (Test-DynamicListSource $attr.settings)) {
				Write-Host "[ERROR] Attribute '$($attr.name)': DynamicList requires settings.mainTable or settings.query — otherwise the form fails to open"
				exit 1
			}
		}
	}

	# --- Temporary DSL ---
	$dsl = New-Object PSObject
	$stubNames = @{}
	if ($hasElems) {
		$dslElements = @($def.elements)
		if ($mode -eq 'cmd') {
			# the compiler applies its command-bar rules (CommandBarButton, ...) to the children of a cmdBar
			$bar = New-Object PSObject
			$bar | Add-Member -NotePropertyName "cmdBar" -NotePropertyValue "FormEditTmpBar"
			$bar | Add-Member -NotePropertyName "children" -NotePropertyValue $dslElements
			$dslElements = @($bar)
		}
		$dsl | Add-Member -NotePropertyName "elements" -NotePropertyValue $dslElements
	}
	$dslAttributes = @()
	$dslAttrTypes = @{}
	if ($hasAttrs) {
		foreach ($attr in $def.attributes) {
			$dslAttrTypes["$($attr.name)"] = if ($attr.type) { "$($attr.type)" } else { "(no type)" }
			# form-compile infers the main attribute (and its SavedData) from a single object-like
			# attribute; the form being edited already has its own.
			if ($null -eq $attr.PSObject.Properties["main"]) { $attr | Add-Member -NotePropertyName "main" -NotePropertyValue $false }
			$dslAttributes += $attr
		}
	}
	if ($hasElems) {
		# A table bound to a DynamicList attribute of the form gets the list-table defaults of the
		# compiler only when it sees that attribute: a stub stands in for it and is discarded.
		$tablePaths = @{}
		Get-TablePaths $def.elements $tablePaths
		foreach ($tp in @($tablePaths.Keys)) {
			if ($dslAttrNames.ContainsKey($tp) -or -not $existingAttrs.ContainsKey($tp)) { continue }
			$typeNode = $existingAttrs[$tp].SelectSingleNode("f:Type/v8:Type", $nsMgr)
			if (-not $typeNode -or $typeNode.InnerText.Trim() -ne "cfg:DynamicList") { continue }
			$settings = New-Object PSObject
			$mt = $existingAttrs[$tp].SelectSingleNode("f:Settings/f:MainTable", $nsMgr)
			if ($mt -and $mt.InnerText.Trim()) { $settings | Add-Member -NotePropertyName "mainTable" -NotePropertyValue $mt.InnerText.Trim() }
			else { $settings | Add-Member -NotePropertyName "query" -NotePropertyValue "stub" }
			$stub = New-Object PSObject
			$stub | Add-Member -NotePropertyName "name" -NotePropertyValue $tp
			$stub | Add-Member -NotePropertyName "type" -NotePropertyValue "DynamicList"
			$stub | Add-Member -NotePropertyName "main" -NotePropertyValue $false
			$stub | Add-Member -NotePropertyName "settings" -NotePropertyValue $settings
			$dslAttributes += $stub
			$stubNames[$tp] = $true
		}
	}
	if ($dslAttributes.Count -gt 0) { $dsl | Add-Member -NotePropertyName "attributes" -NotePropertyValue $dslAttributes }

	$compiled = Invoke-FormCompileFragment $dsl
	$cRoot = $compiled.DocumentElement
	$cNs = New-Object System.Xml.XmlNamespaceManager($compiled.NameTable)
	$cNs.AddNamespace("f", $formNs)

	# --- Compiled elements ---
	$srcElems = @()
	$srcElemIndent = "`t`t"
	if ($hasElems) {
		$srcCI = $cRoot.SelectSingleNode("f:ChildItems", $cNs)
		if ($srcCI -and $mode -eq 'cmd') {
			$srcBar = $srcCI.SelectSingleNode("f:CommandBar", $cNs)
			$srcCI = if ($srcBar) { $srcBar.SelectSingleNode("f:ChildItems", $cNs) } else { $null }
		}
		if ($srcCI) {
			foreach ($child in $srcCI.ChildNodes) {
				if ($child.NodeType -eq 'Element') { $srcElems += $child }
			}
			foreach ($child in $srcCI.ChildNodes) {
				if ($child.NodeType -eq 'Whitespace' -and $child.Value -match '^\r?\n(\t+)') { $srcElemIndent = $Matches[1]; break }
			}
		}

		$ownerName = if ([object]::ReferenceEquals($owner, $root)) { "form" } else { $owner.GetAttribute("name") }
		foreach ($n in $srcElems) {
			$nName = $n.GetAttribute("name")
			if ($mode -eq 'table' -and @('Button','ButtonGroup','Popup','CommandBar') -contains $n.LocalName) {
				$tableBar = $owner.SelectSingleNode("f:AutoCommandBar", $nsMgr)
				$hint = if ($tableBar) { "use into: `"$($tableBar.GetAttribute('name'))`"" } else { "the table has no command bar of its own" }
				Write-Host "[ERROR] '$nName' is <$($n.LocalName)>: the ChildItems of table '$ownerName' hold its columns, buttons go to its command bar — $hint"
				exit 1
			}
			if ($mode -eq 'cmd' -and @('Button','ButtonGroup','Popup') -notcontains $n.LocalName) {
				Write-Host "[ERROR] '$nName' is <$($n.LocalName)>: '$ownerName' takes buttons, button groups and popups only"
				exit 1
			}
		}

		# Имена элементов уникальны (требование 1С; дубль = битый XML, форма не откроется): против всех
		# уже существующих узлов формы, компаньоны включены. Внутри определения следит form-compile.
		$existingNames = @{}
		foreach ($nn in @(Get-NamedNodes)) { $existingNames[$nn.GetAttribute("name")] = $nn }
		foreach ($n in $srcElems) {
			foreach ($nn in $n.SelectNodes('descendant-or-self::*[@name]')) {
				if ($nn.LocalName -eq 'Event') { continue }
				$nm = $nn.GetAttribute("name")
				if ($existingNames.ContainsKey($nm)) {
					Write-Host "[ERROR] Element '$nm' already exists in form (id=$($existingNames[$nm].GetAttribute('id'))) — element names must be unique"
					exit 1
				}
			}
		}
	}

	# --- Compiled attributes ---
	$srcAttrs = @()
	foreach ($a in $cRoot.SelectNodes("f:Attributes/f:Attribute", $cNs)) {
		if (-not $stubNames.ContainsKey($a.GetAttribute("name"))) { $srcAttrs += $a }
	}

	Ensure-Namespaces $compiled ($srcElems + $srcAttrs)

	# --- Elements: target container, ids, indent, insertion ---
	if ($hasElems -and $srcElems.Count -gt 0) {
		if (-not $targetCI) {
			if ([object]::ReferenceEquals($owner, $root)) {
				# Create ChildItems section in form — insert after Events or AutoCommandBar
				$targetCI = $xmlDoc.CreateElement("ChildItems", $formNs)
				$insertAfter = $root.SelectSingleNode("f:Events", $nsMgr)
				if (-not $insertAfter) { $insertAfter = $root.SelectSingleNode("f:AutoCommandBar", $nsMgr) }
				if ($insertAfter) {
					$refNode = $insertAfter.NextSibling
					$ws = $xmlDoc.CreateWhitespace("`r`n`t")
					$root.InsertBefore($ws, $refNode) | Out-Null
					$root.InsertBefore($targetCI, $refNode) | Out-Null
				} else {
					$root.AppendChild($xmlDoc.CreateWhitespace("`r`n`t")) | Out-Null
					$root.AppendChild($targetCI) | Out-Null
				}
				# Also update $rootCI reference
				$rootCI = $targetCI
			} else {
				$targetCI = Ensure-ChildItems $owner
			}
		}
		$childIndent = Get-ChildIndent $targetCI

		$importedNodes = @()
		foreach ($n in $srcElems) {
			$node = $xmlDoc.ImportNode($n, $true)
			Set-NodeIndent $node $srcElemIndent $childIndent
			Set-ElementIds $node
			$importedNodes += $node
		}

		# Report: what was added, from the compiled nodes
		$companionTags = @('ExtendedTooltip','ContextMenu','SearchStringAddition','ViewStatusAddition','SearchControlAddition','AutoCommandBar')
		foreach ($node in $importedNodes) {
			$dp = $node.SelectSingleNode("f:DataPath", $nsMgr)
			$pathStr = if ($dp) { " -> $($dp.InnerText)" } else { "" }
			$evNames = @($node.SelectNodes("f:Events/f:Event", $nsMgr) | ForEach-Object { $_.GetAttribute("name") })
			$evtStr = if ($evNames.Count -gt 0) { " {$($evNames -join ', ')}" } else { "" }
			$addedElems += "  + [$($node.LocalName)] $($node.GetAttribute('name'))$pathStr$evtStr"
			$companionCount += @($node.SelectNodes('descendant-or-self::*[@id]') | Where-Object { $companionTags -contains $_.LocalName }).Count
		}

		# Insert each imported node
		foreach ($node in $importedNodes) {
			Insert-IntoContainer -container $targetCI -newNode $node -afterName $afterName -childIndent $childIndent -beforeName $beforeName
			# Only use afterName for the first insertion; subsequent ones go after the previous
			if ($afterName) { $afterName = $node.GetAttribute("name") }
		}
	}

	# --- Attributes ---
	if ($srcAttrs.Count -gt 0) {
		$attrsSection = $root.SelectSingleNode("f:Attributes", $nsMgr)
		if (-not $attrsSection) {
			# Create Attributes section — insert after ChildItems or after Events
			$attrsSection = $xmlDoc.CreateElement("Attributes", $formNs)
			# Find insertion point: after ChildItems or after the last pre-Attributes element
			$insertAfter = $rootCI
			if (-not $insertAfter) {
				$insertAfter = $root.SelectSingleNode("f:Events", $nsMgr)
			}
			if (-not $insertAfter) {
				$insertAfter = $root.SelectSingleNode("f:AutoCommandBar", $nsMgr)
			}
			if ($insertAfter) {
				$refNode = $insertAfter.NextSibling
				$ws = $xmlDoc.CreateWhitespace("`r`n`t")
				$root.InsertBefore($ws, $refNode) | Out-Null
				$root.InsertBefore($attrsSection, $refNode) | Out-Null
			} else {
				$root.AppendChild($xmlDoc.CreateWhitespace("`r`n`t")) | Out-Null
				$root.AppendChild($attrsSection) | Out-Null
			}
		}

		# Detect indent for attribute children
		$attrChildIndent = Get-ChildIndent $attrsSection
		if (-not $attrChildIndent -or $attrChildIndent -eq "") { $attrChildIndent = "`t`t" }

		foreach ($a in $srcAttrs) {
			$node = $xmlDoc.ImportNode($a, $true)
			Set-NodeIndent $node "`t`t" $attrChildIndent
			$attrId = New-AttrId
			$node.SetAttribute("id", [string]$attrId)
			# Column ids are per attribute, from 1 (as the platform writes them), direct columns
			# and those inside AdditionalColumns alike, in document order
			$colId = 1
			foreach ($col in $node.SelectNodes("f:Columns//f:Column", $nsMgr)) { $col.SetAttribute("id", [string]$colId); $colId++ }
			$typeStr = $dslAttrTypes[$node.GetAttribute("name")]
			$addedAttrs += "  + $($node.GetAttribute('name')): $typeStr (id=$attrId)"
			Insert-IntoContainer -container $attrsSection -newNode $node -afterName $null -childIndent $attrChildIndent
		}
	}
}

# === 12. Add commands ===

$addedCmds = @()

if ($def.commands -and $def.commands.Count -gt 0) {
	$cmdsSection = $root.SelectSingleNode("f:Commands", $nsMgr)
	if (-not $cmdsSection) {
		# Create Commands section — insert after Parameters or Attributes
		$cmdsSection = $xmlDoc.CreateElement("Commands", $formNs)
		$insertAfter = $root.SelectSingleNode("f:Parameters", $nsMgr)
		if (-not $insertAfter) { $insertAfter = $root.SelectSingleNode("f:Attributes", $nsMgr) }
		if (-not $insertAfter) { $insertAfter = $rootCI }
		if ($insertAfter) {
			$refNode = $insertAfter.NextSibling
			$ws = $xmlDoc.CreateWhitespace("`r`n`t")
			$root.InsertBefore($ws, $refNode) | Out-Null
			$root.InsertBefore($cmdsSection, $refNode) | Out-Null
		} else {
			$root.AppendChild($xmlDoc.CreateWhitespace("`r`n`t")) | Out-Null
			$root.AppendChild($cmdsSection) | Out-Null
		}
	}

	$cmdChildIndent = Get-ChildIndent $cmdsSection
	if (-not $cmdChildIndent -or $cmdChildIndent -eq "") { $cmdChildIndent = "`t`t" }

	# Уникальность имён команд: внутри JSON-определения и против существующих команд формы.
	$dslCmdNames = @{}
	foreach ($cmd in $def.commands) {
		Assert-EditUnique -name "$($cmd.name)" -seen $dslCmdNames -ctx 'command name'
		$existingCmd = $cmdsSection.SelectSingleNode("f:Command[@name='$($cmd.name)']", $nsMgr)
		if ($existingCmd) {
			Write-Host "[ERROR] Command '$($cmd.name)' already exists in form — command names must be unique"
			exit 1
		}
	}

	# Generate command fragments
	$script:xml = New-Object System.Text.StringBuilder 1024
	X "<_F $allNsDecl>"
	foreach ($cmd in $def.commands) {
		$cmdId = New-CmdId
		$cmdName = "$($cmd.name)"
		X "$cmdChildIndent<Command name=`"$cmdName`" id=`"$cmdId`">"
		$inner = "$cmdChildIndent`t"

		if ($cmd.title) { Emit-MLText -tag "Title" -text "$($cmd.title)" -indent $inner }

		# Platform order: Title, Shortcut, Picture, Action, Representation. A
		# Picture after Action was refused with an XDTO exception on load.
		if ($cmd.shortcut) { X "$inner<Shortcut>$($cmd.shortcut)</Shortcut>" }
		if ($cmd.picture) {
			X "$inner<Picture>"
			X "$inner`t<xr:Ref>$($cmd.picture)</xr:Ref>"
			X "$inner`t<xr:LoadTransparent>true</xr:LoadTransparent>"
			X "$inner</Picture>"
		}

		# Support single action with optional callType, or multiple actions
		if ($cmd.actions) {
			# Multiple actions: [{ "callType": "Before", "handler": "..." }, ...]
			foreach ($act in $cmd.actions) {
				$actHandler = "$($act.handler)"
				$callTypeAttr = if ($act.callType) { " callType=`"$($act.callType)`"" } else { "" }
				X "$inner<Action$callTypeAttr>$actHandler</Action>"
			}
		} elseif ($cmd.action) {
			$callTypeAttr = if ($cmd.callType) { " callType=`"$($cmd.callType)`"" } else { "" }
			X "$inner<Action$callTypeAttr>$($cmd.action)</Action>"
		}

		if ($cmd.representation) {
			# A command spells picture-and-text TextPicture; PictureAndText is the button's
			# spelling and is not a value of the command property.
			$cmdRepr = if ("$($cmd.representation)" -eq 'PictureAndText') { 'TextPicture' } else { "$($cmd.representation)" }
			X "$inner<Representation>$cmdRepr</Representation>"
		}

		X "$cmdChildIndent</Command>"
		$actionStr = if ($cmd.action) { " -> $($cmd.action)" } elseif ($cmd.actions) { " -> $($cmd.actions.Count) action(s)" } else { "" }
		$addedCmds += "  + ${cmdName}${actionStr} (id=$cmdId)"
	}
	X "</_F>"

	$fragDoc = Parse-Fragment $script:xml.ToString()
	$importedCmds = Import-ElementNodes $fragDoc

	foreach ($node in $importedCmds) {
		Insert-IntoContainer -container $cmdsSection -newNode $node -afterName $null -childIndent $cmdChildIndent
	}
}

# === 12b. Add form-level events ===

$addedFormEvents = @()

if ($def.formEvents -and $def.formEvents.Count -gt 0) {
	$eventsSection = $root.SelectSingleNode("f:Events", $nsMgr)
	if (-not $eventsSection) {
		# Create Events section — insert after AutoCommandBar or at the beginning
		$eventsSection = $xmlDoc.CreateElement("Events", $formNs)
		$insertAfter = $root.SelectSingleNode("f:AutoCommandBar", $nsMgr)
		if ($insertAfter) {
			# Insert after AutoCommandBar (Events come after AutoCommandBar in 1C)
			$ws1 = $xmlDoc.CreateWhitespace("`r`n`t")
			$ws2 = $xmlDoc.CreateWhitespace("`r`n`t")
			if ($insertAfter.NextSibling) {
				$root.InsertBefore($ws1, $insertAfter.NextSibling) | Out-Null
				$root.InsertBefore($eventsSection, $ws1) | Out-Null
				$root.InsertBefore($ws2, $eventsSection) | Out-Null
			} else {
				$root.AppendChild($xmlDoc.CreateWhitespace("`r`n`t")) | Out-Null
				$root.AppendChild($eventsSection) | Out-Null
				$root.AppendChild($xmlDoc.CreateWhitespace("`r`n")) | Out-Null
			}
		} else {
			$firstChild = $root.FirstChild
			if ($firstChild) {
				$ws = $xmlDoc.CreateWhitespace("`r`n`t")
				$root.InsertBefore($eventsSection, $firstChild) | Out-Null
				$root.InsertBefore($ws, $eventsSection) | Out-Null
			} else {
				$root.AppendChild($xmlDoc.CreateWhitespace("`r`n`t")) | Out-Null
				$root.AppendChild($eventsSection) | Out-Null
			}
		}
	}

	$evtChildIndent = Get-ChildIndent $eventsSection
	if (-not $evtChildIndent -or $evtChildIndent -eq "") { $evtChildIndent = "`t`t" }

	# Generate event fragments
	$script:xml = New-Object System.Text.StringBuilder 512
	X "<_F $allNsDecl>"
	foreach ($fe in $def.formEvents) {
		$feName = "$($fe.name)"
		$feHandler = "$($fe.handler)"
		$callTypeAttr = if ($fe.callType) { " callType=`"$($fe.callType)`"" } else { "" }
		X "$evtChildIndent<Event name=`"$feName`"$callTypeAttr>$feHandler</Event>"
		$ctStr = if ($fe.callType) { "[$($fe.callType)]" } else { "" }
		$addedFormEvents += "  + $feName${ctStr} -> $feHandler"
	}
	X "</_F>"

	$fragDoc = Parse-Fragment $script:xml.ToString()
	$importedEvents = Import-ElementNodes $fragDoc

	foreach ($node in $importedEvents) {
		Insert-IntoContainer -container $eventsSection -newNode $node -afterName $null -childIndent $evtChildIndent
	}
}

# === 12c. Add element-level events ===

$addedElemEvents = @()

if ($def.elementEvents -and $def.elementEvents.Count -gt 0) {
	if (-not $rootCI) {
		$rootCI = $root.SelectSingleNode("f:ChildItems", $nsMgr)
	}

	foreach ($ee in $def.elementEvents) {
		$targetName = "$($ee.element)"
		$targetEl = Find-Element $rootCI $targetName
		if (-not $targetEl) {
			Write-Host "[WARN] Element '$targetName' not found — skipping elementEvent"
			continue
		}

		# Find or create Events element within the target
		$targetEvents = $targetEl.SelectSingleNode("f:Events", $nsMgr)
		if (-not $targetEvents) {
			$targetEvents = $xmlDoc.CreateElement("Events", $formNs)
			# Insert Events before closing tag (after last property, before ChildItems if any)
			$ciNode = $targetEl.SelectSingleNode("f:ChildItems", $nsMgr)
			if ($ciNode) {
				$ws = $xmlDoc.CreateWhitespace("`r`n" + (Get-ChildIndent $targetEl))
				$targetEl.InsertBefore($ws, $ciNode) | Out-Null
				$targetEl.InsertBefore($targetEvents, $ciNode) | Out-Null
			} else {
				$trailing = $targetEl.LastChild
				if ($trailing -and ($trailing.NodeType -eq 'Whitespace' -or $trailing.NodeType -eq 'SignificantWhitespace')) {
					$ws = $xmlDoc.CreateWhitespace("`r`n" + (Get-ChildIndent $targetEl))
					$targetEl.InsertBefore($ws, $trailing) | Out-Null
					$targetEl.InsertBefore($targetEvents, $trailing) | Out-Null
				} else {
					$targetEl.AppendChild($xmlDoc.CreateWhitespace("`r`n" + (Get-ChildIndent $targetEl))) | Out-Null
					$targetEl.AppendChild($targetEvents) | Out-Null
				}
			}
		}

		$eeChildIndent = Get-ChildIndent $targetEvents
		if (-not $eeChildIndent -or $eeChildIndent -eq "") {
			$parentIndent = Get-ChildIndent $targetEl
			$eeChildIndent = "$parentIndent`t"
		}

		# Create Event element
		$eeName = "$($ee.name)"
		$eeHandler = "$($ee.handler)"
		$callTypeAttr = if ($ee.callType) { " callType=`"$($ee.callType)`"" } else { "" }

		$script:xml = New-Object System.Text.StringBuilder 256
		X "<_F $allNsDecl>"
		X "$eeChildIndent<Event name=`"$eeName`"$callTypeAttr>$eeHandler</Event>"
		X "</_F>"

		$fragDoc = Parse-Fragment $script:xml.ToString()
		$importedEE = Import-ElementNodes $fragDoc

		foreach ($node in $importedEE) {
			Insert-IntoContainer -container $targetEvents -newNode $node -afterName $null -childIndent $eeChildIndent
		}

		$ctStr = if ($ee.callType) { "[$($ee.callType)]" } else { "" }
		$addedElemEvents += "  + $targetName.$eeName${ctStr} -> $eeHandler"
	}
}

# === 13. Save ===

$content = $xmlDoc.OuterXml
# Ensure encoding declaration is uppercase UTF-8
$content = $content -replace '^<\?xml version="1.0" encoding="utf-8"\?>', '<?xml version="1.0" encoding="UTF-8"?>'
# Match Configurator's compact empty tags without altering literal XML text.
# PreserveWhitespace alone does not preserve the self-closing tag spelling.
$content = [regex]::Replace($content, '(?s)<!\[CDATA\[.*?\]\]>|<!--.*?-->|<\?.*?\?>|(?<=\S) />', { param($m) if ($m.Value -eq ' />') { '/>' } else { $m.Value } })
$targetEol = if ([System.IO.File]::ReadAllText($resolvedFormPath) -match "`r`n") { "`r`n" } else { "`n" }
$content = ($content -replace "`r`n", "`n") -replace "`n", $targetEol

$enc = New-Object System.Text.UTF8Encoding($true)
[System.IO.File]::WriteAllText($resolvedFormPath, $content, $enc)

# === 14. Summary ===

if ($script:isExtension) {
	Write-Host "[EXTENSION] BaseForm detected — IDs start at 1000000+"
	Write-Host ""
}

if ($addedFormEvents.Count -gt 0) {
	Write-Host "Added form events:"
	foreach ($line in $addedFormEvents) { Write-Host $line }
	Write-Host ""
}

if ($addedElemEvents.Count -gt 0) {
	Write-Host "Added element events:"
	foreach ($line in $addedElemEvents) { Write-Host $line }
	Write-Host ""
}

if ($addedElems.Count -gt 0) {
	$posStr = ""
	if ($def.into) { $posStr += "into $($def.into)" }
	if ($def.after) { if ($posStr) { $posStr += ", " }; $posStr += "after $($def.after)" }
	if ($def.before) { if ($posStr) { $posStr += ", " }; $posStr += "before $($def.before)" }
	if ($posStr) { $posStr = " ($posStr)" }
	Write-Host "Added elements${posStr}:"
	foreach ($line in $addedElems) { Write-Host $line }
	Write-Host ""
}

if ($addedAttrs.Count -gt 0) {
	Write-Host "Added attributes:"
	foreach ($line in $addedAttrs) { Write-Host $line }
	Write-Host ""
}

if ($addedCmds.Count -gt 0) {
	Write-Host "Added commands:"
	foreach ($line in $addedCmds) { Write-Host $line }
	Write-Host ""
}

Write-Host "---"
$totalParts = @()
if ($addedFormEvents.Count -gt 0) { $totalParts += "$($addedFormEvents.Count) form event(s)" }
if ($addedElemEvents.Count -gt 0) { $totalParts += "$($addedElemEvents.Count) element event(s)" }
if ($addedElems.Count -gt 0) {
	$compStr = if ($companionCount -gt 0) { " (+$companionCount companions)" } else { "" }
	$totalParts += "$($addedElems.Count) element(s)$compStr"
}
if ($addedAttrs.Count -gt 0) { $totalParts += "$($addedAttrs.Count) attribute(s)" }
if ($addedCmds.Count -gt 0) { $totalParts += "$($addedCmds.Count) command(s)" }
Write-Host "Total: $($totalParts -join ', ')"
Write-Host "Run /form-validate to verify."
