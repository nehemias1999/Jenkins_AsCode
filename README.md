# Jenkins as Code

Configuración declarativa y revisable de los jobs de un controller de Jenkins, en
PowerShell contra la API REST, sin ninguna dependencia más allá de PowerShell y git.

**No escribe nada.** Lee el controller, lee el SCM, lee Jira, y reporta.

```powershell
.\automations\job-inventory\Invoke-JobInventory.ps1    -Command inventory
.\automations\job-inventory\Invoke-JobInventory.ps1    -Command plan
.\automations\pipeline-drift\Invoke-PipelineDrift.ps1  -Command plan
```

---

## El problema

*¿El job que corre en producción está leyendo el commit que yo creo?*

Es la pregunta que importa la mañana después de un envío fallido, y hoy no se puede
responder sin abrir la UI de Jenkins y comparar a mano.

Tres hechos, cada uno inocuo por separado:

**El Branch Specifier no está en ningún archivo.** Vive en la configuración del job, en el
controller. `/api/json` no lo devuelve. No existe un export de la configuración de los jobs
— no está desactualizado: no existe.

**El `Jenkinsfile` sí está versionado, y eso engaña.** Da la impresión de que el circuito
está *as code*. Pero lo versionado es el *contenido* del pipeline, no *qué rama lee el job*.
Las dos mitades de la respuesta viven en lugares distintos y sólo una está bajo control de
versiones.

**Crear una rama no cambia lo que corre.** Un job configurado para leer `main` sigue
corriendo `main`, por más ramas feature que existan. Hay que cambiar también el Branch
Specifier — en la UI. Y nada registra si se cambió.

La falla no tiene mensaje de error: el job corre bien, con el código viejo.

Versión completa: [docs/overview/problem-statement.md](docs/overview/problem-statement.md).

## Por qué es más difícil de lo que parece

Cuatro comportamientos de la API de Jenkins convierten "automatizá el inventario" en un
problema de diseño real. Cada uno tiene una implementación que parece funcionar.

| El comportamiento | La implementación obvia | Qué produce |
| --- | --- | --- |
| `/api/json` no expone el Branch Specifier ni la ruta del script | Inventariar con `/api/json`, que es la API documentada | Un inventario que se ve completo y no puede responder qué commit corre. **La falla es que no falla** |
| Jenkins escribe una declaración **XML 1.1** y .NET parsea 1.0 | Castear a `[xml]` | `Version number '1.1' is invalid`, en **todos** los jobs de **todos** los controllers modernos |
| `Job/Read` alcanza para listar y no para leer `config.xml` | Pedir permiso de lectura | Un inventario que enumera cuarenta jobs y da 403 en el primero, que se lee como problema de red |
| El default de un parámetro Password está cifrado de forma **reversible** | Exportar la definición completa del job | Un export de jobs que es una fuga de credenciales, en cuanto se adjunta a un ticket |

[docs/reference/jenkins-notes.md](docs/reference/jenkins-notes.md) documenta dieciséis
comportamientos como estos, cada uno con **el síntoma** que produce, porque un error se
busca por el síntoma. Manejarlos es la mayor parte de lo que es este repositorio.

## Enfoque

| Principio | En la práctica |
| --- | --- |
| **Declarar, después comparar** | `inventory` dice qué existe sin mirar la declaración; `plan` compara y clasifica cada diferencia |
| **Nunca escribir** | No hay verbo `apply`, ni confirmación, ni función que envíe otra cosa que `GET`. Es la ausencia del camino de código, verificada por un test |
| **No adivinar** | Un comodín en un Branch Specifier, un nombre de campo de Jira duplicado o un script inline se reportan como `blocked`, no se resuelven de una forma plausible |
| **Lo que no se comparó no se afirma** | Una propiedad no declarada produce `skip`, con el valor vivo al lado. `ok` significa que se miró y coincidía |
| **La idempotencia es el criterio de aceptación** | Declarado lo que `inventory` encontró, `plan` da cero `pending`. Ese cero es lo que hace creíble cualquier hallazgo posterior |

