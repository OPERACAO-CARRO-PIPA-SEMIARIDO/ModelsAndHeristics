import pandas as pd
import numpy as np
import time
import os
import sys

# --- Configurações e Caminhos ---
BASE_PATH = "/home/guilherme/repos/backup/AlocacaoCarrosPipas/Dados/"
ARQUIVO_BENEFICIARIOS = os.path.join(BASE_PATH, "Beneficiarios_RN_Ativos1.csv")
ARQUIVO_DATAS = os.path.join(BASE_PATH, "datas.csv")

# Parâmetros
CAPACIDADE_CAMINHAO = 13.0 

# Permite limitar o número de beneficiários para testes rápidos
# Pode ser passado via linha de comando: python calendarioFull.py 100
LIMIT_BENEFICIARIES = int(sys.argv[1]) if len(sys.argv) > 1 else None

print("--- Iniciando Simulação (Algoritmo FULL - Shipping as much as possible) ---")
if LIMIT_BENEFICIARIES:
    print(f"MODO DE TESTE: Limitando a {LIMIT_BENEFICIARIES} beneficiários.")

# --- Leitura de Dados ---
try:
    beneficiarios_total = pd.read_csv(ARQUIVO_BENEFICIARIOS)
    
    if LIMIT_BENEFICIARIES:
        beneficiarios_total = beneficiarios_total.head(LIMIT_BENEFICIARIES)
        
    dias_uteis_df = pd.read_csv(ARQUIVO_DATAS)
except FileNotFoundError as e:
    print(f"Erro Crítico: {e}")
    exit()

# Preparação das Variáveis
consumo_diario_vals = (beneficiarios_total['Pessoas_Atendidas'] * 0.02).round(2).values
capacidade_cisterna_vals = beneficiarios_total['Capacidade'].astype(float).values
num_dias = 150

# Definir dias não úteis (baseado no índice da coluna, de 0 a num_dias-1)
# Assumindo que na coluna 1 do csv: 0 = Feriado/Fim de semana, 1 = Útil
coluna_flag = dias_uteis_df.columns[0]
dia_nao_util = set(dias_uteis_df[dias_uteis_df[coluna_flag] == 0].index)

# Inicialização dos DataFrames (preenchidos com 0.0 para garantir dtype float64)
df_volume = pd.DataFrame(0.0, index=beneficiarios_total.index, columns=range(num_dias))
df_entregas = pd.DataFrame(0, index=beneficiarios_total.index, columns=range(num_dias))

# Volume Inicial = Capacidade Total
df_volume.iloc[:, 0] = capacidade_cisterna_vals

start_time = time.time()

# --- Algoritmo (Lógica FULL) ---
# Loop começa do dia 1 (o dia 0 é o estado inicial)
for i in range(1, num_dias):
    
    # Inicializa contador de caminhões para o dia atual
    entregas_hoje = np.zeros(len(beneficiarios_total))
    
    # Volume atual inicia com o volume do dia anterior menos o consumo
    volume_atual = df_volume.iloc[:, i-1].values - consumo_diario_vals
    
    # Verifica se o índice do dia atual está na lista de dias não úteis
    if i in dia_nao_util:
        # Se volume < 0, volta para 0
        df_volume.iloc[:, i] = np.where(volume_atual < 0, 0.0, volume_atual)
        
    else: # Dia Útil
        # --- Lógica de Abastecimento 1 (FULL) ---
        # Calcula quantos caminhões cabem no espaço vazio atual
        espaco_livre = capacidade_cisterna_vals - volume_atual
        numero_caminhoes = espaco_livre // CAPACIDADE_CAMINHAO
        
        # Condição 1 (FULL Strategy): Se couber pelo menos um caminhão, abastece
        cond1 = numero_caminhoes > 0
        
        # Aplica volume
        volume_atual = np.where(cond1, 
                                volume_atual + CAPACIDADE_CAMINHAO * numero_caminhoes, 
                                volume_atual)
        # Registra entregas
        entregas_hoje += np.where(cond1, numero_caminhoes, 0.0)

        # --- Lógica de Abastecimento 2 (Reforço) ---
        # Se volume ainda for menor ou igual ao consumo, manda +1 caminhão (garantindo o máximo possível)
        cond2 = volume_atual <= consumo_diario_vals
        
        volume_atual = np.where(cond2, 
                                volume_atual + CAPACIDADE_CAMINHAO, 
                                volume_atual)
        entregas_hoje += np.where(cond2, 1.0, 0.0)

        # --- Lógica de Lookahead (Dias não úteis consecutivos) ---
        nao_uteis_consecutivos = 0
        while i + nao_uteis_consecutivos + 1 < num_dias and (i + nao_uteis_consecutivos + 1) in dia_nao_util:
             nao_uteis_consecutivos += 1

        if nao_uteis_consecutivos > 0:
            ajuste_volume = consumo_diario_vals * nao_uteis_consecutivos
            # Checa se o volume atual aguenta os N dias não úteis seguintes
            cond3 = (volume_atual - ajuste_volume <= 0)
            
            volume_atual = np.where(cond3,
                                    volume_atual + CAPACIDADE_CAMINHAO,
                                    volume_atual)
            entregas_hoje += np.where(cond3, 1.0, 0.0)

        # --- Correção Final de Capacidade ---
        # Se o volume estiver maior que a capacidade da cisterna, corrigir para o teto
        volume_final = np.where(volume_atual > capacidade_cisterna_vals, 
                                capacidade_cisterna_vals, 
                                volume_atual)
        
        # Garantir que não seja negativo
        volume_final = np.where(volume_final < 0, 0.0, volume_final)
        
        df_volume.iloc[:, i] = volume_final
    
    # Salva contagem de caminhões no dataframe de entregas
    df_entregas.iloc[:, i] = entregas_hoje

print("Tempo para cálculo de volumes: {} segundos".format(round(time.time()-start_time, 2)))

# --- Exportação (Formato Julia) ---

# Ajuste de índices para exportação (1 a 150)
df_volume.columns = range(1, num_dias + 1)
df_entregas.columns = range(1, num_dias + 1)

# Adiciona coluna de Beneficiarios
df_volume.insert(0, 'Beneficiarios', beneficiarios_total.index + 1)
df_entregas.insert(0, 'Beneficiarios', beneficiarios_total.index + 1)

try:
    df_volume.to_csv("volumes_diarios_py.csv", index=False)
    df_entregas.to_csv("abastecimento_diario_py.csv", index=False)
    print("\nArquivos gerados com sucesso: 'volumes_diarios_py.csv' e 'abastecimento_diario_py.csv'")
except Exception as e:
    print(f"Erro ao salvar CSVs: {e}")
