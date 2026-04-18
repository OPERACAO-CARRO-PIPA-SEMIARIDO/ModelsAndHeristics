using JuMP
using LinearAlgebra
using CSV
using DataFrames
using Gurobi
using MathOptInterface
const MOI = MathOptInterface

BASE_PATH = "C:/Users/lfeli/Documents/AlocacaoCarros/dados/"

beneficiarios_ativos = CSV.read(BASE_PATH * "Beneficiarios_RN_Ativos1.csv", DataFrame)
dias_uteis = CSV.read(BASE_PATH * "datas.csv", DataFrame)
calendarios = CSV.read(BASE_PATH * "CalendariosObrigatorios.csv", DataFrame)
rotas = CSV.read(BASE_PATH * "rotas", DataFrame)

calendarioCarnaval = calendarios.carnaval
entregasObrigatorias = calendarios.lil

TOTAL_BENEFICIARIOS_ARQUIVO = size(beneficiarios_ativos, 1)
TOTAL_MANANCIAIS_ARQUIVO = 92 
CAPACIDADE_MAX_MANANCIAL = 12

# ---> CONFIGURAÇÃO DE TESTE REDUZIDO <---
TOTAL_BENEFICIARIOS = 1500
TOTAL_MANANCIAIS = 45
TOTAL_DIAS = 365
NUM_CANDIDATOS = 3

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
quebra3 = [j for (j, x) in zip(nb, Y) if x < 4]
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

