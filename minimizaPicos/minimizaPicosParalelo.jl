using JuMP
using LinearAlgebra
using CSV
using DataFrames
using Gurobi
using MathOptInterface
using Base.Threads
const MOI = MathOptInterface

# --- CONFIGURAÇÕES GERAIS ---
BASE_PATH = "C:/Users/lfeli/Documents/AlocacaoCarros/dados/"

beneficiarios_ativos = CSV.read(BASE_PATH * "Beneficiarios_RN_Ativos1.csv", DataFrame)
dias_uteis = CSV.read(BASE_PATH * "datas.csv", DataFrame)
calendarios = CSV.read(BASE_PATH * "/CalendariosObrigatorios.csv", DataFrame)

# Dados Globais
calendarioCarnaval = calendarios.carnaval
entregasObrigatorias = calendarios.lil
duas_colunas_b = [beneficiarios_ativos.Capacidade, beneficiarios_ativos.Pessoas_Atendidas]
qtd_dias_uteis = sum(dias_uteis[:, 1]) 

nb = 1:3315
nd = 1:365

preU = [round(i * 0.02, digits=2) for i in duas_colunas_b[2]]
preC = convert(Vector{Float64}, duas_colunas_b[1])
U = [preU[j] for j in nb]
C = [preC[j] for j in nb]

Y = C ./ U
quebra4 = [beneficiario for (beneficiario, x) in zip(nb, Y) if x < 5]
quebra3 = [beneficiario for (beneficiario, x) in zip(nb, Y) if x < 4]
quebra2 = [beneficiario for (beneficiario, x) in zip(nb, Y) if x < 3]

