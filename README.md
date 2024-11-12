# Optimización del Equipo

Este script automatiza una serie de pasos para optimizar un equipo con Windows, liberando espacio y mejorando el rendimiento. Detecta el tipo de disco (HDD o SSD), limpia archivos temporales, libera memoria y desactiva servicios innecesarios.

## Características

- **Limpieza de Archivos Temporales**: Elimina archivos temporales en el sistema y en la carpeta de usuario para liberar espacio.
- **Detección de Disco**: Identifica si el disco es SSD o HDD. Si es HDD, realiza una desfragmentación.
- **Liberación de Memoria**: Cierra automáticamente procesos de navegadores (Chrome, Firefox y Edge) para liberar memoria.
- **Desactivación de Servicios**: Deshabilita servicios innecesarios (`DiagTrack` y `dmwappushservice`) para mejorar el rendimiento.

## Requisitos

- **Sistema Operativo**: Windows
- **Permisos de Administrador**: El script requiere permisos de administrador para modificar servicios y eliminar archivos del sistema.

## Uso

1. Descarga el script o clona el repositorio.
2. Ejecuta el archivo `OptimizaciónEquipo.bat` como administrador.
3. Sigue las instrucciones en pantalla.

## Nota

- **Desfragmentación de SSD**: Este script evita desfragmentar discos SSD para preservar su vida útil, ya que no es necesario realizar desfragmentación en discos sólidos.

## Contribución

Si tienes sugerencias o mejoras, eres bienvenido a abrir un issue o realizar un pull request.

## Licencia

Este proyecto está bajo la licencia MIT.
