import os
import subprocess
import pandas as pd
from pathlib import Path

# Configurações
JULIA_SCRIPT = "modeloRollingArgs.jl"
TOTAL_DIAS = 360
DIAS_POR_PERIODO = 90
PESO_PICO = 0.0
OUTPUT_BASE = "resultados_rolling"

def executar_rolling_horizon():
    path_base = Path(__file__).parent.resolve()
    script_path = path_base / JULIA_SCRIPT
    output_dir = path_base / OUTPUT_BASE
    output_dir.mkdir(exist_ok=True)

    volumes_iniciais = None
    
    num_periodos = (TOTAL_DIAS + DIAS_POR_PERIODO - 1) // DIAS_POR_PERIODO

    for i in range(num_periodos):
        dia_inicio = i * DIAS_POR_PERIODO + 1
        # Ajusta o último período se necessário
        dias_restantes = TOTAL_DIAS - dia_inicio + 1
        periodo_atual = min(DIAS_POR_PERIODO, dias_restantes)
        
        pasta_periodo = output_dir / f"periodo_{i+1}_dia_{dia_inicio}"
        pasta_periodo.mkdir(exist_ok=True)
        
        print(f"\n>>> Executando Período {i+1}: Dias {dia_inicio} a {dia_inicio + periodo_atual - 1}")
        
        cmd = [
            "julia", str(script_path),
            str(PESO_PICO),
            str(pasta_periodo),
            str(dia_inicio),
            str(periodo_atual)
        ]
        
        if volumes_iniciais:
            cmd.append(str(volumes_iniciais))
            
        try:
            # shell=True as vezes ajuda no Windows para achar comandos no PATH
            subprocess.run(cmd, check=True, shell=(os.name == 'nt'))
            
            # Atualiza volumes iniciais para o próximo período
            volumes_finais_path = pasta_periodo / "volumes_finais.csv"
            if volumes_finais_path.exists():
                volumes_iniciais = volumes_finais_path
                print(f"    Volumes finais salvos e prontos para o próximo período.")
            else:
                print(f"    AVISO: volumes_finais.csv não encontrado em {pasta_periodo}")
                break
                
        except subprocess.CalledProcessError as e:
            print(f"    ERRO ao executar Julia no período {i+1}: {e}")
            break

    print("\n>>> Teste de Horizonte Rolante Finalizado.")

if __name__ == "__main__":
    executar_rolling_horizon()
