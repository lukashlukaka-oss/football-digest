# Shared helpers for the Telegram scripts. ASCII-only on purpose:
# Windows PowerShell 5.1 misreads non-ASCII in .ps1 files without a BOM.

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$ProjectRoot = Split-Path -Parent $PSScriptRoot
$EnvFile = Join-Path $ProjectRoot '.env'
$Utf8NoBom = New-Object System.Text.UTF8Encoding $false

function Read-DotEnv {
    $values = @{}
    if (Test-Path $EnvFile) {
        foreach ($line in [IO.File]::ReadAllLines($EnvFile, [Text.Encoding]::UTF8)) {
            $l = $line.Trim().TrimStart([char]0xFEFF)
            if ($l -eq '' -or $l.StartsWith('#') -or -not $l.Contains('=')) { continue }
            $i = $l.IndexOf('=')
            $values[$l.Substring(0, $i).Trim()] = $l.Substring($i + 1).Trim().Trim('"')
        }
    }
    return $values
}

# Environment variables (GitHub Secrets) win over .env
function Get-Setting([string]$name) {
    $v = [Environment]::GetEnvironmentVariable($name)
    if ([string]::IsNullOrWhiteSpace($v)) { $v = (Read-DotEnv)[$name] }
    return $v
}

function Set-DotEnvValue([string]$name, [string]$value) {
    $lines = New-Object System.Collections.Generic.List[string]
    $found = $false
    if (Test-Path $EnvFile) {
        foreach ($line in [IO.File]::ReadAllLines($EnvFile, [Text.Encoding]::UTF8)) {
            if ($line.TrimStart([char]0xFEFF).StartsWith("$name=")) { $lines.Add("$name=$value"); $found = $true }
            else { $lines.Add($line.TrimStart([char]0xFEFF)) }
        }
    }
    if (-not $found) { $lines.Add("$name=$value") }
    [IO.File]::WriteAllLines($EnvFile, $lines, $Utf8NoBom)
}

function Get-BotToken {
    $t = Get-Setting 'TELEGRAM_BOT_TOKEN'
    if ([string]::IsNullOrWhiteSpace($t)) {
        throw 'TELEGRAM_BOT_TOKEN is empty. Paste the bot token into the .env file (or GitHub Secrets).'
    }
    return $t
}

# Uploads files with multipart/form-data (works in PowerShell 5.1 and 7).
# $fields: hashtable of text fields; $files: hashtable name -> local file path.
function Invoke-TelegramUpload([string]$method, [hashtable]$fields, [hashtable]$files) {
    $token = Get-BotToken
    $uri = "https://api.telegram.org/bot$token/$method"
    $boundary = '----fd' + [guid]::NewGuid().ToString('N')
    $ms = New-Object System.IO.MemoryStream
    $write = { param([string]$s) $b = [Text.Encoding]::UTF8.GetBytes($s); $ms.Write($b, 0, $b.Length) }
    foreach ($k in $fields.Keys) {
        & $write ("--$boundary`r`nContent-Disposition: form-data; name=`"$k`"`r`n`r`n" + $fields[$k] + "`r`n")
    }
    foreach ($k in $files.Keys) {
        $path = $files[$k]
        $ext = [IO.Path]::GetExtension($path).ToLower()
        $ctype = switch ($ext) { '.png' { 'image/png' } '.webp' { 'image/webp' } default { 'image/jpeg' } }
        & $write ("--$boundary`r`nContent-Disposition: form-data; name=`"$k`"; filename=`"$k$ext`"`r`nContent-Type: $ctype`r`n`r`n")
        $bytes = [IO.File]::ReadAllBytes($path)
        $ms.Write($bytes, 0, $bytes.Length)
        & $write "`r`n"
    }
    & $write "--$boundary--`r`n"
    try {
        return Invoke-RestMethod -Uri $uri -Method Post -Body $ms.ToArray() -ContentType "multipart/form-data; boundary=$boundary"
    } catch {
        $detail = $_.ErrorDetails.Message
        if (-not $detail) { $detail = $_.Exception.Message }
        throw ("Telegram API error in ${method}: " + $detail.Replace($token, '***'))
    }
}

# Calls the Bot API. Never prints the URL, because it contains the token.
function Invoke-TelegramApi([string]$method, $body = $null) {
    $token = Get-BotToken
    $uri = "https://api.telegram.org/bot$token/$method"
    try {
        if ($null -eq $body) {
            return Invoke-RestMethod -Uri $uri -Method Get
        }
        $json = $body | ConvertTo-Json -Depth 10 -Compress
        $bytes = [Text.Encoding]::UTF8.GetBytes($json)
        return Invoke-RestMethod -Uri $uri -Method Post -Body $bytes -ContentType 'application/json; charset=utf-8'
    } catch {
        $detail = $_.ErrorDetails.Message
        if (-not $detail) { $detail = $_.Exception.Message }
        $detail = $detail.Replace($token, '***')
        throw "Telegram API error in ${method}: $detail"
    }
}
