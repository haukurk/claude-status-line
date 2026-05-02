# Maintained at: https://github.com/haukurk/claude-status-line
# Single line: Model | tokens | %used | %remain | think | 5h bar @reset | 7d bar @reset | extra

$VERSION = "1.1.1"

$input = $Input | Out-String
if ([string]::IsNullOrWhiteSpace($input)) {
    Write-Host "Claude" -NoNewline
    exit 0
}

$json = $input | ConvertFrom-Json

# ANSI colors matching oh-my-posh theme
$blue   = "`e[38;2;0;153;255m"
$orange = "`e[38;2;255;176;85m"
$green  = "`e[38;2;0;160;0m"
$cyan   = "`e[38;2;46;149;153m"
$red    = "`e[38;2;255;85;85m"
$yellow = "`e[38;2;230;200;0m"
$purple = "`e[38;2;167;139;250m"
$white  = "`e[38;2;220;220;220m"
$dim    = "`e[2m"
$rst    = "`e[0m"

function Format-Tokens {
    param([long]$num)
    if ($num -ge 1000000) {
        $v = [math]::Round($num / 1000000, 1)
        if ($v -eq [math]::Floor($v)) { return "{0:0}m" -f $v }
        else { return "{0:0.0}m" -f $v }
    } elseif ($num -ge 1000) {
        return "{0:0}k" -f [math]::Round($num / 1000)
    } else {
        return "$num"
    }
}

function Format-Commas {
    param([long]$num)
    return $num.ToString("N0")
}

function Get-UsageColor {
    param([int]$pct)
    if ($pct -ge 90) {
        if ([int](Get-Date -UFormat %s) % 2 -eq 0) {
            return "`e[38;2;255;85;85m"
        } else {
            return "`e[38;2;255;160;160m"
        }
    } elseif ($pct -ge 70) { return $orange }
    elseif ($pct -ge 50) { return $yellow }
    else { return $green }
}

function Version-GreaterThan {
    param([string]$a, [string]$b)
    $a = $a -replace '^v', ''
    $b = $b -replace '^v', ''
    try {
        $va = [version]$a
        $vb = [version]$b
        return $va -gt $vb
    } catch {
        return $false
    }
}

# Resolve config directory
$claudeConfigDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR }
                   else { Join-Path $env:USERPROFILE ".claude" }

# ===== Extract data from JSON =====
$modelName = if ($json.model.display_name) { $json.model.display_name } else { "Claude" }
$modelName = $modelName -replace ' *\(([0-9.]*[kKmM]*) context\)', ' $1'

$size = if ($json.context_window.context_window_size) { [long]$json.context_window.context_window_size } else { 200000 }
if ($size -eq 0) { $size = 200000 }

$inputTokens = if ($json.context_window.current_usage.input_tokens) { [long]$json.context_window.current_usage.input_tokens } else { 0 }
$cacheCreate = if ($json.context_window.current_usage.cache_creation_input_tokens) { [long]$json.context_window.current_usage.cache_creation_input_tokens } else { 0 }
$cacheRead   = if ($json.context_window.current_usage.cache_read_input_tokens) { [long]$json.context_window.current_usage.cache_read_input_tokens } else { 0 }
$current = $inputTokens + $cacheCreate + $cacheRead

$usedTokens  = Format-Tokens $current
$totalTokens = Format-Tokens $size

$pctUsed = if ($size -gt 0) { [math]::Floor($current * 100 / $size) } else { 0 }
$pctRemain = 100 - $pctUsed

$usedComma   = Format-Commas $current
$remainComma = Format-Commas ($size - $current)

# Check reasoning effort
$settingsPath = Join-Path $claudeConfigDir "settings.json"
$effortLevel = "medium"
if ($env:CLAUDE_CODE_EFFORT_LEVEL) {
    $effortLevel = $env:CLAUDE_CODE_EFFORT_LEVEL
} elseif (Test-Path $settingsPath) {
    try {
        $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json
        if ($settings.effortLevel) { $effortLevel = $settings.effortLevel }
    } catch {}
}

# ===== Build single-line output =====
$out = "${blue}${modelName}${rst}"

