# LEE PATH de USUARIO y arma una tabla auditada
$raw = [Environment]::GetEnvironmentVariable("Path","User")
$paths = $raw -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ }

# Mapa para contar duplicados (case-insensitive)
$counts = @{}
foreach($p in $paths){ $k=$p.ToLower(); $counts[$k] = 1 + ($counts[$k] ?? 0) }

# Tabla ORDENADA por ruta
$report = $paths |
  Sort-Object { $_.ToLower() } |
  Select-Object @{n='Path';e={$_}},
                @{n='Exists';e={ Test-Path $_ }},
                @{n='DuplicateCount';e={ $counts[$_.ToLower()] }},
                @{n='IsDuplicate';e={ $counts[$_.ToLower()] -gt 1 }}
$report | Format-Table -Auto
