# ADR 0003: El HTTP genérico vive en la capa base, no en cada transporte

**Estado.** Aceptado, 2026-09.

## Contexto

Hay dos sistemas externos: Jenkins y Jira. Cada uno necesita autenticación Basic,
construcción de URL, retry, traducción de errores, negativa a seguir redirects y
decodificación UTF-8 explícita.

El repositorio del que viene este diseño tenía **un** sistema externo, y por eso puso todo
eso en su módulo de transporte. Copiar esa forma acá significaría tener la política de
retry escrita dos veces.

Y la política de retry no es trivial. Tiene al menos tres reglas que la implementación
obvia se equivoca:

- Un fallo **sin** código HTTP —DNS, TLS, timeout— es el más transitorio de todos y hay
  que reintentarlo. Clasificarlo como no reintentable porque no hay código con el que
  coincidir es el error común, y hace que la herramienta se rinda exactamente en las
  condiciones para las que existe el retry.
- Un `Retry-After` honrado hay que **topar**, o un `999999` estaciona la corrida once
  días.
- `Retry-After` puede ser un número de segundos o una fecha HTTP, y las dos formas
  aparecen detrás de un proxy inverso.

Una regla implementada dos veces es una regla que se desincroniza. La corrección se aplica
en un lado y el otro sigue con el bug durante meses, hasta que aparece en la peor
circunstancia posible.

## Decisión

`JenkinsAsCode.Http` contiene lo genérico: `Assert-HttpBaseUrl`, `New-HttpUri`,
`New-BasicAuthorizationHeader`, la lectura de headers en las dos formas que devuelve
PowerShell, la decisión de retry, y `Invoke-ReadOnlyRequest`.

**No sabe nada de Jenkins ni de Jira.** No aparece una URL, un endpoint ni un nombre de
permiso en todo el módulo.

Lo específico se queda en el transporte que corresponde:

| En el transporte | Por qué |
| --- | --- |
| Cómo una ruta de carpeta se vuelve URL | Es una regla de Jenkins |
| Qué endpoint tiene la configuración autoritativa | Es una regla de Jenkins |
| Qué endpoint de búsqueda según la versión de API | Es una regla de Jira |
| Qué significa un 403 en este sistema | Es una regla de cada sistema |

La última fila es la que podía arruinar el diseño. El mensaje de un 403 de Jenkins tiene
que nombrar `Job/ExtendedRead`, y el de Jira tiene que nombrar `Browse Projects`. La
tentación es poner ese conocimiento en la capa compartida.

La solución: `Invoke-ReadOnlyRequest` acepta `-StatusMessage`, un diccionario de código a
texto que provee el transporte. Es **dato**, no conocimiento de dominio. La capa
compartida sigue sin saber qué sistema está del otro lado, y un 403 igual dice qué permiso
falta.

## La arista de dependencia que esto crea

`Jenkins.Rest` y `Jira.Rest` dependen de `JenkinsAsCode.Http` y de
`JenkinsAsCode.Configuration`. Es decir: el transporte depende de la base.

Eso es hacia abajo, no a los lados. `Configuration`, `Http` y `Plan` **no dependen de
nada**, así que nada puede ciclar a través de ellos, y ese es el orden de carga de
`Import-Foundation.ps1`. Ver [architecture.md](../reference/architecture.md), sección 2.

Por la misma razón se movió `Get-JenkinsAsCodeRequiredValue` —el lector de variables de
entorno obligatorias— de un transporte a `Configuration`: dos transportes lo necesitan, y
convertir un nombre declarado en un valor es exactamente carga de configuración.

## Consecuencias

**Bueno.** La política de retry existe una vez, con tests que la cubren una vez. Agregar
un tercer sistema externo —otro controller, GitLab, Bitbucket— es escribir un transporte
delgado, no reimplementar HTTP.

**Bueno.** `Jenkins.Rest` bajó de 685 a poco más de 300 líneas con este cambio, y lo que
quedó es exactamente lo que es específico de Jenkins. El módulo se volvió legible.

**Malo.** Un módulo más en `foundation/`. El manifiesto y el orden de carga hay que
mantenerlos.

**Neutro.** El nombre `JenkinsAsCode.Http` menciona Jenkins y el módulo no sabe nada de
Jenkins. Es el prefijo del repositorio, no del contenido, igual que `JenkinsAsCode.Plan`,
que tampoco sabe qué es un job.