# --- FUNÇÃO DO MODELO ---
# Adicionado argumento opcional: arquivo_warm_start
function rodar_cenario(p_valor, nome_pasta; arquivo_warm_start=nothing)
    id_thread = Threads.threadid()

    caminho_pasta = joinpath(pwd(), nome_pasta)
    if !isdir(caminho_pasta)
        mkpath(caminho_pasta)
    end

    model = Model(Gurobi.Optimizer)
    
    # --- CONFIGURAÇÃO DE HARDWARE (Segurança) ---
    set_optimizer_attribute(model, "NodefileStart", 20.0)
      
    @variable(model, 0 <= x[j in nb, k in nd], Int)
    @variable(model, 0 <= V[j in nb, k in nd])
    @variable(model, 0 <= y, Int)

    @objective(model, Min, p_valor * qtd_dias_uteis * y + (1 - p_valor) * sum(x[j, k] for j in nb, k in nd))

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

    # --- LÓGICA DE WARM START (NOVO) ---
    if !isnothing(arquivo_warm_start) && isfile(arquivo_warm_start)
        println(">>> Carregando Warm Start de: $arquivo_warm_start")
        try
            df_start = CSV.read(arquivo_warm_start, DataFrame)
            count_loaded = 0
            
            # Assume que a coluna 1 é o ID do beneficiário e as outras são dias ("1", "2"...)
            for row in eachrow(df_start)
                # Tenta pegar o ID da coluna 'Beneficiarios' ou assume a primeira coluna
                j_id = hasproperty(df_start, :Beneficiarios) ? row.Beneficiarios : row[1]
                
                # Se o ID não estiver no range atual do modelo, pula
                if !(j_id in nb) continue end

                for k in nd
                    col_sym = Symbol(string(k)) # Converte dia int para Symbol ("1")
                    if hasproperty(row, col_sym)
                        valor = row[col_sym]
                        if !ismissing(valor)
                            # Injeta o valor inicial na variável x
                            set_start_value(x[j_id, k], valor)
                            count_loaded += 1
                        end
                    end
                end
            end
            println(">>> Warm Start carregado! Valores injetados em $count_loaded variáveis x.")
            
            # Opcional: Tentar inferir um valor inicial para y baseado no x carregado
            # Isso ajuda o Gurobi a ter um bound superior imediato
            max_pico = 0
            for k in nd
                col_sym = Symbol(string(k))
                if hasproperty(df_start, col_sym)
                     soma_dia = sum(skipmissing(df_start[!, col_sym]))
                     if soma_dia > max_pico
                         max_pico = soma_dia
                     end
                end
            end
            if max_pico > 0
                set_start_value(y, max_pico)
                println(">>> Valor inicial de Y definido como: $max_pico")
            end

        catch e
            println("!!! Erro ao carregar Warm Start: $e")
            println("!!! O modelo continuará rodando sem o Warm Start.")
        end
    elseif !isnothing(arquivo_warm_start)
        println("!!! Aviso: Arquivo de Warm Start não encontrado: $arquivo_warm_start")
    end
    # -----------------------------------

    # --- DEFINIÇÃO DOS CHECKPOINTS (Até 72h) ---
    mins_iniciais = [1, 3, 5, 10, 30]
    horas_range = 1:24
    mins_horas = horas_range .* 60
    
    checkpoints_minutos = unique(vcat(mins_iniciais, mins_horas))
    checkpoints_segundos = Float64.(checkpoints_minutos .* 60)
    
    nomes_arquivos = String[]
    for m in checkpoints_minutos
        if m < 60
            push!(nomes_arquivos, "$(m)min")
        else
            h = Int(m / 60)
            push!(nomes_arquivos, "$(h)h")
        end
    end

    df_historico = DataFrame(
        Tempo_Label = String[], 
        Tempo_Segundos = Float64[],
        FuncaoObjetivo = Float64[], 
        BestBound = Float64[],
        Gap_Percent = Float64[],
        Sum_X = Int[],
        Pico_Y = Int[]
    )
    
    tempo_acumulado_anterior = 0.0

    for (meta_tempo_total, sufixo) in zip(checkpoints_segundos, nomes_arquivos)
        tempo_para_rodar = meta_tempo_total - tempo_acumulado_anterior

        if tempo_para_rodar <= 1.0
            continue
        end

        set_optimizer_attribute(model, "TimeLimit", tempo_para_rodar)

        try
            optimize!(model)
        catch e
            if isa(e, InterruptException)
                println("[p=$p_valor] Interrompido manualmente.")
                if has_values(model)
                    salvar_arquivos(model, nome_pasta, "INTERROMPIDO_$sufixo", nb, nd)
                end
                return 
            else
                rethrow(e)
            end
        end

        tempo_acumulado_anterior = meta_tempo_total

        if has_values(model)
            obj = objective_value(model)
            bound = try objective_bound(model) catch; -1.0 end 
            gap = try MOI.get(model, MOI.RelativeGap()) * 100 catch; 0.0 end
            
            pico = round(Int, value(y))
            soma_x = round(Int, sum(value.(x))) 

            push!(df_historico, (sufixo, meta_tempo_total, obj, bound, gap, soma_x, pico))
            CSV.write(joinpath(nome_pasta, "historico_controle.csv"), df_historico)
            
            salvar_arquivos(model, nome_pasta, sufixo, nb, nd)
        else
            println(" > Ainda sem solução viável.")
        end

        if termination_status(model) == MOI.OPTIMAL
            println("[p=$p_valor] Solução ÓTIMA comprovada! Finalizando.")
            break
        end
    end
end

function salvar_arquivos(model_inst, pasta, sufixo, nb_range, nd_range)
    val_V = value.(model_inst[:V])
    val_x = value.(model_inst[:x])

    colunas_v = Any[[j for j in nb_range]]
    for i in nd_range
        push!(colunas_v, [val_V[j, i] for j in nb_range])
    end
    df_v = DataFrame(colunas_v, Symbol.(["Beneficiarios"; nd_range...]))
    CSV.write(joinpath(pasta, "volumes_$sufixo.csv"), df_v)

    colunas_x = Any[[j for j in nb_range]]
    for i in nd_range
        push!(colunas_x, [round(Int, val_x[j, i]) for j in nb_range])
    end
    df_x = DataFrame(colunas_x, Symbol.(["Beneficiarios"; nd_range...]))
    CSV.write(joinpath(pasta, "abastecimento_$sufixo.csv"), df_x)
end

# --- EXECUÇÃO ---

# EXEMPLO DE USO COM WARM START:
# Supondo que você tem um arquivo chamado "abastecimento_72h.csv" na pasta "resultadosControle"
# e quer rodar um novo cenário (ex: p=0.25) usando ele como base.

#path_start = BASE_PATH * "abastecimento_diario_py.csv"
path_start = joinpath(pwd(), "resultados00/abastecimento_24h.csv")

# Verifique se o arquivo existe antes de rodar, ou deixe a função avisar
rodar_cenario(0.75, "resultados75w00";arquivo_warm_start = path_start)

println("\nEXECUÇÃO FINALIZADA.")