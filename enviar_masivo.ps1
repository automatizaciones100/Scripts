# ============================================
# ENVIO MASIVO DE PLANTILLAS - INDURETROS
# Version multi-pais (detecta codigo de pais por prefijo)
# ============================================

# CONFIGURACION
# La API key se lee de la variable de entorno GUPSHUP_API_KEY.
# NUNCA se escribe en este archivo: esta carpeta esta sincronizada con OneDrive corporativo.
#   [Environment]::SetEnvironmentVariable("GUPSHUP_API_KEY","<tu_key>","User")
$API_KEY        = $env:GUPSHUP_API_KEY
if ([string]::IsNullOrWhiteSpace($API_KEY)) {
    Write-Host "ERROR: No se encontro la variable de entorno GUPSHUP_API_KEY" -ForegroundColor Red
    Write-Host 'Configurala con: [Environment]::SetEnvironmentVariable("GUPSHUP_API_KEY","tu_key","User")' -ForegroundColor Red
    exit 1
}
$SOURCE         = "573007192973"
$APP_NAME       = "Induretrosline2"
$TEMPLATE_ID    = "3fbc53b4-b973-4abf-b68a-809246d59166"
$CSV_INPUT      = "masivo_06_10_2026.csv"
$DELAY_SEGUNDOS = 1

# Si un numero viene SIN codigo de pais (10 digitos empezando por 3),
# se asume este pais por defecto. Cambialo si tu lista por defecto no es Colombia.
$PAIS_DEFAULT_CODIGO = "57"
$PAIS_DEFAULT_NOMBRE = "Colombia"

# ============================================
# TABLA DE PAISES (prefijo telefonico -> nombre)
# Ordenada de prefijo mas largo a mas corto para no confundir
# (ej. 593 Ecuador antes que 59, o 1 EEUU al final).
# ============================================
$PAISES = [ordered]@{
    "593" = "Ecuador"
    "591" = "Bolivia"
    "598" = "Uruguay"
    "595" = "Paraguay"
    "507" = "Panama"
    "506" = "Costa Rica"
    "502" = "Guatemala"
    "504" = "Honduras"
    "503" = "El Salvador"
    "505" = "Nicaragua"
    "971" = "Emiratos Arabes"
    "57"  = "Colombia"
    "58"  = "Venezuela"
    "51"  = "Peru"
    "52"  = "Mexico"
    "56"  = "Chile"
    "55"  = "Brasil"
    "54"  = "Argentina"
    "34"  = "Espana"
    "39"  = "Italia"
    "44"  = "Reino Unido"
    "86"  = "China"
    "90"  = "Turquia"
    "1"   = "EEUU/Canada"
}

# ============================================
# FUNCION: identifica pais y normaliza a formato internacional
# Devuelve un objeto con Destino (solo digitos), Codigo y Pais.
# Si no logra identificar el pais, Pais = "DESCONOCIDO".
# ============================================
function Get-InfoPais {
    param([string]$Numero)

    # 1) dejar solo digitos
    $d = ($Numero -replace '\D', '')

    # 2) quitar el prefijo internacional 00 si viene (ej. 0057...)
    if ($d.StartsWith("00")) { $d = $d.Substring(2) }

    # 3) caso sin codigo de pais: 10 digitos que empiezan por 3 -> movil del pais por defecto
    if ($d.Length -eq 10 -and $d.StartsWith("3")) {
        return [PSCustomObject]@{
            Destino = "$PAIS_DEFAULT_CODIGO$d"
            Codigo  = $PAIS_DEFAULT_CODIGO
            Pais    = $PAIS_DEFAULT_NOMBRE
        }
    }

    # 4) buscar el codigo de pais por prefijo (la tabla ya esta ordenada larga->corta)
    foreach ($cc in $PAISES.Keys) {
        if ($d.StartsWith($cc)) {
            $nacional = $d.Substring($cc.Length)
            # validacion minima: que quede un numero nacional con longitud razonable
            if ($nacional.Length -ge 7 -and $nacional.Length -le 11) {
                return [PSCustomObject]@{
                    Destino = $d
                    Codigo  = $cc
                    Pais    = $PAISES[$cc]
                }
            }
        }
    }

    # 5) no identificado
    return [PSCustomObject]@{
        Destino = $d
        Codigo  = ""
        Pais    = "DESCONOCIDO"
    }
}

# ============================================
# NO MODIFICAR DEBAJO DE ESTA LINEA
# ============================================

if (-not (Test-Path $CSV_INPUT)) {
    Write-Host "ERROR: No se encuentra el archivo $CSV_INPUT" -ForegroundColor Red
    Write-Host "Asegurate de que este en la misma carpeta que este script" -ForegroundColor Red
    exit
}

$contactos = Import-Csv -Path $CSV_INPUT -Encoding UTF8
$total = $contactos.Count

