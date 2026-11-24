#!/usr/bin/env bash
#
# Empaqueta el runtime Linux (proot) DENTRO del APK.
#
# Por qué esto y no una descarga en el primer arranque:
#   - la app queda autocontenida: instalar y listo, funciona sin red;
#   - no dependemos de que packages.termux.dev esté accesible (redes corporativas,
#     censura, caídas);
#   - los binarios viven en nativeLibraryDir, el único directorio que Android
#     permite ejecutar incluso con targetSdk >= 29 (etiqueta apk_data_file).
#
# Uso:
#   ./tools/fetch_runtime.sh              # detecta el host, coloca en jniLibs
#   ./tools/fetch_runtime.sh --abi aarch64
#   ./tools/fetch_runtime.sh --check      # solo valida lo que ya está en jniLibs
#
# Requisitos: curl, tar, python3 (para validar ELF). Corre en dev/CI, NUNCA en
# el teléfono: en el móvil no hay curl, ni tar, ni python3 todavía.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
JNI_ROOT="$PROJECT_DIR/android/app/src/main/jniLibs"

# Versiones fijadas para builds reproducibles.
PROOT_VERSION="5.1.107.102"
# Los .deb de Termux no exponen el número exacto de revisión en el nombre, así
# que se resuelve dinámicamente del índice y se compara con este prefijo.
TERMUX_SUITE="stable"

MIRRORS=(
  "https://packages-cf.termux.dev/apt/termux-main"
  "https://packages.termux.dev/apt/termux-main"
  "https://mirrors.tuna.tsinghua.edu.cn/termux/apt/termux-main"
  "https://grimler.se/termux/apt/termux-main"
)

ABI="aarch64"
CHECK_ONLY=0

log()  { printf '\033[0;36m[chronox]\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m[chronox] AVISO:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[0;31m[chronox] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --abi) ABI="${2:?falta el valor de --abi}"; shift 2 ;;
    --check) CHECK_ONLY=1; shift ;;
    -h|--help) sed -n '2,25p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "opción desconocida: $1" ;;
  esac
done

case "$ABI" in
  aarch64|arm64) ABI="aarch64"; JNI_DIR="$JNI_ROOT/arm64-v8a" ;;
  x86_64|x86-64) ABI="x86_64"; JNI_DIR="$JNI_ROOT/x86_64" ;;
  *) die "ABI no soportada: $ABI (usa aarch64 o x86_64)" ;;
esac

# ---------------------------------------------------------------------------
# Validación ELF: alineación de 16 KB y arquitectura correcta.
# ---------------------------------------------------------------------------
validate_elf() {
  local file="$1" expected_machine="$2"
  python3 - "$file" "$expected_machine" <<'PY'
import struct
import sys

path, expected = sys.argv[1], sys.argv[2]
MACHINES = {0xB7: "aarch64", 0x3E: "x86_64"}
EXPECTED_CODE = {"aarch64": 0xB7, "x86_64": 0x3E}[expected]

with open(path, "rb") as fh:
    data = fh.read()

if data[:4] != b"\x7fELF":
    sys.exit(f"{path}: no es un ELF")

is64 = data[4] == 2
endian = "<" if data[5] == 1 else ">"
if not is64:
    sys.exit(f"{path}: se esperaba ELF64")

machine = struct.unpack(endian + "H", data[0x12:0x14])[0]
if machine != EXPECTED_CODE:
    sys.exit(
        f"{path}: arquitectura {MACHINES.get(machine, hex(machine))}, "
        f"se esperaba {expected}"
    )

phoff = struct.unpack(endian + "Q", data[0x20:0x28])[0]
phentsize = struct.unpack(endian + "H", data[0x36:0x38])[0]
phnum = struct.unpack(endian + "H", data[0x38:0x3A])[0]

aligns = []
interp = None
for i in range(phnum):
    base = phoff + i * phentsize
    p_type = struct.unpack(endian + "I", data[base:base + 4])[0]
    if p_type == 1:  # PT_LOAD
        aligns.append(struct.unpack(endian + "Q", data[base + 0x30:base + 0x38])[0])
    elif p_type == 3:  # PT_INTERP
        off = struct.unpack(endian + "Q", data[base + 0x08:base + 0x10])[0]
        size = struct.unpack(endian + "Q", data[base + 0x20:base + 0x28])[0]
        interp = data[off:off + size].rstrip(b"\x00").decode(errors="replace")

if not aligns:
    sys.exit(f"{path}: sin segmentos PT_LOAD")

minimum = min(aligns)
if minimum < 16384:
    sys.exit(
        f"{path}: alineación {minimum} < 16384. Este binario fallará en "
        f"dispositivos con páginas de 16 KB (Android 15+)."
    )

print(f"  OK {path.split('/')[-1]}: {expected}, align={minimum}, interp={interp or 'estático'}")
PY
}

