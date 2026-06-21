import os
import subprocess
from pathlib import Path

import numpy as np
import pandas as pd


REPO_ROOT = Path(r"C:\Users\lfeli\Documents\AlocacaoCarros\ModelsAndHeristics")
DATA_ROOT = Path(r"C:\Users\lfeli\Documents\AlocacaoCarros\dados")
TEST_DIR = REPO_ROOT / "modeloIntegrado" / "teste_500_15_365_k3"

NUM_BENEFICIARIOS = 500
NUM_MANANCIAIS = 15
NUM_DIAS = 365
CAPACIDADE_CAMINHAO = 13.0

ARQUIVO_BENEFICIARIOS = DATA_ROOT / "Beneficiarios_RN_Ativos1.csv"
ARQUIVO_DATAS = DATA_ROOT / "datas.csv"
ARQUIVO_CALENDARIOS = DATA_ROOT / "CalendariosObrigatorios.csv"
ARQUIVO_ROTAS = DATA_ROOT / "rotas"

HEURISTICA_ALOCACAO = REPO_ROOT / "alocacao" / "heuristicaAlocacaoArgs.py"
SCRIPT_MINPICOS = TEST_DIR / "minimizaPicos_500_365_p00.jl"
SCRIPT_M2 = TEST_DIR / "m2_minpicos_500_15.jl"
SCRIPT_MODELO_INTEGRADO = TEST_DIR / "modeloIntegrado_ws_500_15_72h.jl"


def localizar_abastecimento_minpicos() -> Path:
    candidatos = [
        TEST_DIR / "resultados_minpicos_p00" / "abastecimento_melhor_absoluto.csv",
        TEST_DIR / "resultados_minpicos_p00" / "abastecimento_24h.csv",
        TEST_DIR / "resultados_minpicos_p00" / "abastecimento_21h.csv",
        TEST_DIR / "resultados_minpicos_p00" / "abastecimento_18h.csv",
        TEST_DIR / "resultados_minpicos_p00" / "abastecimento_15h.csv",
        TEST_DIR / "resultados_minpicos_p00" / "abastecimento_12h.csv",
        TEST_DIR / "resultados_minpicos_p00" / "abastecimento_9h.csv",
        TEST_DIR / "resultados_minpicos_p00" / "abastecimento_6h.csv",
        TEST_DIR / "resultados_minpicos_p00" / "abastecimento_3h.csv",
    ]

    for caminho in candidatos:
        if caminho.exists():
            return caminho

    raise FileNotFoundError("Nenhum arquivo de abastecimento do minimizaPicos foi encontrado.")


def run_command(cmd, cwd=TEST_DIR):
    print(f"\n>>> Executando: {' '.join(str(part) for part in cmd)}")
    subprocess.run(cmd, cwd=str(cwd), check=True, shell=(os.name == "nt"))


def gerar_calendario_heuristico(modo: str) -> Path:
    beneficiarios = pd.read_csv(ARQUIVO_BENEFICIARIOS).head(NUM_BENEFICIARIOS)
    dias_uteis = pd.read_csv(ARQUIVO_DATAS).head(NUM_DIAS)
    calendarios = pd.read_csv(ARQUIVO_CALENDARIOS).head(NUM_DIAS)

    consumo_diario = (beneficiarios["Pessoas_Atendidas"] * 0.02).round(2).values
    capacidade_cisterna = beneficiarios["Capacidade"].values.astype(float)

    autonomia = capacidade_cisterna / consumo_diario
    quebra4 = autonomia < 5
    quebra2 = autonomia < 3

    is_dia_util = dias_uteis.iloc[:, 0].values == 1
    carnaval_obrigatorio = calendarios["carnaval"].values == 1
    lil_obrigatorio = calendarios["lil"].values == 1

    entregas = np.zeros((NUM_BENEFICIARIOS, NUM_DIAS), dtype=int)
    volume_atual = capacidade_cisterna.copy()

    for k in range(NUM_DIAS):
        volume_atual -= consumo_diario
        entregas_hoje = np.zeros(NUM_BENEFICIARIOS, dtype=int)

        if is_dia_util[k]:
            cond_obrigatoria = (carnaval_obrigatorio[k] & quebra4) | (lil_obrigatorio[k] & quebra2)
            entregas_hoje = np.where(cond_obrigatoria, 1, 0)

            if modo == "full":
                espaco_livre = capacidade_cisterna - (volume_atual + entregas_hoje * CAPACIDADE_CAMINHAO)
                caminhoes_extras = np.maximum(0, espaco_livre // CAPACIDADE_CAMINHAO)
                entregas_hoje += caminhoes_extras.astype(int)

            nao_uteis_consecutivos = 0
            idx_check = k + 1
            while idx_check < NUM_DIAS and not is_dia_util[idx_check]:
                nao_uteis_consecutivos += 1
                idx_check += 1

            consumo_ate_proximo_util = consumo_diario * (1 + nao_uteis_consecutivos)
            volume_projetado = volume_atual + (entregas_hoje * CAPACIDADE_CAMINHAO)
            precisa_emergencia = volume_projetado < consumo_ate_proximo_util
            entregas_hoje = np.where(precisa_emergencia, entregas_hoje + 1, entregas_hoje)

        volume_atual += entregas_hoje * CAPACIDADE_CAMINHAO
        volume_atual = np.clip(volume_atual, 0, capacidade_cisterna)
        entregas[:, k] = entregas_hoje

    df_saida = pd.DataFrame(entregas, columns=range(1, NUM_DIAS + 1))
    df_saida.insert(0, "Beneficiarios", beneficiarios.index + 1)

    output = TEST_DIR / f"abastecimento_heu_{modo}.csv"
    df_saida.to_csv(output, index=False)
    print(f"Calendario heuristico salvo: {output}")
    return output


def rodar_heuristica_alocacao(caminho_abastecimento: Path, sufixo: str) -> None:
    output_aloc = TEST_DIR / f"alocacao_heu_{sufixo}.csv"
    output_custos = TEST_DIR / f"custos_heu_{sufixo}.csv"

    run_command([
        "python",
        str(HEURISTICA_ALOCACAO),
        str(caminho_abastecimento),
        str(output_aloc),
        str(output_custos),
        str(ARQUIVO_ROTAS),
        str(NUM_MANANCIAIS),
    ], cwd=REPO_ROOT)


def main():
    TEST_DIR.mkdir(parents=True, exist_ok=True)

    print("=== Etapa 1: heuristicas de calendario ===")
    caminho_full = gerar_calendario_heuristico("full")
    caminho_limite = gerar_calendario_heuristico("limite")

    print("=== Etapa 2: heuristica de alocacao ===")
    rodar_heuristica_alocacao(caminho_full, "full")
    rodar_heuristica_alocacao(caminho_limite, "limite")

    print("=== Etapa 3: minimizaPicos p=0.00 ===")
    run_command(["julia", str(SCRIPT_MINPICOS)])

    abastecimento_minpicos = localizar_abastecimento_minpicos()
    print(f"Arquivo escolhido para a etapa 4: {abastecimento_minpicos}")

    print("=== Etapa 4: m2 sobre o melhor calendario do minimizaPicos ===")
    run_command(["julia", str(SCRIPT_M2)])

    print("=== Etapa 5: modelo integrado com warm start e limite de 72h ===")
    run_command(["julia", str(SCRIPT_MODELO_INTEGRADO)])

    print("\nFluxo concluido.")


if __name__ == "__main__":
    main()
