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
function rodar_cenario(p_valor, nome_pasta)
    id_thread = Threads.threadid()

    caminho_pasta = joinpath(pwd(), nome_pasta)
    if !isdir(caminho_pasta)
        mkpath(caminho_pasta)
    end

    model = Model(Gurobi.Optimizer)
    
    # --- CONFIGURAÇÃO DE HARDWARE (Segurança) ---
    # NodefileStart para não estourar a RAM em corridas longas
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

    # --- DEFINIÇÃO DOS CHECKPOINTS (Até 72h) ---
    # Minutos iniciais
    mins_iniciais = [1, 3, 5, 10, 30]
    # Horas completas (de 1h até 72h) -> Convertendo para minutos
    horas_range = 1:72
    mins_horas = horas_range .* 60
    
    # Junta tudo e remove duplicatas
    checkpoints_minutos = unique(vcat(mins_iniciais, mins_horas))
    checkpoints_segundos = Float64.(checkpoints_minutos .* 60)
    
    # Cria nomes amigáveis para os arquivos
    nomes_arquivos = String[]
    for m in checkpoints_minutos
        if m < 60
            push!(nomes_arquivos, "$(m)min")
        else
            h = Int(m / 60)
            push!(nomes_arquivos, "$(h)h")
        end
    end

    # DataFrame estendido com BestBound e Gap
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

        # Pequena margem para evitar rodar por 0.001 segundos
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
            # Extração de Métricas Avançadas
            obj = objective_value(model)
            # Best Bound (Limite Inferior)
            bound = try objective_bound(model) catch; -1.0 end 
            # Gap Relativo
            gap = try MOI.get(model, MOI.RelativeGap()) * 100 catch; 0.0 end
            
            pico = round(Int, value(y))
            # Cálculo eficiente da soma de x
            soma_x = round(Int, sum(value.(x))) 

            # Salva no Histórico
            push!(df_historico, (sufixo, meta_tempo_total, obj, bound, gap, soma_x, pico))
            CSV.write(joinpath(nome_pasta, "historico_controle.csv"), df_historico)
            
            
            # Salva os arquivos pesados (CSVs de volume e abastecimento)
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

# --- OPÇÃO A: Rodar apenas UM Controle (p=0.5) ---
# Use esta opção se quer apenas validar o modelo base.
rodar_cenario(0.5, "resultadosControle")

# --- OPÇÃO B: Rodar em Paralelo (p=0.25 e p=0.75) ---
# Se quiser refazer os cenários anteriores com essa nova lógica de 72h, 
# COMENTE a linha acima (Opção A) e DESCOMENTE as linhas abaixo:

# t1 = Threads.@spawn rodar_cenario(0.25, "Controle_72h_P025")
# t2 = Threads.@spawn rodar_cenario(0.75, "Controle_72h_P075")
# wait(t1)
# wait(t2)

println("\nEXECUÇÃO FINALIZADA.")