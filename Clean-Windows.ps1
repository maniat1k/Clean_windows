#requires -Version 5.1
<#
.SYNOPSIS
    Ejecuta mantenimiento seguro y auditable para Windows 11.

.DESCRIPTION
    Clean-Windows.ps1 es una herramienta modular para limpiar cachés de usuario,
    temporales de Windows, targets modernos de Windows 11, caché de Delivery
    Optimization, componentes de Windows mediante DISM, papelera de reciclaje,
    auditoría de discos y reparación conservadora del PATH.

    El script usa funciones Verb-Noun, admite -WhatIf, -Verbose y -Force, evita
    seguir puntos de reanálisis, omite archivos bloqueados y exige elevación
    explícita para operaciones de sistema.

.PARAMETER Task
    Tareas a ejecutar. Si no se indica ninguna tarea, se muestra la TUI.
    Valores:
    All, TemporaryFiles, Win11Caches, DeliveryOptimization, WindowsComponents,
    RecycleBin, DiskInfo, DefragHdd, Path, Memory, Services, Python.

.PARAMETER Menu
    Muestra el menú interactivo aunque se hayan indicado tareas.

.PARAMETER OlderThanDays
    Antigüedad mínima de archivos a eliminar en limpiezas manuales. Por defecto 1.
    Use 0 para procesar todo el contenido elegible.

.PARAMETER DriveLetter
    Letra de unidad para DefragHdd. Por defecto C.

.PARAMETER Force
    Omite confirmaciones interactivas propias del script. No desactiva -WhatIf.

.EXAMPLE
    .\Clean-Windows.ps1 -Task All -Verbose

.EXAMPLE
    .\Clean-Windows.ps1 -Task Win11Caches,DeliveryOptimization -OlderThanDays 0 -WhatIf

.EXAMPLE
    .\Clean-Windows.ps1 -Menu

.NOTES
    Requiere Windows PowerShell 5.1 o PowerShell 7.
    Las tareas de sistema requieren ejecutar PowerShell como Administrador.
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [ValidateSet(
        'All',
        'TemporaryFiles',
        'Win11Caches',
        'DeliveryOptimization',
        'WindowsComponents',
        'RecycleBin',
        'DiskInfo',
        'DefragHdd',
        'Path',
        'Memory',
        'Services',
        'Python'
    )]
    [string[]]$Task,

    [switch]$Menu,

    [ValidateRange(0, 3650)]
    [int]$OlderThanDays = 1,

    [ValidatePattern('^[A-Za-z]$')]
    [string]$DriveLetter = 'C',

    [switch]$Force,

    [switch]$NoElevate
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:ToolRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

function Test-Administrator {
    <#
    .SYNOPSIS
        Indica si la sesión actual está elevada como Administrador.
    #>
    [CmdletBinding()]
    param()

    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = [Security.Principal.WindowsPrincipal]::new($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        Write-Verbose "No se pudo verificar la elevación: $($_.Exception.Message)"
        return $false
    }
}

function Assert-Administrator {
    <#
    .SYNOPSIS
        Valida elevación antes de una operación que modifica el sistema.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Operation
    )

    if (Test-Administrator) {
        return $true
    }

    Write-Warning "'$Operation' requiere ejecutar PowerShell como Administrador. Tarea omitida."
    return $false
}

function Request-AdministratorRelaunch {
    <#
    .SYNOPSIS
        Relanza el script con elevación UAC cuando la sesión no es Administrador.
    #>
    [CmdletBinding()]
    param()

    if ($NoElevate -or (Test-Administrator)) {
        return
    }

    Clear-Host
    Write-Host ''
    Write-Host '  CLEAN WINDOWS requiere permisos de Administrador.' -ForegroundColor Yellow
    Write-Host '  Se solicitará elevación mediante UAC para continuar de forma segura.' -ForegroundColor Gray
    Write-Host ''

    $hostExe = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }
    $scriptPath = $PSCommandPath
    if (-not $scriptPath) {
        $scriptPath = $MyInvocation.MyCommand.Path
    }

    $argumentList = @(
        '-NoProfile'
        '-ExecutionPolicy'
        'Bypass'
        '-File'
        ('"{0}"' -f $scriptPath)
    )

    try {
        Start-Process -FilePath $hostExe -ArgumentList ($argumentList -join ' ') -Verb RunAs -ErrorAction Stop
    } catch {
        Write-Host "  No se pudo solicitar elevación: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host '  Abre PowerShell como Administrador y vuelve a ejecutar el script.' -ForegroundColor Yellow
        [void](Read-Host '  Presiona Enter para salir')
    }

    exit
}

function Format-ByteSize {
    <#
    .SYNOPSIS
        Formatea bytes en una unidad legible.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [double]$Bytes
    )

    if ($Bytes -ge 1TB) { return ('{0:N2} TB' -f ($Bytes / 1TB)) }
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N2} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N2} KB' -f ($Bytes / 1KB)) }
    return ('{0:N0} bytes' -f $Bytes)
}

function Write-Operation {
    <#
    .SYNOPSIS
        Escribe salida limpia usando el stream de información.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message
    )

    Write-Information $Message -InformationAction Continue
}

function Confirm-CleanAction {
    <#
    .SYNOPSIS
        Solicita confirmación salvo que -Force esté activo.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message
    )

    if ($Force) {
        return $true
    }

    $answer = Read-Host "$Message (S/N)"
    return $answer -match '^(s|si|sí|y|yes)$'
}

