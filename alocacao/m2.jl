using JuMP
using LinearAlgebra
using CSV
using DataFrames
using Gurobi

# ==========================================
# 1. CAMINHOS DOS ARQUIVOS
# ==========================================
BASE_FILE = "C:/Users/lfeli/Documents/AlocacaoCarros/ModelsAndHeristics"

ABASTECIMENTO_FILE = BASE_FILE * "/minimizaPicos/resultados00_150/abastecimento_1min.csv"
ROTAS_FILE = BASE_FILE * "/alocacao/Dados/rotas"
OUTPUT_ALOCACAO = BASE_FILE * "/alocacao/m2/m2_00_150_alocacao.csv"
OUTPUT_CUSTO = BASE_FILE * "/alocacao/m2/m2_10_150_custo.csv"

# ==========================================
# 2. LEITURA E PREPARAÇÃO DOS DADOS
# ==========================================
abastecimento = CSV.read(ABASTECIMENTO_FILE, DataFrame, header=true)
rotas = CSV.read(ROTAS_FILE, DataFrame)

NUM_MANANCIAIS_TESTE = 92 
NUM_BENEFICIARIOS_TESTE = 3315
NUM_DIAS_TESTE = 150
CAPACIDADE_MAX_MANANCIAL = 12

TOTAL_MANANCIAIS_BASE = 92
TOTAL_BENEFICIARIOS_BASE = size(abastecimento, 1)

distancias = rotas.distance_w_factor
Dij_completa = reshape(distancias, (TOTAL_MANANCIAIS_BASE, TOTAL_BENEFICIARIOS_BASE))
Dij = Dij_completa[1:NUM_MANANCIAIS_TESTE, 1:NUM_BENEFICIARIOS_TESTE]

Ajk = Matrix{Float64}(abastecimento[1:NUM_BENEFICIARIOS_TESTE, 2:(NUM_DIAS_TESTE + 1)])

# ==========================================
# 3. MODELO MATEMÁTICO OTIMIZADO (ESPARSO)
# ==========================================
function resolve_M2(NM, NB, ND, matriz_dist, matriz_demanda, cap_max)
    env = Gurobi.Env()
    linModel = Model(() -> Gurobi.Optimizer(env))
    
    # Parâmetros de performance e controle
    set_time_limit_sec(linModel, 86400.0) # 24 horas
    #set_optimizer_attribute(linModel, "MIPFocus", 1) 
    set_optimizer_attribute(linModel, "NodefileStart", 10.0) 

    # Variáveis condicionais (só cria memória se houver demanda)
    @variable(linModel, 0 <= x[i=1:NM, j=1:NB, k=1:ND; matriz_demanda[j,k] > 0], Int) 
    @variable(linModel, y[i=1:NM, j=1:NB], Bin)              

    # Restrições esparsas
    @constraint(linModel, cap_diaria[i=1:NM, k=1:ND], sum(x[i,j,k] for j in 1:NB if matriz_demanda[j,k] > 0) <= cap_max)
    @constraint(linModel, atende_dem[j=1:NB, k=1:ND; matriz_demanda[j,k] > 0], sum(x[i,j,k] for i in 1:NM) == matriz_demanda[j,k])
    @constraint(linModel, fonte_unica[j=1:NB], sum(y[i,j] for i in 1:NM) == 1)
    @constraint(linModel, amarra_x_y[i=1:NM, j=1:NB, k=1:ND; matriz_demanda[j,k] > 0], x[i,j,k] <= matriz_demanda[j,k] * y[i,j])

    @objective(linModel, Min, sum(matriz_dist[i,j] * x[i,j,k] for i in 1:NM, j in 1:NB, k in 1:ND if matriz_demanda[j,k] > 0))

    tempo_inicio = time()
    optimize!(linModel)
    tempo_fim = time()
    tempo_exec = tempo_fim - tempo_inicio

    status = termination_status(linModel)
    if status == OPTIMAL
        println("Status: Solucao otima encontrada.")
    elseif status == TIME_LIMIT
        println("Status: Limite de tempo (24h) atingido.")
    else
        println("Status: O solver parou pelo motivo: ", status)
    end

    if has_values(linModel)
        return value.(y), objective_value(linModel), num_variables(linModel), tempo_exec, true
    else
        return zeros(Int, NM, NB), 0.0, num_variables(linModel), tempo_exec, false
    end
end

# ==========================================
# 4. EXECUÇÃO E GERAÇÃO DAS SAÍDAS
# ==========================================
println("Iniciando M2 - Modelo de Fonte Unica Anual...")
y_opt, custo_total, num_vars, tempo_exec, solucao_valida = resolve_M2(NUM_MANANCIAIS_TESTE, NUM_BENEFICIARIOS_TESTE, NUM_DIAS_TESTE, Dij, Ajk, CAPACIDADE_MAX_MANANCIAL)

if solucao_valida
    df_alocacao = copy(abastecimento[1:NUM_BENEFICIARIOS_TESTE, 1:(NUM_DIAS_TESTE + 1)])

    for j in 1:NUM_BENEFICIARIOS_TESTE
        fonte_escolhida = 0
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

    CSV.write(OUTPUT_CUSTO, df_metricas)
    CSV.write(OUTPUT_ALOCACAO, df_alocacao)

    println("\nFinalizado!")
    println("Custo Total Anual: ", custo_total)
    println("Tempo de Execucao: ", round(tempo_exec, digits=2), " segundos")
else
    println("\nProcessamento abortado: Nenhuma solucao viavel encontrada dentro do tempo limite. Arquivos CSV nao foram gerados para evitar sobrescrita de dados nulos.")
end
