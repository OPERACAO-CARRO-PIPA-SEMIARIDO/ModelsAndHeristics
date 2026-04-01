using JuMP
using LinearAlgebra
using CSV
using DataFrames
using Gurobi

# ==========================================
# 1. LEITURA DOS ARGUMENTOS VIA TERMINAL
# ==========================================
if length(ARGS) < 5
    println("ERRO: Faltam argumentos para o M2.")
    println("Uso: julia m2args.jl <ABASTECIMENTO_CSV> <OUTPUT_ALOCACAO_CSV> <OUTPUT_CUSTO_CSV> <ROTAS_CSV> <NUM_MANANCIAIS>")
    exit(1)
end

ABASTECIMENTO_FILE = ARGS[1]
OUTPUT_ALOCACAO = ARGS[2]
OUTPUT_CUSTO = ARGS[3]
ROTAS_FILE = ARGS[4]
NUM_MANANCIAIS_TESTE = parse(Int, ARGS[5])

# ==========================================
# 2. LEITURA E PREPARAÇÃO DOS DADOS
# ==========================================
abastecimento = CSV.read(ABASTECIMENTO_FILE, DataFrame, header=true)
rotas = CSV.read(ROTAS_FILE, DataFrame)

NUM_DIAS = size(abastecimento, 2) - 1
NUM_MANANCIAIS_TOTAL = 92 # Total no arquivo de rotas
NUM_MANANCIAIS = NUM_MANANCIAIS_TESTE # Limitado para o teste
NUM_BENEFICIARIOS = size(abastecimento, 1)
NB_TOTAL_ROTAS = 3315
CAPACIDADE_MAX_MANANCIAL = 12

distancias = rotas.distance_w_factor
Dij_completa = transpose(reshape(distancias, (NB_TOTAL_ROTAS, NUM_MANANCIAIS_TOTAL)))
Dij = Dij_completa[1:NUM_MANANCIAIS, 1:NUM_BENEFICIARIOS]
Ajk = Matrix{Float64}(abastecimento[:, 2:end])

# ==========================================
# 3. MODELO MATEMÁTICO OTIMIZADO (ESPARSO)
# ==========================================
function resolve_M2(NM, NB, ND, matriz_dist, matriz_demanda, cap_max)
    env = Gurobi.Env()
    linModel = Model(() -> Gurobi.Optimizer(env))
    set_silent(linModel) # Silencia os logs infinitos do solver no terminal do Python
    
    set_time_limit_sec(linModel, 86400.0)
    #set_optimizer_attribute(linModel, "MIPFocus", 1) 
    #set_optimizer_attribute(linModel, "NodefileStart", 4.0) 

    @variable(linModel, 0 <= x[i=1:NM, j=1:NB, k=1:ND; matriz_demanda[j,k] > 0], Int) 
    @variable(linModel, y[i=1:NM, j=1:NB], Bin)              

    @constraint(linModel, cap_diaria[i=1:NM, k=1:ND], sum(x[i,j,k] for j in 1:NB if matriz_demanda[j,k] > 0) <= cap_max)
    @constraint(linModel, atende_dem[j=1:NB, k=1:ND; matriz_demanda[j,k] > 0], sum(x[i,j,k] for i in 1:NM) == matriz_demanda[j,k])
    @constraint(linModel, fonte_unica[j=1:NB], sum(y[i,j] for i in 1:NM) == 1)
    @constraint(linModel, amarra_x_y[i=1:NM, j=1:NB, k=1:ND; matriz_demanda[j,k] > 0], x[i,j,k] <= matriz_demanda[j,k] * y[i,j])

    @objective(linModel, Min, sum(matriz_dist[i,j] * x[i,j,k] for i in 1:NM, j in 1:NB, k in 1:ND if matriz_demanda[j,k] > 0))

    tempo_inicio = time()
    optimize!(linModel)
    tempo_fim = time()
    tempo_exec = tempo_fim - tempo_inicio

    if has_values(linModel)
        return value.(y), objective_value(linModel), num_variables(linModel), tempo_exec, true
    else
        return zeros(Int, NM, NB), 0.0, num_variables(linModel), tempo_exec, false
    end
end

# ==========================================
# 4. EXECUÇÃO E GERAÇÃO DAS SAÍDAS
# ==========================================
y_opt, custo_total, num_vars, tempo_exec, solucao_valida = resolve_M2(NUM_MANANCIAIS, NUM_BENEFICIARIOS, NUM_DIAS, Dij, Ajk, CAPACIDADE_MAX_MANANCIAL)

if solucao_valida
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
else
    # Na automação, não gerar arquivo avisa o Python que algo deu errado
    println("Falha ou timeout. Nenhuma solucao valida para exportar.")
    exit(1)
end
