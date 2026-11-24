# Firma de la aplicación

> Android identifica una app por `applicationId` **+ la clave con la que está firmada**.
> Si la clave cambia, el sistema considera que es otra app distinta y rechaza la
> actualización: `INSTALL_FAILED_UPDATE_INCOMPATIBLE` / "App not installed". El usuario
> tendría que desinstalar y **perder todos sus datos**.
>
> Consecuencia práctica: **la clave se genera una sola vez y se guarda para siempre.**

---

## Estado actual

| Dato | Valor |
|---|---|
| Application ID | `app.chronoxai` (debug: `app.chronoxai.debug`) |
| Alias | `chronoxai` |
| Algoritmo | RSA-4096, SHA-256 |
| Formato | PKCS#12 (`.jks`, compatible con JDK 17 / Gradle) |
| Validez | 30 años (hasta 2056) — Google Play exige validez más allá de 2033 |
| Firmas | v1 (JAR) + v2 + v3, activadas en `build.gradle` |
| Debug | `app.chronoxai.debug` — convive instalada con la release sin pisarla |

**Huella SHA-256 del certificado:**

```
A2:C9:DC:DB:74:C0:63:FE:0B:B9:0C:24:0B:0B:AA:4B:B1:89:54:12:97:6C:40:C4:9A:79:66:66:C3:DA:39:2A
```

Guarda esta huella fuera del repositorio. Sirve para verificar que un APK que te
envía alguien está firmado con tu clave:

```bash
openssl dgst -sha256 -verify <(keytool -exportcert -keystore ... ) # o:
apksigner verify --print-certs chronoxai-release.apk | grep SHA-256
```

## Ficheros generados (y su estatus)

```
chronoxai/android/keystore/chronoxai-release.jks   ← clave, contraseña cifrada
chronoxai/android/keystore/chronoxai-release.key   ← copia PEM de la clave privada
chronoxai/android/keystore/chronoxai-release.crt   ← certificado público
chronoxai/android/key.properties                   ← contraseñas en claro
```

Los cuatro están **excluidos de Git** (`.gitignore`). Están en tu máquina y en el
snapshot del workspace de Arena, pero no se versionan.

> ⚠️ Los ficheros `.key` y `key.properties` están **en claro**. No los subas a GitHub,
> ni a un gist, ni los pegues en un chat. Fueron generados en este entorno: si el
> workspace se comparte o se clona, **trátalos como comprometidos** y rota la clave
> antes de publicar (ver "Rotación", abajo).

## Copia de seguridad (hazlo hoy)

Los cuatro ficheros deben guardarse en **dos** lugares offline: un gestor de
contraseñas (para la contraseña) y un almacenamiento cifrado (para la clave).

```bash
# Cifrado con contraseña, listo para subir a un backup:
tar czf - android/keystore android/key.properties \
  | openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt -out chronoxai-signing-backup.tar.gz.enc
```

Restaurar:

```bash
openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -in chronoxai-signing-backup.tar.gz.enc \
  | tar xzf -
```

Si pierdes la clave **no hay recuperación posible**. Google Play tiene un servicio de
*key upgrade* / *app signing por Google*, pero solo si lo diste de alta **antes** de
publicar; sirve apps nuevas, no rescata una clave perdida de una app ya distribuida
por fuera de Play.

## Compilar

```bash
cd chronoxai
flutter build apk --release          # usa la clave automáticamente
flutter build appbundle --release    # para Play Store (si algún día)
```

Si `key.properties` no existe (clon nuevo, CI sin secretos), la build **avisa por
consola** y firma con la clave de *debug*: sirve para probar, no para publicar.

Comprobar la firma de un APK:

```bash
$ANDROID_HOME/build-tools/34.0.0/apksigner verify --print-certs \
  build/app/outputs/flutter-apk/app-release.apk
```

Debe mostrar 3 esquemas (v1, v2, v3) y la huella SHA-256 de arriba.

## CI (GitHub Actions) sin exponer la clave

Nunca se sube el keystore al repo. Se pasa como secreto:

1. Codifica la clave en base64 y guárdala como secreto del repo:
   ```bash
   base64 -w0 android/keystore/chronoxai-release.jks > keystore.b64
   gh secret set KEYSTORE_BASE64 < keystore.b64
   gh secret set KEYSTORE_PASSWORD --body 'la-contraseña'
   gh secret set KEY_ALIAS --body 'chronoxai'
   gh secret set KEY_PASSWORD --body 'la-contraseña'
   ```
2. En el workflow, antes de compilar:
   ```yaml
   - name: Restaurar clave de firma
     run: |
       mkdir -p chronoxai/android/keystore
       echo "${{ secrets.KEYSTORE_BASE64 }}" | base64 -d \
         > chronoxai/android/keystore/chronoxai-release.jks
       cat > chronoxai/android/key.properties <<EOF
       storePassword=${{ secrets.KEYSTORE_PASSWORD }}
       keyPassword=${{ secrets.KEY_PASSWORD }}
       keyAlias=${{ secrets.KEY_ALIAS }}
       storeFile=keystore/chronoxai-release.jks
       EOF
   - name: Compilar
     run: flutter build apk --release
   ```

En un runner de un fork, los secretos no existen → la build firma con debug y el
workflow debe fallar a propósito si intenta publicar.

## Rotación (solo si la clave se filtró)

1. Genera una clave nueva: `./tools/generate_keystore.sh --force`.
2. Sube el `versionCode`.
3. Publica con un `applicationId` **nuevo** (p. ej. `app.chronoxai.v2`) y avisa a los
   usuarios de que la nueva versión es una instalación limpia.
4. Si ya estabas en Play con *Play App Signing*, pide el *upload key reset* a Google:
   en ese caso la clave de distribución la custodia Google y solo rotas la de subida,
   sin perder a los usuarios.

## Regenerar

```bash
./tools/generate_keystore.sh          # se niega si ya existe (protección)
./tools/generate_keystore.sh --show   # huella, sujeto y fechas de la clave actual
./tools/generate_keystore.sh --force  # sobrescribe: ¡rompe las actualizaciones!
```

---

## Secretos para GitHub Actions (procedimiento exacto)

El workflow `.github/workflows/ci.yml` espera cuatro secretos. Si faltan, compila con
la clave de debug y lo avisa (nunca falla en silencio ni publica un APK sin firmar bien).

```bash
cd chronoxai

# 1. Codificar la clave SIN saltos de línea (-w0). Si se omite, el keystore
#    restaurado queda corrupto y la build falla de forma confusa.
base64 -w0 android/keystore/chronoxai-release.jks > /tmp/keystore.b64

# 2. Subir los secretos
gh secret set KEYSTORE_BASE64 --repo <owner>/ChronoxAi < /tmp/keystore.b64
gh secret set KEYSTORE_PASSWORD --repo <owner>/ChronoxAi \
  --body "$(grep '^storePassword=' android/key.properties | cut -d= -f2-)"
gh secret set KEY_PASSWORD --repo <owner>/ChronoxAi \
  --body "$(grep '^keyPassword=' android/key.properties | cut -d= -f2-)"
gh secret set KEY_ALIAS --repo <owner>/ChronoxAi --body 'chronoxai'

# 3. Borrar el temporal
shred -u /tmp/keystore.b64 2>/dev/null || rm -f /tmp/keystore.b64
```

Verificar que el keystore restaurado es el correcto antes de publicar:

```bash
echo "$KEYSTORE_BASE64" | base64 -d | openssl pkcs12 -passin "pass:$KEYSTORE_PASSWORD" -info -noout
```

La huella debe coincidir con la de arriba (`A2:C9:…:39:2A`).
