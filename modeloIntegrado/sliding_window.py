import os
import subprocess
import pandas as pd
from pathlib import Path

# Configurações Fixas conforme solicitado
JULIA_SCRIPT = "modeloSlidingArgs.jl"
TOTAL_DIAS = 365
WINDOW_SIZE = 45
OVERLAP = 14
PESO_PICO = 0.0
K_CANDIDATOS = 3

def executar_sliding_window():
    path_base = Path(__file__).parent.resolve()
    script_path = path_base / JULIA_SCRIPT
    
    # Nomeação automática: sliding_ndiasjanela_ndiascompartilhados_quantosmananciais
    output_base_name = f"sliding_{WINDOW_SIZE}_{OVERLAP}_{K_CANDIDATOS}"
    output_dir = path_base / output_base_name
    output_dir.mkdir(exist_ok=True)

    volumes_iniciais_path = "nothing"
    pasta_anterior = "nothing"

    dia_inicio = 1
    periodo_count = 1

    while dia_inicio <= TOTAL_DIAS:
        num_dias = min(WINDOW_SIZE, TOTAL_DIAS - dia_inicio + 1)

        pasta_periodo = output_dir / f"periodo_{periodo_count}_dia_{dia_inicio}"
        pasta_periodo.mkdir(exist_ok=True)

        print(f"\n>>> Executando Período {periodo_count}: Dias {dia_inicio} a {dia_inicio + num_dias - 1}")

        # Chamada do Julia com argumentos posicionais:
        # 1: Peso Pico, 2: Pasta, 3: Dia Inicio, 4: Num Dias,
        # 5: Vol Init File, 6: Pasta Anterior, 7: Overlap Dias, 8: K Candidatos
        cmd = [
            "julia", str(script_path),
            str(PESO_PICO),
            str(pasta_periodo),
            str(dia_inicio),
            str(num_dias),
            str(volumes_iniciais_path),
            str(pasta_anterior),
            str(OVERLAP if periodo_count > 1 else 0),
            str(K_CANDIDATOS)
        ]

        try:
            subprocess.run(cmd, check=True, shell=(os.name == 'nt'))

            volumes_todos = pasta_periodo / "volumes_todos_dias.csv"
            if not volumes_todos.exists():
                print(f"    ERRO: O modelo não gerou volumes_todos_dias.csv na pasta {pasta_periodo}.")
                break

            if dia_inicio + num_dias - 1 >= TOTAL_DIAS:
                print(">>> Horizonte total de 365 dias atingido.")
                break

            proximo_dia_inicio = dia_inicio + (WINDOW_SIZE - OVERLAP)
            
            dia_global_ref = proximo_dia_inicio - 1
            dia_local_ref = dia_global_ref - dia_inicio + 1

            df_vol = pd.read_csv(volumes_todos)
            col_name = str(dia_local_ref)

            if col_name in df_vol.columns:
                next_vol_init = pasta_periodo / f"volumes_para_dia_{proximo_dia_inicio}.csv"
                df_next = df_vol[["Beneficiarios", col_name]].copy()
                df_next.columns = ["Beneficiario", "Volume"]
                df_next.to_csv(next_vol_init, index=False)
                volumes_iniciais_path = next_vol_init
            else:
                volumes_iniciais_path = pasta_periodo / "volumes_finais.csv"

            pasta_anterior = pasta_periodo
            dia_inicio = proximo_dia_inicio
            periodo_count += 1

        except subprocess.CalledProcessError as e:
            print(f"    ERRO ao executar Julia no período {periodo_count}: {e}")
            break

    print(f"\n>>> Processo finalizado com {periodo_count} períodos.")
    consolidar_resultados(output_dir, periodo_count)
    gerar_controle(output_dir, K_CANDIDATOS)


