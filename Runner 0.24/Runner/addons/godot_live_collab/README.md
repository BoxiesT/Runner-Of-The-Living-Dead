# Godot Live Collab 3.1

Colaboração ao vivo dentro do editor da Godot: duas ou mais pessoas trabalhando no mesmo projeto como se
estivessem numa **pasta compartilhada**. Quem cria ou edita algo, todos veem — nos dois sentidos, em tempo real.

> Testado na **Godot 4.7.2**. Funciona **só em rede local** (LAN) ou em VPN que simula LAN, como o **Radmin VPN**.
> Use em projetos com backup/controle de versão: é um plugin que mexe em arquivos do projeto.

## O que é sincronizado

| Camada | O que acontece |
|---|---|
| **Cenas** (ao vivo) | Criar, apagar, renomear, mover, reordenar e *reparentar em novo nó*; propriedades (inclusive de scripts exportadas); recursos embutidos compartilhados; referências entre nós; grupos; **conexões de sinais** (aba *Nó → Sinais*, com argumentos extras/descartados); cenas instanciadas; scripts anexados. Arrastar no viewport aparece ao vivo para os outros. Nomes e ordem dos filhos são decididos pelo host, então todos terminam **idênticos** (nada de `Player2`). Edições de outras pessoas marcam a cena como modificada `(*)`, então o editor pergunta se quer salvar ao fechar. Quando alguém salva uma cena que está **instanciada** numa cena aberta aqui, a instância é atualizada na hora. |
| **Scripts** (ao vivo) | Digitação simultânea (até no mesmo ponto) converge nos dois lados. Edições remotas entram como inserções/remoções mínimas: seu cursor, seleção e rolagem não pulam. Cursores e seleções dos colegas aparecem coloridos com o nome. |
| **Arquivos e pastas** (pasta compartilhada) | Criar, editar, mover, renomear e apagar qualquer arquivo **ou pasta (inclusive vazia)** de `res://` (texturas, áudio, cenas, `.tres`, `.import`, `.uid`…). Alterações chegam aos outros em ~1 segundo; o painel *Sistema de Arquivos* dos outros é atualizado sozinho e os assets são importados. Arquivos grandes vão em pedaços por um canal separado, sem travar a edição ao vivo. Antes de sobrescrever ou apagar, guarda cópia em `res://.glc_backup/`. |
| **Project Settings** | Input Map, Autoloads, display, física, camadas, grupos globais… O `project.godot` é salvo logo depois. |
| **Presença** | Ponteiro do mouse no editor 2D (em coordenadas de mundo), câmera no 3D, seleção de nós (contorno no viewport e linha colorida no dock da Cena). |
| **Salvar** | Quando alguém salva uma cena ou script que você também tem aberto, o seu é salvo também. |

Nada é gravado dentro das suas cenas (sem metadados do plugin).

## Instalação

1. Copie `addons/godot_live_collab/` para a pasta `addons/` do projeto. **Todos devem ter a mesma versão do plugin.**
2. *Projeto → Configurações do Projeto → Plugins* → ative **Godot Live Collab**.
3. Abra o painel **Live Collab** (acoplado à direita, no canto superior).

## Como usar

**Host** (quem organiza a sessão):
1. Aba *Sessão* → seu nome, uma senha (recomendado) e a porta (padrão 24680) → **Hospedar**.
2. O painel mostra seus IPs por rede (*rede local*, *Radmin VPN*…). O botão **Copiar endereço** copia `IP:porta`
   (preferindo o IP do Radmin, se houver).

**Colegas:**
1. Tenham uma cópia do projeto (git, zip…). Não precisa estar idêntica: na entrada, o que for diferente é igualado ao host.
2. Aba *Sessão* → a sessão do host aparece sozinha em **Sessões encontradas na rede local / VPN**:
   clique para preencher, digite a senha e clique em **Entrar** (ou clique duplo se não houver senha).
   Se não aparecer, digite o IP do host e a porta manualmente.

