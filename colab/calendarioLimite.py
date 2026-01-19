import pandas as pd
import numpy as np
import time
import os

# --- Configurações Iniciais ---
# Defina a capacidade do caminhão (baseado no seu código Julia: 13.0)
CAPACIDADE_CAMINHAO = 13.0 
# Caminhos dos arquivos (Baseado no seu snippet Julia)
BASE_PATH = "/home/guilherme/repos/backup/AlocacaoCarrosPipas/Dados/"
ARQUIVO_BENEFICIARIOS = os.path.join(BASE_PATH, "Beneficiarios_RN_Ativos_test.csv")
ARQUIVO_DATAS = os.path.join(BASE_PATH, "datas.csv")
# O arquivo de calendários não parecia ser usado explicitamente na lógica do loop Python fornecido, 
# mas se precisar das exceções de carnaval, deve ser carregado aqui.

print("--- Iniciando Processamento Local ---")

# --- Leitura e Preparação dos Dados ---
try:
    beneficiarios_total = pd.read_csv(ARQUIVO_BENEFICIARIOS)
    dias_uteis_df = pd.read_csv(ARQUIVO_DATAS) # Assume coluna 1 com 0 ou 1
except FileNotFoundError as e:
    print(f"Erro: Arquivo não encontrado. Verifique os caminhos.\n{e}")
    exit()

# Preparar parâmetros
consumo_diario = (beneficiarios_total['Pessoas_Atendidas'] * 0.02).round(2).values
capacidade_cisterna = beneficiarios_total['Capacidade'].values.astype(float)
ids_beneficiarios = beneficiarios_total.index # Ou use uma coluna de ID se houver

# Configurar Horizonte de Planejamento
# O Julia usa nd = 1:90. Vamos assumir o tamanho do arquivo datas.csv
num_dias = len(dias_uteis_df)
dias_range = range(num_dias)

# Identificar dias não úteis (Assumindo que 0 = Não útil no arquivo datas.csv)
coluna_flag_dia = dias_uteis_df.columns[0] 
indices_dias_nao_uteis = dias_uteis_df[dias_uteis_df[coluna_flag_dia] == 0].index.tolist()

# --- Inicialização dos DataFrames de Resultados ---
# df_volume: armazena o estado da cisterna
# df_entregas: armazena quantos caminhões foram enviados (output 'x' do Julia)
colunas_dias = [f"Dia_{i+1}" for i in dias_range] # Nomes das colunas para exportação

df_volume = pd.DataFrame(0.0, index=beneficiarios_total.index, columns=dias_range)
df_entregas = pd.DataFrame(0, index=beneficiarios_total.index, columns=dias_range)

# Volume Inicial (Cópia da capacidade total)
volume_inicial = capacidade_cisterna.copy()
df_volume.iloc[:, 0] = volume_inicial

print(f"Calculando para {len(beneficiarios_total)} beneficiários por {num_dias} dias...")
start_time = time.time()

# --- Loop de Simulação (Lógica do Colab Adaptada) ---
for i in range(1, num_dias):
    # Volume inicial do dia é o final do dia anterior
    volume_atual = df_volume.iloc[:, i-1].values
    
    # Reduz consumo
    volume_pos_consumo = volume_atual - consumo_diario
    
    entregas_no_dia = np.zeros(len(beneficiarios_total))
    
    if i in indices_dias_nao_uteis:
        # Dia NÃO útil: Apenas consome
        # Se volume < 0, zera (falta d'água)
        volume_final = np.where(volume_pos_consumo < 0, 0, volume_pos_consumo)
        
    else:
        # Dia ÚTIL: Pode abastecer
        
        # Lógica de Abastecimento (Replicada do seu snippet):
        # Calcula quantos caminhões cabem
        espaco_livre = capacidade_cisterna - volume_pos_consumo
        numero_caminhoes = espaco_livre // CAPACIDADE_CAMINHAO
        
        # Aplica a lógica condicional do seu snippet:
        # Se volume < consumo, abastece com o calculado
        # Nota: O snippet original tinha várias condições sobrepostas, simplifiquei para a lógica principal
        
        # 1. Verifica onde precisa abastecer (Critério básico: se vai faltar água ou está muito baixo)
        precisa_abastecer = volume_pos_consumo < consumo_diario # Exemplo de critério crítico
        
        # Se for crítico, manda caminhão. 
        # (Aqui estou assumindo a lógica do 'numero_caminhoes' calculada acima)
        qtd_entregar = np.where(precisa_abastecer, numero_caminhoes, 0)
        
        # Correção para garantir que pelo menos 1 caminhão vá se estiver vazio
        qtd_entregar = np.where((volume_pos_consumo <= 0) & (qtd_entregar == 0), 1, qtd_entregar)
        
        volume_abastecido = qtd_entregar * CAPACIDADE_CAMINHAO
        volume_final = volume_pos_consumo + volume_abastecido
        
        # Lógica de Previsão de Dias Não Úteis (snippet "nao_uteis_consecutivos")
        nao_uteis_consecutivos = 0
        idx_check = i + 1
        while idx_check < num_dias and idx_check in indices_dias_nao_uteis:
            nao_uteis_consecutivos += 1
            idx_check += 1
            
        if nao_uteis_consecutivos > 0:
            ajuste_necessario = consumo_diario * nao_uteis_consecutivos
            # Se não aguentar o feriado, manda mais um caminhão
            condicao_feriado = (volume_final - ajuste_necessario) <= 0
            volume_final = np.where(condicao_feriado, volume_final + CAPACIDADE_CAMINHAO, volume_final)
            qtd_entregar = np.where(condicao_feriado, qtd_entregar + 1, qtd_entregar)

        # Salva as entregas deste dia
        entregas_no_dia = qtd_entregar

    # --- Restrições Finais de Limites ---
    # Não pode exceder a capacidade da cisterna
    volume_final = np.where(volume_final > capacidade_cisterna, capacidade_cisterna, volume_final)
    # Não pode ser negativo
    volume_final = np.where(volume_final < 0, 0, volume_final)
    
    # Atualiza os DataFrames
    df_volume.iloc[:, i] = volume_final
    df_entregas.iloc[:, i] = entregas_no_dia

print("Tempo de cálculo: {} segundos".format(round(time.time()-start_time, 2)))

# --- Exportação (Formato idêntico ao Julia) ---

# Ajustar índices e colunas para o padrão do Julia
# O Julia exporta: Coluna 'Beneficiarios' e depois os dias (1, 2, 3...)
df_volume.columns = range(1, num_dias + 1)
df_entregas.columns = range(1, num_dias + 1)

# Adicionando a coluna de identificação dos beneficiários (Assumindo índice 1..N ou ID original)
# Se quiser o índice original do arquivo CSV:
df_volume.insert(0, 'Beneficiarios', beneficiarios_total.index + 1) # +1 para bater com o 1:300 do Julia se for indexado em 1
df_entregas.insert(0, 'Beneficiarios', beneficiarios_total.index + 1)

# Salvando
try:
    df_volume.to_csv("volumes_diarios_py.csv", index=False)
    df_entregas.to_csv("abastecimento_diario_py.csv", index=False)
    print("\nCSVs de abastecimento e volume gerados com sucesso (sufixo _py).")
except Exception as e:
    print(f"Erro ao salvar arquivos: {e}")
