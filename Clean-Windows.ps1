#requires -Version 5.1

[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:ToolRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:IsAdmin = $false

function Test-Administrator {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Write-Title([string]$Text) {
    Write-Host "`n== $Text ==" -ForegroundColor Cyan
}

function Write-Info([string]$Text) { Write-Host "[INFO] $Text" -ForegroundColor Cyan }
function Write-Ok([string]$Text) { Write-Host "[OK]   $Text" -ForegroundColor Green }
function Write-Warn([string]$Text) { Write-Host "[AVISO] $Text" -ForegroundColor Yellow }
function Write-Fail([string]$Text) { Write-Host "[ERROR] $Text" -ForegroundColor Red }

function Confirm-Action([string]$Message) {
    $answer = Read-Host "$Message (S/N)"
    return $answer -match '^(s|si|sí|y|yes)$'
}

function Test-AdminRequired([string]$Action) {
    if ($script:IsAdmin) { return $true }
    Write-Warn "'$Action' requiere ejecutar PowerShell como Administrador."
    return $false
}

function Pause-Toolkit {
    [void](Read-Host "`nPresioná Enter para volver al menú")
}

function Format-Bytes([double]$Bytes) {
    if ($Bytes -ge 1TB) { return ('{0:N2} TB' -f ($Bytes / 1TB)) }
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N2} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N2} KB' -f ($Bytes / 1KB)) }
    return ('{0:N0} bytes' -f $Bytes)
}

function Get-DirectorySize([string]$Path) {
    try {
        $sum = (Get-ChildItem -LiteralPath $Path -Force -Recurse -File -ErrorAction SilentlyContinue |
            Measure-Object -Property Length -Sum).Sum
        if ($null -eq $sum) { return 0 }
        return [double]$sum
    } catch { return 0 }
}

function Invoke-TemporaryCleanup {
    Write-Title 'Limpieza de archivos temporales'
    $targets = @($env:TEMP)
    if ($script:IsAdmin) { $targets += (Join-Path $env:WINDIR 'Temp') }
    else { Write-Warn 'Windows\Temp se omitirá porque requiere privilegios de Administrador.' }

    $targets = @($targets | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique)
    if ($targets.Count -eq 0) { Write-Warn 'No se encontraron carpetas temporales accesibles.'; return }
    $targets | ForEach-Object { Write-Host "  - $_" -ForegroundColor DarkGray }
    Write-Warn 'Los archivos en uso se conservarán.'
    if (-not (Confirm-Action '¿Eliminar el contenido de estas carpetas temporales?')) {
        Write-Info 'Acción cancelada.'; return
    }

    $before = 0; $removed = 0; $failed = 0
    foreach ($target in $targets) {
        $before += Get-DirectorySize $target
        Get-ChildItem -LiteralPath $target -Force -ErrorAction SilentlyContinue | ForEach-Object {
            try { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop; $removed++ }
            catch { $failed++ }
        }
    }
    Write-Ok "Resumen: $removed elementos eliminados; $failed omitidos/en uso; hasta $(Format-Bytes $before) procesados."
}

function Invoke-BrowserCleanup {
    Write-Title 'Liberar memoria cerrando navegadores'
    $names = @('chrome','msedge','firefox','brave','opera')
    $processes = @(Get-Process -Name $names -ErrorAction SilentlyContinue)
    if ($processes.Count -eq 0) { Write-Info 'No hay navegadores compatibles en ejecución.'; return }
    $processes | Group-Object ProcessName | ForEach-Object {
        Write-Host ("  {0}: {1} proceso(s)" -f $_.Name, $_.Count) -ForegroundColor Yellow
    }
    Write-Warn 'Cerrarlos puede descartar formularios o sesiones no guardadas.'
    if (-not (Confirm-Action '¿Cerrar estos navegadores?')) { Write-Info 'Acción cancelada.'; return }
    $closed = 0; $failed = 0
    foreach ($process in $processes) {
        try { Stop-Process -Id $process.Id -Force -ErrorAction Stop; $closed++ } catch { $failed++ }
    }
    Write-Ok "Resumen: $closed procesos cerrados; $failed no pudieron cerrarse."
}

