# Diagnostics for the GitHub key (never prints the key itself).
. (Join-Path $PSScriptRoot 'tg-common.ps1')
$token = Get-Setting 'GITHUB_TOKEN'
$repo = Get-Setting 'GITHUB_REPO'
Write-Output ("key: length={0}, starts with github_pat_={1}, has spaces={2}" -f $token.Length, $token.StartsWith('github_pat_'), ($token -match '\s'))
$h = @{ Authorization = "Bearer $token"; Accept = 'application/vnd.github+json'; 'User-Agent' = 'football-digest' }
function Try-Get([string]$url, $headers) {
    try { $r = Invoke-WebRequest -Uri $url -Headers $headers -UseBasicParsing; return "$($r.StatusCode)" }
    catch { if ($_.Exception.Response) { return "$([int]$_.Exception.Response.StatusCode)" } else { return "ERR $($_.Exception.Message)" } }
}
Write-Output ("GET /user with key: " + (Try-Get 'https://api.github.com/user' $h))
Write-Output ("GET repo without key (is it public?): " + (Try-Get "https://api.github.com/repos/$repo" @{ 'User-Agent' = 'football-digest' }))
Write-Output ("GET repo with key: " + (Try-Get "https://api.github.com/repos/$repo" $h))
try {
    $list = Invoke-RestMethod -Uri 'https://api.github.com/users/lukashlukaka-oss/repos' -Headers @{ 'User-Agent' = 'football-digest' }
    Write-Output ("public repos of the account: " + (($list | ForEach-Object { $_.name }) -join ', '))
} catch { Write-Output "could not list repos" }
