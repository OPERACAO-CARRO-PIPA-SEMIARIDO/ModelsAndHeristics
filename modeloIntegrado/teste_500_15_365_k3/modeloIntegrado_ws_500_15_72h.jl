using JuMP
using LinearAlgebra
using CSV
using DataFrames
using Gurobi
using MathOptInterface
const MOI = MathOptInterface

const BASE_PATH = "C:/Users/lfeli/Documents/AlocacaoCarros/dados/"
const TEST_DIR = @__DIR__
const TOTAL_MANANCIAIS_ARQUIVO = 92
const CAPACIDADE_MAX_MANANCIAL = 12

const TOTAL_BENEFICIARIOS = 500
const TOTAL_MANANCIAIS = 15
const TOTAL_DIAS = 365
const NUM_CANDIDATOS = 3

beneficiarios_ativos = CSV.read(BASE_PATH * "Beneficiarios_RN_Ativos1.csv", DataFrame)
dias_uteis = CSV.read(BASE_PATH * "datas.csv", DataFrame)
calendarios = CSV.read(BASE_PATH * "CalendariosObrigatorios.csv", DataFrame)
rotas = CSV.read(BASE_PATH * "rotas", DataFrame)

calendarioCarnaval = calendarios.carnaval
entregasObrigatorias = calendarios.lil

TOTAL_BENEFICIARIOS_ARQUIVO = size(beneficiarios_ativos, 1)

nb = 1:TOTAL_BENEFICIARIOS
nd = 1:TOTAL_DIAS
nm = 1:TOTAL_MANANCIAIS

qtd_dias_uteis = sum(dias_uteis[nd, 1])

preU_full = [round(i * 0.02, digits=2) for i in beneficiarios_ativos.Pessoas_Atendidas]
U = preU_full[nb]

C_full = convert(Vector{Float64}, beneficiarios_ativos.Capacidade)
C = C_full[nb]

Y = C ./ U
quebra4 = [j for (j, x) in zip(nb, Y) if x < 5]
quebra2 = [j for (j, x) in zip(nb, Y) if x < 3]

distancias = rotas.distance_w_factor
Dij_completa = transpose(reshape(distancias, (TOTAL_BENEFICIARIOS_ARQUIVO, TOTAL_MANANCIAIS_ARQUIVO)))
Dij = Dij_completa[nm, nb]

CANDIDATOS_REAIS = min(NUM_CANDIDATOS, TOTAL_MANANCIAIS)
candidatos_por_beneficiario = Dict{Int, Vector{Int}}()
for j in nb
    fontes_ordenadas = sortperm(Dij[:, j])
    candidatos_por_beneficiario[j] = fontes_ordenadas[1:CANDIDATOS_REAIS]
end

