from pathlib import Path

import pandas as pd


TEST_DIR = Path(__file__).resolve().parent
RESULTADOS_DIR = TEST_DIR / "resultados_500_15_365_72h"
SAIDA_XLSX = TEST_DIR / "comparacao_custos_500x15.xlsx"


def ler_custo(caminho: Path) -> float:
    df = pd.read_csv(caminho)
    return float(df["Solucao_otima"].iloc[0])


def montar_resumo() -> pd.DataFrame:
    historico = pd.read_csv(RESULTADOS_DIR / "historico_controle.csv")
    melhor_idx = historico["Custo_Roteamento"].idxmin()
    melhor = historico.loc[melhor_idx]

    linhas = [
        {
            "Metodo": "Heuristica Full",
            "Hora": None,
            "Custo_Roteamento": ler_custo(TEST_DIR / "custos_heu_full.csv"),
            "Gap_MIP_Percent": 0.0,
            "Pico_Y": None,
            "Qtd_Entregas": None,
            "Status": "Heuristica",
        },
        {
            "Metodo": "Heuristica Limite",
            "Hora": None,
            "Custo_Roteamento": ler_custo(TEST_DIR / "custos_heu_limite.csv"),
            "Gap_MIP_Percent": 0.0,
            "Pico_Y": None,
            "Qtd_Entregas": None,
            "Status": "Heuristica",
        },
        {
            "Metodo": "M2 sobre MinPicos p00",
            "Hora": None,
            "Custo_Roteamento": ler_custo(TEST_DIR / "custos_m2_minpicos_p00.csv"),
            "Gap_MIP_Percent": float(pd.read_csv(TEST_DIR / "custos_m2_minpicos_p00.csv")["Gap_Relativo"].iloc[0]) * 100,
            "Pico_Y": None,
            "Qtd_Entregas": None,
            "Status": str(pd.read_csv(TEST_DIR / "custos_m2_minpicos_p00.csv")["Status_Solucao"].iloc[0]),
        },
        {
            "Metodo": "Modelo Integrado Melhor",
            "Hora": int(melhor["Hora"]),
            "Custo_Roteamento": float(melhor["Custo_Roteamento"]),
            "Gap_MIP_Percent": float(melhor["Gap_Percent"]),
            "Pico_Y": int(melhor["Pico_Y"]),
            "Qtd_Entregas": int(melhor["Qtd_Entregas"]),
            "Status": "Melhor checkpoint",
        },
        {
            "Metodo": "Modelo Integrado Ultimo",
            "Hora": int(historico.iloc[-1]["Hora"]),
            "Custo_Roteamento": float(historico.iloc[-1]["Custo_Roteamento"]),
            "Gap_MIP_Percent": float(historico.iloc[-1]["Gap_Percent"]),
            "Pico_Y": int(historico.iloc[-1]["Pico_Y"]),
            "Qtd_Entregas": int(historico.iloc[-1]["Qtd_Entregas"]),
            "Status": "Ultimo checkpoint",
        },
    ]

    return pd.DataFrame(linhas)


def formatar_excel(writer: pd.ExcelWriter, df_resumo: pd.DataFrame, df_historico: pd.DataFrame) -> None:
    df_resumo.to_excel(writer, index=False, sheet_name="Resumo")
    df_historico.to_excel(writer, index=False, sheet_name="ModeloIntegrado")

    for sheet_name in ["Resumo", "ModeloIntegrado"]:
        ws = writer.sheets[sheet_name]
        headers = [cell.value for cell in ws[1]]
        for row in ws.iter_rows(min_row=2):
            for idx, cell in enumerate(row):
                col = str(headers[idx])
                if cell.value is None:
                    continue
                if "Custo" in col and isinstance(cell.value, (int, float)):
                    cell.number_format = '#,##0.00'
                elif "Gap" in col and isinstance(cell.value, (int, float)):
                    cell.number_format = '0.0000'
                elif any(token in col for token in ["Hora", "Pico", "Qtd", "Tempo"]) and isinstance(cell.value, (int, float)):
                    cell.number_format = '#,##0.00' if "Tempo" in col else '#,##0'

        for col_cells in ws.columns:
            max_length = 0
            for cell in col_cells:
                try:
                    max_length = max(max_length, len(str(cell.value)))
                except Exception:
                    pass
            ws.column_dimensions[col_cells[0].column_letter].width = min(max_length + 3, 40)


def main():
    df_resumo = montar_resumo()
    df_historico = pd.read_csv(RESULTADOS_DIR / "historico_controle.csv")

    with pd.ExcelWriter(SAIDA_XLSX, engine="openpyxl") as writer:
        formatar_excel(writer, df_resumo, df_historico)

    print(f"Planilha gerada em: {SAIDA_XLSX}")


if __name__ == "__main__":
    main()
