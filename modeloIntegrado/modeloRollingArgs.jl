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

function rodar_rolling_horizon(
    p::Float64, 
    nome_pasta::String, 
    dia_inicio::Int, 
    num_dias_periodo::Int;
    caminho_volumes_iniciais=nothing,
    abastecimento_warm_start=nothing,
    alocacao_warm_start=nothing
)
    caminho_pasta = joinpath(pwd(), nome_pasta)
    if !isdir(caminho_pasta)
        mkpath(caminho_pasta)
    end

    beneficiarios_ativos = CSV.read(BASE_PATH * "Beneficiarios_RN_Ativos1.csv", DataFrame)
    dias_uteis_full = CSV.read(BASE_PATH * "datas.csv", DataFrame)
    calendarios_full = CSV.read(BASE_PATH * "CalendariosObrigatorios.csv", DataFrame)
    rotas = CSV.read(BASE_PATH * "rotas", DataFrame)

    TOTAL_BENEFICIARIOS = 3315
    TOTAL_MANANCIAIS = 92
    NUM_CANDIDATOS = 1

    dia_fim = dia_inicio + num_dias_periodo - 1
    nd_global = dia_inicio:dia_fim
    nd_local = 1:num_dias_periodo

    calendarioCarnaval = calendarios_full.carnaval[nd_global]
    entregasObrigatorias = calendarios_full.lil[nd_global]
    dias_uteis = dias_uteis_full[nd_global, 1]

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
    Dij_completa = reshape(distancias, (TOTAL_MANANCIAIS_ARQUIVO, size(beneficiarios_ativos, 1)))
    Dij = Dij_completa[nm, nb]

    CANDIDATOS_REAIS = min(NUM_CANDIDATOS, TOTAL_MANANCIAIS)
    candidatos_por_beneficiario = Dict{Int, Vector{Int}}()
    for j in nb
        fontes_ordenadas = sortperm(Dij[:, j])
        candidatos_por_beneficiario[j] = fontes_ordenadas[1:CANDIDATOS_REAIS]
    end

    model = Model(Gurobi.Optimizer)
    
    set_optimizer_attribute(model, "NodefileStart", 10.0) 
    set_optimizer_attribute(model, "MemLimit", 28.0)
    #set_optimizer_attribute(model, "MIPFocus", 1)
    set_optimizer_attribute(model, "Threads", 4)
    #set_optimizer_attribute(model, "Method", 1)
    #set_optimizer_attribute(model, "Cuts", 1)
    #set_optimizer_attribute(model, "Presolve", 1)

    @variable(model, 0 <= x[j in nb, i in candidatos_por_beneficiario[j], k in nd_local], Int) 
    @variable(model, z[j in nb, i in candidatos_por_beneficiario[j]], Bin) 
    @variable(model, 0 <= y_pico, Int)
    @variable(model, 0 <= V[j in nb, k in nd_local])

    @expression(model, expr_pico, qtd_dias_uteis * y_pico)
    @expression(model, expr_custo, sum(Dij[i,j] * x[j, i, k] for j in nb, i in candidatos_por_beneficiario[j], k in nd_local))

    @objective(model, Min, (p * expr_pico) + ((1 - p) * expr_custo))

    if isnothing(caminho_volumes_iniciais) || !isfile(caminho_volumes_iniciais)
        println(">>> Iniciando com volumes máximos (Capacidade)")
        @constraint(model, balancoVolumeInicial[j in nb], V[j, 1] == C[j])
    else
        println(">>> Carregando volumes iniciais de: $caminho_volumes_iniciais")
        df_vol_init = CSV.read(caminho_volumes_iniciais, DataFrame)
        vol_dict = Dict(row[1] => row[2] for row in eachrow(df_vol_init))
        @constraint(model, balancoVolumeInicial[j in nb], V[j, 1] == get(vol_dict, j, C[j]))
    end
    
    @constraint(model, balancoVolume[j in nb, k in 2:num_dias_periodo; !(calendarioCarnaval[k] == -1 && j in quebra4) && !(entregasObrigatorias[k] == -1 && j in quebra2)],
        V[j, k] <= V[j, k-1] - U[j] + 13.0 * sum(x[j, i, k] for i in candidatos_por_beneficiario[j]))
    
    @constraint(model, correcaoVolume[j in nb, k in nd_local; (calendarioCarnaval[k] == -1 && j in quebra4) || (entregasObrigatorias[k] == -1 && j in quebra2)],
        V[j, k] == 0)
        
    @constraint(model, diasInuteis[j in nb, k in nd_local; Int(dias_uteis[k]) == 0], sum(x[j, i, k] for i in candidatos_por_beneficiario[j]) == 0)
    
    @constraint(model, restMaiorPico[k in nd_local], sum(x[j, i, k] for j in nb, i in candidatos_por_beneficiario[j]) <= y_pico)
    
    @constraint(model, volumeMinimo[j in nb, k in nd_local], V[j, k] >= 0)
    
    @constraint(model, capacidadeMax[j in nb, k in nd_local], V[j, k] <= C[j])
    
    @constraint(model, carnavalAbastecimento[j in quebra4, k in nd_local; calendarioCarnaval[k] == 1], sum(x[j, i, k] for i in candidatos_por_beneficiario[j]) >= 1)
    
    @constraint(model, lilAbastecimento[j in quebra2, k in nd_local; entregasObrigatorias[k] == 1], sum(x[j, i, k] for i in candidatos_por_beneficiario[j]) >= 1)

    @constraint(model, fonteUnica[j in nb], sum(z[j, i] for i in candidatos_por_beneficiario[j]) == 1)
    
    @constraint(model, amarra_z_x[j in nb, k in nd_local, i in candidatos_por_beneficiario[j]], 
        x[j, i, k] <= CAPACIDADE_MAX_MANANCIAL * z[j, i])

    @constraint(model, capDiariaManancial[i in nm, k in nd_local; !isempty([j for j in nb if i in candidatos_por_beneficiario[j]])],
        sum(x[j, i, k] for j in nb if i in candidatos_por_beneficiario[j]) <= CAPACIDADE_MAX_MANANCIAL)

    # --- Nova restrição: Volume de Segurança no Fim do Período ---
    # Garante que o último dia do período tenha água suficiente para cobrir os dias inútis subsequentes.
    
    # Descobre quantos dias inuteis consecutivos existem logo após o fim deste período
    dias_inuteis_futuros = 0
    dia_teste = num_dias_periodo + 1
    
    # Checa se o próximo dia está fora do array global (fim do ano), se não, conta os inuteis
    while (dia_inicio + dia_teste - 1) <= length(dias_uteis_full[:, 1]) && 
          Int(dias_uteis_full[dia_inicio + dia_teste - 1, 1]) == 0
        dias_inuteis_futuros += 1
        dia_teste += 1
    end
    
    # Se houver dias inúteis, exige que o volume do último dia do período cubra esse consumo
    if dias_inuteis_futuros > 0
        @constraint(model, SegurancaFimDePeriodo[j in nb], 
            V[j, num_dias_periodo] >= U[j] * dias_inuteis_futuros)
    end

    if !isnothing(abastecimento_warm_start) && isfile(abastecimento_warm_start)
        println(">>> Tentativa de Warm Start ignorada nesta versão do Rolling.")
    end

    horas_checkpoints = 3:3:3
    melhor_obj_encontrado = Inf
    tempo_inicio_global = time()

    for meta_hora in horas_checkpoints
        tempo_real_passado = time() - tempo_inicio_global
        tempo_restante = (meta_hora * 3600.0) - tempo_real_passado
        
        if tempo_restante <= 0 
            continue 
        end

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
                println(">>> Melhor solução (Rolling) encontrada ($tempo_minutos min reais): Obj = $obj")
                melhor_obj_encontrado = obj
                salvar_saidas_rolling(model, caminho_pasta, "melhor_absoluto", nb, nd_local, candidatos_por_beneficiario)
                salvar_volumes_finais(model, caminho_pasta, "volumes_finais", nb, num_dias_periodo)
            end
        end

        if status_parcial == MOI.MEMORY_LIMIT || status_parcial == MOI.INTERRUPTED
            println(">>> O Gurobi abortou o solve prematuramente. Quebrando os checkpoints de tempo.")
            break
        elseif status_parcial == MOI.OPTIMAL
            println(">>> Solução ótima comprovada!")
            break
        end
    end

    # --- NOVO CÓDIGO: Salvamento do histórico consolidado do período ---
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

    tempo_total = round(time() - tempo_inicio_global, digits=2)

    # Coleta as métricas usando NaN caso o modelo tenha falhado sem encontrar nenhuma solução viável
    obj_val = has_values(model) ? objective_value(model) : NaN
    gap_val = has_values(model) ? (try relative_gap(model) catch; NaN end) : NaN
    entregas_val = has_values(model) ? sum(value.(model[:x])) : NaN
    pico_val = has_values(model) ? value(model[:y_pico]) : NaN

    df_hist = DataFrame(
        Dia_Inicio = dia_inicio,
        Motivo_Parada = motivo_parada,
        Tempo_Segundos = tempo_total,
        Funcao_Objetivo = obj_val,
        Gap = gap_val,
        Total_Entregas = entregas_val,
        Pico_Maximo = pico_val
    )

    # Salva no diretório pai (resultados_rolling) para centralizar todos os períodos
    caminho_historico = joinpath(dirname(caminho_pasta), "historico_controle_rolling.csv")
    if isfile(caminho_historico)
        CSV.write(caminho_historico, df_hist, append=true)
    else
        CSV.write(caminho_historico, df_hist)
    end
