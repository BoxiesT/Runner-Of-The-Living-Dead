# Windows/PowerShell version of the integration kit (two real headless editors talking over ENet).
#
#   powershell -ExecutionPolicy Bypass -File glc_kit.ps1 -Godot C:\path\Godot_v4.7.2-stable_win64_console.exe
#   powershell -ExecutionPolicy Bypass -File glc_kit.ps1 -Godot ... -Scenarios tree_basic,files_sync
#
# It builds two throw-away projects (A = host, B = client) with the addon + the test driver, runs every
# scenario with both editors at the same time and prints PASS/FAIL per scenario.
param(
	[Parameter(Mandatory = $true)][string]$Godot,
	[string[]]$Scenarios = @("net_echo", "tree_basic", "props_concurrent", "names_concurrent", "client_edits", "late_join", "big_subtree", "script_concurrent", "files_sync", "empty_join", "files_live", "tree_live", "script_attach", "tree_edge", "instance_reload", "discovery", "dock_check"),
	[string]$WorkDir = (Join-Path $env:TEMP "glc_kit"),
	[int]$Timeout = 150,
	[switch]$Rebuild,
	[switch]$Gui   # real editor windows (rendering, CodeEdit drawing, dialogs) instead of --headless
)

$ErrorActionPreference = "Stop"
$Scenarios = @($Scenarios | ForEach-Object { $_ -split "," } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$Here =Split-Path -Parent $MyInvocation.MyCommand.Path
$AddonDir = (Resolve-Path (Join-Path $Here "..\..")).Path          # ...\addons\godot_live_collab
$OutDir = Join-Path $WorkDir "out"

$ProjectGodot = "; Engine configuration file.`nconfig_version=5`n`n[application]`nconfig/name=`"GLC Test`"`nconfig/features=PackedStringArray(`"4.7`")`n`n[editor_plugins]`nenabled=PackedStringArray(`"res://addons/godot_live_collab/plugin.cfg`", `"res://addons/glc_driver/plugin.cfg`")`n"

function Reset-Project([string]$P) {
	# scenarios may change project settings (autoloads, input...): every run starts from the pristine file
	Set-Content -Encoding ascii -NoNewline -Path (Join-Path $P "project.godot") -Value $ProjectGodot
	Set-Content -Encoding ascii -NoNewline -Path (Join-Path $P "main.tscn") -Value "[gd_scene format=3]`n`n[node name=`"Main`" type=`"Node2D`"]`n`n[node name=`"Player`" type=`"Sprite2D`" parent=`".`"]`nposition = Vector2(10, 20)`n`n[node name=`"UI`" type=`"Control`" parent=`".`"]`nlayout_mode = 3`nanchors_preset = 0`n"
	Set-Content -Encoding ascii -NoNewline -Path (Join-Path $P "player.gd") -Value "extends Node2D`n`nvar speed := 10`n`nfunc _ready():`n`tprint(speed)`n"
	foreach ($x in @("res_extra", ".glc_backup", "shared", "live", "emptydir", "client_only.txt", "from_client.txt", ".godot\glc_manifest_cache.json", "other.tscn", "enemy.tscn", "scripts", "art", "levels", "empty_folder", "game.gd", "game.gd.uid", ".godot\editor\editor_layout.cfg", "attached.gd", "attached.gd.uid", "ui_script.gd", "ui_script.gd.uid", "second.gd", "second.gd.uid", "ui.gd", "ui.gd.uid", "main.gd", "main.gd.uid")) {
		$t = Join-Path $P $x
		if (Test-Path $t) { Remove-Item -Recurse -Force $t }
	}
}

function Copy-Addon([string]$P) {
	$dst = Join-Path $P "addons\godot_live_collab"
	if (Test-Path $dst) { Remove-Item -Recurse -Force $dst }
	Copy-Item -Recurse $AddonDir $dst
	Remove-Item -Recurse -Force (Join-Path $dst "tests\integration")
	$drv = Join-Path $P "addons\glc_driver"
	New-Item -ItemType Directory -Force $drv | Out-Null
	Copy-Item (Join-Path $Here "driver\addons\glc_driver\*") $drv -Force
}

function New-TestProject([string]$P) {
	if (Test-Path $P) { Remove-Item -Recurse -Force $P }
	New-Item -ItemType Directory -Force (Join-Path $P "addons") | Out-Null
	Copy-Addon $P
	Reset-Project $P
	# first start imports the project (class cache, uid files)
	$p0 = Start-Process -FilePath $Godot -ArgumentList @("--headless", "--editor", "--path", "`"$P`"", "--quit-after", "120") -PassThru -WindowStyle Hidden -RedirectStandardOutput (Join-Path $WorkDir "import.log") -RedirectStandardError (Join-Path $WorkDir "import.err")
	if (-not $p0.WaitForExit(120000)) { $p0.Kill() }
}

function Invoke-Pair([string]$Scenario, [int]$Port) {
	$A = Join-Path $WorkDir "A"; $B = Join-Path $WorkDir "B"
	foreach ($P in @($A, $B)) { Reset-Project $P; Copy-Addon $P }
	if (Test-Path $OutDir) { Remove-Item -Recurse -Force $OutDir }
	New-Item -ItemType Directory -Force $OutDir | Out-Null
	$t0 = [double]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) / 1000.0 + 20
	$t0s = $t0.ToString([System.Globalization.CultureInfo]::InvariantCulture)
	$procs = @()
	foreach ($role in @("host", "client")) {
		$P = if ($role -eq "host") { $A } else { $B }
		$json = Join-Path $OutDir "$role.json"
		$mode = if ($Gui) { @("--windowed", "--resolution", "1100x700", "--position", $(if ($role -eq "host") { "0,0" } else { "1120,0" })) } else { @("--headless") }
		$argl = $mode + @("--editor", "--path", "`"$P`"", "--quit-after", "100000", "--", "--glc-role=$role", "--glc-scenario=$Scenario", "--glc-port=$Port", "--glc-t0=$t0s", "--glc-out=`"$json`"")
		$procs += Start-Process -FilePath $Godot -ArgumentList $argl -PassThru -WindowStyle Hidden -RedirectStandardOutput (Join-Path $OutDir "$role.log") -RedirectStandardError (Join-Path $OutDir "$role.err")
		Start-Sleep -Milliseconds 500
	}
	$deadline = (Get-Date).AddSeconds($Timeout)
	foreach ($pr in $procs) {
		$left = [int][Math]::Max(1000, ($deadline - (Get-Date)).TotalMilliseconds)
		if (-not $pr.WaitForExit($left)) { try { $pr.Kill() } catch {} }
	}
	foreach ($role in @("host", "client")) {
		$lines = @()
		foreach ($f in @("$role.log", "$role.err")) {
			$fp = Join-Path $OutDir $f
			if (Test-Path $fp) { $lines += Get-Content $fp }
		}
		$errs = $lines | Where-Object { $_ -match "SCRIPT ERROR|^ERROR|Invalid|Nonexistent|Parse Error" -and $_ -notmatch "Couldn't open directory|still in use at exit|!_is_active" } | Select-Object -Unique -First 8
		foreach ($e in $errs) { Write-Host "  [$role] $e" -ForegroundColor DarkYellow }
	}
}