## Los tres módulos

| Módulo | Responde | Guía |
| --- | --- | --- |
| `job-inventory` | Qué jobs existen, cómo están configurados, y en qué difieren de lo declarado | [guía](automations/job-inventory/README.md) |
| `pipeline-drift` | Qué commit alimenta realmente a cada job, y si la copia local es ese código | [guía](automations/pipeline-drift/README.md) |
| `jira-inventory` | Qué id opaco está detrás de un campo personalizado, y qué devuelven las consultas declaradas | [guía](automations/jira-inventory/README.md) |

## Cómo lee el SCM

Por la línea de comandos de `git`, no por la API del proveedor. La API REST de GitHub
resolvería la consulta, pero obligaría a este repositorio a tener un PAT propio, con todo
lo que eso arrastra: declararlo, guardarlo, rotarlo y protegerlo. `git` ya es
prerrequisito y ya está autenticado en la estación, así que la regla es simple de explicar
y de auditar —**si podés clonar, la herramienta puede leer**— y **acá no hay ningún token
de SCM**.

Lo único que toca localmente es un `fetch` superficial cuando el commit que el job lee no
está en el clon: agrega objetos y mueve `FETCH_HEAD`. No hace checkout, no mueve ramas, no
toca el árbol de trabajo. No existe camino de `checkout` ni de `pull` en el código, y un
test lo verifica.

[docs/adr/0002-git-cli-instead-of-provider-apis.md](docs/adr/0002-git-cli-instead-of-provider-apis.md).

## Empezar

```powershell
git clone https://github.com/nehemias1999/Jenkins_AsCode.git
cd Jenkins_AsCode
.\scripts\bootstrap.ps1

# Offline: sin red, sin token. Prueba que la instalación y la declaración son sanas.
.\automations\job-inventory\Invoke-JobInventory.ps1 -Command validate
```

Prerrequisitos: Windows PowerShell 5.1 o PowerShell 7, y git. Nada más — sin módulos, sin
SDK, sin gestor de paquetes. Es deliberado: una herramienta que observa una plataforma tiene
que correr en una estación restringida y en un agente sin preparar ninguno de los dos.

`Pester` y `PSScriptAnalyzer` hacen falta **sólo** para la suite de tests.

El permiso que importa es **`Job/ExtendedRead`**: con `Job/Read` solo, el listado funciona y
`config.xml` da 403. Detalle completo en
[docs/guides/getting-started.md](docs/guides/getting-started.md).

## Verificar

```powershell
.\scripts\Invoke-Tests.ps1
```

Análisis estático, la suite unitaria y el escaneo de datos sensibles. La integración continua
corre el mismo comando, así que no hay una segunda definición de "pasa".

La suite prueba **ausencias** además de presencias: que ningún `ValidateSet` contenga
`apply`, que no exista un `-Method Post`, que no haya un `git checkout`, y que
`Invoke-WebRequest` figure en un solo archivo. Una regla que sólo está escrita en un
documento es una regla que el próximo commit puede romper sin que nada avise.

## Documentación

Empezar por [docs/README.md](docs/README.md), que rutea por necesidad en lugar de por tema.
Los tres documentos que probablemente hagan falta primero:

- [docs/overview/scope-and-limits.md](docs/overview/scope-and-limits.md) — qué **no** hace, y por qué cada hueco es una decisión
- [docs/reference/jenkins-notes.md](docs/reference/jenkins-notes.md) — el síntoma primero, cuando algo no tiene sentido
- [docs/reference/command-model.md](docs/reference/command-model.md) — cómo se lee un plan

## Seguridad

La configuración declara el **nombre** de una variable de entorno, nunca su valor. Por eso
se puede commitear y revisar como diff: no hay nada adentro que filtrar.

Tres cosas nunca entran en un reporte: el default de un parámetro Password (cifrado de forma
reversible, no hasheado), el default de cualquier parámetro en el snapshot, y el contenido de
un `Jenkinsfile`.

[docs/reference/security-model.md](docs/reference/security-model.md).
