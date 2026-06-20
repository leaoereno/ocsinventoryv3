@echo off
setlocal enabledelayedexpansion
chcp 65001 >nul 2>&1
title OCS Inventory -- Instalador / Atualizador do Agente

:: =============================================================================
:: install-ocsinventory-agent.bat
::
:: Instala ou ATUALIZA o agente do OCS Inventory 3.0 no Windows.
:: Se detectar uma versao anterior instalada, remove-a antes de instalar.
::
:: Uso:
::   install-ocsinventory-agent.bat [URL] [/force]
::
:: Argumentos (todos opcionais -- serao perguntados se omitidos):
::   %1   URL do backend, ex.: http://10.24.22.90:8000
::   /force  Forcar reinstalacao mesmo se a versao ja for igual
:: =============================================================================

:: ---------------------------------------------------------------------------
:: Configuracao
:: ---------------------------------------------------------------------------
set "OCS_VERSION=3.0.0-rc1"
set "INSTALL_DIR=C:\Program Files\OCS Inventory Agent"
set "DATA_DIR=C:\ProgramData\OCS Inventory Agent"
set "TEMP_DIR=%TEMP%\ocs-install-%RANDOM%"
set "LOG_FILE=%TEMP_DIR%\install.log"
set "AGENT_EXE=OCSInventory-Agent-Windows-%OCS_VERSION%.exe"
set "AGENT_CLI=ocsinventory-cli.exe"
set "SERVICE_NAME=OCSInventoryAgent"
set "FORCE_REINSTALL=0"

set "AGENT_DOWNLOAD_URL=https://github.com/OCSInventory-NG/OCSInventory-Agent-Rework/releases/download/%OCS_VERSION%/%AGENT_EXE%"

:: ---------------------------------------------------------------------------
:: Verificar argumentos
:: ---------------------------------------------------------------------------
set "BACKEND_URL="
set "ADMIN_USER=ocsagentes"
set "ADMIN_PASS=PSWAgente"

if not "%~1"=="" (
    echo %~1 | findstr /i "^/force" >nul 2>&1 && set "FORCE_REINSTALL=1" || set "BACKEND_URL=%~1"
)
:: Usuario e senha fixos -- nao lidos de argumentos
if /i "%~4"=="/force" set "FORCE_REINSTALL=1"

:: ---------------------------------------------------------------------------
:: Banner
:: ---------------------------------------------------------------------------
echo.
echo =======================================================
echo   OCS Inventory 3.0 ^| Instalador / Atualizador
echo   Versao alvo: %OCS_VERSION%
echo =======================================================
echo.

:: ---------------------------------------------------------------------------
:: Verificar privilegios de Administrador
:: ---------------------------------------------------------------------------
net session >nul 2>&1
if errorlevel 1 (
    echo [ERRO] Execute como Administrador ^(botao direito -^> Executar como administrador^).
    pause & exit /b 1
)

:: ---------------------------------------------------------------------------
:: Criar diretorio temporario
:: ---------------------------------------------------------------------------
mkdir "%TEMP_DIR%" >nul 2>&1

:: ---------------------------------------------------------------------------
:: Detectar versao instalada atualmente
:: ---------------------------------------------------------------------------
echo [INFO] Verificando versao instalada...
set "INSTALLED_VERSION="
set "INSTALLED_BIN="

:: Verificar binario no diretorio padrao
if exist "%INSTALL_DIR%\%AGENT_CLI%" (
    set "INSTALLED_BIN=%INSTALL_DIR%\%AGENT_CLI%"
)
:: Verificar no PATH
if "!INSTALLED_BIN!"=="" (
    for /f "delims=" %%F in ('where ocsinventory-cli 2^>nul') do set "INSTALLED_BIN=%%F"
)

