#!/bin/bash
# =============================================================================
# Script de Build: openclaude-infogyba — Pacote .deb para Debian 13 (Trixie)
# Autor: Infogyba Solucoes em TI <infogyba@gamail.com>
#       OpenBLAS compilado do fonte com detecção de CPU:
#         - AMD C-60 (Bobcat/btver1): -march=btver1 detectado via /proc/cpuinfo
#         - Outras CPUs: -march=native (otimiza para o hardware atual)
#       libopenblas.so embutida em /opt/openclaude-agent/lib (dinâmica)
#       ldconfig configurado via /etc/ld.so.conf.d/openclaude.conf
#       Usuário de sistema 'openclaude' criado no postinst
#       Wrapper /usr/local/bin/openclaude com --version, --status, --health, --models
#       Serviço systemd system scope (boot automático, sem --user)
#       .desktop com Icon= para GNOME e KDE Plasma
#       AppStream metainfo.xml para GNOME Software e KDE Discover
#       Idempotente por sentinelas em ./deb_output/state/*.done
#       Cada etapa verifica sentinela + artefato; trap ERR apaga sentinela em falha
#       Download do modelo usa wget -c para retomar parcialmente
#       Build do llama.cpp preserva CMakeCache entre tentativas
# =============================================================================
set -euo pipefail
export LC_ALL=C

# ---------------------------------------------------------------------------
# Variáveis
# ---------------------------------------------------------------------------
PKG_NAME="openclaude-infogyba"
PKG_VERSION="1.0"
PKG_REVISION="1"                          # equivalente ao Release do RPM
ARCH="amd64"
MAINTAINER="Infogyba Solucoes em TI <contato@infogyba.com.br>"
INSTALL_DIR="/opt/openclaude-agent"
LIB_DIR="${INSTALL_DIR}/lib"
ICON_NAME="openclaude-infogyba"
MODEL_URL="https://huggingface.co/Qwen/Qwen2.5-Coder-1.5B-Instruct-GGUF/resolve/main/qwen2.5-coder-1.5b-instruct-q4_k_m.gguf"
MODEL_FILE="qwen2.5-coder-1.5b-q4_k_m.gguf"
MODEL_MIN_BYTES=838860800                 # 800 MB mínimo
INFER_THREADS=1
BLAS_THREADS=1
BUILD_ROOT="$(pwd)/deb_output"
STATE_DIR="${BUILD_ROOT}/state"
STAGE="${BUILD_ROOT}/staging"
NPROC="$(nproc)"

ICON_SVG_URLS=(
    "https://upload.wikimedia.org/wikipedia/commons/8/8a/Claude_AI_logo.svg"
    "https://cdn.jsdelivr.net/npm/@thesvg/icons/icons/claude.svg"
)

log()  { echo -e "\033[0;32m[INFO]\033[0m  $*"; }
skip() { echo -e "\033[0;36m[SKIP]\033[0m  $*"; }
warn() { echo -e "\033[0;33m[WARN]\033[0m  $*"; }
err()  { echo -e "\033[0;31m[ERRO]\033[0m  $*" >&2; exit 1; }
step() { echo -e "\n\033[1;34m──── $* ────\033[0m"; }

# ---------------------------------------------------------------------------
# Sistema de sentinelas
# ---------------------------------------------------------------------------
mkdir -p "$STATE_DIR"
CURRENT_STEP=""
DEB_NEEDS_REBUILD=false

done_mark()  { touch "${STATE_DIR}/${1}.done"; }
is_done()    { [[ -f "${STATE_DIR}/${1}.done" ]]; }
clear_done() { for s in "$@"; do rm -f "${STATE_DIR}/${s}.done"; done; }

trap '
  if [[ -n "$CURRENT_STEP" ]]; then
    clear_done "$CURRENT_STEP"
    warn "Etapa \"$CURRENT_STEP\" falhou — sentinela removida."
    warn "Corrija o erro e reexecute: ./build-openclaude-infogyba-deb.sh"
  fi
' ERR

# ---------------------------------------------------------------------------
# Detecção de CPU — AMD C-60 (Bobcat/btver1) ou genérico
# ---------------------------------------------------------------------------
detect_march() {
    local model
    model=$(grep -m1 "model name" /proc/cpuinfo 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)
    if echo "$model" | grep -qE "c-60|c60|bobcat|btver1|e-350|e-450|e-240|e-300"; then
        echo "btver1"
    else
        echo "native"
    fi
}
MARCH=$(detect_march)
log "CPU detectada: -march=${MARCH} $([ "$MARCH" = "btver1" ] && echo "(AMD C-60 Bobcat)" || echo "(genérico nativo)")"