function rodar_modelo_integrado(p::Float64, nome_pasta::String;
                                abastecimento_warm_start=nothing,
                                alocacao_warm_start=nothing)
    caminho_pasta = isabspath(nome_pasta) ? nome_pasta : joinpath(TEST_DIR, nome_pasta)
    if !isdir(caminho_pasta)
        mkpath(caminho_pasta)
    end

    model = Model(Gurobi.Optimizer)
    set_optimizer_attribute(model, "OutputFlag", 1)
    set_optimizer_attribute(model, "LogToConsole", 1)
    set_optimizer_attribute(model, "LogFile", joinpath(caminho_pasta, "gurobi.log"))
    set_optimizer_attribute(model, "NodefileDir", caminho_pasta)
    set_optimizer_attribute(model, "NodefileStart", 1.0)
    set_optimizer_attribute(model, "MemLimit", 18.0)
    set_optimizer_attribute(model, "Threads", 2)
    set_optimizer_attribute(model, "MIPFocus", 1)

    @variable(model, 0 <= x[j in nb, i in candidatos_por_beneficiario[j], k in nd], Int)
    @variable(model, z[j in nb, i in candidatos_por_beneficiario[j]], Bin)
    @variable(model, 0 <= y_pico, Int)
    @variable(model, 0 <= V[j in nb, k in 0:last(nd)])

    @expression(model, expr_pico, qtd_dias_uteis * y_pico)
    @expression(model, expr_custo, sum(Dij[i, j] * x[j, i, k] for j in nb, i in candidatos_por_beneficiario[j], k in nd))
    @expression(model, expr_entregas, sum(x[j, i, k] for j in nb, i in candidatos_por_beneficiario[j], k in nd))

    @objective(model, Min, (p * expr_pico) + ((1 - p) * expr_custo))

    @constraint(model, balancoVolumeInicial[j in nb], V[j, 0] == C[j])

    @constraint(model, balancoVolume[j in nb, k in 1:last(nd);
            !(calendarioCarnaval[k] == -1 && j in quebra4) &&
            !(entregasObrigatorias[k] == -1 && j in quebra2)],
        V[j, k] <= V[j, k - 1] - U[j] + 13.0 * sum(x[j, i, k] for i in candidatos_por_beneficiario[j]))

    @constraint(model, correcaoVolume[j in nb, k in nd;
            (calendarioCarnaval[k] == -1 && j in quebra4) ||
            (entregasObrigatorias[k] == -1 && j in quebra2)],
        V[j, k] == 0)

    @constraint(model, diasInuteis[j in nb, k in nd; Int(dias_uteis[k, 1]) == 0],
        sum(x[j, i, k] for i in candidatos_por_beneficiario[j]) == 0)

    @constraint(model, restMaiorPico[k in nd],
        sum(x[j, i, k] for j in nb, i in candidatos_por_beneficiario[j]) <= y_pico)

    @constraint(model, volumeMinimo[j in nb, k in 0:last(nd)], V[j, k] >= 0)
    @constraint(model, capacidadeMax[j in nb, k in 0:last(nd)], V[j, k] <= C[j])

    @constraint(model, carnavalAbastecimento[j in quebra4, k in nd; calendarioCarnaval[k] == 1],
        sum(x[j, i, k] for i in candidatos_por_beneficiario[j]) >= 1)

    @constraint(model, lilAbastecimento[j in quebra2, k in nd; entregasObrigatorias[k] == 1],
        sum(x[j, i, k] for i in candidatos_por_beneficiario[j]) >= 1)

    @constraint(model, fonteUnica[j in nb],
        sum(z[j, i] for i in candidatos_por_beneficiario[j]) == 1)

    @constraint(model, amarra_z_x[j in nb, k in nd, i in candidatos_por_beneficiario[j]],
        x[j, i, k] <= CAPACIDADE_MAX_MANANCIAL * z[j, i])

    @constraint(model, capDiariaManancial[i in nm, k in nd;
            !isempty([j for j in nb if i in candidatos_por_beneficiario[j]])],
        sum(x[j, i, k] for j in nb if i in candidatos_por_beneficiario[j]) <= CAPACIDADE_MAX_MANANCIAL)

    z_hint = Dict{Int, Int}(j => candidatos_por_beneficiario[j][1] for j in nb)
    n_heu_usados = 0

    if !isnothing(alocacao_warm_start) && isfile(alocacao_warm_start)
        try
            df_aloc = CSV.read(alocacao_warm_start, DataFrame)
            for row_idx in 1:size(df_aloc, 1)
                j_id = hasproperty(df_aloc, :Beneficiarios) ? df_aloc[row_idx, :Beneficiarios] : df_aloc[row_idx, 1]
                if !(j_id in nb)
                    continue
                end
                for k in nd
                    col_sym = Symbol(string(k))
                    if hasproperty(df_aloc, col_sym)
                        val_i = df_aloc[row_idx, col_sym]
                        if !ismissing(val_i) && val_i > 0
                            fonte = Int(val_i)
                            if fonte in candidatos_por_beneficiario[j_id]
                                z_hint[j_id] = fonte
                                n_heu_usados += 1
                            end
                            break
                        end
                    end
                end
            end
        catch e
            println(">>> Aviso warm start z: $e")
        end
    end

    for j in nb
        fonte = z_hint[j]
        set_start_value(z[j, fonte], 1.0)
        for i in candidatos_por_beneficiario[j]
            if i != fonte
                set_start_value(z[j, i], 0.0)
            end
        end
    end

    if !isnothing(abastecimento_warm_start) && isfile(abastecimento_warm_start)
        try
            df_abast = CSV.read(abastecimento_warm_start, DataFrame)
            pico_ws = 0
            for row_idx in 1:size(df_abast, 1)
                j_id = hasproperty(df_abast, :Beneficiarios) ? df_abast[row_idx, :Beneficiarios] : df_abast[row_idx, 1]
                if !(j_id in nb)
                    continue
                end
                fonte = z_hint[j_id]
                for k in nd
                    col_sym = Symbol(string(k))
                    if hasproperty(df_abast, col_sym)
                        val_x = df_abast[row_idx, col_sym]
                        if !ismissing(val_x) && val_x > 0
                            set_start_value(x[j_id, fonte, k], Float64(val_x))
                        end
                    end
                end
            end
            for k in nd
                col_sym = Symbol(string(k))
                if hasproperty(df_abast, col_sym)
                    soma = sum(skipmissing(df_abast[!, col_sym]))
                    if soma > pico_ws
                        pico_ws = round(Int, soma)
                    end
                end
            end
            if pico_ws > 0
                set_start_value(y_pico, Float64(pico_ws))
            end
        catch e
            println(">>> Aviso warm start x: $e")
        end
    end

    println(">>> Warm start: heuristica/minpicos aplicada em $n_heu_usados beneficiarios.")

    horas_checkpoints = 3:3:72
    segundos_checkpoints = Float64.(horas_checkpoints .* 3600)

    df_historico = DataFrame(
        Hora=Int[],
        Tempo_Segundos=Float64[],
        Objective_HigherBound=Float64[],
        Best_LowerBound=Float64[],
        Gap_Percent=Float64[],
        Pico_Y=Int[],
        Custo_Roteamento=Float64[],
        Qtd_Entregas=Int[],
    )

    tempo_acumulado = 0.0
    melhor_obj_encontrado = Inf

    for (hora, meta_tempo) in zip(horas_checkpoints, segundos_checkpoints)
        tempo_restante = meta_tempo - tempo_acumulado
        if tempo_restante <= 0
            continue
        end

        set_optimizer_attribute(model, "TimeLimit", tempo_restante)

        try
            optimize!(model)
        catch e
            if isa(e, InterruptException)
                println("Execucao interrompida manualmente na hora $hora.")
                if has_values(model)
                    salvar_saidas(model, caminho_pasta, "$(hora)h_INT")
                end
                return
            else
                println("\nErro Fatal: $e")
                if has_values(model)
                    println(">>> Salvando melhor incumbente disponivel apos erro na hora $hora.")
                    salvar_saidas(model, caminho_pasta, "$(hora)h_ERRO")
                    salvar_saidas(model, caminho_pasta, "melhor_absoluto")
                end
                break
            end
        end

        tempo_acumulado = meta_tempo

        if has_values(model)
            obj = objective_value(model)
            bound = try
                objective_bound(model)
            catch
                -1.0
            end
            gap = try
                MOI.get(model, MOI.RelativeGap()) * 100
            catch
                0.0
            end

            val_pico = round(Int, value(y_pico))
            val_custo = value(expr_custo)
            val_entregas = round(Int, value(expr_entregas))

            push!(df_historico, (hora, tempo_acumulado, obj, bound, gap, val_pico, val_custo, val_entregas))
            CSV.write(joinpath(caminho_pasta, "historico_controle.csv"), df_historico)

            if obj < melhor_obj_encontrado
                println(">>> Melhor solucao encontrada na hora $hora: Obj = $obj")
                melhor_obj_encontrado = obj
                salvar_saidas(model, caminho_pasta, "$(hora)h")
                salvar_saidas(model, caminho_pasta, "melhor_absoluto")
            end
        else
            println(">>> Hora $hora: sem solucao viavel ainda.")
        end

        if termination_status(model) == MOI.OPTIMAL
            println("Solucao otima comprovada. Finalizando.")
            break
        end
    end