:: Tentar ler a versao instalada
if not "!INSTALLED_BIN!"=="" (
    for /f "tokens=*" %%V in (
        '"!INSTALLED_BIN!" --version 2^>nul'
    ) do (
        set "RAW_VER=%%V"
        :: Extrair padrao x.y.z da saida
        for /f "tokens=1-4 delims=. " %%A in ("!RAW_VER!") do (
            echo !RAW_VER! | findstr /r "[0-9][0-9]*\.[0-9][0-9]*" >nul 2>&1 && (
                set "INSTALLED_VERSION=!RAW_VER!"
            )
        )
    )
    if "!INSTALLED_VERSION!"=="" set "INSTALLED_VERSION=desconhecida"
    echo [INFO] Versao instalada : !INSTALLED_VERSION!
    echo [INFO] Binario          : !INSTALLED_BIN!
) else (
    echo [INFO] Nenhuma versao anterior encontrada -- instalacao nova.
)

:: ---------------------------------------------------------------------------
:: Decidir se precisa atualizar / reinstalar
:: ---------------------------------------------------------------------------
set "NEED_REMOVE=0"

if "!INSTALLED_BIN!"=="" goto :collect_params

:: Versao encontrada -- comparar com a desejada
if "!INSTALLED_VERSION!"=="%OCS_VERSION%" (
    if "!FORCE_REINSTALL!"=="1" (
        echo [AVISO] Versao %OCS_VERSION% ja instalada, mas /force foi especificado. Reinstalando...
        set "NEED_REMOVE=1"
    ) else (
        echo.
        echo [INFO] A versao %OCS_VERSION% ja esta instalada.
        set /p "REINSTALL=  Reinstalar mesmo assim? [S/N]: "
        if /i "!REINSTALL!"=="S" (
            set "NEED_REMOVE=1"
        ) else (
            echo Nenhuma alteracao feita. Use /force para forcar reinstalacao.
            goto :end_clean
        )
    )
) else (
    echo [AVISO] Versao diferente detectada ^(!INSTALLED_VERSION! -^> %OCS_VERSION%^).
    echo [INFO]  Removendo versao anterior antes de instalar...
    set "NEED_REMOVE=1"
)

:: ---------------------------------------------------------------------------
:: Remover versao anterior
:: ---------------------------------------------------------------------------
if "!NEED_REMOVE!"=="1" (
    echo.
    echo [INFO] === Removendo versao anterior ===

    :: 1. Parar e remover servico Windows
    sc query !SERVICE_NAME! >nul 2>&1
    if not errorlevel 1 (
        echo [INFO] Parando servico !SERVICE_NAME!...
        sc stop !SERVICE_NAME! >nul 2>&1
        timeout /t 3 /nobreak >nul

        :: Aguardar o servico parar de fato
        set "STOP_WAIT=0"
        :wait_stop
        sc query !SERVICE_NAME! | findstr /i "STOPPED" >nul 2>&1 && goto :service_stopped
        if !STOP_WAIT! lss 10 (
            timeout /t 2 /nobreak >nul
            set /a STOP_WAIT+=1
            goto :wait_stop
        )
        echo [AVISO] Servico demorou para parar -- forcando...
        taskkill /f /im "%AGENT_CLI%" >nul 2>&1 || true

        :service_stopped
        echo [INFO] Removendo servico !SERVICE_NAME!...
        sc delete !SERVICE_NAME! >nul 2>&1
        timeout /t 2 /nobreak >nul
    )

    :: 2. Usar desinstalador oficial (.exe /S) se disponivel
    if exist "%INSTALL_DIR%\uninstall.exe" (
        echo [INFO] Executando desinstalador oficial...
        "%INSTALL_DIR%\uninstall.exe" /S >nul 2>&1
        timeout /t 5 /nobreak >nul
    )

    :: 3. Matar processo do agente se ainda estiver rodando
    taskkill /f /im "%AGENT_CLI%" >nul 2>&1 || true

    :: 4. Remover binarios e configuracoes
    if exist "%INSTALL_DIR%" (
        echo [INFO] Removendo diretorio de instalacao: %INSTALL_DIR%
        rmdir /s /q "%INSTALL_DIR%" >nul 2>&1 || (
            :: Tentativa forcada com takeown se o rmdir falhar
            takeown /f "%INSTALL_DIR%" /r /d Y >nul 2>&1
            icacls "%INSTALL_DIR%" /grant administrators:F /t >nul 2>&1
            rmdir /s /q "%INSTALL_DIR%" >nul 2>&1
        )
    )

    :: 5. Remover entradas de registro do servico (limpeza residual)
    reg delete "HKLM\SYSTEM\CurrentControlSet\Services\!SERVICE_NAME!" /f >nul 2>&1 || true
    reg delete "HKLM\SOFTWARE\OCS Inventory Agent" /f >nul 2>&1 || true
    reg delete "HKLM\SOFTWARE\WOW6432Node\OCS Inventory Agent" /f >nul 2>&1 || true

    :: 6. Remover entrada do PATH (se foi adicionada pelo instalador anterior)
    powershell -ExecutionPolicy Bypass -Command ^
        "$p = [Environment]::GetEnvironmentVariable('Path','Machine'); ^
         $new = ($p -split ';' ^| Where-Object {$_ -notlike '*OCS Inventory*'}) -join ';'; ^
         [Environment]::SetEnvironmentVariable('Path',$new,'Machine')" >nul 2>&1

    echo [INFO] Versao anterior removida.
    echo.
)

