using JuMP
using LinearAlgebra
using CSV
using DataFrames
using Gurobi
using MathOptInterface
const MOI = MathOptInterface

const BASE_PATH = "C:/Users/lfeli/Documents/AlocacaoCarros/dados/"
const TOTAL_MANANCIAIS_ARQUIVO = 92
const CAPACIDADE_MAX_MANANCIAL = 12

function ler_csv(nome)
    caminhos = [
        joinpath(BASE_PATH, nome),
        joinpath(pwd(), "alocacao", "Dados", nome),
        joinpath(pwd(), "alocacao", "entradas", nome),
        joinpath(pwd(), nome),
        joinpath(dirname(pwd()), nome),
    ]
    for c in caminhos
        if isfile(c)
            return CSV.read(c, DataFrame)
        end
    end
    error("Arquivo $nome não encontrado nos caminhos testados: $(join(caminhos, ", "))")
end

function rodar_rolling_horizon(
    p::Float64,
    nome_pasta::String,
    dia_inicio::Int,
    num_dias_periodo::Int;
    caminho_volumes_iniciais=nothing,
    pasta_anterior=nothing,
    overlap_dias::Int=0,
    num_candidatos::Int=3,
    num_beneficiarios::Int=3315,
    num_mananciais::Int=92,
    fontes_definidas_path=nothing
)
    caminho_pasta = joinpath(pwd(), nome_pasta)
    if !isdir(caminho_pasta)
        mkpath(caminho_pasta)
    end

    beneficiarios_ativos = ler_csv("Beneficiarios_RN_Ativos1.csv")
    dias_uteis_full      = ler_csv("datas.csv")
    calendarios_full     = ler_csv("CalendariosObrigatorios.csv")
    rotas                = ler_csv("rotas")

    TOTAL_BENEFICIARIOS = num_beneficiarios
    TOTAL_MANANCIAIS    = num_mananciais
    NUM_CANDIDATOS      = num_candidatos

    dia_fim    = dia_inicio + num_dias_periodo - 1
    nd_global  = dia_inicio:dia_fim
    nd_local   = 1:num_dias_periodo

    calendarioCarnaval   = calendarios_full.carnaval[nd_global]
    entregasObrigatorias = calendarios_full.lil[nd_global]
    dias_uteis           = dias_uteis_full[nd_global, 1]

    nb = 1:TOTAL_BENEFICIARIOS
    nm = 1:TOTAL_MANANCIAIS

    qtd_dias_uteis = sum(dias_uteis)

    preU_full = [round(i * 0.02, digits=2) for i in beneficiarios_ativos.Pessoas_Atendidas]
    U = preU_full[nb]

    C_full = convert(Vector{Float64}, beneficiarios_ativos.Capacidade)
    C = C_full[nb]

    Y = C ./ U
    quebra4 = [j for (j, x) in zip(nb, Y) if x < 5]
    quebra3 = [j for (j, x) in zip(nb, Y) if x < 4]
    quebra2 = [j for (j, x) in zip(nb, Y) if x < 3]

    distancias = rotas.distance_w_factor
    Dij_completa = transpose(reshape(distancias, (TOTAL_BENEFICIARIOS, TOTAL_MANANCIAIS_ARQUIVO)))
    Dij = Dij_completa[nm, nb]

    CANDIDATOS_REAIS = min(NUM_CANDIDATOS, TOTAL_MANANCIAIS)
    candidatos_por_beneficiario = Dict{Int, Vector{Int}}()
    for j in nb
        fontes_ordenadas = sortperm(Dij[:, j])
        candidatos_por_beneficiario[j] = fontes_ordenadas[1:CANDIDATOS_REAIS]
    end

    model = Model(Gurobi.Optimizer)

    set_optimizer_attribute(model, "NodefileStart", 10.0)
    set_optimizer_attribute(model, "MIPGap", 0.001)
    set_optimizer_attribute(model, "MemLimit", 28.0)
    set_optimizer_attribute(model, "Threads", 4)
    set_optimizer_attribute(model, "MIPFocus", 1)

    @variable(model, 0 <= x[j in nb, i in candidatos_por_beneficiario[j], k in nd_local], Int)
    @variable(model, z[j in nb, i in candidatos_por_beneficiario[j]], Bin)
    @variable(model, 0 <= y_pico, Int)
    @variable(model, 0 <= V[j in nb, k in 0:num_dias_periodo])

    @expression(model, expr_pico, qtd_dias_uteis * y_pico)
    @expression(model, expr_custo, sum(Dij[i,j] * x[j, i, k] for j in nb, i in candidatos_por_beneficiario[j], k in nd_local))

    @objective(model, Min, (p * expr_pico) + ((1 - p) * expr_custo))

    if isnothing(caminho_volumes_iniciais) || !isfile(caminho_volumes_iniciais)
        println(">>> Iniciando com volumes máximos (Capacidade) em k=0")
        @constraint(model, balancoVolumeInicial[j in nb], V[j, 0] == C[j])
    else
        println(">>> Carregando volumes iniciais de: $caminho_volumes_iniciais")
        df_vol_init = CSV.read(caminho_volumes_iniciais, DataFrame)
        vol_dict = Dict(row[1] => row[2] for row in eachrow(df_vol_init))
        @constraint(model, balancoVolumeInicial[j in nb], V[j, 0] == get(vol_dict, j, C[j]))
    end

    @constraint(model, balancoVolume[j in nb, k in 1:num_dias_periodo; !(calendarioCarnaval[k] == -1 && j in quebra4) && !(entregasObrigatorias[k] == -1 && j in quebra2)],
        V[j, k] <= V[j, k-1] - U[j] + 13.0 * sum(x[j, i, k] for i in candidatos_por_beneficiario[j]))

    @constraint(model, correcaoVolume[j in nb, k in nd_local; (calendarioCarnaval[k] == -1 && j in quebra4) || (entregasObrigatorias[k] == -1 && j in quebra2)],
        V[j, k] == 0)

    @constraint(model, diasInuteis[j in nb, k in nd_local; Int(dias_uteis[k]) == 0], sum(x[j, i, k] for i in candidatos_por_beneficiario[j]) == 0)

    @constraint(model, restMaiorPico[k in nd_local], sum(x[j, i, k] for j in nb, i in candidatos_por_beneficiario[j]) <= y_pico)

    @constraint(model, volumeMinimo[j in nb, k in 0:num_dias_periodo], V[j, k] >= 0)

    @constraint(model, capacidadeMax[j in nb, k in 0:num_dias_periodo], V[j, k] <= C[j])

    @constraint(model, carnavalAbastecimento[j in quebra4, k in nd_local; calendarioCarnaval[k] == 1], sum(x[j, i, k] for i in candidatos_por_beneficiario[j]) >= 1)

    @constraint(model, lilAbastecimento[j in quebra2, k in nd_local; entregasObrigatorias[k] == 1], sum(x[j, i, k] for i in candidatos_por_beneficiario[j]) >= 1)

    @constraint(model, fonteUnica[j in nb], sum(z[j, i] for i in candidatos_por_beneficiario[j]) == 1)

    @constraint(model, amarra_z_x[j in nb, k in nd_local, i in candidatos_por_beneficiario[j]],
        x[j, i, k] <= CAPACIDADE_MAX_MANANCIAL * z[j, i])

    @constraint(model, capDiariaManancial[i in nm, k in nd_local; !isempty([j for j in nb if i in candidatos_por_beneficiario[j]])],
        sum(x[j, i, k] for j in nb if i in candidatos_por_beneficiario[j]) <= CAPACIDADE_MAX_MANANCIAL)

    # --- Segurança de volume no fim do período ---
    dias_inuteis_futuros = 0
    dia_teste = num_dias_periodo + 1
    while (dia_inicio + dia_teste - 1) <= length(dias_uteis_full[:, 1]) &&
          Int(dias_uteis_full[dia_inicio + dia_teste - 1, 1]) == 0
        dias_inuteis_futuros += 1
        dia_teste += 1
    end
    if dias_inuteis_futuros > 0
        @constraint(model, SegurancaFimDePeriodo[j in nb],
            V[j, num_dias_periodo] >= U[j] * dias_inuteis_futuros)
    end

    # --- Warm Start base: fonte mais próxima para cada beneficiário ---
    # Fornece um ponto inicial válido para z; ajuda Gurobi a encontrar solução viável mais rápido.
    for j in nb
        set_start_value(z[j, candidatos_por_beneficiario[j][1]], 1.0)
        for i in candidatos_por_beneficiario[j][2:end]
            set_start_value(z[j, i], 0.0)
        end
    end

    # --- Warm Start (z e x da sobreposição do período anterior) ---
    if !isnothing(pasta_anterior) && isdir(pasta_anterior) && overlap_dias > 0
        println(">>> Aplicando Warm Start da pasta: $pasta_anterior")
        try
            df_aloc  = CSV.read(joinpath(pasta_anterior, "alocacao_resultado.csv"), DataFrame)
            df_abast = CSV.read(joinpath(pasta_anterior, "abastecimento_resultado.csv"), DataFrame)

            for j in nb
                fonte_escolhida = 0
                for col in names(df_aloc)
                    if col == "Beneficiarios" continue end
                    val_fonte = df_aloc[j, col]
                    if val_fonte > 0
                        fonte_escolhida = Int(val_fonte)
                        break
                    end
                end
                if fonte_escolhida > 0 && fonte_escolhida in candidatos_por_beneficiario[j]
                    set_start_value(z[j, fonte_escolhida], 1.0)
                    for i in candidatos_por_beneficiario[j]
                        if i != fonte_escolhida
                            set_start_value(z[j, i], 0.0)
                        end
                    end
                end
            end

            num_dias_anterior = size(df_abast, 2) - 1
            for od in 1:overlap_dias
                col_idx  = num_dias_anterior - overlap_dias + od
                col_name = string(col_idx)
                if hasproperty(df_abast, Symbol(col_name))
                    for j in nb
                        qtd   = df_abast[j, col_name]
                        fonte = df_aloc[j, col_name]
                        if fonte > 0 && fonte in candidatos_por_beneficiario[j]
                            set_start_value(x[j, Int(fonte), od], Float64(qtd))
                        end
                    end
                end
            end
            println("    Warm Start aplicado (z e x para $overlap_dias dias de sobreposição).")
        catch e
            println("    AVISO: Falha ao carregar Warm Start: $e")
        end
    end

    # --- Fixa fontes já definidas em períodos anteriores ---
    # Beneficiários com fonte definida têm z fixado — o solver não pode alterar a escolha.
    if !isnothing(fontes_definidas_path) && isfile(fontes_definidas_path)
        println(">>> Fixando fontes definidas de: $fontes_definidas_path")
        df_fontes = CSV.read(fontes_definidas_path, DataFrame)
        n_fixados = 0
        for row in eachrow(df_fontes)
            j     = Int(row.Beneficiario)
            fonte = Int(row.Fonte)
            if j in nb && fonte in candidatos_por_beneficiario[j]
                fix(z[j, fonte], 1.0; force=true)
                for i in candidatos_por_beneficiario[j]
                    if i != fonte
                        fix(z[j, i], 0.0; force=true)
                    end
                end
                n_fixados += 1
            end
        end
        println("    $n_fixados beneficiários com fonte fixada.")
    end

    # --- Otimização (limite de 2 horas, checkpoints a cada 15min/1h/2h) ---
    # Checkpoints curtos garantem que o primeiro resultado viável seja salvo logo que encontrado.
    horas_checkpoints = [0.25, 1.0, 2.0]
    melhor_obj_encontrado = Inf
    tempo_inicio_global = time()

    for meta_hora in horas_checkpoints
        tempo_real_passado = time() - tempo_inicio_global
        tempo_restante = (meta_hora * 3600.0) - tempo_real_passado

        if tempo_restante <= 0 continue end

        set_optimizer_attribute(model, "TimeLimit", tempo_restante)

        try
            optimize!(model)
        catch e
            println("Erro na otimização: $e")
            break
        end

        status_parcial = termination_status(model)

        if has_values(model)
            obj = objective_value(model)
            if obj < melhor_obj_encontrado
                tempo_minutos = round((time() - tempo_inicio_global) / 60, digits=2)
                println(">>> Melhor solução encontrada ($tempo_minutos min): Obj = $obj")
                melhor_obj_encontrado = obj
                salvar_saidas_rolling(model, caminho_pasta, "resultado", nb, nd_local, candidatos_por_beneficiario)
                salvar_volumes_finais(model, caminho_pasta, "volumes_finais", nb, nd_local)
            end
        end

        if status_parcial == MOI.MEMORY_LIMIT || status_parcial == MOI.INTERRUPTED
            println(">>> Gurobi abortou prematuramente.")
            break
        elseif status_parcial == MOI.OPTIMAL
            println(">>> Solução ótima comprovada!")
            break
        end
    end

    # --- Histórico ---
    status_final = termination_status(model)
    motivo_parada = if status_final == MOI.MEMORY_LIMIT
        "Erro 10001 (Memoria)"
    elseif status_final == MOI.TIME_LIMIT
        "Time Limit"
    elseif status_final == MOI.OPTIMAL
        "Otimo"
    elseif status_final == MOI.INTERRUPTED
        "Interrompido"
    else
        string(status_final)
    end

    tempo_total  = round(time() - tempo_inicio_global, digits=2)
    obj_val      = has_values(model) ? objective_value(model) : NaN
    gap_val      = has_values(model) ? (try relative_gap(model) catch; NaN end) : NaN
    entregas_val = has_values(model) ? sum(value.(model[:x])) : NaN
    pico_val     = has_values(model) ? value(model[:y_pico]) : NaN

    df_hist = DataFrame(
        Dia_Inicio    = dia_inicio,
        Motivo_Parada = motivo_parada,
        Tempo_Segundos = tempo_total,
        Funcao_Objetivo = obj_val,
        Gap           = gap_val,
        Total_Entregas = entregas_val,
        Pico_Maximo   = pico_val
    )

    caminho_historico = joinpath(dirname(caminho_pasta), "historico_rolling.csv")
    if isfile(caminho_historico)
        CSV.write(caminho_historico, df_hist, append=true)
    else
        CSV.write(caminho_historico, df_hist)
    end
