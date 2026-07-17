<#
  pull_meta.ps1 — Kéo Meta Ads (mọi account System User), tách MÃ SP từ tên campaign
  (mã = [A-Z]\d{3} đứng trước "IB"/"CD"), gom theo mã SP × KỲ (today/yesterday/this_month/last_month):
    - mess  = onsite_conversion.messaging_conversation_started_7d  (CHỈ camp IB)
    - spend = chi phí (CHỈ camp IB; CD chạy web -> bỏ hẳn, không tính mess lẫn cost)
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
# Mã SP dùng CHUNG giữa các thị trường (vd A029 vừa Thái vừa Indo) -> phải tách theo tên camp.
# ⚠️ Camp Indo KHÔNG phải lúc nào cũng ghi "Indo": nhiều camp IB đặt theo TÊN PAGE Indo
#    (Rumah/Komo/Dunia/Cakra/Taman/anak) -> phải nhận diện cả các từ khoá page này.
# Thái = page CGM/PSói/Changgo/Magic/Brainy (không dính từ khoá Indo). Malay->my, Phil->ph.
function Get-Mkt([string]$name){
  if($name -match '(?i)indo|idn|komo|rumah|dunia|cakra|taman|\banak\b'){ 'id' }
  elseif($name -match '(?i)malay|malaysia'){ 'my' }
  elseif($name -match '(?i)\bphil'){ 'ph' }
  else { 'th' }
}
$mkts=@{}   # mktkey -> @{ code -> @{name; t=@{preset->@{mess;spend}}} }
# DỰ ÁN (đội NV): prefix tên camp (A2S03F->A2) = mã dự án; token[1] = mã NV (trùng ID sale trong đơn POS)
# projs: mkt -> prefix -> @{ brand; staff=@{id->@{name;spend}}; t=@{preset->@{spend;camps}} }  (gom CẢ IB lẫn CD)
$projs=@{}

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
        $nm="" + $row.campaign_name

        # ── DỰ ÁN (đội NV): gom MỌI camp (IB+CD) theo prefix + mã NV ──
        $toks = $nm.Trim() -split '\s+'
        if($toks.Count -ge 3 -and $toks[1] -match '^\d{6,}$'){
          $pref=$toks[0]
          if($pref -match '^([A-Za-z]\d+)S'){ $pm=$Matches[1].ToUpper() } else { $pm=$pref.ToUpper() }
          if($pm -notmatch '^[A-Z]\d+$'){ $pm=$null }   # bỏ prefix rác (AVB, chuỗi lạ)
          if($pm){
          $sid=$toks[1]; $snm=$toks[2]; $mkP=Get-Mkt $nm; $spd=[double]$row.spend
          if(-not $projs.ContainsKey($mkP)){ $projs[$mkP]=@{} }
          if(-not $projs[$mkP].ContainsKey($pm)){
            if($pm -match '^[Aa]'){ $br='AVB' } elseif($pm -match '^[Bb]'){ $br='BAHA' } else { $br='' }
            $projs[$mkP][$pm]=@{ brand=$br; staff=@{}; t=@{} }
          }
          $P=$projs[$mkP][$pm]
          if(-not $P.staff.ContainsKey($sid)){ $P.staff[$sid]=@{ name=$snm; spend=0.0 } }
          $P.staff[$sid].spend += $spd
          if(-not $P.t.ContainsKey($preset)){ $P.t[$preset]=@{ spend=0.0; camps=0 } }
          $P.t[$preset].spend += $spd; $P.t[$preset].camps += 1
          }
        }

        $mch=$reCode.Match($nm); if(-not $mch.Success){ continue }
        $code=$mch.Groups[1].Value; $typ=$mch.Groups[2].Value
        if($typ -ne 'IB'){ continue }   # CHỈ tính camp IB (cả mess lẫn chi phí); CD chạy web -> bỏ hẳn
        $mk=Get-Mkt $nm
        $mess=0; foreach($ac in $row.actions){ if($ac.action_type -eq 'onsite_conversion.messaging_conversation_started_7d'){ $mess=[double]$ac.value; break } }
        if(-not $mkts.ContainsKey($mk)){ $mkts[$mk]=@{} }
        $sp=$mkts[$mk]
        if(-not $sp.ContainsKey($code)){ $sp[$code]=@{ name=''; t=@{} } }
        if(-not $sp[$code].t.ContainsKey($preset)){ $sp[$code].t[$preset]=@{ mess=0.0; spend=0.0 } }
        $sp[$code].t[$preset].mess  += $mess
        $sp[$code].t[$preset].spend += [double]$row.spend
        $rows++
      }
      $url=$r.paging.next
    }
  }
  Write-Host ("  [{0}] gom {1} dòng" -f $preset,$rows) -ForegroundColor Green
}

