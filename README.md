# OCS Inventory 3.0 — Instalador para Servidor Único

Script de instalação majoritariamente desassistida do **OCS Inventory 3.0** (tag `3.0.0-rc1`) em um único servidor de testes/laboratório, cobrindo todos os componentes da nova arquitetura: backend, console web, automação/IPDiscover, SNMP Scanner e o agente unificado.

Suporta duas famílias de distribuição Linux, detectadas automaticamente:

- **Debian**: Ubuntu 22.04/24.04, Debian 12/13
- **RHEL**: RHEL 8/9, Rocky Linux, AlmaLinux, Fedora

## Arquitetura

A versão 3.0 é uma reescrita completa do OCS Inventory. Em vez do antigo servidor Perl + console PHP, a stack agora é:

| Componente | Tecnologia | Função |
|---|---|---|
| Backend | Django + Django REST Framework (Python) | API REST, autenticação, regras de negócio |
| Console web | Vue 3 + Vite | Interface do administrador, consome a API |
| Automação / IPDiscover | Comando de gerência do Django (`manage.py automation`) | Executa regras agendadas; o IPDiscover passou a ser *server-side* nesta versão |
| SNMP Scanner | Script Python standalone | Descoberta de dispositivos de rede via SNMP, alimenta o backend pela API |
| Agente | Binário único compilado em Dart | Coleta de inventário, multiplataforma |

No servidor de testes, esses componentes rodam como serviços systemd independentes: `ocsinventory-backend` (uWSGI), `ocsinventory-automation.timer`, `ocsinventory-snmp-scanner.timer` e `ocsinventory-agent`, mais o Nginx servindo o backend e o console em portas separadas.

## O que o script instala

O script resolve e instala tudo sozinho, com nomes de pacote corretos por família de distro:

- **PostgreSQL** (banco de dados único para todo o stack)
- **Python 3.12+** (exigência do Django 6.0), incluindo os headers de build (`python3-dev`/`python3.12-dev` ou `-devel`), necessários para compilar `python-ldap` e `uwsgi`
- **Node.js 20 LTS** (build do frontend Vue/Vite)
- **Dart SDK** (compilação do agente) — baixado como SDK standalone direto do bucket oficial do Google, não via repositório de pacotes, já que esse repositório não tem equivalente para RHEL
- **Nginx** (proxy do backend e servidor do build estático do frontend)
- **Firewall**: `ufw` no Debian/Ubuntu, `firewalld` no RHEL/Rocky/Alma/Fedora
- **sudo** (algumas instalações mínimas de Debian não o incluem por padrão, e o script depende dele para rodar comandos com privilégios reduzidos)
- No RHEL: `epel-release` e `policycoreutils-python-utils` (fornece `semanage`, usado nos ajustes de SELinux)

## Particularidades tratadas por distro

Diferenças reais entre as famílias que o script resolve automaticamente, não só nomes de pacote:

- **Firewall**: `ufw allow`/`enable` no Debian; `firewall-cmd --add-port`/`--reload` no RHEL.
- **Nginx**: `sites-available` + symlink em `sites-enabled` no Debian; `/etc/nginx/conf.d/*.conf` no RHEL (layout que o pacote já inclui automaticamente).
- **PostgreSQL**: no RHEL o pacote `postgresql-server` não inicializa o cluster por conta própria — o script roda `postgresql-setup --initdb` quando necessário. O caminho do `pg_hba.conf` não é fixo (muda de distro pra distro); o script pergunta ao próprio PostgreSQL via `SHOW hba_file` e insere as regras de autenticação por senha no topo do arquivo, na frente de regras padrão como `ident` (comuns no RHEL) — preservando dono e permissão originais do arquivo.
- **SELinux** (só relevante no RHEL, e só age se estiver `Enforcing`/`Permissive`): libera as portas 8000/8080 no domínio `http_port_t` via `semanage port`, e aplica o contexto `httpd_sys_content_t` nos diretórios estáticos do backend/frontend e `httpd_var_run_t` no socket do uWSGI — sem isso o Nginx daria 403 silencioso mesmo com permissões Unix corretas.
- **Python 3.12 já de fábrica**: Ubuntu 24.04 e RHEL/Rocky/Alma 9.4+/10 já vêm com `python3` = 3.12+, mas sem os headers de build instalados separadamente — o script garante isso nos dois casos.
- **Debian 13 (trixie)**: o pacote `software-properties-common` foi removido dessa versão pelo próprio Debian (sem previsão de retorno); o script só o usa no ramo específico do Ubuntu (PPA deadsnakes), nunca incondicionalmente.
- **Git**: o clone/atualização do código roda como o usuário de sistema `ocs` (dono do diretório), nunca como `root`, evitando a proteção "dubious ownership" do git moderno.

## Uso

```bash
sudo ./install-ocsinventory-3.0.sh [opções]
```

Sem nenhuma opção, a instalação é **100% desassistida**: detecta o IP do servidor, gera senhas aleatórias, instala e configura tudo, e no final mostra um resumo com URLs e credenciais (também salvo em `/root/ocsinventory-credentials.txt`, permissão `600`). A única interação por padrão é uma confirmação `[s/N]` antes de começar — pulada automaticamente com `-y`/`--yes` ou quando não há terminal interativo (ex.: execução via Ansible/CI).

### Opções