# ---------------------------------------------------------------------------
# Estrutura de diretórios — mkdir -p é idempotente
# ---------------------------------------------------------------------------
mkdir -p "${BUILD_ROOT}/build"
mkdir -p "$STAGE${INSTALL_DIR}/bin"
mkdir -p "$STAGE${LIB_DIR}"
mkdir -p "$STAGE/etc/ld.so.conf.d"
mkdir -p "$STAGE/lib/systemd/system"
mkdir -p "$STAGE/usr/share/doc/${PKG_NAME}"
mkdir -p "$STAGE/usr/share/applications"
mkdir -p "$STAGE/usr/share/icons/hicolor/scalable/apps"
mkdir -p "$STAGE/usr/share/metainfo"
mkdir -p "$STAGE/usr/local/bin"
# Diretório de controle do .deb
mkdir -p "$STAGE/DEBIAN"

# ===========================================================================
# ETAPA 1 — Dependências de build
# Sentinela: deps.done
# ===========================================================================
step "1/8 — Dependências de build"
CURRENT_STEP="deps"

if is_done "deps"; then
    skip "Dependências já verificadas."
else
    log "Atualizando lista de pacotes..."
    sudo apt-get update -qq

    BUILD_DEPS=(
        # Compiladores e ferramentas base
        gcc
        g++
        cmake
        git
        curl
        wget
        make
        # Ferramentas de empacotamento Debian
        dpkg-dev
        fakeroot
        # gfortran para OpenBLAS (LAPACK via Fortran)
        gfortran
        # Libs de desenvolvimento para linking estático
        libgomp1
        libstdc++-12-dev
        # Ferramentas de ícone
        librsvg2-bin
        imagemagick
        # AppStream validation (opcional, não bloqueia)
        appstream
        # ldconfig
        libc-bin
    )

    log "Instalando dependências ausentes..."
    sudo apt-get install -y --no-install-recommends "${BUILD_DEPS[@]}"
    done_mark "deps"
fi

# ===========================================================================
# ETAPA 2 — OpenBLAS
# Sentinela: openblas.done
# Artefato: deb_output/build/openblas-install/lib/libopenblas.so
# ===========================================================================
step "2/8 — OpenBLAS (-march=${MARCH})"
CURRENT_STEP="openblas"

OPENBLAS_SRC="${BUILD_ROOT}/build/OpenBLAS"
OPENBLAS_INSTALL="${BUILD_ROOT}/build/openblas-install"
OPENBLAS_LIB="${OPENBLAS_INSTALL}/lib/libopenblas.so"

if is_done "openblas" && [[ -f "$OPENBLAS_LIB" ]]; then
    skip "OpenBLAS já compilado: ${OPENBLAS_LIB}"
else
    # Detecta instalação parcial
    if [[ -d "$OPENBLAS_INSTALL" ]] && [[ ! -f "$OPENBLAS_LIB" ]]; then
        warn "Instalação parcial detectada — limpando openblas-install..."
        rm -rf "$OPENBLAS_INSTALL"
    fi

    # Clone idempotente
    if [[ ! -d "$OPENBLAS_SRC" ]]; then
        log "Clonando OpenBLAS..."
        git clone --depth=1 https://github.com/OpenMathLib/OpenBLAS.git "$OPENBLAS_SRC"
    else
        log "Fonte OpenBLAS já existe — pulando clone."
    fi

    # Limpa objetos parciais sem apagar o fonte
    if [[ ! -f "$OPENBLAS_LIB" ]]; then
        log "Limpando objetos parciais do OpenBLAS..."
        make -C "$OPENBLAS_SRC" clean 2>/dev/null || true
    fi

    mkdir -p "$OPENBLAS_INSTALL"
    log "Compilando OpenBLAS (-march=${MARCH}, sem LTO, ${NPROC} núcleos)..."

    make -C "$OPENBLAS_SRC" -j"${NPROC}" \
        TARGET=GENERIC \
        NUM_THREADS=2 \
        USE_OPENMP=1 \
        NO_LAPACK=0 \
        NO_SHARED=0 \
        NO_STATIC=1 \
        NOFORTRAN=0 \
        COMMON_OPT="-march=${MARCH} -O3 -fno-lto" \
        FCOMMON_OPT="-march=${MARCH} -O3 -fno-lto" \
        PREFIX="$OPENBLAS_INSTALL"

    make -C "$OPENBLAS_SRC" install PREFIX="$OPENBLAS_INSTALL" NO_STATIC=1

    [[ -f "$OPENBLAS_LIB" ]] || err "libopenblas.so não encontrada após make install."
    log "OpenBLAS compilado com sucesso."
    done_mark "openblas"
    DEB_NEEDS_REBUILD=true
fi

# Sincronizar libs no staging
log "Sincronizando libopenblas no staging..."
for f in "${OPENBLAS_INSTALL}/lib"/libopenblas*.so*; do
    [[ -e "$f" ]] || continue
    if [[ -L "$f" ]]; then
        ln -sf "$(readlink "$f")" "${STAGE}${LIB_DIR}/$(basename "$f")" 2>/dev/null || true
    else
        install -m 755 "$f" "${STAGE}${LIB_DIR}/$(basename "$f")"
    fi
done
echo "${LIB_DIR}" > "${STAGE}/etc/ld.so.conf.d/openclaude.conf"

