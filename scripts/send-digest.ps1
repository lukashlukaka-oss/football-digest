# Sends the latest digest (digests/YYYY-MM-DD.md) to Telegram as a news feed:
#  - every news item that has a picture becomes its own post: photo + text under it;
#  - everything else goes as normal text messages, in the original order.
# Pictures are uploaded by the bot itself (no links to other channels).
# Usage:
#   powershell -ExecutionPolicy Bypass -File scripts\send-digest.ps1           -> send latest
#   powershell -ExecutionPolicy Bypass -File scripts\send-digest.ps1 -DryRun   -> only show what would be sent
#   ... -File digests\2026-11-05.md                                            -> send a specific file
param(
    [string]$File,
    [switch]$DryRun,
    [string]$PreviewOut,
    [switch]$OnlyIfNew   # for the cloud: send only today's (MSK) digest, and only once
)
. (Join-Path $PSScriptRoot 'tg-common.ps1')
$SentFile = Join-Path (Join-Path $ProjectRoot 'state') 'digest-sent.txt'

$MaxText = 4000      # Telegram text limit is 4096 visible chars; keep a margin
$MaxCaption = 1000   # Telegram photo caption limit is 1024 visible chars
$Ball = [char]::ConvertFromUtf32(0x26BD)
$Bullet = [string][char]0x2022

