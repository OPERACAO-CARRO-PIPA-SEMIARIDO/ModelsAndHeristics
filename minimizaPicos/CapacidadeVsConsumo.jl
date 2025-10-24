using CSV
using DataFrames
using Plots
using StatsPlots

# Lendo os beneficiários ativos
beneficiarios_ativos = CSV.read(
    "/home/guilherme/AlocacaoCarrosPipas/Dados/Beneficiarios_RN_Ativos_test.csv",
    DataFrame
)
#beneficiarios_ativos= CSV.read("C:\\Users\\je4hu\\colrepos\\alocacao_carros_pipa\\Tese\\Dados\\Beneficiarios_RN_Ativos.xlsx - Planilha1.csv",DataFrame)
# Pegando as colunas necessárias
duas_colunas_b = [beneficiarios_ativos.Capacidade, beneficiarios_ativos.Pessoas_Atendidas]

# Criando vetor de consumo diário (0.02 consumo por pessoa atendida)
U = [round(i * 0.02, digits=2) for i in duas_colunas_b[2]]

# Convertendo capacidade (C) para Float64
C = convert(Vector{Float64}, duas_colunas_b[1])
#C = [parse(Float64, replace(s, "," => ".")) for s in duas_colunas_b[1]]

# Calculando os dias sem abastecimento
Y = C ./ U

# Criando DataFrame com os resultados
df_resultado = DataFrame(
    Beneficiario=1:length(C),
    Capacidade=C,
    Pessoas_Atendidas=duas_colunas_b[2],
    Consumo_Diario=U,
    Dias_sem_abastecimento=Y
)
quebra1 = [beneficiario for (beneficiario, x) in zip(df_resultado.Beneficiario, Y) if x < 2]
quebra2 = [beneficiario for (beneficiario, x) in zip(df_resultado.Beneficiario, Y) if x < 3]
quebra3 = [beneficiario for (beneficiario, x) in zip(df_resultado.Beneficiario, Y) if 3 <= x < 4]
quebra4 = [beneficiario for (beneficiario, x) in zip(df_resultado.Beneficiario, Y) if x < 5]
quebra5 = [beneficiario for (beneficiario, x) in zip(df_resultado.Beneficiario, Y) if x < 6]
max_length = maximum(length, [quebra3, quebra4, quebra5])
println(quebra2)
println(quebra4)
#CSV.write("ProblematicosCarnaval.csv", DataFrame(beneficiarios=quebra4))
#CSV.write("quebra5.csv", DataFrame(beneficiarios=quebra5))
#CSV.write("quebra3.csv", DataFrame(beneficiarios=quebra3))
# Função para preencher um vetor
function pad_with_missing!(vec::Vector, max_len::Int)
    while length(vec) < max_len
        push!(vec, 0)
    end
    return vec
end

# Aplique a função a cada vetor
pad_with_missing!(quebra3, max_length)
pad_with_missing!(quebra4, max_length)
pad_with_missing!(quebra5, max_length)

df_quebras = DataFrame(
    Quebra_em_3=quebra3,
    Quebra_em_4=quebra4,
    Quebra_em_5=quebra5
)

#CSV.write("C:\\Users\\je4hu\\colrepos\\alocacao_carros_pipa\\Tese\\Dados\\quebras_abastecimento.csv", df_quebras)
#CSV.write("C:\\Users\\je4hu\\colrepos\\alocacao_carros_pipa\\Tese\\Dados\\dias_sem_abastecimento.csv", df_resultado)
#CSV.write("quebras_abastecimento.csv", df_quebras)
#CSV.write("/home/guilherme/Codes/PICME/dias_sem_abastecimento.csv", df_resultado)

println("Arquivo CSV gerado com sucesso!")

bp_resultado = boxplot(
    Y,
    label="",
    ylabel="Dias",
    xlabel="",
    title="Quantidade máxima de dias que o beneficiários conseguem ficar sem água"
)
#savefig(bp_resultado, "bp_quebras_abastecimento.png")
print(quebra1)