# ===========================================================================
# ETAPA 3 — llama.cpp
# Sentinela: llamacpp.done
# Artefato: deb_output/build/install/bin/llama-server
# CMakeCache preservado entre tentativas — cmake não roda de novo se OK
# ===========================================================================
step "3/8 — llama.cpp (-march=${MARCH})"
CURRENT_STEP="llamacpp"

LLAMACPP_DIR="${BUILD_ROOT}/build/llama.cpp"
LLAMACPP_BUILD="${LLAMACPP_DIR}/build"
BINARY_PATH="${BUILD_ROOT}/build/install/bin/llama-server"

if is_done "llamacpp" && [[ -f "$BINARY_PATH" ]]; then
    skip "llama-server já compilado: ${BINARY_PATH}"
else
    # Clone idempotente
    if [[ ! -d "$LLAMACPP_DIR" ]]; then
        log "Clonando llama.cpp..."
        git clone --depth=1 https://github.com/ggerganov/llama.cpp "$LLAMACPP_DIR"
    else
        log "Fonte llama.cpp já existe — pulando clone."
    fi

    # Se CMakeCache existe, cmake já foi configurado — apenas recompila
    if [[ ! -f "${LLAMACPP_BUILD}/CMakeCache.txt" ]]; then
        log "Configurando cmake..."
        rm -rf "$LLAMACPP_BUILD"
        mkdir -p "$LLAMACPP_BUILD"

        # Flags SIMD: C-60 tem SSE4.1 mas NÃO tem AVX/AVX2/FMA
        # Para CPUs genéricas com native, o compilador decide
        if [[ "$MARCH" == "btver1" ]]; then
            SIMD_FLAGS="-DGGML_AVX=ON -DGGML_AVX2=OFF -DGGML_F16C=ON -DGGML_FMA=OFF"
        else
            SIMD_FLAGS="-DGGML_AVX=ON -DGGML_AVX2=ON -DGGML_F16C=ON -DGGML_FMA=ON"
        fi

        cmake -S "$LLAMACPP_DIR" -B "$LLAMACPP_BUILD" \
            -DCMAKE_BUILD_TYPE=Release \
            -DBUILD_SHARED_LIBS=OFF \
            -DGGML_STATIC=ON \
            -DLLAMA_STATIC=ON \
            -DLLAMA_NATIVE=OFF \
            -DGGML_OPENMP=ON \
            -DGGML_BLAS=ON \
            -DGGML_BLAS_VENDOR=OpenBLAS \
            -DBLAS_LIBRARIES="${OPENBLAS_INSTALL}/lib/libopenblas.so" \
            -DBLAS_INCLUDE_DIRS="${OPENBLAS_INSTALL}/include" \
            $SIMD_FLAGS \
            -DLLAMA_BUILD_SERVER=ON \
            -DLLAMA_SERVER_WEBUI=OFF \
            -DCMAKE_C_FLAGS="-march=${MARCH} -O3 -fno-lto" \
            -DCMAKE_CXX_FLAGS="-march=${MARCH} -O3 -fno-lto" \
            -DCMAKE_EXE_LINKER_FLAGS="-static-libgcc -static-libstdc++ -Wl,-rpath,${LIB_DIR}" \
            -DCMAKE_INSTALL_PREFIX="${BUILD_ROOT}/build/install"
    else
        log "CMakeCache.txt encontrado — pulando configuração, retomando compilação..."
    fi

    log "Compilando llama.cpp (${NPROC} núcleos)..."
    cmake --build "$LLAMACPP_BUILD" --parallel "$NPROC"
    cmake --install "$LLAMACPP_BUILD"

    [[ -f "$BINARY_PATH" ]] || err "Binário não encontrado após compilação."

    # Verificar dependências
    if command -v ldd &>/dev/null; then
        DEPS=$(ldd "$BINARY_PATH" 2>&1 || true)
        echo "$DEPS" | grep -qiE "libggml|libllama" && \
            warn "AVISO: dependências libggml/libllama dinâmicas detectadas!" || \
            log "OK: sem libggml/libllama dinâmicas."
        echo "$DEPS" | grep -qi "openblas" && \
            log "OK: libopenblas.so linkada dinamicamente (correto)." || \
            warn "OpenBLAS não detectado — verifique a compilação."
    fi

    log "llama-server compilado com sucesso."
    done_mark "llamacpp"
    DEB_NEEDS_REBUILD=true
fi

# Sincronizar binário no staging
install -m 755 "$BINARY_PATH" "${STAGE}${INSTALL_DIR}/bin/llama-server"

# ===========================================================================
# ETAPA 4 — Ícone SVG
# Sentinela: icon.done
# ===========================================================================
step "4/8 — Ícone SVG"
CURRENT_STEP="icon"

ICON_DEST_SVG="${BUILD_ROOT}/build/${ICON_NAME}.svg"
is_valid_svg() { [[ -f "$1" ]] && grep -q "<svg" "$1" 2>/dev/null; }

if is_done "icon" && is_valid_svg "$ICON_DEST_SVG"; then
    skip "Ícone SVG já existe e é válido."