end

function salvar_saidas_rolling(model, pasta, sufixo, nb, nd_local, candidatos_por_beneficiario)
    val_x = value.(model[:x])
    val_z = value.(model[:z])

    colunas_abastecimento = Any[[j for j in nb]]
    colunas_alocacao = Any[[j for j in nb]]

    for k in nd_local
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

    df_abastecimento = DataFrame(colunas_abastecimento, Symbol.(["Beneficiarios"; nd_local...]))
    CSV.write(joinpath(pasta, "abastecimento_$sufixo.csv"), df_abastecimento)

    df_alocacao = DataFrame(colunas_alocacao, Symbol.(["Beneficiarios"; nd_local...]))
    CSV.write(joinpath(pasta, "alocacao_$sufixo.csv"), df_alocacao)
end

function salvar_volumes_finais(model, pasta, sufixo, nb, ultimo_dia)
    val_V = value.(model[:V])
    df_volumes = DataFrame(Beneficiario = Int[], Volume = Float64[])
    for j in nb
        push!(df_volumes, (j, val_V[j, ultimo_dia]))
    end
    CSV.write(joinpath(pasta, "$sufixo.csv"), df_volumes)
end

if length(ARGS) >= 4
    p = parse(Float64, ARGS[1])
    nome_pasta = ARGS[2]
    dia_inicio = parse(Int, ARGS[3])
    num_dias = parse(Int, ARGS[4])
    vol_init = length(ARGS) >= 5 ? ARGS[5] : nothing
    
    rodar_rolling_horizon(p, nome_pasta, dia_inicio, num_dias, caminho_volumes_iniciais=vol_init)
end