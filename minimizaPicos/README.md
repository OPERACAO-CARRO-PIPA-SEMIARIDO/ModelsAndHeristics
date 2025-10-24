Motivação do Projeto

Observou-se que o modelo de otimização inicial, implementado com o Gurobi Optimizer, tende a concentrar um grande número de entregas em um único dia. Do ponto de vista logístico, essa concentração pode gerar problemas operacionais, uma vez que cada manancial possui uma capacidade limitada de expedições diárias. Em grande escala, a ocorrência de picos de demanda se torna um desafio significativo.

A principal motivação desta parte do projeto é desenvolver modelos matemáticos que visem minimizar os picos de entregas ao longo do ano. Para garantir que as soluções propostas também sejam eficientes, foi adotado um critério de desempate secundário: a minimização da quantidade total de entregas anuais.

Descrição dos Scripts

A seguir, uma descrição detalhada de cada script e sua finalidade no projeto.

Modelos de Otimização

    minimizaPicos.jl

        Este é o modelo matemático final, que utiliza o Gurobi Optimizer para encontrar a solução ótima.

        Simula um cenário com entregas no início do dia, definindo o volume mínimo do reservatório como 0.

    minimizaPicos1.jl

        Uma variação do modelo anterior, com uma alteração na restrição de volume mínimo.

        Neste script, o limite mínimo de volume do reservatório é o consumo diário do beneficiário.

        Essa abordagem representa um cenário com entregas ao final do dia.


    miniMinimizaPicos.jl

        Versão simplificada do modelo principal com inserção de dados manual.

        Projetado para testes rápidos e para a análise de comportamento do modelo em cenários controlados e de pequena escala.

Scripts de Análise e Pré-processamento

    analisePlanilha.jl

        Utilitário para processar as planilhas de resultados geradas pelos modelos.

        Extrai e exibe métricas chave, como:

            O maior pico de entregas e os dias em que ele ocorre.

            A quantidade mínima de entregas em um único dia.

            A média de entregas diárias.

            O número total de entregas ao longo do ano.

    CapacidadeVsConsumo.jl

        Script para identificar e separar beneficiários com risco de desabastecimento.

        Analisa a relação entre a capacidade do reservatório e o consumo para determinar quais beneficiários não suportam longos períodos sem recebimento de água.

        Agora implementado diretamente no modelo, na parte de pre-processamento de dados. O modelo separa apenas os índices dentro do range determinado.

    diasProblematicosTratamento.jl

        Utiliza os dados gerados pelo CapacidadeVsConsumo.jl para criar um calendário de entregas obrigatórias.

        Seu objetivo é forçar o abastecimento de beneficiários vulneráveis antes de períodos críticos, como feriados prolongados (ex: Carnaval), agendando entregas consecutivas para que eles possam se preparar.

    feriados.jl

        Script auxiliar para analisar a frequência de dias não úteis consecutivos no calendário, ajudando a identificar períodos que podem impactar a logística de entrega.

Descrição do modelo final

A seguir uma descrição com mais detalhes do modelo final.

Como entrada de dados o modelo recebe, em planilhas, calendários que determinam os dias uteis do ano, dias de entregas obrigatórias para beneficiarios que, por conta de sua baixa capacidade nos reservatórios e dias não uteis sequenciais, em algum período ano ficariam sem abastecimento e dados de quantidade de pessoas e capacidade dos reservatorios de cada beneficiario. Ademais, dentro do código é possível definir o número de dias e beneficiarios que o modelo vai rodar.
Na primeira parte do código ocorre um pré-processamento de dados. Nessa parte, vetores com o uso diario e capacidade de cada beneficiario são definidos, bem como beneficiarios que ficariam sem abastecimento, como já citados, tem seus índices coletados.
Depois o modelo matemático é definido. Com a sintaxe do JuMP define-se as variáveis, restrições e função objetivo para o Gurobi Optimizer.