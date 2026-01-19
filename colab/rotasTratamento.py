
import pandas as pd
import numpy as np
import os

# --- Configurações de Arquivos ---
# Ajuste os nomes se necessário, mas mantive os padrões enviados
ARQUIVO_BENEFICIARIOS = "Beneficiarios_RN_Ativos_test.csv"
ARQUIVO_MANANCIAIS = "Mananciais_RN.csv"
ARQUIVO_SAIDA_ROTAS = "rotas" # O script salvará como rotas (sem extensão ou .csv)

# --- Funções Auxiliares ---

def limpar_coordenada(serie):
    """Converte strings de coordenadas (ex: "-6,166709") para float (-6.166709)."""
    # Remove aspas, troca vírgula por ponto e converte
    return serie.astype(str).str.replace('"', '', regex=False).str.replace(',', '.', regex=False).astype(float)

def haversine_vectorized(lat1, lon1, lat2, lon2):
    """Calcula distância em km entre coordenadas usando Haversine (vetorizado)."""
    R = 6371.0 # Raio da Terra em km
    
    phi1, phi2 = np.radians(lat1), np.radians(lat2)
    dphi = np.radians(lat2 - lat1)
    dlambda = np.radians(lon2 - lon1)
    
    a = np.sin(dphi/2)**2 + np.cos(phi1)*np.cos(phi2)*np.sin(dlambda/2)**2
    c = 2 * np.arctan2(np.sqrt(a), np.sqrt(1 - a))
    
    return R * c

print("--- Iniciando Geração de Rotas ---")

# 1. Carregar Arquivos
try:
    df_ben = pd.read_csv(ARQUIVO_BENEFICIARIOS)
    df_man = pd.read_csv(ARQUIVO_MANANCIAIS)
    print(f"Beneficiários carregados: {len(df_ben)}")
    print(f"Mananciais carregados: {len(df_man)}")
except FileNotFoundError as e:
    print(f"Erro Crítico: Arquivo não encontrado. {e}")
    exit()

# 2. Limpeza e Preparação das Coordenadas
try:
    # Beneficiários
    df_ben['lat_clean'] = limpar_coordenada(df_ben['Latitude (Formato Decimal)'])
    df_ben['lon_clean'] = limpar_coordenada(df_ben['Longitude (Formato Decimal)'])
    
    # Mananciais
    df_man['lat_clean'] = limpar_coordenada(df_man['Latitude (Formato Decimal)'])
    df_man['lon_clean'] = limpar_coordenada(df_man['Longitude (Formato Decimal)'])
    
except KeyError as e:
    print(f"Erro: Coluna de coordenada não encontrada. Verifique os nomes no CSV.\n{e}")
    exit()

# 3. Criação de Índices Sequenciais (0 a N)
# Isso é fundamental para os algoritmos de matriz funcionarem
df_ben['idx_beneficiario'] = range(len(df_ben))
df_man['idx_fonte'] = range(len(df_man))

# 4. Configuração dos Multiplicadores
# Regra: Não definido=0.79, Regular=0.71, Boa=0.68, Ruim=0.79, NaN=0.74
mapa_multiplicador = {
    'Não definido': 0.79,
    'Regular': 0.71,
    'Boa': 0.68,
    'Ruim': 0.79
}
# Valor default (para NaN ou não listados)
VALOR_PADRAO = 0.74

def obter_multiplicador(serie_situacao):
    return serie_situacao.map(mapa_multiplicador).fillna(VALOR_PADRAO)

df_ben['mult'] = obter_multiplicador(df_ben['Situação Estrada de Acesso'])
df_man['mult'] = obter_multiplicador(df_man['Situação Estrada de Acesso'])

# 5. Geração das Rotas (Produto Cartesiano: Todos x Todos)
print("Calculando distâncias para todas as combinações (pode levar alguns segundos)...")

# Criação de chaves temporárias para cross join
df_ben['_key'] = 1
df_man['_key'] = 1

# Merge (Produto Cartesiano)
# Resulta em Num_Ben * Num_Man linhas (ex: 3315 * 92 = ~305.000 linhas)
df_rotas = pd.merge(df_ben[['idx_beneficiario', 'lat_clean', 'lon_clean', 'mult', '_key']], 
                    df_man[['idx_fonte', 'lat_clean', 'lon_clean', 'mult', '_key']], 
                    on='_key', suffixes=('_ben', '_man'))

# Remove chave auxiliar
del df_rotas['_key']

# 6. Cálculo da Distância (Haversine)
df_rotas['distance'] = haversine_vectorized(
    df_rotas['lat_clean_ben'], df_rotas['lon_clean_ben'],
    df_rotas['lat_clean_man'], df_rotas['lon_clean_man']
)

# 7. Cálculo do Fator Multiplicador
# Regra: np.maximum(multiplicador_manancial, multiplicador_beneficiario)
df_rotas['fator_final'] = np.maximum(df_rotas['mult_man'], df_rotas['mult_ben'])

# Cálculo Final do Custo
# "Renumeração = Volume(não entra aqui) x Distância x Viagens(não entra aqui) x Índice"
# Para a matriz de custo de rota unitária, consideramos Distância x Índice
df_rotas['distance_w_factor'] = df_rotas['distance'] * df_rotas['fator_final']

# 8. Formatação e Exportação
# O algoritmo de alocação espera colunas nesta ordem: [Beneficiario, Fonte, Custo]
# Estamos usando os ÍNDICES SEQUENCIAIS (0..N) para garantir compatibilidade com matrizes.
cols_exportacao = ['idx_beneficiario', 'idx_fonte', 'distance_w_factor']

# Se quiser conferir os dados brutos depois, descomente a linha abaixo para salvar tudo
# df_rotas.to_csv("rotas_debug_completo.csv", index=False)

df_rotas[cols_exportacao].to_csv(ARQUIVO_SAIDA_ROTAS, index=False) # Salva como "rotas" (sem .csv se o script Julia ler assim, ou adicione .csv)
print(f"Arquivo '{ARQUIVO_SAIDA_ROTAS}' gerado com sucesso!")
print(f"Total de rotas calculadas: {len(df_rotas)}")
print("Amostra das primeiras linhas:")
print(df_rotas[cols_exportacao].head())

# Dica para verificação:
# O arquivo gerado usa índices 0 a N.
# O Beneficiário na linha 0 do seu CSV original é o índice 0 aqui.