function Get-DiskInventory {
    $items = @()
    try {
        foreach ($disk in @(Get-PhysicalDisk -ErrorAction Stop)) {
            $media = [string]$disk.MediaType
            if ($media -notin @('SSD','HDD')) { $media = 'Desconocido' }
            $items += [pscustomobject]@{
                Number = [string]$disk.DeviceId; Model = [string]$disk.FriendlyName
                MediaType = $media; Size = [double]$disk.Size
            }
        }
    } catch {
        foreach ($disk in @(Get-CimInstance Win32_DiskDrive -ErrorAction Stop)) {
            $label = "{0} {1}" -f $disk.Model, $disk.MediaType
            $media = if ($label -match 'SSD|NVMe|Solid State') { 'SSD' } elseif ($label -match 'HDD|Hard Disk') { 'HDD' } else { 'Desconocido' }
            $items += [pscustomobject]@{
                Number = [string]$disk.Index; Model = [string]$disk.Model
                MediaType = $media; Size = [double]$disk.Size
            }
        }
    }
    return $items
}

function Show-DiskType {
    Write-Title 'Detección de discos'
    try {
        $disks = @(Get-DiskInventory)
        if ($disks.Count -eq 0) { Write-Warn 'No se detectaron discos físicos.'; return }
        $disks | Select-Object @{N='Disco';E={$_.Number}}, @{N='Modelo';E={$_.Model}},
            @{N='Tipo';E={$_.MediaType}}, @{N='Tamaño';E={Format-Bytes $_.Size}} | Format-Table -AutoSize
        if ($disks.MediaType -contains 'Desconocido') {
            Write-Warn 'No se asumirá que un disco desconocido es HDD.'
        }
        Write-Ok "Resumen: $($disks.Count) disco(s) detectado(s)."
    } catch { Write-Fail "No fue posible consultar los discos: $($_.Exception.Message)" }
}

function Get-DriveMediaType([char]$DriveLetter) {
    $partition = Get-Partition -DriveLetter $DriveLetter -ErrorAction Stop
    $disk = Get-Disk -Number $partition.DiskNumber -ErrorAction Stop
    $physical = @(Get-DiskInventory | Where-Object { $_.Number -eq [string]$disk.Number }) | Select-Object -First 1
    if ($null -eq $physical) { return 'Desconocido' }
    return $physical.MediaType
}

function Invoke-HddDefrag {
    Write-Title 'Desfragmentar una unidad HDD'
    if (-not (Test-AdminRequired 'Desfragmentar disco')) { return }
    $inputDrive = (Read-Host 'Letra de unidad [C]').Trim().TrimEnd(':')
    if (-not $inputDrive) { $inputDrive = 'C' }
    if ($inputDrive -notmatch '^[A-Za-z]$') { Write-Warn 'Letra de unidad inválida.'; return }
    $letter = [char]$inputDrive.ToUpperInvariant()
    try {
        $volume = Get-Volume -DriveLetter $letter -ErrorAction Stop
        $media = Get-DriveMediaType $letter
        Write-Info "Unidad $letter`: ($($volume.FileSystemLabel)) detectada como: $media."
        if ($media -eq 'SSD') { Write-Warn 'Acción bloqueada: esta herramienta no desfragmenta SSD.'; return }
        if ($media -ne 'HDD') { Write-Warn 'Acción bloqueada: no se pudo confirmar que la unidad esté en un HDD.'; return }
        if (-not (Confirm-Action "¿Ejecutar la desfragmentación de $letter`:? Puede tardar bastante")) {
            Write-Info 'Acción cancelada.'; return
        }
        & "$env:WINDIR\System32\defrag.exe" "$letter`:" /U /V
        if ($LASTEXITCODE -eq 0) { Write-Ok "Resumen: desfragmentación de $letter`: completada." }
        else { Write-Fail "Defrag terminó con código $LASTEXITCODE." }
    } catch { Write-Fail "No se pudo desfragmentar: $($_.Exception.Message)" }
}