:: ---------------------------------------------------------------------------
:: Coletar parametros de conexao
:: ---------------------------------------------------------------------------
:collect_params
echo [INFO] === Configuracao do backend ===

if "!BACKEND_URL!"=="" (
    echo.
    echo   Informe a URL do backend do OCS Inventory.
    echo   Exemplo: http://10.24.22.90:8000
    echo.
    set /p "BACKEND_URL=  URL do backend: "
    if "!BACKEND_URL!"=="" (
        echo [ERRO] URL obrigatoria.
        pause & exit /b 1
    )
)

:: Remover barra final
if "!BACKEND_URL:~-1!"=="/" set "BACKEND_URL=!BACKEND_URL:~0,-1!"

:: Credenciais ja definidas (conta de servico ocsagentes)

:: ---------------------------------------------------------------------------
:: Confirmar
:: ---------------------------------------------------------------------------
echo.
echo   Resumo:
echo     Backend  : !BACKEND_URL!
echo     Usuario  : !ADMIN_USER!
echo     Versao   : %OCS_VERSION%
echo     Servico  : !SERVICE_NAME!
echo     Pasta    : %INSTALL_DIR%
echo.
set /p "CONFIRM=  Confirmar instalacao? [S/N]: "
if /i not "!CONFIRM!"=="S" (
    echo Instalacao cancelada.
    goto :end_clean
)
echo.

:: ---------------------------------------------------------------------------
:: Download do instalador
:: ---------------------------------------------------------------------------
echo [INFO] === Download do agente ===
echo [INFO] Origem: %AGENT_DOWNLOAD_URL%

powershell -ExecutionPolicy Bypass -Command ^
    "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; ^
     try { ^
         $wc = New-Object System.Net.WebClient; ^
         $wc.DownloadFile('%AGENT_DOWNLOAD_URL%', '%TEMP_DIR%\%AGENT_EXE%'); ^
         Write-Host '[INFO] Download OK.' ^
     } catch { ^
         Write-Host '[AVISO] Download falhou: ' + $_.Exception.Message; ^
         exit 1 ^
     }"

if errorlevel 1 goto :manual_install
if not exist "%TEMP_DIR%\%AGENT_EXE%" goto :manual_install

:: ---------------------------------------------------------------------------
:: Instalacao via installer oficial
:: ---------------------------------------------------------------------------
echo [INFO] === Instalando ===
"%TEMP_DIR%\%AGENT_EXE%" /S ^
    /URL="!BACKEND_URL!" ^
    /USERNAME="!ADMIN_USER!" ^
    /PASSWORD="!ADMIN_PASS!" ^
    /LOGFILE="%LOG_FILE%" ^
    /INSTALL_SERVICE=1

if errorlevel 1 (
    echo [AVISO] Instalador retornou erro. Tentando configuracao manual...
    goto :manual_install
)
goto :start_service

:: ---------------------------------------------------------------------------
:: Instalacao manual (fallback)
:: ---------------------------------------------------------------------------
:manual_install
echo [INFO] === Instalacao manual ===
mkdir "%INSTALL_DIR%" >nul 2>&1
mkdir "%DATA_DIR%" >nul 2>&1

