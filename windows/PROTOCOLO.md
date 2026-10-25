# Evidência e limites — FREE WOLF F75

Versão atual: **F75 Studio 1.0**. Esta 1.0 muda apenas consumo de memória/CPU e o momento das consultas (status USB por evento de dispositivo, caminho HID em cache, sem polling periódico pelo cabo). Os pacotes e comandos USB são os mesmos da 1.0.

Investigação inicial: 18/10/2026. Atualização da documentação: 24/10/2026. Análise local do software instalado pelo usuário.

## Fontes locais

- `C:\Program Files\FREE  WOLF  F75\DeviceDriver.exe`, versão declarada em `config.xml`: 1.0.4.4.
- SHA-256 do executável analisado: `a57d957088cfb15438637bc8184cf3e26f572bcc3360a7706c5279280f5f6bb3`.
- `layouts\kb-k600t.xml`: 81 teclas ativas, posições, códigos HID, índices da matriz, 20 modos de efeito e modo customizado 24. Comentários XML foram excluídos na extração. `source/layout.json` contém apenas essa descrição.
- `language\1033.lan`: nomes dos modos, quatro opções de suspensão e três níveis de resposta.
- Endereços abaixo são VAs do PE x86 com base `0x400000`, exclusivos dessa versão.

## Transporte verificado

Windows enumerou `VID=1A2C PID=A073`, fabricante Shinetek Technology, USB Gaming Keyboard. A interface que respondeu foi MI_00, UsagePage FF02, Usage 2, relatórios de entrada e saída de 65 bytes. MI_02/Col05 não aceitou a consulta enviada na investigação e não é usada pelo novo aplicativo.

Relatório Windows: `00 AA 55 CC 33 command payload...`, preenchido com zeros até 65 bytes. O `00` inicial é o report ID. A função do original em `0x43FFE0` insere esse byte antes de escrever; `0x441930` usa WriteFile. Algumas funções já recebem o report ID pronto, como `0x43FCC0`.

Consulta `0E` observada em `0x4406D4` e `0x42892C`. Resposta recebida no hardware: `AA 55 CC 33 0E 64 03 00 ...`. O original interpreta `64` como 100% e `03` como USB. A nova implementação validou o mesmo resultado via seu transporte C#.

## Status e conexão na versão 0.6

A interface mantém conexão e bateria em um painel persistente. A consulta automática usa intervalo de 30 segundos apenas com a janela visível. O percentual exibido é o valor relatado pelo firmware, sem estimativa criada pelo aplicativo. A leitura USB de 100% observada não comprova a carga real da bateria.

O receptor 2,4 GHz tem consulta experimental limitada ao comando conhecido `0E`; sua enumeração no Windows não comprova vínculo com o teclado. Configurações continuam restritas ao dispositivo USB identificado. Não há leitura de bateria Bluetooth confirmada; ausência de resposta válida deve ser apresentada como indisponível.

## Comandos derivados estaticamente

Offsets nesta tabela são do payload após o comando, não do report ID.

| Comando | Dados | Evidência |
| --- | --- | --- |
| `07` | modo−1, brilho−1, velocidade−1, direção, índice da paleta | `0x411130`–`0x4111E4`; campos de t_light_data |
| `0B` | zeros | `0x4111E9`–`0x411220`, entrada no modo 24 |
| `F6`–`FB` | seis blocos de 54 bytes de RGB | `0x429F20`–`0x42A194` |
| `0C` | opção de suspensão 1–4 | `0x411D71`; string sleeptime; construção das opções em `0x42E83A` |
| `0D` | nível de resposta 1–3 | `0x411EB1`; string key_responsetime; opções em `0x42EDB3` |
| `00`–`02` | três blocos de 54 bytes para uma macro | `0x4106B0`–`0x41089A` |
| `04` | camada, índice da tecla, função padrão=0 | `0x4105DA` e `0x410A11` |

RGB: vetor de 108 posições × três bytes. Ordem R/G/B derivada da cópia do COLORREF armazenado pelo driver. O mapa entre uso HID e índice utiliza key_index do layout (`0x41C935`/`0x41C95E`). Slots sem tecla são preenchidos com preto. O brilho customizado é aplicado aos canais pelo aplicativo; o modo customizado é enviado no brilho máximo do firmware.

Macros: vetor de 162 bytes, começando por camada 1, índice da tecla, execução 1, quantidade de eventos, seguido de pares uso HID/tempo. A função `0x4232F0` codifica o tempo em 5 bits, escala em 2 bits e soltura no bit 7. Escalas identificadas: 10, 50, 100 e 1000 ms. A interface rejeita mais de 60 eventos e sequências que deixam teclas pressionadas. Não houve escrita de macro no hardware durante a verificação.

