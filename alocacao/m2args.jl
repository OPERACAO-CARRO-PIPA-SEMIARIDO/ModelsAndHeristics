
using JuMP
using LinearAlgebra
using CSV
using DataFrames
using Gurobi

# ==========================================
# 1. LEITURA DOS ARGUMENTOS VIA TERMINAL
# ==========================================
if length(ARGS) < 4
    println("ERRO: Faltam argumentos para o M2.")
    println("Uso: julia m2args.jl <ABASTECIMENTO_CSV> <OUTPUT_ALOCACAO_CSV> <OUTPUT_CUSTO_CSV> <ROTAS_CSV>")
    exit(1)
end

ABASTECIMENTO_FILE = ARGS[1]
OUTPUT_ALOCACAO = ARGS[2]
OUTPUT_CUSTO = ARGS[3]
ROTAS_FILE = ARGS[4]

# ==========================================
# 2. LEITURA E PREPARAÇÃO DOS DADOS
# ==========================================
abastecimento = CSV.read(ABASTECIMENTO_FILE, DataFrame, header=true)
rotas = CSV.read(ROTAS_FILE, DataFrame)

# Na automação, extraímos o tamanho real da instância
NUM_DIAS = size(abastecimento, 2) - 1
NUM_MANANCIAIS = 92 # Mantido fixo conforme seu modelo base
NUM_BENEFICIARIOS = size(abastecimento, 1)
CAPACIDADE_MAX_MANANCIAL = 12

# Preparação das matrizes
distancias = rotas.distance_w_factor
Dij = reshape(distancias, (NUM_MANANCIAIS, NUM_BENEFICIARIOS))
Ajk = Matrix{Float64}(abastecimento[:, 2:end])

# ==========================================
# 3. MODELO MATEMÁTICO (M2 - Fonte Única Anual)
# ==========================================
function resolve_M2(NM, NB, ND, matriz_dist, matriz_demanda, cap_max)
    linModel = Model(Gurobi.Optimizer)
    set_silent(linModel) # Opcional: silencia o log do Gurobi para limpar o terminal do Python
    
    @variable(linModel, 0 <= x[i=1:NM, j=1:NB, k=1:ND], Int)
    @variable(linModel, y[i=1:NM, j=1:NB], Bin)             

    @constraint(linModel, cap_diaria[i=1:NM, k=1:ND], sum(x[i,j,k] for j in 1:NB) <= cap_max)
    @constraint(linModel, atende_dem[j=1:NB, k=1:ND], sum(x[i,j,k] for i in 1:NM) == matriz_demanda[j,k])
    @constraint(linModel, fonte_unica[j=1:NB], sum(y[i,j] for i in 1:NM) == 1)
    @constraint(linModel, amarra_x_y[i=1:NM, j=1:NB, k=1:ND], x[i,j,k] <= matriz_demanda[j,k] * y[i,j])

    @objective(linModel, Min, sum(sum(sum(matriz_dist[i,j] * x[i,j,k] for j in 1:NB) for i in 1:NM) for k in 1:ND))

    tempo_inicio = time()
    optimize!(linModel)
    tempo_fim = time()

    return value.(y), objective_value(linModel), num_variables(linModel), (tempo_fim - tempo_inicio)
end

# ==========================================
# 4. EXECUÇÃO E GERAÇÃO DAS SAÍDAS
# ==========================================
y_opt, custo_total, num_vars, tempo_exec = resolve_M2(NUM_MANANCIAIS, NUM_BENEFICIARIOS, NUM_DIAS, Dij, Ajk, CAPACIDADE_MAX_MANANCIAL)

df_alocacao = copy(abastecimento)

for j in 1:NUM_BENEFICIARIOS
    fonte_escolhida = 0
    for i in 1:NUM_MANANCIAIS
        if y_opt[i,j] > 0.5
            fonte_escolhida = i
            break
        end
    end
    
    for k in 1:NUM_DIAS
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

CSV.write(OUTPUT_CUSTO, df_metricas)
CSV.write(OUTPUT_ALOCACAO, df_alocacao)
