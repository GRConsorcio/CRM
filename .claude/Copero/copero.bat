@echo off
chcp 65001 >nul
title Copero - Mod Simulador Carreira
set "COPERO_ROOT=%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -Command "& ([scriptblock]::Create(([IO.File]::ReadAllText('%~f0',[Text.Encoding]::UTF8) -split '#PS-START\r?\n',2)[1]))"
exit /b %errorlevel%
#PS-START
# Launcher do Mod menu - Simulador de Carreira (copero.com.ar)
# Pergunta como voce quer a carreira, abre o Chrome direto no jogo e ja carrega o mod (copero.js).
# Este trecho e PowerShell embutido no .bat: nao precisa de mais nenhum arquivo alem do copero.js.
# Variaveis opcionais (para testes): COPERO_CONFIG (json com as respostas), COPERO_PORT, COPERO_NOWAIT, COPERO_CHROME.

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$ConfigFile = $env:COPERO_CONFIG
$Port       = 9333; if ($env:COPERO_PORT) { $Port = [int]$env:COPERO_PORT }
$NoWait     = [bool]$env:COPERO_NOWAIT
$ChromePath = $env:COPERO_CHROME
$Root       = $env:COPERO_ROOT
$ModJs      = Join-Path $Root 'copero.js'
$DataDir    = Join-Path $env:LOCALAPPDATA 'CoperoMod'
$Profile    = Join-Path $DataDir 'chrome-profile'
$SavedCfg   = Join-Path $DataDir 'config.json'
$GameUrl    = 'https://copero.com.ar/juegos/simulador-carrera'
New-Item -ItemType Directory -Force $DataDir | Out-Null

# ---------- utilitarios ----------
function Norm([string]$s) {
  if (-not $s) { return '' }
  $d = $s.Normalize([Text.NormalizationForm]::FormD)
  $sb = New-Object Text.StringBuilder
  foreach ($c in $d.ToCharArray()) { if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($c) -ne 'NonSpacingMark') { [void]$sb.Append($c) } }
  return $sb.ToString().ToLowerInvariant()
}
function Get-Text([string]$u) {
  $wc = New-Object Net.WebClient
  $wc.Encoding = [Text.Encoding]::UTF8
  $wc.Headers['User-Agent'] = 'Mozilla/5.0'
  return $wc.DownloadString($u)
}
function Ask([string]$prompt, $default) {
  $d = ''
  if ($null -ne $default -and "$default" -ne '') { $d = " [$default]" }
  $r = Read-Host "$prompt$d"
  if ([string]::IsNullOrWhiteSpace($r)) { return $default }
  return $r.Trim()
}
function AskInt([string]$prompt, $default, [int]$min, [int]$max) {
  while ($true) {
    $r = Ask $prompt $default
    $n = 0
    if ([int]::TryParse("$r", [ref]$n) -and $n -ge $min -and $n -le $max) { return $n }
    Write-Host "  valor invalido (use um numero de $min a $max)" -ForegroundColor Yellow
  }
}
function AskYN([string]$prompt, [bool]$defaultYes) {
  $hint = 's/N'; if ($defaultYes) { $hint = 'S/n' }
  while ($true) {
    $r = Read-Host "$prompt ($hint)"
    if ([string]::IsNullOrWhiteSpace($r)) { return $defaultYes }
    switch -Regex ($r.Trim().ToLower()) { '^(s|y|sim|yes)$' { return $true } '^(n|nao|não|no)$' { return $false } }
    Write-Host '  responda s ou n' -ForegroundColor Yellow
  }
}
function Section([string]$t) { Write-Host ''; Write-Host $t -ForegroundColor Cyan }

# "18, 21-23" -> 18, 21, 22, 23
function Parse-Ages([string]$txt) {
  $set = New-Object System.Collections.Generic.SortedSet[int]
  foreach ($p in ($txt -split '[,;\s]+')) {
    $m = [regex]::Match($p.Trim(), '^(\d{1,2})(?:-(\d{1,2}))?$')
    if (-not $m.Success) { continue }
    $a = [int]$m.Groups[1].Value
    $b = $a; if ($m.Groups[2].Success) { $b = [int]$m.Groups[2].Value }
    if ($a -gt $b) { $t = $a; $a = $b; $b = $t }
    for ($x = [Math]::Max($a, 14); $x -le [Math]::Min($b, 45); $x++) { [void]$set.Add($x) }
  }
  return @($set)
}

