# AGENTS.md

Contrato de mantenimiento de este repositorio. Escrito para un agente automatizado, e
igualmente usable por una persona que lo agarra en frío.

## 1. Leer esto primero, en este orden

1. Este archivo.
2. `git status --short --branch`.
3. [docs/README.md](docs/README.md) — el índice rutea por necesidad, así se lee un
   documento en lugar de todos.
4. Sólo lo que la tarea necesite:
   - Estructura y reglas de dependencia: [docs/reference/architecture.md](docs/reference/architecture.md)
   - Agregar una capacidad: [docs/reference/automation-contract.md](docs/reference/automation-contract.md)
   - Significado de verbos y estados: [docs/reference/command-model.md](docs/reference/command-model.md)
   - Un error que no tiene sentido: [docs/reference/jenkins-notes.md](docs/reference/jenkins-notes.md)
   - Contexto compartido: `foundation/config/project-context.json`
   - El módulo que se está cambiando: `automations/<nombre>/`

**Nunca leer ni imprimir** `.env`, nada bajo `.local/`, ni nada bajo `artifacts/`. Tienen
credenciales, valores de estación y registros de ejecución. Si una tarea parece necesitar
leer uno, no lo necesita: lo que hace falta es el **nombre** de una variable, y eso está en
la configuración.

## 2. Reglas que no se negocian

| Regla | Dónde se hace cumplir |
| --- | --- |
| Ningún camino de código escribe en Jenkins ni en Jira. | `Automations.Tests.ps1`, por grep de ausencia |
| `Invoke-WebRequest` aparece en **un solo archivo**. | Ídem |
| Ningún `ValidateSet` contiene `apply`, `reconcile`, `rename`, `delete` ni `remove`. | Ídem |
| Ningún comando de git cambia una rama o el árbol de trabajo. | Ídem |
| La configuración declara el **nombre** de un secreto, nunca un valor. | Schemas, más la puerta de datos sensibles |
| El default de un parámetro Password no se lee nunca. | `Get-JenkinsJobParameter`, más un test |
| El contenido de un `Jenkinsfile` no entra en un reporte. | Revisión, y el comentario en `pipeline-drift` |
| La capa compartida no lleva reglas de dominio. | Revisión, y [ADR 0003](docs/adr/0003-shared-http-layer.md) |

Cambiar cualquiera de estas es un ADR, no un commit.

## 3. Dónde va lo que se agrega

| Se agrega | Va en |
| --- | --- |
| Una capacidad sobre una familia de recursos que ya existe | El punto de entrada de esa automatización |
| Una capacidad sobre una familia nueva | Una automatización **nueva** |
| Algo que necesitan todas las automatizaciones | El módulo de `foundation/` que corresponda |
| Algo que necesita una sola, pero puesto en código compartido | En ningún lado. Va en esa automatización. |

La última fila es el punto de presión. Si la capa compartida parece necesitar un caso
especial para tu módulo, la lógica es de tu módulo.

## 4. Antes de commitear

```powershell
.\scripts\Invoke-Tests.ps1
.\automations\<módulo>\Invoke-<Módulo>.ps1 -Command validate
```

Análisis estático, suite unitaria, puerta de datos sensibles. La integración continua corre
el mismo comando, así que no hay una segunda definición de "pasa".

## 5. Definición de terminado

| # | Requisito |
| --- | --- |
| 1 | El análisis estático y la suite pasan. |
| 2 | El `README.md` del módulo refleja el comportamiento nuevo, incluida su sección de rollback. |
| 3 | Todo documento nuevo está enlazado desde `docs/README.md`. La suite falla si no. |
| 4 | `CHANGELOG.md` nombra el módulo y el resultado observable. |
| 5 | Un test cubre la regla nueva, con fixtures sin ningún dato real. |
| 6 | `plan` produce la misma salida para la misma entrada, o la diferencia se explica en el changelog. |
| 7 | Si el cambio agrega una forma de escribir, existe el ADR que lo autoriza. |

## 6. Commits

```text
#42 leer el label de agente del Jenkinsfile, no de config.xml
```

Imperativo, prefijado con el issue que cierra. La rama por defecto de este repositorio es
`main`, no `master`.

## 7. Convenciones de PowerShell que conviene saber antes de editar

| Convención | Por qué |
| --- | --- |
| Los parámetros de colección son **plurales**; las variables de bucle, singulares. | Los nombres de variable no distinguen mayúsculas, así que un `foreach ($item in ...)` contra un parámetro `[object[]] $Item` asigna al parámetro tipado y envuelve cada elemento en un array. La lectura de propiedades sigue funcionando por enumeración de miembros, así que nada falla: simplemente deja de comportarse. |
| `Set-StrictMode -Version Latest` en todos los módulos. | Un error de tipeo en un nombre de propiedad es un error, no `$null`. Una propiedad opcional se lee con guarda. |
| El XML se navega por **XPath**, no por propiedades encadenadas. | Bajo `StrictMode`, `$xml.project.scm.branches` lanza excepción en cualquier job que no tenga ese elemento, que son la mayoría. `SelectSingleNode` devuelve `$null`, y `$null` es una respuesta. |
| Sólo verbos aprobados. | `Initialize`, `Test`, `Get`, `New`, `Convert` — no `Ensure`, que no está aprobado. |
| La lógica peligrosa es una función **pura** que devuelve acción, estado y razón. | Es lo que la hace testeable offline, que es de donde vino toda la suite. |
| Ayuda basada en comentarios en toda función; los comentarios dicen **por qué**. | Lo que el código hace está en el código. |
| El código y sus comentarios en inglés; la documentación en español. | El código sigue el molde del repositorio hermano y se mantiene ASCII, porque `Get-Content -Raw` sin `-Encoding` en PowerShell 5.1 decodifica como ANSI. **Los JSON y los schemas también son sólo ASCII, por lo mismo.** Los `.md` no los lee el cargador, así que llevan acentos. |

`foundation/Import-Foundation.ps1` se carga con **dot-sourcing**, así que comparte el
ámbito de quien lo llama. Toda variable ahí está prefijada por esa razón.

## 8. Nunca en un commit

Tokens, contraseñas, claves privadas, nombres de host, direcciones IP, nombres de cliente o
de empleador, reportes de ejecución, nada de `.env`, `.local/` ni `artifacts/`.

La puerta de datos sensibles hace cumplir la mitad mecánica. Si marca algo que se cree falso
positivo, **acotar la expresión de permitidos** de esa regla — nunca ensanchar la regla para
que el hallazgo desaparezca.

## 9. Si algo no es seguro de automatizar

No se envía detrás de una advertencia. El plan reporta `manual` o `blocked`, la guía dice por
qué, y **no existe camino de código** al que echar mano por accidente. El ejemplo trabajado
es la escritura entera: ver [ADR 0001](docs/adr/0001-read-only-by-construction.md).

## 10. Una trampa de esta shell, para quien edite por Bash

El heredoc de Git Bash en este entorno **colapsa `\` a `\`**. Eso ya rompió una vez el
regex `'[/\]'` de `New-JenkinsJobPath`, que quedó como `'[/\]'` — un conjunto sin cerrar.
Para escribir un backslash doble, usar Python con `chr(92)` en lugar de un heredoc.
