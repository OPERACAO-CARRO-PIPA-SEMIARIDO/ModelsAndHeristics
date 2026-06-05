@echo off
setlocal
cd /d "%~dp0"

set BASE_DATA=C:\Users\lfeli\Documents\AlocacaoCarros\dados
set ROTAS=%BASE_DATA%\rotas
set M2_SCRIPT=..\..\alocacao\m2args.jl
set NUM_MANANCIAIS=40
set ABAST_MINPICOS=resultados_minpicos\abastecimento_melhor_absoluto.csv

echo ============================================================
echo  minimizaPicos + m2  (1250 benef x 40 mananciais x 365 dias)
echo ============================================================
echo.

echo === [1/2] minimizaPicos - calendario Gurobi (ate 24h) ===
julia minimizaPicos_1250_365.jl
if errorlevel 1 (
    echo ERRO em minimizaPicos. Abortando.
    goto :fim
)

if not exist %ABAST_MINPICOS% (
    echo ERRO: %ABAST_MINPICOS% nao encontrado. minimizaPicos nao gerou solucao.
    goto :fim
)

echo.
echo === [2/2] alocacao m2 - Gurobi (ate 1h) ===
julia %M2_SCRIPT% ^
    %ABAST_MINPICOS% ^
    alocacao_m2_minpicos.csv ^
    custos_m2_minpicos.csv ^
    %ROTAS% ^
    %NUM_MANANCIAIS%
if errorlevel 1 (
    echo ERRO em m2.
    goto :fim
)

echo.
echo Concluido. Resultados:
echo   Calendario: %ABAST_MINPICOS%
echo   Alocacao:   alocacao_m2_minpicos.csv
echo   Custos:     custos_m2_minpicos.csv

:fim
pause
