<#
  pull_meta.ps1 — Kéo Meta Ads (mọi account System User), tách MÃ SP + mã NV từ tên campaign.
  KÉO THEO TỪNG NGÀY (time_increment=1, time_range 45 ngày) -> báo cáo tính được ads cho MỌI khoảng ngày
  (không chỉ 4 preset). CHỈ camp IB (mess + chi phí); CD chạy web -> bỏ.
    - mess  = onsite_conversion.messaging_conversation_started_7d
  Xuất meta.js: byMkt.<mkt>.sp.<code>.days.<yyyy-mm-dd>{mess,spend} + staffAds.<id>.days.<date>{spend,mess}+camps(distinct).
  ⚠️ TOKEN local, không deploy.
#>
$ErrorActionPreference='Stop'
$TOKEN=$env:META_TOKEN
$GV='v21.0'
$since=(Get-Date).AddDays(-45).ToString('yyyy-MM-dd')
$until=(Get-Date).ToString('yyyy-MM-dd')

$acc=Invoke-RestMethod "https://graph.facebook.com/$GV/me/adaccounts?fields=account_id&limit=200&access_token=$TOKEN" -TimeoutSec 30
$accts=$acc.data | ForEach-Object { $_.account_id }
Write-Host "Ad accounts: $($accts.Count) | theo ngày $since -> $until" -ForegroundColor Cyan

$reCode=[regex]'([A-Z]\d{3})\s+(IB|CD)\b'
# Mã SP dùng CHUNG giữa các thị trường -> tách theo TÊN camp. Indo còn đặt theo tên page (Rumah/Komo/anak...).
function Get-Mkt([string]$name){
  if($name -match '(?i)indo|idn|komo|rumah|dunia|cakra|taman|\banak\b'){ 'id' }
  elseif($name -match '(?i)malay|malaysia'){ 'my' }
  elseif($name -match '(?i)\bphil'){ 'ph' }
  else { 'th' }
}
$mkts=@{}   # mkt -> code -> @{name; days=@{date->@{mess;spend}}}
$projs=@{}  # mkt -> sid -> @{name; days=@{date->@{spend;mess}}; camps=@{name->1}}

$tr=[uri]::EscapeDataString('{"since":"'+$since+'","until":"'+$until+'"}')   # PHẢI url-encode JSON trong URL
$rows=0
foreach($acct in $accts){
  $url="https://graph.facebook.com/$GV/act_$acct/insights?level=campaign&fields=campaign_name,spend,actions&time_range=$tr&time_increment=1&limit=500&access_token=$TOKEN"
  $guard=0
  while($url -and $guard -lt 120){
    $guard++; $r=$null
    for($att=1;$att -le 2 -and -not $r;$att++){   # FAIL NHANH khi throttle (tránh timeout cả job)
      try{ $r=Invoke-RestMethod $url -TimeoutSec 45 }
      catch{ if($att -lt 2){ Start-Sleep -Seconds 1 } }
    }
    if(-not $r){ break }
    foreach($row in $r.data){
      $nm="" + $row.campaign_name
      $mch=$reCode.Match($nm); if(-not $mch.Success){ continue }
      $code=$mch.Groups[1].Value; $typ=$mch.Groups[2].Value
      if($typ -ne 'IB'){ continue }
      $dk="" + $row.date_start
      $mk=Get-Mkt $nm
      $mess=0; foreach($ac in $row.actions){ if($ac.action_type -eq 'onsite_conversion.messaging_conversation_started_7d'){ $mess=[double]$ac.value; break } }
      $spd=[double]$row.spend

      # ── ADS THEO MÃ NV (đội dự án) ──
      $toks = $nm.Trim() -split '\s+'
      if($toks.Count -ge 3 -and $toks[1] -match '^\d{6,}$'){
        $sid=$toks[1]
        if(-not $projs.ContainsKey($mk)){ $projs[$mk]=@{} }
        if(-not $projs[$mk].ContainsKey($sid)){ $projs[$mk][$sid]=@{ name=$toks[2]; days=@{}; camps=@{} } }
        $P=$projs[$mk][$sid]
        if(-not $P.days.ContainsKey($dk)){ $P.days[$dk]=@{ spend=0.0; mess=0.0 } }
        $P.days[$dk].spend += $spd; $P.days[$dk].mess += $mess
        $P.camps[$nm]=1
      }
      # ── SP ──
      if(-not $mkts.ContainsKey($mk)){ $mkts[$mk]=@{} }
      $sp=$mkts[$mk]
      if(-not $sp.ContainsKey($code)){ $sp[$code]=@{ name=''; days=@{} } }
      if(-not $sp[$code].days.ContainsKey($dk)){ $sp[$code].days[$dk]=@{ mess=0.0; spend=0.0 } }
      $sp[$code].days[$dk].mess  += $mess
      $sp[$code].days[$dk].spend += $spd
      $rows++
    }
    $url=$r.paging.next
  }
}
Write-Host ("  gom {0} dòng-ngày" -f $rows) -ForegroundColor Green