check_jni_dir() {
  local ok=0
  local required=(libproot.so libtalloc.so libandroid-shmem.so libqemu_guest.so)
  [[ -f "$JNI_DIR/libproot_loader.so" ]] && required+=(libproot_loader.so)
  for lib in "${required[@]}"; do
    if [[ ! -f "$JNI_DIR/$lib" ]]; then
      warn "falta $JNI_DIR/$lib"
      ok=1
    fi
  done
  [[ $ok -eq 0 ]] || return 1

  log "validando ELF en $JNI_DIR"
  validate_elf "$JNI_DIR/libproot.so" "$ABI"
  validate_elf "$JNI_DIR/libqemu_guest.so" "$ABI"
  validate_elf "$JNI_DIR/libtalloc.so" "$ABI"
  validate_elf "$JNI_DIR/libandroid-shmem.so" "$ABI"
  if [[ -f "$JNI_DIR/libproot_loader.so" ]]; then
    validate_elf "$JNI_DIR/libproot_loader.so" "$ABI"
  fi
  return 0
}

if [[ $CHECK_ONLY -eq 1 ]]; then
  check_jni_dir && log "todo correcto" || die "faltan binarios o no son válidos"
  exit 0
fi

command -v curl >/dev/null || die "se necesita curl"
command -v tar  >/dev/null || die "se necesita tar"
command -v python3 >/dev/null || die "se necesita python3 (validación ELF)"
command -v dpkg-deb >/dev/null || die "se necesita dpkg-deb para resolver dependencias QEMU"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

log "ABI: $ABI  destino: $JNI_DIR"
mkdir -p "$JNI_DIR"

# ---------------------------------------------------------------------------
# Resolver un paquete en el índice de Termux y descargar su .deb.
# Devuelve la ruta del .deb descargado.
# ---------------------------------------------------------------------------
fetch_package() {
  local name="$1"
  local index_url="" chosen=""

  for mirror in "${MIRRORS[@]}"; do
    local candidate="$mirror/dists/$TERMUX_SUITE/main/binary-$ABI/Packages.xz"
    local plain="$mirror/dists/$TERMUX_SUITE/main/binary-$ABI/Packages"
    log "buscando $name en $mirror"
    if curl -fsSL --max-time 25 -o "$WORK/Packages.xz" "$candidate" 2>/dev/null; then
      index_url="$candidate"
      if command -v xz >/dev/null; then
        xz -dc "$WORK/Packages.xz" > "$WORK/Packages"
      else
        warn "sin xz; se intenta el índice sin comprimir"
        curl -fsSL --max-time 25 -o "$WORK/Packages" "$plain" || continue
      fi
      break
    elif curl -fsSL --max-time 25 -o "$WORK/Packages" "$plain" 2>/dev/null; then
      index_url="$plain"
      break
    fi
  done

  [[ -n "$index_url" ]] || die "ningún mirror respondió para el índice de Termux"

  # Parsear el bloque del paquete y sacar Filename + Version.
  chosen="$(awk -v pkg="$name" '
    BEGIN { RS=""; FS="\n" }
    {
      name=""; fname=""; ver=""
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^Package: /) { name = substr($i, 10) }
        if ($i ~ /^Filename: /) { fname = substr($i, 11) }
        if ($i ~ /^Version: /)  { ver = substr($i, 10) }
      }
      if (name == pkg) { print fname "\t" ver; exit }
    }' "$WORK/Packages")"

  [[ -n "$chosen" ]] || die "el paquete '$name' no está en el índice"

  local filename version
  filename="$(cut -f1 <<<"$chosen")"
  version="$(cut -f2 <<<"$chosen")"
  log "  $name $version"

  local base="${index_url%/dists/*}"
  local url="$base/$filename"

  local out="$WORK/$(basename "$filename")"
  log "  descargando $url"
  curl -fSL --retry 3 --max-time 180 -o "$out" "$url" \
    || die "fallo al descargar $url"
  printf '%s\n' "$out"
}