# Current working directory
$cwd = $json.cwd
if ($cwd) {
    $displayDir = Split-Path $cwd -Leaf
    $gitBranch = $null
    try {
        $gitBranch = git -C $cwd rev-parse --abbrev-ref HEAD 2>$null
    } catch {}
    $out += " ${dim}|${rst} "
    $out += "${cyan}${displayDir}${rst}"
    if ($gitBranch) {
        $out += "${dim}@${rst}${green}${gitBranch}${rst}"
        try {
            $gitNumstat = git -C $cwd diff --numstat 2>$null
            if ($gitNumstat) {
                $adds = 0; $dels = 0
                foreach ($line in $gitNumstat -split "`n") {
                    $parts = $line -split '\s+'
                    if ($parts.Count -ge 2) {
                        $adds += [int]$parts[0]
                        $dels += [int]$parts[1]
                    }
                }
                if (($adds + $dels) -gt 0) {
                    $out += " ${dim}(${rst}${green}+${adds}${rst} ${red}-${dels}${rst}${dim})${rst}"
                }
            }
        } catch {}
    }
}

$out += " ${dim}|${rst} "
$out += "${orange}${usedTokens}/${totalTokens}${rst} ${dim}(${rst}${green}${pctUsed}%${rst}${dim})${rst}"
$out += " ${dim}|${rst} "
$out += "effort: "
switch ($effortLevel) {
    "low"    { $out += "${dim}${effortLevel}${rst}" }
    "medium" { $out += "${orange}med${rst}" }
    "high"   { $out += "${green}${effortLevel}${rst}" }
    "xhigh"  { $out += "${purple}${effortLevel}${rst}" }
    "max"    { $out += "${red}${effortLevel}${rst}" }
    default  { $out += "${green}${effortLevel}${rst}" }
}

# ===== OAuth token resolution =====
function Get-OAuthToken {
    # 1. Explicit env var override
    if ($env:CLAUDE_CODE_OAUTH_TOKEN) {
        return $env:CLAUDE_CODE_OAUTH_TOKEN
    }

    # 2. Windows Credential Manager (via cmdkey / CredentialManager module)
    # Claude Code stores credentials with a service name pattern
    try {
        if (Get-Command "cmdkey" -ErrorAction SilentlyContinue) {
            $keyName = "Claude Code-credentials"
            if ($env:CLAUDE_CONFIG_DIR) {
                $dirHash = [System.BitConverter]::ToString(
                    [System.Security.Cryptography.SHA256]::Create().ComputeHash(
                        [System.Text.Encoding]::UTF8.GetBytes($env:CLAUDE_CONFIG_DIR)
                    )
                ).Replace("-","").Substring(0,8).ToLower()
                $keyName = "Claude Code-credentials-$dirHash"
            }
            # Try PowerShell CredentialManager module if available
            if (Get-Command "Get-StoredCredential" -ErrorAction SilentlyContinue) {
                $cred = Get-StoredCredential -Target $keyName -ErrorAction SilentlyContinue
                if ($cred) {
                    $blob = $cred.GetNetworkCredential().Password
                    $credJson = $blob | ConvertFrom-Json
                    if ($credJson.claudeAiOauth.accessToken) {
                        return $credJson.claudeAiOauth.accessToken
                    }
                }
            }
        }
    } catch {}

    # 3. Credentials file
    $credsFile = Join-Path $claudeConfigDir ".credentials.json"
    if (Test-Path $credsFile) {
        try {
            $credJson = Get-Content $credsFile -Raw | ConvertFrom-Json
            if ($credJson.claudeAiOauth.accessToken -and $credJson.claudeAiOauth.accessToken -ne "null") {
                return $credJson.claudeAiOauth.accessToken
            }
        } catch {}
    }

    return $null
}

# ===== Usage limits with progress bars =====
$builtinFiveHourPct   = $json.rate_limits.five_hour.used_percentage
$builtinFiveHourReset = $json.rate_limits.five_hour.resets_at
$builtinSevenDayPct   = $json.rate_limits.seven_day.used_percentage
$builtinSevenDayReset = $json.rate_limits.seven_day.resets_at

$useBuiltin = ($null -ne $builtinFiveHourPct) -or ($null -ne $builtinSevenDayPct)

# Cache setup
$configDirHash = [System.BitConverter]::ToString(
    [System.Security.Cryptography.SHA256]::Create().ComputeHash(
        [System.Text.Encoding]::UTF8.GetBytes($claudeConfigDir)
    )
).Replace("-","").Substring(0,8).ToLower()

$cacheDir = Join-Path $env:TEMP "claude"
if (-not (Test-Path $cacheDir)) { New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null }
$cacheFile = Join-Path $cacheDir "statusline-usage-cache-${configDirHash}.json"
$cacheMaxAge = 60

$needsRefresh = $true
$usageData = $null

if ((Test-Path $cacheFile) -and ((Get-Item $cacheFile).Length -gt 0)) {
    $cacheMtime = (Get-Item $cacheFile).LastWriteTime
    $cacheAge = ((Get-Date) - $cacheMtime).TotalSeconds
    if ($cacheAge -lt $cacheMaxAge) {
        $needsRefresh = $false
    }
    try {
        $usageData = Get-Content $cacheFile -Raw | ConvertFrom-Json
    } catch {}
}

