<#
  refresh.ps1 — BÁO CÁO SALE MESSENGER (nguồn Facebook), shop Thái.
  Kéo 45 ngày, lưu DỮ LIỆU THEO NGÀY để trang tự lọc kỳ (Hôm nay/Hôm qua/Tháng này/Tháng trước).
  Ghép 2 nguồn:
    1) Đơn hàng    (Pancake POS, api_key)             -> đơn nguồn Facebook (theo ngày + page + sale + status)
    2) KH tương tác (Pancake Inbox pages.fm, token)    -> "KH mới tương tác" (newCustomer) theo ngày + page

  Cách dùng:
    powershell -ExecutionPolicy Bypass -File refresh.ps1            # 45 ngày (đủ "tháng trước")
    powershell -ExecutionPolicy Bypass -File refresh.ps1 -Days 60

  ⚠️ KEY + TOKEN chỉ nằm trong file này (local). Không commit / không deploy file này (chỉ deploy index.html + data.js).
  ⚠️ KH tương tác (pages.fm) chỉ truy được ~15 ngày gần nhất -> kỳ "Tháng trước" sẽ thiếu KH tương tác (trang tự cảnh báo).
  ⚠️ TOKEN đăng nhập web hết hạn ~đầu 8/2026 -> lấy lại ở pos.pages.vn (F12 > Local Storage > access_token) / nhờ Be.
#>
param(
  [int]$Days = 45
)

$ErrorActionPreference = 'Stop'
$base = 'https://pos.pages.fm/api/v1'
$TOKEN = $env:PANCAKE_TOKEN

# div = đơn vị Pancake lưu giá: THB=satang (÷100), IDR=lưu thẳng (÷1)
$markets = @(
  @{ key='th'; name='Thái Lan'; flag='🇹🇭'; currency='THB'; symbol='฿'; shop='100226157'; apikey=$env:POS_APIKEY; rate=771; div=100; pages=@{} },
  @{ key='id'; name='Indo'; flag='🇮🇩'; currency='IDR'; symbol='Rp'; shop='1021279389'; apikey=$env:POS_APIKEY_ID; rate=1.6; div=1; pages=@{ '1133350909867210'='Komobook - Rumah Ilmu Anak' } }
)

# status_name (Pancake) -> nhãn tiếng Việt
$statusVi = @{
  'submitted'='Đã duyệt'; 'shipped'='Đã gửi hàng'; 'delivered'='Đã giao thành công';
  'canceled'='Đã hủy'; 'cancelled'='Đã hủy'; 'pending'='Chờ xử lý'; 'waitting'='Đang chờ';
  'waiting'='Đang chờ'; 'printed'='Đã in'; 'wait_submit'='Chờ duyệt (nháp)';
  'returned'='Đã hoàn'; 'returning'='Đang hoàn'; 'new'='Mới'
}

$now  = [int][double]::Parse((Get-Date -UFormat %s))
$from = $now - $Days * 86400
$yr   = (Get-Date).Year

$out = [ordered]@{
  generated_at = (Get-Date).ToString('yyyy-MM-dd HH:mm')
  today        = (Get-Date).ToString('yyyy-MM-dd')
  markets      = @()
}

