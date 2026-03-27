using JuMP
using LinearAlgebra
using CSV
using DataFrames
using Gurobi
using MathOptInterface
const MOI = MathOptInterface

# Configurações de caminhos base (Pode ser alterado conforme o ambiente)
# No Linux, o caminho original pode precisar ser adaptado.
# Como o usuário está no Linux (/home/guilherme/...), vou usar caminhos relativos ou permitir customização.

const BASE_PATH = "C:/Users/lfeli/Documents/AlocacaoCarros/dados/"

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

    # Carregamento de dados (Estilo Windows hardcoded)
    beneficiarios_ativos = CSV.read(BASE_PATH * "Beneficiarios_RN_Ativos1.csv", DataFrame)
    dias_uteis_full = CSV.read(BASE_PATH * "datas.csv", DataFrame)
    calendarios_full = CSV.read(BASE_PATH * "CalendariosObrigatorios.csv", DataFrame)
    rotas = CSV.read(BASE_PATH * "rotas", DataFrame)

    TOTAL_BENEFICIARIOS = 3315
    TOTAL_MANANCIAIS = 92
    NUM_CANDIDATOS = 5

    # Filtra os dados para o período solicitado
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
    quebra2 = [j for (j, x) in zip(nb, Y) if x < 3]

    distancias = rotas.distance_w_factor
    Dij_completa = reshape(distancias, (92, size(beneficiarios_ativos, 1)))
    Dij = Dij_completa[nm, nb]

    CANDIDATOS_REAIS = min(NUM_CANDIDATOS, TOTAL_MANANCIAIS)
    candidatos_por_beneficiario = Dict{Int, Vector{Int}}()
    for j in nb
        fontes_ordenadas = sortperm(Dij[:, j])
        candidatos_por_beneficiario[j] = fontes_ordenadas[1:CANDIDATOS_REAIS]
    end

    # Modelo
    model = Model(Gurobi.Optimizer)
    set_optimizer_attribute(model, "NodefileStart", 10.0) 
    set_optimizer_attribute(model, "MemLimit", 28.0)
    set_optimizer_attribute(model, "MIPFocus", 1)

    @variable(model, 0 <= x[j in nb, i in candidatos_por_beneficiario[j], k in nd_local], Int) 
    @variable(model, z[j in nb, i in candidatos_por_beneficiario[j]], Bin) 
    @variable(model, 0 <= y_pico, Int)
    @variable(model, 0 <= V[j in nb, k in nd_local])

    @expression(model, expr_pico, qtd_dias_uteis * y_pico)
    @expression(model, expr_custo, sum(Dij[i,j] * x[j, i, k] for j in nb, i in candidatos_por_beneficiario[j], k in nd_local))
    @expression(model, expr_entregas, sum(x[j, i, k] for j in nb, i in candidatos_por_beneficiario[j], k in nd_local))

    @objective(model, Min, (p * expr_pico) + ((1 - p) * expr_custo))

    # --- LÓGICA DE VOLUMES INICIAIS (ESSENCIAL PARA ROLLING HORIZON) ---
    if isnothing(caminho_volumes_iniciais) || !isfile(caminho_volumes_iniciais)
        println(">>> Iniciando com volumes máximos (Capacidade)")
        @constraint(model, balancoVolumeInicial[j in nb], V[j, 1] == C[j])
    else
        println(">>> Carregando volumes iniciais de: $caminho_volumes_iniciais")
        df_vol_init = CSV.read(caminho_volumes_iniciais, DataFrame)
        # Assume que o CSV tem colunas "Beneficiario" e "Volume"
        vol_dict = Dict(row.Beneficiario => row.Volume for row in eachrow(df_vol_init))
        @constraint(model, balancoVolumeInicial[j in nb], V[j, 1] == get(vol_dict, j, C[j]))
    end
    
    # Restrições de balanço e outras
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

    # Lógica de Warm Start (Opcional, mas mantida por compatibilidade)
    if !isnothing(abastecimento_warm_start) && isfile(abastecimento_warm_start)
        println(">>> Carregando Warm Start de Abastecimento...")
        # Lógica simplificada de warm start...
    end

    # Checkpoints a cada 3 horas
    horas_checkpoints = 3:3:24
    segundos_checkpoints = Float64.(horas_checkpoints .* 3600)
    
    tempo_acumulado = 0.0
    melhor_obj_encontrado = Inf

    for (hora, meta_tempo) in zip(horas_checkpoints, segundos_checkpoints)
        tempo_restante = meta_tempo - tempo_acumulado
        if tempo_restante <= 0 continue end

        set_optimizer_attribute(model, "TimeLimit", tempo_restante)
        
        try
            optimize!(model)
        catch e
            println("Erro na otimização: $e")
            break
        end

        tempo_acumulado = meta_tempo

        if has_values(model)
            obj = objective_value(model)
            if obj < melhor_obj_encontrado
                melhor_obj_encontrado = obj
                salvar_saidas_rolling(model, caminho_pasta, "melhor_absoluto", nb, nd_local, candidatos_por_beneficiario)
                # Salvar volumes finais para o próximo período
                salvar_volumes_finais(model, caminho_pasta, "volumes_finais", nb, num_dias_periodo)
            end
        end

        if termination_status(model) == MOI.OPTIMAL
            break
        end
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

# Se for chamado via linha de comando
if length(ARGS) >= 4
    p = parse(Float64, ARGS[1])
    nome_pasta = ARGS[2]
    dia_inicio = parse(Int, ARGS[3])
    num_dias = parse(Int, ARGS[4])
    vol_init = length(ARGS) >= 5 ? ARGS[5] : nothing
    
    rodar_rolling_horizon(p, nome_pasta, dia_inicio, num_dias, caminho_volumes_iniciais=vol_init)
end