function Read-Result([string]$role) {
	$fp = Join-Path $OutDir "$role.json"
	if (-not (Test-Path $fp)) { return @{ ok = $false; why = "no result file" } }
	try { return (Get-Content $fp -Raw | ConvertFrom-Json) } catch { return @{ ok = $false; why = "bad json" } }
}

function Compare-Result() {
	$h = Read-Result "host"; $c = Read-Result "client"
	$ok = [bool]$h.ok -and [bool]$c.ok
	Write-Host ("  host ok: {0} {1} | client ok: {2} {3}" -f $h.ok, $h.why, $c.ok, $c.why)
	foreach ($side in @(@("host", $h), @("client", $c))) {
		$r = $side[1]
		if ($r.checks) {
			foreach ($pp in $r.checks.PSObject.Properties) {
				$v = [bool]$pp.Value
				if (-not $v) { $ok = $false }
				Write-Host ("    {0,-7} {1,-40} {2}" -f $side[0], $pp.Name, $(if ($v) { "PASS" } else { "FAIL <<<<<<" }))
			}
		}
	}
	if ($h.dump -or $c.dump) {
		$hd = ($h.dump | ConvertTo-Json -Depth 8 -Compress); $cd = ($c.dump | ConvertTo-Json -Depth 8 -Compress)
		if ($hd -eq $cd) { Write-Host ("  TREES IDENTICAL ({0} nodes)" -f @($h.dump).Count) }
		else {
			$ok = $false
			Write-Host "  TREES DIVERGE" -ForegroundColor Red
			Write-Host "    host  : $hd"
			Write-Host "    client: $cd"
		}
	}
	if ($h.text -or $c.text) {
		if ($h.text -eq $c.text) { Write-Host ("  SCRIPT TEXT IDENTICAL ({0} chars)" -f "$($h.text)".Length) }
		else { $ok = $false; Write-Host "  SCRIPT TEXT DIVERGES`n    host  : $($h.text)`n    client: $($c.text)" -ForegroundColor Red }
	}
	foreach ($key in @("stage1", "files")) {
		if ($h.$key -or $c.$key) {
			$hf = @{}; $cf = @{}
			if ($h.$key) { foreach ($pp in $h.$key.PSObject.Properties) { $hf[$pp.Name] = $pp.Value } }
			if ($c.$key) { foreach ($pp in $c.$key.PSObject.Properties) { $cf[$pp.Name] = $pp.Value } }
			$bad = @()
			foreach ($k in (@($hf.Keys) + @($cf.Keys) | Sort-Object -Unique)) { if ($hf[$k] -ne $cf[$k]) { $bad += $k } }
			if ($bad.Count -eq 0) { Write-Host ("  {0}: IDENTICAL (host={1} client={2})" -f $key, $hf.Count, $cf.Count) }
			else {
				$ok = $false
				Write-Host ("  {0}: DIFFER" -f $key) -ForegroundColor Red
				foreach ($k in $bad) { Write-Host ("    {0,-44} host={1} client={2}" -f $k, $hf[$k], $cf[$k]) }
			}
		}
	}
	if ($h.journal_delta) { Write-Host "  operations sent for the new subtree: $($h.journal_delta)" }
	foreach ($side in @(@("host", $h), @("client", $c))) {
		if ($side[1].latency) {
			$parts = @(); foreach ($pp in $side[1].latency.PSObject.Properties) { $parts += ("{0}={1:N2}s" -f $pp.Name, [double]$pp.Value) }
			Write-Host ("  latency ({0}): {1}" -f $side[0], ($parts -join "  "))
		}
	}
	return $ok
}