foreach ($m in $markets) {
  Write-Host "→ Kéo $($m.name) (shop $($m.shop)) $Days ngày..." -ForegroundColor Cyan
  $page = 1; $all = @()
  while ($true) {
    $url = "$base/shops/$($m.shop)/orders?api_key=$($m.apikey)&page_size=200&page_number=$page&startDateTime=$from&endDateTime=$now&order_source=Facebook"
    try { $r = Invoke-RestMethod -Uri $url -TimeoutSec 60 }
    catch { Write-Host "  Lỗi trang $page : $($_.Exception.Message)" -ForegroundColor Yellow; break }
    if (-not $r.data -or $r.data.Count -eq 0) { break }
    $all += $r.data
    if ($page % 10 -eq 0) { Write-Host ("  ...{0} đơn" -f $all.Count) }
    if ($r.data.Count -lt 200) { break }
    $page++; if ($page -gt 500) { break }
  }
  Write-Host ("  Tổng {0} đơn (mọi nguồn)" -f $all.Count)

  # --- Đơn nguồn Facebook: lưu record tối giản theo ngày ---
  $orders = New-Object System.Collections.ArrayList
  $pagesMeta = @{}      # pid -> name
  $statusSeen = @{}
  foreach ($o in $all) {
    if (("" + $o.order_sources_name) -ne 'Facebook') { continue }
    $sn = ("" + $o.status_name).ToLower()
    $pgid  = if ($o.page -and $o.page.id) { "" + $o.page.id } elseif ($o.page_id) { "" + $o.page_id } else { '?' }
    $pname = if ($o.page -and $o.page.name) { $o.page.name } elseif ($o.account_name) { $o.account_name } else { '(Không rõ page)' }
    if (-not $pagesMeta.ContainsKey($pgid)) { $pagesMeta[$pgid] = $pname }
    # Doanh số = giá SAU GIẢM (tiền thật khách trả), KHÔNG dùng total_price (giá gốc trước giảm -> phồng số).
    $rev = [double]$o.total_price_after_sub_discount / $m.div
    if ($rev -le 0) { $rev = [double]$o.total_price / $m.div }
    if ($rev -le 0) { $rev = [double]$o.cod / $m.div }
    $sale = if ($o.marketer -and $o.marketer.name) { $o.marketer.name } else { '(Chưa gán MKT)' }
    $statusSeen[$sn] = $true
    # SP CHÍNH = cuốn được add ĐẦU TIÊN vào đơn (bỏ quà tặng); các cuốn sau là bán kèm, không tính
    $main = ''; $mainq = 0; $maincode = ''
    foreach ($it in @($o.items)) {
      if ($it.is_bonus_product) { continue }
      $nm = if ($it.variation_info -and $it.variation_info.name) { ("" + $it.variation_info.name).Trim() } else { '' }
      if (-not $nm) { continue }
      $main = $nm; $mainq = [int]$it.quantity
      if ($it.variation_info -and $it.variation_info.product_display_id) { $maincode = ("" + $it.variation_info.product_display_id).Trim() }
      break
    }
    # NGÀY GỬI HÀNG (sd) = lần đổi trạng thái sang "Đã gửi hàng" (status code 2) trong status_history.
    # Dùng cho TỈ LỆ HOÀN (lọc theo ngày gửi, giống Pancake "Cập nhật trạng thái: Đã gửi hàng").
    $sd = $null
    foreach ($h in @($o.status_history)) {
      if ([int]$h.status -eq 2) { try { $sd = ([datetime](("" + $h.updated_at) -split '\.')[0]).ToString('yyyy-MM-dd') } catch {}; break }
    }
    [void]$orders.Add([ordered]@{
      d    = ([datetime]$o.inserted_at).ToString('yyyy-MM-dd')
      sd   = $sd
      pid  = $pgid
      st   = $sn
      sale = $sale
      rev  = [math]::Round($rev)
      main = $main
      mcode= $maincode
      mainq= $mainq
    })
  }
  Write-Host ("  Đơn Facebook: {0}" -f $orders.Count) -ForegroundColor Green

  # thêm page cấu hình sẵn (thị trường chưa có đơn inbox, vd Indo) để vẫn lấy KH tương tác
  foreach ($k in @($m.pages.Keys)) { if ($k -and -not $pagesMeta.ContainsKey("$k")) { $pagesMeta["$k"] = $m.pages[$k] } }

  # --- KH mới tương tác theo ngày + page (pages.fm) ---
  $interactions = New-Object System.Collections.ArrayList
  $intFrom = $null
  if ($TOKEN -and $pagesMeta.Count -gt 0) {
    Write-Host "  → Lấy KH tương tác cho $($pagesMeta.Count) page (pages.fm)..." -ForegroundColor Cyan
    foreach ($pgid in @($pagesMeta.Keys)) {
      if ($pgid -eq '?') { continue }
      try { $st = Invoke-RestMethod -Uri "https://pages.fm/api/v1/pages/$pgid/statistics?access_token=$TOKEN" -TimeoutSec 30 }
      catch { Write-Host "    (bỏ qua $($pagesMeta[$pgid]))" -ForegroundColor DarkYellow; continue }
      $cats = $st.data.by_date.categories
      $ser  = $st.data.by_date.series | Where-Object { $_.name -eq 'newCustomer' }
      if (-not $cats -or -not $ser) { continue }
      for ($i=0; $i -lt $cats.Count; $i++) {
        $parts = ("" + $cats[$i]).Split('.')
        if ($parts.Count -lt 2) { continue }
        $cd = Get-Date -Year $yr -Month ([int]$parts[1]) -Day ([int]$parts[0]) -Hour 0 -Minute 0 -Second 0
        $dk = $cd.ToString('yyyy-MM-dd')
        [void]$interactions.Add([ordered]@{ d=$dk; pid=$pgid; n=[int]$ser.data[$i] })
        if (-not $intFrom -or $cd -lt $intFrom) { $intFrom = $cd }
      }
    }
    $totInt = 0; foreach ($x in $interactions) { $totInt += $x.n }
    Write-Host ("  ✓ KH tương tác (15 ngày): {0} bản ghi, tổng {1}" -f $interactions.Count, $totInt) -ForegroundColor Green
  }

  # nhãn status đã gặp
  $statusLabels = [ordered]@{}
  foreach ($k in $statusSeen.Keys) { $statusLabels[$k] = if ($statusVi.ContainsKey($k)) { $statusVi[$k] } else { $k } }

  $out.markets += [ordered]@{
    key=$m.key; name=$m.name; flag=$m.flag; currency=$m.currency; symbol=$m.symbol; source='Facebook'
    rate_vnd         = $m.rate
    pages_meta       = $pagesMeta
    status_labels    = $statusLabels
    interaction_from = if ($intFrom) { $intFrom.ToString('yyyy-MM-dd') } else { $null }
    orders           = @($orders)
    interactions     = @($interactions)
  }
}

