using JuMP
using LinearAlgebra
using CSV
using DataFrames
using Gurobi

# Protege a inclusão do arquivo local independente de onde o terminal foi aberto
include(joinpath(@__DIR__, "dados.jl"))
using .stDados

# Recebendo os caminhos via linha de comando (passados pela automação)
if length(ARGS) < 5
    println("Uso: julia m1args.jl <planilha_entrada.csv> <planilha_saida_alocacao.csv> <planilha_saida_custos.csv> <planilha_rotas.csv> <num_mananciais>")
    exit(1)
end

input_file = ARGS[1]
output_alocacao_file = ARGS[2]
output_custo_file = ARGS[3]
rotas_file = ARGS[4] # Caminho dinâmico das rotas
NUM_MANANCIAIS_TESTE = parse(Int, ARGS[5])

# Leitura dinâmica da entrada
abastecimento = CSV.read(input_file, DataFrame, header=true)
rotas = CSV.read(rotas_file, DataFrame)

tres_colunas_r = [rotas.id_beneficiario, rotas.id_fonte, rotas.distance_w_factor] 
tres_colunas_r[1] .+= 1.
tres_colunas_r[2] .+= 1.

# Criar dataframe de saída idêntico ao de entrada para preenchimento
df_alocacao = copy(abastecimento)

# Detectar o número de dias (ND) e beneficiários (NB) dinamicamente baseado nas colunas do CSV de entrada
NUM_DIAS = size(abastecimento, 2) - 1
NUM_BENEFICIARIOS = size(abastecimento, 1)

function retornaDados()
    NB_TOTAL_ROTAS = 3315
    NB = NUM_BENEFICIARIOS
    Ajk = Matrix{Float64}(abastecimento[1:NB, 2:end])
    NM_TOTAL = 92
    NM = NUM_MANANCIAIS_TESTE
    
    # O arquivo de rotas contém 3315 beneficiários para cada um dos 92 mananciais.
    # Ele está ordenado por Manancial (0..91) e depois por Beneficiário (0..3314).
    # Portanto, reshape(..., (3315, 92)) cria uma matriz onde cada coluna é um manancial.
    # Transpomos para ter Dij[manancial, beneficiario].
    distancias_vetor = tres_colunas_r[3]
    Dij_completa = transpose(reshape(distancias_vetor, (NB_TOTAL_ROTAS, NM_TOTAL)))
    
    # Filtramos para os NM mananciais e NB beneficiários presentes no arquivo de abastecimento
    Dij = Dij_completa[1:NM, 1:NB]
    
    ND = 1:NUM_DIAS
    CAPi = 12
    resp = stDados.instDados(Ajk, NM, NB, ND, Dij, CAPi)
    return resp
end

function resolvePL(dia, dados)
    NM = dados.NM
    NB = dados.NB
    ND = dados.ND
    Dij = dados.Dij
    Ajk = dados.Ajk

    linModel = Model(Gurobi.Optimizer)
    set_silent(linModel) # Silenciar para não poluir o terminal

    @variable(linModel, 0 <= x[i=1:NM, j=1:NB], Int)

    # 1- Restrição de extração
    @constraint(linModel, atendimentoManancial[i=1:NM], sum(x[i,j] for j in 1:NB) <= 12)
    
    # 2- Restrição de consumo
    @constraint(linModel, atendimentoDemanda[j=1:NB], sum(x[i,j] for i in 1:NM) == Ajk[j, dia])
    
    @objective(linModel, Min, sum(sum(Dij[i,j]*x[i,j] for j in 1:NB) for i in 1:NM))

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
        Dia               = Int[],
        Tempo_de_Execucao = Float64[],
        Solucao_otima     = Float64[],
        Num_Variaveis     = Int[],
        Status_Solucao    = String[]
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