else
    log "Obtendo ícone SVG do Claude..."
    ICON_DOWNLOADED=false
    for url in "${ICON_SVG_URLS[@]}"; do
        log "  Tentando: $url"
        if curl -fsSL --max-time 30 -o "$ICON_DEST_SVG" "$url" \
           && is_valid_svg "$ICON_DEST_SVG"; then
            log "  OK: $url"
            ICON_DOWNLOADED=true
            break
        fi
        rm -f "$ICON_DEST_SVG"
    done

    # Fallback: SVG embutido (simple-icons, CC0, cor #D97757 Anthropic)
    if [[ "$ICON_DOWNLOADED" == false ]]; then
        warn "URLs indisponíveis — usando SVG embutido..."
        cat > "$ICON_DEST_SVG" << 'SVGEOF'
<svg fill="#D97757" role="img" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg">
  <title>Claude</title>
  <path d="m4.7144 15.9555 4.7174-2.6471.079-.2307-.079-.1275h-.2307l-.7893-.0486-2.6956-.0729-2.3375-.0971-2.2646-.1214-.5707-.1215-.5343-.7042.0546-.3522.4797-.3218.686.0608 1.5179.1032 2.2767.1578 1.6514.0972 2.4468.255h.3886l.0546-.1579-.1336-.0971-.1032-.0972L6.973 9.8356l-2.55-1.6879-1.3356-.9714-.7225-.4918-.3643-.4614-.1578-1.0078.6557-.7225.8803.0607.2246.0607.8925.686 1.9064 1.4754 2.4893 1.8336.3643.3035.1457-.1032.0182-.0728-.164-.2733-1.3539-2.4467-1.445-2.4893-.6435-1.032-.17-.6194c-.0607-.255-.1032-.4674-.1032-.7285L6.287.1335 6.6997 0l.9957.1336.419.3642.6192 1.4147 1.0018 2.2282 1.5543 3.0296.4553.8985.2429.8318.091.255h.1579v-.1457l.1275-1.706.2368-2.0947.2307-2.6957.0789-.7589.3764-.9107.7468-.4918.5828.2793.4797.686-.0668.4433-.2853 1.8517-.5586 2.9021-.3643 1.9429h.2125l.2429-.2429.9835-1.3053 1.6514-2.0643.7286-.8196.85-.9046.5464-.4311h1.0321l.759 1.1293-.3400.6193-.9957 1.1535-1.3296 1.7667-1.2628 1.6453-.3278.5221.1275.1457h.255l2.0643-.4311 2.8049-.4311 1.3721-.1457.7650.3157.2550.7832-.3886.6254-.5221.2307-1.5786.2854-2.9507.4800-1.9551.3521-.1032.1336.0911.1700 1.4450 1.5300 1.8093 2.0157.9835 1.2143.3279.6072-.1943.8378-.7589.3278-.5100-.1214-1.0321-1.1414-1.6696-1.6150-.9229-1.1293-.3035-.1275-.1457.1154v.2307l.3278 1.5057.6436 2.5136.4311 1.9429.0486.9835-.4554.7589-.8560.1457-.5950-.3643-.2975-.4675-.7346-2.1129-.6557-2.2160-.5343-1.9186-.0850-.1700h-.1579l-.1093.1457-.8318 1.5664-1.5300 2.5743-.9957 1.5907-.5464.7225-.7468.3157-1.0078-.5707.0122-1.0443.3279-.5221.9957-1.5422 1.5178-2.5864.7711-1.5300.1154-.2611-.0729-.0850h-.2064l-1.5786.8864-2.6228 1.4390-1.8215.9957-.9350.3278-.8317-.2307-.3400-.8257.2064-.7043.4311-.3399z"/>
</svg>
SVGEOF
        log "SVG embutido gerado."
    fi
    done_mark "icon"
    DEB_NEEDS_REBUILD=true
fi

# Sincronizar ícone no staging
install -m 644 "$ICON_DEST_SVG" \
    "${STAGE}/usr/share/icons/hicolor/scalable/apps/${ICON_NAME}.svg"

# Gerar PNGs — apenas os tamanhos ausentes
if command -v rsvg-convert &>/dev/null;  then CTOOL="rsvg"
elif command -v convert &>/dev/null;     then CTOOL="imagemagick"
else                                          CTOOL="none"; warn "Sem ferramenta SVG→PNG."; fi

for SIZE in 16 24 32 48 64 128 256 512; do
    PDIR="${STAGE}/usr/share/icons/hicolor/${SIZE}x${SIZE}/apps"
    mkdir -p "$PDIR"
    POUT="${PDIR}/${ICON_NAME}.png"
    [[ -f "$POUT" ]] && continue
    [[ "$CTOOL" == "rsvg" ]] && \
        rsvg-convert -w "$SIZE" -h "$SIZE" -o "$POUT" "$ICON_DEST_SVG" 2>/dev/null && continue
    [[ "$CTOOL" == "imagemagick" ]] && \
        convert -background none "$ICON_DEST_SVG" -resize "${SIZE}x${SIZE}" "$POUT" \
        2>/dev/null && continue
    true