# ---------------------------------------------------------------------------
# Extraer un .deb (ar + data.tar.xz|gz) y quedarse con los ficheros de usr/.
# ---------------------------------------------------------------------------
extract_deb() {
  local deb="$1"
  local dest="$2"
  local ar_dir="$WORK/ar-$(basename "$deb" .deb)"
  mkdir -p "$ar_dir"

  # Un .deb es un archivo `ar` sin comprimir.
  (
    cd "$ar_dir"
    ar x "$deb"
  )

  local data_tar
  data_tar="$(ls "$ar_dir"/data.tar.* 2>/dev/null | head -n1)"
  [[ -n "$data_tar" ]] || die "el .deb $(basename "$deb") no tiene data.tar"

  local ex_dir="$WORK/ex-$(basename "$deb" .deb)"
  mkdir -p "$ex_dir"

  case "$data_tar" in
    *.xz)  tar -xJf "$data_tar" -C "$ex_dir" ;;
    *.gz)  tar -xzf "$data_tar" -C "$ex_dir" ;;
    *.zst) command -v zstd >/dev/null && tar --zstd -xf "$data_tar" -C "$ex_dir" \
             || die "se necesita zstd" ;;
    *) die "formato de data.tar no soportado: $data_tar" ;;
  esac

  # Guardar los ficheros de interés en el destino acumulado.
  mkdir -p "$dest"
  local prefix="data/data/com.termux/files/usr"
  if [[ -d "$ex_dir/$prefix" ]]; then
    cp -a "$ex_dir/$prefix/." "$dest/"
  elif [[ -d "$ex_dir/usr" ]]; then
    cp -a "$ex_dir/usr/." "$dest/"
  else
    warn "$(basename "$deb"): no se encontró el prefijo esperado"
  fi
}

# ---------------------------------------------------------------------------
# Resolver y extraer recursivamente el cierre de dependencias de un paquete.
# QEMU se ejecuta desde nativeLibraryDir (apk_data_file); sus bibliotecas Bionic
# pueden cargarse desde filesDir mediante LD_LIBRARY_PATH en targetSdk 29+.
# ---------------------------------------------------------------------------
declare -A FETCHED_TERMUX_PACKAGES=()
fetch_package_tree() {
  local package="$1"
  [[ -n "${FETCHED_TERMUX_PACKAGES[$package]:-}" ]] && return 0
  FETCHED_TERMUX_PACKAGES[$package]=1

  local deb
  deb="$(fetch_package "$package" | tail -n1)"
  extract_deb "$deb" "$COLLECT"

  local depends
  depends="$(dpkg-deb -f "$deb" Depends 2>/dev/null || true)"
  [[ -n "$depends" ]] || return 0
  while IFS= read -r dependency; do
    [[ -n "$dependency" ]] && fetch_package_tree "$dependency"
  done < <(python3 - "$depends" <<'PYDEPS'
import re, sys
# Pick one concrete package from each dependency alternative; Termux's first
# alternative is the canonical package in its own repository.
for group in sys.argv[1].split(','):
    alternatives = group.split('|')
    names = [re.sub(r':(?:any|native)$', '', re.match(r'\s*([a-z0-9+.-]+(?::(?:any|native))?)', item).group(1))
             for item in alternatives if re.match(r'\s*([a-z0-9+.-]+(?::(?:any|native))?)', item)]
    if names:
        print(names[0])
PYDEPS
)
}

# ---------------------------------------------------------------------------
# Flujo principal
# ---------------------------------------------------------------------------
COLLECT="$WORK/collect"
mkdir -p "$COLLECT"

log "obteniendo binarios de Termux (proot $PROOT_VERSION)"
for pkg in proot libtalloc libandroid-shmem; do
  deb="$(fetch_package "$pkg" | tail -n1)"
  extract_deb "$deb" "$COLLECT"
done

# PRoot -q hace que cada ELF invitado sea interpretado por QEMU. Así el único
# execve del kernel es QEMU, instalado desde jniLibs; Debian/Ubuntu ELF nunca se
# ejecuta directamente desde el directorio privado (W^X targetSdk 29+).
if [[ "$ABI" == "aarch64" ]]; then
  QEMU_PACKAGE="qemu-user-aarch64"
  QEMU_BINARY="qemu-aarch64"
