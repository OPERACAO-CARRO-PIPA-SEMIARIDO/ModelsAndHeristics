import pandas as pd
import numpy as np
import matplotlib.pyplot as plt
import seaborn as sns
import os

class AnalisadorAlocacao:
    def __init__(self, caminho_alocacao, caminho_rotas, num_mananciais=92):
        self.num_mananciais = num_mananciais
        
        print("Carregando dados...")
        self.df_alocacao = pd.read_csv(caminho_alocacao)
        self.df_rotas = pd.read_csv(caminho_rotas) 
        
        num_beneficiarios = len(self.df_alocacao)
        self.dist_matrix = np.array(self.df_rotas['distance_w_factor']).reshape(
            (self.num_mananciais, num_beneficiarios), order='F'
        )
        
        df_dias = self.df_alocacao.iloc[:, 1:]
        self.fontes_escolhidas = df_dias.max(axis=1).fillna(0).astype(int)

    def validar_heuristica_proximidade(self, salvar_csv=True):
        rankings = []
        for j, fonte_julia in enumerate(self.fontes_escolhidas):
            if fonte_julia == 0:
                rankings.append(-1) 
                continue
                
            fonte_python = fonte_julia - 1 
            distancias_j = self.dist_matrix[:, j]
            fontes_ordenadas = np.argsort(distancias_j)
            
            posicao = np.where(fontes_ordenadas == fonte_python)[0][0] + 1
            rankings.append(posicao)
            
        self.df_alocacao['Ranking_Fonte'] = rankings
        
        df_validos = self.df_alocacao[self.df_alocacao['Ranking_Fonte'] > 0]
        contagem = df_validos['Ranking_Fonte'].value_counts().sort_index()
        
        print("\n--- Distribuição de Proximidade ---")
        print(contagem)
        
        if salvar_csv:
            self.df_alocacao.to_csv("alocacao_com_rankings.csv", index=False)
            print("Planilha 'alocacao_com_rankings.csv' gerada com sucesso.")
            
        self._plotar_grafico_proximidade(contagem)
        return contagem

    def _plotar_grafico_proximidade(self, contagem):
        plt.figure(figsize=(10, 6))
        # Aviso do seaborn corrigido com o uso do 'hue' e 'legend=False'
        sns.barplot(x=contagem.index, y=contagem.values, hue=contagem.index, palette='viridis', legend=False)
        
        plt.title('Validação da Heurística: Uso dos Mananciais mais Próximos')
        plt.xlabel('Posição da Fonte (1 = Mais Próxima, 2 = Segunda Mais Próxima...)')
        plt.ylabel('Quantidade de Beneficiários')
        plt.xticks(rotation=0)
        
        for i, valor in enumerate(contagem.values):
            plt.text(i, valor + (max(contagem.values)*0.01), str(valor), ha='center')
            
        plt.tight_layout()
        plt.savefig('boxplot_proximidade.png')
        print("Gráfico salvo como 'boxplot_proximidade.png'.")
        plt.close() # Fecha a figura para não sobrepor futuros gráficos

    def listar_beneficiarios_por_manancial(self, ids_mananciais):
        beneficiarios_alocados = self.df_alocacao[self.fontes_escolhidas.isin(ids_mananciais)]
        return beneficiarios_alocados.iloc[:, 0].tolist() 

    # ==========================================
    # NOVAS FUNÇÕES
    # ==========================================
    def gerar_relatorio_autonomia(self, caminho_beneficiarios, salvar_csv=True):
        """
        Calcula a autonomia dos reservatórios e gera um CSV e um gráfico ordenados de forma decrescente,
        incluindo o ID do manancial, ID do beneficiário e um contador de posição.
        """
        print("\nGerando relatório de autonomia dos reservatórios...")
        df_ben = pd.read_csv(caminho_beneficiarios)
        
        # 1. Atrelar o ID do beneficiário (1 a N, para bater com o Julia) e o Manancial alocado
        df_ben['ID_Beneficiario'] = df_ben.index + 1
        df_ben['Manancial_Alocado'] = self.fontes_escolhidas.values
        
        # 2. Calcular o consumo e a autonomia
        consumo_diario = df_ben['Pessoas_Atendidas'] * 0.02
        df_ben['Dias_Autonomia'] = (df_ben['Capacidade'] / consumo_diario).round(2)
        
        # 3. Ordenar de maneira decrescente
        df_ordenado = df_ben.sort_values(by='Dias_Autonomia', ascending=False).reset_index(drop=True)
        
        # 4. Adicionar o contador de linha (Posição na lista ordenada)
        # Usamos insert na posição 0 para que seja a primeira coluna a aparecer no VisiData/CSV
        df_ordenado.insert(0, 'Posicao', df_ordenado.index + 1)
        
        if salvar_csv:
            # Organizando as colunas para o CSV final
            colunas_exportacao = [
                'Posicao', 
                'ID_Beneficiario', 
                'Pessoas_Atendidas', 
                'Capacidade', 
                'Dias_Autonomia', 
                'Manancial_Alocado'
            ]
            df_export = df_ordenado[colunas_exportacao]
            df_export.to_csv("autonomia_decrescente.csv", index=False)
            print("Planilha 'autonomia_decrescente.csv' gerada com sucesso.")
            
        self._plotar_grafico_autonomia(df_ordenado)
        return df_ordenado

    def _plotar_grafico_autonomia(self, df_ordenado):
        """Método interno para gerar o gráfico de autonomia."""
        plt.figure(figsize=(12, 6))
        
        # Plotando uma curva de decaimento com cor vinho sólido
        plt.plot(df_ordenado.index, df_ordenado['Dias_Autonomia'], color='#722f37', linewidth=2)
        
        # Marcando a linha de quem tem menos de X dias (exemplo visual: linha de corte em 5 dias)
        plt.axhline(y=5, color='gray', linestyle='--', alpha=0.5, label='Linha de corte (5 dias)')
        
        plt.title('Autonomia dos Reservatórios em Ordem Decrescente')
        plt.xlabel('Beneficiários (Ordenados por maior autonomia)')
        plt.ylabel('Dias de Autonomia (Capacidade / Consumo)')
        plt.legend()
        plt.grid(True, alpha=0.3)
        
        plt.tight_layout()
        plt.savefig('grafico_autonomia.png')
        print("Gráfico salvo como 'grafico_autonomia.png'.")
        plt.show()

