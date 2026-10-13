# ============================================
# VALIDACION CSV - INDURETROS (multi-pais)
# Identifica el pais de cada numero y valida formato/duplicados
# Usa la MISMA logica que enviar_masivo.ps1
# ============================================

$CSV_INPUT = "masivo_06_10_2026.csv"

# Si un numero viene SIN codigo de pais (10 digitos empezando por 3),
# se asume este pais por defecto (igual que en el script de envio).
$PAIS_DEFAULT_CODIGO = "57"
$PAIS_DEFAULT_NOMBRE = "Colombia"

# Tabla de paises (prefijo telefonico -> nombre). Ordenada larga -> corta.
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

function Get-InfoPais {
    param([string]$Numero)
    $d = ($Numero -replace '\D', '')
    if ($d.StartsWith("00")) { $d = $d.Substring(2) }
    if ($d.Length -eq 10 -and $d.StartsWith("3")) {
        return [PSCustomObject]@{ Destino = "$PAIS_DEFAULT_CODIGO$d"; Codigo = $PAIS_DEFAULT_CODIGO; Pais = $PAIS_DEFAULT_NOMBRE }
    }
    foreach ($cc in $PAISES.Keys) {
        if ($d.StartsWith($cc)) {
            $nacional = $d.Substring($cc.Length)
            if ($nacional.Length -ge 7 -and $nacional.Length -le 11) {
                return [PSCustomObject]@{ Destino = $d; Codigo = $cc; Pais = $PAISES[$cc] }
            }
        }
    }
    return [PSCustomObject]@{ Destino = $d; Codigo = ""; Pais = "DESCONOCIDO" }
}

# ============================================
if (-not (Test-Path $CSV_INPUT)) {
    Write-Host "ERROR: No existe $CSV_INPUT" -ForegroundColor Red
    exit
}

$contactos = Import-Csv -Path $CSV_INPUT -Encoding UTF8
$total = $contactos.Count
$validos = 0
$invalidos = @()
$duplicados = @()
$numerosVistos = @{}
$resumenPais = @{}

Write-Host "Validando $total contactos..." -ForegroundColor Cyan
Write-Host ""

foreach ($contacto in $contactos) {
    $num = $contacto.numero
    $nom = $contacto.nombre
    $errores = @()

    $info    = Get-InfoPais $num
    $destino = $info.Destino
    $pais    = $info.Pais

    # Validacion 1: que sea solo digitos en un rango razonable
    if ($destino -notmatch '^\d{10,13}$') {
        $errores += "formato invalido (debe quedar solo digitos, 10-13)"
    }

    # Validacion 2: que el pais se haya identificado
    if ($pais -eq "DESCONOCIDO") {
        $errores += "pais no identificado (prefijo desconocido)"
    }

    # Duplicados: sobre el numero YA normalizado (asi cae 573xx... y 3xx... como el mismo)
    if ($numerosVistos.ContainsKey($destino)) {
        $duplicados += "$destino ($nom)"
    } else {
        $numerosVistos[$destino] = $true
    }

    if ($errores.Count -gt 0) {
        $invalidos += [PSCustomObject]@{
            Numero  = $num
            Destino = $destino
            Pais    = $pais
            Nombre  = $nom
            Error   = ($errores -join ", ")
        }
    } else {
        $validos++
        if ($resumenPais.ContainsKey($pais)) { $resumenPais[$pais]++ } else { $resumenPais[$pais] = 1 }
    }
}

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "VALIDACION CSV (multi-pais)"
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "Total filas:      $total"
Write-Host "Validos:          $validos" -ForegroundColor Green
Write-Host "Invalidos:        $($invalidos.Count)" -ForegroundColor Red
Write-Host "Duplicados:       $($duplicados.Count)" -ForegroundColor Yellow
Write-Host ""

if ($resumenPais.Count -gt 0) {
    Write-Host "DISTRIBUCION POR PAIS (validos):" -ForegroundColor Cyan
    foreach ($p in ($resumenPais.GetEnumerator() | Sort-Object Value -Descending)) {
        Write-Host ("  {0,-18} {1}" -f $p.Key, $p.Value)
    }
    Write-Host ""
}

if ($invalidos.Count -gt 0) {
    Write-Host "NUMEROS INVALIDOS:" -ForegroundColor Red
    $invalidos | Format-Table Numero, Destino, Pais, Nombre, Error -AutoSize
}

if ($duplicados.Count -gt 0) {
    Write-Host "NUMEROS DUPLICADOS:" -ForegroundColor Yellow
    $duplicados | ForEach-Object { Write-Host "  - $_" }
}

if ($invalidos.Count -eq 0 -and $duplicados.Count -eq 0) {
    Write-Host "Todo OK. Listo para enviar." -ForegroundColor Green
}
