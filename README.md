# OpenClaude — Infogyba Soluções em TI

IA local baseada em [llama.cpp](https://github.com/ggerganov/llama.cpp) +
**Qwen2.5-Coder-0.5B-Instruct**, otimizada para CPUs sem AVX/AVX2/FMA/F16C
(ex.: **AMD C-60 / Bobcat**). Expõe uma API compatível com OpenAI em
`http://127.0.0.1:11434/v1`, pronta para uso com **VSCode + continue.dev**.

Disponível em três formatos de pacote:

| Pacote | Script | Distribuição alvo |
|---|---|---|
| `.deb` | `deb/openclaude-deb.sh` | Debian / Ubuntu e derivados |
| `.rpm` | `rpm/openclaude-rpm.sh` | Fedora 44 |
| `.flatpak` | `flatpak/openclaude-flatpak.sh` | Qualquer distro com Flatpak |

---

## O que foi corrigido em relação ao script original

1. **Binário não encontrado (`llama-server não foi gerado`)** — o script
   original fixava o clone do llama.cpp no tag `b1412` (nov/2023). Nessa
   versão o binário do servidor ainda se chamava `server`, e só foi
   renomeado para `llama-server` em versões posteriores. Isso fazia o
   `[[ -x "$BINARY_PATH" ]]` falhar sempre, travando o build antes de
   chegar ao download do modelo — por isso "parecia" que o Qwen não
   baixava.
2. **Qwen2.5 não suportado** — além do nome do binário, o tag `b1412` é
   anterior ao suporte da arquitetura do Qwen2.5 no llama.cpp. Mesmo
   corrigindo só o nome do binário, o modelo não rodaria. Os scripts agora
   clonam o `master` por padrão (pode ser fixado via `LLAMACPP_REF=<tag>`).
3. **Detecção robusta do binário** — os scripts agora procuram tanto por
   `llama-server` quanto por `server` em `install/bin`, então funcionam
   com versões antigas ou novas do llama.cpp.
4. **Downloads silenciosamente quebrados** — `curl` agora usa `--fail
   --retry 3`, então uma página de erro HTTP não é mais salva como se
   fosse o modelo/ícone.
5. **"Illegal instruction" no AMD C-60 mesmo com AVX/AVX2 desligados** —
   o `--version` sozinho não passa pelos kernels de matmul/quantização do
   ggml, que é onde instruções AVX2 costumam aparecer. Um build podia
   passar na checagem antiga e mesmo assim travar só na hora de carregar
   o modelo de verdade. Correções:
   - `-march=btver1 -mtune=btver1` (alvo real do GCC/Clang para AMD
     Bobcat/C-Series, mais confiável que ligar/desligar flag por flag)
   - `GGML_CPU_ALL_VARIANTS=OFF` e `GGML_BACKEND_DL=OFF` — builds recentes
     do llama.cpp podem compilar várias variantes de CPU e escolher em
     runtime; em CPUs raras como o C-60 essa detecção pode escolher a
     variante errada
   - checagem **estática** pós-build com `objdump`, procurando
     registradores `ymm`/`zmm` (AVX/AVX512) no binário compilado, que
     falha o build antes de empacotar em vez de só descobrir depois de
     instalado
6. **Início automático do serviço na instalação**:
   - **.deb**: `postinst` já fazia `enable` + `restart`; mantido e revisado.
   - **.rpm**: `%post` usa as macros `%systemd_post` e
     `systemctl enable --now`.
   - **.flatpak**: Flatpak não roda como root nem tem hooks de
     pós-instalação — não existe "serviço do sistema" dentro do sandbox.
     Por isso o próprio `openclaude-flatpak.sh` já cria e habilita, ao
     final do build, um serviço **systemd --user**
     (`~/.config/systemd/user/openclaude.service`) que chama
     `flatpak run com.infogyba.OpenClaude` — tudo dentro do mesmo script,
     sem passo manual separado.

---

## 1. Build .deb (Debian/Ubuntu)

```bash
sudo apt install git cmake make curl dpkg-dev gzip build-essential binutils
cd deb
./openclaude-deb.sh
sudo dpkg -i deb_output/DEBS/openclaude_1.1.0-1_amd64.deb
```

O serviço `openclaude.service` é habilitado e iniciado automaticamente.

Comandos úteis:
```bash
systemctl status openclaude
journalctl -u openclaude -f
sudo systemctl restart openclaude
openclaude --version
sudo dpkg -r openclaude          # remover
```

## 2. Build .rpm (Fedora 44)

```bash
sudo dnf install git cmake make curl rpm-build gzip gcc gcc-c++ systemd-rpm-macros binutils
cd rpm
./openclaude-rpm.sh
sudo dnf install rpm_output/rpmbuild/RPMS/x86_64/openclaude-1.1.0-1.fc44.x86_64.rpm
```

O `%post` do spec já roda `systemctl enable --now openclaude.service`.

Comandos úteis:
```bash
systemctl status openclaude
journalctl -u openclaude -f
sudo dnf remove openclaude       # remover
rpm -qi openclaude               # informações do pacote
```

## 3. Build .flatpak

```bash
sudo dnf install flatpak flatpak-builder binutils   # ou apt install flatpak flatpak-builder binutils
cd flatpak
./openclaude-flatpak.sh
```

Um único script cuida de tudo: instala o runtime/SDK do Flatpak, baixa o
modelo e o ícone, gera o manifesto internamente, compila o llama.cpp,
empacota o `.flatpak`, **instala** para o usuário atual e **já habilita o
autostart** (via `systemd --user`) — sem passos manuais extras.

Comandos úteis:
```bash
flatpak run com.infogyba.OpenClaude --version
systemctl --user status openclaude
journalctl --user -u openclaude -f
sudo loginctl enable-linger $USER    # autostart mesmo sem login gráfico
flatpak uninstall com.infogyba.OpenClaude   # remover
```

### Suporte a Fedora Atomic (Kinoite / Silverblue)

O script detecta automaticamente sistemas `rpm-ostree` e **não faz layer**
de pacotes no sistema base (isso mudaria a imagem do sistema e exigiria
reboot). Em vez disso:

- `flatpak` já vem pré-instalado na imagem do Kinoite — o script nunca
  tenta reinstalá-lo.
- Se `flatpak-builder` nativo não existir, o script instala o
  **`org.flatpak.Builder`** (Flathub) como um Flatpak comum, em escopo
  `--user` — sem root, sem layer, sem reboot. Essa é a forma recomendada
  pelo próprio projeto Flatpak para sistemas imutáveis.
- Se `curl`/`sha256sum` faltarem (raríssimo, já vêm na imagem base), o
  script orienta rodar dentro de um `toolbox` em vez de fazer layer.

> **Nota sobre o `.rpm`:** o `openclaude-rpm.sh` assume um Fedora
> Workstation/Server "normal" com `dnf` funcional (não um sistema
> `rpm-ostree`). Se você quiser gerar o `.rpm` a partir de um Kinoite, rode
> o script de dentro de um `toolbox` (`toolbox create && toolbox enter`),
> que dá acesso a um `dnf` completo sem afetar o sistema base.

---

## Integração com VSCode + continue.dev

> **Continue v2.0+ mudou o formato de configuração.** Versões antigas usavam
> `~/.continue/config.json`. A partir da v2.0 (aviso "*Extension
> configuration is local only as of v2.0.0*" na sidebar), o formato passou
> a ser **YAML**, em `~/.continue/config.yaml`. As instruções abaixo já são
> pra essa versão nova.

1. Instale a extensão **Continue** no VSCode (marketplace: `Continue.continue`).
2. Confirme que o OpenClaude está rodando antes de configurar:

```bash
# .deb / .rpm
systemctl status openclaude

# .flatpak
systemctl --user status openclaude

# Teste direto da API, independente do pacote:
curl http://127.0.0.1:11434/v1/models
```

3. No VSCode, abra a sidebar do Continue e clique no dropdown de configs
   (canto superior direito do campo de mensagem do chat) → clique no ícone
   de **engrenagem ⚙️** ao lado de **"Local Config"**. Isso abre
   `~/.continue/config.yaml` direto no editor.

   > **Não confunda com o `settings.json` do VSCode** (`Ctrl+Shift+P` →
   > "Preferences: Open User Settings (JSON)"). São arquivos diferentes —
   > colar a config do Continue ali não funciona, o Continue nunca lê essa
   > chave do `settings.json`.

4. Apague o conteúdo padrão yaml  e cole o conteudo do arquivo YAML em :
<br>
sudo nano ~/.continue/config.yaml
<br>
5. Salve (`Ctrl+S`). O Continue recarrega sozinho — não precisa reiniciar
   o VSCode.
6. No seletor de modelo do chat, escolha **"OpenClaude - Qwen2.5-Coder
   (Local)"**.

Essa config é **idêntica** independente de qual pacote você instalou
(`.deb`, `.rpm` ou `.flatpak`) — os três sobem o `llama-server` na mesma
porta `127.0.0.1:11434` via `systemd`/`systemd --user`. A única coisa que
muda entre eles é como você gerencia o serviço (`systemctl` vs
`systemctl --user`), não como o Continue se conecta.

### Testando a API manualmente

```bash
curl http://127.0.0.1:11434/v1/models

curl http://127.0.0.1:11434/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
        "model": "qwen2.5-coder-0.5b-instruct",
        "messages": [{"role": "user", "content": "Escreva um hello world em Python"}]
      }'
```

---

## Comandos de referência — OpenClaude

### Status e logs

| Ação | .deb / .rpm | .flatpak |
|---|---|---|
| Ver status do serviço | `systemctl status openclaude` | `systemctl --user status openclaude` |
| Ver logs em tempo real | `journalctl -u openclaude -f` | `journalctl --user -u openclaude -f` |
| Ver últimas 50 linhas de log | `journalctl -u openclaude -n 50` | `journalctl --user -u openclaude -n 50` |

### Controle do serviço

| Ação | .deb / .rpm | .flatpak |
|---|---|---|
| Iniciar | `sudo systemctl start openclaude` | `systemctl --user start openclaude` |
| Parar | `sudo systemctl stop openclaude` | `systemctl --user stop openclaude` |
| Reiniciar | `sudo systemctl restart openclaude` | `systemctl --user restart openclaude` |
| Habilitar no boot | `sudo systemctl enable openclaude` | `systemctl --user enable openclaude` |
| Desabilitar no boot | `sudo systemctl disable openclaude` | `systemctl --user disable openclaude` |

### Binário / versão

```bash
# .deb / .rpm
openclaude --version

# .flatpak
flatpak run com.infogyba.OpenClaude --version
```

### Testando a API (igual nos 3 pacotes)

```bash
# Porta e endpoint são os mesmos em .deb, .rpm e .flatpak
curl http://127.0.0.1:11434/v1/models

curl http://127.0.0.1:11434/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
        "model": "qwen2.5-coder-0.5b-instruct",
        "messages": [{"role": "user", "content": "Escreva um hello world em Python"}]
      }'
```

### Ver se a porta está escutando

```bash
ss -tlnp | grep 11434
```

### Rodar manualmente em primeiro plano (debug)

```bash
# .deb / .rpm
sudo systemctl stop openclaude
openclaude

# .flatpak
systemctl --user stop openclaude
flatpak run com.infogyba.OpenClaude
```

### Desinstalar

```bash
# .deb
sudo dpkg -r openclaude

# .rpm
sudo dnf remove openclaude

# .flatpak
flatpak uninstall com.infogyba.OpenClaude
systemctl --user disable --now openclaude   # remove também o autostart
rm ~/.config/systemd/user/openclaude.service
```

### Informações do pacote instalado

```bash
# .deb
dpkg -l | grep openclaude
dpkg -L openclaude          # lista arquivos instalados

# .rpm
rpm -qi openclaude
rpm -ql openclaude          # lista arquivos instalados

# .flatpak
flatpak info com.infogyba.OpenClaude
```

---

## Notas sobre CPU (AMD C-60 / Bobcat)

O build usa `-march=btver1 -mtune=btver1` — o alvo real do GCC/Clang para
a família AMD Bobcat (C-Series, onde está o C-60) — combinado com
`-mno-avx -mno-avx2 -mno-fma -mno-f16c -mno-avx512f` e as flags CMake
equivalentes do ggml (`GGML_AVX=OFF`, `GGML_CPU_ALL_VARIANTS=OFF`, etc.),
já que o Bobcat não possui AVX/AVX2/FMA/F16C.

Depois do build, os scripts rodam uma checagem **estática** no binário
com `objdump`, procurando por registradores `ymm`/`zmm` (usados por
AVX/AVX2/AVX512). Isso pega builds quebrados *antes* de empacotar — um
`llama-server --version` sozinho não é suficiente, porque não passa pelos
kernels de matmul/quantização onde essas instruções costumam aparecer, e
por isso um binário "aprovado" no `--version` ainda podia dar
`Illegal instruction` só na hora de carregar o modelo de verdade.

Para validar as instruções suportadas pela CPU alvo antes do build:

```bash
grep flags /proc/cpuinfo | head -n1 | tr ' ' '\n' | grep -E 'sse|avx|fma'
```

Se aparecer `avx` na lista, você **não** precisa dessas restrições e pode
trocar `-march=btver1` por algo mais recente (ex.: `-march=native`) para
obter melhor desempenho.

---

## Paralelismo do build (usar todos os núcleos/threads ou limitar)

Assim como as flags de CPU, o número de jobs paralelos usados pelo
`make`/`flatpak-builder` também é uma linha simples de comentar/descomentar
em cada script — útil se você está compilando numa máquina diferente do
AMD C-60 alvo (ex.: um PC atual, mais rápido, pra depois instalar o pacote
no C-60).

**`.deb`** e **`.rpm`** (procure por `JOBS=` logo antes do `make -j`):

```bash
JOBS="$(nproc 2>/dev/null || echo 2)"   # usa todos os núcleos/threads disponíveis
# JOBS=2                                  # ou fixe um número manual de jobs (ex.: 2 para o AMD C-60)
```

**`.flatpak`** (procure por `JOBS=` perto do topo do script, usado no
`--jobs` do `flatpak-builder`):

```bash
JOBS=0     # 0 = usa todos os núcleos/threads disponíveis (auto)
# JOBS=2   # ou fixe um número manual de jobs (ex.: 2 para o AMD C-60)
```

Por padrão, os três já usam **todos** os núcleos/threads disponíveis na
máquina que está compilando (via `nproc` no deb/rpm, ou `--jobs=0` que é o
próprio padrão do flatpak-builder). Se sua máquina tiver pouca RAM e o
build travar ou o processo for morto pelo OOM killer durante o *link*,
comente a linha automática e descomente a linha com um número fixo mais
baixo (ex.: `JOBS=2`).

---

## Screenshots na GNOME Software / KDE Discover

Os três pacotes instalam um `metainfo.xml` (padrão AppStream) além do
`.desktop` — é esse arquivo que faz a GNOME Software/KDE Discover
mostrarem descrição, ícone **e screenshots** do app já instalado, não só
o launcher.

Antes de publicar, edite a variável `SCREENSHOTS_BASE_URL` no topo de
cada script (mesmo padrão nos 3):

```bash
SCREENSHOTS_BASE_URL="${SCREENSHOTS_BASE_URL:-https://raw.githubusercontent.com/SEU_USUARIO/SEU_REPO/main/screenshots}"
```

Troque `SEU_USUARIO/SEU_REPO` pelo caminho real do seu repositório
GitHub, e suba duas imagens em `screenshots/` dentro do repo:

- `screenshots/gnome-software.png`
- `screenshots/continue-vscode.png`

Especificações recomendadas pelo AppStream: proporção **16:9**, largura
mínima de ~620px (recomendado 1280x720). Sem essas imagens no lugar certo,
os screenshots aparecem quebrados na GNOME Software.

Depois de instalar o pacote, o cache do AppStream é atualizado
automaticamente (`appstreamcli refresh-cache --force`, chamado no
`postinst`/`%post`/`post-install` de cada pacote) — não precisa de
reboot nem relogin para os screenshots aparecerem.

---

## Estrutura deste repositório

```
openclaude/
├── deb/openclaude-deb.sh          # script único: build + package + autostart
├── rpm/openclaude-rpm.sh          # script único: build + package + autostart
├── flatpak/openclaude-flatpak.sh  # script único: build + install + autostart
├── continue/config.yaml
└── README.md
```

Cada script é autossuficiente: gera internamente (via heredoc) tudo que
precisa — `control`/`postinst` no .deb, `.spec` no .rpm, manifesto/`.desktop`/
wrapper no flatpak — sem depender de arquivos soltos ao lado.

#screenshots
<img width="1366" height="768" alt="image" src="https://github.com/user-attachments/assets/a561ed4a-6def-49ef-a1a0-0cbf8faa0e6f" />
<img width="892" height="300" alt="image" src="https://github.com/user-attachments/assets/028f3478-8f29-4e9c-a903-9a6a564f7ad1" />
<img width="685" height="453" alt="image" src="https://github.com/user-attachments/assets/c2de508c-3611-4d4e-8476-33aca558ae91" />


**Autor:** Infogyba Soluções em TI <infogyba@gmail.com>
<br>
 
