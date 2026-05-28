import pandas as pd
from pathlib import Path
import time
import subprocess

# ==========================================
# 1. DEFINIÇÃO DE CAMINHOS BASE (Dinâmico)
# ==========================================
NUM_MANANCIAIS = 40
PASTA_BASE     = Path("C:/Users/lfeli/Documents/AlocacaoCarros/ModelsAndHeristics/alocacao")
PASTA_ENTRADAS = Path("C:/Users/lfeli/Documents/AlocacaoCarros/ModelsAndHeristics/alocacao/entradas_1250")
PASTA_SAIDAS   = Path("C:/Users/lfeli/Documents/AlocacaoCarros/ModelsAndHeristics/alocacao/saidas_1250_40_365_2")
ARQUIVO_ROTAS  = Path("C:/Users/lfeli/Documents/AlocacaoCarros/ModelsAndHeristics/alocacao/Dados/rotas")

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

        caminho_aloc_m1d = pasta_alocacao / "alocacao_m1_diario.csv"
        caminho_custo_m1d = pasta_alocacao / "custos_m1_diario.csv"

        caminho_aloc_m1a = pasta_alocacao / "alocacao_m1_anual.csv"
        caminho_custo_m1a = pasta_alocacao / "custos_m1_anual.csv"

        caminho_aloc_m2 = pasta_alocacao / "alocacao_m2.csv"
        caminho_custo_m2 = pasta_alocacao / "custos_m2.csv"

        caminho_aloc_heu = pasta_alocacao / "alocacao_heu.csv"
        caminho_custo_heu = pasta_alocacao / "custos_heu.csv"

        def _cmd_julia(script, aloc, custo):
            return ["julia", str(PASTA_BASE / script),
                    str(caminho_arquivo.resolve()), str(aloc.resolve()),
                    str(custo.resolve()), str(ARQUIVO_ROTAS.resolve()), str(NUM_MANANCIAIS)]

        # 2. Execução dos Modelos e Heurística
        try:
            print("  -> Rodando M1 Diário...")
            subprocess.run(_cmd_julia("m1_diario.jl", caminho_aloc_m1d, caminho_custo_m1d),
                           capture_output=True, text=True, check=True)

            print("  -> Rodando M1 Anual...")
            subprocess.run(_cmd_julia("m1_anual.jl", caminho_aloc_m1a, caminho_custo_m1a),
                           capture_output=True, text=True, check=True)

            print("  -> Rodando M2...")
            subprocess.run(_cmd_julia("m2args.jl", caminho_aloc_m2, caminho_custo_m2),
                           capture_output=True, text=True, check=True)

            print("  -> Rodando Heurística...")
            subprocess.run(["python", str(PASTA_BASE / "heuristicaAlocacaoArgs.py"),
                            str(caminho_arquivo.resolve()), str(caminho_aloc_heu.resolve()),
                            str(caminho_custo_heu.resolve()), str(ARQUIVO_ROTAS.resolve()),
                            str(NUM_MANANCIAIS)],
                           capture_output=True, text=True, check=True)

            # --- CAPTURA DOS CUSTOS, TEMPOS E GAPS REAIS ---
            df_m1d = pd.read_csv(caminho_custo_m1d)
            df_m1a = pd.read_csv(caminho_custo_m1a)
            df_m2  = pd.read_csv(caminho_custo_m2)
            df_heu = pd.read_csv(caminho_custo_heu)

            custo_m1d = round(float(df_m1d['Solucao_otima'].sum()), 2)
            custo_m1a = round(float(df_m1a['Solucao_otima'].sum()), 2)
            custo_m2  = round(float(df_m2['Solucao_otima'].sum()),  2)
            custo_heu = round(float(df_heu['Solucao_otima'].sum()), 2)

            tempo_m1d = round(float(df_m1d['Tempo_de_Execucao'].sum()), 4)
            tempo_m1a = round(float(df_m1a['Tempo_de_Execucao'].iloc[0]), 4)
            tempo_m2  = round(float(df_m2['Tempo_de_Execucao'].iloc[0]),  4)
            tempo_heu = round(float(df_heu['Tempo_de_Execucao'].iloc[0]), 4)

            # Gap MIP do solver (fração → %) — M1 Diário é sempre 0 (resolve até ótimo por dia)
            gap_mip_m1a = round(float(df_m1a['Gap_Relativo'].iloc[0]) * 100, 4)
            gap_mip_m2  = round(float(df_m2['Gap_Relativo'].iloc[0])  * 100, 4)

            status = "Sucesso"
            gap_m1a_m1d = round(((custo_m1a - custo_m1d) / custo_m1d) * 100, 2) if custo_m1d > 0 else 0.0
            gap_m2_m1d  = round(((custo_m2  - custo_m1d) / custo_m1d) * 100, 2) if custo_m1d > 0 else 0.0
            gap_heu_m1d = round(((custo_heu - custo_m1d) / custo_m1d) * 100, 2) if custo_m1d > 0 else 0.0

        except subprocess.CalledProcessError as e:
            print(f"ERRO DE EXECUÇÃO na instância {nome_entrada}.")
            print(f"Detalhes do erro: {e.stderr}")
            custo_m1d = custo_m1a = custo_m2 = custo_heu = None
            tempo_m1d = tempo_m1a = tempo_m2 = tempo_heu = None
            gap_mip_m1a = gap_mip_m2 = None
            status = "Erro Execução"
            gap_m1a_m1d = gap_m2_m1d = gap_heu_m1d = None
        except Exception as e:
            print(f"ERRO DE LEITURA DOS RESULTADOS na instância {nome_entrada}: {e}")
            custo_m1d = custo_m1a = custo_m2 = custo_heu = None
            tempo_m1d = tempo_m1a = tempo_m2 = tempo_heu = None
            gap_mip_m1a = gap_mip_m2 = None
            status = "Erro Leitura"
            gap_m1a_m1d = gap_m2_m1d = gap_heu_m1d = None

        # Guarda os resultados
        dados_planilha.append({
            "Nome da Instância": nome_entrada,
            "Total de Entregas": total_entregas,
            "Pico de Abastecimento (Max/Dia)": pico_abastecimento,
            "Status": status,
            "Custo M1 Diário": custo_m1d,
            "Custo M1 Anual": custo_m1a,
            "Custo M2": custo_m2,
            "Custo Heurística": custo_heu,
            "Gap M1 Anual vs M1 Diário (%)": gap_m1a_m1d,
            "Gap M2 vs M1 Diário (%)": gap_m2_m1d,
            "Gap Heurística vs M1 Diário (%)": gap_heu_m1d,
            "Tempo M1 Diário (s)": tempo_m1d,
            "Tempo M1 Anual (s)": tempo_m1a,
            "Tempo M2 (s)": tempo_m2,
            "Tempo Heurística (s)": tempo_heu,
            "Gap MIP M1 Anual (%)": gap_mip_m1a,
            "Gap MIP M2 (%)": gap_mip_m2,
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
                    if "Custo" in col_name and isinstance(cell.value, (int, float)):
                        cell.number_format = '#,##0.00'

                    elif "Gap" in col_name and isinstance(cell.value, (int, float)):
                        cell.number_format = '0.0000'

                    elif "Tempo" in col_name and isinstance(cell.value, (int, float)):
                        cell.number_format = '#,##0.0000'

                    elif ("Total" in col_name or "Pico" in col_name) and isinstance(cell.value, (int, float)):
                        cell.number_format = '#,##0'

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
