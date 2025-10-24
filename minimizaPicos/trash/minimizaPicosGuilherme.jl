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
beneficiarios_carnaval = CSV.read("/home/guilherme/AlocacaoCarrosPipas/Dados/ProblematicosCarnaval.csv", DataFrame)
calendarios = CSV.read("/home/guilherme/AlocacaoCarrosPipas/Dados/CalendariosObrigatorios.csv", DataFrame)

# --- Preparação dos Parâmetros ---
quebraCarnaval = beneficiarios_carnaval.BeneficiariosProblematicos
calendarioCarnaval = calendarios.carnaval
entregasObrigatorias = calendarios.lil
lils = [1595, 2997]
duas_colunas_b = [beneficiarios_ativos.Capacidade, beneficiarios_ativos.Pessoas_Atendidas]
nb = 1:3315
nd = 1:365

U = [round(i * 0.02, digits=2) for i in duas_colunas_b[2]]
C = convert(Vector{Float64}, duas_colunas_b[1])
# --- Construção do Modelo ---
model = Model(Gurobi.Optimizer)
set_time_limit_sec(model, 1800.0)

# Variáveis
@variable(model, 0 <= x[j in nb, k in nd], Int)
@variable(model, 0 <= V[j in nb, k in nd])
@variable(model, 0 <= y, Int)
@variable(model, desperdicio[j in nb, k in nd] >= 0)


# Função Objetivo
@objective(model, Min, y + 0.001 * sum(x[j, k] for j in nb, k in nd) + 0.01 * sum(desperdicio[j, k] for j in nb, k in nd))

# Restrições
@constraint(model, balancoVolumeInicial[j in nb], V[j, 1] == C[j])

@constraint(model, balancoVolume[j in nb, k in 2:last(nd);
        !(calendarioCarnaval[k] == -1 && j in quebraCarnaval) &&
        !(entregasObrigatorias[k] == -1 && j in lils)],
    V[j, k] + desperdicio[j, k] == V[j, k-1] - U[j] + 13.0 * x[j, k])

@constraint(model, correcaoVolume[j in nb, k in nd;
        (calendarioCarnaval[k] == -1 && j in quebraCarnaval) ||
        (entregasObrigatorias[k] == -1 && j in lils)],
    V[j, k] == 0)

@constraint(model, diasInuteis[j in nb, k in nd; Int(dias_uteis[k, 1]) == 0], x[j, k] == 0)

@constraint(model, maiorPico[k in nd], sum(x[j, k] for j in nb) <= y)

@constraint(model, volumeMinimo[j in nb, k in nd], V[j, k] >= 0)

@constraint(model, capacidadeMax[j in nb, k in nd], V[j, k] <= C[j])

@constraint(model, carnavalAbastecimento[j in quebraCarnaval, k in nd; calendarioCarnaval[k] == 1], x[j, k] >= 1)

@constraint(model, lilAbastecimento[j in lils, k in nd; entregasObrigatorias[k] == 1], x[j, k] >= 1)


function resolve_e_depurar(model_instance)
    tempo_inicio = time()
    optimize!(model_instance)

    if termination_status(model_instance) == MOI.INFEASIBLE
        println("------------------------------------------------------")
        println("ATENÇÃO: Modelo inviável. Iniciando depuração de conflitos (IIS)...")

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

    println("\nModelo resolvido com sucesso!")
    println("Tempo de resolução: ", round(tempo_total, digits=2), " segundos")
    println("Valor da função objetivo: ", objective_value(model_instance))

    return true
end

# --- Execução e Pós-processamento ---
if resolve_e_depurar(model) !== nothing
    println("Pico máximo de abastecimento: ", round(Int, value(y)))

    # Exportar volumes para CSV
    println("Gerando CSV de volumes diários...")
    column_names_v = Symbol.(["Beneficiarios"; nd...])
    beneficiarios = collect(nb)
    # ALTERAÇÃO: Inicializa 'colunas_v' como um vetor do tipo Any
    # para permitir colunas de tipos diferentes (Int para a primeira, Float64 para as outras).
    colunas_v = Any[[j for j in beneficiarios]]
    for i in nd
        push!(colunas_v, [value(V[j, i]) for j in beneficiarios])
    end
    df_output_v = DataFrame(colunas_v, column_names_v)
    CSV.write("volumes_diarios.csv", df_output_v)

    # Exportar abastecimentos para CSV
    println("Gerando CSV de abastecimentos diários...")
    column_names_x = Symbol.(["Beneficiarios"; nd...])
    # ALTERAÇÃO: Inicializa 'colunas_x' como um vetor do tipo Any por segurança.
    colunas_x = Any[[j for j in beneficiarios]]
    for i in nd
        push!(colunas_x, [round(Int, value(x[j, i])) for j in beneficiarios])
    end
    df_output_x = DataFrame(colunas_x, column_names_x)
    CSV.write("abastecimento_diario.csv", df_output_x)

    println("\nCSVs gerados com sucesso!")
else
    println("\nModelo não foi resolvido devido a conflitos. Nenhum CSV foi gerado.")
end