else
  QEMU_PACKAGE="qemu-user-x86-64"
  QEMU_BINARY="qemu-x86_64"
fi
log "obteniendo $QEMU_PACKAGE y dependencias transitivas"
fetch_package_tree "$QEMU_PACKAGE"
[[ -f "$COLLECT/bin/$QEMU_BINARY" ]] || die "no se encontró bin/$QEMU_BINARY en $QEMU_PACKAGE"
cp "$COLLECT/bin/$QEMU_BINARY" "$JNI_DIR/libqemu_guest.so"
chmod 0755 "$JNI_DIR/libqemu_guest.so"

# Los nombres .so.N no son nativos instalables por Android desde jniLibs; viajan
# como Flutter assets y se copian a filesDir en primer arranque. dlopen() de
# bibliotecas en app_data_file sigue permitido con targetSdk >= 29.
QEMU_ASSET_DIR="$PROJECT_DIR/assets/runtime-libs/$([[ "$ABI" == aarch64 ]] && echo arm64-v8a || echo x86_64)"
rm -rf "$QEMU_ASSET_DIR"
mkdir -p "$QEMU_ASSET_DIR"
: > "$QEMU_ASSET_DIR/manifest.txt"
if [[ -d "$COLLECT/lib" ]]; then
  while IFS= read -r -d '' library; do
    name="$(basename "$library")"
    [[ "$name" == *.so* ]] || continue
    cp -L "$library" "$QEMU_ASSET_DIR/$name"
    printf '%s\n' "$name" >> "$QEMU_ASSET_DIR/manifest.txt"
  done < <(find -L "$COLLECT/lib" -type f -name '*.so*' -print0 | sort -z -u)
fi
sort -u -o "$QEMU_ASSET_DIR/manifest.txt" "$QEMU_ASSET_DIR/manifest.txt"
[[ -s "$QEMU_ASSET_DIR/manifest.txt" ]] || die "no se recopilaron bibliotecas de QEMU"


# proot -> libproot.so
[[ -f "$COLLECT/bin/proot" ]] || die "el .deb de proot no trajo bin/proot"
cp "$COLLECT/bin/proot" "$JNI_DIR/libproot.so"
chmod 0755 "$JNI_DIR/libproot.so"
log "colocado libproot.so"

# Loader de proot (PROOT_UNBUNDLE_LOADER). En el paquete de Termux está en
# libexec/proot; si no aparece, se extrae del binario en el primer arranque y
# esta comprobación lo detecta.
LOADER_FOUND=0
for candidate in "$COLLECT/libexec/proot/loader" "$COLLECT/libexec/proot" \
                 "$COLLECT/lib/proot-loader" "$COLLECT/bin/proot-loader"; do
  if [[ -f "$candidate" ]]; then
    cp "$candidate" "$JNI_DIR/libproot_loader.so"
    LOADER_FOUND=1
    log "colocado libproot_loader.so (desde ${candidate#$COLLECT/})"
    break
  fi
done
if [[ $LOADER_FOUND -eq 0 ]]; then
  # proot puede usar su loader embebido, pero eso requiere escribir en
  # PROOT_TMP_DIR en tiempo de ejecución; es un modo degradado, no un error.
  warn "no se encontró el loader en el .deb; se usará el embebido de proot."
  warn "si en el móvil aparece 'ptrace: Permission denied', este es el motivo."
  rm -f "$JNI_DIR/libproot_loader.so"
else
  chmod 0755 "$JNI_DIR/libproot_loader.so"
fi

for lib in libtalloc.so libandroid-shmem.so; do
  if [[ -f "$COLLECT/lib/$lib" ]]; then
    cp "$COLLECT/lib/$lib" "$JNI_DIR/$lib"
    chmod 0755 "$JNI_DIR/$lib"
    log "colocado $lib"
  elif [[ -f "$COLLECT/lib/${lib}.0" ]]; then
    cp "$COLLECT/lib/${lib}.0" "$JNI_DIR/$lib"
    chmod 0755 "$JNI_DIR/$lib"
    log "colocado $lib (desde ${lib}.0)"
  else
    die "no se encontró $lib en el .deb correspondiente"
  fi
done

log "validando resultado"
check_jni_dir || die "la validación falló"

log "listo. El runtime viaja dentro del APK; la app no depende de Termux."
log "recuerda copiar las licencias a THIRD_PARTY_NOTICES.md"
