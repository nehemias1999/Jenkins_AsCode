# Diagnóstico

**Propósito.** El síntoma primero, la causa después. Así se busca un error.

**Alcance.** Fallas al correr una automatización.

**Documentos relacionados**

- [../reference/jenkins-notes.md](../reference/jenkins-notes.md) — el comportamiento de la API detrás de varios de estos
- [../reference/jira-notes.md](../reference/jira-notes.md) — ídem, para Jira
- [getting-started.md](getting-started.md) — la instalación que varios de estos suponen hecha

## Listó los jobs y falló en el primero, con 403

**Es el permiso, no el token.** `Job/Read` alcanza para `/api/json` y **no** para
`config.xml`, que necesita `Job/ExtendedRead`. Como el listado funciona, parece que el
acceso está bien.

Pedir `Job/ExtendedRead` sobre las carpetas en alcance.

## `Version number '1.1' is invalid. Line 1, position 16.`

No debería verse: `ConvertTo-Xml10Text` lo maneja. Si aparece, es que un camino nuevo está
casteando a `[xml]` directamente en lugar de pasar por
`ConvertFrom-JenkinsJobConfigXml`.

Jenkins escribe una declaración XML 1.1 desde la versión 2.190 y .NET parsea 1.0 solamente.

## 404 en un job que existe

La ruta. En Jenkins **cada nivel de carpeta lleva su propio segmento `/job/`**:
`EXAMPLE-FOLDER/example-pipeline` vive en `/job/EXAMPLE-FOLDER/job/example-pipeline/`.

En la declaración se pone la ruta visible con `/` entre niveles —
`EXAMPLE-FOLDER/example-pipeline` — y `New-JenkinsJobPath` construye la URL. Si el 404 persiste,
comparar el nombre carácter por carácter: Jenkins distingue mayúsculas y PowerShell no, así
que un error de mayúsculas no se nota al leer.

## "GET ... was redirected (HTTP 301)"

`JENKINS_URL` está mal. Casi siempre `http` en lugar de `https`, o un prefijo de path de más
o de menos.

Los redirects no se siguen a propósito: mandar el header `Authorization` al host que indique
el `Location` es una fuga de credencial.

## 401 y el token es correcto

En **Jenkins**: tiene que ser un token de API de `/me/configure`, no la contraseña de la
cuenta.

En **Jira**: el token se empareja con el **email** de la cuenta, no con un nombre de
usuario. Es la causa más común de un 401 que parece token equivocado.

En los dos: revisar espacios al final del valor en `.env`. Se hace `Trim()` al leerlos
justamente por eso, pero conviene descartarlo.

## El inventario encontró menos jobs de los que muestra la UI

El token no ve alguna carpeta. `Get-JenkinsFolderChild` con un 404 devuelve vacío en lugar
de fallar, para que una carpeta inaccesible no corte el recorrido — y eso significa que una
carpeta faltante se ve como una carpeta vacía.

Revisar el reporte: una carpeta que se recorrió y no devolvió nada figura como `warning`.

## El inventario no descendió a todo

`maximumDepth`. Alcanzar el tope se marca en el ítem con `truncated`, y las rutas afectadas
se listan en el reporte, así que no se pierde en silencio. Si es legítimo, subir el valor.

## `plan` reporta deriva en todos los jobs Pipeline, por el label de agente

No debería: `job-inventory` no compara el label de un Pipeline. Un Pipeline declarativo
guarda su `agent { label }` en el `Jenkinsfile`, no en `config.xml`, así que `assignedNode`
vacío es correcto y no un dato faltante. El label lo reporta `pipeline-drift`.

## `pipeline-drift` dice que el commit remoto y el local difieren

Normal: un clon atrasado respecto del remoto es el estado normal de un clon. Se reporta
`warning`, no error, y está ahí para explicar el veredicto del archivo que viene abajo — un
`drift` contra un clon viejo no significa nada hasta actualizarlo.

## `pipeline-drift` dice `remoteUrl` pendiente

El remoto de la copia de trabajo **no es el repositorio que lee el job**. Cualquier
comparación de archivos debajo de eso es entre dos repositorios distintos.

Revisar `workingCopy` en `pipelines.json`, o el remoto del clon.

## La rama se reporta ambigua

El Branch Specifier del job tiene un comodín (`**`, `feature/*`) o está armado con una
variable de build. No nombra una sola rama, así que no hay un commit del que hablar.

Es un hecho de configuración, no un fallo de la herramienta: se reporta para que una persona
lo resuelva en lugar de elegir una rama y equivocarse con confianza.

## git se queda colgado y no devuelve nada

No debería: `GIT_TERMINAL_PROMPT=0` está puesto, y por eso `Invoke-GitCommand` falla con
mensaje en lugar de esperar. Si cuelga igual, hay un helper de credenciales gráfico
esperando. Probar el mismo comando a mano en ese directorio para verlo.

## `git ls-remote` falla con error de autenticación

La herramienta usa la autenticación que la estación ya tiene: no aporta ninguna credencial
propia, ni PAT ni clave SSH. Si `git fetch` a mano no funciona en ese clon, esto tampoco.

## Un campo de Jira se reporta `blocked` con dos candidatos

Hay **dos campos personalizados con el mismo nombre visible**. Jira lo permite, y pasa cada
vez que un campo se recrea en lugar de editarse.

Devolver el primero daría un id que funciona y pertenece al campo equivocado, así que decide
una persona. Mirar los dos ids en la UI y quedarse con el correcto.

## Una consulta de Jira devuelve cero y debería devolver algo

Un estado o componente renombrado **no hace fallar el JQL**: lo deja devolviendo cero filas.
Correr el mismo JQL en la UI de Jira. Cero ahí también significa que el JQL quedó viejo, no
que la cola esté vacía.

## El escaneo de datos sensibles marca algo que parece falso positivo

Acotar la expresión de permitidos de esa regla en `scripts/Test-NoSensitiveData.ps1`.
**Nunca** ensanchar la regla para que el hallazgo desaparezca.

## Un test falla con "empty ForEach"

Pester evalúa `-ForEach` en la fase de descubrimiento, **antes** de `BeforeAll`. Los datos
que alimentan un `-ForEach` van en `BeforeDiscovery`.
