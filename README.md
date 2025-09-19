# Proxy App

Aplicativo Flutter simples com um serviço de proxy HTTP opcional em Dart para encaminhar requisições com filtros.

## App Flutter

O app (`lib/`) mostra uma lista de requisições e um relatório gráfico. O botão de “+” dispara chamadas para `https://score.hsborges.dev/api/score?cpf=...` e exibe o status.

## Web Service (Proxy)

Servidor Dart leve em `bin/proxy_server.dart` com fila e rate limit (1 req/s por padrão):

- `POST /proxy`: JSON `{ url, method, headers, body }` (encaminhado via fila)
- `GET /proxy?url=<percent-encoded>`: atalho (encaminhado via fila)
- `GET /proxy/score?cpf=...`: atalho para o endpoint de score (encaminhado via fila)
- `GET /metrics`: métricas estilo Prometheus (fila, contadores, latência)
- `GET /history?limit=N&offset=M`: últimos itens processados (paginável; `limit` padrão = `HISTORY_MAX`, `offset` padrão = 0)
- `DELETE /history`: limpa o histórico (DB e memória)
- `GET /health` e `GET /healthz`: liveness/readiness
- Filtros: hosts permitidos, injeção de header `client-id`, override opcional do parâmetro `cpf`
- CORS e `OPTIONS` suportados
 - Pacing adaptativo: ao receber 429 do upstream, o proxy respeita `Retry-After`/`X-RateLimit-Reset-In`, aguarda e reenvia sem repassar o 429 ao cliente (dentro do TTL).

### Executar o servidor

Pré‑requisitos: Flutter/Dart SDK instalado.

- `dart run bin/proxy_server.dart`

Por padrão, escuta em `0.0.0.0:8080`.
Obs.: O servidor escuta em IPv6 com `v6Only=false`, aceitando conexões via `localhost` (IPv6 `::1`) e IPv4 (`127.0.0.1`). Se o app estiver no Linux, prefira `http://127.0.0.1:PORT` caso tenha problemas com `localhost`.

### Configuração por variáveis de ambiente

- `PORT`: porta do servidor (default `8080`).
- `ALLOWED_HOSTS`: hosts permitidos, separados por vírgula (default `score.hsborges.dev`).
- `CLIENT_ID`: valor do header `client-id` injetado em toda requisição (default `2`).
- `OVERRIDE_CPF`: se definido, substitui o parâmetro de query `cpf` pelo valor informado.
- `PROXY_TIMEOUT_MS`: timeout das requisições ao upstream (default `30000`).
- `RATE_PER_SEC`: taxa máxima para o upstream (default `1.0`).
- `MAX_QUEUE`: tamanho máximo da fila (default `100`).
- `REQUEST_TTL_MS`: TTL de espera na fila antes de expirar (default `30000`).
- `OVERFLOW_POLICY`: `reject` (padrão) ou `drop_oldest` (descarta o mais antigo quando a fila enche).
- `HISTORY_MAX`: tamanho máximo do histórico em memória (default `200`).
 - `DB_PATH`: caminho do arquivo SQLite para persistir histórico (default `proxy_history.db`).

### Exemplos de uso

1) Encaminhar GET via querystring (precisa estar percent-encoded):

`GET http://localhost:8080/proxy?url=https://score.hsborges.dev/api/score?cpf=06556619132`

2) Encaminhar com POST JSON (entra na fila e respeita rate limit):

```
POST http://localhost:8080/proxy
Content-Type: application/json

{
  "url": "https://score.hsborges.dev/api/score?cpf=06556619132",
  "method": "GET",
  "headers": {"Accept": "application/json"}
}
```

Resposta (exemplo):

```
{
  "status": 200,
  "headers": { ... },
  "body": "{\"score\": 700}"
}
```

3) Healthcheck e Métricas:

`GET http://localhost:8080/health` ou `/healthz`

`GET http://localhost:8080/metrics`

### Filtros implementados

- Hosts permitidos: bloqueia requisições cujo `host` não esteja em `ALLOWED_HOSTS` (403).
- Injeção de header: adiciona/força `client-id = CLIENT_ID` em todas as requisições.
- Override de CPF: se `OVERRIDE_CPF` estiver definido e a URL tiver `?cpf=...`, o valor é substituído.

> Observação: O servidor usa apenas `dart:io` e o pacote `http` já presente no projeto; nenhuma dependência extra é necessária.

## Persistência da URL do Proxy no App

O app salva a URL do proxy localmente usando `shared_preferences`. Ao abrir o app novamente, o campo “Proxy URL” já vem preenchido com o último valor usado.


## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Lab: Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Cookbook: Useful Flutter samples](https://docs.flutter.dev/cookbook)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.
Troubleshooting (Linux)
- Se houver erro de `libsqlite3.so` não encontrado, instale a biblioteca do sistema: `sudo apt-get install libsqlite3-0`.
- O binário pode se chamar `libsqlite3.so.0`. O servidor já tenta carregar os caminhos comuns automaticamente.
