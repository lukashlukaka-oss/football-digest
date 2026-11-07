# Uploads the project to GitHub through the REST API (no git needed).
# Needs in .env:  GITHUB_TOKEN=<fine-grained token>   GITHUB_REPO=<owner>/<repo>
# Never uploads .env or .claude. Only changed files are sent.
# Usage: powershell -ExecutionPolicy Bypass -File scripts\github-upload.ps1 [-DryRun] [-Only <path> ...]
param(
    [switch]$DryRun,
    [string[]]$Only
)
. (Join-Path $PSScriptRoot 'tg-common.ps1')

$token = Get-Setting 'GITHUB_TOKEN'
$repo = Get-Setting 'GITHUB_REPO'
if ([string]::IsNullOrWhiteSpace($token)) { throw 'GITHUB_TOKEN is empty in .env' }
if ([string]::IsNullOrWhiteSpace($repo)) { throw 'GITHUB_REPO is empty in .env' }
$headers = @{ Authorization = "Bearer $token"; Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28'; 'User-Agent' = 'football-digest-uploader' }

function Invoke-GitHub([string]$method, [string]$path, $body = $null) {
    $uri = if ($path) { "https://api.github.com/repos/$repo/$path" } else { "https://api.github.com/repos/$repo" }
    try {
        if ($null -eq $body) { return Invoke-RestMethod -Uri $uri -Method $method -Headers $headers }
        $bytes = [Text.Encoding]::UTF8.GetBytes(($body | ConvertTo-Json -Depth 5 -Compress))
        return Invoke-RestMethod -Uri $uri -Method $method -Headers $headers -Body $bytes -ContentType 'application/json; charset=utf-8'
    } catch {
        $code = $null
        if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
        if ($code -eq 404 -and $method -eq 'GET') { return $null }
        $detail = $_.ErrorDetails.Message; if (-not $detail) { $detail = $_.Exception.Message }
        throw ("GitHub API error ($code) on $method ${path}: " + $detail.Replace($token, '***'))
    }
}

# git blob sha1 of a file, to skip unchanged files
function Get-BlobSha([byte[]]$bytes) {
    $header = [Text.Encoding]::ASCII.GetBytes("blob $($bytes.Length)`0")
    $all = New-Object byte[] ($header.Length + $bytes.Length)
    [Array]::Copy($header, $all, $header.Length); [Array]::Copy($bytes, 0, $all, $header.Length, $bytes.Length)
    $sha = [Security.Cryptography.SHA1]::Create().ComputeHash($all)
    return -join ($sha | ForEach-Object { $_.ToString('x2') })
}

$me = Invoke-GitHub 'GET' ''
if (-not $me) { throw "Repository $repo not found or the token has no access to it." }
Write-Output "Repository: $($me.full_name) (private=$($me.private))"

$files = Get-ChildItem -Path $ProjectRoot -Recurse -File -Force | Where-Object {
    $rel = $_.FullName.Substring($ProjectRoot.Length + 1)
    -not ($rel -eq '.env' -or $rel -like '.claude*' -or $rel -like '.git\*' -or $rel -like '*.tmp' -or $rel -like 'sources\*')
}
if ($Only) { $Only = @($Only | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim().Replace('\', '/') }) }
# state first: the cloud must see "already sent" before it sees a new digest
$files = @($files | Sort-Object { if ($_.FullName -like '*\state\*') { 0 } else { 1 } }, FullName)
# выпуски, картинки, страницу и отметки пишет облако — с компьютера их загружаем только по явному -Only
if (-not $Only) {
    $files = @($files | Where-Object {
        $r = $_.FullName.Substring($ProjectRoot.Length + 1)
        -not ($r -like 'digests\*' -or $r -eq 'index.html' -or $r -like 'state\*' -or $r -eq 'data\players-ru.json')
    })
}
if ($Only) { $files = $files | Where-Object { $rel = $_.FullName.Substring($ProjectRoot.Length + 1).Replace('\', '/'); $Only -contains $rel } }

$n = 0
foreach ($f in $files) {
    $rel = $f.FullName.Substring($ProjectRoot.Length + 1).Replace('\', '/')
    $bytes = [IO.File]::ReadAllBytes($f.FullName)
    $encPath = ($rel -split '/' | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'
    $existing = Invoke-GitHub 'GET' "contents/$encPath"
    $localSha = Get-BlobSha $bytes
    if ($existing -and $existing.sha -eq $localSha) { continue }
    if ($DryRun) { Write-Output "WOULD UPLOAD $rel"; continue }
    $body = @{ message = "upload $rel"; content = [Convert]::ToBase64String($bytes) }
    if ($existing) { $body.sha = $existing.sha }
    $null = Invoke-GitHub 'PUT' "contents/$encPath" $body
    Write-Output "UPLOADED $rel"
    $n++
}
Write-Output "Done: $n file(s) uploaded."
