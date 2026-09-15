# Imagen de producción de la SPA.
#
# Sirve para desplegar esta aplicación en un contenedor detrás de cualquier hostname, SIN
# reconstruirla: la configuración se escribe en el arranque (ver docker-entrypoint-config.sh).
# El caso que lo motiva son los entornos de prueba por pull request, donde conviven varias
# versiones de la SPA a la vez y una imagen por entorno no sería viable.
#
# Hasta ahora el repo solo traía `dev.Dockerfile` (servidor de desarrollo de Vite en el 5173) y
# el workflow `generate-war.yml`, que empaqueta un WAR para desplegar dentro del Payara de
# Dataverse. Ninguna de las dos cosas sirve para esto: el WAR va pegado a una instalación
# concreta, porque su configuración se inyecta en el BUILD.
#
#   docker build -t dataverse-frontend:local .
#   docker run --rm -p 8080:8080 \
#     -e DATAVERSE_BACKEND_URL=https://dataverse.example.org \
#     -e OIDC_CLIENT_ID=dataverse-spa \
#     -e OIDC_AUTHORIZATION_ENDPOINT=https://auth.example.org/realms/dataverse/protocol/openid-connect/auth \
#     -e OIDC_TOKEN_ENDPOINT=https://auth.example.org/realms/dataverse/protocol/openid-connect/token \
#     -e OIDC_LOGOUT_ENDPOINT=https://auth.example.org/realms/dataverse/protocol/openid-connect/logout \
#     dataverse-frontend:local
#   # → http://localhost:8080/modern/

# ──────────────────────────────── build ────────────────────────────────
FROM node:22-alpine AS build

# `npm install` compila alguna dependencia nativa (la misma razón por la que dev.Dockerfile
# instala esto).
RUN apk add --no-cache python3 py3-setuptools make g++

WORKDIR /src
COPY . .


# `prepare: husky` se ejecuta en cada `npm install`, y aquí no hay repositorio git —el
# .dockerignore excluye .git a propósito— ni interés en instalar hooks dentro de una imagen.
# `HUSKY=0` es la forma que documenta husky 9 para no hacer nada.
#
# Ojo: NO sirve `npm pkg delete scripts.prepare`. Este repo declara `workspaces` como objeto
# (`{"packages": [...]}`, estilo yarn); `npm install` lo acepta, pero `npm pkg` lo rechaza con
# EWORKSPACESINVALID y aborta el build.
ENV HUSKY=0

# `@iqss/dataverse-client-javascript` se publica en GitHub Packages, no en el registro público de
# npm, y `package-lock.json` lleva esa URL resuelta. GitHub Packages exige autenticación **incluso
# para paquetes públicos**, así que sin token el install muere con un 401.
#
# El token entra como secreto de build: se monta solo durante este RUN y no queda en ninguna capa.
# En GitHub Actions basta con el `GITHUB_TOKEN` del propio workflow; en local, un PAT con
# `read:packages`:
#
#   docker build --secret id=npm_token,env=GITHUB_TOKEN -t dataverse-frontend:local .
RUN --mount=type=secret,id=npm_token \
    if [ ! -s /run/secrets/npm_token ]; then \
      echo "ERROR: falta el secreto de build 'npm_token' (hace falta para @iqss desde GitHub Packages)." >&2; \
      exit 1; \
    fi; \
    { \
      echo 'legacy-peer-deps=true'; \
      echo '@iqss:registry=https://npm.pkg.github.com/'; \
      echo "//npm.pkg.github.com/:_authToken=$(cat /run/secrets/npm_token)"; \
    } > .npmrc \
 && npm install \
 && rm -f .npmrc

# El design-system es un workspace aparte y hay que construirlo ANTES que la aplicación, que lo
# consume ya compilado. Mismo orden que el workflow `generate-war.yml` del repo.
RUN npm run build --workspace=packages/design-system

# `--base` fija el path bajo el que se sirve la aplicación. Es el mismo valor que ya trae
# `vite.config.ts` y el mismo con el que se despliega en la instalación real, así que los enlaces
# y los assets salen coherentes. Es lo ÚNICO específico del despliegue que queda horneado, y es
# un path, no un hostname: la misma imagen sirve para cualquier despliegue.
ARG BASE_PATH=/modern
RUN npm run build -- --base=${BASE_PATH}

# ──────────────────────────────── runtime ──────────────────────────────
FROM nginx:1.27-alpine

# `jq` para generar el config.js: construir JSON con `printf` desde shell se rompe en cuanto un
# valor trae comillas, y `bannerMessage` lleva HTML. Son ~1 MB.
RUN apk add --no-cache jq

# El build lleva `base=/modern`, así que `index.html` pide sus assets en `/modern/...`. Sirviendo
# el árbol bajo ese mismo subdirectorio, las rutas cuadran sin reescribir nada en nginx.
ARG BASE_PATH=/modern
COPY --from=build /src/dist /usr/share/nginx/html${BASE_PATH}

COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY docker-entrypoint-config.sh /docker-entrypoint.d/40-write-runtime-config.sh
RUN chmod +x /docker-entrypoint.d/40-write-runtime-config.sh

# 8080 en vez del 80 para que el contenedor pueda correr sin privilegios: los puertos por debajo
# de 1024 los reserva root.
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
  CMD wget -q -O /dev/null http://localhost:8080/modern/config.js || exit 1
