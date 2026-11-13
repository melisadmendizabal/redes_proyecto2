# Reglas internas (Firewall y ACLs) — Fase 2

Región `us-east-1`, VPC `vpc-startup` (`10.10.0.0/24`). Esta parte cubre dos requisitos. El primero es que TI tenga conectividad hacia todas las subredes y que las demás subredes no tengan conectividad hacia TI. El segundo es que la intranet sea accesible desde las demás subredes, excepto Visitas, y no desde Internet.

## Archivos

| Archivo | Para qué sirve |
|---|---|
| `reglas-internas-fase2.sh` | Se ejecuta en CloudShell. Crea `ti-sg`, `nacl-ti`, el EC2 Instance Connect Endpoint `eice-ti` y su grupo `eice-ti-sg`. Cambia el grupo de `vm-ti-1` y la NACL de la subred TI. Exporta la configuración a `~/evidencia-aws/`. |
| `pruebas-reglas-fase2.sh` | Se ejecuta en CloudShell. Muestra la configuración y prueba el tráfico permitido y el bloqueado. |
| `limpiar-aws.sh` | Ahora también borra el Instance Connect Endpoint antes de borrar las subredes. |

## Dos capas de firewall en AWS

| | Security Group | Network ACL |
|---|---|---|
| Se aplica a | La interfaz de red de cada instancia | La subred completa |
| Estado | **Con estado**: si una conexión sale, su respuesta entra sola | **Sin estado**: la respuesta se evalúa como tráfico nuevo |
| Reglas | Solo `allow` (lo demás se niega) | `allow` y `deny`, evaluadas por número de menor a mayor |

El Security Group es el firewall principal porque entiende conexiones. Por eso basta con no darle a `ti-sg` ninguna regla de entrada desde las otras subredes. Las respuestas a lo que TI inicia entran igual. La NACL agrega una segunda barrera a nivel de subred. Así, un error en un Security Group no deja expuesto a TI.

## Implementación

### Security Group `ti-sg` (asignado a `vm-ti-1`)

En la Fase 1, `vm-ti-1` usaba `startup-sg`, que acepta SSH e ICMP de toda la VPC. Por eso Ventas y Data Center podían llegar a TI. Ahora tiene un grupo propio:

| Dirección | Protocolo | Puerto | Origen/destino | Motivo |
|---|---|---|---|---|
| Entrada | TCP | 22 | `10.10.0.32/27` TI | Administración desde TI y desde el Instance Connect Endpoint, que vive en TI |
| Entrada | ICMP | todos | `10.10.0.32/27` TI | Ping entre equipos de TI |
| Salida | Todos | todos | `0.0.0.0/0` | TI puede iniciar conexiones hacia cualquier subred |

### Network ACL `nacl-ti` (asociada a la subred TI)

Como la NACL no tiene estado, no alcanza con negar la VPC entera. Eso también bloquearía las respuestas a lo que TI inicia. Primero se permiten solo las respuestas y después se niega todo lo demás que venga de la red interna.

| Regla | Acción | Protocolo | Origen | Puertos/tipo | Motivo |
|---|---|---|---|---|---|
| 100 | allow | TCP | `10.10.0.0/24` | 1024-65535 | Respuestas TCP de Ventas, Visitas, Data Center y DMZ (puertos efímeros) |
| 110 | allow | TCP | `10.10.1.0/28` | 1024-65535 | Respuestas TCP del DNS interno |
| 120 | allow | UDP | `10.10.1.0/28` | 1024-65535 | Respuestas UDP del DNS interno |
| 130 | allow | ICMP | `10.10.0.0/24` | tipo 0 echo-reply | Respuesta a los ping que hace TI |
| 140 | allow | ICMP | `10.10.0.0/24` | tipo 3 | Destination unreachable (errores y Path MTU) |
| 150 | allow | ICMP | `10.10.0.0/24` | tipo 11 | Time exceeded (traceroute desde TI) |
| 200 | **deny** | Todos | `10.10.0.0/24` | — | Cualquier otro tráfico iniciado desde la VPC hacia TI |
| 210 | **deny** | Todos | `10.10.1.0/28` | — | Cualquier otro tráfico iniciado desde la VPC del DNS hacia TI |
| 300 | allow | TCP | `0.0.0.0/0` | 1024-65535 | Respuestas del endpoint de S3 (`dnf`). TI no tiene ruta al Internet Gateway |
| * | deny | Todos | `0.0.0.0/0` | — | Regla por defecto |
| Salida 100 | allow | Todos | `0.0.0.0/0` | — | TI puede salir hacia todo |

Un ping de Ventas a TI es ICMP tipo 8 (echo-request), no tipo 0, así que cae en la regla 200. Un SSH de Ventas a TI va al puerto 22, que no es efímero, y también cae en la 200. La limitación de la NACL es que una conexión desde Ventas hacia un puerto alto de TI pasaría la regla 100. Para eso está `ti-sg`, que la descarta. Por eso se usan las dos capas.

Las NACL no filtran el DNS de AWS (`10.10.0.2`) ni el servicio de metadatos. TI sigue resolviendo nombres externos a través del DNS que entrega AWS.

### Administración de TI: EC2 Instance Connect Endpoint `eice-ti`

En la Fase 1 se entraba a las VM privadas saltando por SSH desde `vm-ventas-1`. Con las reglas nuevas, Ventas ya no puede llegar a TI. Por eso se creó un **EC2 Instance Connect Endpoint** dentro de la subred TI. CloudShell abre un túnel hacia el endpoint, y desde ahí se hace SSH a la VM privada:

```bash
ssh -i ~/proyecto-key.pem -o ProxyCommand='aws ec2-instance-connect open-tunnel --instance-id %h' ec2-user@<instance-id>
```

- El endpoint no tiene costo y la VM no necesita IP pública ni bastion.
- La conexión hacia la VM sale con la IP privada del endpoint, que está en `10.10.0.32/27`. Para las demás subredes es tráfico de TI, lo que encaja con la regla "TI llega a todo".
- Su grupo `eice-ti-sg` no tiene reglas de entrada. La única salida permitida es TCP 22 hacia `10.10.0.0/24`.
- AWS permite un solo endpoint por VPC. El script verifica que esté en la subred TI.

## Intranet

Las reglas de la intranet son del grupo `intranet-rrhh-sg` (ver `intranet-fase2.md`). Permite HTTP 80 desde Ventas, TI y Data Center. No incluye Visitas, que además está bloqueada por la regla 50 de `nacl-internas`. Desde Internet no es accesible porque no tiene IP pública, la subred Data Center no tiene ruta al Internet Gateway y el nombre `.local` solo existe en el DNS interno. La DMZ tampoco tiene acceso, a propósito: un servidor público no debe iniciar conexiones hacia servicios internos.

## Matriz de conectividad esperada

| Origen ↓ / Destino → | TI | Ventas | Data Center | Visitas | Intranet (HTTP) |
|---|---|---|---|---|---|
| **TI** | ✔ | ✔ | ✔ | ✔ | ✔ |
| **Ventas** | ✘ (`ti-sg` + `nacl-ti`) | ✔ | ✔ | ✘ | ✔ |
| **Data Center** | ✘ (`ti-sg` + `nacl-ti`) | ✔ | ✔ | ✘ | ✔ |
| **Visitas** | ✘ | ✘ | ✘ | ✔ | ✘ |
| **Internet** | ✘ | solo SSH desde CloudShell | ✘ | solo SSH desde CloudShell | ✘ |

## Pruebas (`pruebas-reglas-fase2.sh`)

| # | Origen → destino | Esperado |
|---|---|---|
| 1 | Configuración: grupo de `vm-ti-1`, reglas de `ti-sg` y de `nacl-ti` | Tablas |
| 2 | `vm-ti-1` → `vm-ventas-1` (ping + TCP 22) | Funciona |
| 3 | `vm-ti-1` → `vm-datacenter-1` (ping + TCP 22) | Funciona |
| 4 | `vm-ti-1` → `vm-visitas-1` (ping + TCP 22) | Funciona |
| 5 | `vm-ti-1` → `http://rrhh.mansiondeldisfraz.local` | HTTP 200 |
| 6 | `vm-ti-1` → VM de la DMZ, TCP 80 (solo si ya existe) | Funciona |
| 7 | `vm-ventas-1` → `vm-ti-1` (ping + TCP 22) | Bloqueado |
| 8 | `vm-ventas-2` → `vm-ti-1` (ping) | Bloqueado |
| 9 | `vm-datacenter-1` → `vm-ti-1` (ping + TCP 22) | Bloqueado |
| 10 | `vm-intranet-rrhh` → `vm-ti-1` (ping + TCP 22) | Bloqueado |
| 11 | `vm-visitas-1` → `vm-ti-1` (ping + TCP 22) | Bloqueado |
| 12 | `vm-ventas-1` → intranet por nombre | HTTP 200 |
| 13 | `vm-datacenter-1` → intranet (`--resolve`) | HTTP 200 |
| 14 | `vm-visitas-1` → intranet | Bloqueado |
| 15 | CloudShell (Internet) → intranet | Bloqueado |

Las pruebas 2 y 7 muestran el comportamiento con estado. TI hace ping a Ventas y recibe la respuesta, pero Ventas no puede hacer ping a TI.

## Revertir (si hiciera falta para una demo)

```bash
aws ec2 modify-instance-attribute --instance-id <id de vm-ti-1> --groups <id de startup-sg>
aws ec2 replace-network-acl-association --association-id <asociación actual de snet-ti> --network-acl-id <id de nacl-internas>
```

## Notas para el resto del equipo

- **Scripts anteriores:** `pruebas-aws.sh` (Fase 1) y la prueba 4 de `pruebas-intranet-fase2.sh` entran a `vm-ti-1` saltando desde `vm-ventas-1`. Ese salto ahora queda bloqueado por diseño. Para entrar a TI se usa el Instance Connect Endpoint (comando de arriba).
- **DMZ (persona 4):** para que TI pueda administrar la DMZ, su Security Group debe aceptar SSH o ICMP desde `10.10.0.32/27`. Si la DMZ tiene NACL propia, debe dejar salir las respuestas hacia TI (puertos 1024-65535). La DMZ no necesita ninguna regla hacia TI: `nacl-ti` la bloquea de todas formas.
- **Visitas y hardening (persona 5):** si se crea una NACL para Visitas, debe permitir la salida de las respuestas hacia `10.10.0.32/27` para que TI siga llegando a Visitas. Visitas no puede iniciar nada hacia TI. En `vm-ti-1` solo debe quedar abierto el 22 (sshd).
- **Nuevas VM en TI:** se lanzan con `--security-group-ids <ti-sg>`.