def consolidar_resultados(output_dir, num_periodos):
    print("\n>>> Consolidando resultados globais...")
    df_abast_global = None
    df_aloc_global = None

    for p in range(1, num_periodos + 1):
        pastas = list(output_dir.glob(f"periodo_{p}_dia_*"))
        if not pastas: continue
        pasta = pastas[0]
        dia_ini_global = int(pasta.name.split("_")[-1])

        file_abast = pasta / "abastecimento_melhor_absoluto.csv"
        file_aloc = pasta / "alocacao_melhor_absoluto.csv"

        if not file_abast.exists(): continue

        df_a = pd.read_csv(file_abast)
        df_l = pd.read_csv(file_aloc)

        if df_abast_global is None:
            df_abast_global = df_a[["Beneficiarios"]].copy()
            df_aloc_global = df_l[["Beneficiarios"]].copy()

        for col in df_a.columns:
            if col == "Beneficiarios": continue
            dia_local = int(col)
            dia_global = dia_ini_global + dia_local - 1
            df_abast_global[str(dia_global)] = df_a[col]
            df_aloc_global[str(dia_global)] = df_l[col]

    if df_abast_global is not None:
        cols = ["Beneficiarios"] + sorted([c for c in df_abast_global.columns if c != "Beneficiarios"], key=int)
        df_abast_global = df_abast_global[cols]
        df_aloc_global = df_aloc_global[cols]
        df_abast_global.to_csv(output_dir / "abastecimento_GLOBAL.csv", index=False)
        df_aloc_global.to_csv(output_dir / "alocacao_GLOBAL.csv", index=False)

def gerar_controle(output_dir, k_candidatos):
    print("\n>>> Gerando planilha de controle...")
    try:
        import numpy as np
        path_raiz = Path(__file__).parent.parent.resolve()
        
        try:
            df_rotas = pd.read_csv(path_raiz / "alocacao" / "Dados" / "rotas")
            distancias = df_rotas['distance_w_factor'].values.reshape(92, 3315)
        except Exception as e:
            print(f"Erro ao carregar rotas: {e}")
            return

        df_abast = pd.read_csv(output_dir / "abastecimento_GLOBAL.csv")
        df_aloc = pd.read_csv(output_dir / "alocacao_GLOBAL.csv")
        
        beneficiarios = df_abast["Beneficiarios"].values
        dias_cols = [c for c in df_abast.columns if c != "Beneficiarios"]
        
        total_entregas = df_abast[dias_cols].sum().sum()
        somas_diarias = df_abast[dias_cols].sum(axis=0)
        maior_pico = somas_diarias.max()
        
        custo_total = 0.0
        rank_counts = {i: 0 for i in range(1, k_candidatos + 1)}
        
        for idx, b_id in enumerate(beneficiarios):
            b_idx = int(b_id) - 1
            dists_b = distancias[:, b_idx]
            rank_map = {m: r+1 for r, m in enumerate(np.argsort(dists_b) + 1)}
            
            for dia in dias_cols:
                qtd = df_abast.loc[idx, dia]
                fonte = df_aloc.loc[idx, dia]
                if qtd > 0 and fonte > 0:
                    custo_total += dists_b[int(fonte) - 1] * qtd
                    rank = rank_map.get(int(fonte), 999)
                    if rank <= k_candidatos:
                        rank_counts[rank] += 1
        
        resumo = {
            "Metrica": ["Total Entregas", "Custo Real Global", "Maior Pico Abastecimento"],
            "Valor": [total_entregas, custo_total, maior_pico]
        }
        for r in range(1, k_candidatos + 1):
            resumo["Metrica"].append(f"Escolhas Fonte {r}ª mais próxima")
            resumo["Valor"].append(rank_counts[r])
            
        df_resumo = pd.DataFrame(resumo)
        df_resumo.to_excel(output_dir / "controle_sliding.xlsx", index=False)
        print(f">>> Controle salvo em {output_dir / 'controle_sliding.xlsx'}")
    except Exception as e:
        print(f"Erro ao gerar controle: {e}")

if __name__ == "__main__":
    executar_sliding_window()
