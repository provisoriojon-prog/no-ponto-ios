# No Ponto

App independente para acompanhar ônibus municipais e BRT do Rio no iPhone. Interface nativa, sem anúncios, cadastro ou SDK de publicidade. É um aplicativo separado do Voa!, com identificador `br.com.provisoriojon.noponto` e ícone próprio.

## Uso

1. Instale o `NoPonto-unsigned.ipa` pelo AltStore Classic já configurado no seu iPhone. O arquivo precisa ser assinado pelo seu fluxo AltStore; o build do GitHub não contém certificado Apple pessoal. A renovação depende da sua conta e configuração do AltStore.
2. O primeiro mapa começa sem ônibus. Toque na lupa e digite pelo menos dois dígitos (ou duas letras de um destino). Surgem até oito sugestões, preservando prefixos como SR397 e SN397.
3. Ao escolher uma linha, ela é salva automaticamente e a busca fecha. Só suas linhas aparecem no mapa, com pequenos veículos coloridos e círculos de acesso à esquerda. Elas continuam salvas ao reabrir o app. O menu permite remover uma ou todas.
4. Toque em uma linha ou veículo para revelar a informação contextual; abra os detalhes para confirmar **sentido**, **ponto de embarque** e consultar estimativas. Favoritos de embarque como “Ida” e “Volta” continuam disponíveis pelo menu.
5. Pontos são marcas discretas, visíveis de perto. Toque no botão de localização para se orientar; “Como chegar ao ponto” calcula uma caminhada pelo Apple Maps quando solicitado. Diagnósticos e configurações ficam na engrenagem.

A versão 1.1 mantém o identificador do aplicativo. Atualize pelo mesmo AltStore sem desinstalar para preservar os favoritos existentes. Eles não ativam linhas automaticamente no novo mapa.

O app exige iOS 17 ou superior. As atualizações funcionam enquanto ele está aberto. Não há promessa de atualização contínua ou alertas de chegada em segundo plano nesta versão.

## Dados e precisão

- [Catálogo GTFS oficial da SMTR](https://dados.mobilidade.rio/gtfs/schedule): linhas, sentidos, variantes, pontos e geometria. A cópia embarcada mantém todas as rotas recebidas; o relatório `catalog-audit.json` registra a quantidade e as limitações verificadas.
- [Posições de ônibus](https://dados.mobilidade.rio/gtfs/realtime/onibus/vehicle-positions) e [posições do BRT](https://dados.mobilidade.rio/gtfs/realtime/brt/vehicle-positions): fontes municipais GTFS-Realtime. [Documentação DATA.RIO](https://www.data.rio/documents/997bc16cc4344a5cb0e48ab06cbdfd1f/about).
- Mapas e rotas a pé: Apple Maps. Este app não é oficial da Prefeitura e não usa código, recursos visuais nem servidores do aplicativo estudado anteriormente.

As chegadas são estimativas locais, não horários oficiais garantidos. O app considera o trajeto, a ordem dos pontos, o movimento observado e o horário original do GPS. Veículos parados, sinal antigo, associação ambígua ao percurso ou dados insuficientes são identificados; uma resposta recente do servidor não torna uma posição antiga atual.

O GPS pode não distinguir calçadas opostas. Sempre confirme ponto e destino. Distâncias dos pontos próximos são em linha reta; o tempo de caminhada só aparece depois de uma resposta real do Apple Maps. Cobertura intermunicipal de todo o estado não está incluída.

Sem internet, catálogo e favoritos continuam disponíveis. Posições guardadas exibem a idade do sinal. O mapa-base depende do cache do Apple Maps; não prometemos um mapa totalmente disponível sem conexão.

Dados de transporte atribuídos à Prefeitura do Rio / SMTR sob [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). O catálogo foi convertido, as geometrias simplificadas e as previsões calculadas independentemente pelo No Ponto.

## Privacidade

Favoritos e preferências ficam neste aparelho. Não há backend próprio de telemetria, rastreamento publicitário ou histórico de localização enviado ao desenvolvedor. Consultas aos serviços públicos e à Apple utilizam a conexão do aparelho; ao solicitar uma caminhada, o Apple Maps recebe origem e destino. A localização é pedida apenas após uma ação do usuário.

`PrivacyInfo.xcprivacy` declara o uso de UserDefaults para preferências e favoritos do próprio aplicativo (`CA92.1`), conforme o [exemplo oficial Apple TN3183](https://developer.apple.com/documentation/technotes/tn3183-adding-required-reason-api-entries-to-your-privacy-manifest).

## Compilação e validação

Projeto Swift 5, SwiftUI/MapKit/Core Location, Xcode 16.4, gerado com XcodeGen. O GitHub Actions usa macOS para compilar o aplicativo de dispositivo e executar testes de lógica e interface no simulador. `scripts/build_catalog.py` prepara o catálogo; `scripts/make_icon.swift` gera recursos originais; `scripts/verify_ipa.py` inspeciona o IPA real, catálogo, ícones, privacidade e executável ARM64 para iPhoneOS.

O modo `--ui-testing` existe somente em builds Debug e exibe **DEMONSTRAÇÃO**. O Release usa fontes reais. Resultados automatizados e telas do simulador validam software, mas não comprovam a precisão do GPS, da bússola ou das previsões em uma viagem real. A validação física deve comparar localização e chegada observada em ônibus municipal e BRT.