# Conteo previo por pais (para que sepas a donde vas a enviar antes de confirmar)
$resumenPais = @{}
$desconocidos = 0
foreach ($c in $contactos) {
    $info = Get-InfoPais $c.numero
    if ($info.Pais -eq "DESCONOCIDO") { $desconocidos++ }
    if ($resumenPais.ContainsKey($info.Pais)) { $resumenPais[$info.Pais]++ } else { $resumenPais[$info.Pais] = 1 }
}

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "ENVIO MASIVO DE PLANTILLAS (multi-pais)" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "Total contactos: $total"
Write-Host "Plantilla ID: $TEMPLATE_ID"
Write-Host "Origen: $SOURCE"
Write-Host "Delay entre envios: $DELAY_SEGUNDOS segundos"
Write-Host ""
Write-Host "Distribucion por pais:" -ForegroundColor Cyan
foreach ($p in ($resumenPais.GetEnumerator() | Sort-Object Value -Descending)) {
    $color = if ($p.Key -eq "DESCONOCIDO") { "Red" } else { "Gray" }
    Write-Host ("  {0,-18} {1}" -f $p.Key, $p.Value) -ForegroundColor $color
}
if ($desconocidos -gt 0) {
    Write-Host ""
    Write-Host "AVISO: $desconocidos numero(s) sin pais identificado. Esos se OMITIRAN." -ForegroundColor Yellow
}
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

$confirm = Read-Host "Continuar con el envio? (S/N)"
if ($confirm -ne "S" -and $confirm -ne "s") {
    Write-Host "Envio cancelado" -ForegroundColor Yellow
    exit
}

Write-Host ""
Write-Host "Iniciando envios..." -ForegroundColor Green
Write-Host ""

$resultados = @()
$contador = 0
$exitosos = 0
$fallidos = 0
$omitidos = 0

foreach ($contacto in $contactos) {
    $contador++
    $numeroOriginal = $contacto.numero
    $nombre = $contacto.nombre

    $info    = Get-InfoPais $numeroOriginal
    $destino = $info.Destino
    $pais    = $info.Pais
    $codigo  = $info.Codigo

    Write-Progress -Activity "Enviando campana" -Status "[$contador/$total] $nombre - $destino ($pais)" -PercentComplete (($contador / $total) * 100)

    Write-Host "[$contador/$total] " -NoNewline
    Write-Host "$nombre " -NoNewline -ForegroundColor White
    Write-Host "($destino) [$pais]..." -NoNewline

    # Si no se identifico el pais, se omite el envio (evita gastar plantillas en numeros malos)
    if ($pais -eq "DESCONOCIDO") {
        Write-Host " OMITIDO (pais no identificado)" -ForegroundColor Yellow
        $omitidos++
        $resultados += [PSCustomObject]@{
            Numero    = $numeroOriginal
            Destino   = $destino
            Pais      = $pais
            Codigo    = $codigo
            Nombre    = $nombre
            Status    = "omitido"
            MessageID = "-"
            Error     = "Pais no identificado"
            Fecha     = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        }
        continue
    }

    $body = @{
        source = $SOURCE
        destination = $destino
        "src.name" = $APP_NAME
        template = "{`"id`":`"$TEMPLATE_ID`",`"params`":[]}"
    }

    try {
        $response = Invoke-RestMethod -Uri 'https://api.gupshup.io/wa/api/v1/template/msg' `
            -Method POST `
            -Headers @{"apikey" = $API_KEY} `
            -Body $body `
            -TimeoutSec 15

        Write-Host " OK" -ForegroundColor Green
        $exitosos++

        $resultados += [PSCustomObject]@{
            Numero    = $numeroOriginal
            Destino   = $destino
            Pais      = $pais
            Codigo    = $codigo
            Nombre    = $nombre
            Status    = $response.status
            MessageID = $response.messageId
            Error     = ""
            Fecha     = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        }
    } catch {
        Write-Host " FALLO: $_" -ForegroundColor Red
        $fallidos++

        $resultados += [PSCustomObject]@{
            Numero    = $numeroOriginal
            Destino   = $destino
            Pais      = $pais
            Codigo    = $codigo
            Nombre    = $nombre
            Status    = "error"
            MessageID = "-"
            Error     = $_.Exception.Message
            Fecha     = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        }
    }

    Start-Sleep -Seconds $DELAY_SEGUNDOS
}

Write-Progress -Activity "Enviando campana" -Completed

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$reportFile = "reporte_envio_$timestamp.csv"
$resultados | Export-Csv -Path $reportFile -NoTypeInformation -Encoding UTF8

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "RESUMEN FINAL" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "Total procesados: $contador"
Write-Host "Exitosos:         $exitosos" -ForegroundColor Green
Write-Host "Fallidos:         $fallidos" -ForegroundColor Red
Write-Host "Omitidos:         $omitidos" -ForegroundColor Yellow
Write-Host "Reporte:          $reportFile"
Write-Host "============================================" -ForegroundColor Cyan
