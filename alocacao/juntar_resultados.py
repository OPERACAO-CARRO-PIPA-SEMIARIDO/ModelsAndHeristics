import pandas as pd
from pathlib import Path
from openpyxl import load_workbook
from openpyxl.styles import PatternFill, Font

PASTA_SAIDAS      = Path(__file__).parent / "saidas_1250_40_365_2"
CAMINHO_XLSX      = PASTA_SAIDAS / "resumo_custos.xlsx"
CAMINHO_INTEGRADO = Path(__file__).parent.parent / "modeloIntegrado" / "resultados00_1250_365" / "historico_controle.csv"

# Mapeamento: sufixo do nome da instância → pasta de resultados do integrado
MAPA_INTEGRADO = {
    "abastecimento_00_1250": CAMINHO_INTEGRADO,
}

df_main = pd.read_excel(CAMINHO_XLSX, sheet_name="Resultados_Custos")

# Lê todos os históricos disponíveis
historicos = {}
for nome, caminho in MAPA_INTEGRADO.items():
    historicos[nome] = pd.read_csv(caminho)

# Descobre todos os horários presentes (union de todos os históricos)
horas_set = set()
for df_h in historicos.values():
    horas_set.update(df_h["Hora"].tolist())
horas_ordenadas = sorted(horas_set)

# Adiciona colunas ao df_main
for h in horas_ordenadas:
    df_main[f"Custo Integrado {h}h"]       = None
    df_main[f"Gap Integrado {h}h vs M1D (%)"] = None
    df_main[f"Gap MIP Integrado {h}h (%)"]  = None

for idx, row in df_main.iterrows():
    nome = row["Nome da Instância"]
    if nome not in historicos:
        continue
    df_h = historicos[nome]
    custo_m1d = row["Custo M1 Diário"]
    for h in horas_ordenadas:
        linha = df_h[df_h["Hora"] == h]
        if linha.empty:
            continue
        custo_int = round(float(linha["Custo_Roteamento"].values[0]), 2)
        gap_mip   = round(float(linha["Gap_Percent"].values[0]), 4)
        gap_vs    = round(((custo_int - custo_m1d) / custo_m1d) * 100, 2) if custo_m1d and custo_m1d > 0 else None
        df_main.at[idx, f"Custo Integrado {h}h"]          = custo_int
        df_main.at[idx, f"Gap Integrado {h}h vs M1D (%)"] = gap_vs
        df_main.at[idx, f"Gap MIP Integrado {h}h (%)"]    = gap_mip

# Consolida todos os históricos numa única aba
frames = []
for nome, df_h in historicos.items():
    df_tmp = df_h.copy()
    df_tmp.insert(0, "Instancia", nome)
    frames.append(df_tmp)
df_integrado_full = pd.concat(frames, ignore_index=True)

# Escreve o xlsx com duas abas
with pd.ExcelWriter(CAMINHO_XLSX, engine="openpyxl") as writer:
    df_main.to_excel(writer, index=False, sheet_name="Resultados_Custos")
    df_integrado_full.to_excel(writer, index=False, sheet_name="ModeloIntegrado")

    # Formatação da aba principal
    ws = writer.sheets["Resultados_Custos"]
    headers = [cell.value for cell in ws[1]]
    for row in ws.iter_rows(min_row=2):
        for idx, cell in enumerate(row):
            col = str(headers[idx])
            if cell.value is None:
                continue
            if "Custo" in col and isinstance(cell.value, (int, float)):
                cell.number_format = "#,##0.00"
            elif "Gap" in col and isinstance(cell.value, (int, float)):
                cell.number_format = "0.0000"
            elif "Tempo" in col and isinstance(cell.value, (int, float)):
                cell.number_format = "#,##0.0000"
            elif ("Total" in col or "Pico" in col) and isinstance(cell.value, (int, float)):
                cell.number_format = "#,##0"
            elif "Nome" in col or "Instancia" in col:
                cell.number_format = "@"
                cell.value = str(cell.value)

    # Ajuste de largura
    for ws_name in ["Resultados_Custos", "ModeloIntegrado"]:
        ws_fmt = writer.sheets[ws_name]
        for col in ws_fmt.columns:
            max_len = max((len(str(c.value)) for c in col if c.value is not None), default=0)
            ws_fmt.column_dimensions[col[0].column_letter].width = max_len + 3

print(f"Planilha atualizada: {CAMINHO_XLSX}")
