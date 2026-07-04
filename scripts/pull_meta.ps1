<#
  pull_meta.ps1 — Kéo Meta Ads (mọi account System User), tách MÃ SP từ tên campaign
  (mã = [A-Z]\d{3} đứng trước "IB"/"CD"), gom theo mã SP × KỲ (today/yesterday/this_month/last_month):
    - mess  = onsite_conversion.messaging_conversation_started_7d  (CẢ IB lẫn CD)
    - spend = chi phí (CHỈ camp IB; CD chạy web nên không tính vào cost/mess)
  Kéo theo date_preset (KHÔNG time_increment) để tránh lỗi 400 "reduce data" ở account nhiều camp.
  Xuất meta.js (window.META_DATA). ⚠️ TOKEN local, không deploy.
#>
$ErrorActionPreference='Stop'
$TOKEN=$env:META_TOKEN
$GV='v21.0'
$presets = 'today','yesterday','this_month','last_month'

$acc=Invoke-RestMethod "https://graph.facebook.com/$GV/me/adaccounts?fields=account_id&limit=200&access_token=$TOKEN" -TimeoutSec 30
$accts=$acc.data | ForEach-Object { $_.account_id }
Write-Host "Ad accounts: $($accts.Count)" -ForegroundColor Cyan

$reCode=[regex]'([A-Z]\d{3})\s+(IB|CD)\b'
$sp=@{}    # code -> @{name; t=@{preset->@{mess;spend}}}

foreach($preset in $presets){
  $rows=0
  foreach($acct in $accts){
    $url="https://graph.facebook.com/$GV/act_$acct/insights?level=campaign&fields=campaign_name,spend,actions&date_preset=$preset&limit=500&access_token=$TOKEN"
    $guard=0
    while($url -and $guard -lt 40){
      $guard++; $r=$null
      for($att=1;$att -le 4 -and -not $r;$att++){
        try{ $r=Invoke-RestMethod $url -TimeoutSec 90 }
        catch{ if($att -lt 4){ Start-Sleep -Seconds (2*$att) } }
      }
      if(-not $r){ break }
      foreach($row in $r.data){
        $mch=$reCode.Match("" + $row.campaign_name); if(-not $mch.Success){ continue }
        $code=$mch.Groups[1].Value; $typ=$mch.Groups[2].Value
        $mess=0; foreach($ac in $row.actions){ if($ac.action_type -eq 'onsite_conversion.messaging_conversation_started_7d'){ $mess=[double]$ac.value; break } }
        if(-not $sp.ContainsKey($code)){ $sp[$code]=@{ name=''; t=@{} } }
        if(-not $sp[$code].t.ContainsKey($preset)){ $sp[$code].t[$preset]=@{ mess=0.0; spend=0.0 } }
        $sp[$code].t[$preset].mess += $mess
        if($typ -eq 'IB'){ $sp[$code].t[$preset].spend += [double]$row.spend }
        $rows++
      }
      $url=$r.paging.next
    }
  }
  Write-Host ("  [{0}] gom {1} dòng" -f $preset,$rows) -ForegroundColor Green
}

# tên cuốn từ data.js
try{
  $D=((Get-Content (Join-Path $PSScriptRoot 'data.js') -Raw -Encoding UTF8) -replace '^window\.REPORT_DATA = ','' -replace ';\s*$','') | ConvertFrom-Json
  $c2n=@{}; foreach($o in $D.markets[0].orders){ if($o.mcode -and $o.main -and -not $c2n.ContainsKey($o.mcode)){ $c2n[$o.mcode]=$o.main } }
  foreach($c in @($sp.Keys)){ if($c2n.ContainsKey($c)){ $sp[$c].name=$c2n[$c] } }
}catch{}

$out=[ordered]@{ generated_at=(Get-Date).ToString('yyyy-MM-dd HH:mm'); presets=$presets; sp=[ordered]@{} }
foreach($c in ($sp.Keys | Sort-Object)){
  $t=[ordered]@{}
  foreach($pr in $presets){ if($sp[$c].t.ContainsKey($pr)){ $t[$pr]=[ordered]@{ mess=[int]$sp[$c].t[$pr].mess; spend=[math]::Round($sp[$c].t[$pr].spend) } } else { $t[$pr]=[ordered]@{ mess=0; spend=0 } } }
  $out.sp[$c]=[ordered]@{ name=$sp[$c].name; t=$t }
}
[System.IO.File]::WriteAllText((Join-Path $PSScriptRoot '../public/meta.js'),"window.META_DATA = $($out | ConvertTo-Json -Depth 8);",(New-Object System.Text.UTF8Encoding $false))
Write-Host ("`n✅ {0} mã SP -> meta.js" -f $out.sp.Count) -ForegroundColor Green
