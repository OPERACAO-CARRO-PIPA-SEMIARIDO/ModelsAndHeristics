import os
import subprocess
import pandas as pd
import numpy as np
from pathlib import Path

# ==========================================
# CONFIGURAÇÃO — edite aqui para mudar o teste
# ==========================================
PASTA_BASE   = Path("C:/Users/lfeli/Documents/AlocacaoCarros/ModelsAndHeristics/modeloIntegrado")
PASTA_SAIDAS = PASTA_BASE
JULIA_SCRIPT = PASTA_BASE / "modeloSlidingArgs.jl"
ROTAS_FILE   = PASTA_BASE.parent / "alocacao" / "Dados" / "rotas"
TOTAL_DIAS   = 365
PESO_PICO    = 0.0
K_CANDIDATOS = 3

# Modelo integrado: janela única cobrindo todo o período (uma só chamada ao solver)
INTEGRADO_NB = 1250
INTEGRADO_NM = 40

# Rolling horizon (sliding window com sobreposição)
# "X-X" = janela de X dias, passo de X dias (sobreposicao = 0)
# Para adicionar sobreposição: aumente "sobreposicao" e a janela cresce por janela = passo + sobreposicao
ROLLING_CONFIGS = [
    {"janela": 60,  "sobreposicao": 0, "nb": 3315, "nm": 92},
    {"janela": 90,  "sobreposicao": 0, "nb": 3315, "nm": 92},
    {"janela": 120, "sobreposicao": 0, "nb": 3315, "nm": 92},
]


# ==========================================
# CONSOLIDAÇÃO E CONTROLE
# ==========================================

def consolidar_resultados(output_dir, num_periodos):
    print(f"\n>>> Consolidando resultados em {output_dir}...")
    df_abast_global = None
    df_aloc_global = None

    for p in range(1, num_periodos + 2):
        pastas = list(output_dir.glob(f"periodo_{p}_dia_*"))
        if not pastas:
            continue
        pasta = pastas[0]
        try:
            dia_ini_global = int(pasta.name.split("_")[-1])
        except Exception:
            continue

        file_abast = pasta / "abastecimento_melhor_absoluto.csv"
        file_aloc  = pasta / "alocacao_melhor_absoluto.csv"
        if not file_abast.exists():
            continue

        df_a = pd.read_csv(file_abast)
        df_l = pd.read_csv(file_aloc)

        if df_abast_global is None:
            df_abast_global = df_a[["Beneficiarios"]].copy()
            df_aloc_global  = df_l[["Beneficiarios"]].copy()

        cols_locais = sorted([c for c in df_a.columns if c.isdigit()], key=int)
        for col in cols_locais:
            dia_global = dia_ini_global + int(col) - 1
            df_abast_global[str(dia_global)] = df_a[col].values
            df_aloc_global[str(dia_global)]  = df_l[col].values

    if df_abast_global is not None:
        cols = ["Beneficiarios"] + sorted(
            [c for c in df_abast_global.columns if c != "Beneficiarios"], key=int)
        df_abast_global = df_abast_global[cols]
        df_aloc_global  = df_aloc_global[cols]
        df_abast_global.to_csv(output_dir / "abastecimento_GLOBAL.csv", index=False)
        df_aloc_global.to_csv(output_dir / "alocacao_GLOBAL.csv", index=False)
        print(f"    Arquivos GLOBAL salvos.")


def gerar_controle(output_dir, k_candidatos=K_CANDIDATOS, nm_usado=92):
    print(f"\n>>> Gerando planilha de controle em {output_dir}...")
    try:
        df_rotas   = pd.read_csv(ROTAS_FILE)
        NM_ARQ     = 92
        NB_ARQ     = len(df_rotas) // NM_ARQ
        distancias = df_rotas['distance_w_factor'].values.reshape(NM_ARQ, NB_ARQ)
        distancias = distancias[:nm_usado, :]  # só os mananciais usados no teste

        df_abast = pd.read_csv(output_dir / "abastecimento_GLOBAL.csv")
        df_aloc  = pd.read_csv(output_dir / "alocacao_GLOBAL.csv")

        beneficiarios = df_abast["Beneficiarios"].values
        dias_cols = [c for c in df_abast.columns if c != "Beneficiarios"]

        total_entregas = df_abast[dias_cols].sum().sum()
        maior_pico     = df_abast[dias_cols].sum(axis=0).max()
        custo_total    = 0.0
        rank_counts    = {i: 0 for i in range(1, k_candidatos + 1)}

        for idx, b_id in enumerate(beneficiarios):
            b_idx   = int(b_id) - 1
            dists_b = distancias[:, b_idx]
            rank_map = {m: r + 1 for r, m in enumerate(np.argsort(dists_b) + 1)}
            for dia in dias_cols:
                qtd   = df_abast.loc[idx, dia]
                fonte = df_aloc.loc[idx, dia]
                if qtd > 0 and fonte > 0:
                    custo_total += dists_b[int(fonte) - 1] * qtd
                    rank = rank_map.get(int(fonte), 999)
                    if rank <= k_candidatos:
                        rank_counts[rank] += 1

        resumo = {
            "Metrica": ["Total Entregas", "Custo Real Global", "Maior Pico Abastecimento"],
            "Valor":   [total_entregas, custo_total, maior_pico],
        }
        for r in range(1, k_candidatos + 1):
            resumo["Metrica"].append(f"Escolhas Fonte {r}a mais proxima")
            resumo["Valor"].append(rank_counts[r])

        pd.DataFrame(resumo).to_excel(output_dir / "controle_sliding.xlsx", index=False)
        print(f"    Controle salvo.")
    except Exception as e:
        print(f"    Erro ao gerar controle: {e}")