end

function salvar_saidas_rolling(model, pasta, sufixo, nb, nd_local, candidatos_por_beneficiario)
    # Usa value() diretamente nas VariableRef para evitar problema de indexação
    # de SparseAxisArray retornado por value.(model[:z])
    x_var = model[:x]
    z_var = model[:z]

    colunas_abastecimento = Any[[j for j in nb]]
    colunas_alocacao      = Any[[j for j in nb]]

    for k in nd_local
        arr_abast_dia = Int[]
        arr_aloc_dia  = Int[]
        for j in nb
            fonte_escolhida = 0
            for i in candidatos_por_beneficiario[j]
                if value(z_var[j, i]) > 0.5
                    fonte_escolhida = i
                    break
                end
            end
            soma_caminhoes = sum(round(Int, value(x_var[j, i, k])) for i in candidatos_por_beneficiario[j])
            push!(arr_abast_dia, soma_caminhoes)
            push!(arr_aloc_dia, soma_caminhoes > 0 ? fonte_escolhida : 0)
        end
        push!(colunas_abastecimento, arr_abast_dia)
        push!(colunas_alocacao, arr_aloc_dia)
    end

    df_abastecimento = DataFrame(colunas_abastecimento, Symbol.(["Beneficiarios"; nd_local...]))
    CSV.write(joinpath(pasta, "abastecimento_$sufixo.csv"), df_abastecimento)

    df_alocacao = DataFrame(colunas_alocacao, Symbol.(["Beneficiarios"; nd_local...]))
    CSV.write(joinpath(pasta, "alocacao_$sufixo.csv"), df_alocacao)