end

function salvar_saidas(model, pasta, sufixo)
    val_x = value.(model[:x])
    val_z = value.(model[:z])

    colunas_abastecimento = Any[[j for j in nb]]
    colunas_alocacao = Any[[j for j in nb]]

    for k in nd
        arr_abast_dia = Int[]
        arr_aloc_dia = Int[]
        for j in nb
            fonte_escolhida = 0
            for i in candidatos_por_beneficiario[j]
                if val_z[j, i] > 0.5
                    fonte_escolhida = i
                    break
                end
            end
            soma_caminhoes = sum(round(Int, val_x[j, i, k]) for i in candidatos_por_beneficiario[j])
            push!(arr_abast_dia, soma_caminhoes)
            push!(arr_aloc_dia, soma_caminhoes > 0 ? fonte_escolhida : 0)
        end
        push!(colunas_abastecimento, arr_abast_dia)
        push!(colunas_alocacao, arr_aloc_dia)
    end

    nomes_colunas = Symbol.(["Beneficiarios"; string.(collect(nd))])

    df_abastecimento = DataFrame(colunas_abastecimento, nomes_colunas)
    CSV.write(joinpath(pasta, "abastecimento_$sufixo.csv"), df_abastecimento)

    df_alocacao = DataFrame(colunas_alocacao, nomes_colunas)
    CSV.write(joinpath(pasta, "alocacao_$sufixo.csv"), df_alocacao)
