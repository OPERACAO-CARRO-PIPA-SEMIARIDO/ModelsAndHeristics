using JuMP
#using HiGHS
using LinearAlgebra
using CSV
using DataFrames
using Gurobi
include("dados.jl")
using .stDados
using Plots



#beneficiarios_ativos= CSV.read("C:/Users/HP/OneDrive/Desktop/Mestrado/Tese/Dados/Beneficiarios_RN_Ativos.xlsx - Planilha1.csv",DataFrame)

#duas_colunas_b = [beneficiarios_ativos.Capacidade,beneficiarios_ativos.Pessoas_Atendidas] 

#mananciais= CSV.read("C:/Users/HP/OneDrive/Desktop/Mestrado/Tese/Dados/Mananciais_RN_csv.csv",DataFrame)

#duas_colunas_m = [mananciais.Id,mananciais.GCDA_manancial] 

#print(duas_colunas_m)

abastecimento= CSV.read("/home/guilherme/repos/backup/AlocacaoCarrosPipas/temp/abastecimento_diario.csv",DataFrame, header=true)

rotas= CSV.read("/home/guilherme/repos/backup/AlocacaoCarrosPipas/Dados/rotas",DataFrame)

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
    #Número de beneficiários(NB)
    NB=3315
    #Abastecimento dos beneficiários j em cada dia k
    Ajk = Matrix{Float64}(abastecimento[1:NB, 2:end])
    #Número de mananciais(NM), distância dos mananciais i e beneficiários j(Dij)
    NM=92
    Dij=reshape(tres_colunas_r[3],(92,3315))[1:NM,1:NB]
    ND=1:365
    CAPi=12
    #Colocando as informações em um struct e retornando
    resp=stDados.instDados(Ajk, NM, NB, ND, Dij, CAPi)
    return resp
end



function resolvePL(dia)
    #Recebendo os dados
    dados=retornaDados()

    #Redefinindo algumas variáveis para simplificar a escrita do código (não escrever dados.coisa toda hora)
    NM=dados.NM
    NB=dados.NB
    ND=dados.ND
    #dias=dados.dias
    Dij=dados.Dij
    Ajk=dados.Ajk

    #Declarando o modelo usando um solver de programação linear
    #linModel=Model(HiGHS.Optimizer)
    linModel=Model(Gurobi.Optimizer)

    #Variáveis, junto com suas limitações inferiores e superiores
        
    #Entrega dos mananciais i para os beneficiários j -> Não negativa e limitada superiormente pelo máximo que pode ser recebido
    @variable(linModel, 0<=x[i=1:NM,j=1:NB], Int)

    #Restrições
    
    #1- Restrição de extração: Respeitar o número máximo de abastecimentos diários por manancial.
    # Para todos os dias k verificar o atendimento máximo de 12 caminhões por manancial

    @constraint(linModel,atendimentoManancial[i=1:NM], sum(x[i,j] for j in 1:NB) <= 12)
    


    
    #2- Restrição de consumo seguindo o calendário de abastecimento: O volume da entrega ij deve ser igual ao calendário do beneficiário j.

    @constraint(linModel, atendimentoDemanda[j=1:NB, k=dia], sum(x[i,j] for i in 1:NM) == Ajk[j,k])
    

    #Função objetivo 
    @objective(linModel, Min, sum(sum(Dij[i,j]*x[i,j] for j in 1:NB) for i in 1:NM))

    #Resolvendo o problema
    optimize!(linModel)

    tempo_fim = time()
    tempo_total = tempo_fim - tempo_inicio


    return tempo_total, objective_value(linModel), num_variables(linModel)

    
    #print(tempo_total)
    #println(objective_value(linModel))

end
tempo_inicio = time()

#resolvePL()




function roda_PL(ND::Int)
    #println("Roda PL sendo usado")
    df_resultados_total = DataFrame(Tempo_de_Execucao = Float64[], Solucao_otima = Float64[], Num_Variaveis = Int[])
    
    for dia in 1:ND
        #print(dia)
        #sleep(5)
        #println("Entrou no dia $dia no for dos dias..",dia)
        #sleep(2)
        resultado = resolvePL(dia)
        #println("Rodou o dia $dia..",dia)
        #sleep(2)
        push!(df_resultados_total, (resultado[1], resultado[2], resultado[3]))
    
    end
    
    CSV.write("m1MinimizaPicos.csv", df_resultados_total)
    
    #gráfico de tempo vs quantidade de dias
    #plot(df_resultados_total[:, :dias], df_resultados_total[:, :Tempo_de_Execucao], xlabel="Dias", ylabel="Tempo de Execução ", legend=false, title="Tempo de Execução vs. Dias")
    #savefig("tempo_vs_dias.png")


    #plot(df_resultados_total[:,:Solucao_otima],df_resultados_total[:, :Tempo_de_Execucao], xlabel="Custo", ylabel="Tempo de Execucao", legend=false, title="Tempo de Execução vs. Custo")
    #savefig("custo_tempo.png")
    #println("Roda PL saida")
    #sleep(2)

end

# Chame a função para executar o modelo
ND=365

roda_PL(ND)
