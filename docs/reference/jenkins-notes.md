# Notas de comportamiento de Jenkins

**Propósito.** Registrar cada comportamiento de la API de Jenkins que hizo falta
descubrir, junto con el síntoma que produce cuando no se lo conoce.

**Alcance.** El controller de Jenkins. Las de Jira están en
[jira-notes.md](jira-notes.md).

**Audiencia.** Cualquiera que cambie `Jenkins.Rest` o `Jenkins.Jobs`, y cualquiera que
esté mirando un error que no tiene sentido.

**Documentos relacionados**

- [architecture.md](architecture.md) — dónde vive el código que aplica estas notas
- [troubleshooting.md](../guides/troubleshooting.md) — el síntoma primero, la causa después

Cada nota dice **el síntoma**, porque un error se busca por el síntoma y no por la
causa. Una nota sin la versión del controller no se puede volver a verificar más
adelante, así que el inventario registra `X-Jenkins` en cada corrida.

---

## 1. `config.xml` es el único documento autoritativo

**El comportamiento.** `/api/json` no expone el Branch Specifier, la ruta del script,
los valores por defecto de los parámetros ni los triggers. Todo eso existe únicamente en
`GET /job/<ruta>/config.xml`.

**El síntoma cuando no se sabe.** Ninguno. Un inventario construido sólo con
`/api/json` se ve completo, lista todos los jobs con sus nombres y estados, y es incapaz
de responder qué commit alimenta cada uno. La falla es que no falla.

**Lo que hace este repositorio.** Todo job se lee por `config.xml`. `/api/json` se usa
sólo para enumerar los hijos de una carpeta.

## 2. `Job/Read` alcanza para listar y no para leer

**El comportamiento.** `Job/Read` permite `/api/json`. Leer `config.xml` exige
**`Job/ExtendedRead`** (o `Overall/Administer`).

**El síntoma.** Un inventario que enumera cuarenta jobs correctamente y devuelve
**403 en el primero** que intenta leer. Se lee como un problema de red o de token, y es
un permiso.

**Lo que hace este repositorio.** El 403 lleva ese texto en el mensaje, y un job
ilegible no corta el recorrido: se reporta `blocked` para ese job y los demás siguen.

## 3. Jenkins escribe una declaración XML 1.1 que .NET no puede parsear

**El comportamiento.** Desde Jenkins 2.190, `config.xml` empieza con
`<?xml version='1.1' encoding='UTF-8'?>`. Lo hace porque XML 1.1 admite caracteres de
control que 1.0 prohíbe, y una descripción de job pegada desde otro lado puede tenerlos.
`System.Xml.XmlDocument` soporta XML 1.0 solamente.

**El síntoma.**

```text
Version number '1.1' is invalid. Line 1, position 16.
```

Se lee como un documento corrupto, no como una diferencia de versión. Y afecta a
**todos** los jobs de **todos** los controllers modernos, así que es lo primero que
rompe.

**Lo que hace este repositorio.** `ConvertTo-Xml10Text` quita la declaración —el texto
ya está decodificado, así que la codificación declarada no aporta nada— y reemplaza los
caracteres que 1.0 prohíbe. Las dos cosas se **reportan** en el resultado: un parser que
edita su entrada en silencio es como un diff sale limpio contra un documento que en
realidad era distinto.

## 4. Cada nivel de carpeta lleva su propio segmento `/job/`

**El comportamiento.** El job que la UI muestra como `EXAMPLE-FOLDER/example-pipeline` vive
en `/job/EXAMPLE-FOLDER/job/example-pipeline/`, no en `/job/EXAMPLE-FOLDER/example-pipeline/`.

**El síntoma.** 404. Y un 404 se interpreta como "el job no existe", cuando lo que no
existe es esa URL.

**Lo que hace este repositorio.** `New-JenkinsJobPath` construye la alternancia y
escapa cada segmento. Un job cuyo nombre es literalmente `job` **no** es ambiguo: la
alternancia es estricta, así que `/job/A/job/job` nombra al job `job` dentro de la
carpeta `A`. Una versión anterior lo rechazaba por una ambigüedad inexistente, y de paso
rechazaba el nombre corriente `Job`, porque PowerShell compara sin distinguir
mayúsculas.

## 5. `depth=` es inusable; `tree=` es la herramienta

**El comportamiento.** `?depth=1` devuelve todos los builds de todos los jobs.

**El síntoma.** En un controller con algunos cientos de jobs, una respuesta lo bastante
grande como para hacer timeout, cuando los campos que se querían eran tres.

**Lo que hace este repositorio.** Toda lectura de `/api/json` lleva un `tree=`
explícito. No hay ninguna llamada con `depth=`.

## 6. Un Pipeline declarativo no guarda su label de agente en el job

**El comportamiento.** La directiva `agent` con su `label` vive en el `Jenkinsfile`, en
el SCM. El `config.xml` de un `flow-definition` no tiene `assignedNode`. Un job Freestyle
sí lo tiene.

**El síntoma.** Un inventario reporta label vacío en casi todos los jobs, y un plan que
tratara eso como deriva marcaría **todos** los jobs del controller.

