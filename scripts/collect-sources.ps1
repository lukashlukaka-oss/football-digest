# Собирает материалы для дайджеста (запускается в GitHub Actions, где открыт весь интернет):
#  - посты Telegram-каналов за последние 48 часов: текст, ссылка, фото
#  - матчи ESPN: результаты за 2 дня и расписание на 7 дней вперёд
# Результат: папка sources/ (posts.md, matches.md, img/). Облачный Claude читает её и пишет выпуск.
param(
    [int]$Hours = 48,
    [int]$MaxImages = 45
)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124 Safari/537.36'
$Root = Split-Path -Parent $PSScriptRoot
$Out = Join-Path $Root 'sources'
$ImgDir = Join-Path $Out 'img'
if (Test-Path $Out) { Remove-Item -Recurse -Force $Out }
New-Item -ItemType Directory -Force $ImgDir | Out-Null
$Utf8 = New-Object System.Text.UTF8Encoding $false
$nowUtc = [DateTime]::UtcNow
$since = $nowUtc.AddHours(-$Hours)
$Msk = [TimeSpan]::FromHours(3)

$Channels = @('myachPRO', 'myachrus', 'okkosport', 'FabrizioRomanoTG', 'fczenit', 'sportexpress', 'sportsru', 'championat')
# фото скачиваем только у постов на наши темы
$Topics = 'реал|зенит|роналду|криштиану|куртуа|мбапп|сафонов|батраков|беллингем|холанд|глушенков|аршавин|лига чемпионов|лч|рпл|ла лиг|сборн|real madrid|zenit|ronaldo|courtois|mbapp|safonov|batrakov|bellingham|haaland|glushenkov|here we go'

function Get-Text([string]$html) {
    $t = $html -replace '<br\s*/?>', "`n"
    $t = [regex]::Replace($t, '<[^>]+>', '')
    return ([System.Net.WebUtility]::HtmlDecode($t)).Trim()
}

# ---------- Telegram ----------
$posts = New-Object System.Collections.Generic.List[object]
foreach ($ch in $Channels) {
    $before = $null
    for ($page = 0; $page -lt 4; $page++) {
        $url = "https://t.me/s/$ch" + $(if ($before) { "?before=$before" } else { '' })
        try { $html = (Invoke-WebRequest -Uri $url -UseBasicParsing -UserAgent $UA -TimeoutSec 30).Content } catch { Write-Output "WARN $ch page ${page}: $($_.Exception.Message)"; break }
        $blocks = $html -split 'tgme_widget_message_wrap' | Select-Object -Skip 1
        if (-not $blocks) { break }
        $minId = $null; $oldest = $nowUtc
        foreach ($b in $blocks) {
            $postRef = [regex]::Match($b, 'data-post="([^"/]+)/(\d+)"')
            if (-not $postRef.Success) { continue }
            $id = [int]$postRef.Groups[2].Value
            if ($null -eq $minId -or $id -lt $minId) { $minId = $id }
            $dt = [regex]::Match($b, 'datetime="([^"]+)"').Groups[1].Value
            if (-not $dt) { continue }
            $when = [DateTimeOffset]::Parse($dt).UtcDateTime
            if ($when -lt $oldest) { $oldest = $when }
            if ($when -lt $since) { continue }
            $text = Get-Text ([regex]::Match($b, 'tgme_widget_message_text[^>]*>(.*?)</div>', 'Singleline').Groups[1].Value)
            $photo = [regex]::Match($b, "tgme_widget_message_(?:photo_wrap|video_thumb)[^>]*background-image:url\('([^']+)'\)").Groups[1].Value
            $posts.Add([pscustomobject]@{ Channel = $ch; Id = $id; When = $when; Text = $text; Photo = $photo; File = '' })
        }
        if ($oldest -lt $since -or -not $minId) { break }
        $before = $minId
    }
}
# без дублей, свежие первыми
$posts = @($posts | Sort-Object Channel, Id -Unique | Sort-Object When -Descending)

# фото к тематическим постам
$n = 0
foreach ($p in $posts) {
    if ($n -ge $MaxImages) { break }
    if (-not $p.Photo) { continue }
    if ($p.Text.ToLower() -notmatch $Topics) { continue }
    $name = "$($p.Channel)-$($p.Id).jpg"
    $file = Join-Path $ImgDir $name
    try {
        Invoke-WebRequest -Uri $p.Photo -UseBasicParsing -UserAgent $UA -TimeoutSec 30 -OutFile $file
        if ((Get-Item $file).Length -lt 5000) { Remove-Item $file; continue }
        $p.File = "img/$name"; $n++
    } catch { }
}

$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine("# Посты Telegram-каналов за последние $Hours ч (собрано $($nowUtc.Add($Msk).ToString('yyyy-MM-dd HH:mm')) МСК)")
[void]$sb.AppendLine("Каналы: $($Channels -join ', '). Фото есть только у тематических постов; путь указан относительно sources/.")
[void]$sb.AppendLine()
foreach ($p in $posts) {
    $t = $p.When.Add($Msk).ToString('yyyy-MM-dd HH:mm')
    [void]$sb.AppendLine("## $t МСК · @$($p.Channel) · https://t.me/$($p.Channel)/$($p.Id)")
    if ($p.File) { [void]$sb.AppendLine("ФОТО: $($p.File)") }
    [void]$sb.AppendLine($(if ($p.Text) { $p.Text } else { '(без текста)' }))
    [void]$sb.AppendLine()
}
[IO.File]::WriteAllText((Join-Path $Out 'posts.md'), $sb.ToString(), $Utf8)

