# ============================================
# ENVIO MASIVO DE PLANTILLAS - INDURETROS
# Version multi-pais + soporte de plantillas con cabecera de MEDIA (imagen/video/documento)
# ============================================

# Fuerza TLS 1.2 (necesario en Windows PowerShell 5.1)
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ============================================
# CONFIGURACION
# ============================================

# La API key se lee de una variable de entorno para no dejarla escrita en el archivo.
# Configurala una sola vez en PowerShell (reemplaza el valor):
#   [Environment]::SetEnvironmentVariable("GUPSHUP_API_KEY","<pega_aqui_tu_key_rotada>","User")
# Luego cierra y vuelve a abrir PowerShell.
$API_KEY = $env:GUPSHUP_API_KEY

$SOURCE         = "573007192973"
$APP_NAME       = "Induretrosline2"

# >>> IMPORTANTE <
# Este UUID debe ser el de la plantilla QUE VAS A ENVIAR HOY.
# Copialo de Gupshup -> Templates -> (tu plantilla) -> ID.
# Si dejas el de una campana anterior, se envia la plantilla vieja.
$TEMPLATE_ID    = "9f3eee34-3d0b-466d-8a98-b9a87b1df778"

# --- CABECERA DE MEDIA ---
# Si la plantilla tiene cabecera de IMAGEN, VIDEO o DOCUMENTO, completa estos campos.
# Si la plantilla es SOLO TEXTO, deja $MEDIA_URL vacio ("").
$MEDIA_URL      = "https://fss.gupshup.io/0/public/0/0/gupshup/573007192973/8a509900-0d96-4ac9-be96-6a375c9cf01b/1785881087989_Feria%20de%20flores%20promo.png"
$MEDIA_TIPO     = "image"          # image | video | document
$MEDIA_FILENAME = "promocion.pdf"  # solo se usa si $MEDIA_TIPO = "document"

# --- PARAMETROS DE LA PLANTILLA ---
# Si el cuerpo de la plantilla tiene variables {{1}}, {{2}}, etc., listalas aqui en orden.
# Ejemplo: $PARAMS = @("Juan", "20%")
# Si la plantilla no tiene variables, dejalo vacio: @()
$PARAMS         = @()

$CSV_INPUT      = "contactos_res_partner_ENVIO.csv"
$DELAY_SEGUNDOS = 1

# Numero de prueba: se envia SOLO a este numero primero para que verifiques
# que llega bien antes de disparar toda la lista. Dejalo vacio ("") para saltar la prueba.
$NUMERO_PRUEBA  = "573124318484"

# Si un numero viene SIN codigo de pais (10 digitos empezando por 3),
# se asume este pais por defecto.
$PAIS_DEFAULT_CODIGO = "57"
$PAIS_DEFAULT_NOMBRE = "Colombia"

# ============================================
# TABLA DE PAISES (prefijo telefonico -> nombre)
# Ordenada de prefijo mas largo a mas corto para no confundir
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
# ============================================
function Get-InfoPais {
    param([string]$Numero)

    $d = ($Numero -replace '\D', '')
    if ($d.StartsWith("00")) { $d = $d.Substring(2) }

    if ($d.Length -eq 10 -and $d.StartsWith("3")) {
        return [PSCustomObject]@{
            Destino = "$PAIS_DEFAULT_CODIGO$d"
            Codigo  = $PAIS_DEFAULT_CODIGO
            Pais    = $PAIS_DEFAULT_NOMBRE
        }
    }

    foreach ($cc in $PAISES.Keys) {
        if ($d.StartsWith($cc)) {
            $nacional = $d.Substring($cc.Length)
            if ($nacional.Length -ge 7 -and $nacional.Length -le 11) {
                return [PSCustomObject]@{
                    Destino = $d
                    Codigo  = $cc
                    Pais    = $PAISES[$cc]
                }
            }
        }
    }

    return [PSCustomObject]@{
        Destino = $d
        Codigo  = ""
        Pais    = "DESCONOCIDO"
    }
}

