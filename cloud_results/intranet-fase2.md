# Intranet de RRHH — Fase 2

Región `us-east-1`. La intranet corre en la EC2 `vm-intranet-rrhh`, con Amazon Linux 2023 y Nginx, en la subred Data Center (`snet-datacenter`, `10.10.0.96/28`) de `vpc-startup`. Su IP privada fija es `10.10.0.101`, la misma a la que apunta el registro `rrhh.mansiondeldisfraz.local` del DNS interno (`10.10.1.4`). No tiene IP pública.

## Archivos

| Archivo | Para qué sirve |
|---|---|
| `desplegar-intranet-fase2.sh` | Se ejecuta en CloudShell. Crea el endpoint de S3, el Security Group y la instancia con la IP fija. |
| `configurar-intranet-fase2.sh` | Se pasa como user data a la instancia. Instala Nginx y escribe `nginx.conf`, el virtual host `conf.d/rrhh.conf` y la página `index.html`. |
| `pruebas-intranet-fase2.sh` | Se ejecuta en CloudShell. Hace las pruebas de acceso permitido y bloqueado. |
| `limpiar-aws.sh` | Ahora también borra los endpoints de la VPC antes de borrar la VPC. |

## Implementación

- **Servidor web:** Nginx atiende en el puerto 80. El virtual host `rrhh.mansiondeldisfraz.local` sirve la página estática de `/usr/share/nginx/rrhh/index.html`. Un `server` por defecto responde `return 444` (cierra la conexión sin responder) a cualquier otro nombre o a la IP directa, así que la intranet solo contesta cuando se pide por su nombre interno. `server_tokens off` oculta la versión de Nginx, y se agregan los encabezados `X-Content-Type-Options` y `X-Frame-Options`.
- **Instalación sin Internet:** la subred Data Center no tiene ruta a Internet. Para que `dnf` instale Nginx se creó un endpoint de tipo gateway para S3 (`vpce-s3-privadas`) en la tabla de rutas principal, que usan TI y Data Center. Los repositorios de Amazon Linux 2023 están en S3, así que la instancia descarga paquetes sin salir a Internet. Un endpoint gateway de S3 no tiene costo.
- **Metadatos:** la instancia exige IMDSv2 (`HttpTokens=required`).

## Control de acceso

Security Group `intranet-rrhh-sg` (`sg-intranet-rrhh`), exclusivo de la intranet:

| Puerto | Origen | Motivo |
|---|---|---|
| TCP 80 | `10.10.0.0/27` Ventas | Acceso de empleados |
| TCP 80 | `10.10.0.32/27` TI | Acceso de empleados |
| TCP 80 | `10.10.0.96/28` Data Center | Acceso desde otros servidores |
| TCP 22 | `10.10.0.0/27` Ventas | Administración por salto desde `vm-ventas-1` |
| TCP 22 | `10.10.0.32/27` TI | Administración desde TI |

Visitas (`10.10.0.64/27`) queda bloqueada en dos capas: la regla 50 de `nacl-internas` y el Security Group, que no la incluye. Desde Internet no hay acceso por tres razones: la instancia no tiene IP pública, la subred no tiene ruta al Internet Gateway y el nombre `.local` solo existe en el DNS interno.

## Pruebas (`pruebas-intranet-fase2.sh`)

| # | Origen → destino | Esperado |
|---|---|---|
| 1 | `vm-intranet-rrhh`: `nginx -t`, servicio activo, puerto 80 y virtual host | OK |
| 2 | `vm-ventas-1` → `http://rrhh.mansiondeldisfraz.local` | HTTP 200 |
| 3 | `vm-ventas-2` → `http://rrhh.mansiondeldisfraz.local` | HTTP 200 |
| 4 | `vm-ti-1` → `http://rrhh.mansiondeldisfraz.local` | HTTP 200 |
| 5 | `vm-datacenter-1` → intranet por IP con `--resolve` | HTTP 200 |
| 6 | `vm-ventas-1` → `http://10.10.0.101` sin el nombre | Conexión cerrada (444) |
| 7 | `vm-visitas-1` → intranet | Sin respuesta (bloqueado) |
| 8 | CloudShell (Internet) → intranet | No resuelve y sin respuesta |

## Notas para el resto del equipo

- **DNS (persona 1):** BIND acepta consultas de Ventas y TI. Si se quiere que el Data Center también resuelva `rrhh`, hay que agregar `10.10.0.96/28` en `allow-query` y en el Security Group del DNS. Por eso la prueba 5 usa `--resolve`.
- **Reglas internas (persona 3):** las reglas de la intranet están en `intranet-rrhh-sg`, separadas de `startup-sg`. La DMZ (`10.10.0.112/28`) no tiene acceso a la intranet a propósito: un servidor público no debe poder iniciar conexiones hacia servicios internos.
- **Hardening (persona 5):** en esta VM solo deben quedar abiertos el 22 (sshd) y el 80 (nginx). Se puede verificar con `sudo ss -tulpn`.
- **Limpieza:** `limpiar-aws.sh` borra el endpoint de S3. El peering y la VPC del DNS se borran aparte.
