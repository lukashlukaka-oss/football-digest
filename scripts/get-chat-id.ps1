# Finds your chat_id from the messages people sent to the bot (getUpdates)
# and saves it to .env when there is exactly one private chat.
. (Join-Path $PSScriptRoot 'tg-common.ps1')

$resp = Invoke-TelegramApi 'getUpdates'
$chats = @{}
foreach ($u in $resp.result) {
    $m = $u.message
    if (-not $m) { $m = $u.edited_message }
    if (-not $m) { continue }
    $c = $m.chat
    $chats["$($c.id)"] = $c
}

if ($chats.Count -eq 0) {
    Write-Output 'NO_CHATS: the bot has no recent messages. Send /start to the bot again and rerun.'
    exit 2
}

foreach ($c in $chats.Values) {
    Write-Output ("chat_id={0} type={1} name={2} username={3}" -f $c.id, $c.type, $c.first_name, $c.username)
}

$private = @($chats.Values | Where-Object { $_.type -eq 'private' })
if ($private.Count -eq 1) {
    Set-DotEnvValue 'TELEGRAM_CHAT_ID' "$($private[0].id)"
    Write-Output "SAVED: TELEGRAM_CHAT_ID=$($private[0].id) written to .env"
} else {
    Write-Output 'NOT_SAVED: more than one private chat found, pick one manually.'
}