# ==========================================
# EXEMPLO DE USO
# ==========================================
if __name__ == "__main__":
    ARQUIVO_ALOCACAO = "/home/guilherme/ModelsAndHeristics/alocacao/saidas_2/alocacao_10wLim/alocacao_m2.csv" 
    ARQUIVO_ROTAS = "/home/guilherme/repos/backup/AlocacaoCarrosPipas/Dados/rotas" 
    # Adicione o caminho do arquivo de beneficiários aqui
    ARQUIVO_BENEFICIARIOS = "/home/guilherme/repos/backup/AlocacaoCarrosPipas/Dados/Beneficiarios_RN_Ativos1.csv"

    try:
        analisador = AnalisadorAlocacao(ARQUIVO_ALOCACAO, ARQUIVO_ROTAS)
        
        analisador.validar_heuristica_proximidade()
        
        beneficiarios_sem_agua = analisador.df_alocacao[analisador.df_alocacao['Ranking_Fonte'] == -1]
        print(f"\nBeneficiários sem consumo no período (Total: {len(beneficiarios_sem_agua)}):")
        print(beneficiarios_sem_agua.iloc[:, 0].tolist())
        
        mananciais_alvo = [1, 15] 
        beneficiarios = analisador.listar_beneficiarios_por_manancial(mananciais_alvo)
        print(f"\nBeneficiários atendidos pelos mananciais {mananciais_alvo}:\n{beneficiarios}")
        
        # Chamada da nova função de autonomia
        analisador.gerar_relatorio_autonomia(ARQUIVO_BENEFICIARIOS)
        
    except FileNotFoundError as e:
        print(f"Erro: Arquivo não encontrado. Verifique os caminhos. Detalhes: {e}")