function Test-ReparsePoint {
    <#
    .SYNOPSIS
        Detecta enlaces simbólicos, junctions y otros puntos de reanálisis.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [System.IO.FileSystemInfo]$Item
    )

    process {
        return (($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
    }
}

function Get-DirectorySize {
    <#
    .SYNOPSIS
        Calcula tamaño de archivos accesibles sin detenerse por elementos bloqueados.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return 0
    }

    $total = 0.0
    try {
        Get-ChildItem -LiteralPath $Path -Force -Recurse -File -ErrorAction SilentlyContinue |
            ForEach-Object { $total += [double]$_.Length }
    } catch {
        Write-Verbose "Tamaño parcial para '$Path': $($_.Exception.Message)"
    }

    return $total
}

function Remove-CleanItem {
    <#
    .SYNOPSIS
        Elimina un archivo o carpeta de forma conservadora.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [System.IO.FileSystemInfo]$Item,

        [Parameter(Mandatory)]
        [datetime]$OlderThan
    )

    process {
        if (Test-ReparsePoint -Item $Item) {
            Write-Verbose "Omitido punto de reanálisis: $($Item.FullName)"
            return [pscustomobject]@{ Removed = 0; Skipped = 1; Failed = 0; Bytes = 0.0 }
        }

        if ($Item.LastWriteTime -gt $OlderThan) {
            Write-Verbose "Omitido por antigüedad: $($Item.FullName)"
            return [pscustomobject]@{ Removed = 0; Skipped = 1; Failed = 0; Bytes = 0.0 }
        }

        $bytes = 0.0
        if (-not $Item.PSIsContainer) {
            $bytes = [double]$Item.Length
        } else {
            $bytes = Get-DirectorySize -Path $Item.FullName
        }

        if (-not $PSCmdlet.ShouldProcess($Item.FullName, 'Eliminar elemento de caché/temporal')) {
            return [pscustomobject]@{ Removed = 0; Skipped = 1; Failed = 0; Bytes = $bytes }
        }

        try {
            Remove-Item -LiteralPath $Item.FullName -Recurse -Force -ErrorAction Stop
            return [pscustomobject]@{ Removed = 1; Skipped = 0; Failed = 0; Bytes = $bytes }
        } catch [System.UnauthorizedAccessException] {
            Write-Verbose "Bloqueado o sin permisos: $($Item.FullName)"
            return [pscustomobject]@{ Removed = 0; Skipped = 1; Failed = 0; Bytes = 0.0 }
        } catch [System.IO.IOException] {
            Write-Verbose "En uso por el sistema o una aplicación: $($Item.FullName)"
            return [pscustomobject]@{ Removed = 0; Skipped = 1; Failed = 0; Bytes = 0.0 }
        } catch {
            Write-Warning "No se pudo eliminar '$($Item.FullName)': $($_.Exception.Message)"
            return [pscustomobject]@{ Removed = 0; Skipped = 0; Failed = 1; Bytes = 0.0 }
        }
    }
}

function New-CleanTarget {
    <#
    .SYNOPSIS
        Crea una definición de target de limpieza.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Path,
        [switch]$RequiresAdministrator
    )

    [pscustomobject]@{
        Name = $Name
        Path = [Environment]::ExpandEnvironmentVariables($Path)
        RequiresAdministrator = [bool]$RequiresAdministrator
    }
}

function Get-TemporaryCleanTarget {
    <#
    .SYNOPSIS
        Devuelve targets temporales actuales para Windows 11.
    #>
    [CmdletBinding()]
    param()

    @(
        New-CleanTarget -Name 'TEMP del usuario' -Path $env:TEMP
        New-CleanTarget -Name 'Windows Temp' -Path (Join-Path $env:WINDIR 'Temp') -RequiresAdministrator
    )
}

function Get-Windows11CleanTarget {
    <#
    .SYNOPSIS
        Devuelve cachés modernas de Windows 11 y aplicaciones integradas.
    #>
    [CmdletBinding()]
    param()

    $local = $env:LOCALAPPDATA
    $programData = $env:ProgramData

    @(
        New-CleanTarget -Name 'Nuevo Teams - LocalCache' -Path (Join-Path $local 'Packages\MSTeams_8wekyb3d8bbwe\LocalCache')
        New-CleanTarget -Name 'Nuevo Teams - TempState' -Path (Join-Path $local 'Packages\MSTeams_8wekyb3d8bbwe\TempState')
        New-CleanTarget -Name 'Teams clásico/UWP - LocalCache' -Path (Join-Path $local 'Packages\MicrosoftTeams_8wekyb3d8bbwe\LocalCache')
        New-CleanTarget -Name 'Edge WebView2 - Cache' -Path (Join-Path $local 'Microsoft\EdgeWebView\User Data\Default\Cache')
        New-CleanTarget -Name 'Edge WebView2 - Code Cache' -Path (Join-Path $local 'Microsoft\EdgeWebView\User Data\Default\Code Cache')
        New-CleanTarget -Name 'Edge WebView2 - GPUCache' -Path (Join-Path $local 'Microsoft\EdgeWebView\User Data\Default\GPUCache')
        New-CleanTarget -Name 'Edge WebView2 - Service Worker Cache' -Path (Join-Path $local 'Microsoft\EdgeWebView\User Data\Default\Service Worker\CacheStorage')
        New-CleanTarget -Name 'Widgets/Web Experience - LocalCache' -Path (Join-Path $local 'Packages\MicrosoftWindows.Client.WebExperience_cw5n1h2txyewy\LocalCache')
        New-CleanTarget -Name 'Widgets/Web Experience - TempState' -Path (Join-Path $local 'Packages\MicrosoftWindows.Client.WebExperience_cw5n1h2txyewy\TempState')
        New-CleanTarget -Name 'Widgets/Web Experience - AC Temp' -Path (Join-Path $local 'Packages\MicrosoftWindows.Client.WebExperience_cw5n1h2txyewy\AC\Temp')
        New-CleanTarget -Name 'Windows Error Reporting del usuario' -Path (Join-Path $local 'Microsoft\Windows\WER\ReportArchive')
        New-CleanTarget -Name 'Windows Error Reporting del sistema' -Path (Join-Path $programData 'Microsoft\Windows\WER\ReportArchive') -RequiresAdministrator
    )
}