# ---------- dados do jogo (clubes e paises, lidos do proprio site) ----------
function Load-GameData {
  $html  = Get-Text $GameUrl
  $idx   = [regex]::Match($html, '/assets/index-[\w-]+\.js').Value
  if (-not $idx) { throw 'nao achei o arquivo principal do jogo' }
  $idxJs = Get-Text ("https://copero.com.ar$idx")
  $chunk = [regex]::Match($idxJs, 'CareerSimulatorPage-[\w-]+\.js').Value
  if (-not $chunk) { throw 'nao achei o arquivo da carreira' }
  $txt = Get-Text ("https://copero.com.ar/assets/$chunk")

  $teams = New-Object System.Collections.ArrayList
  $seen = @{}
  foreach ($m in [regex]::Matches($txt, '\{"id":"([a-z0-9-]+)","name":"((?:[^"\\]|\\.)*)","short_name":"((?:[^"\\]|\\.)*)"')) {
    $id = $m.Groups[1].Value
    if ($seen.ContainsKey($id)) { continue }
    $seen[$id] = $true
    $rest = $txt.Substring($m.Index, [Math]::Min(700, $txt.Length - $m.Index))
    $country = [regex]::Match($rest, '/teams/([A-Za-z]{2,4})/').Groups[1].Value
    $name = $m.Groups[2].Value.Replace('\"', '"')
    $short = $m.Groups[3].Value.Replace('\"', '"')
    [void]$teams.Add([pscustomobject]@{ Id = $id; Name = $name; Country = $country; Key = (Norm "$name $short $id $country") })
  }

  $countries = New-Object System.Collections.ArrayList
  $seenC = @{}
  foreach ($m in [regex]::Matches($txt, '"name_en":"([^"]+)","name_es":"([^"]+)","name_pt":"([^"]+)","iso_alpha2":"([A-Za-z-]+)"')) {
    $iso = $m.Groups[4].Value.ToUpper()
    if ($seenC.ContainsKey($iso)) { continue }
    $seenC[$iso] = $true
    [void]$countries.Add([pscustomobject]@{ Iso = $iso; Name = $m.Groups[3].Value; Key = (Norm ($m.Groups[1].Value + ' ' + $m.Groups[3].Value + ' ' + $iso)) })
  }
  return @{ Teams = @($teams); Countries = @($countries) }
}

function Search-Items($items, [string]$q, [int]$max) {
  $words = (Norm $q) -split '\s+' | Where-Object { $_ }
  $out = New-Object System.Collections.ArrayList
  foreach ($it in $items) {
    $ok = $true
    foreach ($w in $words) { if (-not $it.Key.Contains($w)) { $ok = $false; break } }
    if ($ok) { [void]$out.Add($it); if ($out.Count -ge $max) { break } }
  }
  return @($out)
}

function Pick-Clubs([string]$title, $cat) {
  $ids = New-Object System.Collections.ArrayList
  $queries = New-Object System.Collections.ArrayList
  Section $title
  while ($true) {
    $q = Read-Host '  Digite parte do nome do clube (Enter para continuar)'
    if ([string]::IsNullOrWhiteSpace($q)) { break }
    if (-not $cat) { [void]$queries.Add($q.Trim()); Write-Host "  anotado: $q (sera procurado dentro do jogo)"; continue }
    $hits = @(Search-Items $cat $q 12)
    if ($hits.Count -eq 0) { Write-Host '  nada encontrado' -ForegroundColor Yellow; continue }
    for ($i = 0; $i -lt $hits.Count; $i++) { Write-Host ('   {0,2}) {1}  ({2})' -f ($i + 1), $hits[$i].Name, $hits[$i].Country) }
    $n = Read-Host '  Numero do clube (Enter cancela)'
    $k = 0
    if ([int]::TryParse("$n", [ref]$k) -and $k -ge 1 -and $k -le $hits.Count) {
      $club = $hits[$k - 1]
      if (-not $ids.Contains($club.Id)) { [void]$ids.Add($club.Id) }
      Write-Host ("  + {0}" -f $club.Name) -ForegroundColor Green
    }
  }
  return @{ Ids = @($ids); Queries = @($queries) }
}

