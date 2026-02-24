using JuMP
using LinearAlgebra
using CSV
using DataFrames
using Gurobi
include("dados.jl")
using .stDados

#beneficiarios_ativos= CSV.read("C:/Users/HP/OneDrive/Desktop/Mestrado/Tese/Dados/Beneficiarios_RN_Ativos.xlsx - Planilha1.csv",DataFrame)

#duas_colunas_b = [beneficiarios_ativos.Capacidade,beneficiarios_ativos.Pessoas_Atendidas] 

#mananciais= CSV.read("C:/Users/HP/OneDrive/Desktop/Mestrado/Tese/Dados/Mananciais_RN_csv.csv",DataFrame)

#duas_colunas_m = [mananciais.Id,mananciais.GCDA_manancial] 

#print(duas_colunas_m)

abastecimento= CSV.read("C:/Users/lfeli/Documents/AlocacaoCarros/ModelsAndHeristics/minimizaPicos/resultados10wLim/abastecimento_24h.csv",DataFrame, header=true)

rotas= CSV.read("C:/Users/lfeli/Documents/AlocacaoCarros/dados/rotas",DataFrame)

tres_colunas_r = [rotas.id_beneficiario,rotas.id_fonte,rotas.distance_w_factor] 

tres_colunas_r[1].+=1.
tres_colunas_r[2].+=1.

reshape(tres_colunas_r[3],(92,3315))

#dias_uteis= CSV.read("C:/Users/HP/OneDrive/Desktop/Mestrado/Tese/Dados/datas.csv",DataFrame)




#---------------------------------------------------------------------------------------------------------------
#Função que monta o problema linear e o resolve.
#Recebe..: Nada
#Retorna.: O Modelo linear resolvido
#---------------------------------------------------------------------------------------------------------------

function retornaDados()
    #cap. manancial
    CAPi=13
    #Abastecimento dos beneficiários j em cada dia k
    NB=3315
    Ajk = Matrix{Float64}(abastecimento[:, 2:end])
    #Número de mananciais(NM), Número de beneficiários(NB), distância dos mananciais i e beneficiários j(Dij)
    NM=92
    
    ND=365
    #NBK= [sum(Ajk[:,k]) for k in 1:365]
    #f(x)=x==1 
    #BK= [findall(f,Ajk[:,k]) for k in 1:365]
    Dij=reshape(tres_colunas_r[3],(92,3315))[1:NM,1:NB]

    #Colocando as informações em um struct e retornando
    resp=stDados.instDados(Ajk, NM, NB, ND, Dij, CAPi)
    return resp
end



function resolvePL()
    #Recebendo os dados
    dados=retornaDados()

    #Redefinindo algumas variáveis para simplificar a escrita do código (não escrever dados.coisa toda hora)
    NM=dados.NM
    NB=dados.NB
    ND=dados.ND
    Dij=dados.Dij
    Ajk=dados.Ajk
    CAPi=dados.CAPi
    #NBK=dados.NBK
    #BK=dados.BK

    #Declarando o modelo usando um solver de programação linear
    #linModel=Model(HiGHS.Optimizer)
    linModel=Model(Gurobi.Optimizer)

    set_optimizer_attribute(linModel, "NodefileStart", 20.0)
    set_time_limit_sec(linModel, 36000) 
    #Variáveis, junto com suas limitações inferiores e superiores
        
    #Entrega dos mananciais i para os beneficiários j no dia k -> Não negativa e limitada superiormente pelo máximo que pode ser recebido
    @variable(linModel, 0<=x[i=1:NM,j=1:NB, k=1:ND], Int)
    #Entrega dos mananciais i para os beneficiários j -> Binária
    @variable(linModel, y[i=1:NM,j=1:NB], Bin)

    #Restrições

    #1- Restrição de extração: Respeitar o número máximo de abastecimentos diários por manancial.
    # Para todos os dias k verificar o atendimento máximo de 12 caminhões por manancial

    @constraint(linModel, atendimentoManancial[i=1:NM, k=1:ND], sum(x[i,j,k] for j in 1:NB) <= CAPi)
    
    #@constraint(linModel,atendimentoManancial[i=1:NM, k=1:ND], sum(x[i,j,k] for j in BK) <= 12)

    
    #2- Restrição de consumo seguindo o calendário de abastecimento: O volume da entrega ij deve ser igual ao calendário do beneficiário j.

    @constraint(linModel, atendimentoDemanda[j=1:NB, k=1:ND], sum(x[i,j,k] for i in 1:NM) == Ajk[j,k])
    
    #@constraint(linModel, atendimentoDemanda[j in BK, k=1:ND], sum(x[i,j,k] for i in 1:NM) == Ajk[j,k])

    #3- Restrição de origem da entrega: Respeitar usar o mesmo manancial para todos os abastecimentos.
    # Para todos os dias k verificar se o atendimento j vem de memso ponto i

    @constraint(linModel, atendimentoColeta1[j=1:NB], sum(y[i,j] for i in 1:NM) == 1)

    @constraint(linModel, atendimentoColeta2[i=1:NM, j=1:NB, k=1:ND], x[i,j,k] <= y[i,j])

    #Função objetivo 
    @objective(linModel, Min, sum(sum(sum(Dij[i,j]*x[i,j,k] for j in 1:NB) for i in 1:NM) for k in 1:ND))

    #Resolvendo o problema
    optimize!(linModel)

    #Retornando
    #print(linModel)
    #println(value.(x))
    #for j=1:NB
    #    println("Beneficiário $j recebe das seguintes fontes:",j)
    #    for j in BK[j]
    #end
    #Ix=[findall(f,x[:,:,k]) for k in 1:365]

    println(objective_value(linModel))
    #return Ix
end
tempo_inicio = time()

resolvePL()

tempo_fim = time()
tempo_total = tempo_fim - tempo_inicio

print(tempo_total)