end

function localizar_abastecimento_minpicos()
    candidatos = [
        joinpath(TEST_DIR, "resultados_minpicos_p00", "abastecimento_melhor_absoluto.csv"),
        joinpath(TEST_DIR, "resultados_minpicos_p00", "abastecimento_24h.csv"),
        joinpath(TEST_DIR, "resultados_minpicos_p00", "abastecimento_21h.csv"),
        joinpath(TEST_DIR, "resultados_minpicos_p00", "abastecimento_18h.csv"),
        joinpath(TEST_DIR, "resultados_minpicos_p00", "abastecimento_15h.csv"),
        joinpath(TEST_DIR, "resultados_minpicos_p00", "abastecimento_12h.csv"),
        joinpath(TEST_DIR, "resultados_minpicos_p00", "abastecimento_9h.csv"),
        joinpath(TEST_DIR, "resultados_minpicos_p00", "abastecimento_6h.csv"),
        joinpath(TEST_DIR, "resultados_minpicos_p00", "abastecimento_3h.csv"),
    ]

    for caminho in candidatos
        if isfile(caminho)
            return caminho
        end
    end

    return nothing
end

ws_abast_opt = localizar_abastecimento_minpicos()
ws_aloc_opt = joinpath(TEST_DIR, "alocacao_m2_minpicos_p00.csv")
ws_abast_heu = joinpath(TEST_DIR, "abastecimento_heu_limite.csv")
ws_aloc_heu = joinpath(TEST_DIR, "alocacao_heu_limite.csv")

output_dir = length(ARGS) >= 1 ? ARGS[1] : "resultados_500_15_365_72h"
ws_abast_arg = length(ARGS) >= 2 ? ARGS[2] : nothing
ws_aloc_arg = length(ARGS) >= 3 ? ARGS[3] : nothing

ws_abast = !isnothing(ws_abast_arg) ? ws_abast_arg : (!isnothing(ws_abast_opt) ? ws_abast_opt : ws_abast_heu)
ws_aloc = !isnothing(ws_aloc_arg) ? ws_aloc_arg : (isfile(ws_aloc_opt) ? ws_aloc_opt : ws_aloc_heu)

println("Pasta de saida:          $output_dir")
println("Warm start abastecimento: $ws_abast")
println("Warm start alocacao:      $ws_aloc")

rodar_modelo_integrado(0.00, output_dir;
    abastecimento_warm_start=ws_abast,
    alocacao_warm_start=ws_aloc)
