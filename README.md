# Alocação de Carros-Pipa — RN

Modelos de otimização e heurísticas para o agendamento e roteamento de carros-pipa no Rio Grande do Norte. O problema envolve 3 315 beneficiários (cisternas rurais) e 92 mananciais (fontes de abastecimento).

---

## Estrutura do Projeto

```
minimizaPicos/   Modelos de minimização de pico de entregas (gera os inputs de alocacao/)
alocacao/        Modelos de roteamento manancial–beneficiário (M1, M2, heurística)
colab/           Scripts de coleta de rotas via OSRM e pré-processamento
modeloIntegrado/ Rolling horizon e modelo integrado
analise/         Scripts de análise dos resultados
```

**Arquivos de dados sensíveis (não versionados):**
- `Beneficiarios_RN_Ativos1.csv` — cadastro dos beneficiários ativos
- `Mananciais_RN.csv` — cadastro dos mananciais
- `rotas` — matriz de distâncias ponderadas manancial × beneficiário (92 × 3 315 pares)

---

## Nomenclatura das Instâncias

As instâncias em `alocacao/entradas/` são geradas pelo modelo de minimização de picos (`minimizaPicos/minimizaPicos.jl`), cuja função objetivo é:

```
min  p · D · y  +  (1 − p) · Σ x_{j,k}
```

onde `y` = pico diário, `Σ x` = total de entregas no ano e `D` = número de dias úteis.

| Instância  | p    | Descrição |
|------------|------|-----------|
| `00`       | 0,00 | Minimiza apenas o total de entregas; ignora pico |
| `00_350`   | 0,00 | Igual a `00`, mas com restrição explícita de pico ≤ 350 |
| `01w24`    | 0,01 | Peso mínimo no pico; *warm start* a partir de `00`; limite de 24 h |
| `10wLim`   | 0,10 | Peso baixo no pico; *warm start*; limite de tempo reduzido |
| `5072h`    | 0,50 | Peso igual entre pico e entregas; sem *warm start*; limite de 72 h |
| `50wLim`   | 0,50 | Igual ao anterior com *warm start*; limite de tempo reduzido |
| `75w00`    | 0,75 | Peso alto no pico; *warm start* inicializado com a solução `00` |
| `heu_full` | —    | Calendário gerado pela heurística de agendamento — modo *full*: enche a cisterna a cada visita |
| `heu_lim`  | —    | Calendário gerado pela heurística de agendamento — modo *limite*: entrega apenas o mínimo necessário |

**Convenção dos sufixos:**
- Dois dígitos iniciais = `p × 100` (ex.: `10` → p = 0,10)
- `w` = *warm start* (Gurobi inicializado com solução viável anterior)
- `Lim` = limite de tempo curto (execução interrompida antes da convergência)
- `_350` = restrição de pico ≤ 350 adicionada ao modelo
- `72h` = limite de tempo de 72 horas
- `00` ao final de `75w00` = fonte do *warm start* (solução da instância `00`)

---

## Modelos de Roteamento (`alocacao/`)

Dado um calendário de entregas (input), cada modelo decide **qual manancial** atende cada beneficiário, minimizando o custo total de deslocamento (Σ distância ponderada × carradas).

| Modelo | Restrição de fonte | Formulação |
|--------|-------------------|-----------|
| **M1 Diário** | Livre por dia: um beneficiário pode ser atendido por mananciais diferentes em dias distintos | ILP resolvido dia a dia |
| **M1 Anual** | Livre por dia: igual ao M1 Diário, mas resolvendo todos os 365 dias em um único ILP | ILP anual (limite 24 h) |
| **M2** | Fonte única: cada beneficiário é atribuído a um único manancial para o ano inteiro (`fonte_unica`) | ILP anual com variável binária de atribuição (limite 24 h) |
| **Heurística** | Fonte única: atribuição gulosa por proximidade, ordenando beneficiários por volume total | Algoritmo guloso |

**Capacidade dos mananciais:** 12 carradas/dia.

---

## Planilha de Resultados — `alocacao/saidas_3/resumo_custos.xlsx`

### Colunas de Identificação e Volume

| Coluna | Descrição |
|--------|-----------|
| `Nome da Instância` | Identificador da instância (ver tabela acima) |
| `Total de Entregas` | Soma total de carradas entregues no ano (Σ x_{j,k}) |
| `Pico de Abastecimento (Max/Dia)` | Número máximo de carradas despachadas em um único dia |
| `Status` | Resultado da execução dos modelos (`Sucesso` / erro) |

### Colunas de Custo

O custo é calculado como `Σ distância_ponderada[manancial, beneficiário] × carradas[dia]`.
A distância ponderada já incorpora a qualidade da estrada de acesso de cada manancial e beneficiário.

| Coluna | Descrição |
|--------|-----------|
| `Custo M1 Diário` | Custo ótimo com atribuição livre de manancial por dia (melhor limite inferior) |
| `Custo M1 Anual` | Custo do ILP anual sem restrição de fonte única — deve ser igual ao M1 Diário, confirma consistência |
| `Custo M2` | Custo com fonte única por beneficiário (restrição mais rígida → custo maior que M1) |
| `Custo Heurística` | Custo da solução heurística (greedy por proximidade + capacidade) |
| `Custo Alocação Original` | Custo usando a atribuição de mananciais do cadastro original (`GCDA_Manancial_Assoc`) — sem otimização |

### Colunas de Gap

Gap A vs B = `(A − B) / B × 100%`. Valores positivos indicam que A é mais caro que B.

| Coluna | Interpretação |
|--------|--------------|
| `Gap M1 Anual vs M1 Diário (%)` | Deve ser ≈ 0%; confirma que os dois modelos M1 convergem para a mesma solução |
| `Gap M2 vs M1 Diário (%)` | Custo extra por exigir fonte única (restrição `fonte_unica` do M2) |
| `Gap Heurística vs M1 Diário (%)` | Suboptimalidade da heurística em relação ao ótimo |
| `Gap Original vs M1 Diário (%)` | Ineficiência da alocação administrativa original em relação ao ótimo (~70–77%) |
| `Gap Heurística vs M2 (%)` | Comparação heurística × modelo com fonte única |
| `Gap Original vs M2 (%)` | Ineficiência da alocação original mesmo face à restrição mais rígida |
| `Gap Original vs Heurística (%)` | Quanto a alocação original perde para a heurística simples |

---

## Scripts Principais

| Script | Função |
|--------|--------|
| `minimizaPicos/minimizaPicos.jl` | Gera o calendário de entregas otimizando pico vs total |
| `modeloIntegrado/rolling_horizon.py` | Executa o modelo em janelas deslizantes (sliding window) para instâncias grandes |
| `alocacao/atualizar_resumo_saidas2.py` | Orquestra a execução dos modelos M1/M2/heurística e gera a planilha Excel |
| `alocacao/adicionar_alocacao_original.py` | Calcula o custo da alocação original e atualiza os gaps na planilha |
| `colab/rotasTratamento.py` | Gera a matriz de distâncias (arquivo `rotas`) via API OSRM |