function Invoke-TargetCleanup {
    <#
    .SYNOPSIS
        Limpia un conjunto de targets verificando permisos, edad y puntos de reanálisis.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)]
        [object[]]$Target,

        [ValidateRange(0, 3650)]
        [int]$OlderThanDays = 1
    )

    $olderThan = (Get-Date).AddDays(-$OlderThanDays)
    $totalRemoved = 0
    $totalSkipped = 0
    $totalFailed = 0
    $totalBytes = 0.0

    foreach ($targetItem in $Target) {
        if ($targetItem.RequiresAdministrator -and -not (Assert-Administrator -Operation $targetItem.Name)) {
            $totalSkipped++
            continue
        }

        if (-not (Test-Path -LiteralPath $targetItem.Path)) {
            Write-Verbose "No existe: $($targetItem.Path)"
            continue
        }

        Write-Operation "Procesando: $($targetItem.Name)"
        Write-Verbose "Path: $($targetItem.Path)"

        try {
            $children = @(Get-ChildItem -LiteralPath $targetItem.Path -Force -ErrorAction Stop)
        } catch {
            Write-Warning "No se pudo enumerar '$($targetItem.Path)': $($_.Exception.Message)"
            $totalFailed++
            continue
        }

        foreach ($child in $children) {
            $result = Remove-CleanItem -Item $child -OlderThan $olderThan -WhatIf:$WhatIfPreference
            $totalRemoved += $result.Removed
            $totalSkipped += $result.Skipped
            $totalFailed += $result.Failed
            $totalBytes += $result.Bytes
        }
    }

    [pscustomobject]@{
        Removed = $totalRemoved
        Skipped = $totalSkipped
        Failed = $totalFailed
        EstimatedBytes = $totalBytes
    }
}

function Invoke-TemporaryFileCleanup {
    <#
    .SYNOPSIS
        Limpia temporales de usuario y Windows Temp.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [ValidateRange(0, 3650)]
        [int]$OlderThanDays = 1
    )

    Write-Operation '== Limpieza de archivos temporales =='
    $targets = @(Get-TemporaryCleanTarget)
    $summary = Invoke-TargetCleanup -Target $targets -OlderThanDays $OlderThanDays -WhatIf:$WhatIfPreference
    Write-Operation ("Resumen temporales: {0} eliminados, {1} omitidos, {2} fallidos, {3} estimados." -f $summary.Removed, $summary.Skipped, $summary.Failed, (Format-ByteSize $summary.EstimatedBytes))
}

function Invoke-Windows11CacheCleanup {
    <#
    .SYNOPSIS
        Limpia cachés modernas de Windows 11 como Nuevo Teams, WebView2 y Widgets.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [ValidateRange(0, 3650)]
        [int]$OlderThanDays = 1
    )

    Write-Operation '== Limpieza de cachés Windows 11 =='
    $targets = @(Get-Windows11CleanTarget)
    $summary = Invoke-TargetCleanup -Target $targets -OlderThanDays $OlderThanDays -WhatIf:$WhatIfPreference
    Write-Operation ("Resumen Win11: {0} eliminados, {1} omitidos, {2} fallidos, {3} estimados." -f $summary.Removed, $summary.Skipped, $summary.Failed, (Format-ByteSize $summary.EstimatedBytes))
}

function Invoke-DeliveryOptimizationCleanup {
    <#
    .SYNOPSIS
        Limpia caché de Delivery Optimization con cmdlet nativo cuando está disponible.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    Write-Operation '== Limpieza de Delivery Optimization =='
    if (-not (Assert-Administrator -Operation 'Limpiar Delivery Optimization')) {
        return
    }

    $command = Get-Command -Name Clear-DeliveryOptimizationCache -ErrorAction SilentlyContinue
    if ($command) {
        if ($PSCmdlet.ShouldProcess('Delivery Optimization cache', 'Clear-DeliveryOptimizationCache -Force')) {
            try {
                Clear-DeliveryOptimizationCache -Force -ErrorAction Stop
                Write-Operation 'Delivery Optimization: caché limpiada con cmdlet nativo.'
            } catch {
                Write-Warning "Clear-DeliveryOptimizationCache falló: $($_.Exception.Message)"
            }
        }
        return
    }

    $fallback = Join-Path $env:WINDIR 'SoftwareDistribution\DeliveryOptimization\Cache'
    if (-not (Test-Path -LiteralPath $fallback)) {
        Write-Verbose 'No se encontró cmdlet ni carpeta fallback de Delivery Optimization.'
        return
    }

    Write-Warning 'Clear-DeliveryOptimizationCache no está disponible; se usará fallback conservador sobre la caché.'
    $target = New-CleanTarget -Name 'Delivery Optimization fallback' -Path $fallback -RequiresAdministrator
    [void](Invoke-TargetCleanup -Target @($target) -OlderThanDays 1 -WhatIf:$WhatIfPreference)
}

function Invoke-WindowsComponentCleanup {
    <#
    .SYNOPSIS
        Ejecuta DISM StartComponentCleanup para WinSxS/component store.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    Write-Operation '== Limpieza de componentes de Windows =='
    if (-not (Assert-Administrator -Operation 'DISM StartComponentCleanup')) {
        return
    }

    $dism = Join-Path $env:WINDIR 'System32\dism.exe'
    if (-not (Test-Path -LiteralPath $dism)) {
        throw "No se encontró DISM en '$dism'."
    }

    if ($PSCmdlet.ShouldProcess('Component Store', 'DISM /Online /Cleanup-Image /StartComponentCleanup')) {
        & $dism /Online /Cleanup-Image /StartComponentCleanup
        if ($LASTEXITCODE -ne 0) {
            throw "DISM terminó con código $LASTEXITCODE."
        }
        Write-Operation 'DISM completó StartComponentCleanup correctamente.'
    }
}

