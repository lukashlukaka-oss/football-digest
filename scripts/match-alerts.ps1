# Оповещения о матчах Реала и Зенита в Telegram (данные — открытый ESPN, без ключей).
#  ⏰ за ~15 минут до начала — со стартовыми составами
#  🟢 матч начался
#  🏁 итоговый счёт и авторы голов
# Запускать каждые 5 минут. Что уже отправлено, помнит файл state/alerts.json.
# Проверка без отправки:  ... match-alerts.ps1 -DryRun -Now 2026-11-04T17:28Z -Dates 20261104
param(
    [switch]$DryRun,
    [string]$Now,      # подменить «сейчас» (UTC) для проверки
    [string]$Dates,    # подменить даты поиска, например 20261104
    [string]$TestLineup,
    [switch]$Watch,             # не завершаться, пока идёт/скоро начнётся матч (для облака)
    [int]$WatchMinutes = 330    # максимум работы в режиме слежения
)
. (Join-Path $PSScriptRoot 'tg-common.ps1')

$MyTeams = @{ '86' = 'Реал Мадрид'; '2533' = 'Зенит' }
$Favorites = 'Courtois|Mbapp|Bellingham|Safonov|Batrakov|Haaland|Glushenkov|Ronaldo'
$Leagues = [ordered]@{
    'esp.1' = 'Ла Лига'; 'uefa.champions' = 'Лига чемпионов'; 'rus.1' = 'РПЛ'
    'esp.copa_del_rey' = 'Кубок Испании'; 'esp.super_cup' = 'Суперкубок Испании'
    'rus.cup' = 'Кубок России'; 'fifa.cwc' = 'Клубный чемпионат мира'; 'club.friendly' = 'Товарищеский матч'
}
$TeamRu = @{
    'Real Madrid' = 'Реал Мадрид'; 'Zenit St Petersburg' = 'Зенит'
    'Barcelona' = 'Барселона'; 'Atlético Madrid' = 'Атлетико'; 'Atletico Madrid' = 'Атлетико'; 'Valencia' = 'Валенсия'
    'Sevilla' = 'Севилья'; 'Villarreal' = 'Вильярреал'; 'Real Betis' = 'Бетис'; 'Athletic Club' = 'Атлетик'
    'Real Sociedad' = 'Реал Сосьедад'; 'Girona' = 'Жирона'; 'Osasuna' = 'Осасуна'; 'Celta Vigo' = 'Сельта'
    'Getafe' = 'Хетафе'; 'Mallorca' = 'Мальорка'; 'Rayo Vallecano' = 'Райо Вальекано'; 'Alavés' = 'Алавес'
    'Espanyol' = 'Эспаньол'; 'Elche' = 'Эльче'; 'Levante' = 'Леванте'; 'Real Oviedo' = 'Овьедо'
    'Racing Santander' = 'Расинг'; 'Deportivo' = 'Депортиво'; 'Málaga' = 'Малага'; 'Leganés' = 'Леганес'
    'Spartak Moscow' = 'Спартак'; 'CSKA Moscow' = 'ЦСКА'; 'Lokomotiv Moscow' = 'Локомотив'; 'Dynamo Moscow' = 'Динамо'
    'FC Krasnodar' = 'Краснодар'; 'Krasnodar' = 'Краснодар'; 'Rubin Kazan' = 'Рубин'; 'Akhmat Grozny' = 'Ахмат'
    'Krylia Sovetov' = 'Крылья Советов'; 'Akron Tolyatti' = 'Акрон'; 'Gazovik Orenburg' = 'Оренбург'
    'Pari Nizhny Novgorod' = 'Пари НН'; 'Fakel Voronezh' = 'Факел'; 'Dynamo Makhachkala' = 'Динамо Махачкала'
    'FC Baltika Kaliningrad' = 'Балтика'; 'Sochi' = 'Сочи'; 'Rostov' = 'Ростов'
    'AEK Athens' = 'АЕК'; 'Liverpool' = 'Ливерпуль'; 'Manchester City' = 'Манчестер Сити'; 'Arsenal' = 'Арсенал'
    'Bayern Munich' = 'Бавария'; 'Paris Saint-Germain' = 'ПСЖ'; 'Juventus' = 'Ювентус'; 'Inter Milan' = 'Интер'
    'Internazionale' = 'Интер'; 'AC Milan' = 'Милан'; 'Chelsea' = 'Челси'; 'Borussia Dortmund' = 'Боруссия Д'
    'Galatasaray' = 'Галатасарай'; 'Napoli' = 'Наполи'; 'Benfica' = 'Бенфика'; 'FC Porto' = 'Порту'
}
$Msk = [TimeSpan]::FromHours(3)