function Pick-Country($countries) {
  while ($true) {
    $q = Ask '  Nacionalidade (nome ou sigla, ex.: Brasil, BR, Argentina)' 'BR'
    if (-not $countries -or $countries.Count -eq 0) { return $q.ToUpper() }
    $exact = @($countries | Where-Object { $_.Iso -eq $q.ToUpper() })
    if ($exact.Count -eq 1) { Write-Host ("  -> {0}" -f $exact[0].Name) -ForegroundColor Green; return $exact[0].Iso }
    $hits = @(Search-Items $countries $q 10)
    if ($hits.Count -eq 0) { Write-Host '  pais nao encontrado' -ForegroundColor Yellow; continue }
    if ($hits.Count -eq 1) { Write-Host ("  -> {0}" -f $hits[0].Name) -ForegroundColor Green; return $hits[0].Iso }
    for ($i = 0; $i -lt $hits.Count; $i++) { Write-Host ('   {0,2}) {1}  ({2})' -f ($i + 1), $hits[$i].Name, $hits[$i].Iso) }
    $n = Read-Host '  Numero (Enter para pesquisar de novo)'
    $k = 0
    if ([int]::TryParse("$n", [ref]$k) -and $k -ge 1 -and $k -le $hits.Count) { return $hits[$k - 1].Iso }
  }
}

# ---------- perguntas ----------
$Positions = @(
  @{ Code = 'ST';  Label = 'Centroavante' },        @{ Code = 'LW';  Label = 'Ponta esquerda' },   @{ Code = 'RW';  Label = 'Ponta direita' },
  @{ Code = 'CAM'; Label = 'Meia ofensivo' },       @{ Code = 'LM';  Label = 'Meia esquerda' },    @{ Code = 'RM';  Label = 'Meia direita' },
  @{ Code = 'CM';  Label = 'Meia central' },        @{ Code = 'CDM'; Label = 'Volante' },
  @{ Code = 'LB';  Label = 'Lateral esquerdo' },    @{ Code = 'RB';  Label = 'Lateral direito' },
  @{ Code = 'CB';  Label = 'Zagueiro' },            @{ Code = 'GK';  Label = 'Goleiro' }
)

function Ask-Config($data) {
  $cfg = @{}
  Section '=== Como voce quer a carreira ==='

  Write-Host ''
  Write-Host '  Modo da carreira:  1) Intensa (1 decisao por temporada)   2) Normal   3) Expressa'
  $m = AskInt '  Escolha' 1 1 3
  $cfg.mode = @('long', 'normal', 'express')[$m - 1]

  Section 'Jogador'
  $cfg.lastName = (Ask '  Sobrenome' 'SILVA').ToUpper()
  $cfg.number = AskInt '  Numero da camisa' 10 1 99
  Write-Host ''
  for ($i = 0; $i -lt $Positions.Count; $i++) { Write-Host ('   {0,2}) {1}  ({2})' -f ($i + 1), $Positions[$i].Label, $Positions[$i].Code) }
  $p = AskInt '  Posicao' 1 1 $Positions.Count
  $cfg.position = $Positions[$p - 1].Code
  $cfg.country = Pick-Country $(if ($data) { $data.Countries } else { $null })
  $cfg.foot = if ((Ask '  Perna dominante (E = esquerda, D = direita)' 'D').ToUpper().StartsWith('E')) { 'left' } else { 'right' }

  Section 'Atributos'
  $cfg.ovr = AskInt '  OVR minimo, desde os 16 anos (0 = jogo normal)' 80 0 99
  $cfg.goalsMin = AskInt '  Gols minimos por temporada (0 = jogo normal)' 0 0 200
  $cfg.assistsMin = AskInt '  Assistencias minimas por temporada (0 = jogo normal)' 0 0 200
  $cfg.bdMax = AskInt '  Limite de Bolas de Ouro (-1 = sem limite, o jogo decide)' (-1) (-1) 30
  if ($cfg.bdMax -ge 0) { $cfg.bdChance = AskInt '    Chance de cada Bola de Ouro ser mantida (%)' 30 0 100 } else { $cfg.bdChance = 30 }
  Write-Host ''
  Write-Host '  Ganhar TODOS os titulos do clube so nas idades que voce marcar (ex.: 18, 21-23).'
  Write-Host '  Enter = nenhuma agora; voce tambem marca depois, no menu dentro do jogo.'
  $cfg.trophyAges = @(Parse-Ages (Ask '  Idades' ''))

  $cat = if ($data) { $data.Teams } else { $null }
  $start = Pick-Clubs 'Clube inicial (aparece na oferta dos 16 anos; pode escolher varios)' $cat
  $extra = Pick-Clubs 'Clubes extras nas janelas de transferencia (Enter direto = Real Madrid, Barcelona, PSG, Man City, Liverpool)' $cat
  $cfg.start = $start.Ids; $cfg.startQuery = $start.Queries
  $cfg.extra = $extra.Ids; $cfg.extraQuery = $extra.Queries
  if ($cfg.extra.Count -eq 0 -and $cfg.extraQuery.Count -eq 0) { $cfg.extra = @('real-madrid', 'barcelona', 'paris-saint-germain', 'manchester-city', 'liverpool') }

  Write-Host ''
  $cfg.auto = AskYN '  Pular as telas iniciais automaticamente (ja entrar na oferta de clubes)?' $true
  return $cfg
}

