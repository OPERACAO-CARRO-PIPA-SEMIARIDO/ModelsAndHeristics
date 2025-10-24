using JuMP
using LinearAlgebra
using CSV
using DataFrames
using Gurobi
# Adicionado para acessar a API de depuração de conflitos (IIS)
using MathOptInterface
const MOI = MathOptInterface

# --- Leitura dos Dados ---
beneficiarios_ativos = CSV.read("/home/guilherme/AlocacaoCarrosPipas/Dados/Beneficiarios_RN_Ativos_test.csv", DataFrame)
dias_uteis = CSV.read("/home/guilherme/AlocacaoCarrosPipas/Dados/datas.csv", DataFrame)
calendarios = CSV.read("/home/guilherme/AlocacaoCarrosPipas/Dados/CalendariosObrigatorios.csv", DataFrame)


# --- Preparação dos Parâmetros ---
calendarioCarnaval = calendarios.carnaval #calendario de entregas obrigatorias para abastecimento durante o periodo de carnaval
entregasObrigatorias = calendarios.lil #calendario de entregas obrigatorias para beneficiarios com reservatorio pequueno
duas_colunas_b = [beneficiarios_ativos.Capacidade, beneficiarios_ativos.Pessoas_Atendidas]

nb = 1:300
nd = 1:90

preU = [round(i * 0.02, digits=2) for i in duas_colunas_b[2]]
preC = convert(Vector{Float64}, duas_colunas_b[1])
U = [preU[j] for j in nb]
C = [preC[j] for j in nb]

#Quantidade de dias que o beneficiario pode passar sem abastecimento
Y = C ./ U

#qubraX, x é o limite de dias   que o beneficiario pode passar sem receber uma entrega
quebra4 = [beneficiario for (beneficiario, x) in zip(nb, Y) if x < 5]
quebra3 = [beneficiario for (beneficiario, x) in zip(nb, Y) if x < 4]
quebra2 = [beneficiario for (beneficiario, x) in zip(nb, Y) if x < 3]

# --- Construção do Modelo ---
model = Model(Gurobi.Optimizer)
set_time_limit_sec(model, 180.0)

#---Variáveis---
#Variavel de entrega
@variable(model, 0 <= x[j in nb, k in nd], Int)
#Variavel de volume
@variable(model, 0 <= V[j in nb, k in nd])
#Variavel de pico
@variable(model, 0 <= y, Int)


# Função Objetivo, minimizar o pico de entregas sendo o total de entregas o desempate
@objective(model, Min, y + 0.001 * sum(x[j, k] for j in nb, k in nd))

#-----Restrições-----
#Restrições de volume
@constraint(model, balancoVolumeInicial[j in nb], V[j, 1] == C[j])
@constraint(model, balancoVolume[j in nb, k in 2:last(nd);
        !(calendarioCarnaval[k] == -1 && j in quebra4) &&
        !(entregasObrigatorias[k] == -1 && j in quebra2)],
    V[j, k] <= V[j, k-1] - U[j] + 13.0 * x[j, k])
@constraint(model, correcaoVolume[j in nb, k in nd;
        (calendarioCarnaval[k] == -1 && j in quebra4) ||
        (entregasObrigatorias[k] == -1 && j in quebra2)],
    V[j, k] == 0)

#Restrição para não entregar em dias não úteis
@constraint(model, diasInuteis[j in nb, k in nd; Int(dias_uteis[k, 1]) == 0], x[j, k] == 0)
#Definir pico como maior soma de entregas em único dia
@constraint(model, maiorPico[k in nd], sum(x[j, k] for j in nb) <= y)
#Restrição para a cisterna não ficar vazia
@constraint(model, volumeMinimo[j in nb, k in nd], V[j, k] >= 0)
#Restrição para o volume não ser menor que a capacidade da cisterna
@constraint(model, capacidadeMax[j in nb, k in nd], V[j, k] <= C[j])
#Restrições de correção para entregas dois dias antes e um dia após um períodos em que os beneficiarios ficariam sem água
@constraint(model, carnavalAbastecimento[j in quebra4, k in nd; calendarioCarnaval[k] == 1], x[j, k] >= 1)
@constraint(model, lilAbastecimento[j in quebra2, k in nd; entregasObrigatorias[k] == 1], x[j, k] >= 1)


"""
Função para resolver o modelo e, se for inviável, depurar e imprimir o conjunto de restrições e variáveis conflitantes (IIS).
"""
function resolve_e_depurar(model_instance)
    tempo_inicio = time()
    optimize!(model_instance)

    # --- SEÇÃO DE DEBUGGER ---
    if termination_status(model_instance) == MOI.INFEASIBLE
        println("------------------------------------------------------")
        println("ATENÇÃO: Modelo inviável. Iniciando depuração de conflitos (IIS)...")

        # Pede ao Gurobi para calcular o conjunto de conflitos
        compute_conflict!(model_instance)

        println("\nRestrições em Conflito:")
        for (F, S) in list_of_constraint_types(model_instance)
            for con in all_constraints(model_instance, F, S)
                if get_attribute(con, MOI.ConstraintConflictStatus()) == MOI.IN_CONFLICT
                    println("  → ", con)
                end
            end
        end

        println("\nVariáveis com Limites em Conflito:")
        for var in all_variables(model_instance)
            if get_attribute(var, MOI.VariableConflictStatus()) == MOI.IN_CONFLICT
                println("  → ", var)
            end
        end
        println("------------------------------------------------------")

        return nothing
    end

    tempo_fim = time()
    tempo_total = tempo_fim - tempo_inicio

    println("Tempo de resolução: ", round(tempo_total, digits=2), " segundos")
    println("Valor da função objetivo: ", objective_value(model_instance))

    return true # Retorna um valor para indicar sucesso
end

# --- Execução e Pós-processamento ---
if resolve_e_depurar(model) !== nothing
    println("Pico máximo de abastecimento: ", round(Int, value(y)))

    column_names_v = Symbol.(["Beneficiarios"; nd...])
    beneficiarios = collect(nb)
    colunas_v = Any[[j for j in beneficiarios]]
    for i in nd
        push!(colunas_v, [value(V[j, i]) for j in beneficiarios])
    end
    df_output_v = DataFrame(colunas_v, column_names_v)
    CSV.write("volumes_diarios.csv", df_output_v)

    column_names_x = Symbol.(["Beneficiarios"; nd...])
    colunas_x = Any[[j for j in beneficiarios]]
    for i in nd
        push!(colunas_x, [round(Int, value(x[j, i])) for j in beneficiarios])
    end
    df_output_x = DataFrame(colunas_x, column_names_x)
    CSV.write("abastecimento_diario.csv", df_output_x)

    println("\nCSVs de abastecimento e volume diarios gerados")
else
    println("\nModelo não foi resolvido devido a conflitos. Nenhum CSV foi gerado.")
end
