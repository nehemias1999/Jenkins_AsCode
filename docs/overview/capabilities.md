# Catálogo de capacidades

**Propósito.** Listar cada capacidad, dónde vive y cómo se invoca.

**Alcance.** Capacidades funcionales. Los campos de configuración están en la guía de cada
módulo; el significado de cada verbo en
[command-model.md](../reference/command-model.md).

**Documentos relacionados**

- [scope-and-limits.md](scope-and-limits.md) — las capacidades ausentes a propósito

## 1. De un vistazo

| Módulo | Es dueño de | Punto de entrada |
| --- | --- | --- |
| `job-inventory` | Carpetas, jobs y las propiedades que sólo viven en `config.xml` | `automations/job-inventory/Invoke-JobInventory.ps1` |
| `pipeline-drift` | La unión de job vivo, remoto y copia local | `automations/pipeline-drift/Invoke-PipelineDrift.ps1` |
| `jira-inventory` | Campos personalizados y consultas JQL | `automations/jira-inventory/Invoke-JiraInventory.ps1` |

Los tres se invocan igual: `-Command <verbo>`, y ninguno escribe.

## 2. Jobs y carpetas

| Capacidad | Qué hace | Comando |
| --- | --- | --- |
| Descubrir carpetas y jobs | Recorre en anchura, una petición por carpeta, con tope de profundidad. Alcanzar el tope se reporta en el ítem, nunca se descarta en silencio. | `inventory` |
| Exportar la configuración de un job | Lee `config.xml`, el único documento que tiene el Branch Specifier, la ruta del script, los defaults de los parámetros y los triggers. | `inventory` |
| Comparar contra lo declarado | Cada propiedad declarada es su propia operación, así que el reporte nombra exactamente qué difiere, no que "el job difiere". | `plan` |
| Detectar una diferencia sólo de mayúsculas | Se reporta aparte. Las refs de git distinguen mayúsculas y `Main` contra `main` se lee como un typo en un reporte. | `plan` |
| Reportar un job no declarado | Se preserva y se reporta. Nunca se toca. | `plan` |
| Reportar un script inline | Un pipeline guardado en el job no tiene commit detrás, así que la deriva no es una pregunta que se le pueda hacer — y eso es el hallazgo. | `plan` |
| Sobrevivir a un job ilegible | Se reporta `blocked` para ese job y el recorrido sigue. Un reporte con los otros cuarenta jobs es más útil que una excepción. | `inventory`, `plan` |

## 3. Qué commit corre realmente

| Capacidad | Qué hace | Comando |
| --- | --- | --- |
| Resolver el Branch Specifier | `main`, `*/main`, `origin/main` y `refs/heads/main` son la misma rama. Un comodín o un valor armado con una variable se reportan como ambiguos, no se adivinan. | `inventory`, `plan` |
| Resolver la rama a un commit | Por `git ls-remote`, consultando el ref exacto para que un tag homónimo no gane un sorteo. | `inventory`, `plan` |
| Comparar el `Jenkinsfile` | Fingerprint SHA-256 normalizado. Veredictos `identical`, `cosmetic`, `drift`. | `plan` |
| Verificar que se compara el repo correcto | Compara la URL del remoto local contra la que lee el job. Sin esto, un veredicto de deriva podría ser entre dos repositorios distintos. | `plan` |
| Leer el label de agente | Del `Jenkinsfile`, porque un Pipeline declarativo no lo guarda en `config.xml`. Es léxico y lo dice. | `plan` |

## 4. Jira

| Capacidad | Qué hace | Comando |
| --- | --- | --- |
| Resolver un campo por nombre visible | De `Example Stage` a `customfield_XXXXX`. Con más de un match, `blocked` con los candidatos: Jira permite nombres duplicados y elegir el primero da un id que funciona y pertenece al campo equivocado. | `inventory`, `plan` |
| Resolver un campo sin declararlo | `-FieldName`, para una pregunta puntual. Queda marcado como ad hoc en el reporte. | `inventory` |
| Correr una consulta declarada | Con paginación correcta según la versión de API. | `inventory`, `plan` |
| Detectar un JQL que quedó viejo | Una consulta declarada `non-empty` que devuelve cero es `warning`: un estado renombrado no hace fallar el JQL, lo deja devolviendo cero filas en silencio. | `plan` |

## 5. Evidencia

Todo comando que lee estado vivo escribe un reporte JSON y su resumen Markdown bajo
`artifacts/`, que no está versionado. El reporte pasa por redacción antes de escribirse, y
dos cosas nunca entran en él: el default de un parámetro Password, y el contenido de un
`Jenkinsfile`.
