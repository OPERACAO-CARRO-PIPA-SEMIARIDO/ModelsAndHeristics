using JuMP
using LinearAlgebra
using CSV
using DataFrames
using Gurobi

if length(ARGS) < 5
    println("Uso: julia m2.jl <entrada.csv> <saida_alocacao.csv> <saida_custos.csv> <rotas.csv> <num_mananciais>")
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

function resolve_M2(NM, NB, ND, matriz_dist, matriz_demanda, cap_max)
    env      = Gurobi.Env()
    linModel = Model(() -> Gurobi.Optimizer(env))
    set_silent(linModel)
    set_time_limit_sec(linModel, 86400.0)

    # Demanda total anual por beneficiário: suma sobre todos os dias
    demanda_total = vec(sum(matriz_demanda, dims=2))

    # Dias que têm ao menos um beneficiário com demanda (evita restrições triviais)
    dias_com_demanda = [k for k in 1:ND if any(matriz_demanda[:, k] .> 0)]

    # y[i,j]: 1 se o beneficiário j é atendido pelo manancial i em TODOS os dias
    @variable(linModel, y[i=1:NM, j=1:NB], Bin)

    # Fonte única: cada beneficiário usa exatamente 1 manancial o ano todo
    @constraint(linModel, fonte_unica[j=1:NB],
        sum(y[i,j] for i in 1:NM) == 1)

    # Capacidade: trips totais no manancial i no dia k (x[i,j,k] = Ajk[j,k]*y[i,j])
    @constraint(linModel, cap[i=1:NM, k=dias_com_demanda],
        sum(matriz_demanda[j,k] * y[i,j] for j in 1:NB if matriz_demanda[j,k] > 0) <= cap_max)

    # Objetivo: custo total = sum Dij * x = sum Dij * demanda_total[j] * y[i,j]
    @objective(linModel, Min,
        sum(matriz_dist[i,j] * demanda_total[j] * y[i,j]
            for i in 1:NM, j in 1:NB if demanda_total[j] > 0))

    t0 = time()
    optimize!(linModel)
    tempo_exec = time() - t0

    status = termination_status(linModel)

    if status == MOI.OPTIMAL
        return value.(y), objective_value(linModel), num_variables(linModel), tempo_exec, "Otimo"
    elseif status == MOI.TIME_LIMIT && has_values(linModel)
        println("AVISO: Limite de tempo atingido. Solução subótima retornada.")
        return value.(y), objective_value(linModel), num_variables(linModel), tempo_exec, "SubOtimo_LimiteTempo"
    else
        println("ERRO: Nenhuma solução viável encontrada. Status: $(status)")
        return nothing, 0.0, num_variables(linModel), tempo_exec, string(status)
    end
end

y_opt, custo_total, num_vars, tempo_exec, status_str =
    resolve_M2(NUM_MANANCIAIS, NUM_BENEFICIARIOS, NUM_DIAS, Dij, Ajk, CAPACIDADE_MAX)

if y_opt !== nothing
    df_alocacao = copy(abastecimento)

    for j in 1:NUM_BENEFICIARIOS
        # Fonte única: y é binário, exatamente um i tem y[i,j] = 1
        fonte_escolhida = 0
        for i in 1:NUM_MANANCIAIS
            if y_opt[i, j] > 0.5
                fonte_escolhida = i
                break
            end
        end

        for k in 1:NUM_DIAS
            df_alocacao[j, k + 1] = (Ajk[j, k] > 0) ? fonte_escolhida : 0
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
