using JuMP
using LinearAlgebra
using CSV
using DataFrames
using Gurobi
using MathOptInterface
const MOI = MathOptInterface

# Configuração de caminhos - mude aqui se necessário
# Se estiver no Linux, use caminhos de Linux.
const BASE_PATH = "C:/Users/lfeli/Documents/AlocacaoCarros/dados/"
const TOTAL_MANANCIAIS_ARQUIVO = 92
const CAPACIDADE_MAX_MANANCIAL = 12

function rodar_sliding_window(
    p::Float64, 
    nome_pasta::String, 
    dia_inicio::Int, 
    num_dias_periodo::Int;
    caminho_volumes_iniciais=nothing,
    pasta_anterior=nothing,
    overlap_dias=0
)
    caminho_pasta = joinpath(pwd(), nome_pasta)
    if !isdir(caminho_pasta)
        mkpath(caminho_pasta)
    end

    # Tenta ler os arquivos, se não encontrar no BASE_PATH tenta no diretório atual ou relativos
    function ler_csv(nome)
        caminhos = [
            joinpath(BASE_PATH, nome),
            joinpath(pwd(), "alocacao", "Dados", nome),
            joinpath(pwd(), "alocacao", "entradas", nome),
            joinpath(pwd(), nome)
        ]
        for c in caminhos
            if isfile(c)
                return CSV.read(c, DataFrame)
            end
        end
        error("Arquivo $nome não encontrado nos caminhos testados.")
    end

    # Ajuste: se BASE_PATH não existir, tenta encontrar os arquivos em locais conhecidos
    beneficiarios_ativos = ler_csv("Beneficiarios_RN_Ativos1.csv")
    dias_uteis_full = ler_csv("datas.csv")
    calendarios_full = ler_csv("CalendariosObrigatorios.csv")
    rotas = ler_csv("rotas")

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
    set_optimizer_attribute(model, "Threads", 4)
    set_optimizer_attribute(model, "MIPGap", 0.002) # Aceita gap de 0.2%

    @variable(model, 0 <= x[j in nb, i in candidatos_por_beneficiario[j], k in nd_local], Int) 
    @variable(model, z[j in nb, i in candidatos_por_beneficiario[j]], Bin) 
    @variable(model, 0 <= y_pico, Int)
    @variable(model, 0 <= V[j in nb, k in 0:num_dias_periodo]) # k=0 é o volume inicial antes do dia 1

    @expression(model, expr_pico, qtd_dias_uteis * y_pico)
    @expression(model, expr_custo, sum(Dij[i,j] * x[j, i, k] for j in nb, i in candidatos_por_beneficiario[j], k in nd_local))

    @objective(model, Min, (p * expr_pico) + ((1 - p) * expr_custo))

    # --- V[j, 0] é o volume inicial real ---
    if isnothing(caminho_volumes_iniciais) || !isfile(caminho_volumes_iniciais)
        println(">>> Iniciando com volumes máximos (Capacidade) em k=0")
        @constraint(model, balancoVolumeInicial[j in nb], V[j, 0] == C[j])
    else
        println(">>> Carregando volumes iniciais de: $caminho_volumes_iniciais em k=0")
        df_vol_init = CSV.read(caminho_volumes_iniciais, DataFrame)
        vol_dict = Dict(row[1] => row[2] for row in eachrow(df_vol_init))
        @constraint(model, balancoVolumeInicial[j in nb], V[j, 0] == get(vol_dict, j, C[j]))
    end
    
    # --- Balanço de Volume Corrigido: Inclui o dia 1 (k=1) ---
    # k-1 quando k=1 acessa V[j, 0], que está definido em 0:num_dias_periodo
    @constraint(model, balancoVolume[j in nb, k in 1:num_dias_periodo; !(calendarioCarnaval[k] == -1 && j in quebra4) && !(entregasObrigatorias[k] == -1 && j in quebra2)],
        V[j, k] <= V[j, k-1] - U[j] + 13.0 * sum(x[j, i, k] for i in candidatos_por_beneficiario[j]))
    
    @constraint(model, correcaoVolume[j in nb, k in 1:num_dias_periodo; (calendarioCarnaval[k] == -1 && j in quebra4) || (entregasObrigatorias[k] == -1 && j in quebra2)],
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

    # --- Warm Start ---
    if !isnothing(pasta_anterior) && isdir(pasta_anterior) && overlap_dias > 0
        println(">>> Aplicando Warm Start da pasta: $pasta_anterior")
        try
            # Carrega z (alocação)
            df_aloc = CSV.read(joinpath(pasta_anterior, "alocacao_melhor_absoluto.csv"), DataFrame)
            # Carrega x (abastecimento)
            df_abast = CSV.read(joinpath(pasta_anterior, "abastecimento_melhor_absoluto.csv"), DataFrame)
            
            # z é constante, podemos pegar de qualquer coluna onde houve entrega ou apenas confiar na primeira se houver consistência
            # No modelo Rolling/Sliding, z deve ser o mesmo para todo o período.
            # Vamos assumir que a alocação do beneficiário j é a que está no arquivo.
            for j in nb
                fonte_anterior = df_aloc[j, end] # Pega o último dia do período anterior
                if fonte_anterior > 0 && fonte_anterior in candidatos_por_beneficiario[j]
                    set_start_value(z[j, fonte_anterior], 1.0)
                    for i in candidatos_por_beneficiario[j]
                        if i != fonte_anterior
                            set_start_value(z[j, i], 0.0)
                        end
                    end
                end
            end

            # x para os dias de sobreposição
            # Se P1 era 1-45 e P2 é 39-83, overlap é 7 dias (39-45).
            # No CSV de P1, esses são os dias 39, 40, ..., 45 (colunas "39", "40", ...).
            # No modelo de P2, esses são os dias locais 1, 2, ..., 7.
            
            # Precisamos mapear os dias globais para as colunas do CSV anterior
            # O CSV anterior tem colunas que são os dias locais daquele período.
            # Se o período anterior começou no dia_anterior_inicio, o dia global G é a coluna (G - dia_anterior_inicio + 1).
            
            # Para simplificar, vamos assumir que as colunas do CSV são nomeadas de acordo com o dia LOCAL.
            # Então se overlap_dias = 7 e o período anterior tinha 45 dias, 
            # os últimos 7 dias são 39, 40, 41, 42, 43, 44, 45.
            
            num_dias_anterior = size(df_abast, 2) - 1
            for od in 1:overlap_dias
                col_idx = num_dias_anterior - overlap_dias + od
                col_name = string(col_idx)
                if hasproperty(df_abast, Symbol(col_name))
                    for j in nb
                        qtd = df_abast[j, col_name]
                        fonte = df_aloc[j, col_name]
                        if fonte > 0 && fonte in candidatos_por_beneficiario[j]
                            set_start_value(x[j, fonte, od], Float64(qtd))
                        end
                    end
                end
            end
            println("    Warm Start aplicado com sucesso para z e x (primeiros $overlap_dias dias).")
        catch e
            println("    AVISO: Falha ao carregar Warm Start: $e")
        end
    end

    # Solução
    horas_checkpoints = 3:3:3
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

        if has_values(model)
            obj = objective_value(model)
            if obj < melhor_obj_encontrado
                tempo_minutos = round((time() - tempo_inicio_global) / 60, digits=2)
                println(">>> Melhor solução (Sliding) encontrada ($tempo_minutos min): Obj = $obj")
                melhor_obj_encontrado = obj
                salvar_saidas_sliding(model, caminho_pasta, "melhor_absoluto", nb, nd_local, candidatos_por_beneficiario)
                salvar_volumes_finais_sliding(model, caminho_pasta, "volumes_finais", nb, nd_local)
            end
        end

        status_parcial = termination_status(model)
        if status_parcial == MOI.OPTIMAL
            println(">>> Solução ótima comprovada!")
            break
        elseif status_parcial == MOI.INFEASIBLE
            println(">>> MODELO INFACTÍVEL!")
            # Tenta encontrar o conflito se possível (apenas para debug)
            # compute_conflict!(model)
            break
        end
    end

    # Histórico
    status_final = termination_status(model)
    tempo_total = round(time() - tempo_inicio_global, digits=2)
    obj_val = has_values(model) ? objective_value(model) : NaN
    gap_val = has_values(model) ? (try relative_gap(model) catch; NaN end) : NaN
    entregas_val = has_values(model) ? sum(value.(model[:x])) : NaN
    pico_val = has_values(model) ? value(model[:y_pico]) : NaN

    df_hist = DataFrame(
        Dia_Inicio = dia_inicio,
        Status = string(status_final),
        Tempo = tempo_total,
        Obj = obj_val,
        Gap = gap_val,
        Total_Entregas = entregas_val,
        Pico_Maximo = pico_val
    )
    caminho_historico = joinpath(dirname(caminho_pasta), "historico_sliding_window.csv")
    CSV.write(caminho_historico, df_hist, append=isfile(caminho_historico))
end

function salvar_saidas_sliding(model, pasta, sufixo, nb, nd_local, candidatos_por_beneficiario)
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
    CSV.write(joinpath(pasta, "abastecimento_$sufixo.csv"), DataFrame(colunas_abastecimento, Symbol.(["Beneficiarios"; nd_local...])))
    CSV.write(joinpath(pasta, "alocacao_$sufixo.csv"), DataFrame(colunas_alocacao, Symbol.(["Beneficiarios"; nd_local...])))
end

function salvar_volumes_finais_sliding(model, pasta, sufixo, nb, nd_local)
    val_V = value.(model[:V])
    # Salva apenas o último dia para compatibilidade com o rolling antigo se necessário
    ultimo_dia = last(nd_local)
    df_finais = DataFrame(Beneficiario = Int[], Volume = Float64[])
    for j in nb
        push!(df_finais, (j, val_V[j, ultimo_dia]))
    end
    CSV.write(joinpath(pasta, "$sufixo.csv"), df_finais)

    # Salva todos os dias para o sliding window poder pegar o volume de qualquer dia de overlap
    colunas_volumes = Any[[j for j in nb]]
    for k in [0; collect(nd_local)]
        push!(colunas_volumes, [val_V[j, k] for j in nb])
    end
    df_todos = DataFrame(colunas_volumes, Symbol.(["Beneficiarios"; 0; nd_local...]))
    CSV.write(joinpath(pasta, "volumes_todos_dias.csv"), df_todos)
end

# Execução via CLI
if length(ARGS) >= 4
    p = parse(Float64, ARGS[1])
    pasta = ARGS[2]
    dia_ini = parse(Int, ARGS[3])
    num_d = parse(Int, ARGS[4])
    vol_init = length(ARGS) >= 5 ? (ARGS[5] == "nothing" ? nothing : ARGS[5]) : nothing
    pasta_ant = length(ARGS) >= 6 ? (ARGS[6] == "nothing" ? nothing : ARGS[6]) : nothing
    overlap = length(ARGS) >= 7 ? parse(Int, ARGS[7]) : 0
    
    rodar_sliding_window(p, pasta, dia_ini, num_d, caminho_volumes_iniciais=vol_init, pasta_anterior=pasta_ant, overlap_dias=overlap)
end
