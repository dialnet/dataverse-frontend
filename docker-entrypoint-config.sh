#!/bin/sh
# Escribe la configuración de ejecución de la SPA en cada arranque del contenedor.
#
# En la imagen acaba en /docker-entrypoint.d/40-write-runtime-config.sh: la imagen oficial de
# nginx ejecuta todo lo que encuentra ahí antes de arrancar el servidor.
#
# ── Por qué esto existe ──────────────────────────────────────────────────────────────────────
# `index.html` carga `<script src="/modern/config.js">` ANTES del bundle, y `src/config.ts` lee y
# valida lo que ese script deja en `window.__APP_CONFIG__`. El propio fuente lo dice: «This helps
# changing configuration at runtime without rebuilding the application».
#
# El repo ya explota esa propiedad en `scripts/write-runtime-config.mjs`, pero la ejecuta en el
# BUILD (workflow `generate-war.yml`): una imagen por entorno. Esto es lo mismo movido al ARRANQUE
# DEL CONTENEDOR, que es lo que hace que una sola imagen sirva para cualquier hostname — y con
# ello, que tener varias versiones desplegadas a la vez cueste unos megas cada una.
#
# ── Se REESCRIBE entero, no se parchea ───────────────────────────────────────────────────────
# A propósito. Parchear el fichero en el sitio (`sed -i` sobre marcadores) tiene una trampa
# conocida: en un segundo arranque del MISMO contenedor los marcadores ya no están, y se queda
# sirviendo los valores del arranque anterior sin avisar. Generándolo de cero cada vez, un
# `docker restart` es inofensivo.
#
# ── Y con jq, no con printf ──────────────────────────────────────────────────────────────────
# Construir el JSON a mano se rompe en cuanto un valor trae una comilla, y `BANNER_MESSAGE` lleva
# HTML. `jq -n --arg` escapa por nosotros.

set -eu

: "${BASE_PATH:=/modern}"
OUT="/usr/share/nginx/html${BASE_PATH}/config.js"

log() { echo "[config] $*"; }

# ── Lo que no tiene valor por defecto razonable ──────────────────────────────
# Si falta algo de esto, la SPA arranca y muere pintando "Invalid configuration": mejor fallar
# aquí, donde se ve en `docker logs`, que en la consola del navegador de quien abra la URL.
for v in DATAVERSE_BACKEND_URL OIDC_CLIENT_ID OIDC_AUTHORIZATION_ENDPOINT OIDC_TOKEN_ENDPOINT OIDC_LOGOUT_ENDPOINT; do
  eval "val=\${$v:-}"
  [ -n "$val" ] || { echo "ERROR: falta la variable $v" >&2; exit 1; }
done

# `backendUrl` lo valida `z.url()`: una barra final sobrante no rompe el esquema pero sí duplica
# barras al concatenar las rutas de la API. Se quita aquí y no se piensa más en ello.
BACKEND_URL="${DATAVERSE_BACKEND_URL%/}"

TMP="${OUT}.tmp"

jq -n \
  --arg backendUrl      "$BACKEND_URL" \
  --arg bannerMessage   "${BANNER_MESSAGE:-}" \
  --arg clientId        "$OIDC_CLIENT_ID" \
  --arg authorizationEndpoint "$OIDC_AUTHORIZATION_ENDPOINT" \
  --arg tokenEndpoint   "$OIDC_TOKEN_ENDPOINT" \
  --arg logoutEndpoint  "$OIDC_LOGOUT_ENDPOINT" \
  --arg keyPrefix       "${OIDC_STORAGE_KEY_PREFIX:-DV_}" \
  --arg defaultLanguage "${DEFAULT_LANGUAGE:-en}" \
  --arg dataverseName   "${BRANDING_DATAVERSE_NAME:-Dataverse}" \
  --arg supportUrl      "${SUPPORT_URL:-}" \
  --arg copyrightHolder "${FOOTER_COPYRIGHT_HOLDER:-}" \
  --arg privacyPolicyUrl "${FOOTER_PRIVACY_POLICY_URL:-}" \
  '
  {
    backendUrl: $backendUrl,
    oidc: {
      clientId: $clientId,
      authorizationEndpoint: $authorizationEndpoint,
      tokenEndpoint: $tokenEndpoint,
      logoutEndpoint: $logoutEndpoint,
      localStorageKeyPrefix: $keyPrefix
    },
    languages: [
      { code: "es", name: "Español" },
      { code: "en", name: "English" }
    ],
    defaultLanguage: $defaultLanguage,
    branding: { dataverseName: $dataverseName }
  }
  # Los campos opcionales solo se emiten si tienen valor: el esquema de src/config.ts los declara
  # como `z.url().optional()`, y una cadena vacía NO es una URL válida — la SPA no arrancaría.
  + (if $bannerMessage   != "" then { bannerMessage: $bannerMessage }          else {} end)
  + (if $supportUrl      != "" then { homepage: { supportUrl: $supportUrl } }  else {} end)
  + (if ($copyrightHolder != "" or $privacyPolicyUrl != "") then
       { footer: (
             (if $copyrightHolder  != "" then { copyrightHolder:  $copyrightHolder  } else {} end)
           + (if $privacyPolicyUrl != "" then { privacyPolicyUrl: $privacyPolicyUrl } else {} end)
         )
       }
     else {} end)
  ' > "$TMP"

# Y se escribe en dos pasos, no con `jq … | … > "$OUT"`, a propósito: en una tubería el estado de
# salida es el del ÚLTIMO comando, así que un error de jq se perdería, `set -e` no lo vería y el
# contenedor arrancaría sirviendo un config.js truncado. El síntoma sería «Configuration not
# found» en el navegador y nada en `docker logs`. Comprobado que pasa exactamente eso.
[ -s "$TMP" ] || { echo "ERROR: jq no ha generado configuración" >&2; rm -f "$TMP"; exit 1; }

{ printf 'window.__APP_CONFIG__ = '; cat "$TMP"; } > "$OUT"
rm -f "$TMP"

log "escrito $OUT — backendUrl=$BACKEND_URL"
