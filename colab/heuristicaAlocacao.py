
import pandas as pd
import numpy as np
import time
import os

# --- Configurações ---
BASE_PATH = "/home/guilherme/repos/backup/AlocacaoCarrosPipas/Dados/"
PATH_ABASTECIMENTO = "abastecimento_diario.csv" # Gerado pelo seu script de volumes anterior
PATH_ROTAS = os.path.join(BASE_PATH, "rotas")   # Arquivo de distâncias
PATH_BENEFICIARIOS = os.path.join(BASE_PATH, "Beneficiarios_RN_Ativos_test.csv")

CAPACIDADE_MANANCIAL_DIA = 12.0 # Limite de viagens por dia por manancial

print("--- Iniciando Algoritmo de Alocação Gulosa ---")

# --- 1. Carregamento e Preparação das Matrizes ---

# Carregar Abastecimento (Matriz de Demanda: Beneficiários x Dias)
try:
    df_abastecimento = pd.read_csv(PATH_ABASTECIMENTO)
    # Assume que a col 0 é ID/Nome e o resto são os dias
    # Matriz shape: (Num_Beneficiarios, Num_Dias)
    matriz_demanda = df_abastecimento.iloc[:, 1:].values.astype(float)
    ids_beneficiarios = df_abastecimento.iloc[:, 0].values
    num_beneficiarios, num_dias = matriz_demanda.shape
except FileNotFoundError:
    print(f"Erro: {PATH_ABASTECIMENTO} não encontrado.")
    exit()

# Carregar Rotas (Matriz de Custo: Mananciais x Beneficiários)
try:
    df_rotas = pd.read_csv(PATH_ROTAS)
    # Se não tiver cabeçalho no arquivo 'rotas', definir manualmente:
    # df_rotas.columns = ['id_beneficiario', 'id_fonte', 'distance']
    
    # Precisamos saber quantos mananciais existem. 
    # Assumindo IDs de 0 a 91 (ou 1 a 92). Vamos pegar o max.
    num_mananciais = 92 # Fixo conforme seu contexto anterior
    
    # Criar Matriz de Custos (Distância)
    # Inicializa com infinito para penalizar rotas inexistentes
    matriz_custo = np.full((num_mananciais, num_beneficiarios), np.inf)
    
    # Preencher a matriz
    # Ajuste os índices se o seu CSV começar em 1 (subtraia 1). Se começar em 0, mantenha.
    # O Julia usava +1, então aqui assumimos que no CSV é 0-based.
    idx_ben = df_rotas.iloc[:, 0].values.astype(int) 
    idx_font = df_rotas.iloc[:, 1].values.astype(int)
    distancias = df_rotas.iloc[:, 2].values
    
    matriz_custo[idx_font, idx_ben] = distancias

except Exception as e:
    print(f"Erro ao processar rotas: {e}")
    exit()

# --- 2. Algoritmo de Alocação (Seu snippet adaptado) ---

start_time = time.time()

# Estruturas de Controle
# y: Capacidade USADA de cada manancial em cada dia [Mananciais x Dias]
y = np.zeros((num_mananciais, num_dias))

# x: Qual manancial atende qual beneficiário [Beneficiario] -> ID Manancial
# (Assumindo que um beneficiário é atendido pelo mesmo manancial fixo, conforme lógica do .all())
alocacao_final = np.full(num_beneficiarios, -1) # -1 indica não alocado

# Definir Ordem dos Beneficiários (Decrescente por volume total)
volume_total_por_beneficiario = np.sum(matriz_demanda, axis=1)
# argsort retorna crescente, usamos [::-1] para inverter
ordem_beneficiarios = np.argsort(volume_total_por_beneficiario)[::-1]

# Limite diário expandido para matriz [Mananciais x Dias]
limite_de_abastecimentos_por_dia = CAPACIDADE_MANANCIAL_DIA

print("Alocando mananciais...")

