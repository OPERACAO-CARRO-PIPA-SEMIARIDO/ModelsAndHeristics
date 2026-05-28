using JuMP
using LinearAlgebra
using CSV
using DataFrames
using Gurobi

# ==========================================
# 1. LEITURA DOS ARGUMENTOS VIA TERMINAL
# ==========================================
if length(ARGS) < 5
    println("ERRO: Faltam argumentos para o M1 Anual.")
    println("Uso: julia m1_anual.jl <ABASTECIMENTO_CSV> <OUTPUT_ALOCACAO_CSV> <OUTPUT_CUSTO_CSV> <ROTAS_CSV> <NUM_MANANCIAIS>")
    exit(1)
end

ABASTECIMENTO_FILE = ARGS[1]
OUTPUT_ALOCACAO = ARGS[2]
OUTPUT_CUSTO = ARGS[3]
ROTAS_FILE = ARGS[4]
NUM_MANANCIAIS_TESTE = parse(Int, ARGS[5])

# ==========================================
# 2. LEITURA E PREPARAÇÃO DOS DADOS
# ==========================================
abastecimento = CSV.read(ABASTECIMENTO_FILE, DataFrame, header=true)
rotas = CSV.read(ROTAS_FILE, DataFrame)

NUM_DIAS = size(abastecimento, 2) - 1
NUM_MANANCIAIS_TOTAL = 92
NUM_MANANCIAIS = NUM_MANANCIAIS_TESTE
NUM_BENEFICIARIOS = size(abastecimento, 1)
NB_TOTAL_ROTAS = 3315
CAPACIDADE_MAX_MANANCIAL = 12

distancias = rotas.distance_w_factor
Dij_completa = transpose(reshape(distancias, (NB_TOTAL_ROTAS, NUM_MANANCIAIS_TOTAL)))
Dij = Dij_completa[1:NUM_MANANCIAIS, 1:NUM_BENEFICIARIOS]
Ajk = Matrix{Float64}(abastecimento[:, 2:end])

# ==========================================
# 3. MODELO MATEMÁTICO - M1 ANUAL (SEM RESTRIÇÃO DE FONTE ÚNICA)
# Diferença do M2: beneficiários podem receber de mananciais diferentes ao longo do ano.
# Resolve o ano inteiro como um único ILP, mas sem fixar a fonte por beneficiário.
# ==========================================
function resolve_M1_anual(NM, NB, ND, matriz_dist, matriz_demanda, cap_max)
    t0 = time()

    env      = Gurobi.Env()
    linModel = Model(() -> Gurobi.Optimizer(env))
    set_silent(linModel)
    set_time_limit_sec(linModel, 86400.0)

    @variable(linModel, 0 <= x[i=1:NM, j=1:NB, k=1:ND; matriz_demanda[j,k] > 0], Int)

    @constraint(linModel, cap[i=1:NM, k=1:ND],
        sum(x[i,j,k] for j in 1:NB if matriz_demanda[j,k] > 0) <= cap_max)

    @constraint(linModel, dem[j=1:NB, k=1:ND; matriz_demanda[j,k] > 0],
        sum(x[i,j,k] for i in 1:NM) == matriz_demanda[j,k])

    @objective(linModel, Min,
        sum(matriz_dist[i,j] * x[i,j,k]
            for i in 1:NM, j in 1:NB, k in 1:ND if matriz_demanda[j,k] > 0))

    optimize!(linModel)
    tempo_exec = time() - t0

    status = termination_status(linModel)

    gap_val = try MOI.get(linModel, MOI.RelativeGap()) catch; 0.0 end

    if status == MOI.OPTIMAL
        return value.(x), objective_value(linModel), tempo_exec, "Otimo", gap_val
    elseif status == MOI.TIME_LIMIT && has_values(linModel)
        println("AVISO: Limite de tempo atingido. Solução subótima retornada.")
        return value.(x), objective_value(linModel), tempo_exec, "SubOtimo_LimiteTempo", gap_val
    else
        println("ERRO: Nenhuma solução viável encontrada. Status: $(status)")
        return nothing, 0.0, tempo_exec, string(status), NaN
    end
end

x_opt, custo_total, tempo_exec, status_str, gap_relativo =
    resolve_M1_anual(NUM_MANANCIAIS, NUM_BENEFICIARIOS, NUM_DIAS, Dij, Ajk, CAPACIDADE_MAX_MANANCIAL)

if x_opt !== nothing
    df_alocacao = copy(abastecimento)

    for j in 1:NUM_BENEFICIARIOS
        for k in 1:NUM_DIAS
            if Ajk[j, k] > 0
                # Grava o manancial com o maior número de viagens (correto para demanda > 1)
                fonte_escolhida = 0
                max_viagens     = 0.0
                for i in 1:NUM_MANANCIAIS
                    val = x_opt[i, j, k]
                    if val > max_viagens
                        max_viagens     = val
                        fonte_escolhida = i
                    end
                end
                df_alocacao[j, k + 1] = fonte_escolhida
            else
                df_alocacao[j, k + 1] = 0
            end
        end
    end

    df_metricas = DataFrame(
        Tempo_de_Execucao = [tempo_exec],
        Solucao_otima     = [custo_total],
        Status_Solucao    = [status_str],
        Gap_Relativo      = [gap_relativo]
    )

    CSV.write(OUTPUT_CUSTO,    df_metricas)
    CSV.write(OUTPUT_ALOCACAO, df_alocacao)
else
    df_metricas = DataFrame(
        Tempo_de_Execucao = [tempo_exec],
        Solucao_otima     = [0.0],
        Status_Solucao    = [status_str],
        Gap_Relativo      = [gap_relativo]
    )
    CSV.write(OUTPUT_CUSTO, df_metricas)
    println("Nenhuma solução exportada.")
    exit(1)
end
