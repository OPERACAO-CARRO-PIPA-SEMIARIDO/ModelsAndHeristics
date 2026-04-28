import pandas as pd
import numpy as np
import os

# --- Configurações de Caminhos ---
BASE_PATH_DATA = "/home/guilherme/repos/backup/AlocacaoCarrosPipas/Dados"
ARQUIVO_BENEFICIARIOS = os.path.join(BASE_PATH_DATA, "Beneficiarios_RN_Ativos1.csv")
ARQUIVO_DATAS = os.path.join(BASE_PATH_DATA, "datas.csv")
ARQUIVO_CALENDARIOS = os.path.join(BASE_PATH_DATA, "CalendariosObrigatorios.csv")

CAPACIDADE_CAMINHAO = 13.0
NUM_DIAS = 365

def rodar_heuristica(n_ben, modo="full"):
    # 1. Carregamento
    beneficiarios = pd.read_csv(ARQUIVO_BENEFICIARIOS).head(n_ben)
    dias_uteis = pd.read_csv(ARQUIVO_DATAS).head(NUM_DIAS)
    calendarios = pd.read_csv(ARQUIVO_CALENDARIOS).head(NUM_DIAS)
    
    # 2. Parâmetros
    consumo_diario = (beneficiarios['Pessoas_Atendidas'] * 0.02).round(2).values
    capacidade_cisterna = beneficiarios['Capacidade'].values.astype(float)
    
    Y = capacidade_cisterna / consumo_diario
    quebra4 = Y < 5
    quebra2 = Y < 3
    
    is_dia_util = dias_uteis.iloc[:, 0].values == 1
    carnaval_obrigatorio = calendarios['carnaval'].values == 1
    lil_obrigatorio = calendarios['lil'].values == 1
    
    # 3. Inicialização
    df_entregas = np.zeros((n_ben, NUM_DIAS), dtype=int)
    volume_atual = capacidade_cisterna.copy() # Começa cheio
    
    for k in range(NUM_DIAS):
        # Consumo do dia
        volume_atual -= consumo_diario
        
        entregas_hoje = np.zeros(n_ben, dtype=int)
        
        if is_dia_util[k]:
            # A) Regras Obrigatórias (Carnaval/Lil)
            cond_obrigatoria = (carnaval_obrigatorio[k] & quebra4) | (lil_obrigatorio[k] & quebra2)
            entregas_hoje = np.where(cond_obrigatoria, 1, 0)
            
            # B) Lógica da Estratégia
            if modo == "full":
                # Encher o máximo de caminhões INTEIROS que couberem
                espaco_livre = capacidade_cisterna - (volume_atual + entregas_hoje * CAPACIDADE_CAMINHAO)
                caminhoes_extras = np.maximum(0, espaco_livre // CAPACIDADE_CAMINHAO)
                entregas_hoje += caminhoes_extras.astype(int)
            else:
                # Estratégia Limite (só se precisar)
                pass # A trava de segurança abaixo já cobre o "precisa"
            
            # C) Trava de Segurança (VIABILIDADE)
            # Verifica quantos dias ficaremos sem poder abastecer (feriados/fds)
            nao_uteis_consecutivos = 0
            idx_check = k + 1
            while idx_check < NUM_DIAS and not is_dia_util[idx_check]:
                nao_uteis_consecutivos += 1
                idx_check += 1
            
            consumo_ate_proximo_util = consumo_diario * (1 + nao_uteis_consecutivos)
            
            # Se mesmo após a lógica acima o volume não durar até o próximo dia útil, 
            # FORÇA a entrega de +1 caminhão (mesmo que transborde)
            volume_projetado = volume_atual + (entregas_hoje * CAPACIDADE_CAMINHAO)
            precisa_emergencia = volume_projetado < consumo_ate_proximo_util
            entregas_hoje = np.where(precisa_emergencia, entregas_hoje + 1, entregas_hoje)

        # Atualiza volume e aplica o teto (Capping)
        volume_atual += entregas_hoje * CAPACIDADE_CAMINHAO
        volume_atual = np.minimum(volume_atual, capacidade_cisterna)
        
        # Garante que não é negativo (se for, é falha real de abastecimento por falta de dia útil)
        # No modelo matemático isso geraria INFEASIBLE. Aqui apenas zeramos para métrica.
        volume_atual = np.maximum(volume_atual, 0)
        
        df_entregas[:, k] = entregas_hoje

    return np.sum(df_entregas)

if __name__ == "__main__":
    n = 1250
    print(f"--- Processando {n} beneficiários (VIABILIDADE CORRIGIDA) ---")
    total_full = rodar_heuristica(n, "full")
    total_limite = rodar_heuristica(n, "limite")
    
    print(f"Total Entregas (FULL):   {total_full}")
    print(f"Total Entregas (LIMITE): {total_limite}")