# tên cuốn từ data.js (gộp mọi thị trường: mcode -> tên)
$c2n=@{}
try{
  $D=((Get-Content (Join-Path $PSScriptRoot '../public/data.js') -Raw -Encoding UTF8) -replace '^window\.REPORT_DATA = ','' -replace ';\s*$','') | ConvertFrom-Json
  foreach($mk in $D.markets){ foreach($o in $mk.orders){ if($o.mcode -and $o.main -and -not $c2n.ContainsKey($o.mcode)){ $c2n[$o.mcode]=$o.main } } }
}catch{}

# Xuất theo thị trường: byMkt.<key>.sp.<code>.t.<preset>{mess,spend}
$out=[ordered]@{ generated_at=(Get-Date).ToString('yyyy-MM-dd HH:mm'); presets=$presets; byMkt=[ordered]@{} }
$totCodes=0; $totProj=0
$allMkts = @($mkts.Keys) + @($projs.Keys) | Select-Object -Unique | Sort-Object
foreach($mk in $allMkts){
  # -- SP (mess/chi phí IB theo mã SP) --
  $spOut=[ordered]@{}
  if($mkts.ContainsKey($mk)){
    foreach($c in ($mkts[$mk].Keys | Sort-Object)){
      $t=[ordered]@{}
      foreach($pr in $presets){ if($mkts[$mk][$c].t.ContainsKey($pr)){ $t[$pr]=[ordered]@{ mess=[int]$mkts[$mk][$c].t[$pr].mess; spend=[math]::Round($mkts[$mk][$c].t[$pr].spend) } } else { $t[$pr]=[ordered]@{ mess=0; spend=0 } } }
      $nm=if($c2n.ContainsKey($c)){ $c2n[$c] } else { '' }
      $spOut[$c]=[ordered]@{ name=$nm; t=$t }
      $totCodes++
    }
  }
  # -- DỰ ÁN (đội NV) --
  $projOut=[ordered]@{}
  if($projs.ContainsKey($mk)){
    foreach($pm in ($projs[$mk].Keys | Sort-Object)){
      $P=$projs[$mk][$pm]
      $stOut=[ordered]@{}
      foreach($sid in ($P.staff.Keys | Sort-Object)){ $stOut[$sid]=[ordered]@{ name=$P.staff[$sid].name; spend=[math]::Round($P.staff[$sid].spend) } }
      $pt=[ordered]@{}
      foreach($pr in $presets){ if($P.t.ContainsKey($pr)){ $pt[$pr]=[ordered]@{ spend=[math]::Round($P.t[$pr].spend); camps=[int]$P.t[$pr].camps } } else { $pt[$pr]=[ordered]@{ spend=0; camps=0 } } }
      $projOut[$pm]=[ordered]@{ brand=$P.brand; staff=$stOut; t=$pt }
      $totProj++
    }
  }
  $out.byMkt[$mk]=[ordered]@{ sp=$spOut; projects=$projOut }
}
[System.IO.File]::WriteAllText((Join-Path $PSScriptRoot '../public/meta.js'),"window.META_DATA = $($out | ConvertTo-Json -Depth 8);",(New-Object System.Text.UTF8Encoding $false))
Write-Host ("`n✅ {0} thị trường / {1} mã SP / {2} dự án -> meta.js" -f $out.byMkt.Count,$totCodes,$totProj) -ForegroundColor Green
