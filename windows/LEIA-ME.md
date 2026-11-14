# F75 Studio para Windows — FREE WOLF F75

## Instalação e uso

**Portátil:** extraia o ZIP do F75 Studio em qualquer pasta (ou pendrive) e abra `F75 Studio.exe`. Não instala nada; o perfil fica na pasta `Dados` ao lado do programa, porque o arquivo `portable.txt` está presente. Apagar a pasta remove tudo.

**Instalável:** execute **F75-Studio-Setup** para instalar no Windows 64 bits. O instalador oferece português brasileiro e inglês, cria um atalho no menu Iniciar e permite criar um atalho na área de trabalho. Requer .NET Framework 4.8. Para enviar ajustes, conecte o teclado por um cabo USB de dados e feche o programa original.

1. Em **Cores por tecla**, escolha uma cor na paleta, digite um valor hexadecimal (`#RRGGBB`) ou abra **Mais cores**.
2. Clique numa tecla do desenho para pintá-la. Use **Ctrl + clique** para marcar várias teclas e **Pintar seleção**. Há botões para pintar todas, apagar todas, desfazer e aplicar estilos iniciais.
3. Ajuste o brilho e clique em **Aplicar cores** na barra inferior. A prévia mostra o desenho antes do envio.
4. **Efeitos RGB** oferece 20 efeitos identificados e dois modos experimentais de ritmo de música/tela declarados no layout do programa original. Os modos experimentais podem depender do módulo original. Enviar um efeito substitui o desenho personalizado até que ele seja reaplicado.
5. **Desempenho** oferece os três níveis de resposta documentados pelo fabricante. O preset de baixa latência seleciona o nível 1 e desativa a suspensão. Se estiver sem cabo, o pedido fica pendente. Conecte o cabo e clique em **Enviar pendências**.
6. **Perfis** exporta e importa arquivos JSON. O perfil local é salvo em `%LOCALAPPDATA%\F75Studio\session.json`.
7. Em **Dispositivo → Ao fechar a janela**, escolha **Enviar ajustes pendentes e encerrar** (padrão) ou **Recolher para a bandeja**. No primeiro modo, o app só envia os grupos alterados. Se o envio falhar, você pode voltar à janela ou encerrar com as pendências salvas no perfil local. Na bandeja, a interface é descarregada e as consultas ficam pausadas. O menu do ícone permite abrir o app, desligar/restaurar o RGB e encerrar.

Na página **Macros**, você pode digitar uma sequência na caixa de gravação dedicada, parar, revisar e enviar para uma tecla escolhida. O gravador registra somente enquanto essa caixa está focada; o formato e comando de macro existem no driver original, mas a execução física ainda é experimental.

O aplicativo se comunica por USB com o F75 identificado como `VID 1A2C`, `PID A073`, interface HID `FF02:0002`. Conexão, leitura de status e RGB por tecla foram confirmados neste teclado. Efeitos, tempo de resposta, suspensão e macros foram identificados no executável original; os resultados físicos ainda precisam de confirmação. Macros permanecem experimentais. A gravação de configurações via Bluetooth ou receptor 2,4 GHz não está habilitada. O receptor 2,4 GHz pode ser consultado de forma experimental somente para status, pelo comando conhecido `0E`; detectar um receptor não comprova que o teclado esteja conectado a ele. Bluetooth sem leitura disponível aparece com bateria indisponível.

O painel de conexão e bateria permanece visível durante a navegação. A consulta ocorre ao abrir, ao restaurar a janela, em mudanças de dispositivo com a janela visível ou pelo botão **Atualizar conexão e bateria**. Em USB, os valores são os relatados pelo dispositivo; uma leitura de 100% com cabo não comprova a carga real da bateria. Se não houver leitura válida, o programa informa que a bateria está indisponível.

**Barra branca lateral:** a barra da foto é separada das luzes das teclas. A análise do driver original ainda não identificou um comando independente para apagá-la. O aplicativo não mostra um botão que promete controlar essa barra, porque enviar comandos USB desconhecidos poderia alterar o teclado de forma imprevisível.

## Validação no teclado

Um envio bem-sucedido confirma que os relatórios chegaram à interface USB. Só um teste com o teclado reiniciado confirma a persistência na memória dele. Para conferir o RGB, aplique uma cor fácil de reconhecer, feche o app, retire o cabo, desligue o teclado completamente e ligue-o com o app fechado. Confira a iluminação e, se aplicável, a suspensão. O app não confirma o valor da resposta das teclas por leitura de volta.

## Melhorias de leveza

- Ao minimizar ou esconder, a interface inteira é descartada e a memória devolvida ao Windows; ela é recriada ao restaurar.
- Bandeja e seletor de cores feitos direto na API do Windows: System.Windows.Forms e System.Drawing não são mais carregados.
- JSON próprio no lugar do JavaScriptSerializer: System.Web.Extensions não é mais carregado. O `session.json` da 1.0 continua compatível.
- Layout das teclas compilado no código, sem ler JSON na abertura.
- Sem consulta USB a cada 30 s; atualização por evento de conexão/remoção. O caminho do dispositivo fica em cache, sem enumerar todos os HID a cada envio.
- Gravação do perfil local agrupada (800 ms) em vez de gravar em disco a cada passo do brilho ou a cada clique.
- Cores da interface em cache e congeladas, em vez de criar centenas de objetos a cada tela e a cada clique.
- Renderização por software (sem Direct3D). Para comparar, abra com `"F75 Studio.exe" --gpu`.
- GC sem thread em segundo plano (`F75 Studio.exe.config`).
- Gravador de macro reconhece teclado numérico, tecla Menu e as teclas extras do ABNT2.
- `--measure` mede também o estado minimizado.

## Correções herdadas da 0.6

- Corrigida a falha ao abrir Efeitos RGB: um painel WPF era vinculado a dois elementos da interface.
- Apagar e restaurar o RGB enviado sem substituir as cores do perfil salvo.
- Minimização para a bandeja e parâmetros de efeitos lembrados entre sessões.

Essas melhorias usam os recursos já identificados. Não há suporte confirmado a Rapid Trigger ou SOCD neste modelo.

## Desenvolvimento

O código fica em `source`. Execute `source\build.ps1` no PowerShell para gerar o executável e compile `source\installer.iss` com Inno Setup 6 para gerar o instalador. `F75 Diagnostics.exe --diagnose` consulta o dispositivo; `--self-test` executa verificações offline. Veja `PROTOCOLO.md` para detalhes dos comandos e limites conhecidos.

## English

Run the portable app or install F75 Studio on 64-bit Windows with .NET Framework 4.8. Choose a color, click keys in the diagram and select **Apply colors**. Use a USB data cable to send settings. With USB unavailable, the app saves pending settings locally. Connect the cable and select **Send pending settings**. In **Device**, choose whether closing sends pending settings and quits or minimizes to the system tray.

Per-key RGB has been confirmed on this keyboard. Effect, performance, sleep and macro behavior still needs physical validation; macros are experimental. There is no verified independent command for the white side bar. Bluetooth and 2.4 GHz configuration writes are disabled. The receiver status query is experimental and read-only. Connection and reported battery refresh on open, restore, a device event or manual request. Keyboard retention after power-off needs hardware verification.


