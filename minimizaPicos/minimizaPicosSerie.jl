using JuMP
using LinearAlgebra
using CSV
using DataFrames
using Gurobi
using MathOptInterface
const MOI = MathOptInterface

BASE_PATH = "C:/Users/lfeli/Documents/AlocacaoCarros/dados/"

# --- Leitura dos Dados ---
beneficiarios_ativos = CSV.read(BASE_PATH * "Beneficiarios_RN_Ativos1.csv", DataFrame)
dias_uteis = CSV.read(BASE_PATH * "datas.csv", DataFrame)
calendarios = CSV.read(BASE_PATH * "/CalendariosObrigatorios.csv", DataFrame)

# --- Preparação dos Parâmetros ---
calendarioCarnaval = calendarios.carnaval
entregasObrigatorias = calendarios.lil
duas_colunas_b = [beneficiarios_ativos.Capacidade, beneficiarios_ativos.Pessoas_Atendidas]

qtd_dias_uteis = sum(dias_uteis[:, 1]) 

p = 0.5 
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

# --- Construção do Modelo ---
model = Model(Gurobi.Optimizer)

#---Variáveis---
@variable(model, 0 <= x[j in nb, k in nd], Int)
@variable(model, 0 <= V[j in nb, k in nd])
@variable(model, 0 <= y, Int)

# Função Objetivo
@objective(model, Min, p*qtd_dias_uteis*y + (1 - p)*sum(x[j, k] for j in nb, k in nd))

#-----Restrições-----
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


# --- Função Auxiliar para Salvar CSVs Detalhados ---
function salvar_csvs_detalhados(model_inst, nome_sufixo)
    println("Salvando CSVs detalhados para: $nome_sufixo ...")
    
    val_V = value.(model_inst[:V])
    val_x = value.(model_inst[:x])

    # Volume
    colunas_v = Any[[j for j in nb]]
    for i in nd
        push!(colunas_v, [val_V[j, i] for j in nb])
    end
    df_v = DataFrame(colunas_v, Symbol.(["Beneficiarios"; nd...]))
    CSV.write("volumes_$(nome_sufixo).csv", df_v)

    # Abastecimento
    colunas_x = Any[[j for j in nb]]
    for i in nd
        push!(colunas_x, [round(Int, val_x[j, i]) for j in nb])
    end
    df_x = DataFrame(colunas_x, Symbol.(["Beneficiarios"; nd...]))
    CSV.write("abastecimento_$(nome_sufixo).csv", df_x)
end

# --- Lógica de Resolução Incremental ---

checkpoints_minutos = [1, 3, 5, 10, 30, 90, 180, 360, 540, 720]
checkpoints_segundos = Float64.(checkpoints_minutos .* 60)
nomes_arquivos = ["1min", "3min", "5min", "10min", "30min", "90min", "3h", "6h", "9h", "12h"]

# Arquivo de resumo para controle
df_historico = DataFrame(Checkpoint = String[], FuncaoObjetivo = Float64[], Pico_Y = Int[])

println("Iniciando bateria de CONTROLE incremental (Lógica Delta)...")

tempo_acumulado_anterior = 0.0

for (meta_tempo_total, sufixo) in zip(checkpoints_segundos, nomes_arquivos)
    # Calcula quanto falta rodar para chegar na próxima meta
    tempo_para_rodar = meta_tempo_total - tempo_acumulado_anterior
    
    if tempo_para_rodar <= 0.5 # Margem de erro pequena
        println("Pulo: Meta $sufixo já foi atingida.")
        continue
    end

    println("\n--- Checkpoint: $sufixo (Meta Total: $(meta_tempo_total)s | Rodando por +$(round(tempo_para_rodar))s) ---")
    
    # Define o limite APENAS para este round
    set_optimizer_attribute(model, "TimeLimit", tempo_para_rodar)
    
    try
        optimize!(model)
    catch e
        if isa(e, InterruptException)
            println("Interrompido manualmente.")
            if has_values(model)
                salvar_csvs_detalhados(model, "INTERROMPIDO_$(sufixo)")
            end
            break
        else
            rethrow(e)
        end
    end

    # Atualiza o contador GLOBAL para a próxima iteração
    global tempo_acumulado_anterior = meta_tempo_total

    if has_values(model)
        obj_atual = objective_value(model)
        y_atual = round(Int, value(y))
        
        push!(df_historico, (sufixo, obj_atual, y_atual))
        CSV.write("CONTROLE_historico.csv", df_historico)
        println("Resumo: Pico = $y_atual, Obj = $obj_atual")
        
        salvar_csvs_detalhados(model, "CONTROLE_$(sufixo)")
    else
        println("Sem solução viável ainda.")
    end

    if termination_status(model) == MOI.OPTIMAL
        println("Solução ÓTIMA encontrada! Finalizando bateria.")
        break
    end
end

println("\nProcesso finalizado.")