# ============================================
# FUNCION: construye el JSON de la plantilla
# ============================================
function Build-TemplateJson {
    $partes = @()
    foreach ($p in $PARAMS) {
        $escapado = $p -replace '"', '\"'
        $partes += '"' + $escapado + '"'
    }
    $paramsStr = "[" + ($partes -join ",") + "]"
    return '{"id":"' + $TEMPLATE_ID + '","params":' + $paramsStr + '}'
}

# ============================================
# FUNCION: construye el JSON del media (cabecera)
# Este es el parametro que faltaba y por el cual las plantillas
# con imagen se aceptan pero nunca se entregan.
# ============================================
function Build-MessageJson {
    if ([string]::IsNullOrWhiteSpace($MEDIA_URL)) { return $null }

    switch ($MEDIA_TIPO) {
        "document" {
            return '{"type":"document","document":{"link":"' + $MEDIA_URL + '","filename":"' + $MEDIA_FILENAME + '"}}'
        }
        default {
            return '{"type":"' + $MEDIA_TIPO + '","' + $MEDIA_TIPO + '":{"link":"' + $MEDIA_URL + '"}}'
        }
    }
}

# ============================================
# FUNCION: envia una plantilla a un destino
# ============================================
function Send-Plantilla {
    param([string]$Destino)

    $body = @{
        source        = $SOURCE
        destination   = $Destino
        "src.name"    = $APP_NAME
        template      = Build-TemplateJson
    }

    $msg = Build-MessageJson
    if ($msg) { $body["message"] = $msg }

    return Invoke-RestMethod -Uri 'https://api.gupshup.io/wa/api/v1/template/msg' `
        -Method POST `
        -Headers @{"apikey" = $API_KEY} `
        -Body $body `
        -TimeoutSec 15
}

# ============================================
# FUNCION: extrae el detalle real del error de Gupshup
# ============================================
function Get-DetalleError {
    param($ErrorRecord)
    if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
        return $ErrorRecord.ErrorDetails.Message
    }
    return $ErrorRecord.Exception.Message
}

# ============================================
# NO MODIFICAR DEBAJO DE ESTA LINEA
# ============================================

# --- Validaciones previas ---

if ([string]::IsNullOrWhiteSpace($API_KEY)) {
    Write-Host "ERROR: No se encontro la variable de entorno GUPSHUP_API_KEY" -ForegroundColor Red
    Write-Host 'Configurala con: [Environment]::SetEnvironmentVariable("GUPSHUP_API_KEY","tu_key","User")' -ForegroundColor Red
    Write-Host "Luego cierra y vuelve a abrir PowerShell." -ForegroundColor Red
    exit
}

if ($TEMPLATE_ID -eq "PEGA_AQUI_EL_UUID_DE_LA_PLANTILLA" -or [string]::IsNullOrWhiteSpace($TEMPLATE_ID)) {
    Write-Host "ERROR: Falta configurar TEMPLATE_ID con el UUID de la plantilla." -ForegroundColor Red
    exit
}

if (-not (Test-Path $CSV_INPUT)) {
    Write-Host "ERROR: No se encuentra el archivo $CSV_INPUT" -ForegroundColor Red
    Write-Host "Asegurate de que este en la misma carpeta que este script" -ForegroundColor Red
    exit
}

# Verifica que la URL del media sea accesible publicamente
if (-not [string]::IsNullOrWhiteSpace($MEDIA_URL)) {
    Write-Host "Verificando la URL del media..." -NoNewline
    try {
        $head = Invoke-WebRequest -Uri $MEDIA_URL -Method Head -TimeoutSec 15 -UseBasicParsing
        $tipoContenido = $head.Headers["Content-Type"]
        $tamano = [math]::Round(([int]$head.Headers["Content-Length"]) / 1MB, 2)
        Write-Host " OK ($tipoContenido, $tamano MB)" -ForegroundColor Green

        if ($tipoContenido -like "*text/html*") {
            Write-Host "AVISO: la URL devuelve HTML, no un archivo. Meta la va a rechazar." -ForegroundColor Yellow
            Write-Host "Usa un enlace DIRECTO al archivo (no Drive/Dropbox con vista previa)." -ForegroundColor Yellow
        }
        if ($tamano -gt 5) {
            Write-Host "AVISO: el archivo pesa mas de 5 MB. WhatsApp puede rechazarlo." -ForegroundColor Yellow
        }
    } catch {
        Write-Host " FALLO" -ForegroundColor Red
        Write-Host "No se pudo acceder a $MEDIA_URL" -ForegroundColor Red
        Write-Host "Debe ser HTTPS, publica y sin login. Corrige antes de continuar." -ForegroundColor Red
        exit
    }
}

