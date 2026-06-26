#!/bin/bash
# =============================================================================
# Script de Build: openclaude-infogyba
# Infogyba Soluções em TI
# Target: Fedora 44 / AMD C60 (Bobcat, x86_64, SSE2/SSE3/SSSE3)
# Idempotente: retoma de onde parou em caso de falha
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Variáveis globais
# ---------------------------------------------------------------------------
BUILD_ROOT="$(pwd)/rpm_output"
PKG_NAME="openclaude-infogyba"
PKG_VERSION="1.0"
PKG_RELEASE="1"
WORKDIR="$BUILD_ROOT/BUILD/openclaude-${PKG_VERSION}"
REPO_URL="https://github.com/Gitlawb/openclaude"

# Flags de otimização para AMD C60 (Bobcat μarch: SSE2, SSE3, SSSE3, sem SSE4)
# -march=btver1   → Bobcat 1ª geração (C60)
# -O2             → nível seguro; -O3 pode quebrar em Bobcat
# -fomit-frame-pointer, -pipe → reduz overhead binário
AMD_C60_CFLAGS="-march=btver1 -mtune=btver1 -O2 -fomit-frame-pointer -pipe"
AMD_C60_CXXFLAGS="$AMD_C60_CFLAGS"

# Arquivo de ícone oficial do Claude (PNG 512×512 baixado do repo)
ICON_URL="https://raw.githubusercontent.com/Gitlawb/openclaude/main/assets/icon.png"
ICON_DST="$BUILD_ROOT/BUILD/openclaude-icon.png"

# Cores para log
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERRO]${NC} $*" >&2; }

# ---------------------------------------------------------------------------
# Função de controle de etapas (idempotência via arquivos-flag)
# ---------------------------------------------------------------------------
STAMP_DIR="$BUILD_ROOT/.stamps"
mkdir -p "$STAMP_DIR"

step_done()  { [[ -f "$STAMP_DIR/$1" ]]; }
mark_done()  { touch "$STAMP_DIR/$1"; log "Etapa '$1' concluída."; }

run_step() {
    local name="$1"; shift
    if step_done "$name"; then
        warn "Etapa '$name' já concluída — pulando."
    else
        log "==> Iniciando etapa: $name"
        "$@"
        mark_done "$name"
    fi
}

# ---------------------------------------------------------------------------
# Etapa 1: Estrutura de diretórios RPM
# ---------------------------------------------------------------------------
step_mkdirs() {
    mkdir -p "$BUILD_ROOT"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}
    mkdir -p "$STAMP_DIR"
}

# ---------------------------------------------------------------------------
# Etapa 2: Dependências do sistema (Fedora 44)
# ---------------------------------------------------------------------------
step_deps() {
    sudo dnf install -y \
        rpm-build rpmdevtools git \
        nodejs npm \
        gcc-c++ make \
        curl wget \
        libappstream-glib   # appstream-util para validar metainfo
}

# ---------------------------------------------------------------------------
# Etapa 3: Instalar Bun (se ausente)
# ---------------------------------------------------------------------------
step_bun() {
    if command -v bun &>/dev/null; then
        log "Bun já instalado: $(bun --version)"
        return
    fi
    curl -fsSL https://bun.sh/install | bash
    # shellcheck disable=SC1090
    source "$HOME/.bashrc" 2>/dev/null || true
    export PATH="$HOME/.bun/bin:$PATH"
    log "Bun instalado: $(bun --version)"
}

# ---------------------------------------------------------------------------
# Etapa 4: Clonar repositório
# ---------------------------------------------------------------------------
step_clone() {
    if [[ -d "$WORKDIR/.git" ]]; then
        log "Repositório já clonado em $WORKDIR."
        return
    fi
    git clone "$REPO_URL" "$WORKDIR"
}

# ---------------------------------------------------------------------------
# Etapa 5: Instalar dependências Node/Bun
# ---------------------------------------------------------------------------
step_install() {
    export PATH="$HOME/.bun/bin:$PATH"
    cd "$WORKDIR"
    bun install
}

# ---------------------------------------------------------------------------
# Etapa 6: Compilar com otimizações AMD C60
# ---------------------------------------------------------------------------
step_build() {
    export PATH="$HOME/.bun/bin:$PATH"
    export CFLAGS="$AMD_C60_CFLAGS"
    export CXXFLAGS="$AMD_C60_CXXFLAGS"
    # Passa as flags também para compilações nativas de módulos npm
    export npm_config_CFLAGS="$AMD_C60_CFLAGS"
    export npm_config_CXXFLAGS="$AMD_C60_CXXFLAGS"
    cd "$WORKDIR"
    bun run build
}

