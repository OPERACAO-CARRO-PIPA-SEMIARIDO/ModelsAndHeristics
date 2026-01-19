using CSV, DataFrames, Statistics

function analisarM1()
    # Caminho do arquivo
    file_path = "/home/guilherme/repos/backup/AlocacaoCarrosPipas/m1MinimizaPicos.csv"

    # 1. Leitura correta do arquivo
    df = CSV.read(file_path, DataFrame)

    # 2. Verifica se a coluna existe antes de somar para evitar erros
    if "Solucao_otima" in names(df)
        # 3. Soma correta acessando a coluna com df.Solucao_otima
        total = sum(df.Solucao_otima)

        println("Soma total da Solução Ótima: ", total)
    else
        println("Erro: A coluna 'Solucao_otima' não foi encontrada no arquivo CSV.")
    end
end

analisarM1()
