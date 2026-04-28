import pandas as pd
import numpy as np
import os

# --- Configurações de Caminhos ---
BASE_PATH_DATA = "/home/guilherme/repos/backup/AlocacaoCarrosPipas/Dados"
ARQUIVO_BENEFICIARIOS = os.path.join(BASE_PATH_DATA, "Beneficiarios_RN_Ativos1.csv")
ARQUIVO_DATAS = os.path.join(BASE_PATH_DATA, "datas.csv")
ARQUIVO_CALENDARIOS = os.path.join(BASE_PATH_DATA, "CalendariosObrigatorios.csv")

OUTPUT_DIR = "/home/guilherme/ModelsAndHeristics/alocacao/entradas_1250"

CAPACIDADE_CAMINHAO = 13.0
NUM_DIAS = 365
NUM_BENEFICIARIOS = 1250

def gerar_e_salvar_heuristica(modo="full"):
    # 1. Carregamento
    beneficiarios = pd.read_csv(ARQUIVO_BENEFICIARIOS).head(NUM_BENEFICIARIOS)
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
    df_entregas_matriz = np.zeros((NUM_BENEFICIARIOS, NUM_DIAS), dtype=int)
    volume_atual = capacidade_cisterna.copy()
    
    for k in range(NUM_DIAS):
        volume_atual -= consumo_diario
        entregas_hoje = np.zeros(NUM_BENEFICIARIOS, dtype=int)
        
        if is_dia_util[k]:
            cond_obrigatoria = (carnaval_obrigatorio[k] & quebra4) | (lil_obrigatorio[k] & quebra2)
            entregas_hoje = np.where(cond_obrigatoria, 1, 0)
            
            if modo == "full":
                espaco_livre = capacidade_cisterna - (volume_atual + entregas_hoje * CAPACIDADE_CAMINHAO)
                caminhoes_extras = np.maximum(0, espaco_livre // CAPACIDADE_CAMINHAO)
                entregas_hoje += caminhoes_extras.astype(int)
            
            # Trava de Segurança
            nao_uteis_consecutivos = 0
            idx_check = k + 1
            while idx_check < NUM_DIAS and not is_dia_util[idx_check]:
                nao_uteis_consecutivos += 1
                idx_check += 1
            
            consumo_ate_proximo_util = consumo_diario * (1 + nao_uteis_consecutivos)
            volume_projetado = volume_atual + (entregas_hoje * CAPACIDADE_CAMINHAO)
            precisa_emergencia = volume_projetado < consumo_ate_proximo_util
            entregas_hoje = np.where(precisa_emergencia, entregas_hoje + 1, entregas_hoje)

        volume_atual += entregas_hoje * CAPACIDADE_CAMINHAO
        volume_atual = np.clip(volume_atual, 0, capacidade_cisterna)
        df_entregas_matriz[:, k] = entregas_hoje

    # 4. Exportação Formatada para o Tester
    df_final = pd.DataFrame(df_entregas_matriz, columns=range(1, NUM_DIAS + 1))
    df_final.insert(0, 'Beneficiarios', beneficiarios.index + 1)
    
    nome_arquivo = f"abastecimento_{modo}_1250.csv"
    caminho_completo = os.path.join(OUTPUT_DIR, nome_arquivo)
    df_final.to_csv(caminho_completo, index=False)
    print(f"Arquivo gerado: {nome_arquivo} (Total Entregas: {np.sum(df_entregas_matriz)})")

if __name__ == "__main__":
    if not os.path.exists(OUTPUT_DIR):
        os.makedirs(OUTPUT_DIR)
    
    print("Atualizando matrizes de abastecimento das heurísticas...")
    gerar_e_salvar_heuristica("full")
    gerar_e_salvar_heuristica("limite")
    print("Sucesso!")
