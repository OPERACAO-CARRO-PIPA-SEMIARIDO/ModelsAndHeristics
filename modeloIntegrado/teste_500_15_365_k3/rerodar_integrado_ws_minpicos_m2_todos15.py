import subprocess
from pathlib import Path


TEST_DIR = Path(r"C:\Users\lfeli\Documents\AlocacaoCarros\ModelsAndHeristics\modeloIntegrado\teste_500_15_365_k3")
SCRIPT_MODELO_INTEGRADO = TEST_DIR / "modeloIntegrado_ws_500_15_72h.jl"

WS_ABAST = TEST_DIR / "resultados_minpicos_p00" / "abastecimento_melhor_absoluto.csv"
WS_ALOC = TEST_DIR / "alocacao_m2_minpicos_p00.csv"
OUTPUT_DIR = "resultados_500_15_365_24h_ws_minpicos_m2_todos15"
MAX_HORAS = "24"
NUM_CANDIDATOS = "15"


def main():
    if not WS_ABAST.exists():
        raise FileNotFoundError(f"Warm start de abastecimento nao encontrado: {WS_ABAST}")
    if not WS_ALOC.exists():
        raise FileNotFoundError(f"Warm start de alocacao nao encontrado: {WS_ALOC}")

    cmd = [
        "julia",
        str(SCRIPT_MODELO_INTEGRADO),
        OUTPUT_DIR,
        str(WS_ABAST),
        str(WS_ALOC),
        MAX_HORAS,
        NUM_CANDIDATOS,
    ]

    print(f"Executando: {' '.join(cmd)}")
    subprocess.run(cmd, cwd=str(TEST_DIR), check=True, shell=False)


if __name__ == "__main__":
    main()
