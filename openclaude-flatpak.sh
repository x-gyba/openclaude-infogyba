#!/bin/bash
set -e

# =============================================================================
# OpenClaude - Build + Instala + Autostart Flatpak (Infogyba Soluções em TI)
# Script único: resolve dependências, gera manifesto/ícone/wrapper, compila
# llama.cpp, empacota, instala e habilita o autostart (systemd --user).
# Alvo: CPUs sem AVX/AVX2/FMA (ex.: AMD C-60 / Bobcat)
#
# Compatível com Fedora Atomic (Kinoite/Silverblue): usa o Flatpak
# "org.flatpak.Builder" em vez de fazer layer de flatpak-builder via
# rpm-ostree. Isso é o jeito recomendado pelo próprio projeto Flatpak para
# sistemas imutáveis - não toca na imagem do sistema, não precisa de root
# pra isso e não exige reboot.
# =============================================================================

log() { echo -e "\e[32m[INFO]\e[0m $*"; }
warn() { echo -e "\e[33m[AVISO]\e[0m $*"; }
err() { echo -e "\e[31m[ERRO]\e[0m $*" >&2; exit 1; }

IS_ATOMIC=false
command -v rpm-ostree >/dev/null 2>&1 && IS_ATOMIC=true

# =============================================================================
# 1) flatpak em si - já vem pré-instalado no Kinoite/Silverblue (imagem
#    base), então NUNCA tentamos instalar/fazer layer dele. Só entra em
#    ação se realmente não existir (Debian/Ubuntu/Fedora Workstation etc.).
# =============================================================================
if ! command -v flatpak >/dev/null 2>&1; then
    if $IS_ATOMIC; then
        err "'flatpak' não encontrado, o que é muito incomum em Fedora Atomic. Rode 'rpm-ostree install flatpak' manualmente, reinicie, e execute este script de novo."
    fi
    log "'flatpak' não encontrado. Instalando..."
    if command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y flatpak
    elif command -v apt-get >/dev/null 2>&1; then
        sudo apt-get update -qq
        sudo apt-get install -y flatpak
    else
        err "Gerenciador de pacotes não reconhecido. Instale o 'flatpak' manualmente e rode o script de novo."
    fi
fi
command -v flatpak >/dev/null 2>&1 || err "'flatpak' ainda indisponível após tentativa de instalação."

# =============================================================================
# 2) utilitários básicos (curl, sha256sum) - quase sempre já presentes,
#    inclusive na imagem base do Kinoite. Só tentamos instalar em sistemas
#    NÃO atômicos; em atômicos, se realmente faltar, orientamos usar toolbox
#    em vez de fazer layer.
# =============================================================================
BASIC_MISSING=()
for bin in curl sha256sum; do
    command -v "$bin" >/dev/null 2>&1 || BASIC_MISSING+=("$bin")
done

