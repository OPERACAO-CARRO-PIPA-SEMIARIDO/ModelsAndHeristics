import pandas as pd
from pathlib import Path

def consolidar_resultados_1250():
    """
    Consolida os resultados das alocações (M1, M2, Heurística) com o Modelo Integrado (MI).
    Baseado no teste de 1250 beneficiários e 40 mananciais.
    """
    pasta_raiz = Path(__file__).parent.parent.resolve()
    
    # Caminhos específicos para o setup de 1250 com 40 mananciais
    caminho_alocacao = pasta_raiz / "alocacao" / "saidas_1250_40" / "backup_temporario.csv"
    caminho_mi = pasta_raiz / "modeloIntegrado" / "resultados00_1250_365" / "historico_controle.csv"
    
    if not caminho_alocacao.exists():
        print(f"Erro: {caminho_alocacao} não encontrado. Certifique-se de rodar o tester.py primeiro.")
        return
    if not caminho_mi.exists():
        print(f"Aviso: Histórico do Modelo Integrado não encontrado em {caminho_mi}.")
        # Se não houver MI, apenas formata a planilha de alocação original
        df_final = pd.read_csv(caminho_alocacao, sep=';', decimal=',')
    else:
        # 1. Lendo dados das alocações
        df_base = pd.read_csv(caminho_alocacao, sep=';', decimal=',')
        
        # 2. Lendo dados do Modelo Integrado (Melhor Solução)
        df_mi_raw = pd.read_csv(caminho_mi)
        melhor_mi = df_mi_raw.loc[df_mi_raw['Objective_HigherBound'].idxmin()]
        
        # 3. Criar a nova linha para o MI conforme padrão visual solicitado
        nova_linha = {
            "Nome da Instância": "resultados00_1250_365 (MI)",
            "Total de Entregas": melhor_mi['Qtd_Entregas'],
            "Pico de Abastecimento (Max/Dia)": melhor_mi['Pico_Y'],
            "Status": "Sucesso (MI)",
            "Custo Modelo Exato (M1)": None,
            "Custo Modelo Anual (M2)": None,
            "Custo Heurística": None,
            "Custo Modelo Integrado (MI)": melhor_mi['Custo_Roteamento'],
            "Gap MI (%)": melhor_mi['Gap_Percent']
        }
        
        df_final = pd.concat([df_base, pd.DataFrame([nova_linha])], ignore_index=True)
    
    # 4. Organização de Colunas
    cols_base = ["Nome da Instância", "Total de Entregas", "Pico de Abastecimento (Max/Dia)", "Status"]
    cols_custo = ["Custo Modelo Exato (M1)", "Custo Modelo Anual (M2)", "Custo Heurística", "Custo Modelo Integrado (MI)"]
    cols_gap = ["Gap MI (%)", "Gap Heurística vs M1 (%)", "Gap M2 vs M1 (%)"]
    
    # Garante existência das colunas
    for c in cols_base + cols_custo + cols_gap:
        if c not in df_final.columns:
            df_final[c] = None
            
    df_final = df_final[cols_base + cols_custo + cols_gap]

    # 5. Geração do Excel Formatado
    caminho_saida = pasta_raiz / "alocacao" / "saidas_1250_40" / "resumo_consolidado_com_MI.xlsx"
    
    with pd.ExcelWriter(caminho_saida, engine='openpyxl') as writer:
        df_final.to_excel(writer, index=False, sheet_name='Resultados_Custos')
        worksheet = writer.sheets['Resultados_Custos']
        
        headers = [cell.value for cell in worksheet[1]]
        for row in worksheet.iter_rows(min_row=2):
            for idx, cell in enumerate(row):
                col_name = str(headers[idx])
                if cell.value is not None:
                    if "Custo" in col_name and isinstance(cell.value, (int, float)):
                        cell.number_format = '#,##0.00'
                    elif "Gap" in col_name and isinstance(cell.value, (int, float)):
                        cell.number_format = '0.00'
                    elif ("Total" in col_name or "Pico" in col_name) and isinstance(cell.value, (int, float)):
                        cell.number_format = '#,##0'

        for col in worksheet.columns:
            max_length = 0
            col_letter = col[0].column_letter
            for cell in col:
                try:
                    val_str = str(cell.value)
                    if isinstance(cell.value, float): val_str = f"{cell.value:,.2f}"
                    if len(val_str) > max_length: max_length = len(val_str)
                except: pass
            worksheet.column_dimensions[col_letter].width = max_length + 3

    print(f"Planilha final consolidada em: {caminho_saida}")

if __name__ == "__main__":
    consolidar_resultados_1250()