function Escape-Html([string]$s) { $s.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;') }

# Telegram counts limits on visible text (after HTML tags are parsed), not on raw HTML.
function Get-VisibleLength([string]$html) {
    $t = [regex]::Replace($html, '<[^>]+>', '')
    return ([System.Net.WebUtility]::HtmlDecode($t)).Length
}

# Inline markdown -> Telegram HTML: [text](url), **bold**, _italic_
function Convert-Inline([string]$text) {
    $links = New-Object System.Collections.Generic.List[string]
    $text = [regex]::Replace($text, '\[([^\]]+)\]\(([^)\s]+)\)', {
        param($m)
        $links.Add('<a href="' + (Escape-Html $m.Groups[2].Value).Replace('"', '&quot;') + '">' + (Escape-Html $m.Groups[1].Value) + '</a>')
        return "@@L$($links.Count - 1)@@"
    })
    $text = Escape-Html $text
    $text = [regex]::Replace($text, '\*\*(.+?)\*\*', '<b>$1</b>')
    $text = [regex]::Replace($text, '(?<![\w@])_(.+?)_(?![\w@])', '<i>$1</i>')
    $text = [regex]::Replace($text, '@@L(\d+)@@', { param($m) $links[[int]$m.Groups[1].Value] })
    return $text
}

# Markdown -> list of blocks: heading / item / para. A picture line attaches to the item above it.
function Get-Blocks([string[]]$lines) {
    $blocks = New-Object System.Collections.Generic.List[object]
    foreach ($raw in $lines) {
        $line = $raw.TrimEnd()
        if ($line -eq '') { continue }
        if ($line -match '^\s*!\[([^\]]*)\]\(([^)\s]+)\)\s*$') {
            $last = $null
            for ($j = $blocks.Count - 1; $j -ge 0; $j--) { if ($blocks[$j].Type -eq 'item') { $last = $blocks[$j]; break } }
            if ($last -and -not $last.Image) { $last.Image = $Matches[2] }
            continue
        }
        if ($line -match '^#\s+(.+)$') {
            $blocks.Add([pscustomobject]@{ Type = 'heading'; Html = "$Ball <b>" + (Convert-Inline $Matches[1]) + '</b>'; Image = $null })
        } elseif ($line -match '^#{2,}\s+(.+)$') {
            $blocks.Add([pscustomobject]@{ Type = 'heading'; Html = '<b>' + (Convert-Inline $Matches[1]) + '</b>'; Image = $null })
        } elseif ($line -match '^\s*[-*]\s+(.+)$') {
            $blocks.Add([pscustomobject]@{ Type = 'item'; Html = "$Bullet " + (Convert-Inline $Matches[1]); Image = $null })
        } else {
            $blocks.Add([pscustomobject]@{ Type = 'para'; Html = (Convert-Inline $line); Image = $null })
        }
    }
    return , $blocks
}

# Split long text into messages <= MaxText visible chars, at paragraph, then line boundaries.
function Split-Text([string]$text) {
    $parts = New-Object System.Collections.Generic.List[string]
    $current = ''
    foreach ($block in ($text -split "`n`n")) {
        $pieces = @($block)
        if ((Get-VisibleLength $block) -gt $MaxText) { $pieces = $block -split "`n" }
        foreach ($p in $pieces) {
            while ((Get-VisibleLength $p) -gt $MaxText) {
                if ($current) { $parts.Add($current); $current = '' }
                $parts.Add($p.Substring(0, $MaxText)); $p = $p.Substring($MaxText)
            }
            $sep = if ($current) { "`n`n" } else { '' }
            if ((Get-VisibleLength ($current + $sep + $p)) -gt $MaxText) { $parts.Add($current); $current = $p }
            else { $current = $current + $sep + $p }
        }
    }
    if ($current) { $parts.Add($current) }
    return , $parts
}

# --- pick the digest file ---
if (-not $File) {
    $latest = Get-ChildItem (Join-Path $ProjectRoot 'digests') -Filter '????-??-??.md' | Sort-Object Name | Select-Object -Last 1
    if (-not $latest) { throw 'No digest files found in digests/.' }
    $File = $latest.FullName
} elseif (-not [IO.Path]::IsPathRooted($File)) {
    $File = Join-Path $ProjectRoot $File
}
if ($OnlyIfNew) {
    $todayMsk = [DateTime]::UtcNow.AddHours(3).ToString('yyyy-MM-dd')
    $name = [IO.Path]::GetFileNameWithoutExtension($File)
    $already = if (Test-Path $SentFile) { ([IO.File]::ReadAllText($SentFile)).Trim() } else { '' }
    if ($name -ne $todayMsk) { Write-Output "NOT_TODAY: latest digest is $name, today is $todayMsk - nothing to send"; exit 0 }
    if ($already -eq $name) { Write-Output "ALREADY_SENT: $name"; exit 0 }
}
$mdDir = Split-Path -Parent $File
$blocks = Get-Blocks ([IO.File]::ReadAllLines($File, [Text.Encoding]::UTF8))

# --- build the feed: list of posts {Kind=text|photo, Html, Photo} ---
$posts = New-Object System.Collections.Generic.List[object]
$buffer = New-Object System.Collections.Generic.List[string]    # news items waiting to go as text
$pending = New-Object System.Collections.Generic.List[string]   # headings waiting for their first item

function Add-Line([string]$html, [bool]$isHeading) {
    if ($isHeading) { $pending.Add($html); return }
    if ($pending.Count -gt 0) {
        if ($buffer.Count -gt 0) { $buffer.Add('') }   # blank line before a new section
        $buffer.AddRange($pending); $pending.Clear()
    }
    $buffer.Add($html)
}
function Flush-Text {
    if ($buffer.Count -eq 0) { return }
    $text = ($buffer -join "`n").Trim()
    foreach ($part in (Split-Text $text)) { $posts.Add([pscustomobject]@{ Kind = 'text'; Html = $part; Photo = $null }) }
    $buffer.Clear()
}
function Take-Pending {
    $p = ($pending -join "`n`n").Trim(); $pending.Clear(); return $p
}

foreach ($b in $blocks) {
    $photoPath = $null
    if ($b.Type -eq 'item' -and $b.Image) {
        $src = $b.Image
        try {
            if ($src -match '^https?://') {
                $photoPath = Join-Path ([IO.Path]::GetTempPath()) ("fd-" + [guid]::NewGuid().ToString('N') + '.jpg')
                Invoke-WebRequest -Uri $src -UseBasicParsing -TimeoutSec 30 -OutFile $photoPath
            } else {
                $photoPath = Join-Path $mdDir $src
            }
            if (-not (Test-Path $photoPath) -or (Get-Item $photoPath).Length -eq 0) { $photoPath = $null }
        } catch { $photoPath = $null }
        if (-not $photoPath) { Write-Output "SKIP picture (not found): $src" }
    }

    if (-not $photoPath) {
        Add-Line $b.Html ($b.Type -ne 'item')   # title, period line and section names may ride on a photo caption
        continue
    }

    # photo post: headings waiting in the buffer (e.g. the digest title, a section name) go into the caption
    Flush-Text
    $prefix = Take-Pending

    $caption = if ($prefix) { "$prefix`n`n$($b.Html)" } else { $b.Html }
    if ((Get-VisibleLength $caption) -gt $MaxCaption) {
        if ($prefix) { $posts.Add([pscustomobject]@{ Kind = 'text'; Html = $prefix; Photo = $null }) }
        $caption = $b.Html
    }
    if ((Get-VisibleLength $caption) -gt $MaxCaption) {
        # item too long for a caption: photo first, the text right after it
        $posts.Add([pscustomobject]@{ Kind = 'photo'; Html = ''; Photo = $photoPath })
        $posts.Add([pscustomobject]@{ Kind = 'text'; Html = $b.Html; Photo = $null })
    } else {
        $posts.Add([pscustomobject]@{ Kind = 'photo'; Html = $caption; Photo = $photoPath })
    }
}
if ($pending.Count -gt 0) { $buffer.Add(''); $buffer.AddRange($pending); $pending.Clear() }
Flush-Text

# --- dry run ---
if ($DryRun) {
    $n = 0
    $preview = ($posts | ForEach-Object {
        $n++
        $head = "===== post $n / $($posts.Count): $($_.Kind), $(Get-VisibleLength $_.Html) visible chars"
        if ($_.Photo) { $head += ", photo: $(Split-Path -Leaf $_.Photo)" }
        "$head =====`n$($_.Html)"
    }) -join "`n`n"
    if ($PreviewOut) { [IO.File]::WriteAllText($PreviewOut, $preview, $Utf8NoBom); Write-Output "Preview written to $PreviewOut" }
    else { Write-Output $preview }
    exit 0
}

# --- send ---
$chatId = Get-Setting 'TELEGRAM_CHAT_ID'
if ([string]::IsNullOrWhiteSpace($chatId)) { throw 'TELEGRAM_CHAT_ID is empty. Run scripts\get-chat-id.ps1 first.' }

$i = 0
foreach ($p in $posts) {
    $i++
    if ($p.Kind -eq 'photo') {
        $fields = @{ chat_id = $chatId; parse_mode = 'HTML' }
        if ($p.Html) { $fields.caption = $p.Html }
        try {
            $null = Invoke-TelegramUpload 'sendPhoto' $fields @{ photo = $p.Photo }
            Write-Output "SENT post $i / $($posts.Count): photo"
        } catch {
            # picture failed: still deliver the news as text
            Write-Output "PHOTO FAILED, sending text only: $($_.Exception.Message)"
            if ($p.Html) {
                $null = Invoke-TelegramApi 'sendMessage' @{ chat_id = $chatId; text = $p.Html; parse_mode = 'HTML'; link_preview_options = @{ is_disabled = $true } }
            }
        }
    } else {
        $null = Invoke-TelegramApi 'sendMessage' @{ chat_id = $chatId; text = $p.Html; parse_mode = 'HTML'; link_preview_options = @{ is_disabled = $true } }
        Write-Output "SENT post $i / $($posts.Count): text"
    }
    Start-Sleep -Milliseconds 700
}

# remember what was sent (used by -OnlyIfNew)
$stDir = Split-Path -Parent $SentFile
if (-not (Test-Path $stDir)) { New-Item -ItemType Directory -Force $stDir | Out-Null }
[IO.File]::WriteAllText($SentFile, [IO.Path]::GetFileNameWithoutExtension($File), $Utf8NoBom)