for j in ordem_beneficiarios:
    qtd_abastecimentos_diario = matriz_demanda[j, :] # Vetor [Dias]
    
    # Se o beneficiário não precisa de água em nenhum dia, pular
    if np.sum(qtd_abastecimentos_diario) == 0:
        continue
        
    # Obter lista de mananciais ordenados pela distância (do mais perto para o mais longe)
    # Isso substitui o 'argmin' simples e permite o 'else' iterativo
    fontes_ordenadas = np.argsort(matriz_custo[:, j])
    
    alocado = False
    
    for i in fontes_ordenadas:
        # Se a distância for infinita (rota inexistente), pare de tentar
        if matriz_custo[i, j] == np.inf:
            break
            
        # Verificação de Capacidade (Seu snippet)
        # Verifica se adicionar a demanda deste beneficiário estoura o limite em ALGUM dia
        # O (y + demanda <= limite).all() garante que só aceitamos se couber em TODOS os dias
        if np.all((y[i, :] + qtd_abastecimentos_diario) <= limite_de_abastecimentos_por_dia):
            
            # Aloca
            alocacao_final[j] = i
            # Atualiza uso do manancial
            y[i, :] += qtd_abastecimentos_diario
            alocado = True
            break # Sai do loop das fontes, vai para próximo beneficiário
    
    if not alocado:
        # Caso nenhum manancial aguente a demanda completa (Edge Case)
        # Aqui você pode decidir: Deixar sem água (-1) ou forçar no mais próximo estourando limite?
        # Vou manter como não alocado (-1) para indicar falha, ou você pode logar um aviso.
        # print(f"Aviso: Beneficiário {j} não pôde ser alocado sem estourar limites.")
        pass

print("Tempo para cálculo da alocação: {} segundos".format(round(time.time()-start_time, 2)))

# --- 3. Geração das Saídas ---

# Saída 1: Calendário de Fontes
# "Ao invés de mostrar a quantidade de entregas, mostra de qual manancial vai receber"
# Estrutura igual ao input, mas com ID do manancial nas células onde há entrega.

df_output_fontes = df_abastecimento.copy()

# Iterar para preencher (pode ser otimizado, mas loop é seguro para manter formato)
for j in range(num_beneficiarios):
    fonte_id = alocacao_final[j]
    # Se foi alocado (ID >= 0)
    if fonte_id != -1:
        # Onde a demanda > 0, coloque o ID da fonte. Onde é 0, mantenha 0 ou vazio.
        mask = matriz_demanda[j, :] > 0
        #df_output_fontes.iloc[j, 1:] é a linha dos dias.
        # Usamos np.where para colocar o ID onde tem demanda, e 0 onde não tem
        # Nota: IDs de mananciais +1 para bater com padrão Julia (1 a 92) se desejar
        df_output_fontes.iloc[j, 1:] = np.where(mask, fonte_id + 1, 0)
    else:
        df_output_fontes.iloc[j, 1:] = -1 # Indicativo de falha na alocação

df_output_fontes.to_csv("calendario_fontes_alocadas.csv", index=False)
print("Gerado: calendario_fontes_alocadas.csv")

# Saída 2: Custo por Dia (Igual ao M1 MinimizaPicos)
# Colunas: Tempo (fixo ou cumulativo), Custo Total, Num Variaveis (N/A aqui, mas mantemos coluna)

custos_diarios = []
tempos_dummy = [] # O algoritmo não roda dia a dia, então o tempo é diluído ou repetido
num_vars_dummy = []

tempo_total = time.time() - start_time

for d in range(num_dias):
    custo_dia = 0
    # Custo = Soma(Distancia_Fonte_Beneficiario * Qtd_Entregas) para todos beneficiarios
    
    # Vetorizado:
    # Pegar indices dos beneficiarios ativos neste dia
    demandas_dia = matriz_demanda[:, d]
    ids_fontes_dia = alocacao_final # Vetor com ID da fonte de cada beneficiario
    
    # Filtra apenas quem tem demanda e foi alocado
    mask = (demandas_dia > 0) & (ids_fontes_dia != -1)
    
    if np.any(mask):
        bens_ativos = np.where(mask)[0]
        fontes_ativas = ids_fontes_dia[bens_ativos]
        qts_ativas = demandas_dia[bens_ativos]
        
        # Custo = Distancia[Fonte, Ben] * Qtd
        # Usamos indexação avançada na matriz de custo
        distancias = matriz_custo[fontes_ativas, bens_ativos]
        custo_dia = np.sum(distancias * qts_ativas)

    custos_diarios.append(custo_dia)
    tempos_dummy.append(tempo_total) # Colocando o tempo total ou 0
    num_vars_dummy.append(num_beneficiarios) # Valor dummy

df_custo = pd.DataFrame({
    "Tempo_de_Execucao": tempos_dummy,
    "Custo_Total_Dia": custos_diarios, # Nome adaptado para clareza, ou use "Solucao_otima" para igualar Julia
    "Num_Variaveis": num_vars_dummy
})

# Renomeando para ficar idêntico ao modelo M1 se preferir:
df_custo.rename(columns={"Custo_Total_Dia": "Solucao_otima"}, inplace=True)

df_custo.to_csv("custo_diario_algoritmo.csv", index=False)
print("Gerado: custo_diario_algoritmo.csv")
