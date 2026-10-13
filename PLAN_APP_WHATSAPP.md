# Plan técnico — App de campañas WhatsApp (Gupshup) para Induretros

**Objetivo:** reemplazar los scripts `enviar_masivo.ps1` / `enviar_masivo1.ps1` / `validar_csv.ps1`
por una aplicación mantenible, que funcione **como módulo de Odoo 19** y también **por fuera de Odoo**
(CLI + servicio web), compartiendo un único motor de negocio.

---

## 1. Diagnóstico del estado actual

Escala real observada: `numeros_linea_verde_TODOS.csv` = **3.076 contactos**, delay 1 s → ~51 min
de consola bloqueada por campaña. 10 reportes históricos desde junio.

Defectos que la app debe cerrar (todos verificados en los archivos actuales):

| # | Problema | Evidencia | Impacto |
|---|---|---|---|
| 1 | API key escrita en el archivo | `enviar_masivo.ps1` en la línea de `$API_KEY`; el valor también quedó como comentario en `enviar_masivo1.ps1`, y ambos están en OneDrive sincronizado | **Crítico.** Rotar hoy. |
| 2 | Encoding roto | `PATIÃO`, `COMPAÃÃA`, `NORCONSTRUCCIÃN` en `reporte_envio_20260805_113023.csv` | Nombres corruptos; si mañana se usan como parámetro `{{1}}` de plantilla, llega basura al cliente |
| 3 | Parseo CSV frágil | La fila de EMCIVIL INGENIERIA (nombre con coma) terminó dentro de la columna `Numero` y dejó `Nombre` vacío — 3 filas afectadas | Datos inconsistentes, imposible auditar |
| 4 | Sin idempotencia ni reanudación | El bucle no guarda estado | Si se cierra la consola en el envío 1.500/3.076, relanzar **reenvía** los 1.500 primeros |
| 5 | Solo se registra `submitted` | Todos los reportes tienen `Status=submitted` | No se sabe qué se **entregó**, se leyó o falló. Falta el webhook de callbacks |
| 6 | Sin opt-out ni consentimiento | No existe lista de exclusión | Riesgo Ley 1581/2012 (Habeas Data) + bloqueo de la línea por reportes de spam en Meta |
| 7 | Sin reintentos ni control de tasa | `Start-Sleep 1` fijo, el `catch` solo registra | Fallos transitorios (red / 429) se pierden como definitivos |
| 8 | Deduplicación solo en el validador | `validar_csv.ps1` detecta duplicados pero `enviar_masivo.ps1` no los filtra | Doble mensaje al mismo cliente |
| 9 | Detección de país artesanal | Tabla de 25 prefijos hecha a mano | El prefijo `1` (EEUU) captura falsos positivos; no hay validación de longitud por país |
| 10 | Lógica duplicada en 3 scripts | `Get-InfoPais` copiada en cada `.ps1` | Cualquier corrección hay que hacerla 3 veces |

---

## 2. Evaluación de stack

**Restricción dura:** debe ejecutarse *dentro* de Odoo 19 → el núcleo tiene que ser **Python puro**.
Aunque en `microservices/` ya usan Go con arquitectura hexagonal, replicar el motor en Go obligaría a
duplicar la lógica para el addon. Descartado.

| Opción | Descripción | Veredicto |
|---|---|---|
| A. Todo dentro de Odoo | Módulo Odoo puro, sin capa externa | ❌ No cumple "por fuera"; acoplado a la versión; tests lentos (requieren BD Odoo) |
| B. Microservicio + módulo Odoo delgado que lo llama por HTTP | Un solo runtime, Odoo solo como UI | ❌ El addon deja de ser autónomo: dos despliegues, autenticación entre ambos, punto de fallo extra |
| **C. Núcleo Python hexagonal + 2 adaptadores** | `induretros_wa_core` (0 dependencias de Odoo) consumido por (1) el addon Odoo y (2) CLI/API | ✅ **Recomendada** |

### Por qué C

- El mismo paquete se instala en el venv de Odoo (`external_dependencies` del manifest) o se vendoriza.
- Los tests del motor corren en segundos con `pytest`, sin levantar Odoo.
- Portar 17 ↔ 19 toca solo la capa fina de adaptador (modelos y vistas), no la lógica.
- Encaja con SOLID: el motor depende de *puertos* (Protocol), no de Odoo ni de SQLAlchemy.

### Stack concreto

