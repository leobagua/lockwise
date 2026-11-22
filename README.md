# lockwise

Roda uma DDL em uma tabela quente do Postgres pausando a tabela uma vez só, por um tempo que você escolhe.

É um binário que fala SQL comum com o servidor.

> Estado atual: protótipo.

## O problema

Uma DDL como `ALTER TABLE` precisa de um lock forte. Enquanto ela espera por esse lock, toda consulta nova na tabela fica parada atrás dela.

O jeito comum de lidar com isso é pedir o lock com um prazo curto e repetir. Em tabelas muito usadas isso falha. Cada pedido para a tabela um pouco, e depois de centenas de pedidos a migração desiste sem ter rodado.

## Como o lockwise resolve

Ele faz três coisas, nesta ordem.

1. **Espera sem atrapalhar.** Pega primeiro um lock fraco, `SHARE UPDATE EXCLUSIVE`. Esse lock não bloqueia leitura nem escrita. Ele tira o autovacuum do caminho e põe as DDLs em fila.
2. **Olha antes de pedir.** Vê quem está usando a tabela e há quanto tempo. Se há uma transação longa, espera ela terminar. A tabela segue funcionando.
3. **Pede o lock forte uma vez, com prazo.** Se consegue, roda a DDL e libera. Se nunca aparece uma brecha, não pede, e diz quem está bloqueando.

## Uso

```bash
cargo build --release

target/release/lockwise run \
  --conn "host=localhost user=migrator dbname=app" \
  --preset presets/c1-window-3000ms.toml \
  --lock accounts:ael \
  --sql "ALTER TABLE accounts ADD COLUMN note text"
```

O `--lock` recebe a tabela e o modo. Os modos são `ael` para `ACCESS EXCLUSIVE` e `sre` para `SHARE ROW EXCLUSIVE`.

O usuário do banco precisa do role `pg_monitor`. A conexão deve ser direta, sem PgBouncer.

## Configuração

O preset é um arquivo TOML.

```toml
name = "c1-window-3000ms"
max_runtime_s = 120      # tempo total antes de desistir

[window]
max_pause_ms = 3000      # o máximo que a tabela pode ficar parada
cooldown_ms = 10000      # intervalo entre tentativas
poll_ms = 200            # cadência de observação
prelock_hold_s = 60      # por quanto tempo segurar o lock fraco
```

O valor que mais importa é `max_pause_ms`. Uma pausa menor causa menos dano, mas pode nunca encontrar uma brecha.

## Saída

A ferramenta escreve um evento por linha, em JSON.

| Evento | Significado |
|---|---|
| `queued` | Começou. |
| `prelocked` | Pegou o lock fraco. |
| `waiting` | Está esperando. Traz a lista de quem bloqueia. |
| `acquired` | Pegou o lock forte. |
| `result` | Terminou, com sucesso ou desistência. |

O código de saída é `0` para sucesso, `2` para desistência e `1` para erro.

## Testes

```bash
tests/run.sh
```

O script sobe um Postgres descartável e roda os testes de ponta a ponta. Ele espera os binários do Postgres em `~/.local/share/mise/installs/postgres/17.8/bin`. Para usar outro lugar, defina `PG_ROOT` e `VER`.