$contactos = Import-Csv -Path $CSV_INPUT -Encoding UTF8
$total = $contactos.Count

# Conteo previo por pais
$resumenPais = @{}
$desconocidos = 0
foreach ($c in $contactos) {
    $info = Get-InfoPais $c.numero
    if ($info.Pais -eq "DESCONOCIDO") { $desconocidos++ }
    if ($resumenPais.ContainsKey($info.Pais)) { $resumenPais[$info.Pais]++ } else { $resumenPais[$info.Pais] = 1 }
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "ENVIO MASIVO DE PLANTILLAS (multi-pais)" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "Total contactos:  $total"
Write-Host "Plantilla ID:     $TEMPLATE_ID"
Write-Host "Origen:           $SOURCE"
if ([string]::IsNullOrWhiteSpace($MEDIA_URL)) {
    Write-Host "Cabecera:         solo texto"
} else {
    Write-Host "Cabecera:         $MEDIA_TIPO -> $MEDIA_URL"
}
Write-Host "Parametros:       $($PARAMS.Count)"
Write-Host "Delay:            $DELAY_SEGUNDOS segundos"
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

# --- ENVIO DE PRUEBA ---
if (-not [string]::IsNullOrWhiteSpace($NUMERO_PRUEBA)) {
    $infoPrueba = Get-InfoPais $NUMERO_PRUEBA
    Write-Host "Enviando mensaje de PRUEBA a $($infoPrueba.Destino)..." -NoNewline
    try {
        $r = Send-Plantilla -Destino $infoPrueba.Destino
        Write-Host " OK (status: $($r.status) | id: $($r.messageId))" -ForegroundColor Green
    } catch {
        Write-Host " FALLO" -ForegroundColor Red
        Write-Host (Get-DetalleError $_) -ForegroundColor Red
        Write-Host ""
        Write-Host "El envio masivo se cancela. Corrige el error antes de continuar." -ForegroundColor Red
        exit
    }

    Write-Host ""
    Write-Host "Revisa tu WhatsApp AHORA y confirma que el mensaje llego COMPLETO (imagen + texto)." -ForegroundColor Yellow
    $ok = Read-Host "Llego correctamente? (S/N)"
    if ($ok -ne "S" -and $ok -ne "s") {
        Write-Host "Envio cancelado. Revisa la plantilla y la URL del media." -ForegroundColor Yellow
        exit
    }
    Write-Host ""
}

$confirm = Read-Host "Continuar con el envio a los $total contactos? (S/N)"
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

    try {
        $response = Send-Plantilla -Destino $destino

        Write-Host " OK ($($response.status))" -ForegroundColor Green
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
        $detalle = Get-DetalleError $_
        Write-Host " FALLO: $detalle" -ForegroundColor Red
        $fallidos++

        $resultados += [PSCustomObject]@{
            Numero    = $numeroOriginal
            Destino   = $destino
            Pais      = $pais
            Codigo    = $codigo
            Nombre    = $nombre
            Status    = "error"
            MessageID = "-"
            Error     = $detalle
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
Write-Host ""
Write-Host "NOTA: 'submitted' significa aceptado por Gupshup, NO entregado." -ForegroundColor Yellow
Write-Host "La entrega real se confirma en Gupshup -> Logs (busca por MessageID)." -ForegroundColor Yellow