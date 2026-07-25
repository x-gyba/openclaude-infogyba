#!/bin/bash
set -e

# =============================================================================
# OpenClaude - Build .rpm para Fedora 44 (Infogyba Soluções em TI)
# Compila llama.cpp + empacota llama-server + Qwen2.5-Coder-0.5B em .rpm
# Alvo: CPUs sem AVX/AVX2/FMA (ex.: AMD C-60 / Bobcat)
# =============================================================================

log() { echo -e "\e[32m[INFO]\e[0m $*"; }
warn() { echo -e "\e[33m[AVISO]\e[0m $*"; }
err() { echo -e "\e[31m[ERRO]\e[0m $*" >&2; exit 1; }

# =============================================================================
# Checa e instala dependências automaticamente (dnf/apt)
# =============================================================================
REQUIRED_BINS=(git cmake make curl rpmbuild gzip objdump)
MISSING=()
for bin in "${REQUIRED_BINS[@]}"; do
    command -v "$bin" >/dev/null 2>&1 || MISSING+=("$bin")
done

if [[ ${#MISSING[@]} -gt 0 ]]; then
    log "Dependências ausentes: ${MISSING[*]}. Instalando automaticamente..."
    if command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y git cmake make curl rpm-build gzip gcc gcc-c++ binutils systemd-rpm-macros
    elif command -v apt-get >/dev/null 2>&1; then
        sudo apt-get update -qq
        sudo apt-get install -y git cmake make curl rpm gzip build-essential binutils
    else
        err "Gerenciador de pacotes não reconhecido (dnf/apt). Instale manualmente: ${MISSING[*]}"
    fi

    STILL_MISSING=()
    for bin in "${REQUIRED_BINS[@]}"; do
        command -v "$bin" >/dev/null 2>&1 || STILL_MISSING+=("$bin")
    done
    [[ ${#STILL_MISSING[@]} -eq 0 ]] || err "Não foi possível instalar automaticamente: ${STILL_MISSING[*]}. Instale manualmente e rode o script de novo."
    log "Dependências instaladas com sucesso."
fi

CURRENT_DIR="$(pwd)"
BUILD_ROOT="${CURRENT_DIR}/rpm_output"
rm -rf "$BUILD_ROOT"

# =============================================================================
# Variáveis
# =============================================================================
LLAMACPP_DIR="$BUILD_ROOT/llama.cpp"
INSTALL_PREFIX="${BUILD_ROOT}/BUILD/install"
LLAMACPP_REF="${LLAMACPP_REF:-master}"

MODEL_FILE="qwen2.5-coder-0.5b-instruct-q4_k_m.gguf"
MODEL_URL="https://huggingface.co/Qwen/Qwen2.5-Coder-0.5B-Instruct-GGUF/resolve/main/qwen2.5-coder-0.5b-instruct-q4_k_m.gguf"
ICON_FILE="icon.svg"
ICON_URL="https://raw.githubusercontent.com/lucide-icons/lucide/main/icons/bot.svg"

PKG_NAME="openclaude"
PKG_VERSION="1.1.0"
PKG_RELEASE="1"
DIST_TAG="fc44"
ARCH="x86_64"
INSTALL_DIR="/opt/openclaude-agent"
MAINTAINER="Infogyba Soluções em TI <infogyba@gmail.com>"

# Identidade AppStream (mesma nos 3 pacotes - deb/rpm/flatpak - para a
# GNOME Software/KDE Discover reconhecerem como o mesmo app).
APP_ID="com.infogyba.OpenClaude"

# URL base do repositório GitHub onde ficam os screenshots exibidos na
# GNOME Software. Troque SEU_USUARIO/SEU_REPO pelo caminho real do seu
# repositório antes de publicar - as imagens precisam existir em
# screenshots/ dentro do repo (ver README para especificações).
SCREENSHOTS_BASE_URL="${SCREENSHOTS_BASE_URL:-https://raw.githubusercontent.com/SEU_USUARIO/SEU_REPO/main/screenshots}"

RPMBUILD_ROOT="${BUILD_ROOT}/rpmbuild"
mkdir -p "${RPMBUILD_ROOT}"/{SPECS,SOURCES,BUILD,RPMS,SRPMS} "$BUILD_ROOT/BUILD" "$INSTALL_PREFIX"

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
# Se a máquina que está compilando tiver AVX2+FMA, compila otimizado pra
# ela (-march=native). Senão - como o próprio AMD C-60 (Bobcat) - cai
# automaticamente pro modo seguro/portável de sempre (btver1, sem AVX).
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
    # -march=btver1 é o alvo real do GCC/Clang para AMD Bobcat (C-Series, ex.: C-60).
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
# compilando. Para limitar manualmente, comente a linha de baixo e
# descomente a fixa.
JOBS="$(nproc 2>/dev/null || echo 2)"   # usa todos os núcleos/threads disponíveis
# JOBS=2                                  # ou fixe um número manual de jobs (ex.: 2 para o AMD C-60)

log "Compilando com -j${JOBS}..."
make -j"${JOBS}"

log "Instalando binários compilados em ${INSTALL_PREFIX}..."
make install
popd >/dev/null

# =============================================================================
# Localiza o binário do servidor
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
if ! "$BINARY_PATH" --version >/dev/null 2>&1; then
    err "llama-server incompatível. Build contém instruções não suportadas pela CPU."
fi

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
        warn "objdump não encontrado (instale 'binutils') - pulando checagem estática de instruções AVX."
    fi
fi

log "llama-server compatível."

# =============================================================================
# Modelo e ícone
# =============================================================================
MODEL_DEST="${RPMBUILD_ROOT}/SOURCES/${MODEL_FILE}"
log "Baixando modelo Qwen2.5-Coder-0.5B..."
curl -L --fail --retry 3 --progress-bar -o "$MODEL_DEST" "$MODEL_URL" \
    || err "Falha ao baixar o modelo. Verifique sua conexão ou a URL: $MODEL_URL"
[[ -s "$MODEL_DEST" ]] || err "Arquivo do modelo baixado está vazio."

ICON_DEST="${RPMBUILD_ROOT}/SOURCES/${ICON_FILE}"
log "Baixando ícone..."
curl -L --fail --retry 3 --progress-bar -o "$ICON_DEST" "$ICON_URL" \
    || warn "Falha ao baixar o ícone, seguindo sem ele."

cp "$BINARY_PATH" "${RPMBUILD_ROOT}/SOURCES/llama-server"

# =============================================================================
# Arquivos auxiliares empacotados como SOURCES (copiados pelo %install do spec)
# =============================================================================
cat > "${RPMBUILD_ROOT}/SOURCES/openclaude" <<EOF
#!/bin/sh

if [ "\$1" = "--version" ] || [ "\$1" = "-v" ]; then
    exec ${INSTALL_DIR}/bin/llama-server --version
fi

exec ${INSTALL_DIR}/bin/llama-server \
    -m ${INSTALL_DIR}/${MODEL_FILE} \
    "\$@"
EOF

cat > "${RPMBUILD_ROOT}/SOURCES/openclaude.service" <<EOF
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

cat > "${RPMBUILD_ROOT}/SOURCES/openclaude.desktop" <<EOF
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
cat > "${RPMBUILD_ROOT}/SOURCES/openclaude.metainfo.xml" <<EOF
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

# =============================================================================
# Spec file
# =============================================================================
SPEC_FILE="${RPMBUILD_ROOT}/SPECS/${PKG_NAME}.spec"

cat > "$SPEC_FILE" <<EOF
Name:           ${PKG_NAME}
Version:        ${PKG_VERSION}
Release:        ${PKG_RELEASE}%{?dist}
Summary:        OpenClaude powered by Infogyba - IA local baseada em llama.cpp e Qwen2.5-Coder

License:        MIT
URL:            https://github.com/ggml-org/llama.cpp
Vendor:         Infogyba Soluções em TI
Packager:       Infogyba Soluções em TI <infogyba@gmail.com>

Source0:        llama-server
Source1:        ${MODEL_FILE}
Source2:        icon.svg
Source3:        openclaude
Source4:        openclaude.service
Source5:        openclaude.desktop
Source6:        openclaude.metainfo.xml

BuildArch:      ${ARCH}
Requires:       systemd, libgomp, libstdc++
%{?systemd_requires}
BuildRequires:  systemd-rpm-macros

%description
IA local baseada em llama.cpp e Qwen2.5-Coder, otimizada para CPUs sem
AVX/AVX2/FMA (ex.: AMD C-60). Expõe API compatível com OpenAI em
http://127.0.0.1:11434/v1 para uso com ferramentas como continue.dev.
Desenvolvido por Infogyba Soluções em TI.

%prep
# nada a preparar, binários e recursos já vêm prontos em SOURCES

%build
# build já realizado fora do rpmbuild (llama.cpp compilado previamente)

%install
rm -rf %{buildroot}
mkdir -p %{buildroot}${INSTALL_DIR}/bin
mkdir -p %{buildroot}/usr/bin
mkdir -p %{buildroot}/usr/share/icons/hicolor/scalable/apps
mkdir -p %{buildroot}/usr/share/applications
mkdir -p %{buildroot}/usr/share/metainfo
mkdir -p %{buildroot}%{_unitdir}
mkdir -p %{buildroot}/usr/share/doc/%{name}

install -m755 %{SOURCE0} %{buildroot}${INSTALL_DIR}/bin/llama-server
install -m644 %{SOURCE1} %{buildroot}${INSTALL_DIR}/${MODEL_FILE}
install -m644 %{SOURCE2} %{buildroot}/usr/share/icons/hicolor/scalable/apps/${APP_ID}.svg
install -m755 %{SOURCE3} %{buildroot}/usr/bin/openclaude
install -m644 %{SOURCE4} %{buildroot}%{_unitdir}/openclaude.service
install -m644 %{SOURCE5} %{buildroot}/usr/share/applications/${APP_ID}.desktop
install -m644 %{SOURCE6} %{buildroot}/usr/share/metainfo/${APP_ID}.metainfo.xml

cat > %{buildroot}/usr/share/doc/%{name}/copyright <<DOCEOF
Upstream-Name: openclaude-infogyba
Upstream-Contact: Infogyba Soluções em TI <infogyba@gmail.com>
License: MIT
DOCEOF

%files
${INSTALL_DIR}/bin/llama-server
${INSTALL_DIR}/${MODEL_FILE}
/usr/bin/openclaude
/usr/share/icons/hicolor/scalable/apps/${APP_ID}.svg
/usr/share/applications/${APP_ID}.desktop
/usr/share/metainfo/${APP_ID}.metainfo.xml
%{_unitdir}/openclaude.service
/usr/share/doc/%{name}/copyright

%post
%systemd_post openclaude.service
update-desktop-database -q /usr/share/applications 2>/dev/null || :
gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor 2>/dev/null || :
if command -v appstreamcli >/dev/null 2>&1; then
    appstreamcli refresh-cache --force >/dev/null 2>&1 || :
fi
systemctl enable --now openclaude.service >/dev/null 2>&1 || :

%preun
%systemd_preun openclaude.service

%postun
%systemd_postun_with_restart openclaude.service
update-desktop-database -q /usr/share/applications 2>/dev/null || :
gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor 2>/dev/null || :
if command -v appstreamcli >/dev/null 2>&1; then
    appstreamcli refresh-cache --force >/dev/null 2>&1 || :
fi

%changelog
* $(date "+%a %b %d %Y") Infogyba Soluções em TI <infogyba@gmail.com> - ${PKG_VERSION}-${PKG_RELEASE}
- Correção do path do binário llama-server (build antigo gerava "server")
- Atualização do llama.cpp para versão com suporte a Qwen2.5
- Serviço systemd habilitado e iniciado automaticamente na instalação
- Empacotamento para Fedora 44
EOF

# =============================================================================
# Build do RPM
# =============================================================================
log "Gerando pacote RPM..."
rpmbuild --define "_topdir ${RPMBUILD_ROOT}" -bb "$SPEC_FILE"

RPM_PATH="$(find "${RPMBUILD_ROOT}/RPMS" -name '*.rpm' | head -n1)"
[[ -n "$RPM_PATH" ]] || err "Falha ao gerar o RPM."

log "Build concluído com sucesso!"
log "Pacote disponível em: ${RPM_PATH}"
log "Instale com: sudo dnf install ${RPM_PATH}"
