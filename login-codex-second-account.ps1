Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Invoke-Checked {
  param(
    [Parameter(Mandatory = $true)] [string] $FilePath,
    [Parameter()] [string[]] $ArgumentList = @()
  )
  & $FilePath @ArgumentList
  if ($LASTEXITCODE -ne 0) {
    throw "Command failed ($LASTEXITCODE): $FilePath $($ArgumentList -join ' ')"
  }
}

function Clone-JsonValue {
  param(
    [Parameter(Mandatory = $true)] $Value
  )
  return ($Value | ConvertTo-Json -Depth 100 | ConvertFrom-Json)
}

function Has-DynamicProperty {
  param(
    [Parameter(Mandatory = $true)] $Object,
    [Parameter(Mandatory = $true)] [string] $Name
  )
  if ($null -eq $Object) {
    return $false
  }
  return ($Object.PSObject.Properties.Match($Name).Count -gt 0)
}

function Ensure-JsonObjectProperty {
  param(
    [Parameter(Mandatory = $true)] $Object,
    [Parameter(Mandatory = $true)] [string] $Name
  )
  if (-not (Has-DynamicProperty -Object $Object -Name $Name)) {
    $Object | Add-Member -NotePropertyName $Name -NotePropertyValue ([pscustomobject]@{})
  } elseif ($null -eq $Object.$Name) {
    $Object.$Name = [pscustomobject]@{}
  }
}

function Ensure-JsonArrayProperty {
  param(
    [Parameter(Mandatory = $true)] $Object,
    [Parameter(Mandatory = $true)] [string] $Name
  )
  if (-not (Has-DynamicProperty -Object $Object -Name $Name)) {
    $Object | Add-Member -NotePropertyName $Name -NotePropertyValue @()
  } elseif ($null -eq $Object.$Name) {
    $Object.$Name = @()
  }
}

function Set-DynamicProperty {
  param(
    [Parameter(Mandatory = $true)] $Object,
    [Parameter(Mandatory = $true)] [string] $Name,
    [Parameter(Mandatory = $true)] $Value
  )
  if (Has-DynamicProperty -Object $Object -Name $Name) {
    $Object.PSObject.Properties[$Name].Value = $Value
  } else {
    $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
  }
}

function Get-DynamicProperty {
  param(
    [Parameter(Mandatory = $true)] $Object,
    [Parameter(Mandatory = $true)] [string] $Name
  )
  if (Has-DynamicProperty -Object $Object -Name $Name) {
    return $Object.PSObject.Properties[$Name].Value
  }
  return $null
}

function Build-SingleProfileAuthStore {
  param(
    [Parameter(Mandatory = $true)] [string] $ProfileId,
    [Parameter(Mandatory = $true)] $ProfileValue
  )

  $store = [pscustomobject]@{
    version  = 1
    profiles = [pscustomobject]@{}
    order    = [pscustomobject]@{}
  }
  Set-DynamicProperty -Object $store.profiles -Name $ProfileId -Value $ProfileValue
  Set-DynamicProperty -Object $store.order -Name "openai-codex" -Value @($ProfileId)
  return $store
}

function Build-LegacyAuthJson {
  param(
    [Parameter(Mandatory = $true)] $ProfileValue
  )

  $providerAuth = [pscustomobject]@{
    type = "oauth"
  }

  foreach ($field in @("access", "refresh", "expires", "accountId")) {
    if (Has-DynamicProperty -Object $ProfileValue -Name $field) {
      Set-DynamicProperty -Object $providerAuth -Name $field -Value $ProfileValue.$field
    }
  }

  return [pscustomobject]@{
    "openai-codex" = $providerAuth
  }
}

function Upsert-AgentConfig {
  param(
    [Parameter(Mandatory = $true)] [object[]] $AgentsList,
    [Parameter(Mandatory = $true)] [string] $AgentId,
    [Parameter(Mandatory = $true)] [scriptblock] $Mutator
  )

  $idx = -1
  for ($i = 0; $i -lt $AgentsList.Count; $i++) {
    if ($AgentsList[$i].id -eq $AgentId) {
      $idx = $i
      break
    }
  }

  if ($idx -lt 0) {
    $agent = [pscustomobject]@{ id = $AgentId }
    & $Mutator $agent
    return @($AgentsList + $agent)
  }

  $existing = $AgentsList[$idx]
  & $Mutator $existing
  return $AgentsList
}