| Capa | Elección | Razón |
|---|---|---|
| Núcleo | Python 3.10+ (sintaxis compatible 3.10–3.13), `requests`, `phonenumbers` (opcional, con fallback a la tabla actual) | `requests` ya viene con Odoo; `phonenumbers` es el port de libphonenumber y resuelve el defecto #9 |
| Tests | `pytest` + `responses` | Sin red, rápidos |
| CLI | `Typer` + `rich` | Reemplazo directo de los `.ps1`, misma ergonomía de consola |
| Servicio | `FastAPI` + `Uvicorn` | Tipado, OpenAPI gratis, async para el worker |
| Datos | PostgreSQL (ya lo tienen por Odoo, **base separada**) + SQLAlchemy 2 + Alembic | Cero infraestructura nueva |
| UI | Jinja2 + HTMX + Tailwind | Herramienta interna: una SPA React es sobreingeniería aquí |
| Cola | Tabla `outbox` + worker propio (patrón transactional outbox) | Sin Redis/Celery al inicio; en Odoo el mismo patrón con `ir.cron` |
| Empaque | Docker Compose (ya tienen Docker 29) | Un `docker compose up` |

---

## 3. Modelo de dominio (idéntico dentro y fuera de Odoo)

**Value objects:** `PhoneNumber` (normaliza + país + validez), `TemplateRef`, `MediaHeader`, `TemplateParams`.

**Entidades:** `Contact`, `ContactList`, `Template`, `Campaign`, `Message`, `OptOut`, `Consent`.

**Puertos (interfaces):** `MessageGateway`, `ContactRepository`, `CampaignRepository`,
`OptOutRepository`, `Clock`, `RateLimiter`, `EventPublisher`.

**Casos de uso:** `ImportContacts`, `ValidateContacts`, `PreviewCampaign`, `SendTestMessage`,
`LaunchCampaign`, `ProcessOutbox`, `RegisterDeliveryEvent`, `HandleOptOut`, `BuildReport`.

**Adaptadores:** `GupshupGateway` (requests) · repos SQLAlchemy · repos Odoo ORM · repos en memoria (tests).

**Máquina de estados del mensaje:**

```
draft → queued → sent ─┬→ delivered → read
                       └→ failed → (retry) → queued
      └→ skipped (inválido / duplicado / opt-out)
```

Clave de idempotencia: `(campaign_id, phone_e164)` con índice único → cierra el defecto #4.

---

## 4. Estructura del repositorio

```
induretros-whatsapp/
├─ packages/core/                      # pip: induretros-wa-core  (SIN Odoo, SIN FastAPI)
│  └─ induretros_wa/
│     ├─ domain/                       # entities, value_objects, events, errors
│     ├─ application/                  # use_cases, ports (Protocol), dto
│     └─ infrastructure/
│        ├─ gupshup/                   # cliente HTTP + reintentos + backoff
│        ├─ csvio/                     # import/export robusto (encoding + quoting)
│        └─ memory/                    # repos en memoria para tests
├─ apps/cli/                           # Typer  → reemplaza los .ps1
├─ apps/api/                           # FastAPI + SQLAlchemy + HTMX
├─ odoo/addons/induretros_whatsapp/    # adaptador Odoo 19 (models = repos ORM)
│  ├─ __manifest__.py
│  ├─ models/  wizards/  views/  security/  controllers/
├─ tests/
├─ docker-compose.yml
└─ docs/
```

**Cómo el addon consume el núcleo (dos vías, en orden de preferencia):**

1. `"external_dependencies": {"python": ["induretros_wa_core"]}` + `pip install` en el venv de Odoo.
2. Si no hay acceso a pip en el servidor: carpeta `vendor/` dentro del addon, añadida a `sys.path`
   desde `__init__.py`. Menos limpio, pero no obliga a tocar el entorno.

---

## 4bis. Decisiones tomadas (20/08/2026)

| Tema | Decisión |
|---|---|
| Alcance standalone | **CLI primero** (Fase 1), servicio web y Postgres después (Fase 2) |
| Odoo | Producción sigue en **17**; el addon se escribe para **19** pero cuidando compatibilidad con 17 desde el inicio, para poder usarlo antes de migrar |
| Habeas Data | **Consentimiento y opt-out se modelan en el núcleo desde la Fase 1.** Ningún envío sale sin pasar por ese filtro |

Consecuencias sobre el plan:

- `OptOut` y `Consent` suben de la Fase 2 a la **Fase 1**: entran en el dominio y en el CLI
  (`wa optout add/list/import`), con almacenamiento en archivo local hasta que llegue Postgres.
