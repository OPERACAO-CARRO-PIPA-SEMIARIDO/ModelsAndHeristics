using CSV, DataFrames

function gerarDataFrame(duas_colunas, n)
    nb = 1:n
    # Criando vetor de consumo diário (0.02 consumo por pessoa atendida)
    U = [round(i * 0.02, digits=2) for i in duas_colunas[2]]

    # Convertendo capacidade (C) para Float64
    C = convert(Vector{Float64}, duas_colunas[1])

    #Dias que o beneficiario pode passar sem abastecimento
    Y = C ./ U

    # Criando DataFrame com os resultados
    df_resultado = DataFrame(
        Beneficiario=1:length(C),
        Capacidade=C,
        Pessoas_Atendidas=duas_colunas_b[2],
        Consumo_Diario=U,
        Dias_sem_abastecimento=Y
    )
    quebra4 = [beneficiario for (beneficiario, x) in zip(df_resultado.Beneficiario, Y) if x < 5]
    quebra2 = [beneficiario for (beneficiario, x) in zip(df_resultado.Beneficiario, Y) if x < 3]
    df_resultado = DataFrame()
end

function separarIndices(C, U, n)
    nb = 1:n
    
    #Dias que o beneficiario pode passar sem abastecimento
    Y = C ./ U

    # Criando DataFrame com os resultados
    df_resultado = DataFrame(
        Beneficiario=1:length(C),
        Dias_sem_abastecimento=Y
    )
    quebra4 = [beneficiario for (beneficiario, x) in zip(df_resultado.Beneficiario, Y) if x < 5]
    quebra2 = [beneficiario for (beneficiario, x) in zip(df_resultado.Beneficiario, Y) if x < 3]
    resultado = [quebra2, quebra4]
    return resultado
end