done

# ===========================================================================
# ETAPA 5 — Modelo
# Sentinela: model.done
# wget -c retoma download interrompido
# ===========================================================================
step "5/8 — Modelo Qwen2.5-Coder"
CURRENT_STEP="model"

MODEL_DEST="${BUILD_ROOT}/build/${MODEL_FILE}"

_model_ok() {
    [[ -f "$MODEL_DEST" ]] && \
    [[ $(stat -c%s "$MODEL_DEST" 2>/dev/null || echo 0) -ge $MODEL_MIN_BYTES ]]
}

if is_done "model" && _model_ok; then
    skip "Modelo já completo: $(du -sh "$MODEL_DEST" | cut -f1)"
else
    if [[ -f "$MODEL_DEST" ]]; then
        warn "Arquivo parcial ($(du -sh "$MODEL_DEST" | cut -f1)) — retomando download..."
    else
        log "Baixando modelo Qwen2.5-Coder 1.5B Q4_K_M (~950 MB)..."
    fi
    wget -c "$MODEL_URL" -O "$MODEL_DEST" \
        || { rm -f "$MODEL_DEST"; err "Falha no download do modelo."; }
    _model_ok || err "Modelo incompleto após download ($(du -sh "$MODEL_DEST" | cut -f1))."
    log "Modelo completo: $(du -sh "$MODEL_DEST" | cut -f1)"
    done_mark "model"
    DEB_NEEDS_REBUILD=true
fi

install -m 644 "$MODEL_DEST" "${STAGE}${INSTALL_DIR}/${MODEL_FILE}"

# ===========================================================================
# ETAPA 6 — Arquivos de configuração do staging
# Sentinela: staging.done
# Regenera se qualquer etapa anterior foi refeita
# ===========================================================================
step "6/8 — Arquivos de configuração"
CURRENT_STEP="staging"

if is_done "staging" && [[ "$DEB_NEEDS_REBUILD" == false ]]; then
    skip "Arquivos de configuração já gerados."
else
    log "Gerando arquivos de configuração no staging..."

    # --- Wrapper /usr/local/bin/openclaude ---
    cat > "${STAGE}/usr/local/bin/openclaude" << 'WRAPEOF'
#!/bin/bash
# Wrapper openclaude — Infogyba Solucoes em TI
LLAMA_BIN="/opt/openclaude-agent/bin/llama-server"
PKG_VERSION="1.0"
API_PORT="11434"

case "${1:-}" in
    --version|-v)
        echo "openclaude-infogyba versao ${PKG_VERSION} (Infogyba Solucoes em TI)"
        [[ -x "$LLAMA_BIN" ]] && \
            echo "llama-server: $("$LLAMA_BIN" --version 2>&1 | head -n 1)" || \
            echo "llama-server: binario nao encontrado em $LLAMA_BIN"
        ;;
    --status|-s)
        systemctl status openclaude.service --no-pager 2>/dev/null || \
            echo "Servico nao encontrado ou sem permissao."
        ;;
    --health)
        curl -sf "http://127.0.0.1:${API_PORT}/health" && echo || \
            echo "API indisponivel. Verifique: openclaude --status"
        ;;
    --models)
        curl -sf "http://127.0.0.1:${API_PORT}/v1/models" | \
            python3 -c "import sys,json; [print(' -',m['id']) for m in json.load(sys.stdin).get('data',[])]" \
            2>/dev/null || curl -sf "http://127.0.0.1:${API_PORT}/v1/models"
        ;;
    --help|-h|"")
        echo "Uso: openclaude [--version|--status|--health|--models|--help]"
        ;;
    *)
        echo "Opcao desconhecida: $1. Use: openclaude --help"
        exit 1
        ;;
esac
WRAPEOF
    chmod 755 "${STAGE}/usr/local/bin/openclaude"

    # --- Serviço systemd (system scope — boot automático sem --user) ---
    cat > "${STAGE}/lib/systemd/system/openclaude.service" << SVCEOF
[Unit]
Description=OpenClaude Llama Server (Infogyba Solucoes em TI)
After=network.target
Wants=network.target

[Service]
Type=exec
User=openclaude
Group=openclaude

# Controle de threads — AMD C-60 (2 nucleos / Bobcat)
# 1 thread livre para o compositor Wayland/X11 sem stutters
Environment="OMP_NUM_THREADS=${INFER_THREADS}"
Environment="OPENBLAS_NUM_THREADS=${BLAS_THREADS}"
Environment="OPENBLAS_CORETYPE=BARCELONA"
Environment="GOTO_NUM_THREADS=${BLAS_THREADS}"
Environment="LD_LIBRARY_PATH=${LIB_DIR}"