function Invoke-RecycleBinCleanup {
    <#
    .SYNOPSIS
        Vacía la papelera usando Clear-RecycleBin.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    Write-Operation '== Limpieza de papelera =='
    $command = Get-Command -Name Clear-RecycleBin -ErrorAction SilentlyContinue
    if (-not $command) {
        Write-Warning 'Clear-RecycleBin no está disponible en esta sesión.'
        return
    }

    if ($PSCmdlet.ShouldProcess('Recycle Bin', 'Clear-RecycleBin')) {
        try {
            Clear-RecycleBin -Force:$Force -ErrorAction Stop
            Write-Operation 'Papelera limpiada.'
        } catch {
            Write-Warning "No se pudo limpiar la papelera: $($_.Exception.Message)"
        }
    }
}

function Invoke-BrowserMemoryCleanup {
    <#
    .SYNOPSIS
        Libera memoria cerrando navegadores conocidos previa confirmación.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    Write-Host ''
    Write-Host '== Liberar memoria ==' -ForegroundColor Cyan
    $names = @('chrome', 'msedge', 'firefox', 'brave', 'opera')
    $processes = @(Get-Process -Name $names -ErrorAction SilentlyContinue)

    if ($processes.Count -eq 0) {
        Write-Host 'No hay navegadores compatibles en ejecución.' -ForegroundColor Gray
        return
    }

    $processes | Group-Object ProcessName | ForEach-Object {
        Write-Host ('  {0}: {1} proceso(s)' -f $_.Name, $_.Count) -ForegroundColor Yellow
    }

    Write-Host 'Cerrar navegadores puede descartar formularios o sesiones no guardadas.' -ForegroundColor Yellow
    if (-not (Confirm-CleanAction -Message 'Cerrar estos navegadores')) {
        Write-Host 'Acción cancelada.' -ForegroundColor Gray
        return
    }

    $closed = 0
    $failed = 0
    foreach ($process in $processes) {
        if ($PSCmdlet.ShouldProcess($process.ProcessName, 'Cerrar proceso')) {
            try {
                Stop-Process -Id $process.Id -Force -ErrorAction Stop
                $closed++
            } catch {
                Write-Warning "No se pudo cerrar $($process.ProcessName) [$($process.Id)]: $($_.Exception.Message)"
                $failed++
            }
        }
    }

    Write-Host ("Resumen: {0} proceso(s) cerrados; {1} fallidos." -f $closed, $failed) -ForegroundColor Green
}

function Disable-OptionalService {
    <#
    .SYNOPSIS
        Detiene y deshabilita servicios opcionales conocidos previa confirmación.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    Write-Host ''
    Write-Host '== Desactivar servicios opcionales ==' -ForegroundColor Cyan
    if (-not (Assert-Administrator -Operation 'Desactivar servicios')) {
        return
    }

    $serviceDefinitions = @(
        @{ Name = 'DiagTrack'; Description = 'Telemetría y experiencias de usuario conectado' },
        @{ Name = 'dmwappushservice'; Description = 'Enrutamiento de mensajes WAP; puede no existir' }
    )

    $changed = 0
    $skipped = 0

    foreach ($definition in $serviceDefinitions) {
        $service = Get-Service -Name $definition.Name -ErrorAction SilentlyContinue
        if ($null -eq $service) {
            Write-Host "$($definition.Name): no está instalado." -ForegroundColor DarkGray
            continue
        }

        $startMode = 'No disponible'
        try {
            $startMode = (Get-CimInstance Win32_Service -Filter "Name='$($definition.Name)'" -ErrorAction Stop).StartMode
        } catch {
            Write-Verbose "No se pudo consultar modo de inicio de $($definition.Name): $($_.Exception.Message)"
        }

        Write-Host ''
        Write-Host "$($definition.Name) - $($definition.Description)" -ForegroundColor Yellow
        Write-Host "Estado: $($service.Status) | Inicio: $startMode" -ForegroundColor Gray

        if (-not (Confirm-CleanAction -Message "Detener y deshabilitar $($definition.Name)")) {
            $skipped++
            continue
        }

        if ($PSCmdlet.ShouldProcess($definition.Name, 'Detener y deshabilitar servicio')) {
            try {
                if ($service.Status -ne 'Stopped') {
                    Stop-Service -Name $definition.Name -Force -ErrorAction Stop
                }
                Set-Service -Name $definition.Name -StartupType Disabled -ErrorAction Stop
                Write-Host "$($definition.Name) deshabilitado." -ForegroundColor Green
                $changed++
            } catch {
                Write-Warning "$($definition.Name): $($_.Exception.Message)"
            }
        }
    }

    Write-Host ("Resumen: {0} servicio(s) cambiados; {1} omitidos." -f $changed, $skipped) -ForegroundColor Green
}

function Get-PythonCommand {
    <#
    .SYNOPSIS
        Detecta una instalación real de Python 3 evitando alias de WindowsApps.
    #>
    [CmdletBinding()]
    param()

    $candidates = @()
    $python = Get-Command python.exe -ErrorAction SilentlyContinue
    if ($python) { $candidates += $python.Source }
    $python3 = Get-Command python3.exe -ErrorAction SilentlyContinue
    if ($python3) { $candidates += $python3.Source }

    try {
        $candidates += (& py.exe -0p 2>$null | ForEach-Object { ($_ -replace '^\s*-V:\S+\s+', '').Trim() })
    } catch {
        Write-Verbose "py.exe no disponible: $($_.Exception.Message)"
    }

    $candidates = @(
        $candidates |
            Where-Object { $_ -and (Test-Path -LiteralPath $_) -and ($_ -notmatch '\\WindowsApps\\') } |
            Select-Object -Unique
    )

    foreach ($candidate in $candidates) {
        try {
            $version = (& $candidate --version 2>&1 | Select-Object -First 1)
            if ($LASTEXITCODE -eq 0 -and $version -match '^Python 3\.') {
                return [pscustomobject]@{ Path = $candidate; Version = [string]$version }
            }
        } catch {
            Write-Verbose "Python candidato inválido '$candidate': $($_.Exception.Message)"
        }
    }

    return $null
}

