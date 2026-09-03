# Changelog

Todo cambio relevante se registra acá.

El formato sigue [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), y este proyecto
adhiere a [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

La versión es significativa porque los schemas de configuración son un contrato: un cambio
incompatible en un schema es una versión mayor, haga lo que haga el código.

## [0.1.0] - 2026-09-01

Primera entrega. Sólo lectura: inventario de jobs, detección de deriva de pipelines y
lectura de Jira. No existe camino de código que escriba.

### Agregado

- **`job-inventory`** — recorre las carpetas declaradas de un controller y exporta la
  configuración de cada job desde `config.xml`, que es el único documento que tiene el
  Branch Specifier, la ruta del script, los defaults de los parámetros y los triggers.
  `plan` compara contra la declaración y clasifica cada propiedad por separado, así que el
  reporte nombra qué difiere y no que "el job difiere". Un job no declarado se preserva y se
  reporta; un job ilegible se reporta `blocked` y el recorrido sigue.

- **`pipeline-drift`** — une tres fuentes para responder qué commit alimenta realmente a
  cada job: el job vivo dice qué rama lee, el remoto dice a qué commit apunta, y la copia
  local dice qué está mirando quien trabaja. Detecta la trampa de un job que lee `main`
  mientras alguien edita una rama feature, que hoy no produce ningún error. Verifica además
  que la copia de trabajo apunte al repositorio que el job lee, porque sin eso una
  comparación de archivos podría ser entre dos repositorios distintos.

- **`jira-inventory`** — resuelve el id opaco de un campo personalizado a partir de su
  nombre visible, y corre consultas JQL declaradas. Con más de un campo del mismo nombre
  reporta `blocked` con los candidatos, en lugar de devolver el primero.

- **`JenkinsAsCode.Http`** — HTTP de sólo lectura compartido por los dos transportes: URL,
  credencial Basic, retry, negativa a seguir redirects y decodificación UTF-8 explícita. No
  sabe nada de Jenkins ni de Jira. Existe para que la política de retry esté escrita una vez
  y no dos. Ver [ADR 0003](docs/adr/0003-shared-http-layer.md).

- **`Jenkins.Rest`, `Jenkins.Jobs`** — lo específico de Jenkins, con el parser de
  `config.xml` como función pura sobre una cadena, testeable contra fixtures sin controller,
  sin token y sin red.

- **`Scm.Git`** — resuelve una rama a un commit y lee un archivo en ese commit, por la línea
  de comandos de `git`. Un solo camino de código para cualquier remoto git, y ningún token
  de SCM. Ver [ADR 0002](docs/adr/0002-git-cli-instead-of-provider-apis.md).

- **`Jira.Rest`** — lectura de Jira, con el endpoint de búsqueda y el esquema de paginación
  correctos según la versión de API.

- **Documentación** — dieciséis notas de comportamiento de la API de Jenkins y cinco de
  Jira, cada una con **el síntoma** que produce; tres ADR; el contrato de automatización; el
  modelo de comandos; el modelo de seguridad; guías de instalación y de diagnóstico.

- **Suite de tests** — 123 tests, todos offline. Prueba **ausencias** además de presencias:
  que ningún `ValidateSet` contenga `apply`, que no exista un `-Method Post`, que no haya un
  `git checkout`, y que `Invoke-WebRequest` figure en un solo archivo.

### Portado desde un repositorio hermano para Azure DevOps

- `JenkinsAsCode.Plan`, `.Report` y `.Configuration` se copiaron sin cambios funcionales:
  por diseño no contienen una sola referencia a Azure DevOps, y eso se verificó antes de
  portarlos. Se conserva el vocabulario cerrado de estados y acciones para que quien lea un
  plan de cualquiera de los dos repositorios no tenga que aprender dos idiomas.
- `Get-JenkinsAsCodeMemberList` se retiró: era específico de Teams de Azure DevOps y acá no
  tiene uso. En su lugar, `Get-JenkinsAsCodeRequiredValue`, que vive en la capa compartida
  porque hay **dos** transportes y una regla implementada dos veces se desincroniza.

### Corregido durante el desarrollo

Se registran porque son la evidencia de que la suite hace algo:

- El parser fallaba en **todos** los `config.xml` reales. Jenkins escribe una declaración
  XML 1.1 desde la versión 2.190 y `System.Xml.XmlDocument` parsea 1.0 solamente, con un
  mensaje —`Version number '1.1' is invalid`— que se lee como documento corrupto y no como
  diferencia de versión. `ConvertTo-Xml10Text` quita la declaración y reemplaza los
  caracteres que 1.0 prohíbe, **reportando las dos cosas**: un parser que edita su entrada
  en silencio es como un diff sale limpio contra un documento que era distinto.

- `New-JenkinsJobPath` rechazaba un job llamado `Job`. La guarda que lo hacía partía de una
  premisa falsa: que un segmento llamado `job` sería indistinguible del separador `/job/`.
  No lo es — la alternancia de la URL es estricta, así que `/job/A/job/job` nombra al job
  `job` dentro de la carpeta `A`. Y como PowerShell compara sin distinguir mayúsculas, la
  guarda se llevaba puesto un nombre corriente. Se eliminó.

- `ConvertTo-ProcessArgumentString` no aceptaba un argumento vacío, porque la validación por
  defecto de un parámetro `[string[]]` obligatorio lo rechaza. `git` legítimamente recibe
  argumentos vacíos.

- `ProcessStartInfo.ArgumentList` no existe en .NET Framework, así que el quoting de
  argumentos de Windows está implementado a mano siguiendo las reglas de
  `CommandLineToArgvW`, y probado. Sin eso, una ruta con un espacio se parte en dos
  argumentos y git responde sobre algo que nadie preguntó.

### Corregido al correr contra el parque real

La primera corrida con credenciales encontró seis cosas más. Se registran porque cada una
era invisible hasta tocar un sistema de verdad:

- **La puerta de datos sensibles no podía pasar nunca en una instalación real.** Escaneaba
  `.env`, que está en `.gitignore`, contiene las credenciales a propósito, y por lo tanto
  producía dos hallazgos en cada corrida. Una puerta que nunca puede pasar es una puerta
  que la gente aprende a ignorar, que es justo la falla que esta verificación existe para
  evitar. Ahora le pregunta a git qué ignora, en lugar de mantener una segunda copia de las
  reglas que se desincroniza de `.gitignore`.

  De paso: `git check-ignore --stdin` **no** sirve para esto. Con rutas por stdin no matchea
  nada y sale con código 1 — la misma respuesta que da para "no ignorado" — mientras que las
  mismas rutas como argumentos matchean bien. Medido contra git 2.46.0.windows.1. Una
  respuesta silenciosamente incorrecta de una verificación de seguridad es peor que no
  tenerla, así que se usa `git status --porcelain --ignored`, que reporta en voz alta.

- **Los reportes se escribían con BOM.** `Set-Content -Encoding UTF8` en PowerShell 5.1
  agrega BOM, y un JSON que empieza con BOM lo rechazan los parsers estrictos: Python
  responde `Unexpected UTF-8 BOM`. Un reporte que nadie puede parsear no es evidencia.

- **El reporte decía `null` donde quería decir "ninguno".** Tercera aparición del mismo
  peligro de PowerShell 5.1: un `@()` que sale de un bloque de script se desenvuelve a
  `$null`. Para quien consume el reporte, `null` y `[]` son afirmaciones distintas —"no se
  sabe" contra "ninguno"— y un inventario no puede confundirlas. Afectaba a 45 de 126 jobs.

- **`Import-Foundation.ps1` filtraba `$Name` y `$Force` al ámbito de quien lo llamaba.** Se
  carga con dot-sourcing, así que su bloque `param` declara variables en el ámbito del
  llamador. Un `$name = "customField/$key"` en un punto de entrada asignaba a ese `$Name`
  tipado `[string[]]` —los nombres no distinguen mayúsculas— y devolvía un array de un
  elemento. La función siguiente que esperaba `[string]` fallaba tres capas más allá. Los
  parámetros ahora están prefijados, que es lo mismo que ya hacían todas las variables del
  cuerpo, y por la misma razón.

- **Cero coincidencias rompía la resolución de un campo de Jira**, que es su caso más
  importante: es la respuesta "ese campo no existe". El array vacío llegaba como `$null`.

- **Una URL base con un path de UI producía un error ilegible.** Pegar la URL de la barra del
  navegador es la forma habitual de configurar esto mal: una URL de Jira copiada del tablero
  arrastra `/jira/software`, y cada petición cae en una página HTML que responde 200. El
  error era `Invalid JSON primitive` señalando una línea dentro de un módulo de transporte.
  Ahora se nombra la causa probable y qué revisar.

### Corregido al verificar un clon limpio

- **Dos tests de la puerta de datos sensibles dependian de estado local.** Afirmaban
  contra `.env` y `artifacts/`, que existen unicamente despues de correr
  `bootstrap.ps1` — y `git status --porcelain --ignored` solo lista rutas ignoradas
  que existen en disco. La suite pasaba en una copia de trabajo ya usada y fallaba en
  un clon recien hecho, que es el peor lugar donde descubrirlo. Ahora cada test crea
  su propio archivo de prueba y lo borra, y el directorio solo se elimina si fue el
  test quien lo creo.

### Notas

- El piso de soporte es Windows PowerShell 5.1. En 5.1 la configuración se valida con un
  validador de schema reducido, y el resultado nombra el motor que corrió, para que un
  reporte nunca afirme más cobertura de la que tuvo.
- La rama por defecto de este repositorio es `main`.
