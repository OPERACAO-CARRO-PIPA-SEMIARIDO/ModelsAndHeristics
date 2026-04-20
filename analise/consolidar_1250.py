import pandas as pd
from pathlib import Path

def consolidar_1250():
    # Caminhos base
    pasta_analise = Path(__file__).parent.resolve()
    pasta_raiz = pasta_analise.parent
    
    # Usamos 40 mananciais para bater com o Modelo Integrado
    pasta_alocacao_saidas = pasta_raiz / "alocacao" / "saidas_1250_40"
    pasta_modelo_integrado = pasta_raiz / "modeloIntegrado" / "resultados00_1250_365"
    
    # 1. Carregar a planilha base do tester.py
    caminho_backup = pasta_alocacao_saidas / "backup_temporario.csv"
    if not caminho_backup.exists():
        # Tenta a de 45 caso o usuário ainda não tenha rodado a de 40
        caminho_backup = pasta_raiz / "alocacao" / "saidas_1250_45" / "backup_temporario.csv"
        print(f"Aviso: Usando backup de 45 mananciais como fallback.")

    if not caminho_backup.exists():
        print(f"Erro: Nenhum backup_temporario.csv encontrado.")
        return
    
    df_base = pd.read_csv(caminho_backup, sep=';', decimal=',')
    
    # 2. Buscar resultados do Modelo Integrado (específico 1250)
    caminho_historico = pasta_modelo_integrado / "historico_controle.csv"
    if caminho_historico.exists():
        df_hist = pd.read_csv(caminho_historico)
        if not df_hist.empty:
            # Pega o melhor (menor custo)
            melhor_sol = df_hist.loc[df_hist['Objective_HigherBound'].idxmin()]
            
            # Criamos uma linha para o Modelo Integrado para facilitar o merge
            # O Modelo Integrado (resultados00) corresponde à instância "abastecimento_00_1250"
            mi_data = {
                "Nome da Instância": "abastecimento_00_1250",
                "MI_Custo": melhor_sol['Custo_Roteamento'],
                "MI_Pico": melhor_sol['Pico_Y'],
                "MI_Gap_%": melhor_sol['Gap_Percent'],
                "MI_Tempo_Segundos": melhor_sol['Tempo_Segundos']
            }
            df_mi = pd.DataFrame([mi_data])
            
            # Merge
            df_final = pd.merge(df_base, df_mi, on="Nome da Instância", how="left")
        else:
            df_final = df_base
    else:
        print("Histórico do Modelo Integrado não encontrado.")
        df_final = df_base

    caminho_excel = pasta_analise / "consolidado_1250_geral.xlsx"
    df_final.to_excel(caminho_excel, index=False)
    print(f"\nConsolidação finalizada em: {caminho_excel}")

if __name__ == "__main__":
    consolidar_1250()