function Invoke-ServiceReview {
    Write-Title 'Servicios opcionales conocidos'
    if (-not (Test-AdminRequired 'Modificar servicios')) { return }
    $serviceDefinitions = @(
        @{ Name='DiagTrack'; Description='telemetría y experiencias de usuario conectado' },
        @{ Name='dmwappushservice'; Description='enrutamiento de mensajes WAP (puede no existir)' }
    )
    $changed = 0; $skipped = 0
    foreach ($definition in $serviceDefinitions) {
        $service = Get-Service -Name $definition.Name -ErrorAction SilentlyContinue
        if ($null -eq $service) { Write-Info "$($definition.Name): no está instalado."; continue }
        $startMode = (Get-CimInstance Win32_Service -Filter "Name='$($definition.Name)'" -ErrorAction SilentlyContinue).StartMode
        Write-Host "`n$($definition.Name) — $($definition.Description)" -ForegroundColor Yellow
        Write-Host "Estado: $($service.Status) | Inicio: $startMode"
        if (-not (Confirm-Action "¿Detener y deshabilitar $($definition.Name)?")) { $skipped++; continue }
        try {
            if ($service.Status -ne 'Stopped') { Stop-Service -Name $definition.Name -Force -ErrorAction Stop }
            Set-Service -Name $definition.Name -StartupType Disabled -ErrorAction Stop
            Write-Ok "$($definition.Name) deshabilitado. Se puede revertir desde services.msc."
            $changed++
        } catch { Write-Fail "$($definition.Name): $($_.Exception.Message)" }
    }
    Write-Ok "Resumen: $changed servicio(s) cambiado(s); $skipped omitido(s)."
}

