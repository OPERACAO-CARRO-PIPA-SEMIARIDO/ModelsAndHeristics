import pandas as pd
import numpy as np
from pathlib import Path

PASTA_BASE = Path(__file__).parent.resolve()
PASTA_SAIDAS2 = PASTA_BASE / "saidas_2"
PASTA_M1_ANUAL = PASTA_BASE / "saidas_m1_anual"
CAMINHO_EXCEL = PASTA_SAIDAS2 / "resumo_custos.xlsx"


def gap(a, b):
    """(a - b) / b * 100, preservando NaN."""
    with np.errstate(invalid='ignore', divide='ignore'):
        result = np.where(
            pd.isna(a) | pd.isna(b) | (b == 0),
            np.nan,
            (np.array(a, dtype=float) - np.array(b, dtype=float)) / np.array(b, dtype=float) * 100
        )
    return [round(v, 2) if not np.isnan(v) else None for v in result]


def ler_custo_m1_anual(nome_instancia):
    pasta = PASTA_M1_ANUAL / f"alocacao_{nome_instancia}"
    custo_csv = pasta / "custos_m1_anual.csv"
    if not custo_csv.exists():
        return None
    df = pd.read_csv(custo_csv)
    return round(float(df["Solucao_otima"].sum()), 2)


df = pd.read_excel(CAMINHO_EXCEL)

# Lê custos m1_anual para cada instância
df["Custo M1 Anual"] = df["Nome da Instância"].apply(
    lambda n: ler_custo_m1_anual(str(n))
)

# Renomeia a coluna existente para ficar claro que é diário
df = df.rename(columns={"Custo Modelo Exato (M1)": "Custo M1 Diário"})

m1d = df["Custo M1 Diário"]
m1a = df["Custo M1 Anual"]
m2  = df["Custo Modelo Anual (M2)"]
ori = df["Custo Alocação Original"]
heu = df["Custo Heurística"]

df["Gap M1 Anual vs M1 Diário (%)"]  = gap(m1a, m1d)
df["Gap M2 vs M1 Diário (%)"]        = gap(m2,  m1d)
df["Gap M2 vs M1 Anual (%)"]         = gap(m2,  m1a)
df["Gap Heurística vs M1 Diário (%)"]  = gap(heu, m1d)
df["Gap Heurística vs M1 Anual (%)"]   = gap(heu, m1a)
df["Gap Heurística vs M2 (%)"]         = gap(heu, m2)
df["Gap Original vs M1 Diário (%)"]    = gap(ori, m1d)
df["Gap Original vs M1 Anual (%)"]     = gap(ori, m1a)
df["Gap Original vs M2 (%)"]           = gap(ori, m2)
df["Gap Original vs Heurística (%)"]   = gap(ori, heu)

# Remove colunas de gap antigas (agora substituídas pelas novas)
df = df.drop(columns=["Gap Heurística vs M1 (%)", "Gap M2 vs M1 (%)"], errors="ignore")

# Reordena colunas
meta = ["Caminho da Entrada", "Pasta de Saída", "Qtd Dias", "Custo Projetado (365d)"]
custos = ["Custo M1 Diário", "Custo M1 Anual", "Custo Modelo Anual (M2)",
          "Custo Alocação Original", "Custo Heurística"]
gaps = [
    "Gap M1 Anual vs M1 Diário (%)",
    "Gap M2 vs M1 Diário (%)",
    "Gap M2 vs M1 Anual (%)",
    "Gap Heurística vs M1 Diário (%)",
    "Gap Heurística vs M1 Anual (%)",
    "Gap Heurística vs M2 (%)",
    "Gap Original vs M1 Diário (%)",
    "Gap Original vs M1 Anual (%)",
    "Gap Original vs M2 (%)",
    "Gap Original vs Heurística (%)",
]
base_cols = ["Nome da Instância", "Total de Entregas",
             "Pico de Abastecimento (Max/Dia)", "Status"]
df = df[base_cols + custos + gaps + meta]

# Grava Excel formatado
with pd.ExcelWriter(CAMINHO_EXCEL, engine="openpyxl") as writer:
    df.to_excel(writer, index=False, sheet_name="Resultados_Custos")
    ws = writer.sheets["Resultados_Custos"]
    headers = [c.value for c in ws[1]]

    for row in ws.iter_rows(min_row=2):
        for idx, cell in enumerate(row):
            col = str(headers[idx])
            if cell.value is None:
                continue
            if "Custo" in col and isinstance(cell.value, (int, float)):
                cell.number_format = "#,##0.00"
            elif "Gap" in col and isinstance(cell.value, (int, float)):
                cell.number_format = "0.00"
            elif ("Total" in col or "Pico" in col) and isinstance(cell.value, (int, float)):
                cell.number_format = "#,##0"
            elif "Nome" in col:
                cell.number_format = "@"
                cell.value = str(cell.value)

    for col in ws.columns:
        max_len = 0
        col_letter = col[0].column_letter
        for cell in col:
            try:
                s = f"{cell.value:,.2f}" if isinstance(cell.value, float) else str(cell.value)
                max_len = max(max_len, len(s))
            except Exception:
                pass
        ws.column_dimensions[col_letter].width = max_len + 3

print(f"Excel atualizado: {CAMINHO_EXCEL}")
print(f"Colunas: {list(df.columns)}")
print()
print(df[['Nome da Instância', 'Custo M1 Diário', 'Custo M1 Anual',
          'Gap M1 Anual vs M1 Diário (%)']].to_string(index=False))