| Opção | Padrão | Descrição |
|---|---|---|
| `--host HOST_OU_IP` | IP detectado automaticamente | Endereço usado nas URLs do console e do agente |
| `--backend-port PORTA` | `8000` | Porta do backend/API |
| `--frontend-port PORTA` | `8080` | Porta do console web |
| `--db-password SENHA` | gerada aleatoriamente | Senha do PostgreSQL |
| `--admin-user USUARIO` | `admin` | Usuário administrador do console |
| `--admin-email EMAIL` | `admin@localhost` | E-mail do administrador |
| `--admin-password SENHA` | gerada aleatoriamente | Senha do administrador |
| `--snmp-subnet CIDR` | subnet local detectada automaticamente | Faixa varrida pelo SNMP Scanner |
| `--base-dir CAMINHO` | `/opt/ocsinventory` | Diretório raiz da instalação |
| `--ocs-tag TAG` | `3.0.0-rc1` | Tag git a instalar |
| `--skip-snmp` | — | Não instala o SNMP Scanner |
| `--skip-agent` | — | Não instala o agente neste servidor |
| `-y`, `--yes` | — | Não pergunta confirmação antes de iniciar |
| `-h`, `--help` | — | Mostra a ajuda |

## O que o script faz (ordem das etapas)

Etapas obrigatórias (qualquer falha aborta a instalação com diagnóstico claro):

1. Pacotes base do sistema
2. Usuário de sistema `ocs` (roda todos os serviços da aplicação, nunca como root)
3. Firewall
4. PostgreSQL (instalação, init do cluster se necessário, ajuste de `pg_hba.conf`, criação de role/banco)
5. Backend — código (clone da tag), dependências Python, venv
6. Backend — configuração (`.env`: `SECRET_KEY`, credenciais do banco, `FRONTEND_REDIRECT`)
7. Backend — migrações (cria os grupos `super-admin`/`admin`/`user`) e arquivos estáticos
8. Backend — superusuário (criado via shell do Django, idempotente)
9. Backend — uWSGI + Nginx (porta 8000)
10. Backend — timer systemd de automação (executa `manage.py automation` a cada 5 min, cobre o IPDiscover)
11. Frontend — código e dependências npm
12. Frontend — build (Vite, com `config.json` apontando para o backend)
13. Frontend — Nginx (porta 8080)

Etapas opcionais (uma falha aqui é registrada e avisada, mas não interrompe o restante):

14. SNMP Scanner (clonagem, venv, `scanner.conf`, timer a cada 30 min — ainda exige associar uma comunidade SNMP na console depois)
15. Agente local em Dart (compilado e instalado no próprio servidor via `setup/linux/install.sh` oficial, para autovalidar o fluxo de inventário)

## Idempotência

O script pode ser executado várias vezes sem problema: usuário, banco, repositórios git, venvs e configurações são todos verificados antes de recriados. Isso é útil tanto para corrigir uma execução que falhou no meio quanto para simplesmente atualizar a instalação depois.

## Validação pós-instalação

Ao final, o script testa `http://127.0.0.1:<porta>/api-check/` (backend) e `http://127.0.0.1:<porta>/` (frontend). Validação manual recomendada:

1. Login no console com o usuário/senha do resumo final
2. O próprio servidor de teste aparece no inventário (confirma backend + agente)
3. Associar uma comunidade SNMP ao scanner em Configuração → SNMP, e checar se dispositivos da subnet aparecem após o próximo ciclo do timer
4. Criar uma regra de Scheduler para IPDiscover e confirmar que ela executa no próximo ciclo do `ocsinventory-automation.timer`

## Logs

| O quê | Onde |
|---|---|
| Instalação (script) | `/var/log/ocsinventory-install.log` |
| Backend (uWSGI) | `/var/log/ocsinventory-backend/` |
| Frontend (Nginx) | `/var/log/ocsinventory-frontend/` |
| Agente | `/var/log/ocsinventory-agent/` |
| Credenciais | `/root/ocsinventory-credentials.txt` (permissão `600`) |

## Limitações conhecidas

- `3.0.0-rc1` é release candidate; o próprio projeto pede feedback de usuários nessa fase.
- Não existe repositório apt/yum público oficial para a 3.0 ainda — a instalação é sempre a partir do código-fonte.
- Motor de extensão/plugins completo, CVE e Green IT estão previstos para 3.1/3.2, fora do escopo desta versão.
- Testado de ponta a ponta em Ubuntu 24.04, AlmaLinux 10 e Debian 13; outras distros das mesmas famílias devem funcionar mas não foram validadas com a mesma profundidade.

## Licença

Este script é distribuído sob a licença **MIT**. Sinta-se livre para fazer fork, modificar, redistribuir e adaptar da maneira que quiser — para uso pessoal, comercial ou dentro de qualquer outro projeto — desde que o aviso de copyright e a licença original sejam mantidos. Não há garantia de funcionamento; use por sua conta e risco, especialmente em ambientes de produção.

O texto completo está no arquivo [`LICENSE`](./LICENSE).

## Referências

- Backend: `github.com/OCSInventory-NG/OCSInventory-Server-Backend-Rework` (tag `3.0.0-rc1`)
- Frontend: `github.com/OCSInventory-NG/OCSInventory-Server-Frontend-Rework` (tag `3.0.0-rc1`)
- Agente: `github.com/OCSInventory-NG/OCSInventory-Agent-Rework` (tag `3.0.0-rc1`)
- SNMP Scanner: `github.com/OCSInventory-NG/OCSInventory-SNMP-Scanner` (tag `3.0.0-rc1`)
- Pacotes/Docker/RPM/DEB oficiais: `github.com/OCSInventory-NG/OCSInventory-Server-Packages`
