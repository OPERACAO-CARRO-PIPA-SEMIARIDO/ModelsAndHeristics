@echo off
setlocal
cd /d "%~dp0"

set BASE_DATA=C:\Users\lfeli\Documents\AlocacaoCarros\dados
set ROTAS=%BASE_DATA%\rotas
set M2_SCRIPT=..\..\alocacao\m2args.jl
set NUM_MANANCIAIS=40

echo ============================================================
echo  TESTE: 1250 benef x 40 mananciais x 365 dias x k=5
echo ============================================================
echo.

echo === [1/3] modelo integrado - warm start heuristico (ate 24h) ===
julia modeloIntegrado_ws.jl
if errorlevel 1 (
    echo ERRO em modelo integrado.
    goto :fim
)

echo.
echo === [2/3] minimizaPicos - calendario Gurobi (ate 24h) ===
julia minimizaPicos_1250_365.jl
if errorlevel 1 (
    echo ERRO em minimizaPicos. Abortando.
    goto :fim
)

echo.
echo === [3/3] alocacao m2 - Gurobi (ate 1h) ===
julia %M2_SCRIPT% ^
    resultados_minpicos\abastecimento_melhor_absoluto.csv ^
    alocacao_m2_minpicos.csv ^
    custos_m2_minpicos.csv ^
    %ROTAS% ^
    %NUM_MANANCIAIS%
if errorlevel 1 (
    echo ERRO em m2.
)

:fim
echo.
echo Execucao finalizada.
pause
