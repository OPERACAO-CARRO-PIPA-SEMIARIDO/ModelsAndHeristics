using JuMP
using CSV
using DataFrames
using Gurobi
using MathOptInterface
const MOI = MathOptInterface

const ROTAS_FILE = "C:/Users/lfeli/Documents/AlocacaoCarros/dados/rotas"
const ABASTECIMENTO_FILE = joinpath(@__DIR__, "resultados_minpicos_p00", "abastecimento_melhor_absoluto.csv")
const OUTPUT_ALOCACAO = joinpath(@__DIR__, "alocacao_m2_minpicos_p00.csv")
const OUTPUT_CUSTO = joinpath(@__DIR__, "custos_m2_minpicos_p00.csv")
const NUM_MANANCIAIS = 15
const NUM_MANANCIAIS_TOTAL = 92
const CAPACIDADE_MAX_MANANCIAL = 12

abastecimento = CSV.read(ABASTECIMENTO_FILE, DataFrame)
rotas = CSV.read(ROTAS_FILE, DataFrame)

NUM_DIAS = size(abastecimento, 2) - 1
NUM_BENEFICIARIOS = size(abastecimento, 1)

distancias = rotas.distance_w_factor
NB_TOTAL = length(distancias) ÷ NUM_MANANCIAIS_TOTAL
Dij_completa = transpose(reshape(distancias, (NB_TOTAL, NUM_MANANCIAIS_TOTAL)))
Dij = Dij_completa[1:NUM_MANANCIAIS, 1:NUM_BENEFICIARIOS]
Ajk = Matrix{Float64}(abastecimento[:, 2:end])

println("Dados carregados: $NUM_BENEFICIARIOS benef x $NUM_MANANCIAIS mananciais x $NUM_DIAS dias")

t0 = time()

env = Gurobi.Env()
model = Model(() -> Gurobi.Optimizer(env))
set_optimizer_attribute(model, "OutputFlag", 1)
set_optimizer_attribute(model, "LogToConsole", 1)
set_time_limit_sec(model, 3600.0)
set_optimizer_attribute(model, "NodefileStart", 4.0)
set_optimizer_attribute(model, "MIPFocus", 1)

@variable(model, 0 <= x[i=1:NUM_MANANCIAIS, j=1:NUM_BENEFICIARIOS, k=1:NUM_DIAS; Ajk[j, k] > 0], Int)
@variable(model, y[i=1:NUM_MANANCIAIS, j=1:NUM_BENEFICIARIOS], Bin)

@constraint(model, cap_diaria[i=1:NUM_MANANCIAIS, k=1:NUM_DIAS],
    sum(x[i, j, k] for j in 1:NUM_BENEFICIARIOS if Ajk[j, k] > 0) <= CAPACIDADE_MAX_MANANCIAL)

@constraint(model, atende_dem[j=1:NUM_BENEFICIARIOS, k=1:NUM_DIAS; Ajk[j, k] > 0],
    sum(x[i, j, k] for i in 1:NUM_MANANCIAIS) == Ajk[j, k])

@constraint(model, fonte_unica[j=1:NUM_BENEFICIARIOS],
    sum(y[i, j] for i in 1:NUM_MANANCIAIS) == 1)

@constraint(model, amarra_x_y[i=1:NUM_MANANCIAIS, j=1:NUM_BENEFICIARIOS, k=1:NUM_DIAS; Ajk[j, k] > 0],
    x[i, j, k] <= Ajk[j, k] * y[i, j])

@objective(model, Min,
    sum(Dij[i, j] * x[i, j, k] for i in 1:NUM_MANANCIAIS, j in 1:NUM_BENEFICIARIOS, k in 1:NUM_DIAS if Ajk[j, k] > 0))

optimize!(model)

tempo_exec = time() - t0
status = termination_status(model)
gap_val = try
    MOI.get(model, MOI.RelativeGap())
catch
    0.0
end

println("Status: $status | Tempo: $(round(tempo_exec, digits=1))s | Gap: $(round(gap_val * 100, digits=2))%")

if has_values(model)
    y_opt = value.(y)
    custo = objective_value(model)
    status_s = status == MOI.OPTIMAL ? "Otimo" : "SubOtimo_LimiteTempo"

    df_alocacao = copy(abastecimento)
    for j in 1:NUM_BENEFICIARIOS
        fonte_escolhida = 0
        for i in 1:NUM_MANANCIAIS
            if y_opt[i, j] > 0.5
                fonte_escolhida = i
                break
            end
        end
        for k in 1:NUM_DIAS
            df_alocacao[j, k + 1] = Ajk[j, k] > 0 ? fonte_escolhida : 0
        end
    end

    CSV.write(OUTPUT_ALOCACAO, df_alocacao)
    CSV.write(OUTPUT_CUSTO, DataFrame(
        Tempo_de_Execucao=[tempo_exec],
        Solucao_otima=[custo],
        Status_Solucao=[status_s],
        Gap_Relativo=[gap_val],
    ))
    println("Salvo: $OUTPUT_ALOCACAO")
    println("Salvo: $OUTPUT_CUSTO")
else
    println("ERRO: nenhuma solucao viavel encontrada.")
    CSV.write(OUTPUT_CUSTO, DataFrame(
        Tempo_de_Execucao=[tempo_exec],
        Solucao_otima=[0.0],
        Status_Solucao=[string(status)],
        Gap_Relativo=[NaN],
    ))
    exit(1)
end