end

function salvar_volumes_finais(model, pasta, sufixo, nb, nd_local)
    V_var    = model[:V]
    ultimo_dia = last(nd_local)

    df_finais = DataFrame(Beneficiario = Int[], Volume = Float64[])
    for j in nb
        push!(df_finais, (j, value(V_var[j, ultimo_dia])))
    end
    CSV.write(joinpath(pasta, "$sufixo.csv"), df_finais)

    # volumes_todos_dias.csv — necessário para o warm start de volumes do período seguinte
    colunas_volumes = Any[[j for j in nb]]
    for k in [0; collect(nd_local)]
        push!(colunas_volumes, [value(V_var[j, k]) for j in nb])
    end
    df_todos = DataFrame(colunas_volumes, Symbol.(["Beneficiarios"; 0; nd_local...]))
    CSV.write(joinpath(pasta, "volumes_todos_dias.csv"), df_todos)
end

# --- CLI ---
if length(ARGS) >= 4
    p          = parse(Float64, ARGS[1])
    nome_pasta = ARGS[2]
    dia_inicio = parse(Int, ARGS[3])
    num_dias   = parse(Int, ARGS[4])
    vol_init    = length(ARGS) >= 5  ? (ARGS[5]  == "nothing" ? nothing : ARGS[5])  : nothing
    pasta_ant   = length(ARGS) >= 6  ? (ARGS[6]  == "nothing" ? nothing : ARGS[6])  : nothing
    overlap     = length(ARGS) >= 7  ? parse(Int, ARGS[7]) : 0
    k_cand      = length(ARGS) >= 8  ? parse(Int, ARGS[8]) : 3
    nb_arg      = length(ARGS) >= 9  ? parse(Int, ARGS[9]) : 3315
    nm_arg      = length(ARGS) >= 10 ? parse(Int, ARGS[10]) : 92
    fontes_path = length(ARGS) >= 11 ? (ARGS[11] == "nothing" ? nothing : ARGS[11]) : nothing

    rodar_rolling_horizon(p, nome_pasta, dia_inicio, num_dias,
        caminho_volumes_iniciais=vol_init,
        pasta_anterior=pasta_ant,
        overlap_dias=overlap,
        num_candidatos=k_cand,
        num_beneficiarios=nb_arg,
        num_mananciais=nm_arg,
        fontes_definidas_path=fontes_path)
end
