using HiGHS
using CSV
using DataFrames

#A partir dos dados gerados em CapacidadeVsConsumo definir dias que as entregas devem acontecer
#Estrategia: fazer duas entregas consecutivas imediatamente antes dos feriados problemático e uma depois
#OBS: TALVEZ AS POSIÇÕES NÃO FIQUEM CORRETAS, basta fazer pequenas alterações nos loops ou indices dos loops

#ler dias uteis
df_dias = CSV.read("/home/guilherme/AlocacaoCarrosPipas/Dados/datas.csv", DataFrame)
dias = convert(Vector{Int64}, df_dias.dia_util)

#ler beneficiarios e quebra
beneficiarios_ativos = CSV.read("/home/guilherme/AlocacaoCarrosPipas/Dados/Beneficiarios_RN_Ativos_test.csv" ,DataFrame)
beneficiarios_quebras = CSV.read("/home/guilherme/AlocacaoCarrosPipas/Dados/quebras_abastecimento.csv", DataFrame)

quebra3 = Set(beneficiarios_quebras.Quebra_em_3)
quebra4 = Set(beneficiarios_quebras.Quebra_em_4)
quebra5 = Set(beneficiarios_quebras.Quebra_em_5)


#definir calendario obrigatorios para quebras em 3
global count = 0
entregas_obrigatorias3 = zeros(Int, length(dias))
entregas_obrigatorias2 = zeros(Int, length(dias))
entregas_obrigatorias4 = zeros(Int, length(dias))
for i in 1:length(dias)
    if dias[i] == 0
        global count += 1
    else
        if count >= 3
            if i - count - 1 >= 1
                entregas_obrigatorias3[i - count - 1] = 1
            end
            if i - count - 2 <= length(entregas_obrigatorias3)
                entregas_obrigatorias3[i - count - 2] = 1
            end
            if i <= length(entregas_obrigatorias3)
                 entregas_obrigatorias3[i] = 1
            end
        end
        if count >= 2
            if i - count - 1 >= 1
                entregas_obrigatorias2[i - count - 1] = 1
            end
            if i - count - 2 <= length(entregas_obrigatorias3)
                entregas_obrigatorias2[i - count - 2] = 1
            end
            if i <= length(entregas_obrigatorias3)
                 entregas_obrigatorias2[i] = 1
            end
        end
        if count >= 4
            if i - count - 1 >= 1
                entregas_obrigatorias4[i - count - 1] = 1
            end
            if i - count - 2 <= length(entregas_obrigatorias3)
                entregas_obrigatorias4[i - count - 2] = 1
            end
            if i <= length(entregas_obrigatorias3)
                 entregas_obrigatorias4[i] = 1
            end
        end
        global count = 0
    end
end

#definir calendario obrigatorios para quebras em 5
entregas_obrigatorias5 = zeros(Int, length(dias))
entregas_obrigatorias5[47] = 1
entregas_obrigatorias5[48] = 1
entregas_obrigatorias5[54] = 1

#gerar matriz com as entregas obrigatorias para os beneficiarios.
df_resultado = DataFrame(
    entregas_obrigatorias2 = entregas_obrigatorias2,
    entregas_obrigatorias3 = entregas_obrigatorias3,
    entregas_obrigatorias4 = entregas_obrigatorias4,
    entregas_obrigatorias5 = entregas_obrigatorias5
)
CSV.write("/home/guilherme/AlocacaoCarrosPipas/Calendario_entregas_obrigatorias.csv", df_resultado)

print("Deu bom!")