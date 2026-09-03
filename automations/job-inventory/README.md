# job-inventory

**Propósito.** Descubrir los jobs de un controller de Jenkins y reportar en qué difiere
la configuración viva de la declarada.

**Alcance.** Carpetas, jobs y las propiedades que sólo viven en `config.xml`.
La comparación contra el contenido del `Jenkinsfile` es de [pipeline-drift](../pipeline-drift/README.md).

## Por qué existe

El Branch Specifier, la ruta del script, los defaults de los parámetros y los triggers
de un job **no aparecen en `/api/json`**. Viven únicamente en `config.xml`, que hoy nadie
exporta. La consecuencia práctica es que ningún archivo de ningún repositorio registra
qué rama lee cada job, y la única forma de saberlo es abrir la UI y mirar.

Este módulo produce ese export, versionable y comparable.

## Configuración

Se crea **renombrando** la plantilla, no copiándola: el nombre activo es el que
`.gitignore` excluye, y una copia con otro nombre termina versionada.

```text
config/jobs.example.json  ->  config/jobs.json
```

| Campo | Significado |
| --- | --- |
| `folders` | Carpetas a recorrer. Una cadena vacía recorre la raíz del controller. |
| `maximumDepth` | Niveles a descender. Existe un tope para que un recorrido no se dispare en un controller cuyas carpetas descubren sus propios hijos. |
| `jobs[].key` | Nombre corto y estable. Es la fila en todo reporte. |
| `jobs[].path` | Ruta visible, con `/` entre niveles de carpeta. |
| `jobs[].expected.type` | `pipeline`, `freestyle`, `multibranch`, `folder`, `maven`, `matrix`, `organization-folder`. |
| `jobs[].expected.enabled` | `false` significa que se espera que el job esté deshabilitado. |
| `jobs[].expected.scmUrl` | Repositorio que lee. Omitir en un job sin SCM. |
| `jobs[].expected.branchSpecifier` | Tal como está en `config.xml`, textual. `*/main` y `refs/heads/main` son escrituras distintas y se registran como están. |
| `jobs[].expected.scriptPath` | Ruta del `Jenkinsfile` dentro del repositorio. |

Una propiedad opcional que se omite **no se compara**, y el reporte lo dice: afirmar `ok`
sobre algo que nunca se comparó es como un reporte se vuelve confiadamente falso.

**La declaración no se escribe a mano.** Se corre `inventory` primero, se lee el
snapshot y se deriva de ahí. Después `plan` contra el mismo controller tiene que dar
**cero `pending`**, y ese cero es la prueba de que el inventario y la comparación
coinciden.

## Comandos

```powershell
.\Invoke-JobInventory.ps1 -Command validate    # offline, sin token
.\Invoke-JobInventory.ps1 -Command inventory   # recorre y escribe el snapshot
.\Invoke-JobInventory.ps1 -Command plan        # compara declarado contra vivo
.\Invoke-JobInventory.ps1 -Command plan -JobKey example-pipeline
.\Invoke-JobInventory.ps1 -Command smoke       # plan + checklist manual
```

No hay `apply`, y no existe camino de código que pueda escribir. Ver
[ADR 0001](../../docs/adr/0001-read-only-by-construction.md).

## Permisos

| Permiso | Para qué |
| --- | --- |
| `Overall/Read` | Alcanzar el controller. |
| `Job/Read` | Listar los hijos de una carpeta. |
| **`Job/ExtendedRead`** | Leer `config.xml`. **Con `Job/Read` solo, `/api/json` responde y `config.xml` da 403** — un inventario que lista los jobs y falla en el primero es casi siempre esto. |

## Salida

`artifacts/reports/job-inventory-<comando>-<fecha>.json` y su resumen `.md`.
`artifacts/` no está versionado.

El snapshot lleva nombre y tipo de cada parámetro, **nunca su valor por defecto**.
Distinguir de forma confiable un default inocuo de un secreto no vale el riesgo en un
archivo que termina pegado en un ticket.

## Qué no reporta como problema

Un job **no declarado** se reporta y no se toca nunca. Lo que un job contiene —su
historial de builds, lo que tenga encolado— no está en la declaración, así que el radio
de impacto de tocarlo no se puede predecir desde un plan.

Un **label de agente vacío** en un job Pipeline es correcto, no un dato faltante. Un
Pipeline declarativo guarda su label en el `Jenkinsfile`, en el SCM, no en `config.xml`.
Lo reporta `pipeline-drift`, que sí lee el archivo.

## Rollback

**No hay nada que revertir.** Este módulo no escribe en Jenkins: no existe verbo `apply`
ni función que envíe otra cosa que `GET`. Lo único que produce son archivos bajo
`artifacts/`, que se pueden borrar sin consecuencia alguna.

Si en algún momento se agrega escritura, hará falta un plan de rollback real, y esa
sección tendrá que decir qué hacer cuando un `POST` de `config.xml` reemplace el
documento completo y destruya lo no declarado.