# ==== TÍCH LŨY KH TƯƠNG TÁC: API pages.fm chỉ trả ~16 ngày gần nhất -> gộp với data.js CŨ
#      để giữ lại các ngày cũ hơn. Chạy cron hàng ngày sẽ dần đủ history. ====
$oldPath = Join-Path $PSScriptRoot '../public/data.js'
if (Test-Path $oldPath) {
  try {
    $oldTxt = (Get-Content $oldPath -Raw) -replace '^window\.REPORT_DATA = ','' -replace ';\s*$',''
    $old = $oldTxt | ConvertFrom-Json
    foreach ($mk in $out.markets) {
      $oldMk = $old.markets | Where-Object { $_.key -eq $mk.key } | Select-Object -First 1
      if (-not $oldMk -or -not $oldMk.interactions) { continue }
      $seen = @{}; $newDates = @()
      foreach ($x in @($mk.interactions)) { $seen["$($x.pid)|$($x.d)"] = $true; $newDates += ("" + $x.d) }
      $minNew = if ($newDates.Count) { ($newDates | Sort-Object)[0] } else { '9999-99-99' }
      $merged = New-Object System.Collections.ArrayList
      foreach ($x in @($mk.interactions)) { [void]$merged.Add($x) }
      $kept = 0
      foreach ($x in @($oldMk.interactions)) {
        $k = "$($x.pid)|$($x.d)"
        if (-not $seen.ContainsKey($k) -and ("" + $x.d) -lt $minNew) {
          [void]$merged.Add([ordered]@{ d = ("" + $x.d); pid = ("" + $x.pid); n = [int]$x.n }); $kept++
        }
      }
      $mk.interactions = @($merged)
      $allDates = @($merged | ForEach-Object { "" + $_.d } | Sort-Object)
      if ($allDates.Count) { $mk.interaction_from = $allDates[0] }
      Write-Host ("  ↩ [{0}] tích lũy: giữ thêm {1} ngày tương tác cũ (đủ history từ {2})" -f $mk.key, $kept, $mk.interaction_from) -ForegroundColor Cyan
    }
  } catch { Write-Host "  (bỏ qua merge tương tác cũ: $($_.Exception.Message))" -ForegroundColor DarkYellow }
}

$json = $out | ConvertTo-Json -Depth 8
$path = Join-Path $PSScriptRoot '../public/data.js'
[System.IO.File]::WriteAllText($path, "window.REPORT_DATA = $json;", (New-Object System.Text.UTF8Encoding $false))
Write-Host "`n✅ Đã ghi $path" -ForegroundColor Green