# tên cuốn từ data.js
$c2n=@{}
try{
  $D=((Get-Content (Join-Path $PSScriptRoot '../public/data.js') -Raw -Encoding UTF8) -replace '^window\.REPORT_DATA = ','' -replace ';\s*$','') | ConvertFrom-Json
  foreach($mk in $D.markets){ foreach($o in $mk.orders){ if($o.mcode -and $o.main -and -not $c2n.ContainsKey($o.mcode)){ $c2n[$o.mcode]=$o.main } } }
}catch{}

# Xuất: byMkt.<key>.sp.<code>.days.<date>{mess,spend} + staffAds.<id>.days.<date>{spend,mess}+camps
$out=[ordered]@{ generated_at=(Get-Date).ToString('yyyy-MM-dd HH:mm'); byMkt=[ordered]@{} }
$totCodes=0; $totProj=0
$allMkts = @($mkts.Keys) + @($projs.Keys) | Select-Object -Unique | Sort-Object
foreach($mk in $allMkts){
  $spOut=[ordered]@{}
  if($mkts.ContainsKey($mk)){
    foreach($c in ($mkts[$mk].Keys | Sort-Object)){
      $days=[ordered]@{}
      foreach($dk in ($mkts[$mk][$c].days.Keys | Sort-Object)){ $days[$dk]=[ordered]@{ mess=[int]$mkts[$mk][$c].days[$dk].mess; spend=[math]::Round($mkts[$mk][$c].days[$dk].spend) } }
      $nm=if($c2n.ContainsKey($c)){ $c2n[$c] } else { '' }
      $spOut[$c]=[ordered]@{ name=$nm; days=$days }
      $totCodes++
    }
  }
  $saOut=[ordered]@{}
  if($projs.ContainsKey($mk)){
    foreach($sid in ($projs[$mk].Keys | Sort-Object)){
      $P=$projs[$mk][$sid]
      $days=[ordered]@{}
      foreach($dk in ($P.days.Keys | Sort-Object)){ $days[$dk]=[ordered]@{ spend=[math]::Round($P.days[$dk].spend); mess=[int]$P.days[$dk].mess } }
      $saOut[$sid]=[ordered]@{ name=$P.name; camps=[int]$P.camps.Count; days=$days }
      $totProj++
    }
  }
  $out.byMkt[$mk]=[ordered]@{ sp=$spOut; staffAds=$saOut }
}
[System.IO.File]::WriteAllText((Join-Path $PSScriptRoot '../public/meta.js'),"window.META_DATA = $($out | ConvertTo-Json -Depth 8);",(New-Object System.Text.UTF8Encoding $false))
Write-Host ("`n✅ {0} thị trường / {1} mã SP / {2} NV(ads) [theo ngày] -> meta.js" -f $out.byMkt.Count,$totCodes,$totProj) -ForegroundColor Green