**Lo que hace este repositorio.** `assignedNode` se reporta tal cual: vacío en un
Pipeline, y eso es correcto, no un dato faltante. El label real lo extrae
`pipeline-drift` del `Jenkinsfile`, léxicamente y diciendo que es aproximado.

## 7. Un parámetro de tipo Choice no tiene `defaultValue`

**El comportamiento.** `ChoiceParameterDefinition` no lleva elemento `defaultValue`. El
default es la primera opción de `choices`, y el nombre del elemento que las contiene
cambia según la versión del plugin.

**El síntoma.** El reporte dice que el job no tiene default, cuando sí lo tiene.

**Lo que hace este repositorio.** Toma la primera hoja bajo `choices`, sin depender del
nombre del contenedor.

## 8. El default de un parámetro Password está cifrado, no hasheado

**El comportamiento.** El `defaultValue` de un `PasswordParameterDefinition` guarda algo
de la forma `{AQAAABAAAAAQ...}`, que es **reversible** con la clave del controller.

**El síntoma.** Ninguno, hasta que el export del job termina pegado en un ticket.

**Lo que hace este repositorio.** Es el único campo de una definición de job que se
niega a leer. Se reportan el nombre y el tipo, y el default se reemplaza por un marcador.

## 9. Un Pipeline guarda sus triggers en una property; un Freestyle, en la raíz

**El comportamiento.** Un Pipeline los pone bajo una
`PipelineTriggersJobProperty`. Un Freestyle usa un elemento `triggers` de primer nivel.

**El síntoma.** Leer sólo el primero reporta **todos** los Freestyle como sin triggers,
y viceversa.

**Lo que hace este repositorio.** Lee los dos, con una sola expresión XPath.

## 10. `NullSCM` no es un SCM con URL vacía

**El comportamiento.** Un job sin repositorio declara la clase `hudson.scm.NullSCM`.

**El síntoma.** Tratarlo como un SCM cuya URL es la cadena vacía produce una deriva
reportada contra un job que correctamente no tiene repositorio.

**Lo que hace este repositorio.** Se reporta `kind = none`.

## 11. `Retry-After` puede ser una fecha, y puede ser absurdo

**El comportamiento.** El header admite segundos o una fecha HTTP, y las dos formas
aparecen detrás de un proxy inverso. Nada obliga a que el valor sea razonable.

**El síntoma.** Con un `Retry-After: 999999` honrado sin tope, la corrida queda
estacionada en `Start-Sleep` once días.

**Lo que hace este repositorio.** Parsea las dos formas y topa el resultado en
`retryAfterCapSeconds`, 120 por defecto.

## 12. Un fallo sin código HTTP es el más transitorio de todos

**El comportamiento.** Un fallo de DNS, un reset de TLS o un timeout no traen status.

**El síntoma.** Clasificarlos como no reintentables —porque no hay código con el que
coincidir— hace que la herramienta se rinda exactamente en las condiciones para las que
existe el retry.

**Lo que hace este repositorio.** El status `0` es reintentable. Y como **toda**
petición acá es un `GET`, reintentar siempre es seguro: un `POST` reintentado que el
servidor ya había confirmado fabrica un duplicado, un `GET` no puede.

## 13. Un token de API no necesita crumb CSRF

**El comportamiento.** Jenkins exime del crumb a las peticiones autenticadas con token
de API. Y de todas formas el crumb sólo hace falta para escribir.

**Lo que hace este repositorio.** No hay manejo de crumb, porque no hay camino de
escritura. Si algún día se agrega, esta nota deja de ser tranquilizadora.

## 14. Un redirect con `Authorization` es una fuga de credencial

**El comportamiento.** Si el cliente sigue un 30x, manda el header `Authorization` al
host que indique el `Location`.

**El síntoma.** La causa habitual es un `JENKINS_URL` equivocado —`http` en lugar de
`https`, o un prefijo de path de más o de menos— y el resultado es que el token viaja a
donde apunte el redirect.

**Lo que hace este repositorio.** `MaximumRedirection = 0`, y un 30x se reporta como el
problema de configuración que es, nombrando qué revisar.

## 15. La versión del controller viene en un header, no en el cuerpo

**El comportamiento.** `X-Jenkins` trae la versión. En Windows PowerShell 5.1 no existe
el parámetro `-ResponseHeadersVariable` de `Invoke-RestMethod`.

**Lo que hace este repositorio.** Usa `Invoke-WebRequest` en las dos versiones de
PowerShell —un solo camino de código— y registra la versión en cada inventario, para que
estas notas se puedan volver a verificar.

## 16. `config.xml` se sirve sin charset

**El comportamiento.** La respuesta no trae parámetro `charset`, y Windows PowerShell
5.1 entonces cae a ISO-8859-1.

**El síntoma.** Cualquier carácter no ASCII de una descripción de job o de un default de
parámetro llega corrupto, y una comparación reporta deriva por un acento.

**Lo que hace este repositorio.** Decodifica los bytes crudos como UTF-8 siempre, en
lugar de confiar en el charset de la respuesta. También quita un BOM inicial, que haría
fallar el cast a `[xml]` con "Data at the root level is invalid".