**O que acontece ao entrar:** os arquivos e pastas que o host tem e você não (ou que diferem) são baixados; a versão sua
que for substituída vai para `res://.glc_backup/`; arquivos e pastas que só você tem são enviados ao host; **nada é
apagado** nessa fase. As cenas e scripts que você tem abertos passam a mostrar o estado atual do host, e a **cena em
que o host está trabalhando é aberta automaticamente** assim que o arquivo dela chega (opção na aba *Opções*; não
acontece nas reconexões automáticas, para não tirar você da cena em que estiver).

### Rede: só local (e Radmin VPN)

* O transporte é **ENet (UDP)**. Não existe modo internet/túnel: a sessão só funciona entre máquinas da mesma rede.
* Com a opção **"Host: aceitar só rede local / VPN"** (ligada por padrão), o host recusa qualquer conexão que não venha
  de um endereço local antes mesmo da autenticação: `10.x`, `172.16–31.x`, `192.168.x`, `127.x`, link-local,
  `26.x` (Radmin VPN), `25.x` (Hamachi), `100.64–127.x` (Tailscale) e equivalentes IPv6.
* A **descoberta automática** usa UDP na porta **24679** (consulta por broadcast em cada placa de rede, inclusive a do
  Radmin). O host só responde a endereços locais. Pode ser desligada na aba *Opções*.
* A senha nunca trafega: a entrada usa desafio HMAC **nos dois sentidos** (o cliente prova a senha ao host e o host
  prova ao cliente, então um "host falso" na rede não consegue se passar pelo verdadeiro). O conteúdo da sessão
  **não é criptografado** — por isso o plugin fica restrito à rede local/VPN (o Radmin VPN já criptografa o túnel
  entre os membros da rede dele). Use sempre uma senha.
* O cliente também se recusa a conectar num endereço fora da rede local/VPN quando a opção está ligada.
* A sessão tem formato de estrela: se o host fechar, a sessão acaba; os clientes tentam reconectar sozinhos
  (opção *Reconectar automaticamente*).
* **Tempo real mesmo em segundo plano:** sem foco, a Godot normalmente desacelera para ~10 quadros/s, o que
  atrasaria cada mensagem em até 100 ms. Durante a sessão o plugin mantém o editor respondendo (opção
  *Tempo real mesmo com a janela da Godot em segundo plano*, ligada por padrão); ao sair da sessão o comportamento
  normal volta.
* Arquivos pequenos (scripts, cenas, recursos até 128 KB) viajam junto com o aviso de mudança, e um arquivo usado por
  uma edição (ex.: o script recém-criado no *Anexar Script*) é sempre enviado **antes** dela: do outro lado o nó já
  aparece com o script, sem espera.

#### Usando com Radmin VPN

1. Todos instalam o Radmin VPN e entram na **mesma rede** do Radmin (o host cria a rede com nome e senha).
2. O host clica em **Hospedar** no Live Collab. No painel aparece o IP `26.x.x.x` marcado como *Radmin VPN*.
3. Os colegas veem a sessão na lista automaticamente (ou digitam o IP `26.x.x.x` do host).

#### Firewall do Windows

Na primeira vez que hospedar, o Windows pergunta se a Godot pode usar a rede: **permita em redes privadas**.
Se ninguém conseguir entrar, libere no firewall do host a porta **UDP 24680** (sessão) e **UDP 24679** (descoberta),
ou o executável da Godot. A rede do Radmin VPN deve estar como *rede privada* no Windows.

## Se algo não sincronizar

* **Mesma versão nas duas máquinas.** Copie a pasta `addons/godot_live_collab` para todas e **reinicie a Godot**
  (ou desative e reative o plugin). Quem tiver uma versão diferente é recusado ao entrar ("versões incompatíveis").
