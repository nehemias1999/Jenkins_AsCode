# ADR 0002: Leer el SCM por la línea de comandos de git, no por la API del proveedor

**Estado.** Aceptado, 2026-09. Verificado contra un remoto real antes de decidir.

## Contexto

`pipeline-drift` necesita dos cosas de un repositorio remoto: a qué commit apunta una
rama, y el contenido de un archivo en ese commit. Los repositorios en alcance están en
GitHub.

Las opciones eran tres:

1. **La API REST de GitHub.** Resuelve las dos consultas y acepta un token en un header,
   así que técnicamente es viable. El costo no es el código: es que **obliga a este
   repositorio a tener una credencial propia**. Habría que declarar un PAT en el contrato
   de configuración, guardarlo, rotarlo y protegerlo, y el alcance de ese token sería
   lectura de todos los repositorios que la herramienta mire. Además acopla la
   herramienta a una versión de API y a sus límites de rate.
2. **La CLI de GitHub (`gh`).** Menos código que la API, pero agrega una dependencia
   externa a un repositorio cuyo único prerrequisito es PowerShell y git, y sigue
   necesitando su propia sesión autenticada.
3. **`git`.** Ya es prerrequisito, ya está autenticado en la estación donde viven los
   clones, y no necesita que la herramienta aporte nada.

## Decisión

Se lee por `git`: `ls-remote` para resolver la rama a un commit, `fetch --depth 1` cuando
el commit no está local, `show <sha>:<ruta>` para el contenido.

Las razones, en orden de peso:

**La autenticación es la que la estación ya tiene.** Credential manager, SSH o un PAT ya
configurado en `git`: la herramienta no elige, no guarda y no ve ninguna de las tres. La
consecuencia práctica es una regla simple de explicar y de auditar: **si la persona puede
clonar, la herramienta puede leer; si no, no.** No hay un segundo camino de acceso que
haya que razonar aparte.

**Cero superficie de credenciales en este repositorio.** No hay token de SCM que pedir,
rotar, filtrar ni revocar. Un secreto que no existe no se puede perder, y ese es
justamente el punto: el resto del proyecto ya trata a los secretos declarando su
**nombre** y nunca su valor, y esta decisión evita tener que declarar uno más.

**Un solo camino de código, y agnóstico del proveedor.** `git` responde igual contra
github.com, contra GitHub Enterprise Server o contra cualquier otro remoto. No hay un
caso especial por proveedor porque no hay proveedor en el código: hay un remoto.

Se verificó antes de decidir, no después: `git ls-remote` contra el remoto de este
repositorio devolvió el commit exacto que tenía la copia local, sin que la herramienta
aportara ninguna credencial y con `GIT_TERMINAL_PROMPT=0` puesto.

## El límite que esto impone, y que se respeta

Un `fetch` escribe en el repositorio local. Concretamente: **agrega objetos y mueve
`FETCH_HEAD`**. No hace checkout, no mueve ninguna rama, no toca el árbol de trabajo, no
mergea.

Ese límite es la razón de que no exista camino de `checkout`, `reset`, `pull`, `merge`,
`commit` ni `push` en `Scm.Git`, y de que un test del contrato haga grep exigiendo su
ausencia. Correr esto sobre el clon de alguien mientras trabaja tiene que dejar sus
archivos y su rama actual exactamente como estaban.

## Consecuencias

**Bueno.** No hay credenciales que pedir, rotar ni proteger, y por lo tanto tampoco hay
un permiso que se pueda otorgar de más. Cualquier remoto git se comporta igual, así que
mover un repositorio de proveedor no toca este código.

**Malo.** Hace falta un clon local de cada repositorio, y `pipeline-drift` lo declara
explícitamente en `workingCopyRoot`. Una consulta por API no lo necesitaría. Acá el clon
ya existe —es la copia con la que se trabaja— y compararla es justamente el objetivo, así
que el costo es nulo en una estación de trabajo y sería real en un agente limpio.

**Malo.** `git` se invoca como proceso, y eso trajo dos detalles que hubo que resolver.
`ProcessStartInfo.ArgumentList` no existe en .NET Framework, así que el quoting de
argumentos de Windows está implementado a mano y probado. Y `GIT_TERMINAL_PROMPT` se
desactiva: sin eso, git contra un remoto que no puede autenticar se queda esperando un
usuario que nunca llega, y la corrida cuelga sin salida en lugar de fallar con un mensaje.

**Neutro.** La API REST de GitHub sigue siendo una optimización posible —ahorraría el
`fetch`— pero no es un requisito, y adoptarla reintroduciría las dos cosas que esta
decisión evita: un segundo camino de código y una credencial propia.
