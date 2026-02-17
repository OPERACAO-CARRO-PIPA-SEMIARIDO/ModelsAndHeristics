using CSV, DataFrames, Statistics

entregas = CSV.read("/home/guilherme/ModelsAndHeristics/minimizaPicos/resultadosControle/abastecimento_72h.csv", DataFrame)
df_beneficiario = CSV.read("/home/guilherme/repos/backup/AlocacaoCarrosPipas/Dados/Beneficiarios_RN_Ativos1.csv", DataFrame)

U = [round(i * 0.02, digits=2) for i in df_beneficiario.Pessoas_Atendidas]
minimo = sum(U[i] for i in 1:300) * 365 / 13
sums = [sum(skipmissing(col)) for col in eachcol(entregas[:, 2:end])]
maiorPico = maximum(sums)
indiceDiaPico = argmax(sums)
total = sum(sums)
media = total / 365 
diaPico = names(entregas)[2:end][indiceDiaPico]

println("O maior pico de entregas (soma das colunas) foi: ", maiorPico, " na coluna: ", diaPico)
println("Total de entregas: ", total, "\nMedia de entregas por dia: ", media)
println("Minimo necessário: ", minimo)