function Configure-BizProSplit {
  param(
    [Parameter(Mandatory = $true)] [string] $StateDir,
    [Parameter(Mandatory = $true)] [string] $MainAuthPath,
    [Parameter(Mandatory = $true)] [string] $ConfigPath
  )

  $mainAgentDir = Join-Path $StateDir "agents\main\agent"
  $proAgentDir = Join-Path $StateDir "agents\pro\agent"
  $proAuthPath = Join-Path $proAgentDir "auth-profiles.json"
  $mainLegacyAuthPath = Join-Path $mainAgentDir "auth.json"
  $proLegacyAuthPath = Join-Path $proAgentDir "auth.json"
  $proWorkspace = Join-Path $StateDir "workspace-pro"

  New-Item -ItemType Directory -Path $proAgentDir -Force | Out-Null
  New-Item -ItemType Directory -Path $proWorkspace -Force | Out-Null

  $auth = Get-Content -Path $MainAuthPath -Raw | ConvertFrom-Json
  Ensure-JsonObjectProperty -Object $auth -Name "profiles"
  Ensure-JsonObjectProperty -Object $auth -Name "order"

  $defaultProfileId = "openai-codex:default"
  $bizProfileId = "openai-codex:biz"

  $defaultProfile = Get-DynamicProperty -Object $auth.profiles -Name $defaultProfileId
  $bizProfile = Get-DynamicProperty -Object $auth.profiles -Name $bizProfileId

  if ($null -eq $defaultProfile) {
    throw "Missing profile '$defaultProfileId' in $MainAuthPath"
  }
  if ($null -eq $bizProfile) {
    throw "Missing profile '$bizProfileId' in $MainAuthPath"
  }

  $bizOnlyStore = Build-SingleProfileAuthStore -ProfileId $bizProfileId -ProfileValue (Clone-JsonValue -Value $bizProfile)
  $proOnlyStore = Build-SingleProfileAuthStore -ProfileId $defaultProfileId -ProfileValue (Clone-JsonValue -Value $defaultProfile)

  $cfg = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
  Ensure-JsonObjectProperty -Object $cfg -Name "auth"
  Ensure-JsonObjectProperty -Object $cfg.auth -Name "profiles"
  Ensure-JsonObjectProperty -Object $cfg.auth -Name "order"
  Ensure-JsonObjectProperty -Object $cfg -Name "agents"
  Ensure-JsonArrayProperty -Object $cfg.agents -Name "list"

  if ($cfg.agents.list.Count -eq 0) {
    $cfg.agents.list = @([pscustomobject]@{ id = "main" })
  }

  Set-DynamicProperty -Object $cfg.auth.profiles -Name $defaultProfileId -Value ([pscustomobject]@{
      provider = "openai-codex"
      mode     = "oauth"
    })
  Set-DynamicProperty -Object $cfg.auth.profiles -Name $bizProfileId -Value ([pscustomobject]@{
      provider = "openai-codex"
      mode     = "oauth"
    })
  Set-DynamicProperty -Object $cfg.auth.order -Name "openai-codex" -Value @($bizProfileId, $defaultProfileId)

  $cfg.agents.list = Upsert-AgentConfig -AgentsList $cfg.agents.list -AgentId "main" -Mutator {
    param($agent)
    Set-DynamicProperty -Object $agent -Name "name" -Value "biz"
    Set-DynamicProperty -Object $agent -Name "default" -Value $true
    Ensure-JsonObjectProperty -Object $agent -Name "subagents"
    Set-DynamicProperty -Object $agent.subagents -Name "allowAgents" -Value @("pro")
  }

  $cfg.agents.list = Upsert-AgentConfig -AgentsList $cfg.agents.list -AgentId "pro" -Mutator {
    param($agent)
    Set-DynamicProperty -Object $agent -Name "name" -Value "pro"
    Set-DynamicProperty -Object $agent -Name "workspace" -Value $proWorkspace
    Set-DynamicProperty -Object $agent -Name "agentDir" -Value $proAgentDir
    Set-DynamicProperty -Object $agent -Name "model" -Value "openai-codex/gpt-5.3-codex"
  }

  foreach ($agent in $cfg.agents.list) {
    if ($agent.id -ne "main" -and (Has-DynamicProperty -Object $agent -Name "default")) {
      $agent.PSObject.Properties.Remove("default")
    }
  }

  $mainAgents = @($cfg.agents.list | Where-Object { $_.id -eq "main" })
  $otherAgents = @($cfg.agents.list | Where-Object { $_.id -ne "main" })
  $cfg.agents.list = @($mainAgents + $otherAgents)

  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($MainAuthPath, ($bizOnlyStore | ConvertTo-Json -Depth 100), $utf8NoBom)
  [System.IO.File]::WriteAllText($proAuthPath, ($proOnlyStore | ConvertTo-Json -Depth 100), $utf8NoBom)
  [System.IO.File]::WriteAllText($mainLegacyAuthPath, ((Build-LegacyAuthJson -ProfileValue $bizOnlyStore.profiles.$bizProfileId) | ConvertTo-Json -Depth 100), $utf8NoBom)
  [System.IO.File]::WriteAllText($proLegacyAuthPath, ((Build-LegacyAuthJson -ProfileValue $proOnlyStore.profiles.$defaultProfileId) | ConvertTo-Json -Depth 100), $utf8NoBom)
  [System.IO.File]::WriteAllText($ConfigPath, ($cfg | ConvertTo-Json -Depth 100), $utf8NoBom)

  return $proAuthPath
}

