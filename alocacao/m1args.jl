using JuMP
using LinearAlgebra
using CSV
using DataFrames
using Gurobi

# Protege a inclusão do arquivo local independente de onde o terminal foi aberto
include(joinpath(@__DIR__, "dados.jl"))
using .stDados

# Recebendo os caminhos via linha de comando (passados pela automação)
if length(ARGS) < 4
    println("Uso: julia m1args.jl <planilha_entrada.csv> <planilha_saida_alocacao.csv> <planilha_saida_custos.csv> <planilha_rotas.csv>")
    exit(1)
end

input_file = ARGS[1]
output_alocacao_file = ARGS[2]
output_custo_file = ARGS[3]
rotas_file = ARGS[4] # Caminho dinâmico das rotas

# Leitura dinâmica da entrada
abastecimento = CSV.read(input_file, DataFrame, header=true)
rotas = CSV.read(rotas_file, DataFrame)

tres_colunas_r = [rotas.id_beneficiario, rotas.id_fonte, rotas.distance_w_factor] 
tres_colunas_r[1] .+= 1.
tres_colunas_r[2] .+= 1.

# Criar dataframe de saída idêntico ao de entrada para preenchimento
df_alocacao = copy(abastecimento)

# Detectar o número de dias (ND) dinamicamente baseado nas colunas do CSV de entrada
NUM_DIAS = size(abastecimento, 2) - 1

function retornaDados()
    NB = 3315
    Ajk = Matrix{Float64}(abastecimento[1:NB, 2:end])
    NM = 92
    Dij = reshape(tres_colunas_r[3], (92, 3315))[1:NM, 1:NB]
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

    # Extração da alocação para o formato de saída
    x_sol = value.(x)
    for j in 1:NB
        if Ajk[j, dia] > 0
            for i in 1:NM
                if x_sol[i,j] > 0.5
                    df_alocacao[j, dia + 1] = i
                    break
                end
            end
        else
            df_alocacao[j, dia + 1] = 0
        end
    end

    return objective_value(linModel), num_variables(linModel)
end

function roda_PL(ND_total::Int)
    df_resultados_total = DataFrame(Tempo_de_Execucao = Float64[], Solucao_otima = Float64[], Num_Variaveis = Int[])
    dados = retornaDados()
    
    for dia in 1:ND_total
        tempo_inicio_dia = time()
        custo, vars = resolvePL(dia, dados)
        tempo_fim_dia = time()
        
        push!(df_resultados_total, (tempo_fim_dia - tempo_inicio_dia, custo, vars))
    end
  
    CSV.write(output_custo_file, df_resultados_total)
    CSV.write(output_alocacao_file, df_alocacao)
end

roda_PL(NUM_DIAS)
