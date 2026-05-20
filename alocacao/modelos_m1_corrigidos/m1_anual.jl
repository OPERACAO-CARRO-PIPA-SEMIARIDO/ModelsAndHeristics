using JuMP
using LinearAlgebra
using CSV
using DataFrames
using Gurobi

if length(ARGS) < 5
    println("Uso: julia m1_anual.jl <entrada.csv> <saida_alocacao.csv> <saida_custos.csv> <rotas.csv> <num_mananciais>")
    exit(1)
end

ABASTECIMENTO_FILE   = ARGS[1]
OUTPUT_ALOCACAO      = ARGS[2]
OUTPUT_CUSTO         = ARGS[3]
ROTAS_FILE           = ARGS[4]
NUM_MANANCIAIS_TESTE = parse(Int, ARGS[5])

abastecimento = CSV.read(ABASTECIMENTO_FILE, DataFrame, header=true)
rotas         = CSV.read(ROTAS_FILE,         DataFrame)

NUM_DIAS             = size(abastecimento, 2) - 1
NUM_MANANCIAIS_TOTAL = 92
NUM_MANANCIAIS       = NUM_MANANCIAIS_TESTE
NUM_BENEFICIARIOS    = size(abastecimento, 1)
NB_TOTAL_ROTAS       = 3315
CAPACIDADE_MAX       = 12

# Arquivo de rotas: ordenado por Manancial (0..91) depois Beneficiário (0..3314).
# reshape(..., (NB_TOTAL_ROTAS, NUM_MANANCIAIS_TOTAL)) → cada coluna = um manancial (column-major).
# Após transpose: Dij[i, j] = distância do manancial i ao beneficiário j (índices 1-based).
distancias   = rotas.distance_w_factor
Dij_completa = transpose(reshape(distancias, (NB_TOTAL_ROTAS, NUM_MANANCIAIS_TOTAL)))
Dij          = Dij_completa[1:NUM_MANANCIAIS, 1:NUM_BENEFICIARIOS]
Ajk          = Matrix{Float64}(abastecimento[:, 2:end])

function resolve_M1_anual(NM, NB, ND, matriz_dist, matriz_demanda, cap_max)
    env      = Gurobi.Env()
    linModel = Model(() -> Gurobi.Optimizer(env))
    set_silent(linModel)
    set_time_limit_sec(linModel, 86400.0)

    # Variáveis apenas onde há demanda (reduz tamanho do modelo)
    @variable(linModel, 0 <= x[i=1:NM, j=1:NB, k=1:ND; matriz_demanda[j,k] > 0], Int)

    # Capacidade por manancial por dia
    @constraint(linModel, cap[i=1:NM, k=1:ND],
        sum(x[i,j,k] for j in 1:NB if matriz_demanda[j,k] > 0) <= cap_max)

    # Atendimento da demanda por beneficiário por dia
    @constraint(linModel, dem[j=1:NB, k=1:ND; matriz_demanda[j,k] > 0],
        sum(x[i,j,k] for i in 1:NM) == matriz_demanda[j,k])

    @objective(linModel, Min,
        sum(matriz_dist[i,j] * x[i,j,k]
            for i in 1:NM, j in 1:NB, k in 1:ND if matriz_demanda[j,k] > 0))

    t0 = time()
    optimize!(linModel)
    tempo_exec = time() - t0

    status = termination_status(linModel)

    if status == MOI.OPTIMAL
        return value.(x), objective_value(linModel), num_variables(linModel), tempo_exec, "Otimo"
    elseif status == MOI.TIME_LIMIT && has_values(linModel)
        println("AVISO: Limite de tempo atingido. Solução subótima retornada.")
        return value.(x), objective_value(linModel), num_variables(linModel), tempo_exec, "SubOtimo_LimiteTempo"
    else
        println("ERRO: Nenhuma solução viável encontrada. Status: $(status)")
        return nothing, 0.0, num_variables(linModel), tempo_exec, string(status)
    end
end

x_opt, custo_total, num_vars, tempo_exec, status_str =
    resolve_M1_anual(NUM_MANANCIAIS, NUM_BENEFICIARIOS, NUM_DIAS, Dij, Ajk, CAPACIDADE_MAX)

if x_opt !== nothing
    df_alocacao = copy(abastecimento)

    for j in 1:NUM_BENEFICIARIOS
        for k in 1:NUM_DIAS
            if Ajk[j, k] > 0
                # Grava o manancial com o maior número de viagens (correto para demanda > 1)
                fonte_escolhida = 0
                max_viagens     = 0.0
                for i in 1:NUM_MANANCIAIS
                    val = x_opt[i, j, k]
                    if val > max_viagens
                        max_viagens     = val
                        fonte_escolhida = i
                    end
                end
                df_alocacao[j, k + 1] = fonte_escolhida
            else
                df_alocacao[j, k + 1] = 0
            end
        end
    end

    df_metricas = DataFrame(
        Tempo_de_Execucao = [tempo_exec],
        Solucao_otima     = [custo_total],
        Num_Variaveis     = [num_vars],
        Status_Solucao    = [status_str]
    )

    CSV.write(OUTPUT_CUSTO,    df_metricas)
    CSV.write(OUTPUT_ALOCACAO, df_alocacao)
else
    df_metricas = DataFrame(
        Tempo_de_Execucao = [tempo_exec],
        Solucao_otima     = [0.0],
        Num_Variaveis     = [num_vars],
        Status_Solucao    = [status_str]
    )
    CSV.write(OUTPUT_CUSTO, df_metricas)
    println("Nenhuma solução exportada.")
    exit(1)
end
