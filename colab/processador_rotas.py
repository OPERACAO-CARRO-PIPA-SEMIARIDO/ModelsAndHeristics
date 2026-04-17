import pandas as pd
import numpy as np
import requests
import os
import time

# --- Configurações de Caminhos ---
# Ajustado para os caminhos reais encontrados no sistema
BASE_PATH = "/home/guilherme/repos/backup/AlocacaoCarrosPipas/Dados"
ARQUIVO_BENEFICIARIOS = os.path.join(BASE_PATH, "Beneficiarios_RN_Ativos1.csv")
ARQUIVO_MANANCIAIS = os.path.join(BASE_PATH, "Mananciais_RN.csv")
# O arquivo de saída costuma não ter extensão nos modelos Julia
ARQUIVO_SAIDA_ROTAS = "rotas_novo.csv" 

# Servidor OSRM
# Nota: O servidor público tem limites. Para 300k rotas, o ideal é um servidor local.
# Se for usar local, mude para: "http://localhost:5000/table/v1/driving/"
OSRM_URL = "https://router.project-osrm.org/table/v1/driving/"

# --- Multiplicadores de Estrada ---
# Conforme a lógica do projeto: Distância * max(mult_manancial, mult_beneficiario)
MAPA_MULTIPLICADOR = {
    'Não definido': 0.79,
    'Regular': 0.71,
    'Boa': 0.68,
    'Ruim': 0.79,
    'Péssima': 0.85
}
VALOR_PADRAO_MULT = 0.74

def limpar_coordenada(valor):
    """Trata coordenadas que podem vir com vírgula ou em formatos variados."""
    if pd.isna(valor):
        return None
    if isinstance(valor, str):
        valor = valor.replace('"', '').replace(',', '.').strip()
    try:
        return float(valor)
    except ValueError:
        return None

def obter_matriz_distancias(coords_fontes, coords_beneficiarios, url_base):
    """Consulta o OSRM Table API para obter distâncias reais em metros."""
    # OSRM Table espera: lon,lat;lon,lat...
    all_coords = coords_fontes + coords_beneficiarios
    coords_str = ";".join(all_coords)
    
    # Índices dos mananciais como fontes e beneficiários como destinos
    sources = ";".join([str(i) for i in range(len(coords_fontes))])
    destinations = ";".join([str(i + len(coords_fontes)) for i in range(len(coords_beneficiarios))])
    
    url = f"{url_base}{coords_str}?sources={sources}&destinations={destinations}&annotations=distance"
    
    max_retries = 3
    for attempt in range(max_retries):
        try:
            response = requests.get(url, timeout=60)
            if response.status_code == 200:
                data = response.json()
                if data.get("code") == "Ok":
                    # Retorna matriz em Km
                    return np.array(data["distances"]) / 1000.0
            elif response.status_code == 429:
                print(f"  Aviso: Limite de requisições atingido. Aguardando 15s (Tentativa {attempt+1})")
                time.sleep(15)
            else:
                print(f"  Erro API ({response.status_code}): {response.text}")
        except Exception as e:
            print(f"  Erro de conexão: {e}")
            time.sleep(5)
    return None

def processar():
    print("--- Iniciando Processamento de Rotas ---")
    
    # 1. Carregamento dos Dados
    try:
        df_ben = pd.read_csv(ARQUIVO_BENEFICIARIOS)
        df_man = pd.read_csv(ARQUIVO_MANANCIAIS)
    except Exception as e:
        print(f"Erro ao carregar arquivos: {e}")
        return

    # 2. Limpeza e Preparação
    df_ben['lat_clean'] = df_ben['Latitude (Formato Decimal)'].apply(limpar_coordenada)
    df_ben['lon_clean'] = df_ben['Longitude (Formato Decimal)'].apply(limpar_coordenada)
    df_man['lat_clean'] = df_man['Latitude (Formato Decimal)'].apply(limpar_coordenada)
    df_man['lon_clean'] = df_man['Longitude (Formato Decimal)'].apply(limpar_coordenada)

    # Multiplicadores
    df_ben['mult'] = df_ben['Situação Estrada de Acesso'].map(MAPA_MULTIPLICADOR).fillna(VALOR_PADRAO_MULT)
    df_man['mult'] = df_man['Situação Estrada de Acesso'].map(MAPA_MULTIPLICADOR).fillna(VALOR_PADRAO_MULT)

    # Strings de Coordenadas para o OSRM (longitude,latitude)
    coords_man = [f"{lon},{lat}" for lon, lat in zip(df_man['lon_clean'], df_man['lat_clean'])]
    coords_ben = [f"{lon},{lat}" for lon, lat in zip(df_ben['lon_clean'], df_ben['lat_clean'])]

    num_ben = len(df_ben)
    num_man = len(df_man)
    print(f"Beneficiários: {num_ben}, Mananciais: {num_man}")
    print(f"Total de rotas a calcular: {num_ben * num_man}")

    resultados = []
    
    # 3. Processamento em Chunks
    # Vamos armazenar as distâncias em uma matriz [num_man][num_ben]
    matriz_distancias_total = np.zeros((num_man, num_ben))
    
    # Chunks de beneficiários para otimizar chamadas à API
    chunk_size = 60 
    
    for i in range(0, num_ben, chunk_size):
        end_idx = min(i + chunk_size, num_ben)
        batch_ben = coords_ben[i:end_idx]
        
        print(f"Buscando distâncias para beneficiários {i} até {end_idx}...")
        
        matriz_batch = obter_matriz_distancias(coords_man, batch_ben, OSRM_URL)
        
        if matriz_batch is None:
            print(f"ERRO: Falha ao obter distâncias para o bloco {i}-{end_idx}.")
            continue
            
        # matriz_batch tem formato [num_man][len(batch_ben)]
        matriz_distancias_total[:, i:end_idx] = matriz_batch
        
        if "router.project-osrm.org" in OSRM_URL:
            time.sleep(1.2)

    # 4. Geração dos Resultados com a Ordem Correta (Fonte -> Beneficiário)
    print("Organizando resultados e calculando custos...")
    for m_idx in range(num_man):
        m_man = df_man.iloc[m_idx]['mult']
        for b_idx in range(num_ben):
            m_ben = df_ben.iloc[b_idx]['mult']
            dist_km = matriz_distancias_total[m_idx, b_idx]
            
            fator = max(m_ben, m_man)
            dist_com_fator = dist_km * fator
            
            resultados.append({
                'id_beneficiario': b_idx,
                'id_fonte': m_idx,
                'distance': round(dist_km, 6),
                'multiplicador_manancial': m_man,
                'multiplicador_beneficiario': m_ben,
                'distance_w_factor': round(dist_com_fator, 8)
            })

    # 5. Salvamento
    if resultados:
        df_final = pd.DataFrame(resultados)
        # O Julia costuma esperar o CSV com índice na primeira coluna sem nome
        df_final.to_csv(ARQUIVO_SAIDA_ROTAS, index=True)
        print(f"\nSucesso! Arquivo '{ARQUIVO_SAIDA_ROTAS}' gerado com {len(df_final)} rotas.")
    else:
        print("\nNenhum resultado gerado.")

if __name__ == "__main__":
    processar()