* **Edição de script ao vivo** acontece no editor de scripts da própria Godot. Com editor externo (VS Code etc.), as
  mudanças chegam aos outros quando você **salva**. Para ver as teclas do colega em tempo real, abra o mesmo script;
  se você abrir depois, recebe na hora o texto atual dele (inclusive o que ainda não foi salvo).
* A árvore da cena mostra a cena que **você** está editando: mudanças numa cena que está em outra aba aparecem quando
  você muda para ela.
* O painel *Live Collab → Atividade* mostra o que está acontecendo (arquivos recebidos, ressincronizações...). Os avisos
  no canto da tela ficam só para eventos da sessão (alguém entrou/saiu, erros).

## Boas práticas

* O host é a referência: quando alguém abre uma cena ou script que ainda ninguém tem aberto, vale a versão **salva no
  disco do host**. A cópia de quem entrou é substituída: o arquivo antigo vai para `res://.glc_backup/` e, nos scripts,
  `Ctrl+Z` ainda recupera o texto anterior.
* Arquivos abertos no editor (cena/script) não são sobrescritos nem apagados "por baixo" de você; isso acontece quando
  você os fecha (o painel *Arquivos* mostra quantos estão aguardando).
* Para colaborar com git, faça commits de uma máquina só (a do host) ou combine quem commita; adicione `.glc_backup/` ao `.gitignore`.

## Limitações conhecidas

* Filhos "editáveis" de cenas instanciadas e o comando *Tornar Local* não são sincronizados ao vivo (chegam quando a
  cena é salva e reaberta).
* Conexões de sinais são sincronizadas entre nós da própria cena; conexões para nós *dentro* de cenas instanciadas, não.
* Edição ao vivo de scripts vale para os abertos no **editor de scripts** (GDScript/C#). Shaders e arquivos de texto
  chegam pela sincronização de arquivos (ao salvar).
* Edições remotas entram no histórico de desfazer (`Ctrl+Z`) do editor de script local, como qualquer outra edição;
  nas cenas, edições remotas não entram no seu histórico de desfazer.
* Cenas ainda sem caminho (nunca salvas) só entram na sincronização depois de salvas.
* Recursos externos (`.tres`) editados no Inspetor chegam aos outros quando são **salvos** (via arquivos).
* Câmera 3D: usa o primeiro viewport 3D. Arquivos maiores que 128 MB são ignorados.
* `project.godot`, `export_presets.cfg`, `.godot/` e `.git/` não são copiados como arquivos.
* Se a cópia local de alguém ficar inconsistente, o plugin pede o estado ao host (ressincroniza); alterações locais
  ainda não enviadas naquele instante são descartadas. O botão *Forçar ressincronização* (aba Opções) faz isso manualmente.

## Testes

* **Unitários (sem editor):**
  `godot --headless --path <projeto> -s res://addons/godot_live_collab/tests/unit_tests.gd`
  (OT de texto e modelo de cena sob concorrência aleatória, protocolo, endereços LAN, pastas, conexões de sinais).
* **Integração com dois editores reais (Windows / PowerShell):**
  `powershell -ExecutionPolicy Bypass -File addons\godot_live_collab\tests\integration\glc_kit.ps1 -Godot C:\caminho\Godot_v4.7.2-stable_win64_console.exe`
  (opcional: `-Scenarios tree_live,files_live`). Com `-Gui` os dois editores abrem com janela (desenho do editor
  de scripts, diálogos, teclado de verdade): use para `script_gui` e `attach_dialog`. Também há a versão bash
  (`run_all.sh`) para Linux/macOS.

## Estrutura

```
core/       protocol · session_manager (rede, auth, ordenação) · lan_discovery · text_ot (OT) · scene_model · settings
sync/       scene_tree_sync · property_resource_sync · script_live_sync · file_sync · project_settings_sync · avatar_presence_sync
ui/         collab_dock
tests/      unit_tests.gd · integration/ (dois editores headless: glc_kit.ps1 no Windows, run_all.sh no Linux/macOS)
```
