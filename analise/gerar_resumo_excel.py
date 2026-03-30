import pandas as pd
from pathlib import Path

def gerar_excel_formatado(csv_path, excel_path):
    print(f"Lendo CSV: {csv_path}")
    try:
        # Lê o CSV usando os mesmos parâmetros do tester.py original (; e ,)
        df_resultados = pd.read_csv(csv_path, sep=';', decimal=',')
        
        print(f"Gerando Excel: {excel_path}")
        with pd.ExcelWriter(excel_path, engine='openpyxl') as writer:
            df_resultados.to_excel(writer, index=False, sheet_name='Resultados_Custos')
            worksheet = writer.sheets['Resultados_Custos']
            
            headers = [cell.value for cell in worksheet[1]]
            
            for row in worksheet.iter_rows(min_row=2):
                for idx, cell in enumerate(row):
                    col_name = str(headers[idx])
                    
                    if cell.value is not None:
                        # Formatação de Moeda/Custo
                        if "Custo" in col_name and isinstance(cell.value, (int, float)):
                            cell.number_format = '#,##0.00'
                            
                        # Formatação de Gaps
                        elif "Gap" in col_name and isinstance(cell.value, (int, float)):
                            cell.number_format = '0.00'
                            
                        # Formatação de Entregas e Pico
                        elif ("Total" in col_name or "Pico" in col_name) and isinstance(cell.value, (int, float)):
                            cell.number_format = '#,##0'
                            
                        # Garantir que IDs de instâncias comecem com zero se necessário
                        elif "Nome" in col_name:
                            cell.number_format = '@'
                            cell.value = str(cell.value)

            # Ajuste de largura de colunas
            for col in worksheet.columns:
                max_length = 0
                col_letter = col[0].column_letter
                for cell in col:
                    try:
                        val_str = str(cell.value)
                        if isinstance(cell.value, float):
                            val_str = f"{cell.value:,.2f}"
                        if len(val_str) > max_length:
                            max_length = len(val_str)
                    except:
                        pass
                worksheet.column_dimensions[col_letter].width = max_length + 3
                
        print("Excel gerado com sucesso.")
    except Exception as e:
        print(f"Erro ao gerar Excel: {e}")

if __name__ == "__main__":
    base_dir = Path(__file__).parent.parent
    csv_in = base_dir / "alocacao/saidas_2/backup_temporario.csv"
    excel_out = base_dir / "alocacao/saidas_2/resumo_custos.xlsx"
    
    if csv_in.exists():
        gerar_excel_formatado(csv_in, excel_out)
    else:
        print(f"Arquivo não encontrado: {csv_in}")