# ---------------------------------------------------------------------------
# Etapa 7: Baixar ícone oficial
# ---------------------------------------------------------------------------
step_icon() {
    if [[ -f "$ICON_DST" ]]; then
        log "Ícone já baixado."
        return
    fi
    # Tenta URL principal; se falhar, usa fallback do Claude
    if ! curl -fsSL "$ICON_URL" -o "$ICON_DST" 2>/dev/null; then
        warn "Ícone não encontrado no repo — usando ícone do utilities-terminal como fallback."
        # Cria PNG placeholder 1×1 transparente para não quebrar o spec
        # (o .desktop usará o nome do ícone do sistema como fallback)
        touch "$ICON_DST"
        export USE_SYSTEM_ICON=1
    else
        export USE_SYSTEM_ICON=0
    fi
}

# ---------------------------------------------------------------------------
# Etapa 8: Gerar arquivo .spec
# ---------------------------------------------------------------------------
step_spec() {
    local SPEC_FILE="$BUILD_ROOT/SPECS/openclaude-infogyba.spec"

    # Define valor de ícone: arquivo instalado ou nome do sistema
    local ICON_VALUE
    if [[ "${USE_SYSTEM_ICON:-0}" == "1" ]]; then
        ICON_VALUE="utilities-terminal"
    else
        ICON_VALUE="openclaude"
    fi

    cat > "$SPEC_FILE" <<SPECEOF
Name:           ${PKG_NAME}
Version:        ${PKG_VERSION}
Release:        ${PKG_RELEASE}%{?dist}
Summary:        OpenClaude CLI AI Assistant — Infogyba Soluções em TI
License:        MIT
Requires:       nodejs
BuildArch:      x86_64

# Otimizado para AMD C60 (Bobcat btver1)
%global _optflags ${AMD_C60_CFLAGS}

%description
OpenClaude CLI otimizado pela Infogyba Soluções em TI.

# ------------------------------------------------------------
%install
mkdir -p %{buildroot}/usr/bin
mkdir -p %{buildroot}/opt/openclaude
mkdir -p %{buildroot}/usr/share/applications
mkdir -p %{buildroot}/usr/share/metainfo
mkdir -p %{buildroot}/usr/share/icons/hicolor/512x512/apps
mkdir -p %{buildroot}/usr/share/icons/hicolor/256x256/apps
mkdir -p %{buildroot}/usr/share/icons/hicolor/128x128/apps

# Copia build completo
cp -r ${WORKDIR}/. %{buildroot}/opt/openclaude/

# Wrapper de execução
cat > %{buildroot}/usr/bin/openclaude <<'WRAPPER'
#!/bin/bash
exec node /opt/openclaude/dist/index.js "\$@"
WRAPPER
chmod +x %{buildroot}/usr/bin/openclaude

SPECEOF

    # Bloco condicional do ícone
    if [[ "${USE_SYSTEM_ICON:-0}" != "1" ]]; then
        cat >> "$SPEC_FILE" <<SPECEOF
# Ícone oficial
install -m 644 ${ICON_DST} %{buildroot}/usr/share/icons/hicolor/512x512/apps/openclaude.png
for size in 256 128; do
    # Redimensiona com convert (ImageMagick) se disponível; senão copia mesmo assim
    if command -v convert &>/dev/null; then
        convert -resize \${size}x\${size} ${ICON_DST} \\
            %{buildroot}/usr/share/icons/hicolor/\${size}x\${size}/apps/openclaude.png || \\
            cp ${ICON_DST} %{buildroot}/usr/share/icons/hicolor/\${size}x\${size}/apps/openclaude.png
    else
        cp ${ICON_DST} %{buildroot}/usr/share/icons/hicolor/\${size}x\${size}/apps/openclaude.png
    fi
done

SPECEOF
    fi

    cat >> "$SPEC_FILE" <<'SPECEOF2'
# Arquivo .desktop — aparece no GNOME Shell / Activities
cat > %{buildroot}/usr/share/applications/openclaude.desktop <<'EOD'
[Desktop Entry]
Version=1.1
Type=Application
Name=OpenClaude
GenericName=Assistente de IA
Comment=OpenClaude CLI otimizado pela Infogyba Soluções em TI
Exec=gnome-terminal -- /usr/bin/openclaude
SPECEOF2

    # Linha do ícone depende se temos ícone próprio
    if [[ "${USE_SYSTEM_ICON:-0}" == "1" ]]; then
        echo "Icon=utilities-terminal" >> "$SPEC_FILE"
    else
        echo "Icon=openclaude" >> "$SPEC_FILE"
    fi

    cat >> "$SPEC_FILE" <<'SPECEOF3'
Categories=Development;Utility;
Terminal=false
Keywords=AI;Claude;CLI;Development;
StartupNotify=true
EOD

# Metainfo para GNOME Software (AppStream)
cat > %{buildroot}/usr/share/metainfo/com.infogyba.openclaude.metainfo.xml <<'EOM'
<?xml version="1.0" encoding="UTF-8"?>
<component type="desktop-application">
  <id>com.infogyba.openclaude</id>
  <metadata_license>CC0-1.0</metadata_license>
  <project_license>MIT</project_license>
  <name>OpenClaude</name>
  <summary>Agente de IA para desenvolvimento</summary>
  <description>
    <p>OpenClaude CLI otimizado pela Infogyba Solucoes em TI (com acentos).</p>
  </description>
  <launchable type="desktop-id">openclaude.desktop</launchable>
  <categories>
    <category>Development</category>
    <category>Utility</category>
  </categories>
  <developer_name>Infogyba Soluções em TI</developer_name>
  <url type="homepage">https://github.com/Gitlawb/openclaude</url>
</component>
EOM

# Atualiza cache de ícones após instalação
%post
/usr/bin/gtk-update-icon-cache -f -t /usr/share/icons/hicolor &>/dev/null || :
/usr/bin/update-desktop-database &>/dev/null || :
/usr/bin/appstreamcli refresh --force &>/dev/null || :

%postun
/usr/bin/gtk-update-icon-cache -f -t /usr/share/icons/hicolor &>/dev/null || :
/usr/bin/update-desktop-database &>/dev/null || :
/usr/bin/appstreamcli refresh --force &>/dev/null || :

%files
/opt/openclaude
/usr/bin/openclaude
/usr/share/applications/openclaude.desktop
/usr/share/metainfo/com.infogyba.openclaude.metainfo.xml
SPECEOF3

    # Adiciona linhas de ícone ao %files se necessário
    if [[ "${USE_SYSTEM_ICON:-0}" != "1" ]]; then
        cat >> "$SPEC_FILE" <<'SPECEOF4'
/usr/share/icons/hicolor/512x512/apps/openclaude.png
/usr/share/icons/hicolor/256x256/apps/openclaude.png
/usr/share/icons/hicolor/128x128/apps/openclaude.png
SPECEOF4
    fi

    log "Arquivo .spec gerado em $SPEC_FILE"
}

