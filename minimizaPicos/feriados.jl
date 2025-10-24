using CSV
using DataFrames

# Lê os dados
#df = CSV.read("C:/Users/HP/OneDrive/Desktop/Mestrado/Tese/Dados/datas.csv", DataFrame)
df = CSV.read("/home/guilherme/AlocacaoCarrosPipas/Dados/datas.csv", DataFrame)

# Suponho que a coluna com os dias úteis esteja chamada de "dia_util"
dias = df.dia_util

# Encontrar sequências consecutivas de dias não úteis
seqs = Int[]
contador = 0
print(dias)
for d in dias
    if d == 0
        global contador += 1
    elseif contador > 0
        push!(seqs, contador)
        global contador = 0
    end
end
if contador > 0
    push!(seqs, contador)
end

# Criar DataFrame com o resumo
resumo = combine(groupby(DataFrame(tamanho=seqs), :tamanho), nrow => :ocorrencias)

println(resumo)