#!/bin/bash
set -e

# =============================================================================
# OpenClaude - Build .deb (Infogyba Soluções em TI)
# Compila llama.cpp + empacota llama-server + Qwen2.5-Coder-0.5B em .deb
# Alvo: CPUs sem AVX/AVX2/FMA (ex.: AMD C-60 / Bobcat)
# =============================================================================

log() { echo -e "\e[32m[INFO]\e[0m $*"; }
warn() { echo -e "\e[33m[AVISO]\e[0m $*"; }
err() { echo -e "\e[31m[ERRO]\e[0m $*" >&2; exit 1; }

# =============================================================================
# Checa e instala dependências automaticamente (apt/dnf)
# =============================================================================
REQUIRED_BINS=(git cmake make curl dpkg-deb gzip objdump)
MISSING=()
for bin in "${REQUIRED_BINS[@]}"; do
    command -v "$bin" >/dev/null 2>&1 || MISSING+=("$bin")
done

if [[ ${#MISSING[@]} -gt 0 ]]; then
    log "Dependências ausentes: ${MISSING[*]}. Instalando automaticamente..."
    if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get update -qq
        sudo apt-get install -y git cmake make curl dpkg-dev gzip build-essential binutils
    elif command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y git cmake make curl dpkg gzip gcc gcc-c++ binutils
    elif command -v pacman >/dev/null 2>&1; then
        sudo pacman -Sy --noconfirm git cmake make curl dpkg gzip base-devel binutils
    else
        err "Gerenciador de pacotes não reconhecido (apt/dnf/pacman). Instale manualmente: ${MISSING[*]}"
    fi

    STILL_MISSING=()
    for bin in "${REQUIRED_BINS[@]}"; do
        command -v "$bin" >/dev/null 2>&1 || STILL_MISSING+=("$bin")
    done
    [[ ${#STILL_MISSING[@]} -eq 0 ]] || err "Não foi possível instalar automaticamente: ${STILL_MISSING[*]}. Instale manualmente e rode o script de novo."
    log "Dependências instaladas com sucesso."
fi

CURRENT_DIR="$(pwd)"
BUILD_ROOT="${CURRENT_DIR}/deb_output"
rm -rf "$BUILD_ROOT"

# =============================================================================
# Variáveis
# =============================================================================
LLAMACPP_DIR="$BUILD_ROOT/llama.cpp"
INSTALL_PREFIX="${BUILD_ROOT}/BUILD/install"

# IMPORTANTE: NÃO fixar em um tag antigo (ex.: b1412). Versões de antes de
# meados de 2024 não reconhecem a arquitetura do Qwen2.5 e o binário do
# servidor se chamava "server" (renomeado para "llama-server" depois).
# Permite pinar via variável de ambiente, mas usa "master" por padrão.
LLAMACPP_REF="${LLAMACPP_REF:-master}"

MODEL_FILE="qwen2.5-coder-0.5b-instruct-q4_k_m.gguf"
MODEL_URL="https://huggingface.co/Qwen/Qwen2.5-Coder-0.5B-Instruct-GGUF/resolve/main/qwen2.5-coder-0.5b-instruct-q4_k_m.gguf"
ICON_FILE="icon.svg"
ICON_URL="https://raw.githubusercontent.com/lucide-icons/lucide/main/icons/bot.svg"
STAGE="$BUILD_ROOT/stage"
INSTALL_DIR="/opt/openclaude-agent"
PKG_NAME="openclaude"
PKG_VERSION="1.1.0"
PKG_RELEASE="1"
ARCH="amd64"
PKG_FULL_NAME="${PKG_NAME}_${PKG_VERSION}-${PKG_RELEASE}_${ARCH}"

# Identidade AppStream (mesma nos 3 pacotes - deb/rpm/flatpak - para a
# GNOME Software/KDE Discover reconhecerem como o mesmo app).
APP_ID="com.infogyba.OpenClaude"

# URL base do repositório GitHub onde ficam os screenshots exibidos na
# GNOME Software. Troque SEU_USUARIO/SEU_REPO pelo caminho real do seu
# repositório antes de publicar - as imagens precisam existir em
# screenshots/ dentro do repo (ver README para especificações).
SCREENSHOTS_BASE_URL="${SCREENSHOTS_BASE_URL:-https://raw.githubusercontent.com/SEU_USUARIO/SEU_REPO/main/screenshots}"

mkdir -p "$BUILD_ROOT/BUILD" "$BUILD_ROOT/DEBS" "$STAGE" "$INSTALL_PREFIX"

# =============================================================================
# Build llama.cpp - sem AVX/AVX2/FMA/F16C (compatível com AMD C-60 / Bobcat)
# =============================================================================
log "Clonando llama.cpp (ref: ${LLAMACPP_REF})..."
git clone --depth 1 --branch "$LLAMACPP_REF" https://github.com/ggml-org/llama.cpp "$LLAMACPP_DIR" 2>/dev/null \
    || git clone https://github.com/ggml-org/llama.cpp "$LLAMACPP_DIR"

if [[ "$LLAMACPP_REF" != "master" ]]; then
    pushd "$LLAMACPP_DIR" >/dev/null
    git checkout "$LLAMACPP_REF"
    popd >/dev/null
fi

BUILD_DIR="${LLAMACPP_DIR}/build"
mkdir -p "$BUILD_DIR"
pushd "$BUILD_DIR" >/dev/null

log "Detectando suporte a AVX2/FMA na CPU desta máquina..."

# ─── Detecção automática de CPU ────────────────────────────────────────────
# Se a máquina que está compilando tiver AVX2+FMA (a grande maioria dos PCs
# dos últimos ~10 anos), compila otimizado pra ela (-march=native). Se não
# tiver - como é o caso do próprio AMD C-60 (Bobcat) - cai automaticamente
# pro modo seguro/portável de sempre (btver1, sem AVX). Não precisa editar
# nada na mão: o script decide sozinho a cada execução.
CPU_FLAGS="$(grep -m1 '^flags' /proc/cpuinfo 2>/dev/null || true)"
AVX2_OK=false
if echo "$CPU_FLAGS" | grep -qw avx2 && echo "$CPU_FLAGS" | grep -qw fma; then
    AVX2_OK=true
fi

if $AVX2_OK; then
    log "AVX2/FMA detectado - compilando otimizado para ESTA máquina (-march=native)."
    warn "O binário resultante só vai rodar em CPUs com AVX2/FMA - NÃO vai funcionar no AMD C-60."
    C_CXX_FLAGS="-O2 -march=native -mtune=native"
    GGML_AVX=ON; GGML_AVX2=ON; GGML_FMA=ON; GGML_F16C=ON
else
    log "AVX2/FMA não detectado (ou CPU é o próprio C-60/Bobcat) - usando build seguro/portável (btver1, sem AVX)."
    # -march=btver1 é o alvo real do GCC/Clang para AMD Bobcat (C-Series,
    # ex.: C-60). Mais confiável que desligar flag por flag manualmente.
    C_CXX_FLAGS="-O2 -march=btver1 -mtune=btver1 -mno-avx -mno-avx2 -mno-fma -mno-f16c -mno-avx512f"
    GGML_AVX=OFF; GGML_AVX2=OFF; GGML_FMA=OFF; GGML_F16C=OFF
fi

cmake .. \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_INSTALL_PREFIX="${INSTALL_PREFIX}" \
    -DLLAMA_BUILD_SERVER=ON \
    -DLLAMA_BUILD_TOOLS=ON \
    -DGGML_NATIVE=OFF \
    -DGGML_OPENMP=ON \
    -DGGML_AVX=${GGML_AVX} \
    -DGGML_AVX2=${GGML_AVX2} \
    -DGGML_AVX512=OFF \
    -DGGML_AVX_VNNI=OFF \
    -DGGML_FMA=${GGML_FMA} \
    -DGGML_F16C=${GGML_F16C} \
    -DGGML_BMI2=OFF \
    -DGGML_CPU_ALL_VARIANTS=OFF \
    -DGGML_BACKEND_DL=OFF \
    -DCMAKE_C_FLAGS="$C_CXX_FLAGS" \
    -DCMAKE_CXX_FLAGS="$C_CXX_FLAGS"

# ─── Paralelismo do build (núcleos/threads usados pelo 'make') ────────────
# Por padrão usa TODOS os núcleos/threads disponíveis na máquina que está
# compilando (pode ser bem mais rápido que o hardware alvo, ex.: compilar
# num PC atual para depois instalar no AMD C-60). Para limitar manualmente
# (ex.: pouca RAM, ou pra não travar a máquina durante o link), comente a
# linha de baixo e descomente a fixa.
JOBS="$(nproc 2>/dev/null || echo 2)"   # usa todos os núcleos/threads disponíveis
# JOBS=2                                  # ou fixe um número manual de jobs (ex.: 2 para o AMD C-60)

log "Compilando com -j${JOBS}..."
make -j"${JOBS}"

log "Instalando binários compilados em ${INSTALL_PREFIX}..."
make install

popd >/dev/null

# =============================================================================
# Localiza o binário do servidor (nome varia conforme a versão do llama.cpp)
# =============================================================================
BINARY_PATH=""
for candidate in "$INSTALL_PREFIX/bin/llama-server" "$INSTALL_PREFIX/bin/server"; do
    if [[ -x "$candidate" ]]; then
        BINARY_PATH="$candidate"
        break
    fi
done

if [[ -z "$BINARY_PATH" ]]; then
    BINARY_PATH="$(find "$INSTALL_PREFIX" -maxdepth 3 -type f \( -name 'llama-server' -o -name 'server' \) 2>/dev/null | head -n1)"
fi

[[ -n "$BINARY_PATH" && -x "$BINARY_PATH" ]] || err "llama-server não foi gerado em ${INSTALL_PREFIX}/bin. Verifique o log de 'make'."

log "Binário encontrado: ${BINARY_PATH}"
log "Testando llama-server (--version)..."

if ! "$BINARY_PATH" --version >/dev/null 2>&1; then
    err "llama-server incompatível. Build contém instruções não suportadas pela CPU (verifique 'cat /proc/cpuinfo | grep flags')."
fi

# --version sozinho NÃO passa pelos kernels de matmul/quantização, que são
# onde instruções AVX/AVX2 costumam aparecer. Por isso, no modo seguro
# (sem AVX2 detectado), fazemos também uma checagem estática no binário:
# se houver registradores ymm/zmm (AVX/AVX512) ou o prefixo VEX, o binário
# vai dar "Illegal instruction" no C-60 mesmo passando no --version.
# No modo otimizado (AVX2 detectado) isso é esperado e correto, então a
# checagem é pulada.
if $AVX2_OK; then
    log "Build otimizado (AVX2) - pulando checagem de ausência de AVX (é esperado ter AVX aqui)."
else
    log "Verificando estaticamente se há instruções AVX/AVX2/AVX512 no binário..."
    if command -v objdump >/dev/null 2>&1; then
        if objdump -d "$BINARY_PATH" 2>/dev/null | grep -qiE '%ymm[0-9]|%zmm[0-9]|vex\.'; then
            err "O binário contém instruções AVX/AVX2/AVX512 (registradores ymm/zmm). Isso vai causar 'Illegal instruction' no AMD C-60. Revise as flags GGML_* / CMAKE_*_FLAGS."
        fi
        log "Nenhuma instrução AVX/AVX2/AVX512 encontrada. Binário compatível com AMD C-60."
else
    warn "objdump não encontrado (instale 'binutils') - pulando checagem estática de instruções AVX. Recomendado para não empacotar um binário quebrado."
    fi
fi

log "llama-server compatível."

# =============================================================================
# Modelo
# =============================================================================
MODEL_DEST="${BUILD_ROOT}/BUILD/${MODEL_FILE}"
log "Baixando modelo Qwen2.5-Coder-0.5B..."
curl -L --fail --retry 3 --progress-bar -o "$MODEL_DEST" "$MODEL_URL" \
    || err "Falha ao baixar o modelo. Verifique sua conexão ou a URL: $MODEL_URL"
[[ -s "$MODEL_DEST" ]] || err "Arquivo do modelo baixado está vazio."
log "Modelo baixado ($(du -h "$MODEL_DEST" | cut -f1))."

# =============================================================================
# Ícone
# =============================================================================
ICON_DEST="${BUILD_ROOT}/BUILD/${ICON_FILE}"
log "Baixando ícone..."
curl -L --fail --retry 3 --progress-bar -o "$ICON_DEST" "$ICON_URL" \
    || warn "Falha ao baixar o ícone, seguindo sem ele."

# =============================================================================
# Montagem do Staging
# =============================================================================
mkdir -p "${STAGE}${INSTALL_DIR}/bin"
mkdir -p "${STAGE}/usr/share/icons/hicolor/scalable/apps"
mkdir -p "${STAGE}/usr/bin"
mkdir -p "${STAGE}/lib/systemd/system"
mkdir -p "${STAGE}/usr/share/applications"
mkdir -p "${STAGE}/usr/share/metainfo"
mkdir -p "${STAGE}/usr/share/doc/${PKG_NAME}"
mkdir -p "${STAGE}/DEBIAN"

install -m755 "$BINARY_PATH" "${STAGE}${INSTALL_DIR}/bin/llama-server"
install -m644 "$MODEL_DEST" "${STAGE}${INSTALL_DIR}/${MODEL_FILE}"
[[ -f "$ICON_DEST" ]] && install -m644 "$ICON_DEST" "${STAGE}/usr/share/icons/hicolor/scalable/apps/${APP_ID}.svg"

# Comando global
cat > "${STAGE}/usr/bin/openclaude" <<EOF
#!/bin/sh

if [ "\$1" = "--version" ] || [ "\$1" = "-v" ]; then
    exec ${INSTALL_DIR}/bin/llama-server --version
fi

exec ${INSTALL_DIR}/bin/llama-server \
    -m ${INSTALL_DIR}/${MODEL_FILE} \
    "\$@"
EOF
chmod 755 "${STAGE}/usr/bin/openclaude"

# Serviço systemd (inicia automaticamente após instalação, ver postinst)
cat > "${STAGE}/lib/systemd/system/openclaude.service" <<EOF
[Unit]
Description=OpenClaude Llama Server (AMD C-60 build)
After=network.target

[Service]
Type=simple
User=root
ExecStart=${INSTALL_DIR}/bin/llama-server \
    -m ${INSTALL_DIR}/${MODEL_FILE} \
    --host 127.0.0.1 \
    --port 11434 \
    --ctx-size 1024 \
    -t 2
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# Desktop launcher (nome = APP_ID, para casar com o metainfo.xml e o ícone)
cat > "${STAGE}/usr/share/applications/${APP_ID}.desktop" <<EOF
[Desktop Entry]
Name=OpenClaude
Comment=OpenClaude AMD C60 Local AI
Exec=${INSTALL_DIR}/bin/llama-server -m ${INSTALL_DIR}/${MODEL_FILE} --host 127.0.0.1 --port 11434 -t 2
Icon=${APP_ID}
Terminal=true
Type=Application
Categories=Development;Utility;
Keywords=ai;llama;qwen;local;
EOF

# Metainfo AppStream (é isso que faz a GNOME Software/KDE Discover
# mostrarem descrição, ícone e SCREENSHOTS do app instalado)
cat > "${STAGE}/usr/share/metainfo/${APP_ID}.metainfo.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<component type="desktop-application">
  <id>${APP_ID}</id>
  <name>OpenClaude</name>
  <summary>IA local baseada em llama.cpp e Qwen2.5-Coder</summary>
  <metadata_license>MIT</metadata_license>
  <project_license>MIT</project_license>
  <developer_name>Infogyba Soluções em TI</developer_name>
  <description>
    <p>
      OpenClaude expõe um servidor local compatível com a API da OpenAI
      (llama-server + Qwen2.5-Coder-0.5B), otimizado para CPUs sem
      AVX/AVX2/FMA como o AMD C-60. Pode ser usado com editores como o
      VSCode através da extensão continue.dev.
    </p>
  </description>
  <launchable type="desktop-id">${APP_ID}.desktop</launchable>
  <content_rating type="oars-1.1"/>
  <screenshots>
    <screenshot type="default">
      <caption>OpenClaude na GNOME Software</caption>
      <image>${SCREENSHOTS_BASE_URL}/gnome-software.png</image>
    </screenshot>
    <screenshot>
      <caption>OpenClaude como modelo local no Continue.dev (VSCode)</caption>
      <image>${SCREENSHOTS_BASE_URL}/continue-vscode.png</image>
    </screenshot>
  </screenshots>
  <url type="homepage">https://github.com/SEU_USUARIO/SEU_REPO</url>
  <releases>
    <release version="${PKG_VERSION}" date="$(date +%Y-%m-%d)"/>
  </releases>
</component>
EOF

# Debian metadata
cat > "${STAGE}/usr/share/doc/${PKG_NAME}/copyright" <<EOF
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: openclaude-infogyba
Upstream-Contact: Infogyba Soluções em TI <infogyba@gmail.com>
License: MIT
EOF

gzip -9 -c /dev/null > "${STAGE}/usr/share/doc/${PKG_NAME}/changelog.Debian.gz"

INSTALLED_SIZE=$(du -sk "${STAGE}" | cut -f1)

cat > "${STAGE}/DEBIAN/control" <<EOF
Package: ${PKG_NAME}
Version: ${PKG_VERSION}-${PKG_RELEASE}
Architecture: ${ARCH}
Maintainer: Infogyba Soluções em TI <infogyba@gmail.com>
Installed-Size: ${INSTALLED_SIZE}
Depends: libc6 (>=2.17), libstdc++6 (>=5), libgomp1, systemd
Section: utils
Priority: optional
Description: OpenClaude powered by Infogyba
 IA local baseada em llama.cpp e Qwen2.5-Coder, otimizada para CPUs sem
 AVX/AVX2/FMA (ex.: AMD C-60). Expõe API compatível com OpenAI em
 http://127.0.0.1:11434/v1 para uso com ferramentas como continue.dev.
EOF

# Scripts Debian
cat > "${STAGE}/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e

update-desktop-database -q /usr/share/applications 2>/dev/null || true
gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor 2>/dev/null || true

# Atualiza o cache do AppStream para a GNOME Software/KDE Discover
# reconhecerem o novo metainfo.xml (com screenshots) imediatamente,
# sem precisar de reboot/relogin.
if command -v appstreamcli >/dev/null 2>&1; then
    appstreamcli refresh-cache --force >/dev/null 2>&1 || true
fi

if [ -d /run/systemd/system ]; then
    systemctl daemon-reload || true
    systemctl enable openclaude.service || true
    systemctl restart openclaude.service || true
fi

exit 0
EOF

cat > "${STAGE}/DEBIAN/prerm" <<'EOF'
#!/bin/sh
set -e

if [ -d /run/systemd/system ]; then
    systemctl stop openclaude.service 2>/dev/null || true
    systemctl disable openclaude.service 2>/dev/null || true
fi

exit 0
EOF

cat > "${STAGE}/DEBIAN/postrm" <<'EOF'
#!/bin/sh
set -e

update-desktop-database -q /usr/share/applications 2>/dev/null || true
gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor 2>/dev/null || true

if command -v appstreamcli >/dev/null 2>&1; then
    appstreamcli refresh-cache --force >/dev/null 2>&1 || true
fi

if [ -d /run/systemd/system ]; then
    systemctl daemon-reload || true
fi

exit 0
EOF

chmod 755 \
    "${STAGE}/DEBIAN/postinst" \
    "${STAGE}/DEBIAN/prerm" \
    "${STAGE}/DEBIAN/postrm"

# =============================================================================
# Gerar pacote
# =============================================================================
log "Gerando pacote..."

dpkg-deb --build \
    --root-owner-group \
    "${STAGE}" \
    "${BUILD_ROOT}/DEBS/${PKG_FULL_NAME}.deb"

log "Build concluído com sucesso!"
log "Pacote disponível em: ${BUILD_ROOT}/DEBS/${PKG_FULL_NAME}.deb"
log "Instale com: sudo dpkg -i ${BUILD_ROOT}/DEBS/${PKG_FULL_NAME}.deb"