function rodar_modelo_integrado(p::Float64, nome_pasta::String)
    caminho_pasta = joinpath(pwd(), nome_pasta)
    if !isdir(caminho_pasta)
        mkpath(caminho_pasta)
    end

    model = Model(Gurobi.Optimizer)
    
    set_optimizer_attribute(model, "NodefileStart", 10.0) 
    set_optimizer_attribute(model, "MemLimit", 28.0)
    set_optimizer_attribute(model, "Threads", 2)

    @variable(model, 0 <= x[j in nb, i in candidatos_por_beneficiario[j], k in nd], Int) 
    @variable(model, z[j in nb, i in candidatos_por_beneficiario[j]], Bin) 
    @variable(model, 0 <= y_pico, Int)
    @variable(model, 0 <= V[j in nb, k in 0:last(nd)])

    @expression(model, expr_pico, qtd_dias_uteis * y_pico)
    @expression(model, expr_custo, sum(Dij[i,j] * x[j, i, k] for j in nb, i in candidatos_por_beneficiario[j], k in nd))
    @expression(model, expr_entregas, sum(x[j, i, k] for j in nb, i in candidatos_por_beneficiario[j], k in nd))

    @objective(model, Min, (p * expr_pico) + ((1 - p) * expr_custo))

    @constraint(model, balancoVolumeInicial[j in nb], V[j, 0] == C[j])
    
    @constraint(model, balancoVolume[j in nb, k in 1:last(nd); !(calendarioCarnaval[k] == -1 && j in quebra4) && !(entregasObrigatorias[k] == -1 && j in quebra2)],
        V[j, k] <= V[j, k-1] - U[j] + 13.0 * sum(x[j, i, k] for i in candidatos_por_beneficiario[j]))
    
    @constraint(model, correcaoVolume[j in nb, k in nd; (calendarioCarnaval[k] == -1 && j in quebra4) || (entregasObrigatorias[k] == -1 && j in quebra2)],
        V[j, k] == 0)
        
    @constraint(model, diasInuteis[j in nb, k in nd; Int(dias_uteis[k, 1]) == 0], sum(x[j, i, k] for i in candidatos_por_beneficiario[j]) == 0)
    
    @constraint(model, restMaiorPico[k in nd], sum(x[j, i, k] for j in nb, i in candidatos_por_beneficiario[j]) <= y_pico)
    
    @constraint(model, volumeMinimo[j in nb, k in 0:last(nd)], V[j, k] >= 0)
    
    @constraint(model, capacidadeMax[j in nb, k in 0:last(nd)], V[j, k] <= C[j])
    
    @constraint(model, carnavalAbastecimento[j in quebra4, k in nd; calendarioCarnaval[k] == 1], sum(x[j, i, k] for i in candidatos_por_beneficiario[j]) >= 1)
    
    @constraint(model, lilAbastecimento[j in quebra2, k in nd; entregasObrigatorias[k] == 1], sum(x[j, i, k] for i in candidatos_por_beneficiario[j]) >= 1)

    @constraint(model, fonteUnica[j in nb], sum(z[j, i] for i in candidatos_por_beneficiario[j]) == 1)
    
    @constraint(model, amarra_z_x[j in nb, k in nd, i in candidatos_por_beneficiario[j]], 
        x[j, i, k] <= CAPACIDADE_MAX_MANANCIAL * z[j, i])

    @constraint(model, capDiariaManancial[i in nm, k in nd; !isempty([j for j in nb if i in candidatos_por_beneficiario[j]])],
        sum(x[j, i, k] for j in nb if i in candidatos_por_beneficiario[j]) <= CAPACIDADE_MAX_MANANCIAL)

    horas_checkpoints = 3:3:24
    segundos_checkpoints = Float64.(horas_checkpoints .* 3600)
    
    df_historico = DataFrame(
        Hora = Int[], 
        Tempo_Segundos = Float64[],
        Objective_HigherBound = Float64[], 
        Best_LowerBound = Float64[],
        Gap_Percent = Float64[],
        Pico_Y = Int[],
        Custo_Roteamento = Float64[],
        Qtd_Entregas = Int[]
    )
    
    tempo_acumulado = 0.0
    melhor_obj_encontrado = Inf

    for (hora, meta_tempo) in zip(horas_checkpoints, segundos_checkpoints)
        tempo_restante = meta_tempo - tempo_acumulado
        if tempo_restante <= 0 continue end

        set_optimizer_attribute(model, "TimeLimit", tempo_restante)
        
        try
            optimize!(model)
        catch e
            if isa(e, InterruptException)
                println("Execução interrompida manualmente na hora $hora.")
                if has_values(model) salvar_saidas(model, caminho_pasta, "$(hora)h_INT") end
                return
            else 
                println("\nErro Fatal (Provável Memória): $e")
                println("Abortando para não entrar em loop.")
                break 
            end
        end

        tempo_acumulado = meta_tempo

        if has_values(model)
            obj = objective_value(model)
            bound = try objective_bound(model) catch; -1.0 end 
            gap = try MOI.get(model, MOI.RelativeGap()) * 100 catch; 0.0 end
            
            val_pico = round(Int, value(y_pico))
            val_custo = value(expr_custo)
            val_entregas = round(Int, value(expr_entregas))

            push!(df_historico, (hora, tempo_acumulado, obj, bound, gap, val_pico, val_custo, val_entregas))
            CSV.write(joinpath(caminho_pasta, "historico_controle.csv"), df_historico)
            
            # Só salva se for a melhor solução vista até agora
            if obj < melhor_obj_encontrado
                println(">>> Melhor solução encontrada na hora $hora: Obj = $obj")
                melhor_obj_encontrado = obj
                salvar_saidas(model, caminho_pasta, "$(hora)h")
                # Salva uma cópia fixa para garantir que o melhor está sempre acessível
                salvar_saidas(model, caminho_pasta, "melhor_absoluto")
            end
        end

        if termination_status(model) == MOI.OPTIMAL
            println("Solução Ótima comprovada. Finalizando execução.")
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

    nomes_colunas = Symbol.(["Beneficiarios"; nd...])
    
    df_abastecimento = DataFrame(colunas_abastecimento, nomes_colunas)
    CSV.write(joinpath(pasta, "abastecimento_$sufixo.csv"), df_abastecimento)

    df_alocacao = DataFrame(colunas_alocacao, nomes_colunas)
    CSV.write(joinpath(pasta, "alocacao_$sufixo.csv"), df_alocacao)
end

rodar_modelo_integrado(0.00, "resultados00_1250_365")