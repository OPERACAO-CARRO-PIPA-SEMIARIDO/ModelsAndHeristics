using JuMP
#using HiGHS
using LinearAlgebra
using CSV
using DataFrames
using Gurobi
include("dados.jl")
using .stDados
using Plots

REPO_PATH = "/home/guilherme/ModelsAndHeristics/"
DATA_PATH = "/home/guilherme/repos/backup/AlocacaoCarrosPipas/Dados/"

abastecimento= CSV.read(REPO_PATH * "minimizaPicos/resultados10wLim/abastecimento_24h.csv",DataFrame, header=true)
rotas= CSV.read(DATA_PATH * "/rotas",DataFrame)

tres_colunas_r = [rotas.id_beneficiario,rotas.id_fonte,rotas.distance_w_factor] 
tres_colunas_r[1].+=1.
tres_colunas_r[2].+=1.

reshape(tres_colunas_r[3],(92,3315))

# Criar dataframe de saída idêntico ao de entrada para preenchimento
df_alocacao = copy(abastecimento)

function retornaDados()
    NB=3315
    Ajk = Matrix{Float64}(abastecimento[1:NB, 2:end])
    NM=92
    Dij=reshape(tres_colunas_r[3],(92,3315))[1:NM,1:NB]
    ND=1:365
    CAPi=12
    resp=stDados.instDados(Ajk, NM, NB, ND, Dij, CAPi)
    return resp
end

function resolvePL(dia)
    dados=retornaDados()
    NM=dados.NM
    NB=dados.NB
    ND=dados.ND
    Dij=dados.Dij
    Ajk=dados.Ajk

    linModel=Model(Gurobi.Optimizer)
    set_silent(linModel) # Silenciar para não poluir o terminal

    @variable(linModel, 0<=x[i=1:NM,j=1:NB], Int)

    #1- Restrição de extração [cite: 6]
    @constraint(linModel,atendimentoManancial[i=1:NM], sum(x[i,j] for j in 1:NB) <= 12)
    
    #2- Restrição de consumo [cite: 7]
    @constraint(linModel, atendimentoDemanda[j=1:NB, k=dia], sum(x[i,j] for i in 1:NM) == Ajk[j,k])
    
    @objective(linModel, Min, sum(sum(Dij[i,j]*x[i,j] for j in 1:NB) for i in 1:NM))

    optimize!(linModel)

    # --- NOVO: Extração da alocação para o formato de saída ---
    x_sol = value.(x)
    for j in 1:NB
        if Ajk[j, dia] > 0
            # Encontrar qual manancial (i) foi designado
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

    tempo_fim = time()
    tempo_total = tempo_fim - tempo_inicio
    return tempo_total, objective_value(linModel), num_variables(linModel)
end

tempo_inicio = time()

function roda_PL(ND::Int)
    df_resultados_total = DataFrame(Tempo_de_Execucao = Float64[], Solucao_otima = Float64[], Num_Variaveis = Int[])
    
    for dia in 1:ND
        resultado = resolvePL(dia)
        push!(df_resultados_total, (resultado[1], resultado[2], resultado[3]))
    end
  
    CSV.write("custoM110wLim.csv", df_resultados_total)
    # NOVO: Exportar o calendário de fontes igual ao input
    CSV.write("m110wLim.csv", df_alocacao)
end

ND=365
roda_PL(ND)
