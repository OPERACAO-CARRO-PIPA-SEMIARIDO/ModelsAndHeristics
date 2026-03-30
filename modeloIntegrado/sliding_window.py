import os
import subprocess
import pandas as pd
from pathlib import Path

# Configurações
JULIA_SCRIPT = "modeloSlidingArgs.jl"
TOTAL_DIAS = 365
WINDOW_SIZE = 90
OVERLAP = 14
PESO_PICO = 0.0
OUTPUT_BASE = "resultados_sliding_90_14"


def executar_sliding_window():
    path_base = Path(__file__).parent.resolve()
    script_path = path_base / JULIA_SCRIPT
    output_dir = path_base / OUTPUT_BASE
    output_dir.mkdir(exist_ok=True)

    volumes_iniciais_path = "nothing"
    pasta_anterior = "nothing"

    dia_inicio = 1
    periodo_count = 1

    while dia_inicio <= TOTAL_DIAS:
        num_dias = min(WINDOW_SIZE, TOTAL_DIAS - dia_inicio + 1)

        pasta_periodo = output_dir / \
            f"periodo_{periodo_count}_dia_{dia_inicio}"
        pasta_periodo.mkdir(exist_ok=True)

        print(
            f"\n>>> Executando Período {periodo_count}: Dias {dia_inicio} a {dia_inicio + num_dias - 1}")

        # Chamada do Julia:
        # 1: Peso Pico, 2: Pasta, 3: Dia Inicio, 4: Num Dias,
        # 5: Vol Init File, 6: Pasta Anterior (Warm Start), 7: Overlap Dias
        cmd = [
            "julia", str(script_path),
            str(PESO_PICO),
            str(pasta_periodo),
            str(dia_inicio),
            str(num_dias),
            str(volumes_iniciais_path),
            str(pasta_anterior),
            str(OVERLAP if periodo_count > 1 else 0)
        ]

        try:
            # Executa o modelo para o período atual
            subprocess.run(cmd, check=True, shell=(os.name == 'nt'))

            # Verifica se houve solução antes de prosseguir
            volumes_todos = pasta_periodo / "volumes_todos_dias.csv"
            if not volumes_todos.exists():
                print(
                    f"    ERRO: O modelo não gerou volumes_todos_dias.csv. Provável infactibilidade ou erro no solver.")
                break

            # Prepara para o próximo período
            proximo_dia_inicio = dia_inicio + (WINDOW_SIZE - OVERLAP)
            if proximo_dia_inicio > TOTAL_DIAS:
                print(">>> Fim do horizonte total atingido.")
                break

            # O dia de referência para o volume inicial do próximo período é (proximo_dia_inicio - 1).
            # No período atual, esse dia global G corresponde ao dia local L = G - dia_inicio + 1.
            dia_global_ref = proximo_dia_inicio - 1
            dia_local_ref = dia_global_ref - dia_inicio + 1

            df_vol = pd.read_csv(volumes_todos)
            # O arquivo tem colunas "Beneficiarios", "0", "1", "2", ...
            col_name = str(dia_local_ref)

            if col_name in df_vol.columns:
                next_vol_init = pasta_periodo / \
                    f"volumes_para_dia_{proximo_dia_inicio}.csv"
                df_next = df_vol[["Beneficiarios", col_name]].copy()
                df_next.columns = ["Beneficiario", "Volume"]
                df_next.to_csv(next_vol_init, index=False)
                volumes_iniciais_path = next_vol_init
                print(
                    f"    Volumes para o dia {proximo_dia_inicio} extraídos com sucesso (Local: {col_name}).")
            else:
                print(
                    f"    AVISO: Coluna local {col_name} não encontrada. Usando volumes_finais.csv como fallback.")
                volumes_iniciais_path = pasta_periodo / "volumes_finais.csv"

            pasta_anterior = pasta_periodo
            dia_inicio = proximo_dia_inicio
            periodo_count += 1

        except subprocess.CalledProcessError as e:
            print(
                f"    ERRO ao executar Julia no período {periodo_count}: {e}")
            break

    print(
        f"\n>>> Processo de Sliding Window finalizado com {periodo_count - 1} períodos.")
    consolidar_resultados(output_dir, periodo_count - 1)


def consolidar_resultados(output_dir, num_periodos):
    print("\n>>> Consolidando resultados globais...")

    df_abast_global = None
    df_aloc_global = None

    # Dicionário para mapear Dia Global -> Coluna do Período
    # Vamos construir o calendário dia a dia
    for p in range(1, num_periodos + 1):
        # Encontra a pasta do período
        pastas = list(output_dir.glob(f"periodo_{p}_dia_*"))
        if not pastas:
            continue
        pasta = pastas[0]

        dia_ini_global = int(pasta.name.split("_")[-1])

        file_abast = pasta / "abastecimento_melhor_absoluto.csv"
        file_aloc = pasta / "alocacao_melhor_absoluto.csv"

        if not file_abast.exists():
            continue

        df_a = pd.read_csv(file_abast)
        df_l = pd.read_csv(file_aloc)

        # As colunas são "Beneficiarios", "1", "2", ...
        # Dia local L do período P corresponde ao dia global G = dia_ini_global + L - 1

        if df_abast_global is None:
            # Inicializa com a coluna de beneficiários
            df_abast_global = df_a[["Beneficiarios"]].copy()
            df_aloc_global = df_l[["Beneficiarios"]].copy()

        for col in df_a.columns:
            if col == "Beneficiarios":
                continue

            dia_local = int(col)
            dia_global = dia_ini_global + dia_local - 1

            # Se o dia global já existe, ele será sobrescrito pelo período mais recente (Sliding logic)
            df_abast_global[str(dia_global)] = df_a[col]
            df_aloc_global[str(dia_global)] = df_l[col]

    if df_abast_global is not None:
        # Ordenar colunas numericamente
        cols = ["Beneficiarios"] + \
            sorted([c for c in df_abast_global.columns if c !=
                   "Beneficiarios"], key=int)
        df_abast_global = df_abast_global[cols]
        df_aloc_global = df_aloc_global[cols]

        df_abast_global.to_csv(
            output_dir / "abastecimento_GLOBAL.csv", index=False)
        df_aloc_global.to_csv(output_dir / "alocacao_GLOBAL.csv", index=False)
        print(f">>> Resultados globais salvos em {output_dir}")
        print(
            f"    - abastecimento_GLOBAL.csv ({len(df_abast_global.columns)-1} dias)")
        print(
            f"    - alocacao_GLOBAL.csv ({len(df_aloc_global.columns)-1} dias)")


if __name__ == "__main__":
    executar_sliding_window()