function Repair-PythonConfiguration {
    <#
    .SYNOPSIS
        Prioriza Python 3 real en PATH de usuario y verifica pip.
    #>
    [CmdletBinding()]
    param()

    Write-Host ''
    Write-Host '== Reparar Python ==' -ForegroundColor Cyan
    $python = Get-PythonCommand
    if ($null -eq $python) {
        Write-Host 'No se encontró una instalación real de Python 3.' -ForegroundColor Yellow
        return
    }

    $root = Split-Path -Parent $python.Path
    $scripts = Join-Path $root 'Scripts'
    Write-Host "Detectado: $($python.Version) en $($python.Path)" -ForegroundColor Gray

    $entries = @(Split-PathVariable -Value ([Environment]::GetEnvironmentVariable('Path', 'User')))
    $newEntries = @(Get-UniquePathEntry -Entry (@($root, $scripts) + $entries))

    if (-not (Confirm-CleanAction -Message 'Crear backup, priorizar esta instalación en PATH de usuario y verificar pip')) {
        Write-Host 'Acción cancelada.' -ForegroundColor Gray
        return
    }

    try {
        $backup = Backup-EnvironmentPath
        [Environment]::SetEnvironmentVariable('Path', ($newEntries -join ';'), 'User')
        $env:Path = "$root;$scripts;$env:Path"

        & $python.Path -m ensurepip --upgrade
        if ($LASTEXITCODE -ne 0) {
            throw "ensurepip terminó con código $LASTEXITCODE"
        }

        $pipVersion = (& $python.Path -m pip --version 2>&1 | Select-Object -First 1)
        Write-Host "Python priorizado y pip verificado: $pipVersion" -ForegroundColor Green
        Write-Host "Backup: $backup" -ForegroundColor DarkGray
    } catch {
        Write-Warning "No se pudo completar la reparación de Python: $($_.Exception.Message)"
    }
}

function Get-DiskInventory {
    <#
    .SYNOPSIS
        Obtiene discos físicos y tipo de medio.
    #>
    [CmdletBinding()]
    param()

    $items = @()

    try {
        $searcher = [System.Management.ManagementObjectSearcher]::new('SELECT Index, Model, MediaType, Size FROM Win32_DiskDrive')
        foreach ($disk in @($searcher.Get())) {
            $label = "{0} {1}" -f $disk.Model, $disk.MediaType
            $media = if ($label -match 'SSD|NVMe|Solid State') { 'SSD' } elseif ($label -match 'HDD|Hard Disk|Fixed hard disk') { 'HDD' } else { 'Desconocido' }
            $items += [pscustomobject]@{
                Number = [string]$disk.Index
                Model = [string]$disk.Model
                MediaType = $media
                Size = [double]$disk.Size
            }
        }
    } catch {
        Write-Warning "No se pudo consultar Win32_DiskDrive: $($_.Exception.Message)"
    }

    return $items
}

function Show-DiskInventory {
    <#
    .SYNOPSIS
        Muestra inventario de discos SSD/HDD.
    #>
    [CmdletBinding()]
    param()

    Write-Operation '== Inventario de discos =='
    $disks = @(Get-DiskInventory)
    if ($disks.Count -eq 0) {
        Write-Warning 'No se detectaron discos físicos.'
        return
    }

    $disks |
        Select-Object @{N='Disco';E={$_.Number}}, @{N='Modelo';E={$_.Model}}, @{N='Tipo';E={$_.MediaType}}, @{N='Tamaño';E={Format-ByteSize $_.Size}} |
        Format-Table -AutoSize

    if ($disks.MediaType -contains 'Desconocido') {
        Write-Warning 'No se asumirá que un disco desconocido es HDD.'
    }
}

function Get-DriveMediaType {
    <#
    .SYNOPSIS
        Devuelve el tipo de medio de la unidad indicada.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z]$')]
        [string]$DriveLetter
    )

    $partition = Get-Partition -DriveLetter $DriveLetter -ErrorAction Stop
    $disk = Get-Disk -Number $partition.DiskNumber -ErrorAction Stop
    $physical = @(Get-DiskInventory | Where-Object { $_.Number -eq [string]$disk.Number }) | Select-Object -First 1
    if ($null -eq $physical) {
        return 'Desconocido'
    }

    return $physical.MediaType
}

function Invoke-HddDefrag {
    <#
    .SYNOPSIS
        Ejecuta defrag.exe solo cuando la unidad se confirma como HDD.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [ValidatePattern('^[A-Za-z]$')]
        [string]$DriveLetter = 'C'
    )

    Write-Operation '== Desfragmentación segura de HDD =='
    if (-not (Assert-Administrator -Operation 'Desfragmentar disco')) {
        return
    }

    $letter = $DriveLetter.ToUpperInvariant()
    $media = Get-DriveMediaType -DriveLetter $letter
    Write-Operation "Unidad $letter`: detectada como $media."

    if ($media -eq 'SSD') {
        Write-Warning 'Acción bloqueada: no se desfragmentan SSD desde esta herramienta.'
        return
    }

    if ($media -ne 'HDD') {
        Write-Warning 'Acción bloqueada: no se pudo confirmar que la unidad sea HDD.'
        return
    }

    $defrag = Join-Path $env:WINDIR 'System32\defrag.exe'
    if ($PSCmdlet.ShouldProcess("$letter`:", 'defrag.exe /U /V')) {
        & $defrag "$letter`:" /U /V
        if ($LASTEXITCODE -ne 0) {
            throw "defrag.exe terminó con código $LASTEXITCODE."
        }
    }
}

