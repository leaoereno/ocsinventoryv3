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
:: Servidores OCS conhecidos -- edite conforme o ambiente crescer
:: Formato: set "RELAY_N_IP=IP" e set "RELAY_N_DESC=Nome do Site"
set "RELAY_1_IP=10.24.22.93"       & set "RELAY_1_DESC=Omnichannel"
set "RELAY_2_IP=10.24.55.30"       & set "RELAY_2_DESC=DC Lapa Servers (lnxdczabprod02)"
set "RELAY_3_IP=10.24.55.31"       & set "RELAY_3_DESC=SNOC"
set "RELAY_4_IP=10.24.55.32"       & set "RELAY_4_DESC=DC Lapa Redes"
set "RELAY_5_IP=10.24.127.56"      & set "RELAY_5_DESC=DC Makenzie"
set "RELAY_6_IP=10.24.21.157"      & set "RELAY_6_DESC=Bradesco GVP"
set "RELAY_7_IP=10.230.22.199"     & set "RELAY_7_DESC=Globalhitss"
set "RELAY_8_IP=172.27.0.39"       & set "RELAY_8_DESC=CLOUD"
set "RELAY_9_IP=172.28.118.124"    & set "RELAY_9_DESC=OPENSTACK-EDGE01"
set "RELAY_10_IP=172.28.118.125"   & set "RELAY_10_DESC=OPENSTACK-EDGE02"
set "RELAY_11_IP=172.20.201.95"    & set "RELAY_11_DESC=DCV-01"
set "RELAY_12_IP=172.20.201.98"    & set "RELAY_12_DESC=DCV-02"
set "RELAY_13_IP=10.40.201.124"    & set "RELAY_13_DESC=FEDERADO01"
set "RELAY_14_IP=10.40.201.125"    & set "RELAY_14_DESC=FEDERADO02"
set "RELAY_15_IP=172.19.118.124"   & set "RELAY_15_DESC=Openstack EDGE-BSA01"
set "RELAY_16_IP=172.19.118.125"   & set "RELAY_16_DESC=Openstack EDGE-BSA02"
set "RELAY_17_IP=172.18.118.124"   & set "RELAY_17_DESC=Openstack EDGE-CTA01"
set "RELAY_18_IP=172.18.118.125"   & set "RELAY_18_DESC=Openstack EDGE-CTA02"
set "RELAY_COUNT=18"

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
echo [INFO] === Selecao do Servidor OCS ===

if not "!BACKEND_URL!"=="" goto :url_defined

echo.
echo   Selecione o servidor OCS para onde o agente ira se reportar:
echo.
echo   [ 1]  !RELAY_1_IP!        !RELAY_1_DESC!
echo   [ 2]  !RELAY_2_IP!        !RELAY_2_DESC!
echo   [ 3]  !RELAY_3_IP!        !RELAY_3_DESC!
echo   [ 4]  !RELAY_4_IP!        !RELAY_4_DESC!
echo   [ 5]  !RELAY_5_IP!       !RELAY_5_DESC!
echo   [ 6]  !RELAY_6_IP!       !RELAY_6_DESC!
echo   [ 7]  !RELAY_7_IP!     !RELAY_7_DESC!
echo   [ 8]  !RELAY_8_IP!        !RELAY_8_DESC!
echo   [ 9]  !RELAY_9_IP!    !RELAY_9_DESC!
echo   [10]  !RELAY_10_IP!    !RELAY_10_DESC!
echo   [11]  !RELAY_11_IP!       !RELAY_11_DESC!
echo   [12]  !RELAY_12_IP!       !RELAY_12_DESC!
echo   [13]  !RELAY_13_IP!      !RELAY_13_DESC!
echo   [14]  !RELAY_14_IP!      !RELAY_14_DESC!
echo   [15]  !RELAY_15_IP!    !RELAY_15_DESC!
echo   [16]  !RELAY_16_IP!    !RELAY_16_DESC!
echo   [17]  !RELAY_17_IP!    !RELAY_17_DESC!
echo   [18]  !RELAY_18_IP!    !RELAY_18_DESC!
echo   [19]  Informar manualmente
echo.

set /p "RELAY_ESCOLHA=  Escolha [1-19]: "

if "!RELAY_ESCOLHA!"=="1"  set "BACKEND_URL=http://!RELAY_1_IP!"
if "!RELAY_ESCOLHA!"=="2"  set "BACKEND_URL=http://!RELAY_2_IP!"
if "!RELAY_ESCOLHA!"=="3"  set "BACKEND_URL=http://!RELAY_3_IP!"
if "!RELAY_ESCOLHA!"=="4"  set "BACKEND_URL=http://!RELAY_4_IP!"
if "!RELAY_ESCOLHA!"=="5"  set "BACKEND_URL=http://!RELAY_5_IP!"
if "!RELAY_ESCOLHA!"=="6"  set "BACKEND_URL=http://!RELAY_6_IP!"
if "!RELAY_ESCOLHA!"=="7"  set "BACKEND_URL=http://!RELAY_7_IP!"
if "!RELAY_ESCOLHA!"=="8"  set "BACKEND_URL=http://!RELAY_8_IP!"
if "!RELAY_ESCOLHA!"=="9"  set "BACKEND_URL=http://!RELAY_9_IP!"
if "!RELAY_ESCOLHA!"=="10" set "BACKEND_URL=http://!RELAY_10_IP!"
if "!RELAY_ESCOLHA!"=="11" set "BACKEND_URL=http://!RELAY_11_IP!"
if "!RELAY_ESCOLHA!"=="12" set "BACKEND_URL=http://!RELAY_12_IP!"
if "!RELAY_ESCOLHA!"=="13" set "BACKEND_URL=http://!RELAY_13_IP!"
if "!RELAY_ESCOLHA!"=="14" set "BACKEND_URL=http://!RELAY_14_IP!"
if "!RELAY_ESCOLHA!"=="15" set "BACKEND_URL=http://!RELAY_15_IP!"
if "!RELAY_ESCOLHA!"=="16" set "BACKEND_URL=http://!RELAY_16_IP!"
if "!RELAY_ESCOLHA!"=="17" set "BACKEND_URL=http://!RELAY_17_IP!"
if "!RELAY_ESCOLHA!"=="18" set "BACKEND_URL=http://!RELAY_18_IP!"
if "!RELAY_ESCOLHA!"=="19" (
    echo.
    set /p "BACKEND_URL=  URL ou IP do relay (ex.: http://IP ou http://IP:PORTA): "
    if "!BACKEND_URL!"=="" (
        echo [ERRO] URL obrigatoria.
        pause & exit /b 1
    )
    :: Adicionar http:// se o usuario digitou apenas o IP
    echo !BACKEND_URL! | findstr /i "^http" >nul 2>&1 || set "BACKEND_URL=http://!BACKEND_URL!"
)

if "!BACKEND_URL!"=="" (
    echo [ERRO] Opcao invalida: !RELAY_ESCOLHA!. Escolha entre 1 e 19.
    pause & exit /b 1
)

:: Perguntar tag de identificacao do ativo
echo.
set /p "AGENT_TAG=  Tag do ativo no console (ex.: ITSM-DEVOPS, NOC, INFRA - Enter para pular): "
if not "!AGENT_TAG!"=="" (
    echo [INFO] Tag definida: !AGENT_TAG!
) else (
    echo [INFO] Sem tag definida.
)

:url_defined
:: Remover barra final
if "!BACKEND_URL:~-1!"=="/" set "BACKEND_URL=!BACKEND_URL:~0,-1!"

echo [INFO] Servidor OCS selecionado: !BACKEND_URL!

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
