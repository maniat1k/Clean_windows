# Backup primero
$backup = [Environment]::GetEnvironmentVariable("Path","User")
Set-Content "$env:USERPROFILE\Desktop\PATH_usuario_BACKUP_$(Get-Date -Format yyyyMMdd_HHmmss).txt" $backup

# Nuevo PATH limpio
$newPath = @(
  "C:\Users\mania\AppData\Local\Programs\Python\Python312",
  "C:\Users\mania\AppData\Local\Programs\Python\Python312\Scripts",
  "C:\Program Files\WindowsApps\Microsoft.DesktopAppInstaller_1.26.430.0_x64__8wekyb3d8bbwe",
  "C:\Program Files\PowerShell\7",
  "C:\Program Files\Microsoft\jdk-11.0.16.101-hotspot\bin",
  "C:\Program Files (x86)\Common Files\Oracle\Java\javapath",
  "C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\170\Tools\Binn",
  "C:\Program Files (x86)\Microsoft SQL Server\150\Tools\Binn",
  "C:\Program Files\Microsoft SQL Server\150\Tools\Binn",
  "C:\Program Files\Microsoft SQL Server\150\DTS\Binn",
  "C:\Program Files (x86)\Microsoft SQL Server\150\DTS\Binn",
  "C:\Program Files\PostgreSQL\16\bin",
  "C:\Program Files\dotnet",
  "C:\Program Files (x86)\dotnet",
  "C:\Program Files\PuTTY",
  "C:\Program Files\Docker\Docker\resources",
  "C:\Program Files\WireGuard",
  "C:\Program Files (x86)\GnuPG\bin"
) -join ";"

[Environment]::SetEnvironmentVariable("Path",$newPath,"User")

Write-Host "PATH de usuario actualizado. Cerrá y reabrí PowerShell para aplicar los cambios."
