#---------------------------------------------------------------------------------------------------------------
#Struct auxiliar para armazenar os dados que serão devolvidos pela função retornaDados
#---------------------------------------------------------------------------------------------------------------
using JuMP
using HiGHS
using LinearAlgebra
using CSV
using DataFrames

module stDados
    export containerDados, instDados
    mutable struct containerDados
        Ajk #Matrix indicando o abastecimento dos beneficiários j em cada dia k 
        NM #Número de mananciais
        NB #Número de beneficiários
        ND #Número de dias
        #NBK #Vetor soma
        #BK #Vetor de Vetores para contar dados da coluna
        Dij#Matrix indicando a distância dos mananciais i e beneficiários j
        CAPi
    end

    function instDados(Ajk, NM, NB, ND, Dij, CAPi)#modelo rodando uma única vez para todos os dias juntos
    #function instDados(Ajk, NM, NB, Dij)#modelo rodando uma vez para dia de operação
        return containerDados(Ajk, NM, NB, ND, Dij, CAPi)#modelo rodando uma única vez para todos os dias juntos
        #return containerDados(Ajk, NM, NB, Dij)#modelo rodando uma vez para dia de operação
    end
end