- El caso de uso `LaunchCampaign` incluye el filtro de exclusión como paso obligatorio, no opcional.
- El núcleo se escribe con sintaxis Python **3.10** (no 3.12+) para que corra igual en el venv de
  Odoo 17 y en el de 19.
- La capa de vistas del addon se aísla para tener una sola rama de código con dos juegos de vistas
  (`<tree>` para 17, `<list>` para 19), en vez de dos ramas del módulo completo.

---

## 5. Fases de trabajo

### Fase 0 — Seguridad inmediata *(hoy, ~1 h)*

- Rotar la API key en el panel de Gupshup. **La actual debe considerarse comprometida**: está en
  texto plano dentro de OneDrive corporativo y en dos `.ps1`.
- Purgar la key de todos los archivos (incluidos los comentarios) y de `Downloads/`.
- Dejarla únicamente como variable de entorno / secreto.
- No requiere código nuevo. Es independiente del resto del plan.

### Fase 1 — Núcleo + CLI *(reemplazo directo de los `.ps1`)*

- Paquete `induretros_wa_core`: dominio, puertos, casos de uso, `GupshupGateway`, CSV robusto.
- Normalización y validación de teléfonos, deduplicación, reintentos con backoff, idempotencia.
- Reporte CSV/XLSX equivalente al actual (mismas columnas, sin los defectos 2 y 3).
- Suite `pytest` sobre el motor.
- **Entregables:** `wa validate lista.csv` · `wa send --template <uuid> --dry-run` ·
  `wa send --resume <campaign-id>` · `wa test --to <numero>`.
- Al terminar esta fase los `.ps1` ya se pueden archivar.

### Fase 2 — Persistencia + servicio standalone

- Postgres + Alembic: contactos, campañas, mensajes, outbox, opt-outs, consentimientos.
- Worker de outbox con control de tasa y ventana horaria configurable.
- FastAPI + UI HTMX: cargar CSV, previsualizar, lanzar, ver progreso en vivo, reintentar fallidos.
- **Webhook `/webhooks/gupshup`** para eventos de entrega/lectura/fallo → cierra el defecto #5.
- Autenticación con usuarios y roles; auditoría de quién lanzó cada campaña.
- Docker Compose.

### Fase 3 — Módulo Odoo 19 (`induretros_whatsapp`)

- Modelos `wa.template`, `wa.campaign`, `wa.message`, `wa.optout` como *adaptadores* del núcleo.
- Integración con `res.partner`: móvil normalizado, consentimiento, opt-out.
  (`contactos_res_partner_ENVIO.csv` ya sale de un export de `res.partner`; este paso elimina
  el ida y vuelta por CSV.)
- Wizard "Enviar campaña WhatsApp" desde la vista lista de contactos.
- `ir.cron` procesando el outbox por lotes (mismo caso de uso `ProcessOutbox` de la Fase 2).
- Controller público para el webhook de Gupshup, con validación de origen.
- Grupos de seguridad + record rules + `ir.model.access.csv`.
- **Compatibilidad Odoo 17:** mismo addon, rama con ajustes de manifest y de vistas
  (`<tree>` → `<list>`). A verificar contra la instancia real antes de prometer paridad.

### Fase 4 — Endurecimiento y operación

- Repaso OWASP: validación de entrada, rate limiting, gestión de secretos, CSRF en la UI,
  logs sin PII completa, backups y retención.
- Tablero: entregados / leídos / fallidos por país y por campaña.
- Plantillas versionadas y verificación previa del media (ya hay un embrión en `enviar_masivo1.ps1`).
- Pruebas de carga con la lista real de 3.076 contactos.

---

## 6. Riesgos y decisiones abiertas

- **Cumplimiento legal (Colombia).** Existe la carpeta *AUTORIZACION TRATAMIENTO DE DATOS* en el
  SharePoint; hay que decidir si el consentimiento se modela dentro de la app (recomendado) o se
  mantiene como archivo externo. Sin esto, una campaña de 3.000 mensajes es exposición real.
- **Límites de Gupshup / Meta.** Confirmar el rate limit de la cuenta y la calidad de la línea
  `573007192973` antes de subir el ritmo por encima de 1 msg/s.
- **Versión de Odoo.** El módulo se escribe para 19; si producción sigue en 17 hay que decidir si
  se mantienen las dos ramas o se espera a la migración.
