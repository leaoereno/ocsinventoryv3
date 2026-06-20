# OCS Inventory 3.0 — Instalador Multi-Layer

Conjunto de scripts para instalação, atualização e distribuição do **OCS Inventory 3.0** (tag `3.0.0-rc1`) em qualquer topologia de rede — de um único servidor de laboratório a ambientes corporativos distribuídos em múltiplos sites.

---

## Índice

1. [Arquitetura e componentes](#1-arquitetura-e-componentes)
2. [Papéis de instalação do servidor](#2-papéis-de-instalação-do-servidor)
3. [Scripts disponíveis](#3-scripts-disponíveis)
4. [Pré-requisitos](#4-pré-requisitos)
5. [Instalação do servidor — tipos e exemplos](#5-instalação-do-servidor--tipos-e-exemplos)
   - 5.1 [Tudo em um — laboratório](#51-tudo-em-um--laboratório)
   - 5.2 [Duas camadas — App + Banco](#52-duas-camadas--app--banco)
   - 5.3 [Três camadas — Banco + Backend + Frontend](#53-três-camadas--banco--backend--frontend)
   - 5.4 [Quatro camadas — Banco + Backend + Frontend + SNMP](#54-quatro-camadas--banco--backend--frontend--snmp)
   - 5.5 [Relay de agentes — site remoto com porta 80](#55-relay-de-agentes--site-remoto-com-porta-80)
   - 5.6 [Multi-site com relays distribuídos](#56-multi-site-com-relays-distribuídos)
   - 5.7 [Banco em outro servidor via SSH](#57-banco-em-outro-servidor-via-ssh)
6. [Instalação do agente nos endpoints](#6-instalação-do-agente-nos-endpoints)
   - 6.1 [Linux / Unix](#61-linux--unix)
   - 6.2 [Windows](#62-windows)
   - 6.3 [Credenciais do agente](#63-credenciais-do-agente)
   - 6.4 [Atualização automática](#64-atualização-automática)
7. [Referência de flags — servidor](#7-referência-de-flags--servidor)
8. [Referência de flags — agente Linux](#8-referência-de-flags--agente-linux)
9. [Seleção de IP com múltiplas interfaces](#9-seleção-de-ip-com-múltiplas-interfaces)
10. [Banco de dados — detalhes](#10-banco-de-dados--detalhes)
11. [Particularidades por distro](#11-particularidades-por-distro)
12. [Problemas conhecidos e soluções](#12-problemas-conhecidos-e-soluções)
13. [Validação pós-instalação](#13-validação-pós-instalação)
14. [Logs e credenciais](#14-logs-e-credenciais)
15. [Idempotência](#15-idempotência)
16. [Limitações conhecidas](#16-limitações-conhecidas)
17. [Licença](#17-licença)
18. [Referências](#18-referências)

---

## 1. Arquitetura e componentes

O OCS Inventory 3.0 é uma reescrita completa da stack. Os componentes são independentes e podem ser distribuídos livremente entre servidores.

| Componente | Tecnologia | Função | Porta padrão |
|---|---|---|---|
| **Backend** | Django 6 + DRF + uWSGI | API REST, autenticação, regras de negócio | `8000` |
| **Frontend** | Vue 3 + Vite + Nginx | Console web do administrador | `8080` |
| **Relay** | Nginx (proxy) → uWSGI | Entrada para agentes legados na porta 80 | `80` → `8000` |
| **Automação** | `manage.py automation` (systemd timer) | IPDiscover, regras agendadas | — |
| **SNMP Scanner** | Python (systemd timer) | Descoberta SNMP na rede | — |
| **Agente** | Dart (binário compilado) | Coleta de inventário nos endpoints | — |
| **Banco** | PostgreSQL 14+ ou MariaDB 10.6+ / MySQL 8.0+ | Persistência | `5432` / `3306` |

### Conectividade entre componentes

```
Endpoints / Agentes
        │
        │ :80 (relay) ou :8000 (backend direto)
        ▼
┌───────────────┐     :5432 ou :3306     ┌──────────────┐
│   Backend /   │ ──────────────────────► │    Banco     │
│    Relay      │                         │  de Dados    │
└───────────────┘                         └──────────────┘
        ▲
        │ :8000
┌───────┴───────┐
│   Frontend    │ ◄── Navegador do administrador (:8080)
└───────────────┘

┌───────────────┐     :8000              
│ SNMP Scanner  │ ──────────────────────► Backend
└───────────────┘
```

---

## 2. Papéis de instalação do servidor

O script apresenta um menu interativo ao ser executado sem `--role`:

```
========================================================
  OCS Inventory 3.0 -- Qual o papel deste servidor?
========================================================

  INSTALACAO EM CAMADAS (recomendado para producao):
  [1] Banco de dados      -- MySQL/MariaDB ou PostgreSQL
  [2] Backend (API)       -- Django REST API + uWSGI
  [3] Frontend (console)  -- Vue.js + Nginx
  [4] SNMP Discovery      -- Scanner de rede SNMP

  COMBINACOES CONVENIENTES:
  [5] Aplicacao completa  -- Backend + Frontend no mesmo servidor
  [6] Tudo em um          -- Banco + Backend + Frontend (laboratorio/teste)

  REDES REMOTAS / SITES DISTRIBUIDOS:
  [8] Relay de agentes    -- Backend + Nginx escutando na porta 80
                             (agentes remotos ja configurados para :80;
                              Nginx repassa :80 -> uWSGI :8000 internamente)

  AVANCADO:
  [7] Preparar banco em OUTRO servidor via SSH (exige SSH entre hosts)
```

| `--role` | Opção | Instala | Banco |
|---|---|---|---|
| `db` | [1] | Banco de dados | Local |
| `backend` | [2] | Django + uWSGI + Nginx (:8000) | Remoto |
| `frontend` | [3] | Node.js + Nginx (:8080) | — |
| `snmp` | [4] | Python + SNMP Scanner | — |
| `app` | [5] | Backend + Frontend | Remoto |
| `standalone` | [6] | Tudo em um | Local |
| `db-remote` | [7] | (executa `--role db` remotamente via SSH) | — |
| `relay` | [8] | Django + uWSGI + Nginx (:80 → :8000) | Remoto |

> **Agente OCS:** em qualquer papel multi-layer, o script oferece instalar o agente no próprio servidor (padrão "sim") para que ele também apareça no inventário. No papel `standalone`, o agente é instalado automaticamente. No papel `db`, o padrão é não instalar.

---

## 3. Scripts disponíveis

| Arquivo | Finalidade |
|---|---|
| `install-ocsinventory-3.0.sh` | Instalação e configuração dos **servidores** (backend, frontend, banco, relay, etc.) |
| `install-ocsinventory-agent.sh` | Instalação / atualização do **agente** em endpoints Linux / Unix |
| `install-ocsinventory-agent.bat` | Instalação / atualização do **agente** em endpoints Windows |

---

## 4. Pré-requisitos

### Sistemas operacionais suportados — servidor

| Família | Distros testadas |
|---|---|
| **Debian** | Ubuntu 22.04, Ubuntu 24.04, Debian 12, Debian 13 |
| **RHEL** | AlmaLinux 8.x / 9.x, Rocky Linux 8/9, RHEL 8/9/10, Fedora |

### Sistemas operacionais suportados — agente

| Família | Exemplos |
|---|---|
| Debian | Ubuntu, Mint, Kali, Raspbian, Pop!_OS |
| RHEL | AlmaLinux, Rocky, Fedora, CentOS, Amazon Linux |
| SUSE | openSUSE, SLES |
| Arch | Arch Linux, Manjaro, EndeavourOS |
| Alpine | Alpine Linux |
| Slackware | Slackware |
| Windows | Windows 7 SP1+ / Server 2008 R2+ |

### Versões mínimas do banco (Django 6.0)

| Motor | Mínimo | Recomendado |
|---|---|---|
| PostgreSQL | 14 | 15 LTS |
| MariaDB | **10.6** | 10.11 LTS |
| MySQL | 8.0.11 | 8.0+ |

### Conectividade necessária entre servidores

| De | Para | Porta | Obrigatório |
|---|---|---|---|
| `backend` / `relay` | `db` | 5432 ou 3306 | ✅ |
| `frontend` | `backend` / `relay` | 8000 | ✅ |
| `snmp` | `backend` | 8000 | ✅ |
| Agentes | `backend` | 8000 | ✅ |
| Agentes legados | `relay` | 80 | ✅ |
| Navegador | `frontend` | 8080 | ✅ |

> ⚠️ **Microsegmentação (Guardicore, NSX, ACL de rede):** o ping pode funcionar mas o TCP ser bloqueado na camada de rede. O script testa a conectividade TCP **antes** de instalar qualquer coisa e avisa o que está bloqueado.

---

## 5. Instalação do servidor — tipos e exemplos

### 5.1 Tudo em um — laboratório

Banco, backend, frontend, SNMP Scanner e agente em um único servidor.

```
┌──────────────────────────────────────┐
│            Servidor único            │
│                                      │
│  PostgreSQL  ◄──  Django/uWSGI :8000 │
│                        │             │
│               Vue/Nginx :8080        │
│               SNMP Scanner           │
│               Agente OCS             │
└──────────────────────────────────────┘
         ▲
         │ :8080 (console)
    Administrador
```

```bash
# PostgreSQL (padrão)
sudo ./install-ocsinventory-3.0.sh --role standalone -y

# Com MySQL/MariaDB
sudo ./install-ocsinventory-3.0.sh --role standalone --db-engine mysql -y

# Com senha do admin definida
sudo ./install-ocsinventory-3.0.sh --role standalone --admin-password 'MinhaSenh@' -y
```

---

### 5.2 Duas camadas — App + Banco

Backend e frontend em um servidor, banco em outro.

```
┌──────────────────┐              ┌──────────────────────────────┐
│  Servidor Banco  │              │      Servidor Aplicação      │
│                  │              │                              │
│  PostgreSQL      │◄──:5432─────►│  Django/uWSGI :8000          │
│  ou MariaDB      │              │  Vue/Nginx    :8080          │
│                  │              │  SNMP Scanner                │
│                  │              │  Agente OCS                  │
└──────────────────┘              └──────────────────────────────┘
                                           ▲
                                    :8080  │  :8000
                                  Console  │  Agentes
```

> **Ambientes com CyberArk / bastion:** execute `--role db` diretamente no servidor de banco via sessão vaultada. O papel `db` roda 100% local, sem conexão de rede com o servidor de aplicação.

**Passo 1 — no servidor de banco:**
```bash
sudo ./install-ocsinventory-3.0.sh \
  --role db \
  --db-engine postgresql \
  --app-host IP_SERVIDOR_APP
```

Saída ao final:
```
===================================================================
 OCS Inventory 3.0 -- banco de dados preparado (papel 'db', postgresql)
===================================================================
Host deste servidor de banco ..: IP_BANCO
Banco de dados .................: ocsdb
Usuario da aplicacao ...........: ocsuser
Senha do usuario ................: <gerada-aleatoriamente>

Use estes dados ao rodar o script com --role app no servidor de aplicacao:
  --db-host IP_BANCO --db-name ocsdb --db-user ocsuser --db-password '<senha>'
===================================================================
```

**Passo 2 — no servidor de aplicação:**
```bash
sudo ./install-ocsinventory-3.0.sh \
  --role app \
  --db-engine postgresql \
  --db-host IP_BANCO \
  --db-name ocsdb \
  --db-user ocsuser \
  --db-password 'SENHA_DO_PASSO_1'
```

---

### 5.3 Três camadas — Banco + Backend + Frontend

```
┌────────────┐    :5432    ┌────────────┐    :8000    ┌────────────┐
│  Servidor  │◄───────────►│  Servidor  │◄───────────►│  Servidor  │
│     A      │             │     B      │             │     C      │
│   Banco    │             │  Backend   │             │  Frontend  │
│ PostgreSQL │             │  Django    │             │  Vue/Nginx │
│ ou MariaDB │             │  uWSGI     │             │   :8080    │
└────────────┘             └────────────┘             └────────────┘
                                ▲
                           :8000│
                           Agentes / SNMP
```

**Servidor A — Banco:**
```bash
sudo ./install-ocsinventory-3.0.sh \
  --role db \
  --db-engine postgresql \
  --app-host IP_SERVIDOR_B
```

**Servidor B — Backend:**
```bash
sudo ./install-ocsinventory-3.0.sh \
  --role backend \
  --db-engine postgresql \
  --db-host IP_SERVIDOR_A \
  --db-name ocsdb \
  --db-user ocsuser \
  --db-password 'SENHA'
```

**Servidor C — Frontend:**
```bash
sudo ./install-ocsinventory-3.0.sh \
  --role frontend \
  --backend-host IP_SERVIDOR_B
```

---

### 5.4 Quatro camadas — Banco + Backend + Frontend + SNMP

```
┌────────────┐    :5432    ┌────────────┐    :8000    ┌────────────┐
│  Servidor  │◄───────────►│  Servidor  │◄───────────►│  Servidor  │
│     A      │             │     B      │             │     C      │
│   Banco    │             │  Backend   │             │  Frontend  │
└────────────┘             └────────────┘             └────────────┘
                                ▲
                           :8000│
                          ┌─────┴──────┐
                          │  Servidor  │
                          │     D      │
                          │    SNMP    │
                          │  Scanner   │
                          └────────────┘
```

**Servidor A — Banco:**
```bash
sudo ./install-ocsinventory-3.0.sh \
  --role db \
  --db-engine postgresql \
  --app-host IP_SERVIDOR_B
```

**Servidor B — Backend:**
```bash
sudo ./install-ocsinventory-3.0.sh \
  --role backend \
  --db-engine postgresql \
  --db-host IP_SERVIDOR_A \
  --db-name ocsdb \
  --db-user ocsuser \
  --db-password 'SENHA'
```

**Servidor C — Frontend:**
```bash
sudo ./install-ocsinventory-3.0.sh \
  --role frontend \
  --backend-host IP_SERVIDOR_B
```

**Servidor D — SNMP Scanner:**
```bash
sudo ./install-ocsinventory-3.0.sh \
  --role snmp \
  --backend-host IP_SERVIDOR_B
```

> O agente OCS é instalado em todos os servidores por padrão (padrão "sim" ao perguntar em cada papel), permitindo que o console mostre o inventário de cada camada.

---

### 5.5 Relay de agentes — site remoto com porta 80

Para **sites remotos** onde os agentes já estão instalados e configurados para reportar na porta **80**. O Nginx escuta na porta 80, recebe os envios dos agentes e repassa internamente para o uWSGI na porta 8000. O banco de dados fica no core central.

```
SITE REMOTO                            CORE CENTRAL
                                        
┌──────────┐                           ┌──────────────────────────────┐
│ Endpoint │──►┐                       │                              │
└──────────┘   │                       │  ┌──────────┐  ┌──────────┐ │
               │  ┌─────────────────┐  │  │ Frontend │  │  Banco   │ │
┌──────────┐   └─►│  Servidor Relay │──┼─►│  :8080   │  │ :5432    │ │
│ Endpoint │──►   │                 │  │  └──────────┘  └──────────┘ │
└──────────┘      │  Nginx   :80    │  │        ▲             ▲       │
               ┌─►│  uWSGI   :8000  │  │        │             │       │
┌──────────┐   │  │  (interno)      │  │  ┌─────┴─────────────┴────┐ │
│ Endpoint │──►┘  └────────┬────────┘  │  │    Backend :8000       │ │
└──────────┘               │           │  └────────────────────────┘ │
                           │ :5432     │                              │
                           └───────────┼─► Banco Central             │
                                       └──────────────────────────────┘
```

**Fluxo dos dados:**
```
Agente → :80 → Nginx relay → socket uWSGI → Django → Banco central
```

**Instalação no servidor relay (site remoto):**
```bash
# Porta 80 (padrão para agentes legados)
sudo ./install-ocsinventory-3.0.sh \
  --role relay \
  --db-engine postgresql \
  --db-host IP_BANCO_CORE \
  --db-name ocsdb \
  --db-user ocsuser \
  --db-password 'SENHA'

# Porta personalizada (ex.: agentes apontam para :8080)
sudo ./install-ocsinventory-3.0.sh \
  --role relay \
  --relay-port 8080 \
  --db-engine postgresql \
  --db-host IP_BANCO_CORE \
  --db-name ocsdb \
  --db-user ocsuser \
  --db-password 'SENHA'
```

**Agentes do site remoto** — instalar apontando para o relay local:
```bash
# Linux
sudo ./install-ocsinventory-agent.sh --url http://IP_RELAY

# Windows
install-ocsinventory-agent.bat http://IP_RELAY
```

**Conectividade necessária:**

| De | Para | Porta | Obrigatório |
|---|---|---|---|
| Endpoints remotos | Servidor relay | `80/TCP` (ou `--relay-port`) | ✅ |
| Servidor relay | Banco central | `5432/TCP` | ✅ |
| Servidor relay | Frontend / Backend core | Nenhuma | ❌ |

---

### 5.6 Multi-site com relays distribuídos

Múltiplos sites remotos, cada um com seu relay, todos gravando no mesmo banco central.

```
SITE REMOTO A                 SITE REMOTO B                 CORE CENTRAL
                                                              
┌──────────┐                  ┌──────────┐                 ┌───────────────────────┐
│ Endpoint │──►┐              │ Endpoint │──►┐             │                       │
└──────────┘   │ ┌─────────┐  └──────────┘   │ ┌─────────┐│ ┌────────┐ ┌────────┐│
               └►│ Relay A │──:5432──────────┼►│ Relay B ││ │Frontend│ │  Banco ││
┌──────────┐   ┌►│  :80    │  ┌──────────┐  └►│  :80    │└►│ :8080  │ │ :5432  ││
│ Endpoint │──►┘ └─────────┘  │ Endpoint │──►┘ └─────────┘│ └────────┘ └────────┘│
└──────────┘                  └──────────┘                 │        ▲       ▲     │
                                                           │ ┌──────┴───────┴────┐│
                                                           │ │  Backend  :8000   ││
                                                           │ └───────────────────┘│
                                                           └───────────────────────┘
```

Cada site remoto instala um relay apontando para o **mesmo banco central**:

```bash
# Site A
sudo ./install-ocsinventory-3.0.sh \
  --role relay \
  --db-host IP_BANCO_CORE \
  --db-name ocsdb --db-user ocsuser --db-password 'SENHA'

# Site B (mesmo comando, rodado no servidor do site B)
sudo ./install-ocsinventory-3.0.sh \
  --role relay \
  --db-host IP_BANCO_CORE \
  --db-name ocsdb --db-user ocsuser --db-password 'SENHA'
```

O console web no core exibe o inventário de **todos os sites** em um lugar só, pois todos compartilham o mesmo banco.

---

### 5.7 Banco em outro servidor via SSH

Prepara o banco em outro servidor remotamente, sem precisar logar nele manualmente. Requer SSH liberado entre os hosts.

> ⚠️ **Não use em ambientes com CyberArk ou bloqueio de movimento lateral.** Nesses casos, use `--role db` diretamente no servidor de banco (seção 5.2).

```bash
sudo ./install-ocsinventory-3.0.sh \
  --role db-remote \
  --remote-db-host IP_SERVIDOR_BANCO \
  --remote-db-ssh-user root \
  --app-host IP_SERVIDOR_APP
```

O script copia a si mesmo para o servidor remoto via `scp` e executa `--role db` com um pseudo-terminal alocado. As perguntas interativas aparecem no seu terminal local. As credenciais são salvas em `/root/ocsinventory-credentials-<host>.txt`.

---

## 6. Instalação do agente nos endpoints

### 6.1 Linux / Unix

```bash
chmod +x install-ocsinventory-agent.sh

# Interativo (só pergunta a URL do backend/relay)
sudo ./install-ocsinventory-agent.sh

# Silencioso — backend na porta padrão
sudo ./install-ocsinventory-agent.sh --url http://IP_BACKEND:8000

# Silencioso — agentes apontando para relay na porta 80
sudo ./install-ocsinventory-agent.sh --url http://IP_RELAY

# Forçar reinstalação mesmo se a versão já for igual
sudo ./install-ocsinventory-agent.sh --url http://IP_BACKEND:8000 --force

# Instalar apenas o binário, sem serviço systemd
sudo ./install-ocsinventory-agent.sh --url http://IP_BACKEND:8000 --no-service
```

**Distros suportadas:**

| Família | Exemplos | Gerenciador |
|---|---|---|
| Debian | Ubuntu, Mint, Kali, Raspbian | `apt-get` |
| RHEL | AlmaLinux, Rocky, Fedora, CentOS | `dnf` / `yum` |
| SUSE | openSUSE, SLES | `zypper` |
| Arch | Arch Linux, Manjaro | `pacman` |
| Alpine | Alpine Linux | `apk` |
| Slackware | Slackware | `slackpkg` |

**Fluxo de instalação:**
```
1. Detectar família da distro
2. Instalar dependências base (git, curl, unzip)
3. Verificar versão instalada → remover versão anterior se necessário
4. Instalar Dart SDK
5. Perguntar URL do backend/relay (se não passada via --url)
6. Clonar repositório do agente (tag 3.0.0-rc1)
7. Compilar: dart compile exe lib/app/app.dart -o ocsinventory-cli
8. Instalar via setup/linux/install.sh
9. Registrar e iniciar serviço systemd / OpenRC
10. Verificar instalação
```

### 6.2 Windows

```bat
:: Interativo (só pergunta a URL)
install-ocsinventory-agent.bat

:: Silencioso — backend na porta padrão
install-ocsinventory-agent.bat http://IP_BACKEND:8000

:: Silencioso — agentes apontando para relay na porta 80
install-ocsinventory-agent.bat http://IP_RELAY

:: Forçar reinstalação
install-ocsinventory-agent.bat http://IP_BACKEND:8000 /force
```

> Deve ser executado como **Administrador** (botão direito → "Executar como administrador").

### 6.3 Credenciais do agente

Os scripts usam uma conta de serviço dedicada, sem expor a senha do administrador principal:

| Campo | Valor |
|---|---|
| Usuário | `ocsagentes` |
| Grupo Django | `admin` (permissão de envio de inventário) |

A senha está embutida nos scripts. Para alterar:

```sh
# Linux — editar no topo do arquivo
ADMIN_USER="ocsagentes"
ADMIN_PASS="sua-nova-senha"
```

```bat
:: Windows — editar no topo do arquivo
set "ADMIN_USER=ocsagentes"
set "ADMIN_PASS=sua-nova-senha"
```

### 6.4 Atualização automática

Ambos os scripts detectam a versão instalada e decidem automaticamente:

| Situação | Ação |
|---|---|
| Nenhuma versão instalada | Instalação limpa |
| Versão instalada **diferente** da desejada | Remove a anterior e instala a nova |
| Versão instalada **igual** à desejada | Pergunta se quer reinstalar (ou `--force` / `/force`) |

**O que é removido na desinstalação da versão anterior:**
- Serviço do sistema (`systemctl stop` + `sc delete` no Windows)
- Binários em todos os caminhos conhecidos
- Arquivos de configuração
- Código-fonte compilado (reclonado na próxima execução)
- Entradas de registro (Windows) e entradas do PATH

---

## 7. Referência de flags — servidor

### Gerais

| Flag | Padrão | Descrição |
|---|---|---|
| `--role PAPEL` | menu interativo | Papel: `db`, `backend`, `frontend`, `snmp`, `app`, `standalone`, `relay`, `db-remote` |
| `--host IP` | selecionado interativamente | IP deste servidor para comunicação com os outros componentes |
| `--backend-port PORTA` | `8000` | Porta interna do backend/uWSGI |
| `--frontend-port PORTA` | `8080` | Porta do console web |
| `--relay-port PORTA` | `80` | Porta pública do relay para os agentes (papel `relay`) |
| `--base-dir CAMINHO` | `/opt/ocsinventory` | Diretório raiz da instalação |
| `--ocs-tag TAG` | `3.0.0-rc1` | Tag git a instalar |
| `--os-upgrade` | pergunta | Atualiza o S.O. sem perguntar |
| `--no-os-upgrade` | pergunta | NÃO atualiza o S.O. sem perguntar |
| `--skip-snmp` | pergunta | Não instala o SNMP Scanner |
| `--skip-agent` | pergunta | Não instala o agente neste servidor |
| `-y`, `--yes` | — | Modo não-interativo (usa padrões/flags) |
| `-h`, `--help` | — | Mostra a ajuda |

### Banco de dados

| Flag | Padrão | Papéis | Descrição |
|---|---|---|---|
| `--db-engine mysql\|postgresql` | `mysql` (backend/app/relay) | todos exceto frontend/snmp | Motor do banco |
| `--db-host HOST` | perguntado | backend, app, relay | Host do banco remoto |
| `--db-port PORTA` | 5432/3306 | backend, app, relay | Porta do banco remoto |
| `--db-name NOME` | `ocsdb` | todos | Nome do banco |
| `--db-user USUARIO` | `ocsuser` | todos | Usuário do banco |
| `--db-password SENHA` | gerada ou perguntada | todos | Senha do usuário |
| `--app-host HOST` | perguntado | db | IP do servidor de app a liberar no banco |

### Multi-layer / relay

| Flag | Padrão | Papéis | Descrição |
|---|---|---|---|
| `--backend-host HOST` | perguntado | frontend, snmp | Host do servidor de backend |
| `--relay-port PORTA` | `80` | relay | Porta pública para os agentes |

### Administrador do console

| Flag | Padrão | Descrição |
|---|---|---|
| `--admin-user USUARIO` | `admin` | Usuário administrador do console |
| `--admin-email EMAIL` | `admin@localhost` | E-mail do administrador |
| `--admin-password SENHA` | gerada aleatoriamente | Senha do administrador |
| `--snmp-subnet CIDR` | auto-detectada | Subnet varrida pelo SNMP Scanner |

### db-remote (SSH)

| Flag | Padrão | Descrição |
|---|---|---|
| `--remote-db-host HOST` | perguntado | Host do servidor de banco remoto |
| `--remote-db-ssh-user USER` | `root` | Usuário SSH |
| `--remote-db-ssh-port PORTA` | `22` | Porta SSH |
| `--remote-db-ssh-key CAMINHO` | agente/senha interativa | Chave privada SSH |

---

## 8. Referência de flags — agente Linux

| Flag | Padrão | Descrição |
|---|---|---|
| `--url URL` | perguntado | URL completa do backend ou relay (`http://HOST:PORTA`) |
| `--tag TAG` | `3.0.0-rc1` | Tag git do agente |
| `--base DIR` | `/opt/ocsinventory` | Diretório base de instalação |
| `--no-service` | — | Instalar só o binário, sem serviço systemd/OpenRC |
| `--force` | — | Reinstalar mesmo se a versão já for a desejada |

---

## 9. Seleção de IP com múltiplas interfaces

Quando o servidor tem mais de uma interface de rede, o script lista todas e pergunta qual usar:

```
Este servidor tem 3 interfaces de rede. Qual IP os outros
componentes devem usar para se conectar a ESTE servidor?
  [1] IP_INTERFACE_1      (ens160)
  [2] IP_INTERFACE_2      (ens192)
  [3] IP_INTERFACE_3      (ens224)
Escolha [1-3]:
```

O IP selecionado é usado nas URLs do console, nas regras do banco (`pg_hba.conf`, GRANT MySQL) e nas configurações do agente. Para pular a pergunta: `--host IP_DESEJADO`.

> **Microsegmentação (Guardicore, NSX):** escolha a interface pela qual os outros servidores **realmente** conseguem alcançar este servidor. O script testa a conectividade TCP antes de instalar e informa exatamente qual porta/interface está bloqueada.

---

## 10. Banco de dados — detalhes

### Detecção automática do motor

Ao rodar `--role db` sem `--db-engine`, o script detecta o que já está instalado:

- **Só MariaDB/MySQL** → usa automaticamente
- **Só PostgreSQL** → usa automaticamente
- **Ambos** → mostra menu para escolher
- **Nenhum** → mostra menu de instalação:
  ```
  [1] MySQL/MariaDB -- MariaDB 10.11 LTS
  [2] PostgreSQL    -- PostgreSQL 15
  ```

### RHEL 8 — módulos DNF

Os módulos padrão do RHEL 8 trazem versões antigas (MariaDB 10.3, PostgreSQL 10). O script habilita automaticamente os módulos corretos:
- `dnf module enable mariadb:10.11`
- `dnf module enable postgresql:15`

### Regras `pg_hba.conf`

O script sempre grava regras com **IP + máscara `/32`** em vez de hostname, evitando falha silenciosa quando o servidor de banco não resolve o hostname do servidor de app via DNS:

```
# Nunca usado pelo script (pode falhar se DNS não resolver):
host  ocsdb  ocsuser  nome-do-servidor  md5

# Sempre usado pelo script (funciona independente de DNS):
host  ocsdb  ocsuser  IP_DO_SERVIDOR/32  md5
```

### Mover o datadir após instalação

O script instala sempre no datadir padrão e você move depois com janela de manutenção:

**PostgreSQL:**
```bash
systemctl stop postgresql
rsync -av /var/lib/pgsql/data/ /novo-datadir/
chown -R postgres:postgres /novo-datadir
semanage fcontext -a -t postgresql_db_t "/novo-datadir(/.*)?"
restorecon -Rv /novo-datadir
mkdir -p /etc/systemd/system/postgresql.service.d/
echo -e "[Service]\nEnvironment=PGDATA=/novo-datadir" \
  > /etc/systemd/system/postgresql.service.d/pgdata.conf
systemctl daemon-reload && systemctl start postgresql
```

**MariaDB:**
```bash
systemctl stop mariadb
rsync -av /var/lib/mysql/ /novo-datadir/
chown -R mysql:mysql /novo-datadir
semanage fcontext -a -t mysqld_db_t "/novo-datadir(/.*)?"
restorecon -Rv /novo-datadir
echo -e "[mysqld]\ndatadir=/novo-datadir" > /etc/my.cnf.d/datadir.cnf
systemctl start mariadb
```

---

## 11. Particularidades por distro

| Situação | O que o script faz |
|---|---|
| RHEL 8 — MariaDB 10.3 por padrão | Habilita `mariadb:10.11` via `dnf module` |
| RHEL 8 — PostgreSQL 10 por padrão | Habilita `postgresql:15` via `dnf module` |
| RHEL — PostgreSQL nunca inicializado | `postgresql-setup --initdb` automático; move dir "sujo" para backup |
| RHEL — locale inválido | Instala `glibc-langpack-en`, passa `--locale=en_US.UTF-8` ao `initdb` |
| RHEL — banco RPM corrompido (BDB0091) | Remove `/var/lib/rpm/__db*`, `rpm --rebuilddb`, tenta novamente |
| RHEL — processo `rpm` travado (100% CPU) | Detecta e mata com `SIGKILL` antes de qualquer `pkg_install` |
| RHEL — pg_hba.conf com PGDATA antigo | Remove `/etc/sysconfig/pgsql/postgresql` e drop-ins systemd |
| RHEL — SELinux | `semanage port` para 8000/8080/80; `restorecon` nos diretórios |
| RHEL — Nginx porta 80 conflita com default | Remove automaticamente o server block padrão antes de configurar o relay |
| Debian 13 — `software-properties-common` removido | Script nunca o instala incondicionalmente |
| Debian — sudo ausente | Instalado automaticamente |
| Git — dubious ownership | Todos os `git` rodam como usuário `ocs` (dono do diretório) |
| Nginx — site default conflitante | Detecta e desabilita antes de configurar os vhosts do OCS |
| Proxy Squid no ambiente | Todos os curls locais usam `--noproxy '*'` para evitar interceptação |
| uWSGI — socket some após restart | Unit systemd usa `RuntimeDirectory` + `KillSignal=SIGQUIT` para garantir recriação correta |

---

## 12. Problemas conhecidos e soluções

### Porta bloqueada (Guardicore / NSX / ACL)

**Sintoma:** ping funciona mas conexão TCP trava ou retorna "Connection refused" / "No route to host".

**Diagnóstico:**
```bash
# Testar porta específica
timeout 3 bash -c "echo > /dev/tcp/IP_DESTINO/PORTA" && echo "ABERTA" || echo "BLOQUEADA"

# Testar várias portas de uma vez
for porta in 22 80 3306 5432 8000 8080; do
  timeout 2 bash -c "echo > /dev/tcp/IP_DESTINO/$porta" 2>/dev/null \
    && echo "PORTA $porta: ABERTA" || echo "PORTA $porta: BLOQUEADA"
done
```

**Solução:** abrir regra no Guardicore/NSX com origem, destino, porta e protocolo TCP.

### PostgreSQL — `pg_hba.conf entry not found`

```bash
# Ver regras carregadas
sudo -u postgres psql -c "SELECT * FROM pg_hba_file_rules WHERE database = '{ocsdb}';"

# Corrigir hostname para IP
sed -i 's/nome-servidor/IP_SERVIDOR\/32/' /var/lib/pgsql/data/pg_hba.conf

# Corrigir IP sem máscara
sed -i 's|IP_SERVIDOR    md5|IP_SERVIDOR/32    md5|' /var/lib/pgsql/data/pg_hba.conf

# Recarregar
sudo -u postgres psql -c "SELECT pg_reload_conf();"
```

### PostgreSQL — não inicia após editar pg_hba.conf

**Sintoma:** `journalctl -u postgresql` mostra `invalid IP mask`.

**Causa:** IP sem máscara `/32` no `pg_hba.conf`.

```bash
grep -n "ocsuser" /var/lib/pgsql/data/pg_hba.conf
sed -i 's|IP_SERVIDOR    md5|IP_SERVIDOR/32    md5|' /var/lib/pgsql/data/pg_hba.conf
systemctl start postgresql
```

### Banco RPM corrompido — BDB0091

```bash
rm -f /var/lib/rpm/__db*
rpm --rebuilddb
```

### Processo `rpm` travado (100% CPU, bloqueia systemctl)

```bash
# Identificar
ps aux | grep rpm

# Matar
kill -9 PID_DO_RPM

# Limpar e reconstruir
rm -f /var/lib/rpm/__db*
rpm --rebuilddb &
```

### Locale inválido — initdb falha

```bash
dnf install -y glibc-langpack-en
```

### uWSGI — socket não criado / backend retorna 502

```bash
# Ver se o socket existe
ls -la /run/ocsinventory-backend/

# Subir manualmente para ver o erro
sudo -u ocs /opt/ocsinventory/backend/venv/bin/uwsgi \
  --ini /opt/ocsinventory/backend/uwsgi.ini \
  --daemonize /var/log/ocsinventory-backend/ocsinventory-backend.log
sleep 3
curl --noproxy '*' http://127.0.0.1:8000/api-check/
```

### Proxy Squid interceptando curls locais

```bash
# Sempre usar --noproxy para testes locais
curl --noproxy '*' http://127.0.0.1:8000/api-check/
curl --noproxy '*' http://127.0.0.1:8080/
```

### Agente não aparece no console

```bash
# Verificar serviço
systemctl status ocsinventory-agent

# Verificar conectividade com o backend
timeout 3 bash -c "echo > /dev/tcp/IP_BACKEND/8000" && echo OK

# Forçar envio imediato
ocsinventory-cli --now

# Ver log do agente
journalctl -u ocsinventory-agent -n 50
```

---

## 13. Validação pós-instalação

```bash
# Backend respondendo (sem proxy)
curl --noproxy '*' -s http://127.0.0.1:8000/api-check/
# Esperado: {"message":"API is online!"}

# Relay respondendo (porta 80)
curl --noproxy '*' -s http://127.0.0.1:80/api-check/
# Esperado: {"message":"API is online!"}

# Frontend respondendo
curl --noproxy '*' -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8080/
# Esperado: 200

# Serviços ativos
systemctl status ocsinventory-backend
systemctl status nginx
systemctl list-timers | grep ocsinventory
```

**No navegador:**
1. Acesse `http://IP_FRONTEND:8080`
2. Login com usuário/senha do resumo final ou `/root/ocsinventory-credentials.txt`
3. O servidor de instalação deve aparecer no inventário após o primeiro ciclo do agente
4. Para SNMP: Configuração → SNMP → adicionar comunidade → aguardar próximo ciclo do timer (30 min)

---

## 14. Logs e credenciais

| O quê | Onde |
|---|---|
| Log da instalação do servidor | `/var/log/ocsinventory-install.log` |
| Backend (uWSGI) | `/var/log/ocsinventory-backend/ocsinventory-backend.log` |
| Relay (Nginx access/error) | `/var/log/ocsinventory-backend/relay-access.log` e `relay-error.log` |
| Frontend (Nginx) | `/var/log/ocsinventory-frontend/` |
| Agente | `/var/log/ocsinventory-agent/` (ou `journalctl -u ocsinventory-agent`) |
| Credenciais do servidor (banco + console) | `/root/ocsinventory-credentials.txt` (modo `600`) |
| Credenciais do banco remoto (db-remote) | `/root/ocsinventory-credentials-<host>.txt` (modo `600`) |

> A senha de root do banco **nunca é salva** em nenhum arquivo.

---

## 15. Idempotência

O script pode ser re-executado sem risco: usuário de sistema, banco, clone git, virtualenv Python e configurações são verificados antes de serem recriados. Útil para corrigir uma execução que falhou no meio ou para atualizar a instalação depois.

---

## 16. Limitações conhecidas

- `3.0.0-rc1` é release candidate; o projeto pede feedback nessa fase.
- Não existe repositório apt/yum público para o OCS 3.0 — a instalação é sempre a partir do código-fonte.
- Motor de plugins completo, CVE e Green IT estão previstos para versões 3.1/3.2.
- Testado de ponta a ponta em AlmaLinux 8.10, Ubuntu 24.04 e Debian 13; outras distros das mesmas famílias devem funcionar mas não foram validadas com a mesma profundidade.
- Em arquitetura multi-layer sem SSH liberado entre servidores, o resultado do `--role db` é copiado manualmente para o próximo passo. O papel `db-remote` cobre esse gap quando SSH está disponível.
- O papel `db-remote` precisa do script em arquivo local — não funciona via `curl | bash`.
- O papel `relay` remove o server block padrão do Nginx na porta 80. Em servidores que hospedam outros sites no Nginx, revise o `/etc/nginx/nginx.conf` e os vhosts antes de usar.

---

## 17. Licença

Distribuído sob a licença **MIT**. Pode ser usado, modificado e redistribuído livremente — para uso pessoal, comercial ou em qualquer projeto — desde que o aviso de copyright seja mantido. Sem garantia de funcionamento; use por sua conta e risco em produção.

Texto completo: [`LICENSE`](./LICENSE)

---

## 18. Referências

- Backend: `github.com/OCSInventory-NG/OCSInventory-Server-Backend-Rework` (tag `3.0.0-rc1`)
- Frontend: `github.com/OCSInventory-NG/OCSInventory-Server-Frontend-Rework` (tag `3.0.0-rc1`)
- Agente: `github.com/OCSInventory-NG/OCSInventory-Agent-Rework` (tag `3.0.0-rc1`)
- SNMP Scanner: `github.com/OCSInventory-NG/OCSInventory-SNMP-Scanner` (tag `3.0.0-rc1`)
- Pacotes oficiais: `github.com/OCSInventory-NG/OCSInventory-Server-Packages`
