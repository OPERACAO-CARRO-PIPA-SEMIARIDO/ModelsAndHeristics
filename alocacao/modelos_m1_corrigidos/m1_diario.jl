using JuMP
using LinearAlgebra
using CSV
using DataFrames
using Gurobi

include(joinpath(@__DIR__, "dados.jl"))
using .stDados

if length(ARGS) < 5
    println("Uso: julia m1_diario.jl <entrada.csv> <saida_alocacao.csv> <saida_custos.csv> <rotas.csv> <num_mananciais>")
    exit(1)
end

input_file          = ARGS[1]
output_alocacao_file = ARGS[2]
output_custo_file   = ARGS[3]
rotas_file          = ARGS[4]
NUM_MANANCIAIS_TESTE = parse(Int, ARGS[5])

abastecimento = CSV.read(input_file,  DataFrame, header=true)
rotas         = CSV.read(rotas_file,  DataFrame)

df_alocacao   = copy(abastecimento)
NUM_DIAS          = size(abastecimento, 2) - 1
NUM_BENEFICIARIOS = size(abastecimento, 1)

function retornaDados()
    NB_TOTAL_ROTAS = 3315
    NB     = NUM_BENEFICIARIOS
    NM_TOTAL = 92
    NM     = NUM_MANANCIAIS_TESTE
    Ajk    = Matrix{Float64}(abastecimento[1:NB, 2:end])

    # Arquivo de rotas: ordenado por Manancial (0..91) depois Beneficiário (0..3314).
    # reshape(..., (NB_TOTAL_ROTAS, NM_TOTAL)) → cada coluna = um manancial (column-major).
    # Após transpose: Dij[i, j] = distância do manancial i ao beneficiário j (índices 1-based).
    distancias_vetor = rotas.distance_w_factor
    Dij_completa = transpose(reshape(distancias_vetor, (NB_TOTAL_ROTAS, NM_TOTAL)))
    Dij = Dij_completa[1:NM, 1:NB]

    ND   = 1:NUM_DIAS
    CAPi = 12
    return stDados.instDados(Ajk, NM, NB, ND, Dij, CAPi)
end

function resolvePL(dia, dados)
    NM  = dados.NM
    NB  = dados.NB
    Dij = dados.Dij
    Ajk = dados.Ajk

    linModel = Model(Gurobi.Optimizer)
    set_silent(linModel)

    @variable(linModel, 0 <= x[i=1:NM, j=1:NB], Int)

    @constraint(linModel, cap[i=1:NM],   sum(x[i,j] for j in 1:NB) <= 12)
    @constraint(linModel, dem[j=1:NB],   sum(x[i,j] for i in 1:NM) == Ajk[j, dia])

    @objective(linModel, Min, sum(Dij[i,j] * x[i,j] for i in 1:NM, j in 1:NB))

    optimize!(linModel)

    status = termination_status(linModel)
    if status != MOI.OPTIMAL
        println("AVISO: dia $dia — status $(status). Dia pulado.")
        return 0.0, num_variables(linModel), string(status)
    end

    x_sol = value.(x)
    for j in 1:NB
        if Ajk[j, dia] > 0
            # Grava o manancial com o maior número de viagens (correto para demanda > 1)
            fonte_escolhida = 0
            max_viagens     = 0.0
            for i in 1:NM
                if x_sol[i, j] > max_viagens
                    max_viagens     = x_sol[i, j]
                    fonte_escolhida = i
                end
            end
            df_alocacao[j, dia + 1] = fonte_escolhida
        else
            df_alocacao[j, dia + 1] = 0
        end
    end

    return objective_value(linModel), num_variables(linModel), "Otimo"
end

function roda_PL(ND_total::Int)
    df_resultados = DataFrame(
        Dia              = Int[],
        Tempo_de_Execucao = Float64[],
        Solucao_otima    = Float64[],
        Num_Variaveis    = Int[],
        Status_Solucao   = String[]
    )
    dados = retornaDados()

    for dia in 1:ND_total
        t0 = time()
        custo, nvars, status = resolvePL(dia, dados)
        t1 = time()
        push!(df_resultados, (dia, t1 - t0, custo, nvars, status))
    end

    CSV.write(output_custo_file,    df_resultados)
    CSV.write(output_alocacao_file, df_alocacao)
end

roda_PL(NUM_DIAS)