$userHome = $env:USERPROFILE
$stateDir = Join-Path $userHome ".openclaw"
$authPath = Join-Path $stateDir "agents\main\agent\auth-profiles.json"
$configPath = Join-Path $stateDir "openclaw.json"
$proAuthPath = Join-Path $stateDir "agents\pro\agent\auth-profiles.json"
$backupDir = Join-Path $stateDir "backup"
$repoRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }

if (-not (Test-Path $authPath)) {
  throw "auth-profiles.json not found: $authPath"
}
if (-not (Test-Path $configPath)) {
  throw "openclaw.json not found: $configPath"
}

New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
Copy-Item $authPath (Join-Path $backupDir "auth-profiles.$stamp.json") -Force
Copy-Item $configPath (Join-Path $backupDir "openclaw.$stamp.json") -Force

$auth = Get-Content -Path $authPath -Raw | ConvertFrom-Json
Ensure-JsonObjectProperty -Object $auth -Name "profiles"
Ensure-JsonObjectProperty -Object $auth -Name "order"

$defaultProfileId = "openai-codex:default"
$bizProfileId = "openai-codex:biz"

if ($auth.profiles.PSObject.Properties.Name.Contains($defaultProfileId)) {
  if (-not $auth.profiles.PSObject.Properties.Name.Contains($bizProfileId)) {
    Set-DynamicProperty -Object $auth.profiles -Name $bizProfileId -Value $auth.profiles.$defaultProfileId
  }
}
Set-DynamicProperty -Object $auth.order -Name "openai-codex" -Value @($defaultProfileId, $bizProfileId)

$cfg = Get-Content -Path $configPath -Raw | ConvertFrom-Json
Ensure-JsonObjectProperty -Object $cfg -Name "auth"
Ensure-JsonObjectProperty -Object $cfg.auth -Name "profiles"
Ensure-JsonObjectProperty -Object $cfg.auth -Name "order"

Set-DynamicProperty -Object $cfg.auth.profiles -Name $defaultProfileId -Value ([pscustomobject]@{
    provider = "openai-codex"
    mode = "oauth"
  })
Set-DynamicProperty -Object $cfg.auth.profiles -Name $bizProfileId -Value ([pscustomobject]@{
    provider = "openai-codex"
    mode = "oauth"
  })
Set-DynamicProperty -Object $cfg.auth.order -Name "openai-codex" -Value @($defaultProfileId, $bizProfileId)

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($authPath, ($auth | ConvertTo-Json -Depth 100), $utf8NoBom)
[System.IO.File]::WriteAllText($configPath, ($cfg | ConvertTo-Json -Depth 100), $utf8NoBom)

Write-Host "[1/4] Existing Codex account preserved as '$bizProfileId'."
Write-Host "[2/6] Starting OAuth login for the new account..."

Invoke-Checked -FilePath "openclaw" -ArgumentList @(
  "onboard",
  "--mode",
  "local",
  "--auth-choice",
  "openai-codex",
  "--gateway-port",
  "18789",
  "--gateway-bind",
  "lan",
  "--no-install-daemon",
  "--skip-ui",
  "--skip-channels",
  "--skip-skills",
  "--skip-health"
)

Write-Host "[3/6] Splitting accounts by role (main=biz, pro=default)..."
$proAuthPath = Configure-BizProSplit -StateDir $stateDir -MainAuthPath $authPath -ConfigPath $configPath

Write-Host "[4/6] Uploading updated state to R2..."
$bucket = if ($env:R2_BUCKET_NAME -and $env:R2_BUCKET_NAME.Trim()) { $env:R2_BUCKET_NAME.Trim() } else { "moltbot-data" }

Write-Host "[5/6] Deploying moltworker..."
Push-Location $repoRoot
try {
  Invoke-Checked -FilePath "npx" -ArgumentList @(
    "wrangler",
    "r2",
    "object",
    "put",
    "$bucket/openclaw/agents/main/agent/auth-profiles.json",
    "--file",
    $authPath,
    "--remote"
  )
  Invoke-Checked -FilePath "npx" -ArgumentList @(
    "wrangler",
    "r2",
    "object",
    "put",
    "$bucket/openclaw/agents/pro/agent/auth-profiles.json",
    "--file",
    $proAuthPath,
    "--remote"
  )
  Invoke-Checked -FilePath "npx" -ArgumentList @(
    "wrangler",
    "r2",
    "object",
    "put",
    "$bucket/openclaw/openclaw.json",
    "--file",
    $configPath,
    "--remote"
  )
  Invoke-Checked -FilePath "npm" -ArgumentList @("run", "deploy")
} finally {
  Pop-Location
}

Write-Host "[6/6] Done. Accounts are split (main=biz, pro=default), synced to R2, and deployed."
