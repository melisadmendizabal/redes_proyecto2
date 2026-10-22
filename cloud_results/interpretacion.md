# Interpretación de la configuración y pruebas en AWS

La ejecución se realizó el **22 de octubre de 2026**, en la región `us-east-1`
y zona `us-east-1a`, con los scripts de la revisión
`93fc01e589d12dd3190679e2456bef502b899a8f`. El despliegue terminó con código `0`.
Los siete JSON se exportaron mediante `limpiar-aws.sh` antes de eliminar recursos.
Representan el estado de esa captura, no una consulta en tiempo real.

Se comprobaron los doce casos de `pruebas-aws.sh`: ocho comunicaciones internas
exitosas y cuatro bloqueos esperados. El [registro completo](pruebas-aws.log)
y las capturas enlazadas en la tabla de resultados documentan la ejecución.

## 1. VPC (`vpc.json`)

La VPC `vpc-startup`, identificada como `vpc-00889353775d6c950`, contiene el bloque
IPv4 `10.10.0.0/24`. No es la VPC predeterminada, aparece en estado `available`
y tiene la etiqueta `Project=proyecto-redes`.

Este bloque reúne las cuatro áreas en una red común, mientras las subredes,
tablas de rutas y ACL determinan la separación y el tráfico permitido.

## 2. Subredes (`subnets.json`)

Las cuatro subredes están disponibles en `us-east-1a`, pertenecen a la VPC del
proyecto y no presentan solapamientos entre sus bloques IPv4.

| Área | CIDR | IP aún disponibles | IP pública automática |
| --- | --- | ---: | --- |
| Ventas | `10.10.0.0/27` | 25 | Sí |
| TI | `10.10.0.32/27` | 26 | No |
| Visitas | `10.10.0.64/27` | 26 | Sí |
| Data Center | `10.10.0.96/28` | 10 | No |

`AvailableIpAddressCount` indica las direcciones aún disponibles al exportar,
no la capacidad total. Los valores son coherentes con dos VM en Ventas y una
en cada una de las otras áreas. La clasificación pública o privada depende
también de las asociaciones de rutas del siguiente apartado.

## 3. Enrutamiento (`route-tables.json`)

La tabla `rt-publica` (`rtb-0614ecf623beac3ce`) está asociada explícitamente
a Ventas y Visitas. Contiene dos rutas activas:

- `10.10.0.0/24` hacia `local`, para el tráfico dentro de la VPC.
- `0.0.0.0/0` hacia `igw-012961e90a091737f`, como salida a Internet.

La tabla principal `rtb-0c040c18e2df73dea` contiene únicamente la ruta local.
TI y Data Center no tienen asociaciones explícitas en la exportación, por lo
que utilizan esa tabla principal. Estas subredes tienen comunicación interna,
pero sus tablas no ofrecen salida a Internet ni una ruta hacia un NAT Gateway.

La configuración de rutas explica por qué se accede por salto SSH a las VM
privadas desde `vm-ventas-1`. La conectividad a Internet de las VM públicas
no se verificó mediante una prueba de salida específica.

## 4. Internet Gateway (`internet-gateway.json`)

El gateway `igw-startup` (`igw-012961e90a091737f`) aparece adjunto a la VPC
`vpc-00889353775d6c950`, con estado de asociación `available`.
Coincide con el destino de la ruta predeterminada de Ventas y Visitas.
El acceso SSH desde CloudShell a sus VM públicas funcionó durante las pruebas.

## 5. ACL de red (`network-acls.json`)

La ACL `nacl-internas` (`acl-04c9a46ac1e5166dc`) está asociada a Ventas, TI y
Data Center. Sus reglas de entrada son:

| Número | Origen | Acción | Protocolos |
| ---: | --- | --- | --- |
| 50 | `10.10.0.64/27` (Visitas) | Denegar | Todos |
| 100 | `0.0.0.0/0` | Permitir | Todos |
| 32767 | `0.0.0.0/0` | Denegar | Todos |

La regla 50 se evalúa antes que la 100 y bloquea el tráfico de Visitas al entrar
a las tres subredes internas. La salida se permite mediante la regla 100.

Visitas utiliza la ACL predeterminada `acl-057f43d85da835804`, que permite entrada
y salida con reglas 100. El aislamiento se aplica en el ingreso a las áreas
internas, no mediante una denegación en la ACL de Visitas.

Las ACL no mantienen estado. Por eso, además de bloquear los pings desde
Visitas hacia Ventas, TI y Data Center, se bloquea la respuesta de Visitas a
un ping iniciado por Ventas. Los cuatro casos presentaron 100 % de pérdida,
de acuerdo con estas reglas. La prueba confirma el comportamiento ICMP; no
constituye una prueba exhaustiva de todos los protocolos.

## 6. Grupos de seguridad (`security-groups.json`)

Se exportaron el grupo `default` y el grupo `startup-sg`, etiquetado como
`sg-startup`. Las cinco VM utilizan `startup-sg` (`sg-00203825199f203cb`).
Sus permisos son:

| Dirección | Protocolo / puerto | Origen o destino | Propósito |
| --- | --- | --- | --- |
| Entrada | TCP/22 | `174.129.87.242/32` | SSH desde CloudShell |
| Entrada | TCP/22 | `10.10.0.0/24` | SSH interno para el salto a VM privadas |
| Entrada | ICMP, todos los tipos/códigos | `10.10.0.0/24` | Pruebas de ping internas |
| Salida | Todos | `0.0.0.0/0` | Tráfico saliente permitido |

La regla SSH interna sí aparece en esta nueva exportación y permitió realizar
las pruebas desde TI y Data Center. La IP `/32` corresponde a esta sesión;
puede cambiar en otra ejecución de CloudShell.