function Split-PathVariable {
    <#
    .SYNOPSIS
        Divide una variable PATH en entradas no vacías.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return @()
    }

    return @($Value -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Get-UniquePathEntry {
    <#
    .SYNOPSIS
        Quita duplicados exactos de PATH conservando orden.
    #>
    [CmdletBinding()]
    param(
        [string[]]$Entry
    )

    $seen = @{}
    $result = @()
    foreach ($item in $Entry) {
        $key = $item.TrimEnd('\').ToLowerInvariant()
        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            $result += $item
        }
    }

    return $result
}

function Backup-EnvironmentPath {
    <#
    .SYNOPSIS
        Crea backup del PATH de usuario y máquina.
    #>
    [CmdletBinding()]
    param()

    $backupDir = Join-Path $script:ToolRoot 'backups'
    if (-not (Test-Path -LiteralPath $backupDir)) {
        [void](New-Item -ItemType Directory -Path $backupDir -Force)
    }

    $backupFile = Join-Path $backupDir ("PATH-backup-{0}.txt" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    @(
        '# Clean Windows - PATH backup'
        "# Date: $(Get-Date -Format o)"
        "USER=$([Environment]::GetEnvironmentVariable('Path', 'User'))"
        "MACHINE=$([Environment]::GetEnvironmentVariable('Path', 'Machine'))"
    ) | Set-Content -LiteralPath $backupFile -Encoding UTF8

    return $backupFile
}

function Repair-EnvironmentPath {
    <#
    .SYNOPSIS
        Normaliza PATH quitando vacíos y duplicados exactos; conserva rutas inexistentes.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    Write-Operation '== Reparación conservadora de PATH =='
    $allowedScopes = @('User')
    if (Test-Administrator) {
        $allowedScopes += 'Machine'
    } else {
        Write-Warning 'Sin elevación solo se modificará PATH de usuario; PATH de máquina se auditará.'
    }

    $plan = @()
    $duplicateCount = 0

    foreach ($scope in @('User', 'Machine')) {
        $raw = [Environment]::GetEnvironmentVariable('Path', $scope)
        $entries = @(Split-PathVariable -Value $raw)
        $unique = @(Get-UniquePathEntry -Entry $entries)
        $duplicates = $entries.Count - $unique.Count
        $missing = @($unique | Where-Object { -not (Test-Path -LiteralPath ([Environment]::ExpandEnvironmentVariables($_))) })
        $duplicateCount += $duplicates

        Write-Operation ("{0} PATH: {1} entradas, {2} duplicadas, {3} no verificables." -f $scope, $entries.Count, $duplicates, $missing.Count)
        $missing | ForEach-Object { Write-Verbose "Ruta no verificable conservada: $_" }

        $plan += [pscustomobject]@{
            Scope = $scope
            Entries = $unique
            Duplicates = $duplicates
        }
    }

    if ($duplicateCount -eq 0) {
        Write-Operation 'PATH ya está normalizado.'
        return
    }

    if (-not (Confirm-CleanAction -Message "Crear backup y quitar $duplicateCount duplicado(s) de los ámbitos permitidos")) {
        Write-Operation 'Reparación de PATH cancelada.'
        return
    }

    $backup = Backup-EnvironmentPath
    foreach ($item in $plan | Where-Object { $_.Scope -in $allowedScopes -and $_.Duplicates -gt 0 }) {
        if ($PSCmdlet.ShouldProcess("$($item.Scope) PATH", 'Quitar entradas duplicadas exactas')) {
            [Environment]::SetEnvironmentVariable('Path', ($item.Entries -join ';'), $item.Scope)
        }
    }

    $env:Path = @(
        [Environment]::GetEnvironmentVariable('Path', 'Machine')
        [Environment]::GetEnvironmentVariable('Path', 'User')
    ) -join ';'

    Write-Operation "Backup creado: $backup"
}

function Get-SystemSnapshot {
    <#
    .SYNOPSIS
        Obtiene información básica del sistema.
    #>
    [CmdletBinding()]
    param()

    $windows = [Environment]::OSVersion.VersionString
    $architecture = $env:PROCESSOR_ARCHITECTURE
    $cpuName = $env:PROCESSOR_IDENTIFIER
    $ramTotal = 'No disponible'
    $diskType = 'Desconocido'

    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $windows = "$($os.Caption) build $($os.BuildNumber)"
        $architecture = $os.OSArchitecture
    } catch {
        Write-Verbose "No se pudo consultar Win32_OperatingSystem: $($_.Exception.Message)"
    }

    try {
        $cpu = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1
        if ($cpu.Name) {
            $cpuName = $cpu.Name
        }
    } catch {
        try {
            $cpuName = (Get-ItemProperty 'HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\0' -ErrorAction Stop).ProcessorNameString.Trim()
        } catch {
            Write-Verbose "No se pudo consultar CPU: $($_.Exception.Message)"
        }
    }

    try {
        $computer = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        $ramTotal = Format-ByteSize ([double]$computer.TotalPhysicalMemory)
    } catch {
        Write-Verbose "No se pudo consultar RAM: $($_.Exception.Message)"
    }

    try {
        $firstDisk = @(Get-DiskInventory | Where-Object { $_.MediaType -in @('SSD', 'HDD') } | Select-Object -First 1)
        if ($firstDisk.Count -gt 0) {
            $diskType = $firstDisk[0].MediaType
        }
    } catch {
        Write-Verbose "No se pudo consultar tipo de disco: $($_.Exception.Message)"
    }

    [pscustomobject][ordered]@{
        OS = $windows
        CPU = $cpuName
        RAM = $ramTotal
        'Tipo de Disco' = $diskType
        Usuario = $env:USERNAME
        Arquitectura = $architecture
        FechaHora = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        Administrador = if (Test-Administrator) { 'Sí' } else { 'No' }
    }
}

function Limit-Text {
    <#
    .SYNOPSIS
        Recorta texto para mantener la alineación de la TUI.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$Text,

        [Parameter(Mandatory)]
        [int]$Width
    )

    if ($null -eq $Text) {
        $Text = ''
    }

    if ($Width -le 3) {
        return $Text.Substring(0, [Math]::Min($Text.Length, $Width))
    }

    if ($Text.Length -le $Width) {
        return $Text
    }

    return ($Text.Substring(0, $Width - 3) + '...')
}

