import pandas as pd
from pathlib import Path
import time
import subprocess

NUM_MANANCIAIS = 92

PASTA_BASE     = Path(__file__).parent.resolve()
PASTA_ENTRADAS = PASTA_BASE / "entradas"
PASTA_SAIDAS   = PASTA_BASE / "saidas_3"
ARQUIVO_ROTAS  = PASTA_BASE / "Dados" / "rotas"

PASTA_SAIDAS.mkdir(parents=True, exist_ok=True)


def rodar_cmd(cmd, label):
    resultado = subprocess.run(cmd, capture_output=True, text=True)
    if resultado.returncode != 0:
        raise subprocess.CalledProcessError(
            resultado.returncode, cmd, resultado.stdout, resultado.stderr
        )
    return resultado


def ler_custo(caminho_csv):
    df = pd.read_csv(caminho_csv)
    custo  = round(float(df["Solucao_otima"].sum()), 2)
    tempo  = round(float(df["Tempo_de_Execucao"].sum()), 2)
    if "Status_Solucao" in df.columns:
        n_falhas   = (df["Status_Solucao"] != "Otimo").sum()
        status_col = "Otimo" if n_falhas == 0 else f"Parcial ({n_falhas} falhas)"
    else:
        status_col = "Desconhecido"
    return custo, tempo, status_col


def gap(a, b):
    if a is None or b is None or b == 0:
        return None
    return round((a - b) / b * 100, 2)


def formatar_excel(worksheet, headers):
    for row in worksheet.iter_rows(min_row=2):
        for idx, cell in enumerate(row):
            col = str(headers[idx])
            if cell.value is None:
                continue
            if "Custo" in col and isinstance(cell.value, (int, float)):
                cell.number_format = "#,##0.00"
            elif "Gap" in col and isinstance(cell.value, (int, float)):
                cell.number_format = "0.00"
            elif "Tempo" in col and isinstance(cell.value, (int, float)):
                cell.number_format = "#,##0.00"
            elif ("Total" in col or "Pico" in col) and isinstance(cell.value, (int, float)):
                cell.number_format = "#,##0"
            elif "Nome" in col:
                cell.number_format = "@"
                cell.value = str(cell.value)

    for col in worksheet.columns:
        max_len    = 0
        col_letter = col[0].column_letter
        for cell in col:
            try:
                s = f"{cell.value:,.2f}" if isinstance(cell.value, float) else str(cell.value)
                max_len = max(max_len, len(s))
            except Exception:
                pass
        worksheet.column_dimensions[col_letter].width = max_len + 3


def executar_automacao():
    dados_planilha   = []
    arquivos_entrada = sorted(PASTA_ENTRADAS.glob("*.csv"))

    if not arquivos_entrada:
        print("Nenhum arquivo CSV encontrado em 'entradas'.")
        return

    modelos = [
        ("m1_diario",  "julia",  PASTA_BASE / "m1_diario.jl",              "M1 Diário"),
        ("m1_anual",   "julia",  PASTA_BASE / "m1_anual.jl",               "M1 Anual"),
        ("m2",         "julia",  PASTA_BASE / "m2args.jl",                  "M2"),
        ("heuristica", "python", PASTA_BASE / "heuristicaAlocacaoArgs.py",  "Heurística"),
    ]

    for caminho_arquivo in arquivos_entrada:
        nome = caminho_arquivo.stem
        print(f"\n[{time.strftime('%H:%M:%S')}] Processando: {nome}...")

        df_entrada         = pd.read_csv(caminho_arquivo, sep=",", index_col=0)
        total_entregas     = int(df_entrada.values.sum())
        pico_abastecimento = int(df_entrada.sum().max())

        pasta = PASTA_SAIDAS / f"alocacao_{nome}"
        pasta.mkdir(parents=True, exist_ok=True)

        resultados = {}

        for chave, interpretador, script, label in modelos:
            aloc      = pasta / f"alocacao_{chave}.csv"
            custo_csv = pasta / f"custos_{chave}.csv"

            cmd = [
                interpretador, str(script),
                str(caminho_arquivo.resolve()),
                str(aloc.resolve()),
                str(custo_csv.resolve()),
                str(ARQUIVO_ROTAS.resolve()),
                str(NUM_MANANCIAIS),
            ]

            print(f"  -> Rodando {label}...")
            try:
                rodar_cmd(cmd, label)
                custo, tempo, status_sol = ler_custo(custo_csv)
                resultados[chave] = {"custo": custo, "tempo": tempo, "status": status_sol}
            except subprocess.CalledProcessError as e:
                print(f"     ERRO de execução em {label}: {e.stderr[:300]}")
                resultados[chave] = {"custo": None, "tempo": None, "status": "Erro Execução"}
            except Exception as e:
                print(f"     ERRO ao ler resultados de {label}: {e}")
                resultados[chave] = {"custo": None, "tempo": None, "status": "Erro Leitura"}

        c_d  = resultados["m1_diario"]["custo"]
        c_a  = resultados["m1_anual"]["custo"]
        c_m2 = resultados["m2"]["custo"]
        c_h  = resultados["heuristica"]["custo"]

        dados_planilha.append({
            "Nome da Instância":               nome,
            "Total de Entregas":               total_entregas,
            "Pico de Abastecimento (Max/Dia)": pico_abastecimento,
            "Status M1 Diário":                resultados["m1_diario"]["status"],
            "Status M1 Anual":                 resultados["m1_anual"]["status"],
            "Status M2":                       resultados["m2"]["status"],
            "Status Heurística":               resultados["heuristica"]["status"],
            "Custo M1 Diário":                 c_d,
            "Custo M1 Anual":                  c_a,
            "Custo M2":                        c_m2,
            "Custo Heurística":                c_h,
            "Gap M1 Anual vs M1 Diário (%)":   gap(c_a,  c_d),
            "Gap M2 vs M1 Diário (%)":         gap(c_m2, c_d),
            "Gap Heurística vs M1 Diário (%)": gap(c_h,  c_d),
            "Gap Heurística vs M2 (%)":        gap(c_h,  c_m2),
            "Tempo M1 Diário (s)":             resultados["m1_diario"]["tempo"],
            "Tempo M1 Anual (s)":              resultados["m1_anual"]["tempo"],
            "Tempo M2 (s)":                    resultados["m2"]["tempo"],
            "Tempo Heurística (s)":            resultados["heuristica"]["tempo"],
            "Caminho da Entrada":              str(caminho_arquivo.resolve()),
            "Pasta de Saída":                  str(pasta.resolve()),
        })

        pd.DataFrame(dados_planilha).to_csv(
            PASTA_SAIDAS / "backup_temporario.csv",
            index=False, sep=";", decimal=",",
        )

    df = pd.DataFrame(dados_planilha)
    caminho_excel = PASTA_SAIDAS / "resumo_custos.xlsx"

    with pd.ExcelWriter(caminho_excel, engine="openpyxl") as writer:
        df.to_excel(writer, index=False, sheet_name="Resultados")
        ws      = writer.sheets["Resultados"]
        headers = [c.value for c in ws[1]]
        formatar_excel(ws, headers)

    print(f"\nFinalizado! Planilha gerada em: {caminho_excel}")


if __name__ == "__main__":
    executar_automacao()
