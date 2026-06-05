@echo off
setlocal
cd /d "%~dp0"

echo ============================================================
echo  ROLLING HORIZON: 120 dias, 90 dias, 60 dias
echo  3315 benef x 92 mananciais x 365 dias x k=3
echo  Tempo limite por janela: 5 horas
echo  Saida: testes_rolling\
echo ============================================================
echo.

python rolling_horizon.py
if errorlevel 1 (
    echo ERRO ao executar rolling_horizon.py
    goto :fim
)

:fim
echo.
echo Execucao finalizada.
pause