ExecStartPre=/bin/sh -c 'test -x ${INSTALL_DIR}/bin/llama-server || (echo "ERRO: binario nao encontrado" && exit 1)'
ExecStartPre=/bin/sh -c 'test -f ${INSTALL_DIR}/${MODEL_FILE} || (echo "ERRO: modelo nao encontrado" && exit 1)'
ExecStart=${INSTALL_DIR}/bin/llama-server \
    -m ${INSTALL_DIR}/${MODEL_FILE} \
    --host 127.0.0.1 \
    --port 11434 \
    --ctx-size 2048 \
    --threads ${INFER_THREADS} \
    --alias qwen2.5-coder-1.5b
Restart=on-failure
RestartSec=10
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=${INSTALL_DIR}
PrivateTmp=yes
StandardOutput=journal
StandardError=journal
SyslogIdentifier=openclaude

[Install]
WantedBy=multi-user.target
SVCEOF

    # --- .desktop (GNOME + KDE Plasma) ---
    # KDE Discover e GNOME Software leem o mesmo .desktop
    # Icon= sem extensão — hicolor theme resolve para SVG ou PNG automaticamente
    cat > "${STAGE}/usr/share/applications/${PKG_NAME}.desktop" << DESKTOPEOF
[Desktop Entry]
Type=Application
Name=Openclaude Infogyba
GenericName=Assistente IA Local
Comment=Servidor LLM local com Qwen2.5-Coder — Infogyba Solucoes em TI
Icon=${ICON_NAME}
Exec=xdg-open http://127.0.0.1:11434
Terminal=false
Categories=Development;Science;Education;Utility;
Keywords=ia;llm;ai;codigo;assistente;claude;qwen;
StartupNotify=true
X-KDE-FormFactor=desktop;
DESKTOPEOF

    # --- AppStream MetaInfo (GNOME Software + KDE Discover) ---
    # O arquivo .metainfo.xml é o padrão freedesktop — lido por ambos
    cat > "${STAGE}/usr/share/metainfo/${PKG_NAME}.metainfo.xml" << XMLEOF
<?xml version="1.0" encoding="UTF-8"?>
<component type="desktop-application">
  <id>${PKG_NAME}</id>
  <name>Openclaude Infogyba</name>
  <summary>Servidor LLM local com Qwen2.5-Coder — Infogyba Solucoes em TI</summary>
  <metadata_license>MIT</metadata_license>
  <project_license>MIT</project_license>

  <developer id="br.com.infogyba">
    <name>Infogyba Solucoes em TI</name>
  </developer>

  <description>
    <p>IA local de alta performance baseada em llama.cpp com modelo Qwen2.5-Coder 1.5B Q4_K_M.</p>
    <p>OpenBLAS compilado do fonte com deteccao automatica de CPU (AMD C-60 Bobcat ou nativa).
    Threads ajustadas para nao causar stutters no compositor. API compativel com OpenAI na porta 11434.</p>
    <ul>
      <li>Modelo Qwen2.5-Coder 1.5B Q4_K_M embutido no pacote</li>
      <li>OpenBLAS otimizado para o hardware (libopenblas.so embutida)</li>
      <li>Binario estatico — sem dependencias libggml/libllama externas</li>
      <li>Servico systemd com inicio automatico no boot</li>
      <li>Compativel com GNOME Software e KDE Discover</li>
    </ul>
  </description>

  <launchable type="desktop-id">${PKG_NAME}.desktop</launchable>
  <icon type="stock">${ICON_NAME}</icon>

  <url type="homepage">https://www.infogyba.com.br</url>
  <url type="bugtracker">mailto:contato@infogyba.com.br</url>

  <categories>
    <category>Development</category>
    <category>Science</category>
    <category>Utility</category>
  </categories>

  <keywords>
    <keyword>ia</keyword>
    <keyword>llm</keyword>
    <keyword>ai</keyword>
    <keyword>claude</keyword>
    <keyword>qwen</keyword>
    <keyword>assistente</keyword>
    <keyword>llama</keyword>
  </keywords>

  <provides>
    <binary>llama-server</binary>
  </provides>

  <releases>
    <release version="${PKG_VERSION}" date="$(date +%Y-%m-%d)">
      <description>
        <p>Build com linking estatico, OpenBLAS otimizado por CPU e modelo Qwen2.5-Coder 1.5B Q4_K_M embutido.</p>
      </description>
    </release>
  </releases>

  <content_rating type="oars-1.1"/>
</component>
XMLEOF

    # --- Documentação ---
    cat > "${STAGE}/usr/share/doc/${PKG_NAME}/copyright" << DOCEOF
Upstream-Name: openclaude-infogyba
Maintainer: Infogyba Solucoes em TI <contato@infogyba.com.br>
License: MIT
Website: https://www.infogyba.com.br
DOCEOF

    cat > "${STAGE}/usr/share/doc/${PKG_NAME}/changelog.Debian" << CLEOF
${PKG_NAME} (${PKG_VERSION}-${PKG_REVISION}) stable; urgency=low

  * Build inicial para Debian 13 (Trixie)
  * OpenBLAS compilado com deteccao automatica de CPU
  * Otimizacao especifica para AMD C-60 (Bobcat/btver1)
  * AppStream metainfo para GNOME Software e KDE Discover

 -- Infogyba Solucoes em TI <contato@infogyba.com.br>  $(date -R)
