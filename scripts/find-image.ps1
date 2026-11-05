# Finds a picture for a news link and (optionally) saves it into the project.
#  - Telegram post (t.me/<channel>/<id>): the post's own photo; channel avatars are ignored.
#  - Any other page: its og:image / twitter:image.
# Usage:
#   ... find-image.ps1 <url> [<url> ...]                    -> print picture URL(s)
#   ... find-image.ps1 -Out digests\img\2026-11-05-1.jpg <url> [<url> ...]
#        -> tries the links in order, saves the first picture found, prints the saved path
param(
    [string]$Out,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Urls
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124 Safari/537.36'
$ProjectRoot = Split-Path -Parent $PSScriptRoot

function Get-Html([string]$u) {
    (Invoke-WebRequest -Uri $u -UseBasicParsing -UserAgent $UA -TimeoutSec 20).Content
}

function Find-Image([string]$u) {
    if ($u -match '^https?://t\.me/(?:s/)?([A-Za-z0-9_]+)/(\d+)') {
        $html = Get-Html ("https://t.me/{0}/{1}?embed=1" -f $Matches[1], $Matches[2])
        $m = [regex]::Match($html, "tgme_widget_message_(?:photo_wrap|video_thumb)[^>]*background-image:url\('([^']+)'\)")
        if ($m.Success) { return $m.Groups[1].Value }
        return $null    # text-only post: its og:image is just the channel avatar
    }
    $html = Get-Html $u
    foreach ($p in @(
        '<meta[^>]+(?:property|name)=["''](?:og:image|twitter:image)["''][^>]*content=["'']([^"'']+)',
        '<meta[^>]+content=["'']([^"'']+)["''][^>]*(?:property|name)=["''](?:og:image|twitter:image)["'']')) {
        $m = [regex]::Match($html, $p)
        if ($m.Success) { return [System.Net.WebUtility]::HtmlDecode($m.Groups[1].Value) }
    }
    return $null
}

foreach ($u in $Urls) {
    try {
        $img = Find-Image $u
        if (-not $img) { continue }
        if (-not $Out) { Write-Output $img; continue }

        $target = if ([IO.Path]::IsPathRooted($Out)) { $Out } else { Join-Path $ProjectRoot $Out }
        $dir = Split-Path -Parent $target
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
        Invoke-WebRequest -Uri $img -UseBasicParsing -UserAgent $UA -TimeoutSec 30 -OutFile $target
        if ((Get-Item $target).Length -lt 5000) { Remove-Item $target; continue }   # too small: icon/avatar
        Write-Output $Out
        exit 0
    } catch {
        # unreachable page or picture: try the next link
    }
}
if ($Out) { Write-Output 'NO_IMAGE'; exit 3 }
