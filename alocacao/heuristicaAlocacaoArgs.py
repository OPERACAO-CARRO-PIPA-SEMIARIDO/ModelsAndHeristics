import pandas as pd
import numpy as np
import time
import sys

if len(sys.argv) < 6:
    print("Uso: python heuristica.py <planilha_entrada.csv> <planilha_saida_alocacao.csv> <planilha_saida_custos.csv> <planilha_rotas.csv> <num_mananciais>")
    sys.exit(1)

# Recebendo os caminhos via linha de comando (passados pela automação)
PATH_ABASTECIMENTO = sys.argv[1]
OUTPUT_ALOCACAO = sys.argv[2]
OUTPUT_CUSTOS = sys.argv[3]
PATH_ROTAS = sys.argv[4] # Caminho dinâmico das rotas
num_mananciais = int(sys.argv[5])

CAPACIDADE_MANANCIAL_DIA = 12.0

# --- 1. Carregamento Seguro ---
try:
    df_abastecimento = pd.read_csv(PATH_ABASTECIMENTO)
    ids_beneficiarios = df_abastecimento.iloc[:, 0].values
    matriz_demanda = df_abastecimento.iloc[:, 1:].values.astype(float)
    num_beneficiarios, num_dias = matriz_demanda.shape
    
    # Criar um mapeamento de ID do beneficiário (do CSV) para o índice na matriz (0 a num_beneficiarios-1)
    # Assumimos que o ID no arquivo de rotas (id_beneficiario) corresponde ao valor na primeira coluna do abastecimento - 1
    # Se o ID no CSV de abastecimento for 1, no rotas ele é 0.
    map_id_para_idx = {int(id_b): i for i, id_b in enumerate(ids_beneficiarios)}
    
except Exception as e:
    print(f"ERRO ao ler abastecimento: {e}")
    sys.exit(1)

try:
    df_rotas = pd.read_csv(PATH_ROTAS)
    
    # ... (busca de colunas mantida)
    col_ben = next((c for c in df_rotas.columns if 'beneficiario' in c.lower() or 'id_beneficiario' in c.lower()), None)
    col_fonte = next((c for c in df_rotas.columns if 'fonte' in c.lower() or 'id_fonte' in c.lower()), None)
    col_dist = next((c for c in df_rotas.columns if 'dist' in c.lower()), None)

    if not col_ben or not col_fonte:
        idx_ben, idx_fonte, idx_dist = 0, 1, 2
    else:
        idx_ben = df_rotas.columns.get_loc(col_ben)
        idx_fonte = df_rotas.columns.get_loc(col_fonte)
        idx_dist = df_rotas.columns.get_loc(col_dist) if col_dist else 2

    matriz_custo = np.full((num_mananciais, num_beneficiarios), np.inf)
    
    for row in df_rotas.itertuples(index=False):
        b_id_rotas = int(row[idx_ben])
        f_idx = int(row[idx_fonte])
        dist = float(row[idx_dist])
        
        # O id_beneficiario no rotas começa em 0. No abastecimento começa em 1.
        id_abastecimento = b_id_rotas + 1
        
        if id_abastecimento in map_id_para_idx and f_idx < num_mananciais:
            idx_matriz = map_id_para_idx[id_abastecimento]
            matriz_custo[f_idx, idx_matriz] = dist

except Exception as e:
    print(f"ERRO CRÍTICO ao ler rotas: {e}")
    sys.exit(1)

# --- 2. Algoritmo de Alocação ---
start_time = time.time()
usage_y = np.zeros((num_mananciais, num_dias))
alocacao_final_idx = np.full(num_beneficiarios, -1) 

volumes = np.sum(matriz_demanda, axis=1)
ordem = np.argsort(volumes)[::-1]

for j in ordem:
    demanda_j = matriz_demanda[j, :]
    if np.sum(demanda_j) == 0:
        continue
    
    distancias = matriz_custo[:, j]
    fontes_candidatas = np.argsort(distancias)
    
    for i in fontes_candidatas:
        if distancias[i] == np.inf:
            break
        if np.all(usage_y[i, :] + demanda_j <= CAPACIDADE_MANANCIAL_DIA):
            alocacao_final_idx[j] = i
            usage_y[i, :] += demanda_j
            break

# --- 3. Geração das Saídas ---
colunas_dias = df_abastecimento.columns[1:]
df_output = pd.DataFrame(columns=['Beneficiarios'] + list(colunas_dias))
df_output['Beneficiarios'] = ids_beneficiarios
dados_saida = np.zeros((num_beneficiarios, num_dias), dtype=int)

for j in range(num_beneficiarios):
    manancial_idx = alocacao_final_idx[j] 
    if manancial_idx != -1:
        id_output = manancial_idx + 1
        mask = matriz_demanda[j, :] > 0
        dados_saida[j, mask] = id_output

df_output.iloc[:, 1:] = dados_saida
df_output.to_csv(OUTPUT_ALOCACAO, index=False)

# --- Métricas ---
custos = []
for d in range(num_dias):
    c = 0.0
    for j in range(num_beneficiarios):
        f = alocacao_final_idx[j]
        if f != -1 and matriz_demanda[j, d] > 0:
            c += matriz_custo[f, j] * matriz_demanda[j, d]
    custos.append(c)

df_metricas = pd.DataFrame({
    "Tempo_de_Execucao": [time.time() - start_time] * num_dias, 
    "Solucao_otima": custos,
    "Num_Variaveis": [num_beneficiarios] * num_dias
})
df_metricas.to_csv(OUTPUT_CUSTOS, index=False)