# Determine if builtin data is trustworthy
$effectiveBuiltin = $false
if ($useBuiltin) {
    if (($null -ne $builtinFiveHourPct -and [math]::Round([double]$builtinFiveHourPct) -ne 0) -or
        ($null -ne $builtinSevenDayPct -and [math]::Round([double]$builtinSevenDayPct) -ne 0)) {
        $effectiveBuiltin = $true
    }
    if (-not $effectiveBuiltin) {
        if (($builtinFiveHourReset -and $builtinFiveHourReset -ne "null" -and $builtinFiveHourReset -ne 0) -or
            ($builtinSevenDayReset -and $builtinSevenDayReset -ne "null" -and $builtinSevenDayReset -ne 0)) {
            $effectiveBuiltin = $true
        }
    }
}

function Format-EpochToTime {
    param([long]$epoch, [string]$format = "HH:mm")
    $dt = [DateTimeOffset]::FromUnixTimeSeconds($epoch).LocalDateTime
    return $dt.ToString($format)
}

function Format-IsoToLocal {
    param([string]$isoStr, [string]$style = "time")
    if ([string]::IsNullOrEmpty($isoStr) -or $isoStr -eq "null") { return $null }
    try {
        $dt = [DateTimeOffset]::Parse($isoStr).LocalDateTime
        switch ($style) {
            "time"     { return $dt.ToString("HH:mm") }
            "datetime" { return $dt.ToString("MMM d, HH:mm") }
            "date"     { return $dt.ToString("MMM d") }
        }
    } catch { return $null }
}

$sep = " ${dim}|${rst} "