# ---------------------------------------------------------------------------
# Etapa 9: Build RPM
# ---------------------------------------------------------------------------
step_rpm() {
    local SPEC_FILE="$BUILD_ROOT/SPECS/openclaude-infogyba.spec"
    rpmbuild \
        --define "_topdir $BUILD_ROOT" \
        --define "_builddir $BUILD_ROOT/BUILD" \
        --define "optflags $AMD_C60_CFLAGS" \
        -ba "$SPEC_FILE"
}

# ---------------------------------------------------------------------------
# Execução principal (com idempotência por etapa)
# ---------------------------------------------------------------------------
log "============================================================"
log " Build openclaude-infogyba — Infogyba Soluções em TI"
log " Target: Fedora 44 / AMD C60 (btver1)"
log "============================================================"

run_step "mkdirs"  step_mkdirs
run_step "deps"    step_deps
run_step "bun"     step_bun
run_step "clone"   step_clone
run_step "install" step_install
run_step "build"   step_build
run_step "icon"    step_icon
run_step "spec"    step_spec
run_step "rpm"     step_rpm

# ---------------------------------------------------------------------------
# Resultado final
# ---------------------------------------------------------------------------
RPM_FILE=$(find "$BUILD_ROOT/RPMS/x86_64" -name "${PKG_NAME}-*.rpm" | head -1)

echo ""
log "============================================================"
log " CONCLUÍDO COM SUCESSO!"
log "============================================================"
log " RPM gerado: $RPM_FILE"
log ""
log " Para instalar:"
log "   sudo dnf install '$RPM_FILE'"
log ""
log " Para reinstalar após mudanças (limpa stamps e reconstrói):"
log "   rm -rf '$STAMP_DIR' && bash $0"
log ""
log " Para limpar tudo e recomeçar:"
log "   rm -rf '$BUILD_ROOT' && bash $0"
log "============================================================"