# ---------- Chrome + CDP ----------
function Find-Chrome {
  if ($ChromePath -and (Test-Path $ChromePath)) { return $ChromePath }
  $c = @(
    "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
    "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
    "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
  )
  foreach ($p in $c) { if ($p -and (Test-Path $p)) { return $p } }
  try {
    $reg = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe' -ErrorAction Stop).'(default)'
    if ($reg -and (Test-Path $reg)) { return $reg }
  } catch {}
  throw 'Nao achei o Google Chrome neste computador.'
}
function Get-Targets {
  # no PowerShell 5.1 a lista chega como um unico objeto-array: emite item por item
  $r = Invoke-RestMethod "http://127.0.0.1:$Port/json" -TimeoutSec 2
  foreach ($i in @($r)) { $i }
}
function Get-PageTarget {
  foreach ($t in @(Get-Targets)) { if ($t.type -eq 'page' -and $t.webSocketDebuggerUrl) { return $t } }
  return $null
}

function Send-Cdp($ws, [int]$id, [string]$method, $params) {
  $msg = ConvertTo-Json -InputObject @{ id = $id; method = $method; params = $params } -Depth 10 -Compress
  $bytes = [Text.Encoding]::UTF8.GetBytes($msg)
  $seg = New-Object 'ArraySegment[byte]' -ArgumentList (, $bytes)
  [void]$ws.SendAsync($seg, [Net.WebSockets.WebSocketMessageType]::Text, $true, [Threading.CancellationToken]::None).GetAwaiter().GetResult()
}
function Receive-Cdp($ws) {
  $buf = New-Object byte[] 65536
  $seg = New-Object 'ArraySegment[byte]' -ArgumentList (, $buf)
  $sb = New-Object Text.StringBuilder
  do {
    $r = $ws.ReceiveAsync($seg, [Threading.CancellationToken]::None).GetAwaiter().GetResult()
    if ($r.MessageType -eq [Net.WebSockets.WebSocketMessageType]::Close) { return $null }
    [void]$sb.Append([Text.Encoding]::UTF8.GetString($buf, 0, $r.Count))
  } while (-not $r.EndOfMessage)
  return $sb.ToString()
}
function Invoke-Cdp($ws, [int]$id, [string]$method, $params) {
  Send-Cdp $ws $id $method $params
  while ($true) {
    $raw = Receive-Cdp $ws
    if ($null -eq $raw) { throw 'Chrome fechou a conexao' }
    $o = $raw | ConvertFrom-Json
    if ($o.id -eq $id) {
      if ($o.error) { throw ("Chrome recusou {0}: {1}" -f $method, $o.error.message) }
      return $o
    }
  }
}

