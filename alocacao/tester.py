import pandas as pd
from pathlib import Path
import time
import subprocess

# ==========================================
# 1. DEFINIÇÃO DE CAMINHOS BASE (Dinâmico)
# ==========================================
NUM_MANANCIAIS = 45  # Limite de mananciais a serem usados
PASTA_BASE = Path(__file__).parent.resolve()
PASTA_ENTRADAS = PASTA_BASE / "entradas_1500"
PASTA_SAIDAS = PASTA_BASE / f"saidas_1500_{NUM_MANANCIAIS}"

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

        # 1. Tratamento dos dados de entrada
        # 1. Tratamento dos dados de entrada
        df_entrada = pd.read_csv(caminho_arquivo, sep=',', index_col=0)

        # Faz a soma real dos valores de cada coluna (dia)
        entregas_por_dia = df_entrada.sum()

        # Soma todos os dias para ter o total absoluto
        total_entregas = int(entregas_por_dia.sum())

        # O pico passa a ser o dia com o MAIOR NÚMERO DE CAMINHÕES, não apenas de visitas
        pico_abastecimento = int(entregas_por_dia.max())

        pasta_alocacao = PASTA_SAIDAS / f"alocacao_{nome_entrada}"
        pasta_alocacao.mkdir(parents=True, exist_ok=True)

        caminho_aloc_m1 = pasta_alocacao / "alocacao_m1.csv"
        caminho_custo_m1 = pasta_alocacao / "custos_m1.csv"

        caminho_aloc_m2 = pasta_alocacao / "alocacao_m2.csv"
        caminho_custo_m2 = pasta_alocacao / "custos_m2.csv"

        caminho_aloc_heu = pasta_alocacao / "alocacao_heu.csv"
        caminho_custo_heu = pasta_alocacao / "custos_heu.csv"

        # 2. Execução dos Modelos e Heurística
        try:
            cmd_m1 = [
                "julia", str(PASTA_BASE / "m1args.jl"),
                str(caminho_arquivo.resolve()),
                str(caminho_aloc_m1.resolve()),
                str(caminho_custo_m1.resolve()),
                str(ARQUIVO_ROTAS.resolve()),
                str(NUM_MANANCIAIS)
            ]

            cmd_m2 = [
                "julia", str(PASTA_BASE / "m2args.jl"),
                str(caminho_arquivo.resolve()),
                str(caminho_aloc_m2.resolve()),
                str(caminho_custo_m2.resolve()),
                str(ARQUIVO_ROTAS.resolve()),
                str(NUM_MANANCIAIS)
            ]

            cmd_heu = [
                "python", str(PASTA_BASE / "HeuristicaAlocacaoArgs.py"),
                str(caminho_arquivo.resolve()),
                str(caminho_aloc_heu.resolve()),
                str(caminho_custo_heu.resolve()),
                str(ARQUIVO_ROTAS.resolve()),
                str(NUM_MANANCIAIS)
            ]

            print("  -> Rodando Modelo Exato Diário (M1)...")
            subprocess.run(cmd_m1, capture_output=True, text=True, check=True)

            print("  -> Rodando Modelo Exato Anual (M2)...")
            subprocess.run(cmd_m2, capture_output=True, text=True, check=True)

            print("  -> Rodando Heurística (Python)...")
            subprocess.run(cmd_heu, capture_output=True, text=True, check=True)

            # --- CAPTURA DOS CUSTOS REAIS ---
            df_custo_m1 = pd.read_csv(caminho_custo_m1)
            custo_m1 = round(float(df_custo_m1['Solucao_otima'].sum()), 2)

            df_custo_m2 = pd.read_csv(caminho_custo_m2)
            custo_m2 = round(float(df_custo_m2['Solucao_otima'].sum()), 2)

            df_custo_heu = pd.read_csv(caminho_custo_heu)
            custo_heu = round(float(df_custo_heu['Solucao_otima'].sum()), 2)

            status = "Sucesso"
            gap_heu_m1 = round(((custo_heu - custo_m1) / custo_m1)
                               * 100, 2) if custo_m1 > 0 else 0.0
            gap_m2_m1 = round(((custo_m2 - custo_m1) / custo_m1)
                              * 100, 2) if custo_m1 > 0 else 0.0

        except subprocess.CalledProcessError as e:
            print(f"ERRO DE EXECUÇÃO na instância {nome_entrada}.")
            print(f"Detalhes do erro: {e.stderr}")
            custo_m1, custo_m2, custo_heu = None, None, None
            status = "Erro Execução"
            gap_heu_m1, gap_m2_m1 = None, None
        except Exception as e:
            print(
                f"ERRO DE LEITURA DOS RESULTADOS na instância {nome_entrada}: {e}")
            custo_m1, custo_m2, custo_heu = None, None, None
            status = "Erro Leitura"
            gap_heu_m1, gap_m2_m1 = None, None

        # Guarda os resultados
        dados_planilha.append({
            "Nome da Instância": nome_entrada,
            "Total de Entregas": total_entregas,
            "Pico de Abastecimento (Max/Dia)": pico_abastecimento,
            "Status": status,
            "Custo Modelo Exato (M1)": custo_m1,
            "Custo Modelo Anual (M2)": custo_m2,
            "Custo Heurística": custo_heu,
            "Gap Heurística vs M1 (%)": gap_heu_m1,
            "Gap M2 vs M1 (%)": gap_m2_m1,
            "Caminho da Entrada": str(caminho_arquivo.resolve()),
            "Pasta de Saída": str(pasta_alocacao.resolve())
        })

        # -----------------------------------------------------
        # CORREÇÃO 1: CSV SECUNDÁRIO PADRONIZADO PARA O BRASIL
        # Usando sep=';' e decimal=',' para garantir que, caso você abra
        # o arquivo de backup no Excel BR, os números não quebrem.
        # -----------------------------------------------------
        pd.DataFrame(dados_planilha).to_csv(
            PASTA_SAIDAS / "backup_temporario.csv",
            index=False,
            sep=';',
            decimal=','
        )

    # ==========================================
    # 3. GERAÇÃO DA PLANILHA EXCEL FORMATADA
    # ==========================================
    df_resultados = pd.DataFrame(dados_planilha)
    caminho_planilha = PASTA_SAIDAS / "resumo_custos.xlsx"

    with pd.ExcelWriter(caminho_planilha, engine='openpyxl') as writer:
        df_resultados.to_excel(writer, index=False,
                               sheet_name='Resultados_Custos')
        worksheet = writer.sheets['Resultados_Custos']

        # Obter os cabeçalhos para aplicar formatação correta por coluna
        headers = [cell.value for cell in worksheet[1]]

        for row in worksheet.iter_rows(min_row=2):
            for idx, cell in enumerate(row):
                col_name = str(headers[idx])

                if cell.value is not None:
                    # CORREÇÃO 2: Forçar exibição das 2 casas decimais + separador de milhar (Ex: 2.467.920,50)
                    if "Custo" in col_name and isinstance(cell.value, (int, float)):
                        cell.number_format = '#,##0.00'

                    # Fixar os Gaps em 2 casas decimais sempre (Ex: 11,00)
                    elif "Gap" in col_name and isinstance(cell.value, (int, float)):
                        cell.number_format = '0.00'

                    # Formatar Entregas e Pico com ponto de milhar (Ex: 43.418)
                    elif ("Total" in col_name or "Pico" in col_name) and isinstance(cell.value, (int, float)):
                        cell.number_format = '#,##0'

                    # CORREÇÃO 3: Avisar ao Excel que o nome é TEXTO puro para ele não transformar "00" em 0
                    elif "Nome" in col_name:
                        cell.number_format = '@'
                        cell.value = str(cell.value)

        # Ajuste inteligente de largura das colunas considerando a formatação injetada
        for col in worksheet.columns:
            max_length = 0
            col_letter = col[0].column_letter
            for cell in col:
                try:
                    val_str = str(cell.value)
                    if isinstance(cell.value, float):
                        # Simula o tamanho real formatado para o ajuste
                        val_str = f"{cell.value:,.2f}"
                    if len(val_str) > max_length:
                        max_length = len(val_str)
                except:
                    pass
            worksheet.column_dimensions[col_letter].width = max_length + 3

    print(f"\nFinalizado! Planilha gerada em: {caminho_planilha}")


if __name__ == "__main__":
    executar_automacao()