# ==========================================
# EXECUTOR DE JANELA (SLIDING WINDOW CORE)
# ==========================================

def executar_janela(janela, sobreposicao, nb, nm, pasta_saida):
    """Executa o rolling horizon (sliding window) com os parâmetros dados."""
    pasta_saida = Path(pasta_saida)
    pasta_saida.mkdir(parents=True, exist_ok=True)

    passo                = janela - sobreposicao
    volumes_iniciais_path = "nothing"
    pasta_anterior        = "nothing"
    dia_inicio            = 1
    periodo_count         = 1

    while dia_inicio <= TOTAL_DIAS:
        num_dias      = min(janela, TOTAL_DIAS - dia_inicio + 1)
        pasta_periodo = pasta_saida / f"periodo_{periodo_count}_dia_{dia_inicio}"
        pasta_periodo.mkdir(exist_ok=True)

        print(f"\n  Período {periodo_count}: dias {dia_inicio} a {dia_inicio + num_dias - 1}")

        cmd = [
            "julia", str(JULIA_SCRIPT),
            str(PESO_PICO),
            str(pasta_periodo),
            str(dia_inicio),
            str(num_dias),
            str(volumes_iniciais_path),
            str(pasta_anterior),
            str(sobreposicao if periodo_count > 1 else 0),
            str(K_CANDIDATOS),
            str(nb),
            str(nm),
        ]

        try:
            subprocess.run(cmd, check=True, shell=(os.name == 'nt'))
        except subprocess.CalledProcessError as e:
            print(f"    ERRO ao executar Julia: {e}")
            break

        volumes_todos = pasta_periodo / "volumes_todos_dias.csv"
        if not volumes_todos.exists():
            print("    ERRO: volumes_todos_dias.csv não gerado.")
            break

        if dia_inicio + num_dias - 1 >= TOTAL_DIAS:
            break

        # Prepara volumes iniciais para o próximo período
        proximo_dia  = dia_inicio + passo
        dia_local_ref = passo  # = dia na janela atual cujos volumes passam adiante

        df_vol   = pd.read_csv(volumes_todos)
        col_name = str(dia_local_ref)

        if col_name in df_vol.columns:
            next_vol = pasta_periodo / f"volumes_para_dia_{proximo_dia}.csv"
            df_next  = df_vol[["Beneficiarios", col_name]].copy()
            df_next.columns = ["Beneficiario", "Volume"]
            df_next.to_csv(next_vol, index=False)
            volumes_iniciais_path = next_vol
        else:
            volumes_iniciais_path = pasta_periodo / "volumes_finais.csv"

        pasta_anterior = pasta_periodo
        dia_inicio     = proximo_dia
        periodo_count += 1

    consolidar_resultados(pasta_saida, periodo_count)
    gerar_controle(pasta_saida, K_CANDIDATOS, nm_usado=nm)


# ==========================================
# MAIN
# ==========================================

def main():
    # --- 1. Modelo integrado (janela única = ano inteiro) ---
    print("\n" + "=" * 60)
    print(f"MODELO INTEGRADO: {INTEGRADO_NB} beneficiários, {INTEGRADO_NM} mananciais, {TOTAL_DIAS} dias")
    pasta_int = PASTA_SAIDAS / f"integrado_{INTEGRADO_NB}nb_{INTEGRADO_NM}nm"
    executar_janela(TOTAL_DIAS, 0, INTEGRADO_NB, INTEGRADO_NM, pasta_int)

    # --- 2. Rolling horizon com diferentes janelas ---
    for cfg in ROLLING_CONFIGS:
        j = cfg["janela"]
        s = cfg["sobreposicao"]
        nb = cfg["nb"]
        nm = cfg["nm"]
        passo = j - s
        tag   = f"rolling_{j}_{passo}"

        print("\n" + "=" * 60)
        print(f"ROLLING HORIZON: janela={j}, sobreposicao={s}, passo={passo}, nb={nb}, nm={nm}")
        executar_janela(j, s, nb, nm, PASTA_SAIDAS / tag)

    print("\n>>> Todos os testes concluídos.")


if __name__ == "__main__":
    main()
