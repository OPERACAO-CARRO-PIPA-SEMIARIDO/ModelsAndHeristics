import pandas as pd
import numpy as np
import time
import os

# --- Configurações e Caminhos ---
BASE_PATH = "/home/guilherme/repos/backup/AlocacaoCarrosPipas/Dados/"
ARQUIVO_BENEFICIARIOS = os.path.join(BASE_PATH, "Beneficiarios_RN_Ativos_test.csv")
ARQUIVO_DATAS = os.path.join(BASE_PATH, "datas.csv")

# Parâmetros
CAPACIDADE_CAMINHAO = 13.0 

print("--- Iniciando Simulação (Algoritmo V2) ---")

# --- Leitura de Dados ---
try:
    beneficiarios_total = pd.read_csv(ARQUIVO_BENEFICIARIOS)
    dias_uteis_df = pd.read_csv(ARQUIVO_DATAS)
except FileNotFoundError as e:
    print(f"Erro Crítico: {e}")
    exit()

# Preparação das Variáveis
consumo_diario = (beneficiarios_total['Pessoas_Atendidas'] * 0.02).round(2)
capacidade_cisterna = beneficiarios_total['Capacidade'].astype(float)
num_dias = len(dias_uteis_df)

# Definir dias não úteis (baseado no índice da coluna, de 0 a num_dias-1)
# Assumindo que na coluna 1 do csv: 0 = Feriado/Fim de semana, 1 = Útil
coluna_flag = dias_uteis_df.columns[0]
dia_nao_util = set(dias_uteis_df[dias_uteis_df[coluna_flag] == 0].index)

# Inicialização dos DataFrames
# Usaremos índices numéricos (0 a N) para facilitar a correlação com dias_uteis
df_volume = pd.DataFrame(index=beneficiarios_total.index, columns=range(num_dias))
df_entregas = pd.DataFrame(0, index=beneficiarios_total.index, columns=range(num_dias))

# V2 limite: Volume Inicial = Capacidade Total
np.random.seed(42)
volume_inicial = beneficiarios_total['Capacidade']
df_volume.iloc[:, 0] = volume_inicial

start_time = time.time()

# --- Algoritmo (Lógica V2) ---
# Loop começa do dia 1 (o dia 0 é o estado inicial)
for i in range(1, len(df_volume.columns)):
    
    # Inicializa contador de caminhões para o dia atual
    entregas_hoje = np.zeros(len(beneficiarios_total))
    
    # Verifica se o índice do dia atual está na lista de dias não úteis
    if i in dia_nao_util:
        # Reduz consumo
        df_volume.iloc[:, i] = df_volume.iloc[:, i-1] - consumo_diario.values
        # Se volume < 0, volta para 0
        df_volume.iloc[:, i] = np.where(df_volume.iloc[:, i] < 0, 0, df_volume.iloc[:, i])
        
    else: # Dia Útil
        # Passo base: subtrai o consumo do dia anterior
        df_volume.iloc[:, i] = df_volume.iloc[:, i-1] - consumo_diario.values

        # --- Lógica de Abastecimento 1 ---
        # Calcula quantos caminhões cabem no espaço vazio atual
        numero_caminhoes = (capacidade_cisterna - df_volume.iloc[:, i]) // CAPACIDADE_CAMINHAO
        
        # Condição 1: Se volume < consumo, abastece com numero_caminhoes
        cond1 = df_volume.iloc[:, i].values < consumo_diario.values
        
        # Aplica volume
        df_volume.iloc[:, i] = np.where(cond1, 
                                        df_volume.iloc[:, i] + CAPACIDADE_CAMINHAO * numero_caminhoes, 
                                        df_volume.iloc[:, i].values)
        # Registra entregas
        entregas_hoje += np.where(cond1, numero_caminhoes, 0)

        # --- Lógica de Abastecimento 2 (Reforço) ---
        # Se volume ainda for menor ou igual ao consumo, manda +1 caminhão
        cond2 = df_volume.iloc[:, i].values <= consumo_diario.values
        
        df_volume.iloc[:, i] = np.where(cond2, 
                                        df_volume.iloc[:, i] + CAPACIDADE_CAMINHAO, 
                                        df_volume.iloc[:, i].values)
        entregas_hoje += np.where(cond2, 1, 0)

        # --- Lógica de Lookahead (Dias não úteis consecutivos) ---
        nao_uteis_consecutivos = 0
        while i + nao_uteis_consecutivos + 1 < len(df_volume.columns) and (i + nao_uteis_consecutivos + 1) in dia_nao_util:
             nao_uteis_consecutivos += 1

        if nao_uteis_consecutivos > 0:
            ajuste_volume = consumo_diario * nao_uteis_consecutivos
            # Checa se o volume atual aguenta os N dias não úteis seguintes
            cond3 = (df_volume.iloc[:, i] - ajuste_volume <= 0)
            
            df_volume.iloc[:, i] = np.where(cond3,
                                            df_volume.iloc[:, i] + CAPACIDADE_CAMINHAO,
                                            df_volume.iloc[:, i])
            entregas_hoje += np.where(cond3, 1, 0)

        # --- Correção Final de Capacidade ---
        # Se o volume estiver maior que a capacidade da cisterna, corrigir para o teto
        # (Isso não altera o número de caminhões enviados, apenas desperdiça a água excedente)
        df_volume.iloc[:, i] = np.where(df_volume.iloc[:, i].values > capacidade_cisterna, 
                                        capacidade_cisterna, 
                                        df_volume.iloc[:, i].values)
    
    # Salva contagem de caminhões no dataframe de entregas
    df_entregas.iloc[:, i] = entregas_hoje

print("Tempo para cálculo de volumes: {} segundos".format(round(time.time()-start_time, 2)))

# --- Exportação (Formato Julia) ---

# Ajuste de índices para exportação (1 a 90, e não 0 a 89)
df_volume.columns = range(1, num_dias + 1)
df_entregas.columns = range(1, num_dias + 1)

# Adiciona coluna de Beneficiarios
df_volume.insert(0, 'Beneficiarios', beneficiarios_total.index + 1)
df_entregas.insert(0, 'Beneficiarios', beneficiarios_total.index + 1)

try:
    df_volume.to_csv("volumes_diarios.csv", index=False)
    df_entregas.to_csv("abastecimento_diario.csv", index=False)
    print("\nArquivos gerados com sucesso: 'volumes_diarios.csv' e 'abastecimento_diario.csv'")
except Exception as e:
    print(f"Erro ao salvar CSVs: {e}")
