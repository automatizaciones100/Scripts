#!/usr/bin/env bash
# ============================================================================
# audit-prod.sh - Auditoria EXTERNA, NO DESTRUCTIVA, de ReparApp en produccion.
#
# Pensado para ejecutarse DESDE COLOMBIA (el WAF geo-bloquea fuera de CO) en una
# maquina con red saliente. Hace SOLO lecturas/observacion (pocas peticiones por
# chequeo). NO hace fuerza bruta, NI DoS, NI modifica datos.
#
# Uso:
#   bash infra/aws/audit-prod.sh
#   (requiere: curl; opcional: openssl para detalle de certificado)
#
# La salida se imprime en pantalla y se guarda en audit-prod-report-<fecha>.txt
# Envia ese archivo de vuelta para el analisis.
# ============================================================================
set -uo pipefail

# --------------------------- Configuracion ----------------------------------
API_HOST="api.induagro.com.co"
FRONT_HOST="reparapp.induagro.com.co"
API="https://${API_HOST}/api/v1"
FRONT="https://${FRONT_HOST}"

# Muestreo de uptime/latencia (baja frecuencia, no es prueba de carga).
SAMPLES="${SAMPLES:-15}"      # muestras por endpoint
INTERVAL="${INTERVAL:-6}"     # segundos entre muestras

# Endpoints protegidos que DEBEN responder 401 sin token.
PROTEGIDOS=("/service-orders" "/users" "/payroll/periods" "/registros-horas" "/clients")

# Rutas sensibles que NO deberian estar expuestas (esperado 403/404).
SENSIBLES=("/.env" "/.git/HEAD" "/.git/config" "/uploads/" "/config.json")

TS="$(date +%Y%m%d-%H%M%S)"
OUT="audit-prod-report-${TS}.txt"

# --------------------------- Utilidades -------------------------------------
# Imprime a pantalla y al archivo a la vez.
log() { echo -e "$@" | tee -a "$OUT"; }
sep() { log "\n------------------------------------------------------------------"; }

# Trae solo las cabeceras (via GET, -D vuelca headers) de una URL.
headers() { curl -sS -m 15 -D - -o /dev/null "$1" 2>/dev/null; }

# Codigo HTTP de una URL (GET).
code() { curl -sS -m 15 -o /dev/null -w '%{http_code}' "$1" 2>/dev/null; }

# Busca una cabecera (case-insensitive) e informa PRESENTE/AUSENTE.
check_header() {
  local dump="$1" name="$2"
  if echo "$dump" | grep -iq "^${name}:"; then
    local val; val="$(echo "$dump" | grep -i "^${name}:" | head -1 | sed 's/\r//')"
    log "  [OK ] ${val}"
  else
    log "  [!! ] FALTA: ${name}"
  fi
}

# ---------------------------- Inicio ----------------------------------------
log "============================================================"
log " AUDITORIA EXTERNA ReparApp - ${TS}"
log " API:   ${API}"
log " Front: ${FRONT}"
log " IP publica de salida (este equipo):"
log "   $(curl -sS -m 10 https://api.ipify.org 2>/dev/null || echo '(no disponible)')"
log "============================================================"

# Preflight: herramientas disponibles.
command -v curl >/dev/null || { echo "ERROR: falta 'curl'."; exit 1; }
HAS_OPENSSL=0; command -v openssl >/dev/null && HAS_OPENSSL=1

# --- 0. Conectividad / geo-bloqueo ------------------------------------------
sep; log "0) CONECTIVIDAD Y SALUD"
HC="$(code "${API}/health")"
log "  GET ${API}/health -> HTTP ${HC}"
if [ "$HC" = "000" ]; then
  log "  [!! ] Sin respuesta. ¿Sin red, o bloqueado? Si estas FUERA de Colombia,"
  log "        el WAF geo-bloquea: corre esto desde una IP colombiana."
elif [ "$HC" = "403" ]; then
  log "  [?? ] 403: podria ser geo-bloqueo del WAF (¿estas fuera de CO?)."
fi
log "  Cuerpo de /health:"
log "    $(curl -sS -m 15 "${API}/health" 2>/dev/null | head -c 300)"

