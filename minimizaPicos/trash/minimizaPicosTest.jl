using JuMP
using LinearAlgebra
using CSV
using DataFrames
using Gurobi
using MathOptInterface
const MOI = MathOptInterface

# --- Constantes e Parâmetros Chave ---
const VOLUME_CARRO_PIPA = 13.0
const LIMITE_TEMPO_SEGUNDOS = 180.0 # Aumentado para 5 minutos
const TOLERANCIA_MIPGAP = 0.05 # Aceita soluções 5% ótimas

# --- Leitura e Preparação dos Dados ---
println("Carregando e preparando os dados...")

beneficiarios_ativos = CSV.read("/home/guilherme/AlocacaoCarrosPipas/Dados/Beneficiarios_RN_Ativos_test.csv", DataFrame)
dias_uteis = CSV.read("/home/guilherme/AlocacaoCarrosPipas/Dados/datas.csv", DataFrame)
beneficiarios_carnaval = CSV.read("/home/guilherme/AlocacaoCarrosPipas/Dados/ProblematicosCarnaval.csv", DataFrame)
calendarios = CSV.read("/home/guilherme/AlocacaoCarrosPipas/Dados/CalendariosObrigatorios.csv", DataFrame)

# Definição dos índices do modelo
indices_beneficiarios = 1:nrow(beneficiarios_ativos)
indices_dias = 1:nrow(dias_uteis)

# Parâmetros do modelo (consumo, capacidade, etc.)
U = round.(beneficiarios_ativos.Pessoas_Atendidas .* 0.02, digits=2)
C = convert(Vector{Float64}, beneficiarios_ativos.Capacidade)

# Conjuntos (Sets) para checagens de pertencimento rápidas e eficientes
lils_set = Set([1595, 2997])
quebraCarnaval_set = Set(beneficiarios_carnaval.BeneficiariosProblematicos)
calendarioCarnaval_dias = calendarios.carnaval
entregasObrigatorias_dias = calendarios.lil

# --- Construção do Modelo de Otimização ---
println("Construindo o modelo JuMP...")

# CORREÇÃO: Inicializa o Gurobi com parâmetros chave usando `optimizer_with_attributes`
model = Model(Gurobi.Optimizer)
set_time_limit_sec(model, 180.0)


# --- Variáveis de Decisão ---
@variable(model, x[j in indices_beneficiarios, k in indices_dias], Bin) # 1 se houver abastecimento, 0 caso contrário
@variable(model, V[j in indices_beneficiarios, k in indices_dias] >= 0) # Volume no final do dia
@variable(model, y >= 0, Int) # Pico máximo de entregas em um único dia

# --- Função Objetivo ---
@objective(model, Min, y + 0.001 * sum(x))

# --- Restrições do Modelo ---
# VERSÃO HÍBRIDA: Sintaxe original para restrições complexas, mantendo as outras melhorias.

# Adiciona um limite inferior mais forte para 'y', ajudando o solver
consumo_total_periodo = sum(U) * length(indices_dias)
media_entregas_diarias = consumo_total_periodo / VOLUME_CARRO_PIPA / length(indices_dias)
@constraint(model, y_lower_bound, y >= ceil(Int, media_entregas_diarias))

# Restrição de balanço de volume (unificada e corrigida)
@constraint(model, balancoVolume[j in indices_beneficiarios, k in indices_dias],
    V[j,k] == (k == 1 ? C[j] : V[j, k-1]) - U[j] + VOLUME_CARRO_PIPA * x[j,k])

# Restrição de capacidade máxima, revertida para a sintaxe original
@constraint(model, capacidadeMax[j in indices_beneficiarios, k in indices_dias;
    !(j in quebraCarnaval_set && calendarioCarnaval_dias[k] == 1) &&
    !(j in lils_set && entregasObrigatorias_dias[k] == 1)],
    V[j,k] <= C[j])

# Força o não abastecimento em dias não úteis, revertida para a sintaxe original
@constraint(model, diasInuteis[j in indices_beneficiarios, k in indices_dias; Int(dias_uteis[k,1]) == 0],
    x[j,k] == 0)

# Vincula a variável 'y' ao pico máximo de entregas diárias
@constraint(model, maiorPico[k in indices_dias], sum(x[:, k]) <= y)

# Força o abastecimento em dias específicos para grupos especiais
@constraint(model, carnavalAbastecimento[j in quebraCarnaval_set, k in findall(==(1), calendarioCarnaval_dias)], x[j, k] == 1)
@constraint(model, lilAbastecimento[j in lils_set, k in findall(==(1), entregasObrigatorias_dias)], x[j, k] == 1)


"""
Função para resolver o modelo e depurar conflitos (IIS) em caso de inviabilidade.
"""
function resolve_e_depurar(model_instance)
    println("\nOtimização iniciada pelo Gurobi...")
    tempo_inicio = time()
    optimize!(model_instance)
    status = termination_status(model_instance)

    if status == MOI.INFEASIBLE
        println("\n------------------------------------------------------")
        println("ATENÇÃO: Modelo inviável. Iniciando depuração de conflitos (IIS)...")
        compute_conflict!(model_instance)

        println("\nRestrições em Conflito:")
        for (F, S) in list_of_constraint_types(model_instance)
            for con in all_constraints(model_instance, F, S)
                if get_attribute(con, MOI.ConstraintConflictStatus()) == MOI.IN_CONFLICT
                    println("  → ", name(con), "[", index(con), "]: ", constraint_object(con))
                end
            end
        end
        println("------------------------------------------------------")
        return false
    end

    tempo_fim = time()
    tempo_total = tempo_fim - tempo_inicio

    println("\nOtimização finalizada!")
    println("Status da Solução: ", raw_status(model_instance))
    println("Tempo de resolução: ", round(tempo_total, digits=2), " segundos")
    
    if has_values(model_instance)
        println("Valor da função objetivo: ", round(objective_value(model_instance), digits=4))
        return true
    else
        println("Nenhuma solução viável foi encontrada dentro dos limites de tempo/gap.")
        return false
    end
end

# --- Execução e Pós-processamento ---
if resolve_e_depurar(model)
    println("\nPós-processando resultados...")
    println("Pico máximo de abastecimento diário: ", round(Int, value(y)))

    # Supondo que a coluna de ID no seu CSV se chama 'id_beneficiario'
    id_beneficiarios = beneficiarios_ativos.id_beneficiario

    # Exporta volumes diários para CSV
    println("Gerando CSV de volumes...")
    volumes_matrix = value.(V)
    df_volumes = DataFrame(volumes_matrix, Symbol.(indices_dias))
    insertcols!(df_volumes, 1, :Beneficiario => id_beneficiarios)
    CSV.write("volumes_diarios.csv", df_volumes)

    # Exporta decisões de abastecimento diário para CSV
    println("Gerando CSV de abastecimentos...")
    abastecimentos_matrix = round.(Int, value.(x))
    df_abastecimentos = DataFrame(abastecimentos_matrix, Symbol.(indices_dias))
    insertcols!(df_abastecimentos, 1, :Beneficiario => id_beneficiarios)
    CSV.write("abastecimento_diario.csv", df_abastecimentos)

    println("\nCSVs gerados com sucesso!")
else
    println("\nO modelo não foi resolvido. Nenhum CSV foi gerado.")
end

