using JuMP
using LinearAlgebra
using CSV
using DataFrames
using Gurobi
using MathOptInterface
using Base.Threads # Necessário para o @spawn
const MOI = MathOptInterface

# --- CONFIGURAÇÕES GERAIS ---
BASE_PATH = "C:/Users/lfeli/Documents/AlocacaoCarros/dados/"

# Carregamento de dados (Compartilhado na memória para economizar RAM)
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
    # Identifica em qual thread do processador está rodando
    id_thread = Threads.threadid()
    println("\n[Thread $id_thread] Iniciando cenário p=$p_valor na pasta $nome_pasta")

    caminho_pasta = joinpath(pwd(), nome_pasta)
    if !isdir(caminho_pasta)
        mkpath(caminho_pasta)
    end

    # Criação do ambiente Gurobi isolado é automática pelo JuMP
    model = Model(Gurobi.Optimizer)
    
    # LIMITAÇÃO DE RECURSOS: Usar 8 threads para cada modelo (Total 16)
    set_optimizer_attribute(model, "Threads", 8)
    set_optimizer_attribute(model, "MIPFocus", 3) 
    
    # Trava de segurança de RAM: Se passar de 10GB, ele escreve no disco
    # Isso evita que o PC trave se os dois modelos explodirem a memória juntos
    set_optimizer_attribute(model, "NodefileStart", 10.0)

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

    # Checkpoints solicitados: 90min, 3h, 6h, 9h, 12h
    checkpoints_minutos = [90, 180, 360, 540, 720]
    checkpoints_segundos = Float64.(checkpoints_minutos .* 60)
    nomes_arquivos = ["90min", "3h", "6h", "9h", "12h"]
    
    df_historico = DataFrame(Checkpoint = String[], FuncaoObjetivo = Float64[], Pico_Y = Int[])
    tempo_acumulado_anterior = 0.0

    for (meta_tempo_total, sufixo) in zip(checkpoints_segundos, nomes_arquivos)
        tempo_para_rodar = meta_tempo_total - tempo_acumulado_anterior

        if tempo_para_rodar <= 1.0
            continue
        end

        println("\n[p=$p_valor] Checkpoint: $sufixo (Meta: $(meta_tempo_total)s)")
        set_optimizer_attribute(model, "TimeLimit", tempo_para_rodar)

        try
            optimize!(model)
        catch e
            if isa(e, InterruptException)
                println("[p=$p_valor] Interrompido. Salvando e saindo.")
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
            pico = round(Int, value(y))
            push!(df_historico, (sufixo, obj, pico))
            CSV.write(joinpath(nome_pasta, "historico_convergencia.csv"), df_historico)
            
            salvar_arquivos(model, nome_pasta, sufixo, nb, nd)
        end

        if termination_status(model) == MOI.OPTIMAL
            println("[p=$p_valor] Solução ÓTIMA encontrada! Finalizando este cenário.")
            break
        end
    end
end

function salvar_arquivos(model_inst, pasta, sufixo, nb_range, nd_range)
    # Salvamento otimizado (sem imprimir no console para não misturar log das threads)
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

# --- EXECUÇÃO PARALELA ---

println("Iniciando execução paralela com $(Threads.nthreads()) threads do Julia...")

# Dispara a tarefa 1 em background
task1 = Threads.@spawn rodar_cenario(0.25, "resultados025")

# Dispara a tarefa 2 em background
task2 = Threads.@spawn rodar_cenario(0.75, "resultados075")

# O script principal espera as duas terminarem
println("Tarefas disparadas. Aguardando conclusão...")
wait(task1)
wait(task2)

println("\nAMBOS OS MODELOS FINALIZADOS.")