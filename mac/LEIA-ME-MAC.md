# F75 Studio 1.0 para Mac

App nativo para o teclado FREE WOLF F75 (USB `1A2C:A073`, HID `FF02:0002`) no macOS 11 ou mais novo, Apple Silicon e Intel. Mesmas seis telas, mesmos pacotes USB e mesmo arquivo de perfil da versão Windows 1.0.

## Por que assim (leveza)

- Interface em AppKit puro (Objective-C), sem SwiftUI, Electron, .NET nem webview. O acesso USB usa IOKit direto, sem driver e sem extensão de kernel.
- O teclado inteiro é desenhado por uma única view, não por 81 botões.
- Nada de polling: o status é lido ao abrir, ao conectar ou desconectar o cabo (evento do IOKit) e quando você pede. Só uma conexão sem fio 2,4 GHz visível é relida a cada 30 s, igual ao Windows.
- O teclado só é aberto durante cada operação e fechado logo depois.
- Ao minimizar ou ir para segundo plano, a interface inteira é descartada e a memória devolvida ao sistema (`malloc_zone_pressure_relief`).

## As duas opções ao fechar (Dispositivo → Ao fechar o F75 Studio)

- **Gravar no teclado e fechar de vez** (padrão): ao fechar a janela ou sair (⌘Q), grava no teclado a iluminação no último modo usado (cores por tecla, efeito ou RGB desligado), o tempo de resposta e a suspensão, e encerra o processo. Macros já ficam no teclado quando você as envia. Se o teclado não estiver conectado e havia mudança pendente, o app pergunta se quer tentar de novo, sair sem gravar ou cancelar.
- **Ficar em segundo plano**: fechar ou minimizar só esconde a janela. Fica apenas o ícone na barra de menus, sem ícone no Dock, sem janela, sem timers e sem acesso USB. O menu do ícone tem Abrir, Desligar RGB, Restaurar cores, Sair e gravar no teclado e Sair sem enviar.

A escolha fica no perfil (`KeepInTray`; `LightMode` guarda o último modo de luz), no mesmo formato do Windows.

## Como gerar o app e o .dmg

Num Mac, com as ferramentas de linha de comando da Apple (não precisa do Xcode):

```sh
xcode-select --install      # só na primeira vez
cd F75-Studio-Mac-1.0
./build.sh
```

Saída: `build/F75 Studio.app` e `build/F75-Studio-1.0.dmg`. O script roda os testes do núcleo, confere que os pacotes são idênticos aos do Windows 1.0, compila universal (arm64 + x86_64), assina localmente (ad-hoc) e cria o .dmg.

Sem Mac: coloque esta pasta num repositório do GitHub e rode a ação **Build F75 Studio for Mac** (`.github/workflows/build-mac.yml`); o .dmg sai como artefato.

### Primeira abertura

O app não tem assinatura de desenvolvedor Apple (isso exige conta paga). Se foi gerado no próprio Mac com `build.sh`, abre normalmente. Se veio de outro computador ou do GitHub, o macOS bloqueia na primeira vez: clique com o botão direito em F75 Studio → **Abrir**, ou em Ajustes do Sistema → Privacidade e Segurança → **Abrir Mesmo Assim**.

Feche outros apps que controlam o teclado antes de usar.

## Arquivos

- Perfil e estado: `~/Library/Application Support/F75Studio/session.json` (+ `.bak`, `errors.log`).
- Perfis exportados (`.json`) abrem tanto no Windows quanto no Mac.

## Linha de comando

```sh
"/Applications/F75 Studio.app/Contents/MacOS/F75Studio" --self-test    # 35 verificações offline
"/Applications/F75 Studio.app/Contents/MacOS/F75Studio" --diagnose     # consulta 0E e mostra a resposta
"/Applications/F75 Studio.app/Contents/MacOS/F75Studio" --measure      # CPU e memória em repouso, com janela e em segundo plano
```

`--measure` usa o mesmo número da coluna Memória do Monitor de Atividade (`phys_footprint`).

## Estrutura do código

- `core/` — protocolo, layout das 81 teclas, perfil JSON e testes, em C99 puro. Não depende de macOS; compila em qualquer sistema.
- `mac/F75HID.m` — transporte USB via IOKit (equivalente ao `Device.cs`).
- `mac/F75Views.m` — teclado desenhado, amostras de cor, captura de macro.
- `mac/F75App.m` — janela, páginas, barra de menus, ciclo de vida.
- `tests/` — `run-linux.sh` testa o núcleo sem Mac; `golden-windows-1.0.txt` são 325 linhas de pacotes e JSON geradas pelo código C# do Windows 1.0, comparadas byte a byte.

## Mac e Windows no mesmo código

O que pode ser compartilhado já é: o `core/` em C é o protocolo e o formato de perfil, testado contra o C# do Windows. As interfaces ficam nativas em cada sistema (WPF no Windows, AppKit no Mac), porque é isso que mantém o consumo baixo. Uma interface única multiplataforma (.NET + Avalonia, Electron, Qt) pesaria mais que a versão Windows atual nos dois sistemas. Se no futuro o Windows também quiser usar o `core/` em C, ele pode ser chamado por P/Invoke a partir do C#.

## O que foi testado e o que não foi

Testado (num Linux, sem Mac):
- Núcleo em C: 35 verificações passam com clang e gcc (também com AddressSanitizer e UBSan).
- Pacotes USB e JSON idênticos byte a byte ao código C# do Windows 1.0 (comandos 07, 0B, F6–FB, 0C, 0D, 00–02, 04, codificação de tempo de macro, layout, perfil, macro).
- O código Objective-C passou numa checagem de sintaxe e tipos (clang com cabeçalhos GNUstep e declarações de API do macOS), sem erros.

Não testado:
- Não foi compilado nem executado num Mac: compilar para macOS exige o SDK da Apple, que só existe num Mac. Interface, layout das telas e ciclo de vida não foram vistos rodando.
- Transporte USB no Mac (abrir a interface FF02:0002, enviar relatório de saída de 64 bytes com report ID 0, ler a resposta 0E) segue o mesmo modelo do hidapi, mas não foi conferido com o teclado.
- Os avisos de conectar e desconectar o cabo usam `IOHIDManager` sem abrir os dispositivos; se não chegarem no seu macOS, use Consultar conexão e bateria.
- Se o macOS pedir permissão de **Monitoramento de Entrada**, aceite: a interface FF02 é de fabricante e normalmente não pede.
- Mesmos limites da versão Windows: resposta, suspensão e macros não tiveram validação física; não há prova de que o teclado guarda os ajustes depois de desligado; barra lateral sem comando conhecido.
- Consumo de RAM e CPU no Mac não foi medido. Use `--measure` e o Monitor de Atividade para comparar.