Não foi encontrado comando separado para a barra lateral. Revisão de 24/10/2026 dos 20 pontos do `DeviceDriver.exe` que montam pacotes `AA 55 CC 33`: o comando `07` usa só os cinco bytes acima, a interface do original não tem nenhum texto ou opção de barra/lateral/logo, e as 27 posições do vetor RGB sem tecla já recebem preto sem apagar a barra. Comandos usados pelo original e não implementados aqui: `10 00`/`10 01` (associado à chave `fn_switch`), `08` (seguido de releitura de todas as configurações), `09` (luz em tempo real, blocos a partir de `F0`), `0A` e `0F`; os três últimos sem função confirmada. Não há implementação de firmware, bootloader, reset global ou sondagem de comandos desconhecidos.

O layout XML lista também os modos 22 (`Music rhythm`) e 23 (`Screen light rhythm`), além dos 20 modos nomeados pela interface principal. O F75 Studio expõe esses dois modos como experimentais pelo mesmo comando `07`; a análise estática não confirma que o firmware os execute sem o módulo de áudio/tela do aplicativo original. O modo 21 não está listado.

Um atalho `Fn + Left Shift` para alternar efeito de faixa lateral aparece em documentação de outras variantes F75, mas não foi confirmado para o teclado `1A2C:A073`. A interface o apresenta somente como tentativa manual; nenhum comando USB de barra lateral foi inferido a partir desse atalho.

## Validação executada

- Compilação x64 do aplicativo e da ferramenta de diagnóstico: concluída.
- 11 verificações offline: limites de resposta/suspensão, estrutura de transação RGB, canais e índices Esc/seta direita, apagamento, tempo de macro, rejeição de teclas presas, 81 posições únicas, serialização e perfil inválido.
- Seis telas renderizadas em PT-BR e inglês e janela compacta; telas de iluminação inspecionadas visualmente.
- Consulta USB real, tanto na investigação Python quanto na implementação C#: resposta coincidente e válida.
- Amostra de consumo com janela carregada: após três segundos de aquecimento, em cinco segundos sem interação foram contabilizados 343,75 ms de CPU do processo, working set de 96 MiB e memória privada de 111 MiB. Execução de diagnóstico com janela oculta; não é benchmark prolongado nem comparação com o software original.
- O usuário confirmou que o RGB por tecla funcionou no teclado. Os comandos de resposta, suspensão e macros não tiveram validação física. Não há evidência de latência física, desligamento da barra, precisão dos atrasos de macro, comportamento sem cabo ou persistência após reconexão.

As gravações da aplicação têm timeout e conferência de quantidade de bytes. Operações são serializadas fora da thread da interface; fechamento fica bloqueado durante a operação. Uma falha parcial não oferece rollback: a interface informa que a operação não foi concluída e o usuário pode reaplicar o perfil. O firmware não oferece leitura de volta confirmada para esses ajustes na implementação atual.

## Alterações de interface da versão 0.6

O erro de navegação em Efeitos RGB decorria da associação de um painel WPF a dois pais lógicos. A correção constrói os elementos com um único pai. Também foram adicionados apagamento/restauração RGB temporários sem substituir as cores do perfil salvo, parâmetros de efeitos persistidos e minimização para a bandeja. Essas funções não representam novos comandos de firmware; não há suporte confirmado a Rapid Trigger ou SOCD.

As verificações históricas acima descrevem as versões anteriores. A confirmação física de status sem fio, bateria e recursos novos depende de respostas reais do teclado; esta documentação não atribui validação física aos recursos apenas implementados.

## Verificação da versão 0.6 — 24/10/2026

- Compilação x64 concluída; 16 verificações offline passaram, incluindo compatibilidade com perfil antigo, IDs dos modos 22/23, bateria 0%, percentual inválido e rejeição de resposta truncada.
- 12 telas em PT-BR/inglês e uma janela compacta capturadas; navegação repetida por Efeitos RGB, cores e dispositivo sem erro. Os processos terminaram com código 0 e stderr vazio.
- Consulta física USB retornou `AA55CC330E6403…`: bateria informada de 100%. Esse valor não comprova a carga real; o byte 6 não é usado como indicador de transporte.
- Amostra de repouso de 5 segundos após aquecimento: 31,25 ms de CPU, working set 103 MiB e memória privada 108 MiB. Não é uma comparação direta com a versão anterior nem benchmark prolongado.
- O receptor 2,4 GHz e Bluetooth não foram validados fisicamente nesta rodada. Nenhuma configuração de teclado foi enviada durante os testes; a consulta `0E` somente solicita status.