function Split-PathVariable([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return @() }
    return @($Value -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Get-UniquePathEntries([string[]]$Entries) {
    $seen = @{}; $result = @()
    foreach ($entry in $Entries) {
        $key = $entry.TrimEnd('\').ToLowerInvariant()
        if (-not $seen.ContainsKey($key)) { $seen[$key] = $true; $result += $entry }
    }
    return $result
}

function Backup-EnvironmentPath {
    $backupDir = Join-Path $script:ToolRoot 'backups'
    if (-not (Test-Path $backupDir)) { New-Item -ItemType Directory -Path $backupDir | Out-Null }
    $backupFile = Join-Path $backupDir ("PATH-backup-{0}.txt" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    @(
        '# Clean Windows Toolkit - PATH backup',
        "# Date: $(Get-Date -Format o)",
        "USER=$([Environment]::GetEnvironmentVariable('Path','User'))",
        "MACHINE=$([Environment]::GetEnvironmentVariable('Path','Machine'))"
    ) | Set-Content -LiteralPath $backupFile -Encoding UTF8
    return $backupFile
}

function Repair-SystemPath {
    Write-Title 'Auditar y reparar PATH'
    $scopes = @('User')
    if ($script:IsAdmin) { $scopes += 'Machine' }
    else { Write-Warn 'Sin privilegios elevados solo se reparará el PATH del usuario; el PATH del sistema se auditará sin modificar.' }

    $plan = @(); $totalDuplicates = 0
    foreach ($scope in @('User','Machine')) {
        $raw = [Environment]::GetEnvironmentVariable('Path', $scope)
        $entries = @(Split-PathVariable $raw)
        $unique = @(Get-UniquePathEntries $entries)
        $missing = @($unique | Where-Object { -not (Test-Path ([Environment]::ExpandEnvironmentVariables($_))) })
        $duplicates = $entries.Count - $unique.Count
        $totalDuplicates += $duplicates
        Write-Host "`n$scope PATH: $($entries.Count) entradas; $duplicates duplicadas; $($missing.Count) no verificables." -ForegroundColor Cyan
        $missing | ForEach-Object { Write-Host "  ? $_" -ForegroundColor DarkYellow }
        $plan += [pscustomobject]@{ Scope=$scope; Raw=$raw; Entries=$unique; Duplicates=$duplicates }
    }
    Write-Warn 'Las rutas inexistentes/no verificables se conservarán por seguridad; solo se quitan vacíos y duplicados exactos.'
    if ($totalDuplicates -eq 0) { Write-Ok 'Resumen: PATH ya está normalizado; no se hicieron cambios.'; return }
    if (-not (Confirm-Action "¿Crear backup y quitar $totalDuplicates duplicado(s) de los ámbitos permitidos?")) {
        Write-Info 'Acción cancelada.'; return
    }
    try {
        $backup = Backup-EnvironmentPath; $changed = 0
        foreach ($item in $plan | Where-Object { $_.Scope -in $scopes -and $_.Duplicates -gt 0 }) {
            [Environment]::SetEnvironmentVariable('Path', ($item.Entries -join ';'), $item.Scope)
            $changed++
        }
        $env:Path = @(
            [Environment]::GetEnvironmentVariable('Path','Machine'),
            [Environment]::GetEnvironmentVariable('Path','User')
        ) -join ';'
        Write-Ok "Resumen: $changed ámbito(s) reparado(s). Backup: $backup"
    } catch { Write-Fail "No se pudo reparar PATH: $($_.Exception.Message)" }
}

function Get-PythonCommand {
    $candidates = @()
    $python = Get-Command python.exe -ErrorAction SilentlyContinue
    if ($python) { $candidates += $python.Source }
    $python3 = Get-Command python3.exe -ErrorAction SilentlyContinue
    if ($python3) { $candidates += $python3.Source }
    try { $candidates += (& py.exe -0p 2>$null | ForEach-Object { ($_ -replace '^\s*-V:\S+\s+','').Trim() }) } catch {}
    $candidates = @($candidates | Where-Object { $_ -and (Test-Path -LiteralPath $_) -and ($_ -notmatch '\\WindowsApps\\') } | Select-Object -Unique)
    foreach ($candidate in $candidates) {
        try {
            $version = (& $candidate --version 2>&1 | Select-Object -First 1)
            if ($LASTEXITCODE -eq 0 -and $version -match '^Python 3\.') {
                return [pscustomobject]@{ Path=$candidate; Version=[string]$version }
            }
        } catch {}
    }
    return $null
}

function Repair-PythonConfiguration {
    Write-Title 'Reparar configuración de Python'
    $python = Get-PythonCommand
    if ($null -eq $python) { Write-Warn 'No se encontró una instalación real de Python 3. No se hicieron cambios.'; return }
    $root = Split-Path -Parent $python.Path
    $scripts = Join-Path $root 'Scripts'
    Write-Info "Detectado: $($python.Version) en $($python.Path)"
    $entries = @(Split-PathVariable ([Environment]::GetEnvironmentVariable('Path','User')))
    $newEntries = @(Get-UniquePathEntries (@($root, $scripts) + $entries))
    if (-not (Confirm-Action '¿Crear backup, priorizar esta instalación en PATH de usuario y verificar pip?')) {
        Write-Info 'Acción cancelada.'; return
    }
    try {
        $backup = Backup-EnvironmentPath
        [Environment]::SetEnvironmentVariable('Path', ($newEntries -join ';'), 'User')
        $env:Path = "$root;$scripts;$env:Path"
        & $python.Path -m ensurepip --upgrade
        if ($LASTEXITCODE -ne 0) { throw "ensurepip terminó con código $LASTEXITCODE" }
        $pipVersion = (& $python.Path -m pip --version 2>&1 | Select-Object -First 1)
        Write-Ok "Resumen: Python priorizado y pip verificado ($pipVersion). Backup: $backup"
        Write-Info 'Cerrá y reabrí la terminal para que otras sesiones usen el PATH actualizado.'
    } catch { Write-Fail "No se pudo completar la reparación: $($_.Exception.Message)" }
}

function Get-SystemSnapshot {
    $windows = [Environment]::OSVersion.VersionString
    $architecture = $env:PROCESSOR_ARCHITECTURE
    $cpuName = $env:PROCESSOR_IDENTIFIER
    $ramTotal = 'No disponible'; $ramFree = 'No disponible'; $driveFree = 'No disponible'

    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $windows = "$($os.Caption) (build $($os.BuildNumber))"
        $architecture = $os.OSArchitecture
        $ramFree = Format-Bytes ($os.FreePhysicalMemory * 1KB)
    } catch {}
    try {
        $cpu = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1
        if ($cpu.Name) { $cpuName = $cpu.Name }
    } catch {
        try { $cpuName = (Get-ItemProperty 'HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\0' -ErrorAction Stop).ProcessorNameString.Trim() } catch {}
    }
    try {
        $computer = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        $ramTotal = Format-Bytes $computer.TotalPhysicalMemory
    } catch {}
    try {
        $drive = New-Object System.IO.DriveInfo($env:SystemDrive)
        if ($drive.IsReady) { $driveFree = Format-Bytes $drive.AvailableFreeSpace }
    } catch {}

    return [pscustomobject][ordered]@{
        Equipo = $env:COMPUTERNAME
        Usuario = $env:USERNAME
        Windows = $windows
        Arquitectura = $architecture
        CPU = $cpuName
        'RAM total' = $ramTotal
        'RAM libre' = $ramFree
        PowerShell = $PSVersionTable.PSVersion.ToString()
        Administrador = if ($script:IsAdmin) { 'Sí' } else { 'No' }
        'Unidad del sistema libre' = $driveFree
    }
}

function Show-SystemInformation {
    Write-Title 'Información detallada del sistema'
    Get-SystemSnapshot | Format-List
    Write-Ok 'Resumen: información del sistema actualizada.'
}

function Invoke-SafeWhisper {
    Write-Title 'Ejecutar safe_whisper.py'
    $scriptPath = Join-Path $script:ToolRoot 'safe_whisper.py'
    if (-not (Test-Path -LiteralPath $scriptPath)) { Write-Warn "No existe $scriptPath."; return }
    $python = Get-PythonCommand
    if ($null -eq $python) { Write-Warn 'Python 3 no está disponible. No se ejecutó safe_whisper.py.'; return }
    if (-not (Get-Command ffmpeg.exe -ErrorAction SilentlyContinue)) { Write-Warn 'FFmpeg no está disponible en PATH; safe_whisper.py lo necesita.'; return }
    & $python.Path -c 'import whisper' 2>$null
    if ($LASTEXITCODE -ne 0) { Write-Warn "El paquete Python 'whisper' no está instalado en $($python.Path)."; return }

    $inputFile = (Read-Host 'Ruta del audio o video').Trim('"')
    if (-not (Test-Path -LiteralPath $inputFile -PathType Leaf)) { Write-Warn 'El archivo de entrada no existe.'; return }
    $language = Read-Host 'Idioma [es]'; if (-not $language) { $language = 'es' }
    $model = Read-Host 'Modelo [small]'; if (-not $model) { $model = 'small' }
    $chunk = Read-Host 'Duración de fragmento en segundos [600]'; if (-not $chunk) { $chunk = '600' }
    $chunkValue = 0
    if (-not [int]::TryParse($chunk, [ref]$chunkValue) -or $chunkValue -lt 30) { Write-Warn 'La duración debe ser un entero de al menos 30 segundos.'; return }
    $outDir = Read-Host 'Carpeta de salida [transcripts]'; if (-not $outDir) { $outDir = (Join-Path $script:ToolRoot 'transcripts') }
    if (-not (Confirm-Action "¿Iniciar transcripción con el modelo '$model'?")) { Write-Info 'Acción cancelada.'; return }
    try {
        & $python.Path $scriptPath --input $inputFile --lang $language --model $model --chunk_sec $chunkValue --outdir $outDir
        if ($LASTEXITCODE -eq 0) { Write-Ok "Resumen: safe_whisper.py finalizó correctamente. Salida: $outDir" }
        else { Write-Fail "safe_whisper.py terminó con código $LASTEXITCODE." }
    } catch { Write-Fail "No se pudo ejecutar safe_whisper.py: $($_.Exception.Message)" }
}

function Get-ConsoleWidth {
    try { return [int]$Host.UI.RawUI.WindowSize.Width } catch { return 80 }
}

function Limit-Text([string]$Text, [int]$Width) {
    if ($null -eq $Text) { $Text = '' }
    if ($Width -le 3) { return $Text.Substring(0, [Math]::Min($Text.Length, $Width)) }
    if ($Text.Length -le $Width) { return $Text }
    return $Text.Substring(0, $Width - 3) + '...'
}

function Format-SystemField([string]$Label, [object]$Value, [int]$Width) {
    $prefix = ('{0,-14}: ' -f (Limit-Text $Label 14))
    $valueWidth = [Math]::Max(1, $Width - $prefix.Length)
    return $prefix + (Limit-Text ([string]$Value) $valueWidth).PadRight($valueWidth)
}

function Write-PanelRule([int]$Width, [string]$Caption) {
    $inner = $Width - 2
    if ([string]::IsNullOrWhiteSpace($Caption)) {
        Write-Host ('+' + ('-' * $inner) + '+') -ForegroundColor DarkGray
        return
    }
    $captionText = " $Caption "
    if ($captionText.Length -gt $inner) { $captionText = Limit-Text $captionText $inner }
    $remaining = $inner - $captionText.Length
    $left = [Math]::Floor($remaining / 2)
    $right = $remaining - $left
    Write-Host ('+' + ('-' * $left) + $captionText + ('-' * $right) + '+') -ForegroundColor DarkGray
}

function Write-SystemPanel([object]$Snapshot, [int]$Width) {
    Write-PanelRule $Width 'INFORMACIÓN DEL SISTEMA'
    if ($Width -ge 88) {
        $gap = 3
        $availableWidth = $Width - 4 - $gap
        $leftWidth = [Math]::Floor($availableWidth / 2)
        $rightWidth = $availableWidth - $leftWidth
        $rows = @(
            @('Equipo', $Snapshot.Equipo, 'Usuario', $Snapshot.Usuario),
            @('Windows', $Snapshot.Windows, 'Arquitectura', $Snapshot.Arquitectura),
            @('CPU', $Snapshot.CPU, 'PowerShell', $Snapshot.PowerShell),
            @('RAM total', $Snapshot.'RAM total', 'RAM libre', $Snapshot.'RAM libre'),
            @('Administrador', $Snapshot.Administrador, 'Unidad libre', $Snapshot.'Unidad del sistema libre')
        )
        foreach ($row in $rows) {
            $left = Format-SystemField $row[0] $row[1] $leftWidth
            $right = Format-SystemField $row[2] $row[3] $rightWidth
            Write-Host ('| ' + $left + (' ' * $gap) + $right + ' |') -ForegroundColor Gray
        }
    } else {
        $fieldWidth = $Width - 4
        foreach ($property in $Snapshot.PSObject.Properties) {
            $label = if ($property.Name -eq 'Unidad del sistema libre') { 'Unidad libre' } else { $property.Name }
            $line = Format-SystemField $label $property.Value $fieldWidth
            Write-Host ('| ' + $line + ' |') -ForegroundColor Gray
        }
    }
    Write-PanelRule $Width ''
}

function Write-MenuLine([string]$Text, [int]$Width, [ConsoleColor]$Color = [ConsoleColor]::Cyan) {
    $line = Limit-Text $Text ($Width - 4)
    Write-Host ('  ' + $line) -ForegroundColor $Color
}

function Show-Menu {
    Clear-Host
    $consoleWidth = Get-ConsoleWidth
    $panelWidth = [Math]::Min(104, [Math]::Max(32, $consoleWidth - 2))
    $snapshot = Get-SystemSnapshot

    Write-Host ''
    Write-Host '  CLEAN WINDOWS' -ForegroundColor Green
    Write-Host (Limit-Text '  Toolkit de mantenimiento seguro para Windows' $panelWidth) -ForegroundColor Gray
    Write-Host ''
    Write-SystemPanel $snapshot $panelWidth
    Write-Host ''

    if ($script:IsAdmin) {
        Write-MenuLine '[OK] Sesión con privilegios de Administrador.' $panelWidth Green
    } else {
        if ($panelWidth -lt 72) {
            Write-MenuLine '[AVISO] 4 y 5 requieren Administrador.' $panelWidth Yellow
            Write-MenuLine '        1 y 6 tendrán alcance limitado.' $panelWidth Yellow
        } else {
            Write-MenuLine '[AVISO] 4 y 5 requieren Administrador; 1 y 6 tendrán alcance limitado.' $panelWidth Yellow
        }
    }
    Write-Host ''

    Write-MenuLine 'MANTENIMIENTO' $panelWidth Green
    Write-MenuLine '[1] Limpiar archivos temporales' $panelWidth
    Write-MenuLine '[2] Liberar memoria cerrando navegadores' $panelWidth
    Write-MenuLine '[3] Detectar tipo de disco SSD/HDD' $panelWidth
    Write-MenuLine '[4] Desfragmentar disco (solo HDD)' $panelWidth
    Write-Host ''
    Write-MenuLine 'REPARACIÓN' $panelWidth Green
    Write-MenuLine '[6] Reparar PATH del sistema' $panelWidth
    Write-MenuLine '[7] Reparar configuración de Python' $panelWidth
    Write-Host ''
    Write-MenuLine 'HERRAMIENTAS' $panelWidth Green
    Write-MenuLine '[5] Revisar servicios opcionales' $panelWidth
    Write-MenuLine '[8] Mostrar información detallada del sistema' $panelWidth
    Write-MenuLine '[9] Ejecutar safe_whisper.py' $panelWidth
    Write-MenuLine '[0] Salir' $panelWidth DarkGray
    Write-Host ''
}

$script:IsAdmin = Test-Administrator
$running = $true
while ($running) {
    Show-Menu
    $choice = Read-Host 'Seleccioná una opción'
    try {
        switch ($choice) {
            '1' { Invoke-TemporaryCleanup }
            '2' { Invoke-BrowserCleanup }
            '3' { Show-DiskType }
            '4' { Invoke-HddDefrag }
            '5' { Invoke-ServiceReview }
            '6' { Repair-SystemPath }
            '7' { Repair-PythonConfiguration }
            '8' { Show-SystemInformation }
            '9' { Invoke-SafeWhisper }
            '0' { $running = $false; Write-Host "`nHasta la próxima." -ForegroundColor Green }
            default { Write-Warn 'Opción inválida.' }
        }
    } catch { Write-Fail "Error no esperado: $($_.Exception.Message)" }
    if ($running) { Pause-Toolkit }
}
