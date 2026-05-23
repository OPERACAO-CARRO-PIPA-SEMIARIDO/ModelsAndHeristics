import pandas as pd
import numpy as np
from pathlib import Path

BASE = Path(__file__).parent.resolve()
PASTA_SAIDAS = BASE / "saidas_3"
PASTA_ENTRADAS = BASE / "entradas"
ARQUIVO_BENEFICIARIOS = BASE.parent / "Beneficiarios_RN_Ativos1.csv"
ARQUIVO_MANANCIAIS = BASE.parent / "Mananciais_RN.csv"
ARQUIVO_ROTAS = BASE.parent / "rotas"
CAMINHO_EXCEL = PASTA_SAIDAS / "resumo_custos.xlsx"


def gcda_para_fonte(df_man):
    """Constrói mapeamento exato GCDA → id_fonte (= índice de linha no CSV de mananciais)."""
    df = df_man.dropna(subset=["Id"]).reset_index(drop=True)
    return {int(row["Cód. GCDA Manancial"]): idx for idx, row in df.iterrows()}


def calcular_custo_original(nome_instancia, dist_original):
    """
    Custo original = sum_j( dist_w_factor[original_fonte[j], j] * total_entregas[j] )
    A alocação usa o manancial do GCDA_Manancial_Assoc de cada beneficiário, sem otimização.
    """
    caminho = PASTA_ENTRADAS / f"{nome_instancia}.csv"
    if not caminho.exists():
        return None
    df_entrada = pd.read_csv(caminho, index_col=0)
    total_por_beneficiario = df_entrada.sum(axis=1).values.astype(float)
    return float(round(np.dot(dist_original, total_por_beneficiario), 2))


def gap(a, b):
    if a is None or b is None or b == 0:
        return None
    return round((a - b) / b * 100, 2)


def main():
    df_ben = pd.read_csv(ARQUIVO_BENEFICIARIOS)
    df_man = pd.read_csv(ARQUIVO_MANANCIAIS, sep=";")
    df_rotas = pd.read_csv(ARQUIVO_ROTAS)

    mapping = gcda_para_fonte(df_man)
    print("Mapeamento GCDA → id_fonte (exacto via Mananciais_RN.csv):")
    for gcda in sorted(df_ben["GCDA_Manancial_Assoc"].unique()):
        fonte = mapping.get(int(gcda), "NÃO ENCONTRADO")
        print(f"  GCDA {gcda} → fonte {fonte}")

    # Distância ponderada do manancial original para cada beneficiário
    rotas_idx = df_rotas.set_index(["id_beneficiario", "id_fonte"])["distance_w_factor"]
    num_ben = len(df_ben)
    dist_original = np.zeros(num_ben)
    missing = 0
    for row_idx in range(num_ben):
        gcda = int(df_ben.iloc[row_idx]["GCDA_Manancial_Assoc"])
        fonte = mapping.get(gcda)
        if fonte is None:
            missing += 1
            continue
        dist_original[row_idx] = float(rotas_idx.get((row_idx, int(fonte)), 0.0))  # type: ignore[arg-type]
    if missing:
        print(f"AVISO: {missing} beneficiários sem manancial mapeado.")

    # Carrega Excel existente
    df = pd.read_excel(CAMINHO_EXCEL)

    # Calcula custo original para cada instância
    custos_originais = []
    for nome in df["Nome da Instância"]:
        custo = calcular_custo_original(str(nome), dist_original)
        custos_originais.append(custo)
        print(f"  {nome}: Custo Original = {custo:,.2f}" if custo else f"  {nome}: N/A")

    # Remove todos os gaps antigos
    df = df.drop(columns=[c for c in df.columns if c.startswith("Gap")])

    # Substitui coluna Custo Alocação Original (ou insere após Custo Heurística)
    if "Custo Alocação Original" in df.columns:
        df["Custo Alocação Original"] = custos_originais
    else:
        idx: int = df.columns.get_loc("Custo Heurística")  # type: ignore[assignment]
        df.insert(idx + 1, "Custo Alocação Original", custos_originais)

    m1d = df["Custo M1 Diário"]
    m1a = df["Custo M1 Anual"]
    m2  = df["Custo M2"]
    heu = df["Custo Heurística"]
    ori = df["Custo Alocação Original"]

    # 7 gaps:
    #   1 para confirmar M1 Anual ≈ M1 Diário
    #   3 comparando M2, Heurística e Original contra M1 Diário (referência)
    #   3 entre si (M2 × Heu, M2 × Ori, Heu × Ori)
    gap_definitions = [
        ("Gap M1 Anual vs M1 Diário (%)",    m1a, m1d),
        ("Gap M2 vs M1 Diário (%)",           m2,  m1d),
        ("Gap Heurística vs M1 Diário (%)",   heu, m1d),
        ("Gap Original vs M1 Diário (%)",     ori, m1d),
        ("Gap Heurística vs M2 (%)",          heu, m2),
        ("Gap Original vs M2 (%)",            ori, m2),
        ("Gap Original vs Heurística (%)",    ori, heu),
    ]

    for col_name, a_series, b_series in gap_definitions:
        df[col_name] = [gap(a, b) for a, b in zip(a_series, b_series)]

    # Salva Excel com formatação
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

    print(f"\nExcel atualizado: {CAMINHO_EXCEL}")
    print(f"Colunas: {list(df.columns)}")


if __name__ == "__main__":
    main()
