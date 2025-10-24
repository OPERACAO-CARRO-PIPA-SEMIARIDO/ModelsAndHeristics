#Modelo reduzido utilizado para entender o comportamento do gurobi ao resolver o problema
using Gurobi, JuMP, LinearAlgebra, DataFrames, CSV

C = [13, 13, 16, 16, 8, 8, 50, 60, 13, 13, 16, 16, 8, 8, 50, 60, 13, 13, 16, 16, 8, 8, 50, 60]
U = [2, 5, 2, 5, 4, 1.5, 5, 15, 2, 5, 2, 5, 4, 1.5, 5, 15, 2, 5, 2, 5, 4, 1.5, 5, 15]


nd = 1:30
nb = 1:24

model = Model(Gurobi.Optimizer)
set_time_limit_sec(model, 180.0)

@variable(model, 0 <= x[j in nb, k in nd], Int)
@variable(model, 0 <= V[j in nb, k in nd])
@variable(model, 0 <= y, Int)


@objective(model, Min, y + 0.0001 * sum(x[j, k] for j in nb, k in nd))

@constraint(model, balancoVolumeInicial[j in nb], V[j, 1] == C[j])

@constraint(model, balancoVolume[j in nb, k in 2:last(nd)], V[j, k] <= V[j, k-1] - U[j] + 13.0 * x[j, k])

#@constraint(model, diasInuteis[j in nb, k in nd; Int(dias_uteis[k, 1]) == 0], x[j, k] == 0)

@constraint(model, maiorPico[k in nd], sum(x[j, k] for j in nb) <= y)

@constraint(model, volumeMinimo[j in nb, k in nd], V[j, k] >= 0)

@constraint(model, capacidadeMax[j in nb, k in nd], V[j, k] <= C[j])

tempo_inicio = time()
optimize!(model)
tempo_fim = time()
tempo_total = tempo_fim - tempo_inicio

println("Tempo de resolução: ", round(tempo_total, digits=2), " segundos")
println("Valor da função objetivo: ", objective_value(model))
println("Pico máximo de abastecimento: ", round(Int, value(y)))

column_names_v = Symbol.(["Beneficiarios"; nd...])
beneficiarios = collect(nb)
colunas_v = Any[[j for j in beneficiarios]]
for i in nd
    push!(colunas_v, [value(V[j, i]) for j in beneficiarios])
end
df_output_v = DataFrame(colunas_v, column_names_v)
CSV.write("miniVolume.csv", df_output_v)

column_names_x = Symbol.(["0"; nd...])
colunas_x = Any[[j for j in beneficiarios]]
for i in nd
    push!(colunas_x, [round(Int, value(x[j, i])) for j in beneficiarios])
end
df_output_x = DataFrame(colunas_x, column_names_x)
CSV.write("miniAbastecimento.csv", df_output_x)