# --- 1. TLS y certificado ---------------------------------------------------
sep; log "1) TLS Y CERTIFICADO"
for H in "$API_HOST" "$FRONT_HOST"; do
  log "  Host: ${H}"
  if [ "$HAS_OPENSSL" = "1" ]; then
    INFO="$(echo | openssl s_client -connect "${H}:443" -servername "${H}" 2>/dev/null)"
    log "    Protocolo: $(echo "$INFO" | grep -i 'Protocol' | head -1 | sed 's/^ *//')"
    log "    Cipher:    $(echo "$INFO" | grep -i 'Cipher *:' | head -1 | sed 's/^ *//')"
    DATES="$(echo "$INFO" | openssl x509 -noout -dates 2>/dev/null)"
    log "    $(echo "$DATES" | tr '\n' ' ')"
    log "    Emisor:    $(echo "$INFO" | openssl x509 -noout -issuer 2>/dev/null | sed 's/issuer=//')"
  else
    log "    (openssl no disponible; omito detalle de certificado)"
  fi
done

# --- 2. Redireccion HTTP -> HTTPS -------------------------------------------
sep; log "2) REDIRECCION HTTP -> HTTPS"
for H in "$API_HOST" "$FRONT_HOST"; do
  RC="$(curl -sS -m 15 -o /dev/null -w '%{http_code} -> %{redirect_url}' "http://${H}/" 2>/dev/null)"
  log "  http://${H}/  =>  ${RC}"
done

# --- 3. Cabeceras de seguridad ----------------------------------------------
sep; log "3) CABECERAS DE SEGURIDAD"
log "  --- Frontend (${FRONT}) ---"
FH="$(headers "${FRONT}/")"
for h in "Strict-Transport-Security" "Content-Security-Policy" "Content-Security-Policy-Report-Only" \
         "X-Frame-Options" "X-Content-Type-Options" "Referrer-Policy" "Permissions-Policy"; do
  check_header "$FH" "$h"
done
log "  Fugas de tecnologia (no deberian aparecer):"
LEAK_F="$(echo "$FH" | grep -iE '^(Server|X-Powered-By|Via):' | sed 's/\r//')"
if [ -n "$LEAK_F" ]; then log "$(echo "$LEAK_F" | sed 's/^/    /')"; else log "    (ninguna)"; fi

log "  --- API (${API}/health) ---"
AH="$(headers "${API}/health")"
for h in "Strict-Transport-Security" "X-Frame-Options" "X-Content-Type-Options" "Referrer-Policy"; do
  check_header "$AH" "$h"
done
log "  Fugas de tecnologia API:"
LEAK_A="$(echo "$AH" | grep -iE '^(Server|X-Powered-By|Via):' | sed 's/\r//')"
if [ -n "$LEAK_A" ]; then log "$(echo "$LEAK_A" | sed 's/^/    /')"; else log "    (ninguna)"; fi

# --- 4. CORS ----------------------------------------------------------------
sep; log "4) CORS (probando Origin falso)"
CORS="$(curl -sS -m 15 -D - -o /dev/null -H 'Origin: https://atacante.example.com' "${API}/health" 2>/dev/null)"
ACAO="$(echo "$CORS" | grep -i '^Access-Control-Allow-Origin:' | sed 's/\r//')"
if [ -z "$ACAO" ]; then
  log "  [OK ] No se refleja Access-Control-Allow-Origin para un Origin desconocido."
elif echo "$ACAO" | grep -q '\*'; then
  log "  [!! ] CORS PERMISIVO: ${ACAO}"
else
  log "  [OK ] ${ACAO}"
fi

# --- 5. Enforcement de autenticacion ----------------------------------------
sep; log "5) AUTENTICACION (endpoints protegidos SIN token -> esperado 401)"
for p in "${PROTEGIDOS[@]}"; do
  C="$(code "${API}${p}")"
  MARK="[OK ]"; [ "$C" != "401" ] && MARK="[!! ]"
  log "  ${MARK} GET ${p} -> HTTP ${C} (esperado 401)"
done

# --- 6. Divulgacion de informacion ------------------------------------------
sep; log "6) DIVULGACION DE INFORMACION"
log "  a) JSON malformado en login (no debe filtrar stack trace):"
BAD="$(curl -sS -m 15 -X POST "${API}/auth/login" -H 'Content-Type: application/json' -d '{bad json' 2>/dev/null)"
log "     $(echo "$BAD" | head -c 300)"
log "  b) Ruta inexistente (404 generico):"
NF="$(curl -sS -m 15 "${API}/ruta-inexistente-xyz-$RANDOM" 2>/dev/null)"
log "     $(echo "$NF" | head -c 300)"
if echo "$BAD $NF" | grep -qiE 'at .*\(|node_modules|Error:.*\.js|stack'; then
  log "  [!! ] Posible fuga de detalles internos (revisar arriba)."