function Ru([string]$name) { if ($TeamRu.ContainsKey($name)) { $TeamRu[$name] } else { $name } }
function Esc([string]$s) { $s.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;') }

function Update-Now {
    $script:nowUtc = if ($Now) { [DateTimeOffset]::Parse($Now).UtcDateTime } else { [DateTime]::UtcNow }
    $script:dateList = if ($Dates) { @($Dates -split ',') } else { @($nowUtc.AddDays(-1).ToString('yyyyMMdd'), $nowUtc.ToString('yyyyMMdd'), $nowUtc.AddDays(1).ToString('yyyyMMdd')) }
}
Update-Now

# --- что уже отправлено ---
$stateDir = Join-Path $ProjectRoot 'state'
$stateFile = Join-Path $stateDir 'alerts.json'
$sent = @{}
if (Test-Path $stateFile) {
    $obj = [IO.File]::ReadAllText($stateFile, [Text.Encoding]::UTF8) | ConvertFrom-Json
    foreach ($p in $obj.PSObject.Properties) { $sent[$p.Name] = $p.Value }
}

# --- русские имена игроков: словарь data/players-ru.json, иначе — транслитерация ---
$PlayerRu = @{}
$dictFile = Join-Path (Join-Path $ProjectRoot 'data') 'players-ru.json'
if (Test-Path $dictFile) {
    $d = [IO.File]::ReadAllText($dictFile, [Text.Encoding]::UTF8) | ConvertFrom-Json
    foreach ($p in $d.PSObject.Properties) { if (-not $p.Name.StartsWith('_')) { $PlayerRu[$p.Name] = $p.Value } }
}
$Translit = [ordered]@{
    'sch' = 'ш'; 'shch' = 'щ'; 'zh' = 'ж'; 'kh' = 'х'; 'ch' = 'ч'; 'sh' = 'ш'; 'ts' = 'ц'; 'yu' = 'ю'; 'ya' = 'я'
    'yo' = 'ё'; 'ph' = 'ф'; 'th' = 'т'; 'ck' = 'к'; 'qu' = 'к'; 'ou' = 'у'; 'ee' = 'и'; 'oo' = 'у'; 'ei' = 'ей'
    'a' = 'а'; 'b' = 'б'; 'c' = 'к'; 'd' = 'д'; 'e' = 'е'; 'f' = 'ф'; 'g' = 'г'; 'h' = 'х'; 'i' = 'и'; 'j' = 'х'
    'k' = 'к'; 'l' = 'л'; 'm' = 'м'; 'n' = 'н'; 'o' = 'о'; 'p' = 'п'; 'q' = 'к'; 'r' = 'р'; 's' = 'с'; 't' = 'т'
    'u' = 'у'; 'v' = 'в'; 'w' = 'в'; 'x' = 'кс'; 'y' = 'й'; 'z' = 'з'
}
function Remove-Accents([string]$s) {
    $n = $s.Normalize([Text.NormalizationForm]::FormD)
    -join ($n.ToCharArray() | Where-Object { [Globalization.CharUnicodeInfo]::GetUnicodeCategory($_) -ne 'NonSpacingMark' })
}
function PlayerName([string]$name) {
    if ($PlayerRu.ContainsKey($name)) { return $PlayerRu[$name] }
    $plain = (Remove-Accents $name).ToLower()
    $out = ''; $i = 0
    while ($i -lt $plain.Length) {
        $hit = $false
        foreach ($k in $Translit.Keys) {
            if ($plain.Length - $i -ge $k.Length -and $plain.Substring($i, $k.Length) -eq $k) { $out += $Translit[$k]; $i += $k.Length; $hit = $true; break }
        }
        if (-not $hit) { $out += $plain[$i]; $i++ }
    }
    $out = [regex]::Replace($out, '(?<=[бвгджзклмнпрстфхцчшщ])й', 'и')   # Aboubakary -> Абубакари
    # Заглавные буквы в начале слов
    return (($out -split ' ') | ForEach-Object { if ($_.Length) { $_.Substring(0, 1).ToUpper() + $_.Substring(1) } }) -join ' '
}
function Fav([string]$espnName, [string]$ru) { if ($espnName -match $Favorites) { "<b>$(Esc $ru)</b>" } else { Esc $ru } }

function Send-Alert([string]$key, [string]$html, [string]$photo) {
    if ($DryRun) {
        $p = if ($photo) { " + photo $photo" } else { '' }
        Write-Output "----- WOULD SEND [$key]$p -----`n$html`n"; $script:sent[$key] = 'dry'; return
    }
    $chat = Get-Setting 'TELEGRAM_CHAT_ID'
    $done = $false
    if ($photo -and (Get-VisibleLength $html) -le 1000) {
        try { $null = Invoke-TelegramUpload 'sendPhoto' @{ chat_id = $chat; caption = $html; parse_mode = 'HTML' } @{ photo = $photo }; $done = $true }
        catch { Write-Output "PHOTO FAILED, text only: $($_.Exception.Message)" }
    }
    if (-not $done) {
        $null = Invoke-TelegramApi 'sendMessage' @{ chat_id = $chat; text = $html; parse_mode = 'HTML'; link_preview_options = @{ is_disabled = $true } }
    }
    $script:sent[$key] = [DateTime]::UtcNow.ToString('o')
    Write-Output "SENT [$key]"
}
function Get-VisibleLength([string]$html) { ([System.Net.WebUtility]::HtmlDecode(([regex]::Replace($html, '<[^>]+>', '')))).Length }

# Стартовый состав ТОЛЬКО моей команды, по линиям, по-русски.
function Get-MyLineup([string]$league, [string]$eventId, [string]$myTeamId) {
    try {
        $s = Invoke-RestMethod "https://site.api.espn.com/apis/site/v2/sports/soccer/$league/summary?event=$eventId" -TimeoutSec 20
    } catch { return $null }
    $r = $s.rosters | Where-Object { "$($_.team.id)" -eq $myTeamId } | Select-Object -First 1
    if (-not $r) { return $null }
    $starters = @($r.roster | Where-Object { $_.starter })
    if ($starters.Count -lt 11) { return $null }
    $groups = [ordered]@{ 'gk' = @(); 'def' = @(); 'mid' = @(); 'fw' = @() }
    foreach ($p in $starters) {
        $pos = "$($p.position.abbreviation)".ToUpper()
        $g = if ($pos -eq 'G' -or $pos -eq 'GK') { 'gk' }
             elseif ($pos -match '^(CD|CB|LB|RB|LWB|RWB|SW|D)') { 'def' }
             elseif ($pos -match '^(F|CF|ST|LW|RW|SS)') { 'fw' }
             else { 'mid' }
        $groups[$g] += (Fav $p.athlete.displayName (PlayerName $p.athlete.displayName))
    }
    $team = Esc (Ru $r.team.displayName)
    $form = if ($r.formation) { " ($($r.formation))" } else { '' }
    $out = "📋 <b>Состав: $team</b>$form"
    if ($groups.gk.Count)  { $out += "`n🧤 " + ($groups.gk -join ', ') }
    if ($groups.def.Count) { $out += "`n🛡 " + ($groups.def -join ', ') }
    if ($groups.mid.Count) { $out += "`n⚙️ " + ($groups.mid -join ', ') }
    if ($groups.fw.Count)  { $out += "`n⚔️ " + ($groups.fw -join ', ') }
    return $out
}

# Картинка со стартовым составом из Telegram-канала (пост не раньше чем за 3 часа до матча).
$LineupChannels = @{
    '2533' = @(@{ ch = 'fczenit'; must = 'состав' })
    '86'   = @(@{ ch = 'myachPRO'; must = 'состав.*реал|реал.*состав' }, @{ ch = 'okkosport'; must = 'состав.*реал|реал.*состав' })
}
function Find-LineupPhoto([string]$myTeamId, [DateTime]$kickUtc) {
    foreach ($src in $LineupChannels[$myTeamId]) {
        try {
            $q = [uri]::EscapeDataString('состав')
            $h = (Invoke-WebRequest "https://t.me/s/$($src.ch)?q=$q" -UseBasicParsing -UserAgent 'Mozilla/5.0' -TimeoutSec 20).Content
        } catch { continue }
        $posts = $h -split 'tgme_widget_message_wrap' | Select-Object -Skip 1
        [array]::Reverse($posts)   # свежие первыми
        foreach ($b in $posts) {
            $t = [regex]::Match($b, 'datetime="([^"]+)"').Groups[1].Value
            if (-not $t) { continue }
            $postUtc = [DateTimeOffset]::Parse($t).UtcDateTime
            if ($postUtc -lt $kickUtc.AddHours(-3) -or $postUtc -gt $kickUtc.AddMinutes(30)) { continue }
            $txt = [System.Net.WebUtility]::HtmlDecode(([regex]::Replace([regex]::Match($b, 'tgme_widget_message_text[^>]*>(.*?)</div>', 'Singleline').Groups[1].Value, '<[^>]+>', ' '))).ToLower()
            if ($txt -notmatch $src.must) { continue }
            $img = [regex]::Match($b, "tgme_widget_message_photo_wrap[^>]*background-image:url\('([^']+)'\)").Groups[1].Value
            if (-not $img) { continue }
            $tmp = Join-Path ([IO.Path]::GetTempPath()) ("lineup-" + [guid]::NewGuid().ToString('N') + '.jpg')
            try { Invoke-WebRequest $img -UseBasicParsing -UserAgent 'Mozilla/5.0' -TimeoutSec 30 -OutFile $tmp; return $tmp } catch { }
        }
    }
    return $null
}

if ($TestLineup) {   # проверка составов: -TestLineup uefa.champions:401915383:86[:2026-11-04T17:45Z]
    $parts = $TestLineup -split ':', 4
    Write-Output (Get-MyLineup $parts[0] $parts[1] $parts[2])
    if ($parts.Count -ge 4) { Write-Output ("photo: " + (Find-LineupPhoto $parts[2] ([DateTimeOffset]::Parse($parts[3]).UtcDateTime))) }
    exit 0
}

$PreWindow = if ($Watch) { 15 } else { 20 }   # за сколько минут до начала слать «скоро матч»

function Invoke-Check {
Update-Now
$script:myMatches = @()
foreach ($league in $Leagues.Keys) {
    foreach ($d in $dateList) {
        try {
            $board = Invoke-RestMethod "https://site.api.espn.com/apis/site/v2/sports/soccer/$league/scoreboard?dates=$d" -TimeoutSec 20
        } catch { continue }   # турнира нет или сеть — пропускаем
        foreach ($ev in $board.events) {
            $comp = $ev.competitions[0]
            $hTeam = $comp.competitors | Where-Object { $_.homeAway -eq 'home' } | Select-Object -First 1
            $aTeam = $comp.competitors | Where-Object { $_.homeAway -eq 'away' } | Select-Object -First 1
            $mine = @($comp.competitors | Where-Object { $MyTeams.ContainsKey("$($_.team.id)") })
            if ($mine.Count -eq 0) { continue }

            $id = $ev.id
            $title = (Esc (Ru $hTeam.team.displayName)) + ' — ' + (Esc (Ru $aTeam.team.displayName))
            $kick = [DateTimeOffset]::Parse($ev.date).UtcDateTime
            $kickMsk = $kick.Add($Msk).ToString('HH:mm')
            $mins = [Math]::Round(($kick - $nowUtc).TotalMinutes)
            $state = $ev.status.type.state           # pre / in / post
            $tour = $Leagues[$league]
            $script:myMatches += [pscustomobject]@{ Id = $id; Kick = $kick; State = $state; Title = $title }

            # ⏰ за 15 минут до начала
            $myId = "$($mine[0].team.id)"
            if ($state -eq 'pre' -and $mins -le $PreWindow -and $mins -ge 0 -and -not $sent["${id}:pre"]) {
                $msg = "⏰ <b>Через $mins мин: $title</b>`n🏆 $tour · $kickMsk МСК"
                $lu = Get-MyLineup $league $id $myId
                $msg += if ($lu) { "`n`n$lu" } else { "`n`n📋 Состав пока не объявлен." }
                Send-Alert "${id}:pre" $msg (Find-LineupPhoto $myId $kick)
            }

            # 🟢 матч начался (если предупреждение пропустили — добавим состав)
            if ($state -eq 'in' -and -not $sent["${id}:start"]) {
                $msg = "🟢 <b>Матч начался!</b> $title`n🏆 $tour"
                $photo = $null
                if (-not $sent["${id}:pre"]) {
                    $lu = Get-MyLineup $league $id $myId
                    if ($lu) { $msg += "`n`n$lu" }
                    $photo = Find-LineupPhoto $myId $kick
                    $sent["${id}:pre"] = 'skipped'
                }
                Send-Alert "${id}:start" $msg $photo
            }

            # 🏁 итог
            if ($state -eq 'post' -and $ev.status.type.completed -and -not $sent["${id}:final"]) {
                # не пишем об очень старых матчах (например, при первом запуске)
                if (($nowUtc - $kick).TotalHours -le 6) {
                    $hs = $hTeam.score; $as = $aTeam.score
                    $me = $mine[0]
                    $myScore = [int]$me.score
                    $other = $comp.competitors | Where-Object { $_.team.id -ne $me.team.id } | Select-Object -First 1
                    $res = if ($myScore -gt [int]$other.score) { '✅ Победа!' } elseif ($myScore -lt [int]$other.score) { '❌ Поражение' } else { '🤝 Ничья' }
                    $msg = "🏁 <b>Финал: " + (Esc (Ru $hTeam.team.displayName)) + " ${hs}:${as} " + (Esc (Ru $aTeam.team.displayName)) + "</b>`n$res · $tour"
                    $goals = @($comp.details | Where-Object { $_.scoringPlay })
                    if ($goals.Count -gt 0) {
                        $g = $goals | ForEach-Object {
                            $who = if ($_.athletesInvolved) { $en = $_.athletesInvolved[0].displayName; Fav $en (PlayerName $en) } else { '?' }
                            $extra = if ($_.ownGoal) { ' (автогол)' } elseif ($_.penaltyKick) { ' (пен.)' } else { '' }
                            "⚽ $($_.clock.displayValue) $who$extra"
                        }
                        $msg += "`n`n" + ($g -join "`n")
                    }
                    Send-Alert "${id}:final" $msg
                } else {
                    $sent["${id}:final"] = 'old'
                }
                $sent["${id}:start"] = $sent["${id}:start"]; if (-not $sent["${id}:start"]) { $sent["${id}:start"] = 'skipped' }
                if (-not $sent["${id}:pre"]) { $sent["${id}:pre"] = 'skipped' }
            }
        }
    }
}
}

# --- запомнить отправленное (храним только последние 200 записей) ---
function Save-State {
    if ($DryRun) { return }
    if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory -Force $stateDir | Out-Null }
    $keep = [ordered]@{}
    foreach ($k in ($sent.Keys | Sort-Object | Select-Object -Last 200)) { $keep[$k] = $sent[$k] }
    [IO.File]::WriteAllText($stateFile, ($keep | ConvertTo-Json), $Utf8NoBom)
}