function New-PanelLine {
    <#
    .SYNOPSIS
        Construye una línea de panel de ancho fijo.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Text,

        [Parameter(Mandatory)]
        [int]$Width
    )

    $innerWidth = $Width - 4
    $content = Limit-Text -Text $Text -Width $innerWidth
    return '| ' + $content.PadRight($innerWidth) + ' |'
}

function New-PanelRule {
    <#
    .SYNOPSIS
        Construye borde superior, inferior o título de panel.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int]$Width,

        [string]$Title
    )

    $inner = $Width - 2
    if ([string]::IsNullOrWhiteSpace($Title)) {
        return '+' + ('-' * $inner) + '+'
    }

    $caption = " $Title "
    if ($caption.Length -gt $inner) {
        $caption = Limit-Text -Text $caption -Width $inner
    }

    $remaining = $inner - $caption.Length
    $left = [Math]::Floor($remaining / 2)
    $right = $remaining - $left
    return '+' + ('-' * $left) + $caption + ('-' * $right) + '+'
}

function Write-TuiRow {
    <#
    .SYNOPSIS
        Escribe una fila compuesta por panel izquierdo y derecho.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Left,

        [Parameter(Mandatory)]
        [string]$Right,

        [ConsoleColor]$LeftColor = [ConsoleColor]::Cyan,
        [ConsoleColor]$RightColor = [ConsoleColor]::Gray
    )

    Write-Host '  ' -NoNewline
    Write-Host $Left -ForegroundColor $LeftColor -NoNewline
    Write-Host '  ' -NoNewline
    Write-Host $Right -ForegroundColor $RightColor
}