CLEOF
    gzip -9 -n -f "${STAGE}/usr/share/doc/${PKG_NAME}/changelog.Debian"

    done_mark "staging"
    DEB_NEEDS_REBUILD=true
fi

# ===========================================================================
# ETAPA 7 — Controle do .deb (DEBIAN/)
# Sentinela: control.done
# ===========================================================================
step "7/8 — Controle do pacote .deb"
CURRENT_STEP="control"

if is_done "control" && [[ "$DEB_NEEDS_REBUILD" == false ]]; then
    skip "Arquivos de controle já gerados."
else
    log "Gerando arquivos de controle DEBIAN/..."

    # Calcular tamanho instalado em KB
    INSTALLED_SIZE=$(du -sk "${STAGE}" | cut -f1)

    # --- control ---
    cat > "${STAGE}/DEBIAN/control" << CTRLEOF
Package: ${PKG_NAME}
Version: ${PKG_VERSION}-${PKG_REVISION}
Architecture: ${ARCH}
Maintainer: ${MAINTAINER}
Installed-Size: ${INSTALLED_SIZE}
Depends: libc6 (>= 2.17), libstdc++6, libgomp1
Recommends: curl, python3
Section: devel
Priority: optional
Homepage: https://www.infogyba.com.br
Description: IA local de alta performance — Infogyba Solucoes em TI
 Servidor LLM leve rodando localmente na porta 11434,
 baseado em llama.cpp com modelo Qwen2.5-Coder 1.5B Q4_K_M.
 OpenBLAS compilado com deteccao automatica de CPU (AMD C-60 ou nativo).
 Binario compilado estaticamente — sem dependencias libggml/libllama externas.
 API compativel com OpenAI disponivel em http://127.0.0.1:11434.
CTRLEOF

    # --- conffiles: arquivos de configuração preservados no upgrade ---
    cat > "${STAGE}/DEBIAN/conffiles" << CONFEOF
/etc/ld.so.conf.d/openclaude.conf
CONFEOF

    # --- postinst: executado após instalação ---
    cat > "${STAGE}/DEBIAN/postinst" << 'POSTINSTEOF'
#!/bin/bash
set -e

# Criar grupo openclaude
if ! getent group openclaude >/dev/null; then
    groupadd --system openclaude
fi

# Criar usuário de sistema openclaude (sem shell de login, sem home)
if ! getent passwd openclaude >/dev/null; then
    useradd --system \
            --shell /usr/sbin/nologin \
            --home-dir /opt/openclaude-agent \
            --gid openclaude \
            --comment "OpenClaude Service" \
            openclaude
fi