Invoke-Check
Save-State

# --- режим слежения: GitHub запускает проверку неточно (раз в 30–60 минут),
#     поэтому если матч скоро начнётся или уже идёт — остаёмся и проверяем каждую минуту ---
if ($Watch) {
    $started = [DateTime]::UtcNow
    while (([DateTime]::UtcNow - $started).TotalMinutes -lt $WatchMinutes) {
        $active = @($myMatches | Where-Object {
            ($_.State -eq 'in') -or
            ($_.State -eq 'pre' -and ($_.Kick - $nowUtc).TotalMinutes -le 150 -and ($_.Kick - $nowUtc).TotalMinutes -gt -180) -or
            ($_.State -eq 'post' -and -not $sent["$($_.Id):final"])
        })
        if ($active.Count -eq 0) { break }
        # до «за 15 минут» ещё далеко — спим подольше, иначе — минуту
        $next = ($active | Where-Object { $_.State -eq 'pre' } | ForEach-Object { ($_.Kick - $nowUtc).TotalMinutes - $PreWindow } | Measure-Object -Minimum).Minimum
        $sleep = 60
        if ($null -ne $next -and $next -gt 3 -and -not ($active | Where-Object { $_.State -ne 'pre' })) { $sleep = [Math]::Min(600, [int](($next - 2) * 60)) }
        $left = [int]($WatchMinutes * 60 - ([DateTime]::UtcNow - $started).TotalSeconds)
        if ($left -le 0) { break }
        $sleep = [Math]::Min($sleep, $left)
        Write-Output ("WATCH: {0} active match(es), next check in {1}s" -f $active.Count, $sleep)
        Start-Sleep -Seconds $sleep
        Invoke-Check
        Save-State
    }
}
