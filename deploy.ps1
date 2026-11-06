$ErrorActionPreference = 'Stop'
$expected = 'ylkgfzfbdbabioycbaph'
Set-Location "$HOME\work\sale"
$ref = (Get-Content supabase\.temp\project-ref).Trim()
if ($ref -ne $expected) { Write-Host "STOP: المشروع المربوط $ref وليس $expected" -ForegroundColor Red; exit 1 }
Write-Host "الهدف سليم: $ref" -ForegroundColor Green

Write-Host "`n--- الملفات اللي هتتنفذ ---"
supabase db push --linked --dry-run

Write-Host "`n--- تنفيذ ---"
supabase db push --linked --yes
if ($LASTEXITCODE -ne 0) { Write-Host "فشل التنفيذ، انسخ الرسالة وابعتها" -ForegroundColor Red; exit 1 }

Write-Host "`n--- فحص الأرقام ---"
$sql = "select (select count(*) from pg_tables where schemaname='public') as tables, (select count(*) from pg_tables where schemaname='public' and rowsecurity) as rls, (select count(*) from pg_policies where schemaname='public') as policies, (select count(*) from storage.buckets) as buckets, (select count(*) from pg_policies where schemaname='storage' and tablename='objects') as storage_policies, (select string_agg(policyname, ', ') from pg_policies where schemaname='storage' and tablename='objects' and 'anon' = any(roles)) as anon_policies, (select string_agg(id || '=' || public::text, ', ' order by id) from storage.buckets) as buckets_public;"
supabase db query --linked $sql
if ($LASTEXITCODE -ne 0) { Write-Host "أمر الفحص مش مدعوم عندك. شغّل نفس الـ SQL يدويًا في SQL Editor." -ForegroundColor Yellow; Write-Host $sql }
