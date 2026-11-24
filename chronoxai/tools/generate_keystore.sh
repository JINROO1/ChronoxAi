#!/usr/bin/env bash
#
# Genera la CLAVE DE FIRMA de Chronox AI.
#
# Por qué esto importa tanto: Android identifica una app por su
# `applicationId` + la clave con la que está firmada. Si cambias la clave,
# el sistema considera que es OTRA app y no permite actualizar encima
# ("App not installed" / "signatures do not match"). Por eso la clave se genera
# UNA vez y se guarda para siempre.
#
# Uso:
#   ./tools/generate_keystore.sh                      # genera con valores por defecto
#   ./tools/generate_keystore.sh --force              # sobrescribe (¡rompe updates!)
#   ./tools/generate_keystore.sh --show               # muestra huellas de la clave actual
#
# Requisitos: openssl >= 1.1 (no necesita Java para generar; Gradle sí lo usará
# para firmar, pero el keystore es PKCS#12 estándar y JDK 17 lo lee sin problema).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
KEYSTORE_DIR="$PROJECT_DIR/android/keystore"
KEYSTORE="$KEYSTORE_DIR/chronoxai-release.jks"
KEY_PROPS="$PROJECT_DIR/android/key.properties"
ALIAS="chronoxai"
VALIDITY_DAYS=10950   # 30 años: Android exige que el certificado no haya caducado
                      # (Google Play requiere validez más allá de oct-2033).
KEY_SIZE=4096

log()  { printf '\033[0;36m[chronox]\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m[chronox] AVISO:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[0;31m[chronox] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

FORCE=0
SHOW_ONLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE=1; shift ;;
    --show)  SHOW_ONLY=1; shift ;;
    -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "opción desconocida: $1" ;;
  esac
done

command -v openssl >/dev/null || die "se necesita openssl"

fingerprints() {
  local store="$1" pass="$2"
  openssl pkcs12 -in "$store" -passin "pass:$pass" -nokeys -clcerts 2>/dev/null \
    | openssl x509 -noout -fingerprint -sha256 2>/dev/null
}

if [[ $SHOW_ONLY -eq 1 ]]; then
  [[ -f "$KEYSTORE" ]] || die "no existe $KEYSTORE"
  [[ -f "$KEY_PROPS" ]] || die "no existe $KEY_PROPS"
  # shellcheck disable=SC1090
  pass="$(grep '^storePassword=' "$KEY_PROPS" | cut -d= -f2-)"
  [[ -n "$pass" ]] || die "no se pudo leer storePassword de key.properties"
  log "keystore: $KEYSTORE"
  fingerprints "$KEYSTORE" "$pass" | sed 's/^/  /'
  openssl pkcs12 -in "$KEYSTORE" -passin "pass:$pass" -nokeys -clcerts 2>/dev/null \
    | openssl x509 -noout -subject -dates | sed 's/^/  /'
  exit 0
fi

if [[ -f "$KEYSTORE" && $FORCE -eq 0 ]]; then
  warn "ya existe $KEYSTORE"
  warn "NO lo sobrescribas: perderías la capacidad de actualizar la app."
  warn "usa --show para ver la huella, o --force si de verdad quieres empezar de cero."
  exit 0
fi

# Contraseña fuerte sin caracteres que rompan properties/URLs.
generate_password() {
  # 32 bytes -> base64 -> solo alfanuméricos, 40 caracteres.
  openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 40
}

STORE_PASS="${CHRONOX_STORE_PASSWORD:-$(generate_password)}"
KEY_PASS="$STORE_PASS"

mkdir -p "$KEYSTORE_DIR"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

log "generando clave RSA-$KEY_SIZE (esto puede tardar unos segundos)…"
openssl req -x509 -newkey "rsa:$KEY_SIZE" -sha256 -nodes \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -days "$VALIDITY_DAYS" \
  -subj "/C=PR/ST=San Juan/L=San Juan/O=Chronox AI/OU=Android Release/CN=Chronox AI/emailAddress=chronox@chronoxai.app" \
  -addext "basicConstraints=critical,CA:FALSE" \
  -addext "keyUsage=critical,digitalSignature,keyEncipherment" \
  -addext "extendedKeyUsage=codeSigning" \
  2>/dev/null

log "empaquetando en PKCS#12 ($KEYSTORE)…"
openssl pkcs12 -export \
  -in "$TMP/cert.pem" -inkey "$TMP/key.pem" \
  -name "$ALIAS" \
  -out "$KEYSTORE" \
  -passout "pass:$STORE_PASS"

chmod 600 "$KEYSTORE"

log "escribiendo $KEY_PROPS"
cat > "$KEY_PROPS" <<EOF
# Credenciales de firma de Chronox AI.
# ESTE FICHERO NO SE VERSIONA (está en .gitignore). Guárdalo con la clave.
storePassword=$STORE_PASS
keyPassword=$KEY_PASS
keyAlias=$ALIAS
storeFile=keystore/chronoxai-release.jks
EOF
chmod 600 "$KEY_PROPS"

# Copia de seguridad del material en PEM, por si hay que migrar a otro formato.
openssl pkey -in "$TMP/key.pem" -out "$KEYSTORE_DIR/chronoxai-release.key" 2>/dev/null
cp "$TMP/cert.pem" "$KEYSTORE_DIR/chronoxai-release.crt"
chmod 600 "$KEYSTORE_DIR/chronoxai-release.key"

echo
log "hecho."
echo
echo "  Application ID : app.chronoxai   (debug: app.chronoxai.debug)"
echo "  Alias          : $ALIAS"
echo "  Keystore       : $KEYSTORE"
echo "  key.properties : $KEY_PROPS"
echo "  Validez        : $VALIDITY_DAYS días"
echo
echo "  Huella SHA-256 (guárdala, sirve para verificar builds):"
fingerprints "$KEYSTORE" "$STORE_PASS" | sed 's/^/    /'
echo
warn "HAZ COPIA DE SEGURIDAD de estos 4 ficheros en un lugar seguro y offline:"
warn "  android/keystore/chronoxai-release.jks"
warn "  android/keystore/chronoxai-release.key"
warn "  android/keystore/chronoxai-release.crt"
warn "  android/key.properties   (contiene la contraseña)"
warn "Si los pierdes, NO podrás publicar actualizaciones de la app instalada:"
warn "los usuarios tendrían que desinstalar y perder sus datos."
