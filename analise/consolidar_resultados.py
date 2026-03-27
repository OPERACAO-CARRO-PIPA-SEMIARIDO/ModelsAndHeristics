import pandas as pd
import os
from pathlib import Path

def consolidar_resultados():
    # Caminhos base
    pasta_analise = Path(__file__).parent.resolve()
    pasta_raiz = pasta_analise.parent
    pasta_alocacao_saidas = pasta_raiz / "alocacao" / "saidas_150"
    pasta_modelo_integrado = pasta_raiz / "modeloIntegrado"
    
    # 1. Carregar a planilha base do tester.py (usando o CSV de backup por segurança)
    caminho_backup = pasta_alocacao_saidas / "backup_temporario.csv"
    if not caminho_backup.exists():
        print(f"Erro: {caminho_backup} não encontrado.")
        return
    
    df_base = pd.read_csv(caminho_backup, sep=';', decimal=',')
    
    # 2. Buscar resultados do modeloIntegrado
    dados_integrado = []
    
    for pasta in pasta_modelo_integrado.iterdir():
        if pasta.is_dir() and pasta.name.startswith("resultados"):
            caminho_historico = pasta / "historico_controle.csv"
            if caminho_historico.exists():
                try:
                    df_hist = pd.read_csv(caminho_historico)
                    if not df_hist.empty:
                        # Pega a melhor solução (menor custo / última linha com sucesso)
                        melhor_sol = df_hist.loc[df_hist['Objective_HigherBound'].idxmin()]
                        
                        dados_integrado.append({
                            "Pasta_ModeloIntegrado": pasta.name,
                            "MI_Custo": melhor_sol['Custo_Roteamento'],
                            "MI_Pico": melhor_sol['Pico_Y'],
                            "MI_Gap_%": melhor_sol['Gap_Percent'],
                            "MI_Tempo_Segundos": melhor_sol['Tempo_Segundos'],
                            "MI_Entregas": melhor_sol['Qtd_Entregas']
                        })
                except Exception as e:
                    print(f"Erro ao ler {caminho_historico}: {e}")

    df_integrado = pd.DataFrame(dados_integrado)
    
    # 3. Tentativa de merge (como os nomes podem não bater exatamente, vou criar uma planilha com as duas partes)
    # e o usuário pode conferir. Se houver um padrão claro, podemos automatizar o merge.
    
    print("\n--- Resultados do Modelo Integrado Encontrados ---")
    print(df_integrado)
    
    caminho_final = pasta_analise / "consolidado_geral.xlsx"
    
    with pd.ExcelWriter(caminho_final, engine='openpyxl') as writer:
        df_base.to_excel(writer, sheet_name='Base_Tester', index=False)
        if not df_integrado.empty:
            df_integrado.to_excel(writer, sheet_name='Modelo_Integrado', index=False)
        
        # Se quiser tentar um merge automático por similaridade de nome ou ordem:
        # Aqui fazemos um merge simples se o usuário quiser, mas por enquanto salvamos em abas separadas.
        
    print(f"\nConsolidação finalizada em: {caminho_final}")

if __name__ == "__main__":
    consolidar_resultados()