# ---------- principal ----------
try {
  Write-Host ''
  Write-Host '  ==============================' -ForegroundColor Green
  Write-Host '   Copero - Mod Simulador Carreira' -ForegroundColor Green
  Write-Host '  ==============================' -ForegroundColor Green

  if (-not (Test-Path $ModJs)) { throw "Nao achei o copero.js ao lado do copero.bat ($ModJs)" }
  $chrome = Find-Chrome

  $cfg = $null
  if ($ConfigFile) {
    $o = Get-Content $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $cfg = @{}; $o.PSObject.Properties | ForEach-Object { $cfg[$_.Name] = $_.Value }
  } else {
    if (Test-Path $SavedCfg) {
      if (AskYN 'Usar a mesma configuracao da ultima vez?' $true) {
        $o = Get-Content $SavedCfg -Raw -Encoding UTF8 | ConvertFrom-Json
        $cfg = @{}; $o.PSObject.Properties | ForEach-Object { $cfg[$_.Name] = $_.Value }
      }
    }
    if (-not $cfg) {
      Write-Host ''
      Write-Host '  Carregando a lista de clubes e paises do jogo...' -ForegroundColor DarkGray
      $data = $null
      try { $data = Load-GameData } catch { Write-Host "  (nao consegui baixar a lista: $($_.Exception.Message); vou procurar os clubes dentro do jogo)" -ForegroundColor Yellow }
      $cfg = Ask-Config $data
      ConvertTo-Json -InputObject $cfg -Depth 5 | Set-Content -Path $SavedCfg -Encoding UTF8
    }
  }

  # configuracao do mod e identidade do jogador
  $ovr = [int]$cfg.ovr
  $bdMax = [int]$cfg.bdMax
  $mod = @{
    ovrOn = ($ovr -gt 0); ovr = [Math]::Max($ovr, 1)
    bdOn = ($bdMax -ge 0); bdMax = [Math]::Max($bdMax, 0); bdChance = [int]$cfg.bdChance
    trophyAges = @($cfg.trophyAges | Where-Object { $null -ne $_ -and "$_" -ne '' } | ForEach-Object { [int]$_ })
    goalsMin = [int]$cfg.goalsMin; assistsMin = [int]$cfg.assistsMin
    startOn = $true; start = @($cfg.start | Where-Object { $_ }); startQuery = @($cfg.startQuery | Where-Object { $_ })
    extraOn = $true; extra = @($cfg.extra | Where-Object { $_ }); extraQuery = @($cfg.extraQuery | Where-Object { $_ })
    auto = [bool]$cfg.auto; open = $true
  }
  $prefs = @{ mode = $cfg.mode; identity = @{
    nationalityIsoAlpha2 = $cfg.country; position = $cfg.position; lastName = $cfg.lastName
    preferredNumber = [int]$cfg.number; preferredFoot = $cfg.foot } }

  $prefsJson = ConvertTo-Json -InputObject $prefs -Depth 5 -Compress
  $modJson   = ConvertTo-Json -InputObject $mod -Depth 5 -Compress
  $pre = '(function(){try{if(window.top!==window||!/(^|\.)copero\.com\.ar$/.test(location.hostname))return;' +
         "localStorage.setItem('copero:minigames:career-simulator:preferences:v1',JSON.stringify($prefsJson));" +
         "localStorage.setItem('copero:minigames:career-simulator:language:v1','pt');" +
         "window.__COPMOD_CFG=$modJson;}catch(e){}})();"
  $source = $pre + "`n" + [IO.File]::ReadAllText($ModJs, [Text.Encoding]::UTF8)

  # abre (ou reaproveita) o Chrome do mod
  Write-Host ''
  Write-Host '  Abrindo o Chrome...' -ForegroundColor DarkGray
  $target = $null
  $running = $false
  try { Get-Targets | Out-Null; $running = $true } catch {}
  if ($running) {
    $target = Invoke-RestMethod -Method Put "http://127.0.0.1:$Port/json/new?about:blank"
  } else {
    New-Item -ItemType Directory -Force $Profile | Out-Null
    $chromeArgs = @("--remote-debugging-port=$Port", "--user-data-dir=`"$Profile`"", '--no-first-run', '--no-default-browser-check', '--window-size=1280,860', 'about:blank')
    Start-Process -FilePath $chrome -ArgumentList $chromeArgs | Out-Null
    for ($i = 0; $i -lt 60 -and -not $target; $i++) {
      Start-Sleep -Milliseconds 500
      try { $target = Get-PageTarget } catch {}
    }
  }
  if (-not $target) { throw 'O Chrome abriu mas nao respondeu na porta de controle.' }

  $ws = New-Object Net.WebSockets.ClientWebSocket
  $ws.ConnectAsync([Uri]$target.webSocketDebuggerUrl, [Threading.CancellationToken]::None).GetAwaiter().GetResult()
  Invoke-Cdp $ws 1 'Page.enable' @{} | Out-Null   # sem isto o Chrome ignora o script de inicializacao
  Invoke-Cdp $ws 2 'Page.addScriptToEvaluateOnNewDocument' @{ source = $source } | Out-Null
  Invoke-Cdp $ws 3 'Page.navigate' @{ url = $GameUrl } | Out-Null

  Write-Host ''
  Write-Host '  Pronto! O jogo abriu com o mod carregado.' -ForegroundColor Green
  Write-Host '  - No jogo: botao redondo no canto inferior direito (ou tecla Insert) abre/fecha o menu do mod.'
  Write-Host '  - Deixe esta janela aberta enquanto joga (se recarregar a pagina, o mod volta sozinho).'
  Write-Host '  - Fechar o Chrome do mod encerra isto aqui.'
  if ($NoWait) { return }

  try { while ($true) { if ($null -eq (Receive-Cdp $ws)) { break } } } catch {}
  Write-Host ''
  Write-Host '  Chrome fechado. Ate a proxima!'
} catch {
  Write-Host ''
  Write-Host ("  ERRO: {0}" -f $_.Exception.Message) -ForegroundColor Red
  if (-not $ConfigFile) { Read-Host '  Aperte Enter para fechar' | Out-Null }
  exit 1
}
