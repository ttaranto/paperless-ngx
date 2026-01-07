# Paperless-ngx Production Deployment

Paperless-ngx com Docker, Nginx SSL (Let's Encrypt), PostgreSQL, Tika e Gotenberg.

**Domain:** https://paperless.taranto.ai

## Arquitetura

```
Internet → Nginx (80/443) → Paperless (8000)
                          ↓
           PostgreSQL ← Redis ← Tika/Gotenberg
```

## Estrutura de Diretórios

**No servidor (dados persistentes):**
```
/opt/apps/paperless/
├── data/      # Dados internos do Paperless
├── media/     # Documentos processados
├── consume/   # Pasta de entrada (drop folder)
└── export/    # Exportações
```

**No projeto (volumes Docker):**
```
./postgres-data/  # Dados do PostgreSQL
./certbot/        # Certificados SSL
./backups/        # Backups do banco
```

---

## Deploy em Produção

### 1. Copiar projeto para o servidor

```bash
# Via git (se tiver repositório)
git clone <repo-url> /home/user/paperless-ngx
cd /home/user/paperless-ngx

# Ou via rsync/scp
rsync -avz ./paperless-ngx/ user@server:/home/user/paperless-ngx/
```

### 2. Criar diretórios no servidor

```bash
sudo mkdir -p /opt/apps/paperless/{data,media,consume,export}
sudo chown -R 1000:1000 /opt/apps/paperless
```

### 3. Configurar o .env

O arquivo `.env` já está configurado. Revise e altere se necessário:

```bash
nano .env
```

**IMPORTANTE:** Altere a senha do admin antes do primeiro start:
- `PAPERLESS_ADMIN_PASSWORD` - senha do usuário admin

### 4. Inicializar certificados SSL

```bash
cd scripts
chmod +x *.sh
sudo ./init-letsencrypt.sh
```

O script irá:
1. Criar config temporária do Nginx (HTTP + ACME)
2. Solicitar certificado real do Let's Encrypt via webroot
3. Trocar para a config completa com SSL
4. Configurar renovação automática via cron

Pré-requisitos:
- DNS apontando para o IP do servidor
- Nginx e certbot instalados no host
- `PAPERLESS_PORT` correto no `.env` (porta que o app expõe no host)

### 5. Iniciar todos os serviços

```bash
cd ..
docker compose up -d
```

### 6. Verificar status

```bash
# Ver logs
docker compose logs -f

# Ver status dos containers
docker compose ps

# Verificar saúde do Paperless
docker compose exec paperless python manage.py document_index
```

### 7. Acessar o sistema

Acesse https://paperless.taranto.ai

**Login:**
- Usuário: `admin`
- Senha: (definida em `PAPERLESS_ADMIN_PASSWORD` no .env)

---

## Backup

### Backup Manual

```bash
./scripts/backup-postgres.sh
```

O backup é salvo em `./backups/` com timestamp.

### Backup Automático (Cron)

```bash
# Editar crontab
crontab -e

# Adicionar linha (backup diário às 2h da manhã)
0 2 * * * /home/user/paperless-ngx/scripts/backup-postgres.sh >> /var/log/paperless-backup.log 2>&1
```

### Restaurar Backup

```bash
# Restaurar backup específico
./scripts/restore-postgres.sh ./backups/paperless_20260102_140000.sql.gz

# Restaurar último backup
./scripts/restore-postgres.sh latest
```

---

## Comandos Úteis

```bash
# Parar todos os serviços
docker compose down

# Reiniciar serviço específico
docker compose restart paperless

# Ver logs de um serviço
docker compose logs -f paperless

# Criar superusuário manualmente
docker compose exec paperless python manage.py createsuperuser

# Reindexar documentos
docker compose exec paperless python manage.py document_index --reindex

# Verificar consumo de disco
du -sh /opt/apps/paperless/*
du -sh ./postgres-data

# Renovar certificado SSL manualmente
docker compose exec certbot certbot renew
docker compose exec nginx nginx -s reload
```

---

## Solução de Problemas

### Nginx não inicia (certificado inválido)

```bash
# Remover certificados e reinicializar
rm -rf ./certbot
./scripts/init-letsencrypt.sh
```

### Paperless não conecta ao banco

```bash
# Verificar se PostgreSQL está rodando
docker compose ps postgres
docker compose logs postgres

# Testar conexão
docker compose exec postgres psql -U paperless -d paperless -c "SELECT 1;"
```

### Documentos não são processados

```bash
# Verificar permissões
ls -la /opt/apps/paperless/consume/

# Verificar logs do consumer
docker compose logs -f paperless | grep -i consumer
```

### OCR não funciona em português

```bash
# Verificar se Tika está rodando
docker compose ps tika
curl http://localhost:9998/tika
```

---

## Atualização

```bash
# Baixar novas imagens
docker compose pull

# Reiniciar com novas versões
docker compose up -d

# Verificar versão
docker compose exec paperless python manage.py --version
```

---

## Credenciais

| Serviço    | Usuário    | Senha                                    |
|------------|------------|------------------------------------------|
| Paperless  | admin      | (ver PAPERLESS_ADMIN_PASSWORD no .env)   |
| PostgreSQL | paperless  | W9mI6ZopCkUBLE/VLpij5eErjwjwEbG+         |

**Secret Key:** `121f94bf516c059f76a12513d2e7a5a55f2409fc5b47fd3a5c1a5b0455b52031`

---

## Portas

| Serviço    | Porta Interna | Porta Externa |
|------------|---------------|---------------|
| Nginx      | 80, 443       | 80, 443       |
| Paperless  | 8000          | -             |
| PostgreSQL | 5432          | -             |
| Redis      | 6379          | -             |
| Tika       | 9998          | -             |
| Gotenberg  | 3000          | -             |
