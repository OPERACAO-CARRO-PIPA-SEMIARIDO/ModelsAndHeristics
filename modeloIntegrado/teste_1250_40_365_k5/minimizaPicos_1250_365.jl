using JuMP
using CSV
using DataFrames
using Gurobi
using MathOptInterface
const MOI = MathOptInterface

const BASE_PATH = "C:/Users/lfeli/Documents/AlocacaoCarros/dados/"

beneficiarios_ativos = CSV.read(BASE_PATH * "Beneficiarios_RN_Ativos1.csv", DataFrame)
dias_uteis           = CSV.read(BASE_PATH * "datas.csv", DataFrame)
calendarios          = CSV.read(BASE_PATH * "CalendariosObrigatorios.csv", DataFrame)

calendarioCarnaval   = calendarios.carnaval
entregasObrigatorias = calendarios.lil

nb = 1:1250
nd = 1:365

qtd_dias_uteis = sum(dias_uteis[nd, 1])

preU = [round(i * 0.02, digits=2) for i in beneficiarios_ativos.Pessoas_Atendidas]
preC = convert(Vector{Float64}, beneficiarios_ativos.Capacidade)
U = [preU[j] for j in nb]
C = [preC[j] for j in nb]

Y = C ./ U
quebra4 = [j for (j, x) in zip(nb, Y) if x < 5]
quebra3 = [j for (j, x) in zip(nb, Y) if x < 4]
quebra2 = [j for (j, x) in zip(nb, Y) if x < 3]

# p=1.0 → minimiza pico; p=0.0 → minimiza total de entregas
const P_VALOR = 1.0

