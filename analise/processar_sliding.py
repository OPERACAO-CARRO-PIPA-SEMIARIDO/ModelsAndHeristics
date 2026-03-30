import pandas as pd
import numpy as np
import argparse
import sys
from pathlib import Path

def carregar_dataframe(caminho):
    try:
        df = pd.read_csv(caminho)
        if 'Beneficiarios' in df.columns:
            df = df.set_index('Beneficiarios')
        elif 'Beneficiario' in df.columns:
             df = df.set_index('Beneficiario')
        return df
    except Exception as e:
        print(f"Erro ao carregar {caminho}: {e}")
        return None

def salvar_dataframe(df, caminho):
    df = df.reset_index()
    if 'index' in df.columns:
        df = df.rename(columns={'index': 'Beneficiarios'})
    df.to_csv(caminho, index=False)
    print(f"Arquivo salvo com sucesso: {caminho}")

def calcular_custo_total(df_aloc, df_abast, rotas_path):
    try:
        df_rotas = pd.read_csv(rotas_path)
        NM = 92
        NB = 3315
        Dij = np.array(df_rotas['distance_w_factor']).reshape((NM, NB), order='F')
        
        custo_total = 0.0
        for col in df_aloc.columns:
            # Garantir que estamos pegando colunas numéricas (dias)
            if not col.isdigit(): continue
            
            aloc_dia = df_aloc[col].values
            abast_dia = df_abast[col].values
            
            for j_idx in range(NB):
                fonte_id = aloc_dia[j_idx]
                entregas = abast_dia[j_idx]
                
                if fonte_id > 0 and entregas > 0:
                    i_idx = int(fonte_id - 1)
                    custo_total += Dij[i_idx, j_idx] * entregas
        return custo_total
    except Exception as e:
        print(f"Erro ao calcular custo: {e}")
        return 0.0

def analisar_calendario(abast_path, aloc_path=None, rotas_path=None):
    df_abast = carregar_dataframe(abast_path)
    if df_abast is None: return
    df_abast = df_abast.apply(pd.to_numeric, errors='coerce').fillna(0)
    
    total_entregas = df_abast.sum().sum()
    entregas_por_dia = df_abast.sum(axis=0)
    pico_valor = entregas_por_dia.max()
    num_dias = len(entregas_por_dia)
    
    custo_total = 0.0
    if aloc_path and rotas_path:
        df_aloc = carregar_dataframe(aloc_path)
        if df_aloc is not None:
            custo_total = calcular_custo_total(df_aloc, df_abast, rotas_path)

    # Projeção linear para 365 dias
    custo_projetado = (custo_total / num_dias) * 365 if num_dias > 0 else 0.0

    print("-" * 50)
    print(f"MÉTRICAS (Baseadas em {num_dias} dias):")
    print(f"  Total de Entregas:            {total_entregas:.0f}")
    print(f"  Maior Pico Diário:            {pico_valor:.0f}")
    print(f"  Custo Real ({num_dias}d):         R$ {custo_total:,.2f}")
    print(f"  Custo Projetado (365d):       R$ {custo_projetado:,.2f}")
    print("-" * 50)

    return {
        "total_entregas": int(total_entregas),
        "pico": int(pico_valor),
        "custo": round(custo_total, 2),
        "qtd_dias": num_dias,
        "custo_365": round(custo_projetado, 2)
    }

def atualizar_backup(nome_instancia, metricas, backup_path):
    try:
        df_backup = pd.read_csv(backup_path, sep=';', decimal=',')
        
        if nome_instancia in df_backup['Nome da Instância'].values:
            idx = df_backup[df_backup['Nome da Instância'] == nome_instancia].index[0]
        else:
            new_row = {col: "" for col in df_backup.columns}
            new_row['Nome da Instância'] = nome_instancia
            df_backup = pd.concat([df_backup, pd.DataFrame([new_row])], ignore_index=True)
            idx = df_backup.index[-1]
            
        df_backup.at[idx, 'Total de Entregas'] = metricas['total_entregas']
        df_backup.at[idx, 'Pico de Abastecimento (Max/Dia)'] = metricas['pico']
        df_backup.at[idx, 'Custo Modelo Exato (M1)'] = metricas['custo']
        
        # Colunas adicionais para a dissertação
        if 'Qtd Dias' not in df_backup.columns: df_backup['Qtd Dias'] = ""
        if 'Custo Projetado (365d)' not in df_backup.columns: df_backup['Custo Projetado (365d)'] = ""
        
        df_backup.at[idx, 'Qtd Dias'] = metricas['qtd_dias']
        df_backup.at[idx, 'Custo Projetado (365d)'] = metricas['custo_365']
        df_backup.at[idx, 'Status'] = "Sucesso (Sliding)"
        
        df_backup.to_csv(backup_path, index=False, sep=';', decimal=',')
        print(f"Backup atualizado para {nome_instancia}.")
    except Exception as e:
        print(f"Erro ao atualizar backup: {e}")

def main():
    base_dir = Path(__file__).parent.parent
    rotas = base_dir / "alocacao/Dados/rotas"
    backup = base_dir / "alocacao/saidas_2/backup_temporario.csv"
    
    for sliding_config in ["resultados_sliding_45_14", "resultados_sliding_90_14"]:
        print(f"\n>>> Analisando: {sliding_config}")
        s_dir = base_dir / "modeloIntegrado" / sliding_config
        aba_g = s_dir / "abastecimento_GLOBAL.csv"
        alo_g = s_dir / "alocacao_GLOBAL.csv"
        
        if aba_g.exists() and alo_g.exists():
            metricas = analisar_calendario(str(aba_g), str(alo_g), str(rotas))
            atualizar_backup(sliding_config, metricas, str(backup))
        else:
            print(f"ERRO: Arquivos globais não encontrados em {s_dir}")

if __name__ == "__main__":
    main()
