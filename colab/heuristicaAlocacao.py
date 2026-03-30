import pandas as pd
import numpy as np
import time
import os
import sys

# --- Configurações ---
DATA_PATH = "/home/guilherme/repos/backup/AlocacaoCarrosPipas/Dados/"
REPO_PATH = "/home/guilherme/ModelsAndHeristics/"
PATH_ABASTECIMENTO = os.path.join(REPO_PATH, "minimizaPicos/resultados10wLim/abastecimento_24h.csv")
PATH_ROTAS = os.path.join(DATA_PATH, "rotas")
OUTPUT_DIR = os.path.join(REPO_PATH, "colab/")
CAPACIDADE_MANANCIAL_DIA = 12.0

# Permite limitar o número de beneficiários para testes rápidos
# Pode ser passado via linha de comando: python heuristicaAlocacao.py 100
LIMIT_BENEFICIARIES = int(sys.argv[1]) if len(sys.argv) > 1 else None

if not os.path.exists(OUTPUT_DIR):
    os.makedirs(OUTPUT_DIR)

print("--- INICIANDO EXECUÇÃO CORRIGIDA ---")
if LIMIT_BENEFICIARIES:
    print(f"MODO DE TESTE: Limitando a {LIMIT_BENEFICIARIES} beneficiários.")

# --- 1. Carregamento Seguro ---
try:
    df_abastecimento = pd.read_csv(PATH_ABASTECIMENTO)
    
    if LIMIT_BENEFICIARIES:
        df_abastecimento = df_abastecimento.head(LIMIT_BENEFICIARIES)
        
    # Separa IDs dos dados de demanda
    ids_beneficiarios = df_abastecimento.iloc[:, 0].values
    matriz_demanda = df_abastecimento.iloc[:, 1:].values.astype(float)
    num_beneficiarios, num_dias = matriz_demanda.shape
    print(f"Demanda carregada: {num_beneficiarios} beneficiários.")
except Exception as e:
    print(f"ERRO ao ler abastecimento: {e}")
    sys.exit(1)

try:
    # Lê o arquivo de rotas
    df_rotas = pd.read_csv(PATH_ROTAS)
    
    # Tenta identificar colunas pelos nomes usados no Julia
    # O Julia usa: rotas.id_beneficiario, rotas.id_fonte, rotas.distance_w_factor
    cols = df_rotas.columns.str.lower()
    
    # Mapeamento dinâmico de colunas para evitar erro de índice
    col_ben = next((c for c in df_rotas.columns if 'beneficiario' in c.lower() or 'id_beneficiario' in c.lower()), None)
    col_fonte = next((c for c in df_rotas.columns if 'fonte' in c.lower() or 'id_fonte' in c.lower()), None)
    col_dist = next((c for c in df_rotas.columns if 'dist' in c.lower()), None)

    # Se não achar pelo nome, tenta usar a posição padrão (0, 1, 2)
    if not col_ben or not col_fonte:
        print("AVISO: Cabeçalhos não encontrados. Usando índices 0 (Ben), 1 (Fonte), 2 (Dist).")
        idx_ben, idx_fonte, idx_dist = 0, 1, 2
    else:
        print(f"Colunas identificadas: Ben='{col_ben}', Fonte='{col_fonte}'")
        idx_ben = df_rotas.columns.get_loc(col_ben)
        idx_fonte = df_rotas.columns.get_loc(col_fonte)
        idx_dist = df_rotas.columns.get_loc(col_dist) if col_dist else 2

    # Construção da Matriz de Custo
    num_mananciais = 92
    matriz_custo = np.full((num_mananciais, num_beneficiarios), np.inf)
    
    for row in df_rotas.itertuples(index=False):
        # Acesso seguro via índice
        b_idx = int(row[idx_ben])
        f_idx = int(row[idx_fonte])
        dist = float(row[idx_dist])
        
        # Validação de limites
        if b_idx < num_beneficiarios and f_idx < num_mananciais:
            matriz_custo[f_idx, b_idx] = dist
            
    print("Matriz de custos montada com sucesso.")

except Exception as e:
    print(f"ERRO CRÍTICO ao ler rotas: {e}")
    sys.exit(1)

# --- 2. Algoritmo de Alocação ---
start_time = time.time()
usage_y = np.zeros((num_mananciais, num_dias))
alocacao_final_idx = np.full(num_beneficiarios, -1) # Armazena índice 0-91

# Ordenação (Gulosa)
volumes = np.sum(matriz_demanda, axis=1)
ordem = np.argsort(volumes)[::-1]

for j in ordem:
    demanda_j = matriz_demanda[j, :]
    if np.sum(demanda_j) == 0:
        continue
    
    # Seleção de fontes
    distancias = matriz_custo[:, j]
    fontes_candidatas = np.argsort(distancias)
    
    for i in fontes_candidatas:
        if distancias[i] == np.inf:
            break
        
        # Verifica capacidade
        if np.all(usage_y[i, :] + demanda_j <= CAPACIDADE_MANANCIAL_DIA):
            alocacao_final_idx[j] = i
            usage_y[i, :] += demanda_j
            break

# --- 3. Geração das Saídas (Do Zero) ---
print("Gerando arquivo de saída...")

# Cria um DataFrame novo, limpo.
colunas_dias = df_abastecimento.columns[1:]
df_output = pd.DataFrame(columns=['Beneficiarios'] + list(colunas_dias))
df_output['Beneficiarios'] = ids_beneficiarios

# Matriz de dados para preencher o DataFrame
dados_saida = np.zeros((num_beneficiarios, num_dias), dtype=int)

for j in range(num_beneficiarios):
    manancial_idx = alocacao_final_idx[j] # Índice 0 a 91
    
    if manancial_idx != -1:
        # Lógica Crucial: ID Output = Índice + 1
        # Ex: Índice 0 vira Manancial 1.
        id_output = manancial_idx + 1
        
        # Onde tem demanda, escreve o ID do Manancial. Onde não tem, mantém 0.
        mask = matriz_demanda[j, :] > 0
        dados_saida[j, mask] = id_output

# Injeta os dados na planilha
df_output.iloc[:, 1:] = dados_saida

# Verifica integridade antes de salvar
max_val = np.max(dados_saida)
if max_val > 92:
    print(f"ERRO: Valor inválido detectado ({max_val}). O arquivo não será salvo corretamente.")
else:
    output_path = os.path.join(OUTPUT_DIR, "Heu10wLim.csv")
    df_output.to_csv(output_path, index=False)
    print(f"Arquivo salvo CORRETAMENTE em: {output_path}")

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
df_metricas.to_csv(os.path.join(OUTPUT_DIR, "custoHeu10wLim.csv"), index=False)
print("Concluído.")
