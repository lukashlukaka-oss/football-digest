# Diagnostics: which bot the token belongs to, webhook state, pending updates.
. (Join-Path $PSScriptRoot 'tg-common.ps1')

$me = Invoke-TelegramApi 'getMe'
Write-Output ("bot: @{0} ({1})" -f $me.result.username, $me.result.first_name)

$wh = Invoke-TelegramApi 'getWebhookInfo'
Write-Output ("webhook set: {0}; pending updates: {1}" -f (-not [string]::IsNullOrEmpty($wh.result.url)), $wh.result.pending_update_count)

$u = Invoke-TelegramApi 'getUpdates'
Write-Output ("updates via getUpdates: {0}" -f @($u.result).Count)
foreach ($x in $u.result) {
    $keys = ($x.PSObject.Properties.Name | Where-Object { $_ -ne 'update_id' }) -join ','
    Write-Output (" - update {0}: {1}" -f $x.update_id, $keys)
}