if ($effectiveBuiltin) {
    # Use rate_limits from JSON input
    if ($null -ne $builtinFiveHourPct) {
        $fiveHourPct = [math]::Round([double]$builtinFiveHourPct)
        $fiveHourColor = Get-UsageColor $fiveHourPct
        $out += "${sep}${white}5h${rst} ${fiveHourColor}${fiveHourPct}%${rst}"
        if ($builtinFiveHourReset -and $builtinFiveHourReset -ne "null") {
            $fiveHourResetStr = Format-EpochToTime ([long]$builtinFiveHourReset)
            $out += " ${dim}@${fiveHourResetStr}${rst}"
        }
    }

    if ($null -ne $builtinSevenDayPct) {
        $sevenDayPct = [math]::Round([double]$builtinSevenDayPct)
        $sevenDayColor = Get-UsageColor $sevenDayPct
        $out += "${sep}${white}7d${rst} ${sevenDayColor}${sevenDayPct}%${rst}"
        if ($builtinSevenDayReset -and $builtinSevenDayReset -ne "null") {
            $sevenDayResetStr = Format-EpochToTime ([long]$builtinSevenDayReset) "MMM d, HH:mm"
            $out += " ${dim}@${sevenDayResetStr}${rst}"
        }
    }

    # Cache builtin values as fallback (convert epoch to ISO for API-format compatibility)
    $fhResetJson = "null"
    if ($builtinFiveHourReset -and $builtinFiveHourReset -ne "null" -and $builtinFiveHourReset -ne 0) {
        $fhIso = [DateTimeOffset]::FromUnixTimeSeconds([long]$builtinFiveHourReset).ToString("yyyy-MM-ddTHH:mm:ssZ")
        $fhResetJson = "`"$fhIso`""
    }
    $sdResetJson = "null"
    if ($builtinSevenDayReset -and $builtinSevenDayReset -ne "null" -and $builtinSevenDayReset -ne 0) {
        $sdIso = [DateTimeOffset]::FromUnixTimeSeconds([long]$builtinSevenDayReset).ToString("yyyy-MM-ddTHH:mm:ssZ")
        $sdResetJson = "`"$sdIso`""
    }
    $fhPctVal = if ($builtinFiveHourPct) { $builtinFiveHourPct } else { 0 }
    $sdPctVal = if ($builtinSevenDayPct) { $builtinSevenDayPct } else { 0 }
    $cacheJson = "{`"five_hour`":{`"utilization`":$fhPctVal,`"resets_at`":$fhResetJson},`"seven_day`":{`"utilization`":$sdPctVal,`"resets_at`":$sdResetJson}}"
    try { $cacheJson | Set-Content $cacheFile -NoNewline } catch {}

} elseif ($usageData -and $usageData.five_hour) {
    # Fall back: API-fetched or cached usage data
    $fiveHourPct = [math]::Round([double]$usageData.five_hour.utilization)
    $fiveHourColor = Get-UsageColor $fiveHourPct
    $fiveHourReset = Format-IsoToLocal $usageData.five_hour.resets_at "time"
    $out += "${sep}${white}5h${rst} ${fiveHourColor}${fiveHourPct}%${rst}"
    if ($fiveHourReset) { $out += " ${dim}@${fiveHourReset}${rst}" }

    $sevenDayPct = [math]::Round([double]$usageData.seven_day.utilization)
    $sevenDayColor = Get-UsageColor $sevenDayPct
    $sevenDayReset = Format-IsoToLocal $usageData.seven_day.resets_at "datetime"
    $out += "${sep}${white}7d${rst} ${sevenDayColor}${sevenDayPct}%${rst}"
    if ($sevenDayReset) { $out += " ${dim}@${sevenDayReset}${rst}" }

    # Extra usage
    if ($usageData.extra_usage.is_enabled -eq $true) {
        $extraPct = [math]::Round([double]$usageData.extra_usage.utilization)
        $extraUsed  = "{0:F2}" -f ($usageData.extra_usage.used_credits / 100)
        $extraLimit = "{0:F2}" -f ($usageData.extra_usage.monthly_limit / 100)
        if ($extraUsed -and $extraLimit) {
            $extraColor = Get-UsageColor $extraPct
            $out += "${sep}${white}extra${rst} ${extraColor}`$${extraUsed}/`$${extraLimit}${rst}"
        } else {
            $out += "${sep}${white}extra${rst} ${green}enabled${rst}"
        }
    }
} else {
    if (-not $effectiveBuiltin -and $needsRefresh) {
        # Fetch usage from API in background
        $token = Get-OAuthToken
        if ($token) {
            # Touch cache file as stampede lock
            try { "" | Set-Content $cacheFile -NoNewline } catch {}
            Start-Job -ScriptBlock {
                param($token, $cacheFile)
                try {
                    $headers = @{
                        "Accept"         = "application/json"
                        "Content-Type"   = "application/json"
                        "Authorization"  = "Bearer $token"
                        "anthropic-beta" = "oauth-2025-04-20"
                        "User-Agent"     = "claude-code/2.1.34"
                    }
                    $response = Invoke-RestMethod -Uri "https://api.anthropic.com/api/oauth/usage" `
                        -Headers $headers -TimeoutSec 10 -ErrorAction Stop
                    if ($response.five_hour) {
                        $response | ConvertTo-Json -Depth 10 | Set-Content $cacheFile -NoNewline
                    }
                } catch {}
            } -ArgumentList $token, $cacheFile | Out-Null
        }
    }
    $out += "${sep}${white}5h${rst} ${dim}-${rst}"
    $out += "${sep}${white}7d${rst} ${dim}-${rst}"
}

# ===== Update check (cached, 24h TTL) =====
$versionCacheFile = Join-Path $cacheDir "statusline-version-cache.json"
$versionCacheMaxAge = 86400

$versionNeedsRefresh = $true
$versionData = $null

if ((Test-Path $versionCacheFile) -and ((Get-Item $versionCacheFile).Length -gt 0)) {
    $vcMtime = (Get-Item $versionCacheFile).LastWriteTime
    $vcAge = ((Get-Date) - $vcMtime).TotalSeconds
    if ($vcAge -lt $versionCacheMaxAge) {
        $versionNeedsRefresh = $false
    }
    try {
        $versionData = Get-Content $versionCacheFile -Raw | ConvertFrom-Json
    } catch {}
}

if ($versionNeedsRefresh) {
    Start-Job -ScriptBlock {
        param($versionCacheFile)
        try {
            $headers = @{ "Accept" = "application/vnd.github+json" }
            $response = Invoke-RestMethod -Uri "https://api.github.com/repos/haukurk/claude-status-line/releases/latest" `
                -Headers $headers -TimeoutSec 5 -ErrorAction Stop
            if ($response.tag_name) {
                $response | ConvertTo-Json -Depth 10 | Set-Content $versionCacheFile -NoNewline
            }
        } catch {}
    } -ArgumentList $versionCacheFile | Out-Null
}

$updateLine = ""
if ($versionData -and $versionData.tag_name) {
    if (Version-GreaterThan $versionData.tag_name $VERSION) {
        $tag = $versionData.tag_name
        $updateLine = "`n${dim}Update available: ${tag} -> https://github.com/haukurk/claude-status-line${rst}"
    }
}

# Output
Write-Host "${out}${updateLine}" -NoNewline

exit 0
