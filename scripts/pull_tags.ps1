# pull_tags.ps1 — dem HOI THOAI MOI TAO (theo ngay) co gan THE (tag tuy chinh, id>0),
# gom theo tagId x ngay. Xuat tags.js (window.TAGINT_DATA). De web map tagId -> ma SP.
# KEY/TOKEN local, khong deploy file nay.
$ErrorActionPreference = 'Continue'
$dir = "$PSScriptRoot/../public"
$TOKEN = $env:PANCAKE_TOKEN
$Days = 45
$pages = '966474336541380','950171114848099','653403301182324','1002607506260086','868546983019187'

$fromDate = (Get-Date).Date.AddDays(-$Days)
$tagInt = @{}      # tagId -> @{ date -> count }
$tagSample = @{}   # tagId -> snippet mau
$tagTotal = @{}    # tagId -> tong

foreach ($pgid in $pages) {
  $last = $null; $guard = 0; $seen = @{}
  while ($guard -lt 60) {
    $guard++
    $u = "https://pages.fm/api/v1/pages/$pgid/conversations?access_token=$TOKEN"
    if ($last) { $u += "&last_conversation_id=$last" }
    $r = $null
    for ($t = 1; $t -le 3 -and -not $r; $t++) {
      try { $r = Invoke-RestMethod -Uri $u -TimeoutSec 40 } catch { if ($t -lt 3) { Start-Sleep -Seconds $t } }
    }
    if (-not $r) { break }
    $cv = @($r.conversations)
    if ($cv.Count -eq 0) { break }
    $newInPage = 0
    foreach ($c in $cv) {
      if ($seen.ContainsKey("" + $c.id)) { continue }   # khu trung: moi hoi thoai chi dem 1 lan
      $seen["" + $c.id] = 1; $newInPage++
      $ins = $null
      try { $ins = [datetime]::Parse(($c.inserted_at -split '\.')[0]) } catch {}
      if (-not $ins) { continue }
      if ($ins -lt $fromDate) { continue }
      $dk = $ins.ToString('yyyy-MM-dd')
      foreach ($tg in @($c.tags)) {
        $tid = 0; [void][int]::TryParse(("" + $tg), [ref]$tid)
        if ($tid -le 0) { continue }   # bo tag he thong (id am)
        $k = "$tid"
        if (-not $tagInt.ContainsKey($k)) { $tagInt[$k] = @{} }
        if (-not $tagInt[$k].ContainsKey($dk)) { $tagInt[$k][$dk] = 0 }
        $tagInt[$k][$dk]++
        if (-not $tagSample.ContainsKey($k) -and $c.snippet) {
          $sn = "" + $c.snippet; if ($sn.Length -gt 45) { $sn = $sn.Substring(0,45) }
          $tagSample[$k] = $sn
        }
      }
    }
    if ($newInPage -eq 0) { break }   # het trang moi -> dung
    $last = $cv[-1].id
  }
  Write-Host ("Page {0}: {1} hoi thoai duy nhat" -f $pgid.Substring(0,8), $seen.Count)
}

# --- MERGE voi tags.js cu: giu ngay cu khong con trong 60 gan nhat (tich luy lich su) ---
$oldPath = Join-Path $dir 'tags.js'
if (Test-Path $oldPath) {
  try {
    $oldTxt = (Get-Content $oldPath -Raw) -replace '^window\.TAGINT_DATA = ','' -replace ';\s*$',''
    $old = $oldTxt | ConvertFrom-Json
    foreach ($tp in $old.tag_int.PSObject.Properties) {
      $k = $tp.Name
      if (-not $tagInt.ContainsKey($k)) { $tagInt[$k] = @{} }
      foreach ($dp in $tp.Value.PSObject.Properties) {
        if (-not $tagInt[$k].ContainsKey($dp.Name)) { $tagInt[$k][$dp.Name] = [int]$dp.Value }
      }
    }
    foreach ($sp2 in $old.tag_sample.PSObject.Properties) { if (-not $tagSample.ContainsKey($sp2.Name)) { $tagSample[$sp2.Name] = $sp2.Value } }
  } catch {}
}
$tagTotal = @{}
foreach ($k in $tagInt.Keys) { $s = 0; foreach ($dk in $tagInt[$k].Keys) { $s += [int]$tagInt[$k][$dk] }; $tagTotal[$k] = $s }

$out = [ordered]@{
  generated_at = (Get-Date).ToString('yyyy-MM-dd HH:mm')
  tag_int    = $tagInt
  tag_sample = $tagSample
  tag_total  = $tagTotal
}
$json = $out | ConvertTo-Json -Depth 6
[System.IO.File]::WriteAllText((Join-Path $dir 'tags.js'), "window.TAGINT_DATA = $json;", (New-Object System.Text.UTF8Encoding $false))
Copy-Item (Join-Path $dir 'tags.js') (Join-Path $dir 'public\tags.js') -Force -ErrorAction SilentlyContinue
Write-Host ("OK: {0} tag -> tags.js" -f $tagInt.Keys.Count) -ForegroundColor Cyan