function rodar_minpicos(p_valor, nome_pasta; arquivo_warm_start=nothing)
    caminho_pasta = isabspath(nome_pasta) ? nome_pasta : joinpath(@__DIR__, nome_pasta)
    if !isdir(caminho_pasta) mkpath(caminho_pasta) end

    model = Model(Gurobi.Optimizer)
    set_optimizer_attribute(model, "NodefileStart", 20.0)
    set_optimizer_attribute(model, "MIPFocus", 1)
    set_optimizer_attribute(model, "MIPGap", 0.002)
    set_optimizer_attribute(model, "Threads", 4)

    @variable(model, 0 <= x[j in nb, k in nd], Int)
    @variable(model, 0 <= V[j in nb, k in nd])
    @variable(model, 0 <= y, Int)

    @objective(model, Min,
        p_valor * qtd_dias_uteis * y + (1 - p_valor) * sum(x[j, k] for j in nb, k in nd))

    @constraint(model, balancoVolumeInicial[j in nb], V[j, 1] == C[j])
    @constraint(model, balancoVolume[j in nb, k in 2:last(nd);
            !(calendarioCarnaval[k] == -1 && j in quebra4) &&
            !(entregasObrigatorias[k] == -1 && j in quebra2)],
        V[j, k] <= V[j, k-1] - U[j] + 13.0 * x[j, k])
    @constraint(model, correcaoVolume[j in nb, k in nd;
            (calendarioCarnaval[k] == -1 && j in quebra4) ||
            (entregasObrigatorias[k] == -1 && j in quebra2)],
        V[j, k] == 0)
    @constraint(model, diasInuteis[j in nb, k in nd; Int(dias_uteis[k, 1]) == 0], x[j, k] == 0)
    @constraint(model, maiorPico[k in nd], sum(x[j, k] for j in nb) <= y)
    @constraint(model, volumeMinimo[j in nb, k in nd], V[j, k] >= 0)
    @constraint(model, capacidadeMax[j in nb, k in nd], V[j, k] <= C[j])
    @constraint(model, carnavalAbastecimento[j in quebra4, k in nd; calendarioCarnaval[k] == 1], x[j, k] >= 1)
    @constraint(model, lilAbastecimento[j in quebra2, k in nd; entregasObrigatorias[k] == 1], x[j, k] >= 1)

    # Warm start a partir do abastecimento heurístico
    if !isnothing(arquivo_warm_start) && isfile(arquivo_warm_start)
        try
            df_ws = CSV.read(arquivo_warm_start, DataFrame)
            max_pico = 0
            for row in eachrow(df_ws)
                j_id = hasproperty(df_ws, :Beneficiarios) ? row.Beneficiarios : row[1]
                if !(j_id in nb) continue end
                for k in nd
                    col_sym = Symbol(string(k))
                    if hasproperty(row, col_sym)
                        val = row[col_sym]
                        if !ismissing(val) && val > 0
                            set_start_value(x[j_id, k], Float64(val))
                        end
                    end
                end
            end
            for k in nd
                col_sym = Symbol(string(k))
                if hasproperty(df_ws, col_sym)
                    soma = sum(skipmissing(df_ws[!, col_sym]))
                    if soma > max_pico max_pico = round(Int, soma) end
                end
            end
            if max_pico > 0 set_start_value(y, Float64(max_pico)) end
            println(">>> Warm Start carregado: $arquivo_warm_start")
        catch e
            println(">>> Aviso warm start: $e")
        end
    end

    # Checkpoints a cada 3h até 24h
    horas_checkpoints    = 3:3:24
    segundos_checkpoints = Float64.(horas_checkpoints .* 3600)

    df_historico = DataFrame(
        Hora        = Int[],
        Tempo_s     = Float64[],
        Obj         = Float64[],
        Bound       = Float64[],
        Gap_Pct     = Float64[],
        Pico_Y      = Int[],
        Total_X     = Int[]
    )

    tempo_acumulado       = 0.0
    melhor_obj_encontrado = Inf

    for (hora, meta) in zip(horas_checkpoints, segundos_checkpoints)
        restante = meta - tempo_acumulado
        if restante <= 0 continue end

        set_optimizer_attribute(model, "TimeLimit", restante)

        try
            optimize!(model)
        catch e
            if isa(e, InterruptException)
                println("Interrompido na hora $hora.")
                if has_values(model) salvar_minpicos(model, caminho_pasta, "$(hora)h_INT") end
                return
            else
                println("Erro fatal: $e"); break
            end
        end

        tempo_acumulado = meta

        if has_values(model)
            obj   = objective_value(model)
            bound = try objective_bound(model) catch; -1.0 end
            gap   = try MOI.get(model, MOI.RelativeGap()) * 100 catch; 0.0 end
            pico  = round(Int, value(y))
            soma  = round(Int, sum(value.(x)))

            push!(df_historico, (hora, meta, obj, bound, gap, pico, soma))
            CSV.write(joinpath(caminho_pasta, "historico_controle.csv"), df_historico)

            if obj < melhor_obj_encontrado
                println(">>> Melhor solução na hora $hora: Obj=$obj  Pico=$pico")
                melhor_obj_encontrado = obj
                salvar_minpicos(model, caminho_pasta, "$(hora)h")
                salvar_minpicos(model, caminho_pasta, "melhor_absoluto")
            end
        else
            println(">>> Hora $hora: sem solução viável ainda.")
        end

        if termination_status(model) == MOI.OPTIMAL
            println("Ótimo comprovado. Finalizando.")
            break
        end
    end
end

function salvar_minpicos(model, pasta, sufixo)
    val_x = value.(model[:x])
    val_V = value.(model[:V])

    colunas_x = Any[[j for j in nb]]
    colunas_v = Any[[j for j in nb]]
    for k in nd
        push!(colunas_x, [round(Int, val_x[j, k]) for j in nb])
        push!(colunas_v, [val_V[j, k] for j in nb])
    end

    nomes = Symbol.(["Beneficiarios"; nd...])
    CSV.write(joinpath(pasta, "abastecimento_$sufixo.csv"), DataFrame(colunas_x, nomes))
    CSV.write(joinpath(pasta, "volumes_$sufixo.csv"),       DataFrame(colunas_v, nomes))
end

ws_path = joinpath(@__DIR__, "abastecimento_heu_full.csv")
rodar_minpicos(P_VALOR, "resultados_minpicos"; arquivo_warm_start=ws_path)