function Show-Menu {
    <#
    .SYNOPSIS
        Muestra la interfaz visual interactiva por consola.
    #>
    [CmdletBinding()]
    param()

$running = $true
    while ($running) {
        Clear-Host
        $snapshot = Get-SystemSnapshot
        $leftWidth = 42
        $rightWidth = 68

        $banner = @'
   ______ _      ______          _   _   __          ___           _
  / _____| |    |  ____|   /\   | \ | |  \ \        / (_)         | |
 | |     | |    | |__     /  \  |  \| |   \ \  /\  / / _ _ __   __| | _____      _____
 | |     | |    |  __|   / /\ \ | . ` |    \ \/  \/ / | | '_ \ / _` |/ _ \ \ /\ / / __|
 | |____ | |____| |____ / ____ \| |\  |     \  /\  /  | | | | | (_| | (_) \ V  V /\__ \
  \_____|______|______/_/    \_\_| \_|      \/  \/   |_|_| |_|\__,_|\___/ \_/\_/ |___/
'@

        Write-Host ''
        Write-Host $banner -ForegroundColor White -BackgroundColor Black
        Write-Host ''
        Write-Host '  CLEAN WINDOWS' -ForegroundColor Cyan
        Write-Host ''

        $leftPanel = @(
            New-PanelRule -Width $leftWidth -Title 'MENÚ PRINCIPAL'
            New-PanelLine -Width $leftWidth -Text '[1] Limpieza de Temporales'
            New-PanelLine -Width $leftWidth -Text '[2] Liberar Memoria'
            New-PanelLine -Width $leftWidth -Text '[3] Detectar Disco'
            New-PanelLine -Width $leftWidth -Text '[4] Desfragmentar HDD'
            New-PanelLine -Width $leftWidth -Text '[5] Desactivar Servicios'
            New-PanelLine -Width $leftWidth -Text '[6] Reparar PATH'
            New-PanelLine -Width $leftWidth -Text '[7] Reparar Python'
            New-PanelLine -Width $leftWidth -Text '[8] Mostrar Info del Sistema'
            New-PanelLine -Width $leftWidth -Text '[0] Salir'
            New-PanelRule -Width $leftWidth
        )

        $rightPanel = @(
            New-PanelRule -Width $rightWidth -Title 'INFORMACIÓN DEL SISTEMA'
            New-PanelLine -Width $rightWidth -Text "OS: $($snapshot.OS)"
            New-PanelLine -Width $rightWidth -Text "CPU: $($snapshot.CPU)"
            New-PanelLine -Width $rightWidth -Text "RAM: $($snapshot.RAM)"
            New-PanelLine -Width $rightWidth -Text "Tipo de Disco: $($snapshot.'Tipo de Disco')"
            New-PanelLine -Width $rightWidth -Text "Usuario actual: $($snapshot.Usuario)"
            New-PanelLine -Width $rightWidth -Text "Fecha/Hora: $($snapshot.FechaHora)"
            New-PanelLine -Width $rightWidth -Text "Administrador: $($snapshot.Administrador)"
            New-PanelRule -Width $rightWidth
            New-PanelRule -Width $rightWidth -Title 'ADVERTENCIA'
            New-PanelLine -Width $rightWidth -Text 'Ejecuta como Administrador para limpieza completa.'
            New-PanelLine -Width $rightWidth -Text 'DISM, servicios, Windows Temp y defrag requieren elevación.'
            New-PanelRule -Width $rightWidth
        )

        $rowCount = [Math]::Max($leftPanel.Count, $rightPanel.Count)
        for ($i = 0; $i -lt $rowCount; $i++) {
            $left = if ($i -lt $leftPanel.Count) { $leftPanel[$i] } else { ' ' * $leftWidth }
            $right = if ($i -lt $rightPanel.Count) { $rightPanel[$i] } else { ' ' * $rightWidth }
            $rightColor = if ($i -ge 8) { [ConsoleColor]::Yellow } else { [ConsoleColor]::Gray }
            Write-TuiRow -Left $left -Right $right -LeftColor Cyan -RightColor $rightColor
        }

        Write-Host ''
        Write-Host '  Selecciona una opcion: ' -ForegroundColor Green -NoNewline
        $choice = Read-Host
        if ([string]::IsNullOrWhiteSpace($choice) -and [Console]::IsInputRedirected) {
            $running = $false
            continue
        }

        try {
            switch ($choice) {
                '1' {
                    Invoke-TemporaryFileCleanup -OlderThanDays $OlderThanDays -WhatIf:$WhatIfPreference
                    Invoke-Windows11CacheCleanup -OlderThanDays $OlderThanDays -WhatIf:$WhatIfPreference
                    Invoke-DeliveryOptimizationCleanup -WhatIf:$WhatIfPreference
                    Invoke-RecycleBinCleanup -WhatIf:$WhatIfPreference
                }
                '2' { Invoke-BrowserMemoryCleanup -WhatIf:$WhatIfPreference }
                '3' { Show-DiskInventory }
                '4' { Invoke-HddDefrag -DriveLetter $DriveLetter -WhatIf:$WhatIfPreference }
                '5' { Disable-OptionalService -WhatIf:$WhatIfPreference }
                '6' { Repair-EnvironmentPath -WhatIf:$WhatIfPreference }
                '7' { Repair-PythonConfiguration }
                '8' { Get-SystemSnapshot | Format-List }
                '0' { $running = $false }
                default { Write-Warning 'Opción inválida.' }
            }
        } catch {
            Write-Error "Error en la tarea: $($_.Exception.Message)"
        }

        if ($running) {
            [void](Read-Host 'Presiona Enter para continuar')
        }
    }
}

function Invoke-WindowsClean {
    <#
    .SYNOPSIS
        Orquesta tareas de mantenimiento seguro para Windows 11.

    .DESCRIPTION
        Ejecuta una o más tareas de limpieza y mantenimiento. Las tareas de sistema
        validan elevación antes de ejecutarse y las limpiezas manuales evitan puntos
        de reanálisis, archivos recientes y archivos bloqueados.

    .PARAMETER Task
        Lista de tareas a ejecutar.

    .PARAMETER OlderThanDays
        Antigüedad mínima para limpiezas manuales.

    .PARAMETER DriveLetter
        Unidad a evaluar para DefragHdd.

    .PARAMETER Force
        Omite confirmaciones interactivas.
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [ValidateSet(
            'All',
            'TemporaryFiles',
            'Win11Caches',
            'DeliveryOptimization',
            'WindowsComponents',
            'RecycleBin',
            'DiskInfo',
            'DefragHdd',
            'Path',
            'Memory',
            'Services',
            'Python'
        )]
        [string[]]$Task = @('All'),

        [ValidateRange(0, 3650)]
        [int]$OlderThanDays = 1,

        [ValidatePattern('^[A-Za-z]$')]
        [string]$DriveLetter = 'C',

        [switch]$Force
    )

    $expandedTask = if ($Task -contains 'All') {
        @('TemporaryFiles', 'Win11Caches', 'DeliveryOptimization', 'WindowsComponents', 'RecycleBin', 'DiskInfo')
    } else {
        $Task
    }

    if (-not $Force -and -not (Confirm-CleanAction -Message "Ejecutar tareas: $($expandedTask -join ', ')")) {
        Write-Operation 'Ejecución cancelada.'
        return
    }

    foreach ($item in $expandedTask) {
        try {
            switch ($item) {
                'TemporaryFiles' { Invoke-TemporaryFileCleanup -OlderThanDays $OlderThanDays -WhatIf:$WhatIfPreference }
                'Win11Caches' { Invoke-Windows11CacheCleanup -OlderThanDays $OlderThanDays -WhatIf:$WhatIfPreference }
                'DeliveryOptimization' { Invoke-DeliveryOptimizationCleanup -WhatIf:$WhatIfPreference }
                'WindowsComponents' { Invoke-WindowsComponentCleanup -WhatIf:$WhatIfPreference }
                'RecycleBin' { Invoke-RecycleBinCleanup -WhatIf:$WhatIfPreference }
                'DiskInfo' { Show-DiskInventory }
                'DefragHdd' { Invoke-HddDefrag -DriveLetter $DriveLetter -WhatIf:$WhatIfPreference }
                'Path' { Repair-EnvironmentPath -WhatIf:$WhatIfPreference }
                'Memory' { Invoke-BrowserMemoryCleanup -WhatIf:$WhatIfPreference }
                'Services' { Disable-OptionalService -WhatIf:$WhatIfPreference }
                'Python' { Repair-PythonConfiguration }
            }
        } catch {
            Write-Error "La tarea '$item' falló: $($_.Exception.Message)"
        }
    }
}

if ($Menu) {
    Request-AdministratorRelaunch
    Show-Menu
} elseif ($Task -and $Task.Count -gt 0) {
    Invoke-WindowsClean -Task $Task -OlderThanDays $OlderThanDays -DriveLetter $DriveLetter -Force:$Force -WhatIf:$WhatIfPreference
} else {
    Request-AdministratorRelaunch
    Show-Menu
}
