import pandas as pd
from pathlib import Path
import time
import subprocess

# ==========================================
# 1. DEFINIÇÃO DE CAMINHOS BASE (Dinâmico)
# ==========================================
NUM_MANANCIAIS = 92
PASTA_BASE = Path(__file__).parent.resolve()
PASTA_ENTRADAS = PASTA_BASE / "entradas"
PASTA_SAIDAS = PASTA_BASE / "saidas_m1_anual"

ARQUIVO_ROTAS = PASTA_BASE / "Dados" / "rotas"

PASTA_SAIDAS.mkdir(parents=True, exist_ok=True)


def executar_automacao():
    dados_planilha = []
    arquivos_entrada = list(PASTA_ENTRADAS.glob("*.csv"))

    if not arquivos_entrada:
        print("Nenhum arquivo CSV encontrado na pasta 'entradas'.")
        return

    for caminho_arquivo in arquivos_entrada:
        nome_entrada = caminho_arquivo.stem
        print(f"\n[{time.strftime('%H:%M:%S')}] Processando: {nome_entrada}...")

        df_entrada = pd.read_csv(caminho_arquivo, sep=',', index_col=0)
        entregas_por_dia = df_entrada.sum()
        total_entregas = int(entregas_por_dia.sum())
        pico_abastecimento = int(entregas_por_dia.max())

        pasta_alocacao = PASTA_SAIDAS / f"alocacao_{nome_entrada}"
        pasta_alocacao.mkdir(parents=True, exist_ok=True)

        caminho_aloc = pasta_alocacao / "alocacao_m1_anual.csv"
        caminho_custo = pasta_alocacao / "custos_m1_anual.csv"

        try:
            cmd_m1_anual = [
                "julia", str(PASTA_BASE / "m1_anual.jl"),
                str(caminho_arquivo.resolve()),
                str(caminho_aloc.resolve()),
                str(caminho_custo.resolve()),
                str(ARQUIVO_ROTAS.resolve()),
                str(NUM_MANANCIAIS)
            ]

            print("  -> Rodando M1 Anual (sem fonte única)...")
            resultado = subprocess.run(cmd_m1_anual, capture_output=True, text=True)

            if resultado.returncode != 0:
                raise subprocess.CalledProcessError(
                    resultado.returncode, cmd_m1_anual, resultado.stdout, resultado.stderr
                )

            df_custo = pd.read_csv(caminho_custo)
            custo = round(float(df_custo['Solucao_otima'].sum()), 2)
            tempo = round(float(df_custo['Tempo_de_Execucao'].sum()), 2)
            status = "Sucesso"

        except subprocess.CalledProcessError as e:
            print(f"ERRO DE EXECUÇÃO na instância {nome_entrada}.")
            print(f"Detalhes stdout: {e.stdout}")
            print(f"Detalhes stderr: {e.stderr}")
            custo, tempo = None, None
            status = "Erro Execução"
        except Exception as e:
            print(f"ERRO DE LEITURA DOS RESULTADOS na instância {nome_entrada}: {e}")
            custo, tempo = None, None
            status = "Erro Leitura"

        dados_planilha.append({
            "Nome da Instância": nome_entrada,
            "Total de Entregas": total_entregas,
            "Pico de Abastecimento (Max/Dia)": pico_abastecimento,
            "Status": status,
            "Custo M1 Anual": custo,
            "Tempo de Execução (s)": tempo,
            "Caminho da Entrada": str(caminho_arquivo.resolve()),
            "Pasta de Saída": str(pasta_alocacao.resolve())
        })

        pd.DataFrame(dados_planilha).to_csv(
            PASTA_SAIDAS / "backup_temporario.csv",
            index=False,
            sep=';',
            decimal=','
        )

    # ==========================================
    # 2. GERAÇÃO DA PLANILHA EXCEL FORMATADA
    # ==========================================
    df_resultados = pd.DataFrame(dados_planilha)
    caminho_planilha = PASTA_SAIDAS / "resumo_custos.xlsx"

    with pd.ExcelWriter(caminho_planilha, engine='openpyxl') as writer:
        df_resultados.to_excel(writer, index=False, sheet_name='Resultados_Custos')
        worksheet = writer.sheets['Resultados_Custos']

        headers = [cell.value for cell in worksheet[1]]

        for row in worksheet.iter_rows(min_row=2):
            for idx, cell in enumerate(row):
                col_name = str(headers[idx])

                if cell.value is not None:
                    if "Custo" in col_name and isinstance(cell.value, (int, float)):
                        cell.number_format = '#,##0.00'
                    elif "Tempo" in col_name and isinstance(cell.value, (int, float)):
                        cell.number_format = '#,##0.00'
                    elif ("Total" in col_name or "Pico" in col_name) and isinstance(cell.value, (int, float)):
                        cell.number_format = '#,##0'
                    elif "Nome" in col_name:
                        cell.number_format = '@'
                        cell.value = str(cell.value)

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

    print(f"\nFinalizado! Planilha gerada em: {caminho_planilha}")


if __name__ == "__main__":
    executar_automacao()