# Ajustar permissões
chown -R openclaude:openclaude /opt/openclaude-agent
chmod 750 /opt/openclaude-agent/bin/llama-server
chmod 640 /opt/openclaude-agent/*.gguf 2>/dev/null || true

# Wrapper acessível ao grupo openclaude
chown root:openclaude /usr/local/bin/openclaude
chmod 750 /usr/local/bin/openclaude

# Registrar libopenblas.so no ldconfig
ldconfig

# Atualizar caches de ícones e aplicativos
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -f -t /usr/share/icons/hicolor >/dev/null 2>&1 || true
fi
if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database /usr/share/applications >/dev/null 2>&1 || true
fi
if command -v appstreamcli >/dev/null 2>&1; then
    appstreamcli refresh-cache >/dev/null 2>&1 || true
fi

# Ativar e iniciar serviço systemd
if command -v systemctl >/dev/null 2>&1 && systemctl is-system-running --quiet 2>/dev/null; then
    systemctl daemon-reload
    systemctl enable openclaude.service
    systemctl start openclaude.service || \
        echo "[WARN] Falha ao iniciar. Verifique: journalctl -u openclaude -n 30"
else
    echo "[INFO] Systemd nao detectado ou nao ativo."
    echo "[INFO] Execute manualmente:"
    echo "       systemctl daemon-reload"
    echo "       systemctl enable --now openclaude.service"
fi

exit 0
POSTINSTEOF
    chmod 755 "${STAGE}/DEBIAN/postinst"

    # --- prerm: executado antes de remover ---
    cat > "${STAGE}/DEBIAN/prerm" << 'PRERMEOF'
#!/bin/bash
set -e

if command -v systemctl >/dev/null 2>&1; then
    systemctl is-active --quiet openclaude.service 2>/dev/null && \
        systemctl stop openclaude.service || true
    systemctl disable openclaude.service 2>/dev/null || true
fi

exit 0
PRERMEOF
    chmod 755 "${STAGE}/DEBIAN/prerm"

    # --- postrm: executado após remover ---
    cat > "${STAGE}/DEBIAN/postrm" << 'POSTRMEOF'
#!/bin/bash
set -e

if [ "$1" = "purge" ] || [ "$1" = "remove" ]; then
    # Remover usuário de sistema apenas na remoção completa
    if getent passwd openclaude >/dev/null 2>&1; then
        userdel openclaude 2>/dev/null || true
    fi
fi

if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload 2>/dev/null || true
fi

ldconfig 2>/dev/null || true

if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -f -t /usr/share/icons/hicolor >/dev/null 2>&1 || true
fi
if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database /usr/share/applications >/dev/null 2>&1 || true
fi

exit 0
POSTRMEOF
    chmod 755 "${STAGE}/DEBIAN/postrm"

    done_mark "control"
    DEB_NEEDS_REBUILD=true
fi

# ===========================================================================
# ETAPA 8 — Gerar o pacote .deb
# Sentinela: deb.done
# Só regera se alguma etapa anterior foi refeita
# ===========================================================================
step "8/8 — Pacote .deb"
CURRENT_STEP="deb"

DEB_FILE="${BUILD_ROOT}/${PKG_NAME}_${PKG_VERSION}-${PKG_REVISION}_${ARCH}.deb"

if is_done "deb" && [[ -f "$DEB_FILE" ]] && [[ "$DEB_NEEDS_REBUILD" == false ]]; then
    skip "Pacote .deb já existe e está atualizado: ${DEB_FILE}"
else
    log "Ajustando permissões finais do staging..."
    # Debian exige que DEBIAN/ tenha permissões corretas
    find "${STAGE}/DEBIAN" -type f -exec chmod 755 {} \;
    chmod 755 "${STAGE}/DEBIAN"
    # Arquivos regulares: 644; diretórios: 755; executáveis: 755
    find "${STAGE}" -not -path "${STAGE}/DEBIAN*" -type f \
        ! -name "*.so*" ! -name "llama-server" ! -name "openclaude" \
        -exec chmod 644 {} \;
    find "${STAGE}" -type d -exec chmod 755 {} \;
    chmod 755 "${STAGE}${INSTALL_DIR}/bin/llama-server"
    chmod 755 "${STAGE}/usr/local/bin/openclaude"

    log "Construindo pacote .deb com fakeroot..."
    fakeroot dpkg-deb --build --root-owner-group "$STAGE" "$DEB_FILE"

    [[ -f "$DEB_FILE" ]] || err "Pacote .deb não encontrado após dpkg-deb."
    log "Pacote gerado: ${DEB_FILE} ($(du -sh "$DEB_FILE" | cut -f1))"

    # Verificar conteúdo do pacote
    log "Verificando conteúdo do pacote:"
    dpkg-deb --info "$DEB_FILE"

    done_mark "deb"
fi

# ---------------------------------------------------------------------------
# Concluído
# ---------------------------------------------------------------------------
CURRENT_STEP=""
DONE_LIST=$(ls "${STATE_DIR}"/*.done 2>/dev/null | xargs -I{} basename {} .done | tr '\n' ' ')

echo ""
log "========================================================="
log "Build finalizado!"
log "Pacote : ${DEB_FILE}"
log "Tamanho: $(du -sh "$DEB_FILE" | cut -f1)"
log "Estado : ${DONE_LIST}"
log ""
log "Instalar:"
log "  sudo apt install ${DEB_FILE}"
log "  # ou: sudo dpkg -i ${DEB_FILE} && sudo apt-get install -f"
log ""
log "Verificar conteudo:"
log "  dpkg-deb -c ${DEB_FILE}"
log "  dpkg -l ${PKG_NAME}"
log ""
log "Verificar dependencias do binario:"
log "  ldd ${BUILD_ROOT}/build/install/bin/llama-server"
log ""
log "Apos instalar:"
log "  sudo systemctl status openclaude.service"
log "  curl http://127.0.0.1:11434/health"
log "  curl http://127.0.0.1:11434/v1/models"
log "  openclaude --version"
log ""
log "Adicionar usuario ao grupo openclaude (para usar o wrapper):"
log "  sudo usermod -aG openclaude \$USER && newgrp openclaude"
log ""
log "Usar os 2 nucleos do C-60 (sem desktop ativo):"
log "  sudo systemctl edit openclaude.service"
log "  # [Service]"
log "  # Environment=OMP_NUM_THREADS=2"
log "  # Environment=OPENBLAS_NUM_THREADS=2"
log "  # ExecStart="
log "  # ExecStart=${INSTALL_DIR}/bin/llama-server -m ${INSTALL_DIR}/${MODEL_FILE} --host 127.0.0.1 --port 11434 --ctx-size 2048 --threads 2 --alias qwen2.5-coder-1.5b"
log "  sudo systemctl daemon-reload && sudo systemctl restart openclaude.service"
log ""
log "Desinstalar:"
log "  sudo apt remove ${PKG_NAME}"
log "  sudo apt purge ${PKG_NAME}  # remove usuario openclaude tambem"
log ""
log "Forcando rebuild de etapa especifica:"
log "  rm deb_output/state/llamacpp.done   # recompila llama.cpp"
log "  rm deb_output/state/openblas.done   # recompila OpenBLAS"
log "  rm deb_output/state/model.done      # rebaixa modelo"
log "  rm deb_output/state/*.done          # rebuild completo"
log "========================================================="
