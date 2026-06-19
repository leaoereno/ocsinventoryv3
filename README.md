# OCS Inventory 3.0 — Instalador Multi-Layer

Script de instalação do **OCS Inventory 3.0** (tag `3.0.0-rc1`), com suporte a arquitetura multi-layer completa: cada componente pode ser instalado em um servidor dedicado, combinado conforme a necessidade, ou tudo em um único servidor para laboratório.

**Lições aprendidas em produção** integradas ao script: seleção interativa de IP quando o servidor tem múltiplas interfaces de rede, teste de conectividade TCP antes de instalar qualquer coisa, detecção e auto-correção de corrupção do banco RPM, tratamento de bloqueio de microsegmentação (Guardicore, NSX), correção automática de locale inválido para o `initdb` do PostgreSQL, e regras do `pg_hba.conf` sempre gravadas com IP + máscara (`/32`) em vez de hostname — evitando falhas silenciosas de resolução DNS entre servidores.

---

## Índice

1. [Arquitetura do OCS Inventory 3.0](#1-arquitetura-do-ocs-inventory-30)
2. [Papéis disponíveis](#2-papéis-disponíveis)
3. [Seleção de IP (múltiplas interfaces)](#3-seleção-de-ip-múltiplas-interfaces)
4. [Pré-requisitos](#4-pré-requisitos)
5. [Tipos de instalação — passo a passo](#5-tipos-de-instalação--passo-a-passo)
   - 5.1 [Tudo em um (laboratório)](#51-tudo-em-um-laboratório)
   - 5.2 [Duas camadas: App + Banco](#52-duas-camadas-app--banco)
   - 5.3 [Quatro camadas: Banco + Backend + Frontend + SNMP](#53-quatro-camadas-banco--backend--frontend--snmp)
   - 5.4 [Banco em outro servidor via SSH](#54-banco-em-outro-servidor-via-ssh)
6. [Referência de flags](#6-referência-de-flags)
7. [O que o script instala por papel](#7-o-que-o-script-instala-por-papel)
8. [Ordem das etapas](#8-ordem-das-etapas)
9. [Banco de dados — detalhes](#9-banco-de-dados--detalhes)
10. [Particularidades por distro](#10-particularidades-por-distro)
11. [Problemas conhecidos e soluções](#11-problemas-conhecidos-e-soluções)
12. [Validação pós-instalação](#12-validação-pós-instalação)
13. [Logs e credenciais](#13-logs-e-credenciais)
14. [Idempotência](#14-idempotência)
15. [Limitações conhecidas](#15-limitações-conhecidas)
16. [Licença](#16-licença)
17. [Referências](#17-referências)

---

## 1. Arquitetura do OCS Inventory 3.0

A versão 3.0 é uma reescrita completa. Em vez do antigo servidor Perl + console PHP, a stack agora é:

| Componente | Tecnologia | Papel | Porta padrão |
|---|---|---|---|
| **Backend** | Django 6 + DRF + uWSGI | API REST, autenticação, regras de negócio | `8000` |
| **Frontend** | Vue 3 + Vite + Nginx | Console web do administrador | `8080` |
| **Automação / IPDiscover** | `manage.py automation` (systemd timer) | Regras agendadas, IPDiscover server-side | — |
| **SNMP Scanner** | Python standalone (systemd timer) | Descoberta de dispositivos via SNMP | — |
| **Agente** | Dart (binário único) | Coleta de inventário nos endpoints | — |
| **Banco de dados** | PostgreSQL 14+ ou MariaDB 10.6+ / MySQL 8.0+ | Persistência | `5432` / `3306` |

### Arquitetura máxima (4 camadas)

```
┌──────────────────────────────────────────────────────────────────┐
│                        Clientes / Agentes                        │
└────────────────────────────┬─────────────────────────────────────┘
                             │ HTTP :8080
              ┌──────────────▼──────────────┐
              │   Servidor C — Frontend     │
              │   Vue 3 + Nginx (:8080)     │
              └──────────────┬──────────────┘
                             │ HTTP :8000
              ┌──────────────▼──────────────┐       ┌─────────────────────┐
              │   Servidor B — Backend      │◄──────►│  Servidor D — SNMP  │
              │   Django + uWSGI (:8000)    │       │  Scanner Python     │
              └──────────────┬──────────────┘       └─────────────────────┘
                             │ TCP :5432 / :3306
              ┌──────────────▼──────────────┐
              │   Servidor A — Banco        │
              │   PostgreSQL / MariaDB      │
              └─────────────────────────────┘
```

---

## 2. Papéis disponíveis

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

  AVANCADO:
  [7] Preparar banco em OUTRO servidor via SSH (exige SSH entre hosts)
```

| `--role` | Menu | Instala | Banco |
|---|---|---|---|
| `db` | [1] | Banco de dados | Local |
| `backend` | [2] | Django + uWSGI + Nginx | Remoto |
| `frontend` | [3] | Node.js + Nginx | — |
| `snmp` | [4] | Python + SNMP Scanner | — |
| `app` | [5] | Backend + Frontend | Remoto |
| `standalone` | [6] | Tudo | Local |
| `db-remote` | [7] | (executa `--role db` em outro servidor via SSH) | — |

> **Agente OCS:** em arquitetura multi-layer, o agente é instalado em **todos** os servidores automaticamente (o script pergunta em cada papel, com padrão "sim" — exceto no servidor de banco onde o padrão é "não"). No modo `standalone`, o agente é sempre instalado.

---

## 3. Seleção de IP (múltiplas interfaces)

Quando o servidor tem mais de uma interface de rede (cenário comum em produção), o script lista todas e pergunta qual usar para comunicação com os outros componentes:

```
Este servidor tem 3 interfaces de rede. Qual IP os outros
componentes devem usar para se conectar a ESTE servidor?
  [1] 172.18.190.103      (ens160)
  [2] 10.24.22.90         (ens192)
  [3] 172.27.31.115       (ens224)
Escolha [1-3]:
```

O IP selecionado é usado nas URLs do console, nas regras do banco (`pg_hba.conf`, GRANT MySQL) e nas configurações do agente. Para pular a pergunta, passe `--host IP` na linha de comando.

> **Nota sobre microsegmentação (Guardicore, NSX, etc.):** se o servidor tiver múltiplas interfaces, escolha a interface pela qual os outros servidores **realmente conseguem alcançar** este servidor. Se a conectividade TCP estiver bloqueada em alguma interface, o script detecta e avisa antes de instalar qualquer coisa — poupando horas de diagnóstico.

---

## 4. Pré-requisitos

### Sistema operacional suportado

| Família | Distros testadas |
|---|---|
| **Debian** | Ubuntu 22.04, Ubuntu 24.04, Debian 12, Debian 13 |
| **RHEL** | AlmaLinux 8.x / 9.x, Rocky Linux 8/9, RHEL 8/9/10, Fedora |

### Por papel

| Papel | Requisitos mínimos |
|---|---|
| `db` | Acesso root local; banco já instalado ou permissão para instalar |
| `backend` | Acesso root local; conectividade TCP com o servidor de banco |
| `frontend` | Acesso root local; conectividade TCP com o servidor de backend (:8000) |
| `snmp` | Acesso root local; conectividade TCP com o servidor de backend (:8000) |
| `app` / `standalone` | Acesso root local; conectividade TCP com o banco (se remoto) |
| `db-remote` | SSH liberado entre este host e o servidor de banco |

### Banco de dados — versões mínimas exigidas pelo Django 6.0

| Motor | Versão mínima | Versão recomendada |
|---|---|---|
| PostgreSQL | 14 | 15 LTS |
| MariaDB | **10.6** | 10.11 LTS |
| MySQL | 8.0.11 | 8.0+ |

> ⚠️ O **MariaDB 10.3.x** que vem por padrão no AlmaLinux/RHEL 8 está **abaixo do mínimo** e fora de suporte oficial (EOL desde maio de 2023). O script detecta e avisa, dando a opção de abortar para atualizar o banco antes de prosseguir.

### Conectividade de rede necessária

| De | Para | Porta | Serviço |
|---|---|---|---|
| `backend` | `db` | 5432 ou 3306 | Banco de dados |
| `frontend` | `backend` | 8000 | API Django |
| `snmp` | `backend` | 8000 | API Django |
| Agentes | `backend` | 8000 | Envio de inventário |
| Navegador | `frontend` | 8080 | Console web |

> ⚠️ **Microsegmentação (Guardicore, NSX, ACL de rede):** essas ferramentas bloqueiam tráfego TCP por política de segmento — o SO do servidor pode ter a porta aberta no `firewalld`/`ufw` e o `ping` pode funcionar, mas o TCP ainda assim é bloqueado na camada de rede. O script testa a conectividade TCP antecipadamente e informa exatamente qual porta e host estão bloqueados.

---

## 5. Tipos de instalação — passo a passo

### 5.1 Tudo em um (laboratório)

Um único servidor, banco de dados local (PostgreSQL por padrão), sem perguntas.

```
┌─────────────────────────────┐
│     Servidor único          │
│  PostgreSQL + Backend       │
│  + Frontend + SNMP + Agente │
└─────────────────────────────┘
```

**Comando:**
```bash
sudo ./install-ocsinventory-3.0.sh --role standalone -y
```

**Com MySQL/MariaDB local:**
```bash
sudo ./install-ocsinventory-3.0.sh --role standalone --db-engine mysql -y
```

**O que acontece:**
1. Detecta o IP do servidor (seleciona automaticamente se só houver um)
2. Instala todas as dependências (Python 3.12, Node.js 20, Dart SDK, Nginx, banco)
3. Cria usuário de sistema `ocs`, banco `ocsdb`, usuário `ocsuser`
4. Instala e configura backend (Django + uWSGI), frontend (Vue + Nginx), SNMP Scanner e agente
5. Imprime URL do console, login e senha em `/root/ocsinventory-credentials.txt`

---

### 5.2 Duas camadas: App + Banco

```
┌─────────────────────┐        ┌─────────────────────────────┐
│   Servidor de Banco │        │   Servidor de Aplicação     │
│   MySQL/MariaDB ou  │◄──────►│   Backend + Frontend        │
│   PostgreSQL        │  TCP   │   + SNMP Scanner + Agente   │
└─────────────────────┘        └─────────────────────────────┘
  lnxdcocsdb01                   lnxdcocsapp01
```

> **Ambientes com CyberArk / bastion / bloqueio de movimento lateral:** execute o script com `--role db` **diretamente no servidor de banco** via sessão vaultada normal. O papel `db` roda 100% local, sem nenhuma conexão de rede com o servidor de aplicação.

**Passo 1 — no servidor de banco** (ex.: `lnxdcocsdb01`):
```bash
sudo ./install-ocsinventory-3.0.sh \
  --role db \
  --db-engine postgresql \
  --app-host 10.24.22.90
```

O script vai:
- Detectar ou instalar o PostgreSQL
- Perguntar nome/usuário/senha do banco (ou gerar senha aleatória)
- Criar o banco e o usuário
- Abrir a porta 5432 no firewall para o IP do servidor de aplicação
- Adicionar regra no `pg_hba.conf` com IP + `/32` (nunca hostname, para evitar falha de DNS)
- Imprimir um resumo com o comando exato para o próximo passo

Saída esperada ao final:
```
===================================================================
 OCS Inventory 3.0 -- banco de dados preparado (papel 'db', postgresql)
===================================================================
Host deste servidor de banco ..: 10.24.22.125
Banco de dados .................: ocsdb
Usuario da aplicacao ...........: ocsuser
Senha do usuario ................: x8KAj0uYy8DL2KRaXaSYCRUB
Liberado para o host ............: 10.24.22.90

Use estes dados ao rodar o script com --role app no servidor de aplicacao:
  --db-host 10.24.22.125 --db-name ocsdb --db-user ocsuser --db-password 'x8KAj0uYy8DL2KRaXaSYCRUB'
===================================================================
```

**Passo 2 — no servidor de aplicação** (ex.: `lnxdcocsapp01`):
```bash
sudo ./install-ocsinventory-3.0.sh \
  --role app \
  --db-engine postgresql \
  --db-host 10.24.22.125 \
  --db-name ocsdb \
  --db-user ocsuser \
  --db-password 'x8KAj0uYy8DL2KRaXaSYCRUB'
```

O script vai:
- Selecionar o IP correto (pergunta se houver múltiplas interfaces)
- **Testar a conectividade TCP com o banco antes de instalar qualquer coisa**
- Instalar Python 3.12, Node.js 20, Dart SDK, Nginx
- Instalar e configurar backend + frontend + SNMP Scanner + agente

> **Se o servidor tiver múltiplas interfaces:** quando o teste de conexão travar (sem resposta), provavelmente a interface usada não tem rota para o banco. Teste manualmente qual interface funciona: `timeout 3 bash -c "echo > /dev/tcp/IP_DO_BANCO/5432" && echo OK || echo BLOQUEADO`, e passe `--host IP_CORRETO` no comando do passo 2.

---

### 5.3 Quatro camadas: Banco + Backend + Frontend + SNMP

```
┌──────────┐   TCP:5432   ┌──────────┐   TCP:8000   ┌──────────┐
│ Servidor │◄────────────►│ Servidor │◄────────────►│ Servidor │
│    A     │              │    B     │              │    C     │
│  Banco   │              │ Backend  │              │ Frontend │
└──────────┘              └──────────┘              └──────────┘
                               ▲
                       TCP:8000│
                          ┌────┴─────┐
                          │ Servidor │
                          │    D     │
                          │   SNMP   │
                          └──────────┘
```

**Servidor A — Banco de dados:**
```bash
sudo ./install-ocsinventory-3.0.sh \
  --role db \
  --db-engine postgresql \
  --app-host IP_SERVIDOR_B
```

**Servidor B — Backend (API Django):**
```bash
sudo ./install-ocsinventory-3.0.sh \
  --role backend \
  --db-engine postgresql \
  --db-host IP_SERVIDOR_A \
  --db-name ocsdb \
  --db-user ocsuser \
  --db-password 'SENHA_DO_PASSO_A'
```

**Servidor C — Frontend (console web):**
```bash
sudo ./install-ocsinventory-3.0.sh \
  --role frontend \
  --backend-host IP_SERVIDOR_B
```

**Servidor D — SNMP Discovery:**
```bash
sudo ./install-ocsinventory-3.0.sh \
  --role snmp \
  --backend-host IP_SERVIDOR_B
```

> O script testa a conectividade TCP com o componente de destino **antes de instalar qualquer coisa** em cada servidor. Se a porta estiver bloqueada (Guardicore, NSX, ACL), o erro aparece imediatamente com instruções de diagnóstico.

> O agente OCS é instalado em **todos os servidores** (padrão "sim" ao perguntar em cada papel), permitindo que o console mostre o inventário de cada camada da arquitetura.

---

### 5.4 Banco em outro servidor via SSH

Para quando você quer preparar o banco sem logar manualmente no servidor de banco — desde que SSH esteja liberado entre os hosts.

> ⚠️ **Não use em ambientes com CyberArk ou bloqueio de movimento lateral.** Nesses casos, use `--role db` diretamente no servidor de banco (seção 5.2).

```bash
sudo ./install-ocsinventory-3.0.sh \
  --role db-remote \
  --remote-db-host IP_SERVIDOR_BANCO \
  --app-host IP_SERVIDOR_APP
```

O script copia a si mesmo para o servidor remoto via `scp` e executa `--role db` com um pseudo-terminal alocado — as perguntas interativas aparecem no seu terminal local, como se você estivesse logado no servidor de banco. As credenciais são trazidas de volta em `/root/ocsinventory-credentials-<host>.txt`.

> Requer que o script seja executado a partir de um arquivo local (não funciona via `curl | bash`).

---

## 6. Referência de flags

### Gerais

| Flag | Padrão | Descrição |
|---|---|---|
| `--role PAPEL` | menu interativo | Papel deste servidor (db, backend, frontend, snmp, app, standalone, db-remote) |
| `--host IP` | selecionado interativamente | IP deste servidor para comunicação com os outros componentes |
| `--backend-port PORTA` | `8000` | Porta do backend/API |
| `--frontend-port PORTA` | `8080` | Porta do console web |
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
| `--db-engine mysql\|postgresql` | `mysql` (backend/app), `postgresql` (standalone) | db, backend, app, standalone | Motor do banco |
| `--db-host HOST` | perguntado | backend, app | Host do banco remoto |
| `--db-port PORTA` | 5432/3306 | backend, app | Porta do banco remoto |
| `--db-name NOME` | `ocsdb` | todos | Nome do banco |
| `--db-user USUARIO` | `ocsuser` | todos | Usuário do banco |
| `--db-password SENHA` | gerada ou perguntada | todos | Senha do usuário do banco |
| `--app-host HOST` | perguntado | db | IP do servidor de app a liberar no banco |

### Multi-layer

| Flag | Padrão | Papéis | Descrição |
|---|---|---|---|
| `--backend-host HOST` | perguntado | frontend, snmp | Host do servidor de backend |

### Administrador do console

| Flag | Padrão | Descrição |
|---|---|---|
| `--admin-user USUARIO` | `admin` | Usuário administrador |
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

## 7. O que o script instala por papel

| Componente | standalone | db | backend | frontend | snmp | app |
|---|:---:|:---:|:---:|:---:|:---:|:---:|
| Banco de dados (local) | ✅ | ✅ | — | — | — | — |
| Python 3.12 + deps | ✅ | — | ✅ | — | ✅ | ✅ |
| Django + uWSGI | ✅ | — | ✅ | — | — | ✅ |
| Node.js 20 + Vue build | ✅ | — | — | ✅ | — | ✅ |
| Nginx (backend proxy) | ✅ | — | ✅ | — | — | ✅ |
| Nginx (frontend) | ✅ | — | — | ✅ | — | ✅ |
| SNMP Scanner | ✅ (opcional) | — | — | — | ✅ | opcional |
| Dart SDK + agente | ✅ | — (opc.) | ✅ (opc.) | ✅ (opc.) | ✅ (opc.) | ✅ (opc.) |
| Firewall (portas 8000/8080) | ✅ | — | 8000 | 8080 | — | ✅ |
| Usuário de sistema `ocs` | ✅ | — | ✅ | ✅ | ✅ | ✅ |

---

## 8. Ordem das etapas

### Etapas comuns (todos os papéis)

1. Detecção do SO e família de pacotes
2. Seleção interativa do IP (se múltiplas interfaces)
3. Instalação dos pacotes base (lista reduzida no papel `db`)
4. Atualização do SO (pergunta antes — pode reiniciar serviços existentes)
5. Configuração do firewall

### Papel `db` (encerra aqui)

6. Detecção/instalação do banco, validação de versão, criação de banco/usuário, liberação de acesso remoto

### Papéis `backend`, `app`, `standalone`

6. Criação do usuário de sistema `ocs`
7. Conexão com o banco (teste TCP + autenticação) — ou instalação do banco local (`standalone`)
8. Clone do repositório backend, criação do virtualenv, instalação de dependências Python
9. Configuração do `.env` (SECRET_KEY, motor/credenciais/host do banco, FRONTEND_REDIRECT)
10. Migrações Django (cria grupos super-admin/admin/user) + `collectstatic`
11. Criação do superusuário do console (idempotente)
12. Configuração do uWSGI + Nginx (porta 8000) + SELinux (RHEL)
13. Timer systemd de automação (executa `manage.py automation` a cada 5 min — cobre IPDiscover)

### Papéis `frontend`, `app`, `standalone`

14. (Papel `frontend`) Verificação de conectividade TCP com o backend remoto
15. Clone do repositório frontend, instalação de dependências npm
16. Build do Vue/Vite com `config.json` apontando para o backend correto
17. Configuração do Nginx (porta 8080) + SELinux (RHEL)

### Papel `snmp` (dedicado)

18. Verificação de conectividade TCP com o backend remoto
19. Clone do SNMP Scanner, criação do virtualenv, configuração do `scanner.conf`
20. Timer systemd (a cada 30 min)

### Etapas opcionais (perguntadas ou controladas via flag)

- **SNMP Scanner** (em `standalone`/`app`): pergunta, padrão "não"
- **Agente Dart**: pergunta em todos os papéis exceto `db`; padrão "sim" em multi-layer, "sempre" em standalone

---

## 9. Banco de dados — detalhes

### Detecção automática do motor

Ao rodar `--role db` sem `--db-engine`, o script detecta o que já está instalado:

- **Só MariaDB/MySQL encontrado** → usa esse motor automaticamente
- **Só PostgreSQL encontrado** → usa PostgreSQL automaticamente
- **Ambos encontrados** → mostra menu com versão e compatibilidade de cada um para você escolher
- **Nenhum encontrado** → mostra menu de instalação:
  ```
  [1] MySQL/MariaDB -- MariaDB 10.11 LTS (via módulo DNF mariadb:10.11 no RHEL 8)
  [2] PostgreSQL    -- PostgreSQL 15 (via módulo DNF postgresql:15 no RHEL 8)
  ```

### Versão mínima e RHEL 8

No AlmaLinux/RHEL 8, os módulos padrão trazem versões antigas:
- MariaDB → 10.3 (EOL, abaixo do mínimo) → o script habilita `mariadb:10.11` via `dnf module`
- PostgreSQL → 10.x (abaixo do mínimo) → o script habilita `postgresql:15` via `dnf module`

### Regras de acesso remoto (`pg_hba.conf`)

O script sempre grava as regras com **IP + máscara `/32`** em vez de hostname. Isso evita falha silenciosa quando o servidor de banco não consegue resolver o hostname do servidor de app via DNS:

```
# Errado (pode falhar se DNS não resolver):
host  ocsdb  ocsuser  lnxdcocsapp01  md5

# Correto (sempre funciona):
host  ocsdb  ocsuser  10.24.22.90/32  md5
```

### Mover o datadir depois da instalação

O script instala sempre no datadir padrão da distro (`/var/lib/mysql` ou `/var/lib/pgsql/data`) e você move depois com janela de manutenção:

**PostgreSQL (RHEL/AlmaLinux):**
```bash
systemctl stop postgresql
rsync -av /var/lib/pgsql/data/ /seu-novo-datadir/
chown -R postgres:postgres /seu-novo-datadir
semanage fcontext -a -t postgresql_db_t "/seu-novo-datadir(/.*)?"
restorecon -Rv /seu-novo-datadir
mkdir -p /etc/systemd/system/postgresql.service.d/
echo -e "[Service]\nEnvironment=PGDATA=/seu-novo-datadir" \
  > /etc/systemd/system/postgresql.service.d/pgdata.conf
systemctl daemon-reload
systemctl start postgresql
```

**MariaDB (RHEL/AlmaLinux):**
```bash
systemctl stop mariadb
rsync -av /var/lib/mysql/ /seu-novo-datadir/
chown -R mysql:mysql /seu-novo-datadir
semanage fcontext -a -t mysqld_db_t "/seu-novo-datadir(/.*)?"
restorecon -Rv /seu-novo-datadir
echo -e "[mysqld]\ndatadir=/seu-novo-datadir" > /etc/my.cnf.d/datadir.cnf
systemctl start mariadb
```

---

## 10. Particularidades por distro

| Situação | O que o script faz |
|---|---|
| **RHEL 8 — MariaDB 10.3 instalado por padrão** | `dnf module reset mariadb && dnf module enable mariadb:10.11` antes de instalar |
| **RHEL 8 — PostgreSQL 10 instalado por padrão** | `dnf module reset postgresql && dnf module enable postgresql:15` antes de instalar |
| **RHEL — PostgreSQL nunca inicializado** | `postgresql-setup --initdb` automático; detecta e move diretório "sujo" (sem `PG_VERSION`) para backup antes de inicializar |
| **RHEL — locale inválido** | Instala `glibc-langpack-en` automaticamente e passa `--locale=en_US.UTF-8` ao `initdb` |
| **RHEL — banco RPM corrompido** (`BDB0091 DB_VERSION_MISMATCH`) | Remove `/var/lib/rpm/__db*` automaticamente na primeira falha e tenta de novo |
| **RHEL — pg_hba.conf com PGDATA antigo** | Remove `/etc/sysconfig/pgsql/postgresql` e drop-ins systemd de tentativas anteriores antes do `initdb` |
| **RHEL — SELinux** | `semanage port` para liberar 8000/8080 em `http_port_t`; `semanage fcontext` + `restorecon` nos diretórios do uWSGI e estáticos |
| **Debian 13 (trixie)** | `software-properties-common` foi removido dessa versão — o script nunca o instala incondicionalmente (só no ramo Ubuntu/deadsnakes) |
| **Debian — sudo ausente** | Instalado automaticamente (instalações mínimas frequentemente não incluem) |
| **Git — dubious ownership** | Todos os comandos `git` rodam como usuário `ocs` (dono do diretório), nunca como root |
| **Nginx — site default conflitante** | Detecta e desabilita automaticamente antes de configurar os vhosts do OCS |

---

## 11. Problemas conhecidos e soluções

### Porta bloqueada (Guardicore / NSX / ACL de rede)

**Sintoma:** `timeout 3 bash -c "echo > /dev/tcp/HOST/PORTA"` retorna `PORTA BLOQUEADA`, mas `ping` funciona.

**Causa:** Ferramentas de microsegmentação (Guardicore, VMware NSX Distributed Firewall) aplicam políticas por VM na camada de rede, invisíveis para o SO. O `firewall-cmd`/`ufw` não controla essas regras.

**Solução:** Abrir a regra no console do Guardicore/NSX:
- Origem: IP do servidor de origem
- Destino: IP do servidor de destino
- Porta: a porta necessária (5432, 3306, 8000, 8080)
- Protocolo: TCP

**Diagnóstico manual:**
```bash
# Testar conectividade TCP direta (sem precisar do cliente do serviço)
timeout 3 bash -c "echo > /dev/tcp/IP_DESTINO/PORTA" && echo "ABERTA" || echo "BLOQUEADA"

# Testar várias portas de uma vez
for porta in 22 3306 5432 8000 8080; do
  timeout 2 bash -c "echo > /dev/tcp/IP_DESTINO/$porta" 2>/dev/null \
    && echo "PORTA $porta: ABERTA" || echo "PORTA $porta: BLOQUEADA"
done
```

### PostgreSQL — `pg_hba.conf entry not found`

**Sintoma:** `FATAL: no pg_hba.conf entry for host "X.X.X.X"` ao conectar remotamente.

**Causas e soluções:**

1. **Regra com hostname em vez de IP** (hostname não resolve no servidor de banco):
   ```bash
   sed -i 's/lnxdcocsapp01/10.24.22.90\/32/' /var/lib/pgsql/data/pg_hba.conf
   sudo -u postgres psql -c "SELECT pg_reload_conf();"
   ```

2. **Regra com IP sem máscara** (formato inválido — `md5` interpretado como máscara):
   ```bash
   sed -i 's|10.24.22.90    md5|10.24.22.90/32    md5|' /var/lib/pgsql/data/pg_hba.conf
   sudo -u postgres psql -c "SELECT pg_reload_conf();"
   ```

3. **Método de autenticação incompatível** (`scram-sha-256` com cliente antigo):
   ```bash
   sed -i 's/scram-sha-256/md5/' /var/lib/pgsql/data/pg_hba.conf
   sudo -u postgres psql -c "ALTER USER ocsuser WITH PASSWORD 'SENHA';"
   sudo -u postgres psql -c "SELECT pg_reload_conf();"
   ```

4. **Verificar qual pg_hba.conf o PostgreSQL está realmente usando:**
   ```bash
   sudo -u postgres psql -c "SHOW hba_file;"
   sudo -u postgres psql -c "SELECT pg_reload_conf();"
   sudo -u postgres psql -c "SELECT * FROM pg_hba_file_rules WHERE database = '{ocsdb}';"
   ```

### PostgreSQL — falha ao iniciar após editar pg_hba.conf

**Sintoma:** `systemctl restart postgresql` falha; `journalctl -u postgresql` mostra `invalid IP mask`.

**Causa:** linha no `pg_hba.conf` com IP sem máscara (ex.: `172.18.190.103    md5` em vez de `172.18.190.103/32    md5`).

**Solução:**
```bash
# Ver a linha problemática
grep -n "ocsuser" /var/lib/pgsql/data/pg_hba.conf

# Corrigir
sed -i 's|ENDEREÇO_IP    md5|ENDEREÇO_IP/32    md5|' /var/lib/pgsql/data/pg_hba.conf

# Subir o serviço
systemctl start postgresql
```

### Banco RPM corrompido — BDB0091 DB_VERSION_MISMATCH

**Sintoma:** `dnf install` falha com `RPM: error: db5 error(-30969) ... BDB0091 DB_VERSION_MISMATCH`.

**Causa:** Arquivos de ambiente do Berkeley DB em `/var/lib/rpm` incompatíveis com a versão atual do `rpm`/`dnf` (comum após restauração de snapshot ou migração de VM).

**Solução manual (o script já faz automaticamente):**
```bash
rm -f /var/lib/rpm/__db*
rpm --rebuilddb
```

### Locale inválido — PostgreSQL initdb falha

**Sintoma:** `/var/lib/pgsql/initdb_postgresql.log` mostra `initdb: error: invalid locale settings`.

**Causa:** `LANG=en_US.utf8` definida mas o langpack não está instalado.

**Solução:**
```bash
dnf install -y glibc-langpack-en
```

---

## 12. Validação pós-instalação

Após a instalação, teste manualmente:

```bash
# Backend respondendo?
curl -s -o /dev/null -w "%{http_code}" http://localhost:8000/
# Esperado: 200 ou 301

# Frontend respondendo?
curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/
# Esperado: 200

# Serviços ativos?
systemctl status ocsinventory-backend
systemctl status nginx
systemctl list-timers | grep ocsinventory
```

**No navegador:**
1. Acesse `http://IP_DO_FRONTEND:8080`
2. Login com o usuário/senha do resumo final (ou `/root/ocsinventory-credentials.txt`)
3. O próprio servidor de instalação deve aparecer no inventário após o primeiro ciclo do agente
4. Para SNMP: Configuração → SNMP → adicionar comunidade e confirmar que dispositivos da subnet aparecem após o próximo ciclo do timer (30 min)

---

## 13. Logs e credenciais

| O quê | Onde |
|---|---|
| Log da instalação | `/var/log/ocsinventory-install.log` |
| Backend (uWSGI) | `/var/log/ocsinventory-backend/` |
| Frontend (Nginx) | `/var/log/ocsinventory-frontend/` |
| Agente | `/var/log/ocsinventory-agent/` |
| Credenciais (banco + console) | `/root/ocsinventory-credentials.txt` (permissão `600`) |
| Credenciais do banco remoto (db-remote) | `/root/ocsinventory-credentials-<host>.txt` (permissão `600`) |

> A senha de root do banco **nunca é salva** em nenhum arquivo.

---

## 14. Idempotência

O script pode ser re-executado sem risco: usuário de sistema, banco, clone git, virtualenv Python e configurações são verificados antes de recriados. Útil para corrigir uma execução que falhou no meio ou atualizar a instalação depois.

---

## 15. Limitações conhecidas

- `3.0.0-rc1` é release candidate; o projeto pede feedback nessa fase.
- Não existe repositório apt/yum público para o OCS 3.0 ainda — a instalação é sempre a partir do código-fonte.
- Motor de extensão/plugins completo, CVE e Green IT estão previstos para versões 3.1/3.2.
- Testado de ponta a ponta em AlmaLinux 8.10, Ubuntu 24.04 e Debian 13; outras distros das mesmas famílias devem funcionar mas não foram validadas com a mesma profundidade.
- Em arquitetura multi-layer sem SSH liberado entre servidores, não há orquestração automática — o resultado do `--role db` é copiado manualmente para o próximo passo. O papel `db-remote` cobre esse gap quando SSH está disponível.
- O papel `db-remote` precisa do script em arquivo local (`./install-ocsinventory-3.0.sh`) — não funciona via `curl | bash`.

---

## 16. Licença

Este script é distribuído sob a licença **MIT**. Sinta-se livre para fazer fork, modificar, redistribuir e adaptar da maneira que quiser — para uso pessoal, comercial ou dentro de qualquer outro projeto — desde que o aviso de copyright e a licença original sejam mantidos. Não há garantia de funcionamento; use por sua conta e risco, especialmente em ambientes de produção.

O texto completo está no arquivo [`LICENSE`](./LICENSE).

---

## 17. Referências

- Backend: `github.com/OCSInventory-NG/OCSInventory-Server-Backend-Rework` (tag `3.0.0-rc1`)
- Frontend: `github.com/OCSInventory-NG/OCSInventory-Server-Frontend-Rework` (tag `3.0.0-rc1`)
- Agente: `github.com/OCSInventory-NG/OCSInventory-Agent-Rework` (tag `3.0.0-rc1`)
- SNMP Scanner: `github.com/OCSInventory-NG/OCSInventory-SNMP-Scanner` (tag `3.0.0-rc1`)
- Pacotes oficiais: `github.com/OCSInventory-NG/OCSInventory-Server-Packages`
