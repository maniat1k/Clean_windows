# === fix_python.ps1 ===
# Fuerza Python 3.12 del usuario, corrige PATH y pip, y evita que se use el Python de Inkscape.

$pyRoot = "$env:LOCALAPPDATA\Programs\Python\Python312"
$pyExe  = Join-Path $pyRoot "python.exe"
$pyScr  = Join-Path $pyRoot "Scripts"

if (-not (Test-Path $pyExe)) {
  Write-Error "No existe $pyExe. Verificá tu instalación de Python 3.12."
  exit 1
}

# 1) Python Launcher (py) por defecto a 3.12
$pyIniUser = Join-Path $env:LOCALAPPDATA "py.ini"
"[defaults]`npython=3.12-64" | Set-Content -Path $pyIniUser -Encoding Ascii

# 2) Limpiar PATH de usuario: sacar Python310/311 y Scripts viejos, y anteponer 3.12
$oldUserPath = [Environment]::GetEnvironmentVariable("Path","User")
$userParts = @()
if ($oldUserPath) { $userParts = $oldUserPath.Split(';') | Where-Object { $_ } }

# Quitar rastro de otras versiones de Python del perfil de usuario
$userParts = $userParts | Where-Object {
    ($_ -notmatch '\\Python31\d(\\|$)') -and
    ($_ -notmatch '\\Python3\d\\Scripts(\\|$)')
}

# Anteponer 3.12 (evitar duplicados exactos)
$prepend = @($pyRoot, $pyScr)
foreach ($p in $prepend) {
  $userParts = @($p) + ($userParts | Where-Object { $_ -ne $p })
}

$newUserPath = ($userParts -join ';')
[Environment]::SetEnvironmentVariable("Path", $newUserPath, "User")

# 3) Componer PATH efectivo de esta sesión con 3.12 primero (antes que el PATH del sistema)
$machinePath = [Environment]::GetEnvironmentVariable("Path","Machine")
$env:Path = ($prepend -join ';') + ';' + ($newUserPath) + ';' + ($machinePath)

Write-Host "`n== VERIFICAR (debería salir TU Python 3.12 antes que Inkscape) =="
where.exe python
where.exe pip
& "$pyExe" --version

# 4) Usar SIEMPRE el Python correcto por ruta explícita para (re)instalar pip y paquetes
Write-Host "`n== ACTUALIZAR pip/setuptools/wheel en 3.12 =="
& "$pyExe" -m ensurepip --upgrade
& "$pyExe" -m pip install -U pip setuptools wheel

Write-Host "`n== PRUEBA pip (3.12) =="
& "$pyExe" -m pip --version

# 5) Ejemplo de instalación (Whisper)
Write-Host "`n== INSTALAR openai-whisper EN 3.12 =="
& "$pyExe" -m pip install -U openai-whisper

Write-Host "`nListo. Cerrá y reabrí PowerShell para sesiones nuevas. En esta sesión ya quedó activo."