else
  log "  [OK ] No se observan stack traces ni rutas internas."
fi

# --- 7. Rutas sensibles -----------------------------------------------------
sep; log "7) RUTAS SENSIBLES (esperado 403/404, NUNCA 200 con contenido)"
for base in "${FRONT}" "https://${API_HOST}"; do
  log "  Base: ${base}"
  for s in "${SENSIBLES[@]}"; do
    C="$(code "${base}${s}")"
    MARK="[OK ]"; [ "$C" = "200" ] && MARK="[!! ]"
    log "    ${MARK} ${s} -> HTTP ${C}"
  done
done

# --- 8. Rate limiting en login ----------------------------------------------
sep; log "8) RATE LIMIT / BLOQUEO DE CUENTA EN LOGIN"
log "  Enviando 6 intentos con credenciales FALSAS (correo inexistente, no bloquea a nadie real)..."
FAKE="audit-noexiste-${RANDOM}@example.com"
for i in $(seq 1 6); do
  R="$(curl -sS -m 15 -o /dev/null -w '%{http_code}' -X POST "${API}/auth/login" \
        -H 'Content-Type: application/json' \
        -d "{\"correo\":\"${FAKE}\",\"password\":\"ClaveInvalida${i}!\"}" 2>/dev/null)"
  log "    intento ${i} -> HTTP ${R}"
  sleep 1
done
log "  (Se espera ver 401 al inicio y un 429 cuando aplica el bloqueo/limite.)"

# --- 9. Uptime y latencia ---------------------------------------------------
sep; log "9) UPTIME Y LATENCIA (${SAMPLES} muestras c/u, intervalo ${INTERVAL}s)"
sample_endpoint() {
  local url="$1" label="$2" tmp; tmp="$(mktemp)"
  local ok=0 hc tt ttfb tls
  for i in $(seq 1 "$SAMPLES"); do
    # http_code total ttfb tls_handshake (en una sola lectura separada por espacios)
    read -r hc tt ttfb tls < <(curl -sS -m 20 -o /dev/null \
      -w '%{http_code} %{time_total} %{time_starttransfer} %{time_appconnect}' "$url" 2>/dev/null)
    [ -z "${hc:-}" ] && hc="000"
    case "$hc" in 2*) ok=$((ok+1));; esac
    echo "${tt:-0} ${ttfb:-0} ${tls:-0}" >> "$tmp"
    [ "$i" -lt "$SAMPLES" ] && sleep "$INTERVAL"
  done
  local disp; disp="$(awk "BEGIN{printf \"%.1f\", ${ok}/${SAMPLES}*100}")"
  log "  ${label}: disponibilidad ${ok}/${SAMPLES} (${disp}%)"
  # Promedios/min/max con awk basico; p95 con sort+sed (portable, sin asort).
  local n; n="$(wc -l < "$tmp" | tr -d ' ')"
  if [ "${n:-0}" -eq 0 ]; then log "    (sin datos)"; rm -f "$tmp"; return; fi
  local idx; idx="$(awk "BEGIN{i=int(${n}*0.95); print (i<1?1:i)}")"
  local p95; p95="$(awk '{print $1}' "$tmp" | sort -n | sed -n "${idx}p")"
  awk -v p95="$p95" '{st+=$1; stf+=$2; stl+=$3; if($1>mx)mx=$1; if(mn==""||$1<mn)mn=$1}
    END{ printf "    total: min %.3fs | prom %.3fs | p95 %.3fs | max %.3fs\n", mn, st/NR, p95, mx;
         printf "    TTFB prom %.3fs | TLS handshake prom %.3fs\n", stf/NR, stl/NR }' "$tmp" | tee -a "$OUT"
  rm -f "$tmp"
}
sample_endpoint "${API}/health" "API /health"
sample_endpoint "${FRONT}/"     "Frontend /"

# ---------------------------- Cierre ----------------------------------------
sep
log "\nAUDITORIA COMPLETA. Reporte guardado en: ${OUT}"
log "Envia ese archivo para el analisis. (Marcas: [OK ] bien | [!! ] revisar | [?? ] depende del contexto)"
