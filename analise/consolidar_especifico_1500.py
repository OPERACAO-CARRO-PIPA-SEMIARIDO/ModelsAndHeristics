import pandas as pd
from pathlib import Path

def consolidar_especifico():
    # Caminhos base
    pasta_raiz = Path(__file__).parent.parent.resolve()
    
    # Arquivo 1: Resultados de Alocação (M1, M2, Heurística)
    caminho_alocacao = pasta_raiz / "alocacao" / "saidas_1500_45" / "backup_temporario.csv"
    
    # Arquivo 2: Resultados do Modelo Integrado
    caminho_mi = pasta_raiz / "modeloIntegrado" / "resultados00_1500_150" / "historico_controle.csv"
    
    # Verificação de existência
    if not caminho_alocacao.exists():
        print(f"Erro: {caminho_alocacao} não encontrado.")
        return
    if not caminho_mi.exists():
        print(f"Erro: {caminho_mi} não encontrado.")
        return

    # Lendo os dados
    # Alocação usa ';' como separador e ',' como decimal conforme visto no arquivo
    df_alocacao = pd.read_csv(caminho_alocacao, sep=';', decimal=',')
    
    # MI usa ',' padrão
    df_mi = pd.read_csv(caminho_mi)
    
    # Nome do arquivo de saída
    arquivo_saida = pasta_raiz / "analise" / "consolidado_1500_150.xlsx"
    
    print(f"Gerando planilha em: {arquivo_saida}")
    
    with pd.ExcelWriter(arquivo_saida, engine='openpyxl') as writer:
        # Aba 1: Comparativo de Alocação
        df_alocacao.to_excel(writer, sheet_name='Alocacao_M1_M2_Heu', index=False)
        
        # Aba 2: Evolução do Modelo Integrado
        df_mi.to_excel(writer, sheet_name='Modelo_Integrado_Evolucao', index=False)
        
        # Ajuste básico de largura de colunas (opcional, mas bom para análise)
        for sheet_name in writer.sheets:
            worksheet = writer.sheets[sheet_name]
            for col in worksheet.columns:
                max_length = 0
                col_letter = col[0].column_letter
                for cell in col:
                    try:
                        if len(str(cell.value)) > max_length:
                            max_length = len(str(cell.value))
                    except:
                        pass
                worksheet.column_dimensions[col_letter].width = max_length + 2

    print("Sucesso! Os dados foram unidos em uma única planilha.")

if __name__ == "__main__":
    consolidar_especifico()