# ---------- ESPN ----------
$Leagues = [ordered]@{
    'esp.1' = 'Ла Лига'; 'uefa.champions' = 'Лига чемпионов'; 'rus.1' = 'РПЛ'; 'uefa.nations' = 'Лига наций'
    'esp.copa_del_rey' = 'Кубок Испании'; 'fifa.world' = 'Чемпионат мира'; 'uefa.euro' = 'Евро'
    'fifa.worldq.uefa' = 'Отбор ЧМ (Европа)'; 'eng.1' = 'АПЛ'; 'fra.1' = 'Лига 1'; 'tur.1' = 'Чемпионат Турции'; 'ksa.1' = 'Чемпионат Саудовской Аравии'
}
# лиги, где интересны все матчи; в остальных — только с командами наших игроков
$WatchAll = @('esp.1', 'uefa.champions', 'rus.1', 'uefa.nations', 'fifa.world', 'uefa.euro', 'fifa.worldq.uefa')
$PlayerTeams = 'Real Madrid|Zenit|Paris Saint-Germain|Galatasaray|Manchester City|Al Nassr|Portugal|Russia|Belgium|France|England|Norway'

$matches = New-Object System.Collections.Generic.List[object]
foreach ($lg in $Leagues.Keys) {
    for ($d = -2; $d -le 7; $d++) {
        $date = $nowUtc.AddDays($d).ToString('yyyyMMdd')
        try { $board = Invoke-RestMethod "https://site.api.espn.com/apis/site/v2/sports/soccer/$lg/scoreboard?dates=$date" -TimeoutSec 20 } catch { continue }
        foreach ($ev in $board.events) {
            $c = $ev.competitions[0]
            $h = $c.competitors | Where-Object homeAway -eq 'home' | Select-Object -First 1
            $a = $c.competitors | Where-Object homeAway -eq 'away' | Select-Object -First 1
            $names = "$($h.team.displayName) $($a.team.displayName)"
            if ($WatchAll -notcontains $lg -and $names -notmatch $PlayerTeams) { continue }
            $kick = [DateTimeOffset]::Parse($ev.date).UtcDateTime
            $state = $ev.status.type.state
            if ($state -eq 'pre' -and $kick -lt $nowUtc.AddHours(-3)) { continue }
            if ($state -ne 'pre' -and $kick -lt $nowUtc.AddHours(-$Hours)) { continue }
            $score = if ($state -eq 'pre') { '' } else { "$($h.score):$($a.score)" }
            $goals = @($c.details | Where-Object { $_.scoringPlay } | ForEach-Object {
                $who = if ($_.athletesInvolved) { $_.athletesInvolved[0].displayName } else { '?' }
                $tm = if ("$($_.team.id)" -eq "$($h.team.id)") { $h.team.displayName } else { $a.team.displayName }
                $x = if ($_.ownGoal) { ' (OG)' } elseif ($_.penaltyKick) { ' (pen)' } else { '' }
                "$($_.clock.displayValue) $who$x [$tm]"
            })
            $matches.Add([pscustomobject]@{
                Kick = $kick; League = $Leagues[$lg]; Home = $h.team.displayName; Away = $a.team.displayName
                Score = $score; Status = $ev.status.type.description; Goals = ($goals -join '; '); Id = $ev.id; Slug = $lg
            })
        }
    }
}
$matches = @($matches | Sort-Object Id -Unique | Sort-Object Kick)

$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine("# Матчи (ESPN), собрано $($nowUtc.Add($Msk).ToString('yyyy-MM-dd HH:mm')) МСК")
[void]$sb.AppendLine("Формат: дата время МСК | турнир | ХОЗЯЕВА — ГОСТИ | счёт | статус | голы. Названия команд и игроков — как в ESPN (по-английски), в выпуске пиши по-русски.")
[void]$sb.AppendLine()
[void]$sb.AppendLine('## Сыграно (последние 48 ч)')
foreach ($m in ($matches | Where-Object { $_.Score })) {
    [void]$sb.AppendLine(("{0} МСК | {1} | {2} — {3} | {4} | {5} | {6} | https://www.espn.com/soccer/match/_/gameId/{7}" -f $m.Kick.Add($Msk).ToString('yyyy-MM-dd HH:mm'), $m.League, $m.Home, $m.Away, $m.Score, $m.Status, $m.Goals, $m.Id))
}
[void]$sb.AppendLine()
[void]$sb.AppendLine('## Расписание (7 дней)')
foreach ($m in ($matches | Where-Object { -not $_.Score })) {
    [void]$sb.AppendLine(("{0} МСК | {1} | {2} — {3} | https://www.espn.com/soccer/match/_/gameId/{4}" -f $m.Kick.Add($Msk).ToString('yyyy-MM-dd HH:mm'), $m.League, $m.Home, $m.Away, $m.Id))
}
[IO.File]::WriteAllText((Join-Path $Out 'matches.md'), $sb.ToString(), $Utf8)

Write-Output ("DONE: {0} posts, {1} images, {2} matches" -f $posts.Count, $n, $matches.Count)