El permiso ICMP del grupo no anula la denegación de la ACL: ambos controles
deben permitir el tráfico. Esto explica que el grupo permita ICMP de la VPC
pero las pruebas procedentes de Visitas queden bloqueadas.

## 7. Instancias (`instancias.json`)

Se registraron cinco instancias `t3.micro`, todas en estado `running` al exportar:

| Nombre | Identificador | IP privada | IP pública |
| --- | --- | --- | --- |
| `vm-ventas-1` | `i-0835e1c56db5f935a` | `10.10.0.27` | `13.223.243.134` |
| `vm-ventas-2` | `i-0e90bf08327f7f06e` | `10.10.0.4` | `3.239.213.73` |
| `vm-ti-1` | `i-0549c393197876ce8` | `10.10.0.52` | Sin IP pública |
| `vm-datacenter-1` | `i-003607ff81753a21a` | `10.10.0.103` | Sin IP pública |
| `vm-visitas-1` | `i-0df35f9f630a8701a` | `10.10.0.81` | `100.53.105.193` |

La distribución coincide con `INTERNAS=1` y `BONUS=1`, valores predeterminados
del script actualizado. A diferencia de la evidencia anterior de tres VM,
esta ejecución incluye máquinas en TI y Data Center y permite comprobar
la comunicación entre todas las áreas internas.

## 8. Resultados de conectividad

Cada caso envió cuatro solicitudes ICMP. Las conexiones SSH se establecieron
y ejecutaron `hostname`, `hostname -I` y `ping`; los bloqueos registrados
corresponden al ping y no a un fallo de autenticación SSH.

| Prueba | Origen → destino | Recibidos | Pérdida | Evaluación | Captura |
| ---: | --- | ---: | ---: | --- | --- |
| 1 | Ventas 1 → Ventas 2 | 4/4 | 0 % | Conforme | [Ver](capturas/prueba-01.jpg) |
| 2 | Ventas 2 → Ventas 1 | 4/4 | 0 % | Conforme | [Ver](capturas/prueba-02.jpg) |
| 3 | Ventas 1 → TI | 4/4 | 0 % | Conforme | [Ver](capturas/prueba-03.jpg) |
| 4 | TI → Ventas 1 | 4/4 | 0 % | Conforme | [Ver](capturas/prueba-04.jpg) |
| 5 | Ventas 1 → Data Center | 4/4 | 0 % | Conforme | [Ver](capturas/prueba-05.jpg) |
| 6 | Data Center → Ventas 1 | 4/4 | 0 % | Conforme | [Ver](capturas/prueba-06.jpg) |
| 7 | TI → Data Center | 4/4 | 0 % | Conforme | [Ver](capturas/prueba-07.jpg) |
| 8 | Data Center → TI | 4/4 | 0 % | Conforme | [Ver](capturas/prueba-08.jpg) |
| 9 | Visitas → Ventas 1 | 0/4 | 100 % | Bloqueo esperado | [Ver](capturas/prueba-09.jpg) |
| 10 | Visitas → TI | 0/4 | 100 % | Bloqueo esperado | [Ver](capturas/prueba-10.jpg) |
| 11 | Visitas → Data Center | 0/4 | 100 % | Bloqueo esperado | [Ver](capturas/prueba-11.jpg) |
| 12 | Ventas 1 → Visitas | 0/4 | 100 % | Bloqueo de respuesta esperado | [Ver](capturas/prueba-12.jpg) |

El código final de `pruebas-aws.sh` fue `1`: el script devuelve el estado
del último ping, que debía fallar. Por ello se evaluaron los doce resultados
individualmente. No se interpretó ese código como un fallo del despliegue
ni como un resumen automático de aprobación.

## 9. Evidencias y alcance

Los JSON de esta carpeta se descargaron antes del borrado. El archivo comprimido
descargado conservó la misma huella SHA-256 que el generado en CloudShell:
`d96d9ecbbec8bf6056dc42f9c413a7a478794525e29fbbdeeffe3829027ec4ce`.

El [registro de despliegue](despliegue-aws.log), el [registro de pruebas](pruebas-aws.log)
y las doce capturas complementan los siete archivos de configuración.
Las capturas se tomaron al mostrar desde el registro la salida de cada caso.
La exportación describe recursos en ejecución y no cambia el estado histórico
capturado tras la limpieza.

## 10. Limpieza verificada

Después de guardar las evidencias, se confirmó el borrado mediante
`limpiar-aws.sh`. La consulta posterior, iniciada el 22 de octubre de 2026
a las 16:19:59 de Guatemala (`22:19:59 UTC`), confirmó:

- Cero VPC con la etiqueta del proyecto y cero subredes de la VPC eliminada.
- Cero instancias activas del proyecto; las cinco instancias figuran como `terminated`.
- Cero llaves llamadas `proyecto-key` y ausencia del gateway de esta ejecución.

El [registro de limpieza](limpieza-aws.log) documenta la eliminación de subredes,
ACL, tabla de rutas, grupo de seguridad, gateway, VPC y llave. El
[registro de verificación](limpieza-verificacion.log) recoge las consultas
posteriores. La evidencia JSON se conserva con el estado previo al borrado.

## Conclusión

La ejecución valida la comunicación ICMP bidireccional dentro de Ventas y entre
Ventas, TI y Data Center para los pares probados. También valida el aislamiento
ICMP de Visitas respecto de las áreas internas, incluida la denegación de las
respuestas cuando Ventas inicia el ping. Las rutas y las IP de las VM son
coherentes con dos subredes públicas y dos privadas. Los doce casos cumplen
el comportamiento esperado para esta configuración.