if [[ ${#BASIC_MISSING[@]} -gt 0 ]]; then
    if $IS_ATOMIC; then
        err "Faltando no sistema: ${BASIC_MISSING[*]}. Isso é muito raro na imagem base do Kinoite. Rode este script de dentro de um 'toolbox' (toolbox enter) em vez de instalar no host."
    fi
    log "Instalando utilitários ausentes: ${BASIC_MISSING[*]}..."
    if command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y curl coreutils
    elif command -v apt-get >/dev/null 2>&1; then
        sudo apt-get update -qq
        sudo apt-get install -y curl coreutils
    fi
fi

# =============================================================================
# 3) remote flathub (escopo --user, não precisa de root)
# =============================================================================
flatpak remote-add --if-not-exists --user flathub https://flathub.org/repo/flathub.flatpakrepo 2>/dev/null || true

# =============================================================================
# 4) flatpak-builder - usa o binário nativo se existir; caso contrário usa
#    o Flatpak "org.flatpak.Builder" do Flathub. Isso funciona igual em
#    Kinoite, Silverblue, Fedora normal, Debian/Ubuntu - sem layers, sem
#    reboot, sem root (fica só no --user do Flatpak).
# =============================================================================
if command -v flatpak-builder >/dev/null 2>&1; then
    log "Usando flatpak-builder nativo do sistema."
    FLATPAK_BUILDER=(flatpak-builder)
else
    log "flatpak-builder nativo não encontrado. Instalando org.flatpak.Builder via Flatpak (sem layer, sem reboot)..."
    flatpak install -y --user --noninteractive flathub org.flatpak.Builder \
        || err "Falha ao instalar org.flatpak.Builder pelo Flathub. Verifique sua conexão e se o remote 'flathub' está configurado."
    FLATPAK_BUILDER=(flatpak run --user org.flatpak.Builder)
    log "Usando flatpak-builder via 'flatpak run org.flatpak.Builder'."
fi

# =============================================================================
# Variáveis do build
# =============================================================================
CURRENT_DIR="$(pwd)"
BUILD_ROOT="${CURRENT_DIR}/flatpak_output"
rm -rf "$BUILD_ROOT"
mkdir -p "$BUILD_ROOT"
cd "$BUILD_ROOT"

APP_ID="com.infogyba.OpenClaude"
MODEL_FILE="qwen2.5-coder-0.5b-instruct-q4_k_m.gguf"
MODEL_URL="https://huggingface.co/Qwen/Qwen2.5-Coder-0.5B-Instruct-GGUF/resolve/main/qwen2.5-coder-0.5b-instruct-q4_k_m.gguf"
ICON_URL="https://raw.githubusercontent.com/lucide-icons/lucide/main/icons/bot.svg"
LLAMACPP_REF="${LLAMACPP_REF:-master}"

# ─── Detecção automática de CPU (AVX2/FMA) ────────────────────────────────
# Se a máquina que está compilando tiver AVX2+FMA, compila otimizado pra
# ela (-march=native). Senão - como o próprio AMD C-60 (Bobcat) - cai
# automaticamente pro modo seguro/portável de sempre (btver1, sem AVX).
# A detecção roda no host (fora do sandbox do flatpak-builder), mas reflete
# a CPU física real, já que não há virtualização de CPU envolvida.
CPU_FLAGS="$(grep -m1 '^flags' /proc/cpuinfo 2>/dev/null || true)"
AVX2_OK=false
if echo "$CPU_FLAGS" | grep -qw avx2 && echo "$CPU_FLAGS" | grep -qw fma; then
    AVX2_OK=true
fi

if $AVX2_OK; then
    log "AVX2/FMA detectado - compilando otimizado para ESTA máquina (-march=native)."
    warn "O binário resultante só vai rodar em CPUs com AVX2/FMA - NÃO vai funcionar no AMD C-60."
    CPU_GGML_OPTS="      - -DGGML_AVX=ON
      - -DGGML_AVX2=ON
      - -DGGML_AVX512=OFF
      - -DGGML_AVX_VNNI=OFF
      - -DGGML_FMA=ON
      - -DGGML_F16C=ON
      - -DGGML_BMI2=OFF
      - -DGGML_CPU_ALL_VARIANTS=OFF
      - -DGGML_BACKEND_DL=OFF
      - -DCMAKE_C_FLAGS=-O2 -march=native -mtune=native
      - -DCMAKE_CXX_FLAGS=-O2 -march=native -mtune=native"
else
    log "AVX2/FMA não detectado (ou CPU é o próprio C-60/Bobcat) - usando build seguro/portável (btver1, sem AVX)."
    CPU_GGML_OPTS="      - -DGGML_AVX=OFF
      - -DGGML_AVX2=OFF
      - -DGGML_AVX512=OFF
      - -DGGML_AVX_VNNI=OFF
      - -DGGML_FMA=OFF
      - -DGGML_F16C=OFF
      - -DGGML_BMI2=OFF
      - -DGGML_CPU_ALL_VARIANTS=OFF
      - -DGGML_BACKEND_DL=OFF
      - -DCMAKE_C_FLAGS=-O2 -march=btver1 -mtune=btver1 -mno-avx -mno-avx2 -mno-fma -mno-f16c -mno-avx512f
      - -DCMAKE_CXX_FLAGS=-O2 -march=btver1 -mtune=btver1 -mno-avx -mno-avx2 -mno-fma -mno-f16c -mno-avx512f"
fi

# Checagem estática de AVX no post-install do manifesto: só faz sentido no
# modo seguro (btver1). No modo otimizado, ter AVX é esperado e correto.
if $AVX2_OK; then
    POST_INSTALL_AVX_CHECK="      - |
        echo \"Build otimizado (AVX2) - pulando checagem de ausência de AVX.\""
else
    POST_INSTALL_AVX_CHECK="      - |
        # O SDK freedesktop já traz binutils/objdump; verificação estática
        # aqui evita empacotar um binário que dá \"Illegal instruction\" no
        # AMD C-60 (--version sozinho não passa pelos kernels de matmul).
        if command -v objdump >/dev/null 2>&1; then
          if objdump -d /app/bin/llama-server | grep -qiE '%ymm[0-9]|%zmm[0-9]|vex\.'; then
            echo \"ERRO: binário contém instruções AVX/AVX2/AVX512, incompatível com AMD C-60\" >&2
            exit 1
          fi
        fi"
fi

# ─── Paralelismo do build (núcleos/threads usados pelo flatpak-builder) ───
# Por padrão (JOBS=0) o flatpak-builder usa TODOS os núcleos/threads
# disponíveis automaticamente. Para limitar manualmente, comente a linha
# de baixo e descomente a fixa.
JOBS=0     # 0 = usa todos os núcleos/threads disponíveis (auto)
# JOBS=2   # ou fixe um número manual de jobs (ex.: 2 para o AMD C-60)

# URL base do repositório GitHub onde ficam os screenshots (usados no
# metainfo.xml, exibidos pela GNOME Software/KDE Discover). Troque
# SEU_USUARIO/SEU_REPO pelo caminho real do seu repositório antes de
# publicar. As imagens precisam existir em screenshots/ dentro do repo -
# veja o README para especificações (tamanho, proporção).
SCREENSHOTS_BASE_URL="${SCREENSHOTS_BASE_URL:-https://raw.githubusercontent.com/SEU_USUARIO/SEU_REPO/main/screenshots}"

# =============================================================================
# Runtime/SDK (escopo --user)
# =============================================================================
log "Garantindo runtime/SDK freedesktop 23.08..."
flatpak install -y --user --noninteractive flathub org.freedesktop.Platform//23.08 org.freedesktop.Sdk//23.08 2>/dev/null \
    || warn "Não foi possível instalar automaticamente o runtime. Garanta o remote 'flathub' configurado."

# =============================================================================
# Baixa modelo + ícone e calcula sha256 (exigido pelo flatpak-builder)
# =============================================================================
log "Baixando modelo Qwen2.5-Coder-0.5B..."
curl -L --fail --retry 3 --progress-bar -o "$MODEL_FILE" "$MODEL_URL" \
    || err "Falha ao baixar o modelo. Verifique sua conexão ou a URL: $MODEL_URL"
[[ -s "$MODEL_FILE" ]] || err "Arquivo do modelo baixado está vazio."
MODEL_SHA="$(sha256sum "$MODEL_FILE" | awk '{print $1}')"
log "Modelo baixado ($(du -h "$MODEL_FILE" | cut -f1)), sha256: ${MODEL_SHA}"

log "Baixando ícone..."
if curl -L --fail --retry 3 --progress-bar -o icon.svg "$ICON_URL"; then
    log "Ícone baixado."
else
    warn "Falha ao baixar o ícone (${ICON_URL}), seguindo sem ele."
    rm -f icon.svg
fi

# =============================================================================
# Gera wrapper, .desktop e metainfo (tudo embutido neste script, via heredoc)
# =============================================================================
cat > openclaude-wrapper <<'EOF'
#!/bin/sh
MODEL=/app/share/openclaude/qwen2.5-coder-0.5b-instruct-q4_k_m.gguf

if [ "$1" = "--version" ] || [ "$1" = "-v" ]; then
    exec /app/bin/llama-server --version
fi

exec /app/bin/llama-server \
    -m "$MODEL" \
    --host 127.0.0.1 \
    --port 11434 \
    --ctx-size 1024 \
    -t 2 \
    "$@"
EOF
chmod 755 openclaude-wrapper

cat > openclaude.desktop <<EOF
[Desktop Entry]
Name=OpenClaude
Comment=OpenClaude AMD C60 Local AI
Exec=openclaude
Icon=${APP_ID}
Terminal=true
Type=Application
Categories=Development;Utility;
Keywords=ai;llama;qwen;local;
EOF

cat > openclaude.metainfo.xml <<EOF
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
</component>
EOF

# =============================================================================
# Gera o manifesto flatpak-builder (fica dentro de flatpak_output/, gerado
# neste build - não é um arquivo entregue separadamente)
# =============================================================================
MANIFEST="${APP_ID}.yml"

# O módulo de ícone só entra no manifesto se o download deu certo.
if [[ -f icon.svg ]]; then
    ICON_MODULE="      - install -Dm644 icon.svg /app/share/icons/hicolor/scalable/apps/${APP_ID}.svg"
    ICON_SOURCE="      - type: file
        path: icon.svg"
else
    ICON_MODULE=""
    ICON_SOURCE=""
fi

cat > "$MANIFEST" <<EOF
app-id: ${APP_ID}
runtime: org.freedesktop.Platform
runtime-version: '23.08'
sdk: org.freedesktop.Sdk
command: openclaude

finish-args:
  - --share=network
  - --socket=fallback-x11
  - --socket=wayland
  - --device=dri

modules:
  - name: llama.cpp
    buildsystem: cmake-ninja
    config-opts:
      - -DCMAKE_BUILD_TYPE=Release
      - -DBUILD_SHARED_LIBS=OFF
      - -DLLAMA_BUILD_SERVER=ON
      - -DLLAMA_BUILD_TOOLS=ON
      - -DGGML_NATIVE=OFF
      - -DGGML_OPENMP=ON
${CPU_GGML_OPTS}
    sources:
      - type: git
        url: https://github.com/ggml-org/llama.cpp
        branch: ${LLAMACPP_REF}
    post-install:
      - |
        if [ -f /app/bin/llama-server ]; then
          :
        elif [ -f /app/bin/server ]; then
          install -Dm755 /app/bin/server /app/bin/llama-server
        else
          echo "ERRO: nenhum binário server/llama-server encontrado em /app/bin" >&2
          exit 1
        fi
${POST_INSTALL_AVX_CHECK}

  - name: openclaude-model
    buildsystem: simple
    build-commands:
      - install -Dm644 ${MODEL_FILE} /app/share/openclaude/${MODEL_FILE}
    sources:
      - type: file
        path: ${MODEL_FILE}

  - name: openclaude-wrapper
    buildsystem: simple
    build-commands:
      - install -Dm755 openclaude-wrapper /app/bin/openclaude
      - install -Dm644 openclaude.desktop /app/share/applications/${APP_ID}.desktop
      - install -Dm644 openclaude.metainfo.xml /app/share/metainfo/${APP_ID}.metainfo.xml
${ICON_MODULE}
    sources:
      - type: file
        path: openclaude-wrapper
      - type: file
        path: openclaude.desktop
      - type: file
        path: openclaude.metainfo.xml
${ICON_SOURCE}
EOF

# =============================================================================
# Build
# =============================================================================
log "Construindo com flatpak-builder (compila o llama.cpp, pode demorar)..."
"${FLATPAK_BUILDER[@]}" --force-clean --user --install-deps-from=flathub --jobs="${JOBS}" --repo=repo build-dir "$MANIFEST"

log "Gerando bundle .flatpak único..."
flatpak build-bundle repo "${APP_ID}.flatpak" "$APP_ID"

# =============================================================================
# Instala
# =============================================================================
log "Instalando o pacote flatpak para o usuário atual..."
flatpak install -y --user --noninteractive "${BUILD_ROOT}/${APP_ID}.flatpak"

BINARY_PATH="$(find "${BUILD_ROOT}/.flatpak-builder/build" -maxdepth 4 -type f \( -name llama-server -o -name server \) 2>/dev/null | head -n1)"
if [[ -n "$BINARY_PATH" ]]; then
    if ! "$BINARY_PATH" --version >/dev/null 2>&1; then
        err "llama-server incompatível. Build contém instruções não suportadas pela CPU."
    fi
    log "llama-server compatível (checagem --version)."
fi

# =============================================================================
# Autostart automático (systemd --user) - sem passo manual separado
# =============================================================================
log "Configurando autostart via systemd --user..."
UNIT_DIR="${HOME}/.config/systemd/user"
UNIT_FILE="${UNIT_DIR}/openclaude.service"
mkdir -p "$UNIT_DIR"

cat > "$UNIT_FILE" <<EOF
[Unit]
Description=OpenClaude (Flatpak) Llama Server
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/flatpak run ${APP_ID}
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now openclaude.service \
    || warn "Não foi possível habilitar o serviço systemd --user automaticamente. Rode manualmente: systemctl --user enable --now openclaude.service"

log "Build, instalação e autostart concluídos com sucesso!"
log "Pacote: ${BUILD_ROOT}/${APP_ID}.flatpak"
log "Testar: flatpak run ${APP_ID} --version"
log "Status do autostart: systemctl --user status openclaude"
log ""
log "OBS: para o serviço subir mesmo sem sessão gráfica aberta, rode:"
log "  sudo loginctl enable-linger \$USER"
