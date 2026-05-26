# Análise de Custos — Sliding Window

## TL;DR

Os custos calculados pelo `gerar_controle` nos arquivos `controle_sliding.xlsx` estão **~4.3x acima do valor real** por um bug no salvamento das fontes. Os valores corretos estão na tabela abaixo.

---

## Custos corretos (recomputados com heurística de alocação)

| Configuração       | Entregas | Custo **ERRADO** (controle_sliding.xlsx) | Custo **CORRETO** (heurística) |
|--------------------|----------|------------------------------------------|-------------------------------|
| sliding\_60\_14\_3  | 53.510   | 8.030.469                                | **2.269.678**                 |
| sliding\_90\_14\_3  | 49.560   | 7.467.429                                | **2.122.377**                 |
| sliding\_120\_14\_3 | 48.518   | 7.320.367                                | **2.078.368**                 |

## Referência: minimizaPicos + saidas\_3

| Instância    | M1 Diário  | M2 (fonte única) |
|--------------|------------|-----------------|
| alocacao\_00  | 1.651.961  | 1.750.413       |
| alocacao\_10wLim | 1.608.397 | 1.634.182    |

Os custos corretos do sliding window (~2.1–2.3M) são maiores que saidas\_3 (~1.65–1.75M) porque o sliding window gera mais entregas totais, pressionando mais a capacidade dos mananciais.

---

## Qual é o bug

**Arquivo:** `modeloSlidingArgs.jl` → função `salvar_saidas_sliding`

**O que acontece:** A função salva a fonte (manancial) atribuída a cada beneficiário em `alocacao_melhor_absoluto.csv`. Mas **93% das fontes registradas estão erradas** — apontam para mananciais fora do top-3 candidatos do beneficiário.

**Exemplo concreto:**
- Beneficiário 1, top-3 candidatos: fontes 9, 11, 45 (distâncias ~51–58)
- Fonte **salva no arquivo**: 31 (rank #92 de 92 — o **mais distante**, dist=272)

**Por que o Obj do histórico está certo?** O `historico_sliding_window.csv` usa `objective_value(model)` diretamente do solver — não depende dos arquivos de alocação. Ele reflete o custo real da otimização (~452K–600K por período de 90 dias).

**Por que o `gerar_controle` fica errado?** Ele lê as fontes do `alocacao_melhor_absoluto.csv` para calcular `distância × caminhões`. Com fontes erradas (muito distantes), o custo explode.

**Causa provável:** Acesso indexado à `SparseAxisArray` do JuMP para o `val_z[j, i]` pode retornar 0 mesmo quando a variável tem valor 1, fazendo `fonte_escolhida = 0` e corrompendo o arquivo.

---

## O que está OK

- `minimizaPicos.jl` — sem erros de lógica
- `rolling_horizon.py` — lógica de sobreposição e consolidação correta; o `abastecimento_GLOBAL.csv` está correto
- `alocacao/saidas_3` (M1 Diário, M2, Heurística) — sem erros de lógica, valores confiáveis

---

## O que precisa ser corrigido

1. **`salvar_saidas_sliding`** em `modeloSlidingArgs.jl`: verificar por que `val_z[j, i]` não retorna o valor correto e corrigir o loop de salvamento da fonte
2. **Após corrigir**: rerodar `gerar_controle` (ou recalcular custos via heurística) para atualizar os `controle_sliding.xlsx`
