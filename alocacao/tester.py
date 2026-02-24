import pandas as pd
from pathlib import Path
import time
import subprocess

# ==========================================
# 1. DEFINIÇÃO DE CAMINHOS BASE (Dinâmico)
# ==========================================
PASTA_BASE = Path(__file__).parent.resolve()
PASTA_ENTRADAS = PASTA_BASE / "entradas"
PASTA_SAIDAS = PASTA_BASE / "saidas"

# Assumindo que a pasta Dados está na raiz do projeto (ajuste se necessário)
ARQUIVO_ROTAS = PASTA_BASE / "Dados" / "rotas"

PASTA_SAIDAS.mkdir(parents=True, exist_ok=True)

def executar_automacao():
    dados_planilha = []

    arquivos_entrada = list(PASTA_ENTRADAS.glob("*.csv"))

    if not arquivos_entrada:
        print("Nenhum arquivo CSV encontrado na pasta 'entradas'.")
        return

    for caminho_arquivo in arquivos_entrada:
        nome_entrada = caminho_arquivo.stem 
        print(f"\n[{time.strftime('%H:%M:%S')}] Processando: {nome_entrada}...")
        
        # 1. Tratamento do separador e do índice
        df_entrada = pd.read_csv(caminho_arquivo, sep=',', index_col=0) 
        total_entregas = len(df_entrada) 
        
        pasta_alocacao = PASTA_SAIDAS / f"alocacao_{nome_entrada}"
        pasta_alocacao.mkdir(parents=True, exist_ok=True)
        
        # Define os caminhos de saída exatos para esta instância
        caminho_aloc_m1 = pasta_alocacao / "alocacao_m1.csv"
        caminho_custo_m1 = pasta_alocacao / "custos_m1.csv"
        
        caminho_aloc_heu = pasta_alocacao / "alocacao_heu.csv"
        caminho_custo_heu = pasta_alocacao / "custos_heu.csv"

        # 2. Blindagem contra falhas do Solver/Modelo
        try:
            # Monta os comandos passando: entrada, saida_alocacao, saida_custos, arquivo_rotas
            cmd_m1 = [
                "julia", str(PASTA_BASE / "m1args.jl"), 
                str(caminho_arquivo.resolve()), 
                str(caminho_aloc_m1.resolve()), 
                str(caminho_custo_m1.resolve()),
                str(ARQUIVO_ROTAS.resolve())
            ]
            
            cmd_heu = [
                "python", str(PASTA_BASE / "HeuristicaAlocacaoArgs.py"), 
                str(caminho_arquivo.resolve()), 
                str(caminho_aloc_heu.resolve()), 
                str(caminho_custo_heu.resolve()),
                str(ARQUIVO_ROTAS.resolve())
            ]
            
            # Executa o modelo em Julia
            print("  -> Rodando Modelo Exato (Julia)...")
            subprocess.run(cmd_m1, capture_output=True, text=True, check=True)
            
            # Executa a Heurística em Python
            print("  -> Rodando Heurística (Python)...")
            subprocess.run(cmd_heu, capture_output=True, text=True, check=True)

            # --- CAPTURA DOS CUSTOS REAIS ---
            # Lê os arquivos gerados e soma a coluna 'Solucao_otima' de todos os dias
            df_custo_m1 = pd.read_csv(caminho_custo_m1)
            custo_m1 = df_custo_m1['Solucao_otima'].sum()

            df_custo_heu = pd.read_csv(caminho_custo_heu)
            custo_heu = df_custo_heu['Solucao_otima'].sum()
            
            status = "Sucesso"
            gap = round(((custo_heu - custo_m1) / custo_m1) * 100, 2) if custo_m1 > 0 else 0.0
            
        except subprocess.CalledProcessError as e:
            print(f"ERRO DE EXECUÇÃO na instância {nome_entrada}.")
            print(f"Detalhes do erro: {e.stderr}") 
            custo_m1 = None
            custo_heu = None
            status = "Erro Execução"
            gap = None       
        except Exception as e:
            print(f"ERRO DE LEITURA DOS RESULTADOS na instância {nome_entrada}: {e}")
            custo_m1 = None
            custo_heu = None
            status = "Erro Leitura"
            gap = None 

        # Guarda os resultados
        dados_planilha.append({
            "Nome da Instância": nome_entrada,
            "Total de Entregas": total_entregas,
            "Status": status,
            "Custo Modelo Exato (M1)": custo_m1,
            "Custo Heurística": custo_heu,
            "Gap (%)": gap,
            "Caminho da Entrada": str(caminho_arquivo.resolve()),
            "Pasta de Saída": str(pasta_alocacao.resolve())
        })

        # 3. Salva um backup CSV a cada iteração
        pd.DataFrame(dados_planilha).to_csv(PASTA_SAIDAS / "backup_temporario.csv", index=False)

    # ==========================================
    # 3. GERAÇÃO DA PLANILHA EXCEL FORMATADA
    # ==========================================
    df_resultados = pd.DataFrame(dados_planilha)
    caminho_planilha = PASTA_SAIDAS / "resumo_custos.xlsx"
    
    with pd.ExcelWriter(caminho_planilha, engine='openpyxl') as writer:
        df_resultados.to_excel(writer, index=False, sheet_name='Resultados_Custos')
        
        worksheet = writer.sheets['Resultados_Custos']
        for col in worksheet.columns:
            max_length = 0
            col_letter = col[0].column_letter
            for cell in col:
                try:
                    if len(str(cell.value)) > max_length:
                        max_length = len(str(cell.value))
                except:
                    pass
            worksheet.column_dimensions[col_letter].width = max_length + 2

    print(f"\nFinalizado! Planilha gerada em: {caminho_planilha}")

if __name__ == "__main__":
    executar_automacao()
