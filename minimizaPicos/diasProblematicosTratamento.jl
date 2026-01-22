using CSV
using DataFrames

#Problemas: Quebras de abastecimento no carnaval e beneficiario 2997 aguentar somente 2 dias sem abastecimento
#1: Separar os beneficiarios problematicos no carnaval, para ajusta-los manualmente no modelo
#2: Fazer um calendario de entregas obrigatorias para o beneficiario 2997 

#########################################################################################
#1: Separar os beneficiarios problematicos no carnaval, para ajusta-los manualmente no modelo
beneficiarios_ativos = CSV.read("C:/Users/lfeli/Documents/dados/Beneficiarios_RN_Ativos1.csv", DataFrame, decimal=',', validate=false)


U = [round(i * 0.02, digits=2) for i in duas_colunas_b[2]]
C = convert(Vector{Float64}, duas_colunas_b[1])
#quantos dias o reservatorio do beneficiario aguenta sem abastecimento
Y = [u == 0.0 ? 0.0 : c / u for (c, u) in zip(C, U)]
df_beneficiariosVsReservatorio = DataFrame(
    Beneficiario=1:length(C),
    Dias_sem_abastecimento=Y
)
quebrasCarnaval = [beneficiario for (beneficiario, x) in zip(df_beneficiariosVsReservatorio.Beneficiario, Y) if x < 5]
df_ProblematicosCarnaval = DataFrame(BeneficiariosProblematicos=quebrasCarnaval)
#CSV.write("C:\Users\lfeli\Documents\dados\ProblematicosCarnaval.csv", df_ProblematicosCarnaval)

#########################################################################################
#2: Fazer um calendario de entregas obrigatorias para o beneficiario 2997 e um para facilitar a correcao das quebras de carnaval
dias_uteis = CSV.read("C:/Users/lfeli/Documents/dados/datas.csv", DataFrame)
dias = convert(Vector{Int64}, dias_uteis.dia_util)

entregas_obrigatorias2997 = zeros(Int, length(dias))
global count = 0
for i in 1:length(dias)
    if dias[i] == 0
        global count += 1
    else
        if count >= 3
            if dias[i-count-1] != 0
                entregas_obrigatorias2997[i-count-1] = 1
            end
            #if dias[i - count - 2] != 0
            #    entregas_obrigatorias2997[i - count - 2] = 1
            #end
            entregas_obrigatorias2997[i] = 1
            for j in 1:count
                entregas_obrigatorias2997[i-count+j-1] = -1
            end
        end
        global count = 0
    end
end
#entregas_obrigatorias2997[158] = 1
#entregas_obrigatorias2997[157] = 1
#entregas_obrigatorias2997[365] = -1
#entregas_obrigatorias2997[364] = -1

entregas_obrigatorias_carnaval = zeros(Int, length(dias))
global count = 0
for i in 1:length(dias)
    if dias[i] == 0
        global count += 1
    else
        if count >= 5
            entregas_obrigatorias_carnaval[i-count-1] = 1
            #entregas_obrigatorias_carnaval[i - count - 2] = 1
            entregas_obrigatorias_carnaval[i] = 1
            for j in 1:count
                entregas_obrigatorias_carnaval[i-count+j-1] = -1
            end
        end
        global count = 0
    end
end
df_calendarios = DataFrame(
    lil=entregas_obrigatorias2997,
    carnaval=entregas_obrigatorias_carnaval
)
#CSV.write("/home/guilherme//AlocacaoCarrosPipas/Dados/calendario2997_2.csv", DataFrame(obrigatorias=entregas_obrigatorias2997))
#CSV.write("/home//guilherme/AlocacaoCarrosPipas/Dados/calendarioCarnaval.csv", DataFrame(obrigatorias=entregas_obrigatorias_carnaval))
CSV.write("C:/Users/lfeli/Documents/dados/CalendariosObrigatorios.csv", df_calendarios)
#####################################################################

print(entregas_obrigatorias2997)