# CI/CD — app-go (K3s na AWS)

[![CI](https://github.com/dhuberto/ci_cd_kubernets/actions/workflows/ci.yml/badge.svg)](https://github.com/dhuberto/ci_cd_kubernets/actions/workflows/ci.yml)

Pipeline completo de **CI/CD** para uma aplicação web em **Go + PostgreSQL**,
com deploy automatizado em **K3s** (Kubernetes leve) na EC2, usando
**Rolling Update** e **Blue/Green**.

O projeto cobre desde a validação do código (testes, análise estática,
auditoria de dependências) até o deploy em produção com **rollback
instantâneo** e **switch de tráfego sem downtime**.

---

## Sumário

- [Visão geral](#visão-geral)
- [Stack](#stack)
- [Arquitetura de deploy](#arquitetura-de-deploy)
- [Pipeline de CI](#pipeline-de-ci)
- [Pipeline de CD](#pipeline-de-cd)
- [Como fazer rollback](#como-fazer-rollback)
- [Acessando o ambiente](#acessando-o-ambiente)
- [Como rodar localmente](#como-rodar-localmente)
- [Estrutura do repositório](#estrutura-do-repositório)
- [Decisões técnicas](#decisões-técnicas)

---

## Visão geral

O pipeline cobre dois ciclos:

- **CI** — a cada PR e push na `main`, roda `go vet`, `go test` em
  matrix Go 1.25, `govulncheck` (auditoria de CVEs) e Trivy (scan de
  segurança do filesystem e da imagem). Se qualquer gate falhar, o
  merge é bloqueado.
- **CD** — provisiona a infraestrutura na AWS via Terraform, instala o
  K3s na EC2 via Ansible, e faz deploy com duas estratégias:
  **Rolling Update** e **Blue/Green** com switch de tráfego e rollback.

A imagem da aplicação é publicada no **GHCR**
(`ghcr.io/dhuberto/ci_cd_kubernets:<sha>`).

**Aplicação:** todo-list minimalista em Go com renderização no servidor
(SSR) e persistência em PostgreSQL. O binário é estático
(`CGO_ENABLED=0`), a imagem final tem cerca de **~20 MB** e o driver
Postgres é compilado dentro do binário — zero dependências em runtime.

---

## Stack

| Camada | Tecnologia |
|---|---|
| **Aplicação** | Go 1.25, `net/http`, `html/template`, `database/sql`, `lib/pq` |
| **Banco de dados** | PostgreSQL (StatefulSet + PVC no K3s) |
| **Container** | Docker (multi-stage build, Alpine, binário estático) |
| **Cluster** | K3s (Kubernetes leve) em EC2 |
| **Ingress** | Traefik (padrão do K3s) |
| **CI/CD** | GitHub Actions |
| **Registry** | GHCR (GitHub Container Registry) |
| **Infra as Code** | Terraform |
| **Configuração** | Ansible |

---

## Arquitetura de deploy

```
GitHub Actions (runner hospedado)
 │
 ├── cd-provision.yml
 │     └── Terraform: VPC + subnet + IGW + SG + EC2 (Amazon Linux 2023)
 │     └── Ansible: K3s Server + namespaces
 │
 ├── cd-rolling.yml
 │     └── build+push GHCR → kubectl apply no namespace rolling → smoke test
 │
 ├── cd-blue-green.yml
 │     └── build+push GHCR → deploy no slot blue OU green (sem mexer no tráfego)
 │
 └── cd-blue-green-switch.yml
       └── kubectl patch no Service active → muda a cor da interface
 │
 ▼ (SSH)
EC2 Amazon Linux 2023
 └── cluster K3s "k3s"
       ├── namespace: rolling
       │     ├── StatefulSet postgres   (1 réplica, PVC 1Gi, postgres:alpine)
       │     ├── Service postgres       (headless, para DNS estável)
       │     ├── Deployment app-go      (3 réplicas, APP_COLOR=purple)
       │     ├── Service app-go         (ClusterIP)
       │     └── Ingress rolling.local
       │
       └── namespace: blue-green
             ├── StatefulSet postgres       (1 réplica, PVC 1Gi)
             ├── Service postgres           (headless)
             ├── Deployment app-go-blue     (2 réplicas, APP_COLOR=blue)
             ├── Deployment app-go-green    (2 réplicas, APP_COLOR=green)
             ├── Service app-go-active      (selector trocável)
             ├── Ingress app-go.local       (aponta para o active)
             ├── Ingress app-go-azul.local  (aponta fixo para o blue)
             └── Ingress app-go-verde.local (aponta fixo para o green)
```

### Componentes

| Camada | Tecnologia | Papel |
|---|---|---|
| Infra AWS | Terraform | VPC, subnet, IGW, SG, EC2 |
| Configuração da EC2 | Ansible | K3s Server + namespaces |
| Cluster | K3s | Kubernetes leve em EC2 |
| Ingress | Traefik | Ponto único de entrada HTTP |
| Banco de dados | Postgres (StatefulSet + PVC) | Persistência real (1Gi por namespace) |
| Aplicação | Go + `database/sql` + `lib/pq` | SSR, binário estático, sem runtime deps |
| Registry | GHCR | Imagem `ghcr.io/dhuberto/ci_cd_kubernets:<sha>` |
| Deploy | kubectl via SSH | Aplica manifestos no cluster |
| Rollback | `kubectl patch` no Service | Troca o selector ativo (Blue/Green) |

---

## Pipeline de CI

**Workflow:** `.github/workflows/ci.yml`

**Gatilhos:** `pull_request` e `push` na `main`.

**O que roda:**

1. **Análise estática** com `go vet`
2. **Testes** com `go test` em matrix Go 1.25
3. **Auditoria de dependências** com `govulncheck`
4. **Scan de segurança** com Trivy (filesystem + image)

**Features de destaque:**

- **Reusable workflow** (`_reusable-test.yml`) extrai os steps de
  teste, evitando duplicação entre jobs.
- **Cache de módulos Go** (`go.sum`).
- **`permissions:` mínimo** — `contents: read` por padrão.
- **Branch protection** — required checks bloqueiam o merge se
  qualquer um falhar.
- **CODEOWNERS** — revisores atribuídos automaticamente por arquivo.

### Como disparar o CI

Automático em qualquer PR ou push na `main`. Para rodar manualmente:
**Actions → CI → Run workflow**. O input `run_build` (booleano)
controla se os jobs de build/publish também rodam.

---

## Pipeline de CD

Todos os workflows de CD rodam **manualmente** via
**Actions → Run workflow**.

### 1. Provisionar a infra

```
Actions → CD - Provision Infra → Run workflow
```

**O que faz:**

- Cria VPC, subnet, IGW, SG e EC2 (Amazon Linux 2023) via Terraform
- Instala o K3s Server via Ansible (script oficial)
- Ajusta o kubeconfig para o `ec2-user`
- Cria os namespaces `rolling` e `blue-green`
- Publica os artifacts `ec2-ssh-key` e `terraform-state`

**Depois de rodar:**

1. Baixe o artifact `ec2-ssh-key` e cadastre em
   **Settings → Environments → aws → Secrets → `EC2_SSH_KEY`**.
2. Copie o IP do summary e atualize a variable
   **`EC2_PUBLIC_IP`** no mesmo Environment.

### 2. Deploy Rolling

```
Actions → CD - Rolling Update → Run workflow
  image_tag: latest
```

**O que faz:**

- Build + push da imagem para o GHCR
- Aplica o Postgres (Secret + Service + StatefulSet) no namespace `rolling`
- Aguarda o rollout do Postgres
- Aplica o RBAC + a aplicação (Deployment + Service + Ingress)
- Aguarda o rollout dos 3 pods
- Smoke test via Ingress (`http://rolling.local/healthz`)

**Como acessar:**

Adicione ao arquivo `C:\Windows\System32\drivers\etc\hosts`
(Windows, como Administrador):

```
<IP_DA_EC2>   rolling.local
<IP_DA_EC2>   app-go.local
<IP_DA_EC2>   app-go-azul.local
<IP_DA_EC2>   app-go-verde.local
```

Depois abra `http://rolling.local/` — tema **roxo**.

### 3. Deploy Blue/Green — slot BLUE

```
Actions → CD - Blue/Green (deploy por cor) → Run workflow
  color:     blue
  image_tag: latest
```

**O que faz:**

- Build + push da imagem
- Aplica o Postgres do namespace `blue-green`
- Aplica os Services (`app-go-blue`, `app-go-green`, `app-go-active`),
  os Ingress (`app-go.local`, `app-go-azul.local`, `app-go-verde.local`)
  e o Deployment `app-go-blue`
- Smoke test direto no pod do slot blue
- **Não altera o tráfego** — o `app-go-active` já aponta para blue por default

**Como acessar:**

- `http://app-go.local/` — tema **azul** (cor ativa)
- `http://app-go-azul.local/` — tema **azul** (fixo no slot blue)

### 4. Deploy Blue/Green — slot GREEN

```
Actions → CD - Blue/Green (deploy por cor) → Run workflow
  color:     green
  image_tag: latest
```

**O que faz:**

- Deploya o slot green no cluster
- **Não altera o tráfego** — a interface em `app-go.local` continua azul

**Estado esperado no cluster:** 4 pods no namespace (blue + green).

**Como acessar o slot inativo:**

- `http://app-go-verde.local/` — tema **verde** (fixo no slot green)

### 5. Switch de tráfego para GREEN

```
Actions → CD - Blue/Green (switch de tráfego) → Run workflow
  color: green
```

**O que faz:** um único `kubectl patch` no Service `app-go-active`:

```bash
kubectl -n blue-green patch svc app-go-active \
  -p '{"spec":{"selector":{"app":"app-go","slot":"green"}}}'
```

**Resultado:** a interface em `http://app-go.local/` muda de **azul
para verde ao vivo**. Sem downtime, sem recriar pods, sem esperar rollout.

Os Ingress dedicados (`app-go-azul.local` e `app-go-verde.local`)
**não são afetados** — continuam apontando para os slots fixos.

---

## Como fazer rollback

### Rollback do Blue/Green (recomendado)

Rode o mesmo workflow de switch com a **cor anterior**:

```
Actions → CD - Blue/Green (switch de tráfego) → Run workflow
  color: blue
```

O patch troca o selector de volta. A interface em `app-go.local` volta
a azul em segundos.

**Validação:**

```bash
kubectl -n blue-green get svc app-go-active -o jsonpath='{.spec.selector}'
# → {"app":"app-go","slot":"blue"}
```

### Rollback do Rolling

Rode o `CD - Rolling Update` informando no input `image_tag` o SHA do
commit que estava em produção antes. O Deployment passa a usar aquela
imagem e o kubelet faz o rollout de volta.

```
Actions → CD - Rolling Update → Run workflow
  image_tag: a1b2c3d    # SHA curto do commit anterior
```

Não é instantâneo como o Blue/Green — o kubelet sobe pods novos com a
imagem antiga e derruba os atuais gradualmente.

### Rollback total (teardown)

```
Actions → CD - Destroy Infra → Run workflow
  confirm: DESTROY
```

Destrói VPC, subnet, IGW, SG e EC2. Preserva o Key Pair
(`ci-cd-deploy-key`), o artifact do state e os secrets.

Para limpar tudo:

```
Actions → CD - Destroy Full → Run workflow
  confirm: DESTROY-ALL
```

---

## Acessando o ambiente

Acessa via SSH:

```bash
ssh -i ~/.ssh/deploy_key ec2-user@<IP_DA_EC2>
```

Comandos úteis dentro da EC2:

```bash
# Pods da aplicação no rolling
kubectl -n rolling get pods -o wide

# Postgres no rolling
kubectl -n rolling get statefulset,pvc

# Pods no blue-green
kubectl -n blue-green get pods -o wide

# Ingress do blue-green
kubectl -n blue-green get ingress

# Qual cor está ativa agora
kubectl -n blue-green get svc app-go-active -o jsonpath='{.spec.selector}'

# Nodes do cluster K3s
kubectl get nodes -o wide
```

### Hostnames disponíveis

| URL | O que mostra |
|---|---|
| `http://rolling.local/` | Aplicação do namespace rolling (tema roxo) |
| `http://app-go.local/` | Cor ativa do Blue/Green (muda com o switch) |
| `http://app-go-azul.local/` | Slot blue (sempre azul) |
| `http://app-go-verde.local/` | Slot green (sempre verde) |

---

## Como rodar localmente

### Pré-requisitos

- **Go 1.25+** instalado (`go version`)
- **Docker** + **Docker Compose** (para a stack completa com Postgres)
- **git**

### Rodar os testes

```bash
go mod tidy
go test ./...
go vet ./...
```

### Rodar direto (sem Docker)

Precisa de um Postgres acessível e das envs `DB_*` exportadas:

```bash
export DB_HOST=localhost
export DB_PORT=5432
export DB_USER=appuser
export DB_PASSWORD=mudar123
export DB_NAME=appdb
export APP_PORT=5000
export APP_COLOR=purple

go run ./src
```

### Rodar com Docker

```bash
docker build -t app-go:dev .
docker run --rm -p 8080:5000 \
  -e DB_HOST=host.docker.internal \
  -e DB_PORT=5432 \
  -e DB_USER=appuser \
  -e DB_PASSWORD=mudar123 \
  -e DB_NAME=appdb \
  -e APP_COLOR=purple \
  app-go:dev
```

Acesse `http://localhost:8080/`.

**Rotas para testar:**

| Rota | Resposta esperada |
|---|---|
| `http://localhost:8080/` | Página da todo-list |
| `http://localhost:8080/healthz` | `ok` |

### Rodar os checks do CI localmente

```bash
go vet ./...
go test -v ./...
go install golang.org/x/vuln/cmd/govulncheck@latest
govulncheck ./...
```

---

## Estrutura do repositório

```
ci_cd_kubernets/
├── .github/
│   ├── CODEOWNERS
│   └── workflows/
│       ├── ci.yml                          # CI: go vet, go test, govulncheck, Trivy
│       ├── _reusable-test.yml              # Workflow reutilizável
│       ├── cd-provision.yml                # Terraform + Ansible (instala K3s)
│       ├── cd-rolling.yml                  # Build+push e deploy Rolling
│       ├── cd-blue-green.yml               # Build+push e deploy por cor
│       ├── cd-blue-green-switch.yml        # Patch do Service active
│       ├── cd-destroy.yml                  # Teardown parcial
│       └── cd-destroy-full.yml             # Teardown total
│
├── terraform/
│   ├── providers.tf                        # Provider AWS + versão do Terraform
│   ├── variables.tf                        # Variáveis: região, tipo, key_name, CIDR
│   ├── main.tf                             # Recursos AWS
│   ├── outputs.tf                          # Outputs consumidos pelo workflow
│   └── user_data.sh                        # Bootstrap da EC2 (git + curl)
│
├── ansible/
│   ├── ansible.cfg                         # Configuração global
│   └── playbook.yml                        # Instala K3s + cria namespaces
│
├── k8s/
│   ├── rolling/
│   │   ├── postgres-secret.yaml
│   │   ├── postgres-service.yaml
│   │   ├── postgres-statefulset.yaml
│   │   ├── rbac.yaml
│   │   ├── deployment.yaml
│   │   ├── service.yaml
│   │   └── ingress.yaml                    # IngressClass: traefik
│   └── blue-green/
│       ├── postgres-secret.yaml
│       ├── postgres-service.yaml
│       ├── postgres-statefulset.yaml
│       ├── rbac.yaml
│       ├── deployment-blue.yaml
│       ├── deployment-green.yaml
│       ├── service-blue.yaml
│       ├── service-green.yaml
│       ├── service-active.yaml
│       ├── ingress.yaml                    # IngressClass: traefik
│       ├── ingress-blue.yaml               # IngressClass: traefik
│       └── ingress-green.yaml              # IngressClass: traefik
│
├── docs/
│   ├── ci-pipeline.md
│   └── cd-pipeline.md
│
├── src/
│   ├── main.go
│   └── main_test.go
│
├── go.mod
├── go.sum
├── Dockerfile
└── README.md
```

---

## Decisões técnicas

- **K3s em vez de EKS:** custo controlado (~US$ 30/mês contra ~US$ 190 do
  EKS com NAT Gateway + ALB), Kubernetes de verdade (produção-ready),
  Traefik e local-path já vêm inclusos. Single-node é suficiente para
  demonstrar Rolling Update e Blue/Green com persistência real.
- **Terraform em vez de Console AWS:** infra reproduzível, revisável
  e destruível por código.
- **Ansible em vez de `user_data`:** mantém a configuração do cluster
  no repositório, versionada e idempotente.
- **Go em vez de Python/Node:** binário estático de ~20 MB, zero
  dependências em runtime, `govulncheck` como gate de segurança.
- **Postgres como StatefulSet + PVC:** persistência real com 1Gi por
  namespace. O `local-path` provisioner do K3s já cria o volume.
- **GHCR em vez de Docker Hub:** autenticação nativa via `GITHUB_TOKEN`,
  sem rate limit.
- **Traefik como Ingress:** padrão do K3s, vem instalado e configurado,
  zero setup extra.
- **Blue/Green com `APP_COLOR`:** torna o switch visualmente
  verificável (roxo/azul/verde). O rollback é um único `kubectl patch`
  no selector do Service `app-go-active`.
- **Ingress dedicados por cor:** além do Ingress que reflete o switch
  (`app-go.local`), há dois Ingress fixos (`app-go-azul.local` e
  `app-go-verde.local`) que permitem inspecionar cada slot
  independentemente do tráfego de produção.

---

## Referências

- [`docs/ci-pipeline.md`](docs/ci-pipeline.md) — documentação detalhada do CI
- [`docs/cd-pipeline.md`](docs/cd-pipeline.md) — documentação detalhada do CD
- [`src/main.go`](src/main.go) — código da aplicação (Go)
- [`src/main_test.go`](src/main_test.go) — testes unitários
