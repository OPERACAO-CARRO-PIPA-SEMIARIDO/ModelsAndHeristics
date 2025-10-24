using JuMP
#using HiGHS
using LinearAlgebra
using CSV
using DataFrames
using Gurobi


#beneficiarios_ativos= CSV.read("C:\\Users\\je4hu\\colrepos\\alocacao_carros_pipa\\Tese\\Dados\\Beneficiarios_RN_Ativos.xlsx - Planilha1.csv",DataFrame)
#dias_uteis= CSV.read("C:\\Users\\je4hu\\colrepos\\alocacao_carros_pipa\\Tese\\Dados\\datas.csv",DataFrame)
beneficiarios_ativos = CSV.read("/home/guilherme/AlocacaoCarrosPipas/Dados/Beneficiarios_RN_Ativos_test.csv", DataFrame)
dias_uteis = CSV.read("/home/guilherme/AlocacaoCarrosPipas/Dados/datas.csv", DataFrame)
beneficiarios_carnaval = CSV.read("/home/guilherme/AlocacaoCarrosPipas/Dados/ProblematicosCarnaval.csv", DataFrame)
calendarios = CSV.read("/home/guilherme/AlocacaoCarrosPipas/Dados/CalendariosObrigatorios.csv", DataFrame)

quebraCarnaval = beneficiarios_carnaval.BeneficiariosProblematicos
calendarioCarnaval = calendarios.carnaval
entregasObrigatorias = calendarios.lil

duas_colunas_b = [beneficiarios_ativos.Capacidade,beneficiarios_ativos.Pessoas_Atendidas] 

# nb = 1:length(duas_colunas_b[1])
nb = 1:2997
# nd = 1:length(dias_uteis[:,1])
nd = 1:365

U = [round(i*0.02, digits=2) for i in duas_colunas_b[2]] # cria vetor de consumo diario

# U[1:34]

C = convert(Vector{Float64}, duas_colunas_b[1])
#C = [parse(Float64, replace(s, "," => ".")) for s in duas_colunas_b[1]]
# C[165:172]


model = Model(Gurobi.Optimizer)
set_time_limit_sec(model, 180.0)

# variavel de abastecimento
@variable(model, 0 <= x[j in nb, k in nd], Int)

# variavel de volume
@variable(model, 0 <= V[j in nb , k in nd])

# variavel de pico de abastecimento
@variable(model, 0 <= y, Int)

# Variaveis de folga para descobrir onde está infactivel
# @variable(model, 0 <= s1[j in nb, k in nd])
# @variable(model, 0 <= s2[j in nb, k in nd])


# funcao objetivo
@objective(model, Min, y + 0.001*sum(x[j,k] for j in nb, k in nd)) 
# + sum(s1[j,k] for j in nb, k in nd)
# acrescentar variavel de folga nas restrições e minimizar elas

# restricao de volume no primeiro dia
@constraint(model, balancoVolumeInicial[j in nb] , V[j,1] == C[j])

# restricao de decaimento de volume
#@constraint(model, balancoVolume[j in nb , k=2:length(nd)] , V[j,k] <= V[j, k-1] - U[j] + 13*x[j,k])
@constraint(model, balancoVolume[j in nb, k in 2:last(nd) ; 
    !(calendarioCarnaval[k] == -1 && j in quebraCarnaval) &&
    !(entregasObrigatorias[k] == -1 && j == 2997)], 
    V[j,k] <= V[j, k-1] - U[j] + 13*x[j,k])


# restricao de nao entregar em dias nao uteis
@constraint(model, diasInuteis[j in nb, k in nd ; Int(dias_uteis[k,1]) == 0], x[j,k] == 0)

# restricao para y ser o maior pico de entrega
@constraint(model, maiorPico[k in nd], sum(x[j,k] for j in nb) <= y)

# restricao para volume nao ser menor que o minimo
@constraint(model, volumeMinimo[j in nb, k in nd] , V[j,k] >= U[j])
# + s1[j,k]
# restricao de capacidade maxima da cisterna
@constraint(model, capacidadeMax[j in nb, k in nd],  V[j,k] <= C[j])

#restricao entregas obrigatorias carnaval, e ajuste no volume
@constraint(model, carnavalAbastecimento[j in quebraCarnaval, k in nd ; calendarioCarnaval[k] == 1], x[j, k] == 1)
#@constraint(model, carnavalVolume[j in quebraCarnaval, k in nd ; calendarioCarnaval[k] == -1], V[j, k] == U[j])

#restricoes de ajuste do beneficiario 2997
@constraint(model, lilAbastecimento[k in nd ; entregasObrigatorias[k] == 1], x[2997, k] == 1)
#@constraint(model, lilVolume[k in nd ; entregasObrigatorias[k] == -1], V[2997, k] == U[2997])

function resolvepl(model_instance)
    tempo_inicio = time()
    optimize!(model_instance)
    if termination_status(model_instance) == MOI.INFEASIBLE
    # Compute and print the IIS
        compute_conflict!(model_instance)
        return nothing
    end
    tempo_fim = time()
    tempo_total = tempo_fim - tempo_inicio

    print(tempo_total)
    println(objective_value(model_instance))

    return tempo_total, objective_value(model_instance), num_variables(model_instance)
end

resolvepl(model)

println(value(y))

# passar variaveis para csv
# variaveis de volume V[j,k]
column_names = []
push!(column_names, "Beneficiarios")
append!(column_names , [i for i in nd])
column_names = Symbol.(column_names)


beneficiarios = collect(nb)
colunas = []
push!(colunas, [i for i in beneficiarios])
for i in nd
    coluna = [value(V[j,i]) for j in beneficiarios]
    push!(colunas, coluna)
end

df_output = DataFrame(colunas, column_names)

CSV.write("volumes_diarios.csv", df_output)

# variaveis de volume x[j,k]
colunasx = []
push!(colunasx, [i for i in beneficiarios])
for i in nd
    coluna = [value(x[j,i]) for j in beneficiarios]
    push!(colunasx, coluna)
end
df_output = DataFrame(colunasx, column_names)


CSV.write("abastecimento_diario.csv", df_output)


# colunas = []
# push!(colunas, [i for i in beneficiarios])
# for i in nd
#     coluna = [value(s1[j,i]) for j in beneficiarios]
#     push!(colunas, coluna)
# end

# df_output = DataFrame(colunas, column_names)

# CSV.write("folga_diarios.csv", df_output)