New-Item -ItemType Directory -Force $WorkDir | Out-Null
$A = Join-Path $WorkDir "A"; $B = Join-Path $WorkDir "B"
if ($Rebuild -or -not (Test-Path (Join-Path $A "project.godot"))) {
	Write-Host "Building test projects in $WorkDir ..."
	New-TestProject $A
	if (Test-Path $B) { Remove-Item -Recurse -Force $B }
	Copy-Item -Recurse $A $B
}

$results = [ordered]@{}
$port = 25600 + (Get-Random -Maximum 3000)
foreach ($sc in $Scenarios) {
	$port += 1
	Write-Host "=== $sc (port $port)" -ForegroundColor Cyan
	Invoke-Pair $sc $port
	$ok = Compare-Result
	$results[$sc] = $ok
	if ($ok) { Write-Host "--> PASS" -ForegroundColor Green } else { Write-Host "--> FAIL" -ForegroundColor Red; Copy-Item -Recurse $OutDir (Join-Path $WorkDir "fail_$sc") -Force }
}
Write-Host ""
foreach ($k in $results.Keys) { Write-Host ("{0,-22} {1}" -f $k, $(if ($results[$k]) { "PASS" } else { "FAIL" })) }
if ($results.Values -contains $false) { exit 1 } else { exit 0 }