if not exist "%INSTALL_DIR%\%AGENT_CLI%" (
    echo [AVISO] Binario nao encontrado em %INSTALL_DIR%.
    echo         Copie manualmente o %AGENT_CLI% para %INSTALL_DIR% e
    echo         execute novamente, ou instale via:
    echo         https://github.com/OCSInventory-NG/OCSInventory-Agent-Rework/releases
)

:: Criar arquivo de configuracao
echo [INFO] Criando ocsinventory.cfg...
(
echo [ocsinventory]
echo server   = !BACKEND_URL!
echo username = !ADMIN_USER!
echo password = !ADMIN_PASS!
echo logfile  = %DATA_DIR%\ocsinventory.log
echo loglevel = 3
echo mode     = 1
) > "%INSTALL_DIR%\ocsinventory.cfg"

:: Criar servico se o binario existir
if exist "%INSTALL_DIR%\%AGENT_CLI%" (
    sc create !SERVICE_NAME! ^
        binPath= "\"%INSTALL_DIR%\%AGENT_CLI%\" --config \"%INSTALL_DIR%\ocsinventory.cfg\"" ^
        DisplayName= "OCS Inventory Agent" ^
        start= auto >nul 2>&1 && (
        echo [INFO] Servico !SERVICE_NAME! criado.
    ) || echo [AVISO] Falha ao criar servico.
)

:: ---------------------------------------------------------------------------
:: Iniciar servico
:: ---------------------------------------------------------------------------
:start_service
echo.
echo [INFO] === Iniciando servico ===
sc query !SERVICE_NAME! >nul 2>&1
if not errorlevel 1 (
    sc start !SERVICE_NAME! >nul 2>&1
    timeout /t 3 /nobreak >nul
)

:: Adicionar ao PATH
powershell -ExecutionPolicy Bypass -Command ^
    "$p = [Environment]::GetEnvironmentVariable('Path','Machine'); ^
     if ($p -notlike '*OCS Inventory*') { ^
         [Environment]::SetEnvironmentVariable('Path', $p + ';%INSTALL_DIR%', 'Machine') ^
     }" >nul 2>&1

:: ---------------------------------------------------------------------------
:: Verificar resultado
:: ---------------------------------------------------------------------------
echo.
echo [INFO] === Verificacao ===

set "FINAL_STATUS=DESCONHECIDO"
sc query !SERVICE_NAME! >nul 2>&1
if not errorlevel 1 (
    for /f "tokens=3" %%S in ('sc query !SERVICE_NAME! ^| findstr /i "STATE"') do (
        set "FINAL_STATUS=%%S"
    )
)

if exist "%INSTALL_DIR%\%AGENT_CLI%" (
    echo [INFO] Binario : %INSTALL_DIR%\%AGENT_CLI%
) else (
    echo [AVISO] Binario nao encontrado em %INSTALL_DIR%
)
echo [INFO] Servico : !SERVICE_NAME! ^(estado: !FINAL_STATUS!^)
echo [INFO] Config  : %INSTALL_DIR%\ocsinventory.cfg
echo [INFO] Log     : %DATA_DIR%\ocsinventory.log

:: ---------------------------------------------------------------------------
:: Resumo final
:: ---------------------------------------------------------------------------
echo.
echo =======================================================
echo   Instalacao concluida ^| OCS Inventory %OCS_VERSION%
echo =======================================================
echo   Backend  : !BACKEND_URL!
echo   Usuario  : !ADMIN_USER!
echo   Servico  : !SERVICE_NAME! ^(!FINAL_STATUS!^)
echo   Pasta    : %INSTALL_DIR%
echo   Log inst.: %LOG_FILE%
echo.
echo   Comandos uteis:
echo     Iniciar  : sc start !SERVICE_NAME!
echo     Parar    : sc stop !SERVICE_NAME!
echo     Status   : sc query !SERVICE_NAME!
echo     Executar : "%INSTALL_DIR%\%AGENT_CLI%" --now
echo =======================================================

:end_clean
:: Limpar temporarios
if exist "%TEMP_DIR%\%AGENT_EXE%" del /f /q "%TEMP_DIR%\%AGENT_EXE%" >nul 2>&1

echo.
pause
endlocal
exit /b 0
