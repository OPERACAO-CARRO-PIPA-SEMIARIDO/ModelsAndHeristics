using JuMP
using LinearAlgebra
using CSV
using DataFrames
using Gurobi

# ==========================================
# 1. CAMINHOS DOS ARQUIVOS
# ==========================================
# Altere BASE_FILE para o caminho correspondente no seu ambiente
BASE_FILE = "C:/Users/lfeli/Documentos/AlocacaoCarros/ModelsAndHeristics"

ABASTECIMENTO_FILE = BASE_FILE * "/minimizaPicos/resultados10wLim/abastecimento_24h.csv"
ROTAS_FILE = BASE_FILE * "/alocacao/Dados/rotas"
OUTPUT_ALOCACAO = BASE_FILE * "/alocacao/m2_alocacao.csv"
OUTPUT_CUSTO = BASE_FILE * "/alocacao/m2_custo.csv"

# ==========================================
# 2. LEITURA E PREPARAÇÃO DOS DADOS
# ==========================================
abastecimento = CSV.read(ABASTECIMENTO_FILE, DataFrame, header=true)
rotas = CSV.read(ROTAS_FILE, DataFrame)

# --- VARIÁVEIS DE CONTROLE DE TAMANHO ---
# Altere estes números livremente. O código adaptará as matrizes.
NUM_MANANCIAIS_TESTE = 10 
NUM_BENEFICIARIOS_TESTE = 20
NUM_DIAS_TESTE = 5
CAPACIDADE_MAX_MANANCIAL = 12

# Dimensões originais baseadas na leitura dos arquivos completos
TOTAL_MANANCIAIS_BASE = 92
TOTAL_BENEFICIARIOS_BASE = size(abastecimento, 1)

# Extração e redimensionamento SEGURO da matriz de distâncias
distancias = rotas.distance_w_factor
# 1º: Remonta a matriz no tamanho original completo para garantir alinhamento
Dij_completa = reshape(distancias, (TOTAL_MANANCIAIS_BASE, TOTAL_BENEFICIARIOS_BASE))
# 2º: Recorta apenas a fatia exata configurada nas variáveis de teste acima
Dij = Dij_completa[1:NUM_MANANCIAIS_TESTE, 1:NUM_BENEFICIARIOS_TESTE]

# Recorta a matriz de demanda limitando o número de beneficiários e os dias (+1 para pular a coluna de ID)
Ajk = Matrix{Float64}(abastecimento[1:NUM_BENEFICIARIOS_TESTE, 2:(NUM_DIAS_TESTE + 1)])

# ==========================================
# 3. MODELO MATEMÁTICO (M2 - Fonte Única Anual)
# ==========================================
function resolve_M2(NM, NB, ND, matriz_dist, matriz_demanda, cap_max)
    linModel = Model(Gurobi.Optimizer)
    
    # Variáveis
    @variable(linModel, 0 <= x[i=1:NM, j=1:NB, k=1:ND], Int) # Quantidade entregue
    @variable(linModel, y[i=1:NM, j=1:NB], Bin)              # 1 se fonte i atende beneficiário j

    # Restrição 1: Limite de extração diária do manancial
    @constraint(linModel, cap_diaria[i=1:NM, k=1:ND], sum(x[i,j,k] for j in 1:NB) <= cap_max)

    # Restrição 2: Atendimento da demanda do dia
    @constraint(linModel, atende_dem[j=1:NB, k=1:ND], sum(x[i,j,k] for i in 1:NM) == matriz_demanda[j,k])

    # Restrição 3: Fonte Única
    @constraint(linModel, fonte_unica[j=1:NB], sum(y[i,j] for i in 1:NM) == 1)

    # Restrição 4: Amarração
    @constraint(linModel, amarra_x_y[i=1:NM, j=1:NB, k=1:ND], x[i,j,k] <= matriz_demanda[j,k] * y[i,j])

    # Função Objetivo
    @objective(linModel, Min, sum(sum(sum(matriz_dist[i,j] * x[i,j,k] for j in 1:NB) for i in 1:NM) for k in 1:ND))

    tempo_inicio = time()
    optimize!(linModel)
    tempo_fim = time()

    return value.(y), objective_value(linModel), num_variables(linModel), (tempo_fim - tempo_inicio)
end

# ==========================================
# 4. EXECUÇÃO E GERAÇÃO DAS SAÍDAS
# ==========================================
println("Iniciando M2 - Modelo de Fonte Única Anual...")
y_opt, custo_total, num_vars, tempo_exec = resolve_M2(NUM_MANANCIAIS_TESTE, NUM_BENEFICIARIOS_TESTE, NUM_DIAS_TESTE, Dij, Ajk, CAPACIDADE_MAX_MANANCIAL)

# O DataFrame de alocação de saída agora também é reduzido para bater com os testes
df_alocacao = copy(abastecimento[1:NUM_BENEFICIARIOS_TESTE, 1:(NUM_DIAS_TESTE + 1)])

for j in 1:NUM_BENEFICIARIOS_TESTE
    fonte_escolhida = 0
    # Descobre qual manancial foi designado para o beneficiário
    for i in 1:NUM_MANANCIAIS_TESTE
        if y_opt[i,j] > 0.5
            fonte_escolhida = i
            break
        end
    end
    
    for k in 1:NUM_DIAS_TESTE
        if Ajk[j, k] > 0
            df_alocacao[j, k + 1] = fonte_escolhida
        else
            df_alocacao[j, k + 1] = 0
        end
    end
end

df_metricas = DataFrame(
    Tempo_de_Execucao = [tempo_exec], 
    Solucao_otima = [custo_total], 
    Num_Variaveis = [num_vars]
)

# Exportação
CSV.write(OUTPUT_CUSTO, df_metricas)
CSV.write(OUTPUT_ALOCACAO, df_alocacao)

println("\nFinalizado!")
println("Custo Total Anual: ", custo_total)
println("Tempo de Execução: ", round(tempo_exec, digits=2), " segundos")
